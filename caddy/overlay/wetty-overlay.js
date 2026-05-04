/* ============================================================================
 * wetty-overlay.js — virtual keyboard for mterm.{$DOMAIN}
 *
 * Features:
 *   - Multiple key sets, swipeable (left/right) on touch, mouse drag on desktop
 *   - Sticky modifiers Ctrl + Alt:
 *       tap          = arm for one keystroke
 *       long-press   = LOCK (every keystroke prefixed until tap-to-release)
 *   - F1..F12 in a "fkeys" set
 *   - hide/show pill, persisted in localStorage
 *
 * Injected by Caddy (replace-response) into wetty's index.html before </body>.
 * No external deps. Idempotent.
 * ============================================================================ */
(function () {
    'use strict';

    if (window.__wettyOverlayLoaded) return;
    window.__wettyOverlayLoaded = true;

    // ---- Storage keys -------------------------------------------------------
    const HIDDEN_KEY = 'wovl:hidden';
    const SET_KEY    = 'wovl:set';

    // ---- Special-key event helpers (printed as KeyboardEvent) --------------
    const K = (key, code, keyCode) => ({ key, code, keyCode });
    const ARROW_UP    = K('ArrowUp',    'ArrowUp',    38);
    const ARROW_DOWN  = K('ArrowDown',  'ArrowDown',  40);
    const ARROW_LEFT  = K('ArrowLeft',  'ArrowLeft',  37);
    const ARROW_RIGHT = K('ArrowRight', 'ArrowRight', 39);

    // ---- Key sets -----------------------------------------------------------
    // Each entry: { label, seq?, key?, ctrl?:bool, alt?:bool, cls?:str }
    //   seq  = raw bytes via execCommand('insertText')
    //   key  = synthetic KeyboardEvent (for arrows, Esc, Tab, Fn)
    //   ctrl = sticky Ctrl button (special)
    //   alt  = sticky Alt button (special)
    //   cls  = extra CSS class: 'mod' | 'arr' | 'util'
    const SETS = {
        zellij: {
            name: 'zellij',
            keys: [
                { label: 'ESC',  key: K('Escape', 'Escape', 27) },
                { label: 'TAB',  key: K('Tab',    'Tab',    9)  },
                { label: 'Ctrl', ctrl: true, cls: 'mod' },
                { label: 'Alt',  alt:  true, cls: 'mod' },
                { label: 'Ctrl+P', seq: '\x10', cls: 'mod' },
                { label: 'Ctrl+T', seq: '\x14', cls: 'mod' },
                { label: 'Ctrl+W', seq: '\x17', cls: 'mod' },
                { label: 'Ctrl+Q', seq: '\x11', cls: 'mod' },
                { label: 'Ctrl+C', seq: '\x03', cls: 'mod' },
                { label: 'Ctrl+D', seq: '\x04', cls: 'mod' },
                { label: '↑', cls: 'arr', key: ARROW_UP    },
                { label: '↓', cls: 'arr', key: ARROW_DOWN  },
                { label: '←', cls: 'arr', key: ARROW_LEFT  },
                { label: '→', cls: 'arr', key: ARROW_RIGHT },
            ],
        },
        vim: {
            name: 'vim',
            keys: [
                { label: 'ESC',  key: K('Escape', 'Escape', 27) },
                { label: ':',    seq: ':' },
                { label: '/',    seq: '/' },
                { label: 'Ctrl', ctrl: true, cls: 'mod' },
                { label: 'gg',   seq: 'gg' },
                { label: 'G',    seq: 'G'  },
                { label: 'dd',   seq: 'dd' },
                { label: 'yy',   seq: 'yy' },
                { label: 'p',    seq: 'p'  },
                { label: 'u',    seq: 'u'  },
                { label: '↑', cls: 'arr', key: ARROW_UP    },
                { label: '↓', cls: 'arr', key: ARROW_DOWN  },
                { label: '←', cls: 'arr', key: ARROW_LEFT  },
                { label: '→', cls: 'arr', key: ARROW_RIGHT },
            ],
        },
        fkeys: {
            name: 'fkeys',
            keys: (() => {
                const arr = [
                    { label: 'ESC',  key: K('Escape', 'Escape', 27) },
                    { label: 'Ctrl', ctrl: true, cls: 'mod' },
                    { label: 'Alt',  alt:  true, cls: 'mod' },
                ];
                for (let i = 1; i <= 12; i++) {
                    arr.push({ label: 'F' + i, cls: 'arr', key: K('F' + i, 'F' + i, 111 + i) });
                }
                return arr;
            })(),
        },
    };

    const SET_ORDER = ['zellij', 'vim', 'fkeys'];

    // ---- Modifier state -----------------------------------------------------
    // Each modifier: state ∈ { 'off', 'armed' (one-shot), 'locked' }.
    const mods = {
        ctrl: { state: 'off', btn: null },
        alt:  { state: 'off', btn: null },
    };

    function setMod(name, state) {
        mods[name].state = state;
        const btn = mods[name].btn;
        if (!btn) return;
        btn.classList.toggle('armed',  state === 'armed');
        btn.classList.toggle('locked', state === 'locked');
    }

    function cycleMod(name) {
        // tap cycles: off → armed; armed/locked → off
        const cur = mods[name].state;
        setMod(name, cur === 'off' ? 'armed' : 'off');
    }

    function lockMod(name) {
        const cur = mods[name].state;
        setMod(name, cur === 'locked' ? 'off' : 'locked');
    }

    function ctrlByteFor(ch) {
        if (!ch || ch.length !== 1) return null;
        const c = ch.toLowerCase();
        const code = c.charCodeAt(0);
        if (code >= 97 && code <= 122) return String.fromCharCode(code - 96);
        switch (c) {
            case '@': case ' ': return '\x00';
            case '[': return '\x1b';
            case '\\': return '\x1c';
            case ']': return '\x1d';
            case '^': return '\x1e';
            case '_': case '/': return '\x1f';
            case '?': return '\x7f';
        }
        return null;
    }

    function consumeModsForByte(byte) {
        let out = byte;
        if (mods.ctrl.state !== 'off') {
            const cb = ctrlByteFor(byte);
            if (cb !== null) out = cb;
            if (mods.ctrl.state === 'armed') setMod('ctrl', 'off');
        }
        if (mods.alt.state !== 'off') {
            // Alt+x in a terminal = ESC + x (meta prefix, ANSI convention).
            out = '\x1b' + out;
            if (mods.alt.state === 'armed') setMod('alt', 'off');
        }
        return out;
    }

    // ---- Input dispatch -----------------------------------------------------
    function findTA() { return document.querySelector('textarea.xterm-helper-textarea'); }

    function sendSeqRaw(seq) {
        const ta = findTA();
        if (!ta) return;
        ta.focus();
        try { document.execCommand('insertText', false, seq); return; } catch (_) {}
        try {
            ta.value += seq;
            ta.dispatchEvent(new InputEvent('input', { data: seq, inputType: 'insertText', bubbles: true }));
        } catch (_) {}
    }

    function sendSeq(seq) {
        if (mods.ctrl.state === 'off' && mods.alt.state === 'off') {
            sendSeqRaw(seq);
            return;
        }
        let out = '';
        for (const ch of seq) out += consumeModsForByte(ch);
        sendSeqRaw(out);
    }

    function sendKey(opts) {
        const ta = findTA();
        if (!ta) return;
        ta.focus();
        const init = Object.assign({ bubbles: true, cancelable: true }, opts);
        if (mods.ctrl.state !== 'off') init.ctrlKey = true;
        if (mods.alt.state  !== 'off') init.altKey  = true;
        ['keydown', 'keypress', 'keyup'].forEach(type => {
            try { ta.dispatchEvent(new KeyboardEvent(type, init)); } catch (_) {}
        });
        if (mods.ctrl.state === 'armed') setMod('ctrl', 'off');
        if (mods.alt.state  === 'armed') setMod('alt',  'off');
    }

    function installModInterceptor() {
        const ta = findTA();
        if (!ta || ta.__wovlModHooked) return;
        ta.__wovlModHooked = true;

        ta.addEventListener('beforeinput', (ev) => {
            if (mods.ctrl.state === 'off' && mods.alt.state === 'off') return;
            const data = ev.data || '';
            if (!data || data.length !== 1) {
                if (mods.ctrl.state === 'armed') setMod('ctrl', 'off');
                if (mods.alt.state  === 'armed') setMod('alt',  'off');
                return;
            }
            const transformed = consumeModsForByte(data);
            if (transformed !== data) {
                ev.preventDefault();
                ev.stopPropagation();
                sendSeqRaw(transformed);
            }
        }, true);

        ta.addEventListener('keydown', (ev) => {
            if (mods.ctrl.state === 'off' && mods.alt.state === 'off') return;
            if (['Control','Shift','Alt','Meta'].includes(ev.key)) return;
            if (ev.key && ev.key.length === 1) {
                const transformed = consumeModsForByte(ev.key);
                if (transformed !== ev.key) {
                    ev.preventDefault();
                    ev.stopPropagation();
                    sendSeqRaw(transformed);
                }
            }
        }, true);
    }

    // ---- DOM construction ---------------------------------------------------
    let currentSet = 'zellij';
    try {
        const saved = localStorage.getItem(SET_KEY);
        if (saved && SETS[saved]) currentSet = saved;
    } catch (_) {}

    function rebuildBar() {
        let bar = document.getElementById('wovl');
        if (bar) bar.remove();
        mods.ctrl.btn = null;
        mods.alt.btn  = null;

        bar = document.createElement('div');
        bar.id = 'wovl';

        // Set indicator on the left (also clickable to cycle forward)
        const ind = document.createElement('button');
        ind.type = 'button';
        ind.className = 'util ind';
        ind.textContent = '◀ ' + SETS[currentSet].name + ' ▶';
        ind.title = 'Swipe (or tap) to switch set';
        ind.addEventListener('pointerdown', (e) => { e.preventDefault(); cycleSet(+1); });
        bar.appendChild(ind);

        for (const k of SETS[currentSet].keys) {
            const btn = document.createElement('button');
            btn.type = 'button';
            btn.textContent = k.label;
            if (k.cls) btn.className = k.cls;

            if (k.ctrl) mods.ctrl.btn = btn;
            if (k.alt)  mods.alt.btn  = btn;

            // Long-press detection for sticky-mod buttons (>= 500ms = LOCK)
            let pressTimer = null;
            const LONG_MS = 500;

            const onDown = (ev) => {
                ev.preventDefault();
                ev.stopPropagation();
                if (k.ctrl || k.alt) {
                    pressTimer = setTimeout(() => {
                        pressTimer = null;
                        lockMod(k.ctrl ? 'ctrl' : 'alt');
                    }, LONG_MS);
                }
            };
            const onUp = (ev) => {
                ev.preventDefault();
                ev.stopPropagation();
                if (k.ctrl || k.alt) {
                    if (pressTimer) {
                        clearTimeout(pressTimer);
                        pressTimer = null;
                        cycleMod(k.ctrl ? 'ctrl' : 'alt');
                    }
                    return;
                }
                if ('seq' in k) sendSeq(k.seq);
                else if ('key' in k) sendKey(k.key);
            };
            const onCancel = () => { if (pressTimer) { clearTimeout(pressTimer); pressTimer = null; } };

            btn.addEventListener('pointerdown',   onDown);
            btn.addEventListener('pointerup',     onUp);
            btn.addEventListener('pointercancel', onCancel);
            btn.addEventListener('pointerleave',  onCancel);
            btn.addEventListener('click', (e) => { e.preventDefault(); });

            bar.appendChild(btn);
        }

        // Hide button at the end
        const hide = document.createElement('button');
        hide.type = 'button';
        hide.className = 'util';
        hide.textContent = 'hide ▾';
        hide.addEventListener('pointerdown', (ev) => { ev.preventDefault(); setHidden(true); });
        bar.appendChild(hide);

        // Reapply modifier visual state after rebuild
        setMod('ctrl', mods.ctrl.state);
        setMod('alt',  mods.alt.state);

        // Swipe to switch sets (anywhere on the bar except buttons)
        attachSwipe(bar);

        document.body.appendChild(bar);
        document.body.classList.add('wovl-on');
    }

    function attachSwipe(bar) {
        let startX = null, startY = null, startT = 0;
        bar.addEventListener('pointerdown', (e) => {
            if (e.target.closest('button')) { startX = null; return; }
            startX = e.clientX; startY = e.clientY; startT = Date.now();
        }, { passive: true });
        bar.addEventListener('pointerup', (e) => {
            if (startX === null) return;
            const dx = e.clientX - startX;
            const dy = e.clientY - startY;
            const dt = Date.now() - startT;
            startX = null;
            if (dt < 600 && Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy) * 1.5) {
                cycleSet(dx < 0 ? +1 : -1);
            }
        }, { passive: true });
    }

    function cycleSet(dir) {
        const i = SET_ORDER.indexOf(currentSet);
        const next = SET_ORDER[(i + dir + SET_ORDER.length) % SET_ORDER.length];
        currentSet = next;
        try { localStorage.setItem(SET_KEY, next); } catch (_) {}
        rebuildBar();
    }

    function buildShowPill() {
        const pill = document.createElement('button');
        pill.type = 'button';
        pill.id = 'wovl-show';
        pill.textContent = '⌨';
        pill.title = 'Show keyboard bar';
        pill.addEventListener('pointerdown', (ev) => { ev.preventDefault(); setHidden(false); });
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
            if (!document.getElementById('wovl')) rebuildBar();
            try { localStorage.removeItem(HIDDEN_KEY); } catch (_) {}
        }
    }

    function init() {
        let hidden = false;
        try { hidden = localStorage.getItem(HIDDEN_KEY) === '1'; } catch (_) {}
        setHidden(hidden);
        installModInterceptor();
    }

    function ready() {
        if (findTA()) { init(); return true; }
        return false;
    }

    if (!ready()) {
        const obs = new MutationObserver(() => { if (ready()) obs.disconnect(); });
        obs.observe(document.documentElement, { childList: true, subtree: true });
        setTimeout(() => {
            if (!document.getElementById('wovl') && !document.getElementById('wovl-show')) init();
        }, 8000);
    }
})();
