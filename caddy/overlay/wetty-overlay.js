/* ============================================================================
 * wetty-overlay.js — virtual keyboard for mterm.{$DOMAIN}
 *
 * Injected by Caddy (replace-response module) into wetty's index.html
 * just before </body>. No npm, no CDN, no modifications to wetty itself.
 *
 * Strategy: locate xterm.js's hidden helper textarea, then for each tap:
 *   - printable / control bytes  -> document.execCommand('insertText', ...)
 *   - special keys (Esc, arrows) -> dispatch synthetic KeyboardEvent
 *
 * Idempotent: a reload that re-runs this script will not double-inject.
 * ============================================================================ */
(function () {
    'use strict';

    // Guard against double-init if the script gets injected twice.
    if (window.__wettyOverlayLoaded) return;
    window.__wettyOverlayLoaded = true;

    // ---- Key mapping --------------------------------------------------------
    // Edit/extend this array to add or remove buttons. Each entry is either:
    //   { label, seq:  '<raw bytes>' }              -> sent via execCommand
    //   { label, key:  { key, code, keyCode, ... } } -> sent as KeyboardEvent
    // Optional: cls = extra CSS class ('mod' | 'arr' | 'util').
    const KEYS = [
        { label: 'ESC',    key: { key: 'Escape',    code: 'Escape',    keyCode: 27 } },
        { label: 'TAB',    key: { key: 'Tab',       code: 'Tab',       keyCode: 9  } },
        { label: 'Ctrl',   ctrl: true, cls: 'mod' },   // sticky modifier: next keystroke -> Ctrl+key
        { label: 'Ctrl+P', seq: '\x10', cls: 'mod' },  // zellij: prev pane
        { label: 'Ctrl+N', seq: '\x0e', cls: 'mod' },  // zellij: new pane
        { label: 'Ctrl+T', seq: '\x14', cls: 'mod' },  // zellij: new tab
        { label: 'Ctrl+O', seq: '\x0f', cls: 'mod' },  // zellij: session/layout
        { label: 'Ctrl+W', seq: '\x17', cls: 'mod' },  // zellij: close pane
        { label: 'Ctrl+Q', seq: '\x11', cls: 'mod' },  // zellij: quit / detach
        { label: 'Ctrl+C', seq: '\x03', cls: 'mod' },  // SIGINT
        { label: 'Ctrl+D', seq: '\x04', cls: 'mod' },  // EOF
        { label: '↑', cls: 'arr', key: { key: 'ArrowUp',    code: 'ArrowUp',    keyCode: 38 } },
        { label: '↓', cls: 'arr', key: { key: 'ArrowDown',  code: 'ArrowDown',  keyCode: 40 } },
        { label: '←', cls: 'arr', key: { key: 'ArrowLeft',  code: 'ArrowLeft',  keyCode: 37 } },
        { label: '→', cls: 'arr', key: { key: 'ArrowRight', code: 'ArrowRight', keyCode: 39 } },
    ];

    const HIDDEN_KEY = 'wovl:hidden';

    // ---- Sticky Ctrl modifier ----------------------------------------------
    // When armed, the next keystroke (whether produced by the soft keyboard
    // or by another bar button) is converted to its Ctrl+<letter> control
    // byte (\x01..\x1A for a..z, plus a few common symbols). Auto-disarms
    // after a single key. Tap Ctrl again to cancel without sending anything.
    let ctrlArmed = false;
    let ctrlBtnRef = null;

    function ctrlByteFor(ch) {
        if (!ch || ch.length !== 1) return null;
        const c = ch.toLowerCase();
        const code = c.charCodeAt(0);
        if (code >= 97 && code <= 122) return String.fromCharCode(code - 96); // a-z -> \x01-\x1a
        // Common Ctrl+symbol shortcuts
        switch (c) {
            case '@': case ' ': return '\x00'; // Ctrl+@ / Ctrl+Space
            case '[': return '\x1b';            // Ctrl+[ == ESC
            case '\\': return '\x1c';
            case ']': return '\x1d';
            case '^': return '\x1e';
            case '_': case '/': return '\x1f';
            case '?': return '\x7f';            // Ctrl+? == DEL
        }
        return null;
    }

    function setCtrlArmed(on) {
        ctrlArmed = !!on;
        if (ctrlBtnRef) ctrlBtnRef.classList.toggle('armed', ctrlArmed);
    }

    function installCtrlInterceptor() {
        // Capture-phase handler on the helper textarea: as soon as the next
        // 'input' fires (soft keyboard typed a char), swallow the char and
        // re-emit it as a control byte. We attach lazily because the textarea
        // may not exist yet when init runs.
        const ta = findTA();
        if (!ta || ta.__wovlCtrlHooked) return;
        ta.__wovlCtrlHooked = true;

        ta.addEventListener('beforeinput', (ev) => {
            if (!ctrlArmed) return;
            // Only single-char insertions can become Ctrl+letter. If the
            // browser sends a composition or a multi-char insert, just disarm.
            const data = ev.data || '';
            const byte = ctrlByteFor(data);
            if (data.length === 1 && byte) {
                ev.preventDefault();
                ev.stopPropagation();
                setCtrlArmed(false);
                // Send the control byte exactly like our other buttons do.
                sendSeq(byte);
            } else {
                setCtrlArmed(false); // unsupported char, just disarm
            }
        }, true);

        // Also hook keydown for desktop physical keyboards.
        ta.addEventListener('keydown', (ev) => {
            if (!ctrlArmed) return;
            // Ignore pure modifier presses
            if (ev.key === 'Control' || ev.key === 'Shift' || ev.key === 'Alt' || ev.key === 'Meta') return;
            const byte = ctrlByteFor(ev.key);
            if (byte) {
                ev.preventDefault();
                ev.stopPropagation();
                setCtrlArmed(false);
                sendSeq(byte);
            } else {
                setCtrlArmed(false);
            }
        }, true);
    }

    // ---- Input dispatch -----------------------------------------------------
    function findTA() {
        return document.querySelector('textarea.xterm-helper-textarea');
    }

    function sendSeq(seq) {
        const ta = findTA();
        if (!ta) return;
        ta.focus();
        // Primary path: insertText. xterm wires the textarea so that this
        // ends up shipped through the WebSocket as raw bytes.
        try {
            if (document.execCommand) {
                document.execCommand('insertText', false, seq);
                return;
            }
        } catch (_) { /* fall through */ }

        // Fallback: input event (some browsers).
        try {
            ta.value += seq;
            ta.dispatchEvent(new InputEvent('input', { data: seq, inputType: 'insertText', bubbles: true }));
        } catch (_) { /* give up silently */ }
    }

    function sendKey(opts) {
        const ta = findTA();
        if (!ta) return;
        ta.focus();
        const init = Object.assign({ bubbles: true, cancelable: true }, opts);
        ['keydown', 'keypress', 'keyup'].forEach(type => {
            try { ta.dispatchEvent(new KeyboardEvent(type, init)); } catch (_) {}
        });
    }

    // ---- DOM construction ---------------------------------------------------
    function buildBar() {
        const bar = document.createElement('div');
        bar.id = 'wovl';

        for (const k of KEYS) {
            const btn = document.createElement('button');
            btn.type = 'button';
            btn.textContent = k.label;
            if (k.cls) btn.className = k.cls;

            // Use pointerdown for snappier touch response, but prevent the
            // default so the textarea keeps focus on iOS / Android.
            const fire = (ev) => {
                ev.preventDefault();
                ev.stopPropagation();
                if (k.ctrl) {
                    // Sticky modifier toggle.
                    setCtrlArmed(!ctrlArmed);
                    return;
                }
                if ('seq' in k) sendSeq(k.seq);
                else if ('key' in k) sendKey(k.key);
            };
            btn.addEventListener('pointerdown', fire);
            // Belt-and-suspenders for browsers that swallow pointerdown.
            btn.addEventListener('click', (e) => { e.preventDefault(); });
            if (k.ctrl) ctrlBtnRef = btn;
            bar.appendChild(btn);
        }

        // Hide button
        const hide = document.createElement('button');
        hide.type = 'button';
        hide.className = 'util';
        hide.textContent = 'hide ▾';
        hide.addEventListener('pointerdown', (ev) => {
            ev.preventDefault();
            setHidden(true);
        });
        bar.appendChild(hide);

        return bar;
    }

    function buildShowPill() {
        const pill = document.createElement('button');
        pill.type = 'button';
        pill.id = 'wovl-show';
        pill.textContent = '⌨';
        pill.title = 'Show keyboard bar';
        pill.addEventListener('pointerdown', (ev) => {
            ev.preventDefault();
            setHidden(false);
        });
        return pill;
    }

    function setHidden(hidden) {
        const bar = document.getElementById('wovl');
        const pill = document.getElementById('wovl-show');
        if (hidden) {
            if (bar) bar.remove();
            document.body.classList.remove('wovl-on');
            if (!pill) document.body.appendChild(buildShowPill());
            try { localStorage.setItem(HIDDEN_KEY, '1'); } catch (_) {}
        } else {
            if (pill) pill.remove();
            if (!document.getElementById('wovl')) {
                document.body.appendChild(buildBar());
                document.body.classList.add('wovl-on');
            }
            try { localStorage.removeItem(HIDDEN_KEY); } catch (_) {}
        }
    }

    function init() {
        let hidden = false;
        try { hidden = localStorage.getItem(HIDDEN_KEY) === '1'; } catch (_) {}
        setHidden(hidden);
        installCtrlInterceptor();
    }

    // ---- Boot: wait for xterm's textarea to appear --------------------------
    function ready() {
        if (findTA()) { init(); return true; }
        return false;
    }

    if (!ready()) {
        const obs = new MutationObserver(() => {
            if (ready()) obs.disconnect();
        });
        obs.observe(document.documentElement, { childList: true, subtree: true });
        // Hard timeout: try anyway after 8s so a missing terminal still gets a bar
        setTimeout(() => {
            if (!document.getElementById('wovl') && !document.getElementById('wovl-show')) {
                init();
            }
        }, 8000);
    }
})();
