#!/bin/bash
# ============================================================================
# update-agents — install/update AI coding agent CLIs for the 'lab' user
# ============================================================================
# All installs land in ~/.local (persistent bind mount on the host), so:
#   * updates survive `docker compose build` / image rebuilds
#   * ~/.local/bin comes first in PATH and shadows image-baked copies
#   * no sudo, no rebuild, no downtime for the running zellij session
#
# Usage:
#   update-agents                 install/update every known agent
#   update-agents claude codex    only the named ones
#   update-agents --list          show installed versions and exit
#
# Known agents:
#   claude     Claude Code            npm @anthropic-ai/claude-code
#   codex      OpenAI Codex CLI       npm @openai/codex
#   opencode   opencode               npm opencode-ai
#   kimi       Kimi Code (Moonshot)   official installer (code.kimi.com)
#   agy        Google Antigravity     self-updater only (no official npm pkg;
#                                     the npm lookalikes are third-party/squatted)
#   kiro       kiro-cli               self-updater only (install it manually once)
# ============================================================================

set -uo pipefail

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
    BOLD=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi
ok()   { echo "  ${GREEN}✓${RESET} $*"; }
warn() { echo "  ${YELLOW}!${RESET} $*"; }
fail() { echo "  ${RED}✗${RESET} $*"; }

usage() {
    cat <<'EOF'
update-agents — install/update AI coding agent CLIs into ~/.local (persistent)

Usage:
  update-agents                 install/update every known agent
  update-agents claude codex    only the named ones
  update-agents --list          show installed versions and exit

Known agents: claude, codex, opencode, kimi, agy, kiro
EOF
}

# Globals must land in the persistent ~/.local volume, not /usr/local.
export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-$HOME/.local}"
export PATH="$HOME/.local/bin:$PATH"

# name : command : method : source
#   npm  → source is the npm package, installed/updated via npm -g
#   curl → source is the official installer URL, piped to bash
#   self → no install channel we can safely automate; use `<command> update`
AGENTS=(
    "claude|claude|npm|@anthropic-ai/claude-code"
    "codex|codex|npm|@openai/codex"
    "opencode|opencode|npm|opencode-ai"
    "kimi|kimi|curl|https://code.kimi.com/kimi-code/install.sh"
    "agy|agy|self|"
    "kiro|kiro-cli|self|"
)
KNOWN="claude codex opencode kimi agy kiro"

version_of() { "$1" --version 2>/dev/null | head -n1; }

list_all() {
    for entry in "${AGENTS[@]}"; do
        IFS='|' read -r name cmd method src <<< "$entry"
        if command -v "$cmd" >/dev/null 2>&1; then
            ok "${BOLD}${name}${RESET}  $(version_of "$cmd" || echo '?')  ($(command -v "$cmd"))"
        elif [[ "$method" == "self" ]]; then
            warn "${name}  not installed  (no automated channel — install manually once)"
        else
            warn "${name}  not installed  (install with: update-agents ${name})"
        fi
    done
}

update_agent() {
    local name="$1" entry n cmd="" method="" src="" found=""
    for entry in "${AGENTS[@]}"; do
        IFS='|' read -r n cmd method src <<< "$entry"
        [[ "$n" == "$name" ]] && { found=1; break; }
    done
    if [[ -z "$found" ]]; then
        fail "Unknown agent '${name}'. Known: ${KNOWN}"
        return 1
    fi

    local before after
    before=$(version_of "$cmd" || true)

    case "$method" in
    npm)
        echo "${BOLD}→ ${name}${RESET}  (npm ${src})"
        if npm install -g "${src}@latest" --no-fund --no-audit; then
            hash -r
            after=$(version_of "$cmd" || true)
            if [[ -n "$before" && "$before" == "$after" ]]; then
                ok "${name} already up to date (${after})"
            else
                ok "${name}: ${before:-not installed} → ${after:-?}"
            fi
        else
            fail "npm install failed for ${src}"
            return 1
        fi
        ;;
    curl)
        echo "${BOLD}→ ${name}${RESET}  (official installer: ${src})"
        if curl -fsSL "$src" | bash; then
            hash -r
            after=$(version_of "$cmd" || true)
            if [[ -n "$before" && "$before" == "$after" ]]; then
                ok "${name} already up to date (${after})"
            else
                ok "${name}: ${before:-not installed} → ${after:-?}"
            fi
        else
            fail "installer failed for ${name}"
            return 1
        fi
        ;;
    self)
        # No install channel we can safely automate (e.g. agy has no official
        # npm package — only third-party/squatted lookalikes). Use the tool's
        # own self-updater once it's installed.
        if command -v "$cmd" >/dev/null 2>&1; then
            echo "${BOLD}→ ${name}${RESET}  (${cmd} self-updater)"
            if "$cmd" update; then
                ok "${name}: $(version_of "$cmd" || echo '?')"
            else
                warn "'${cmd} update' failed or is unsupported — update it the way you installed it."
            fi
        else
            warn "${name} (${cmd}) not installed — install it once manually (into ~/.local/bin so it persists); afterwards this script can self-update it."
        fi
        ;;
    esac
}

case "${1:-}" in
    --list|-l) list_all; exit 0 ;;
    --help|-h) usage; exit 0 ;;
esac

targets=("$@")
[[ ${#targets[@]} -eq 0 ]] && targets=(claude codex opencode kimi agy kiro)

rc=0
for t in "${targets[@]}"; do
    update_agent "$t" || rc=1
    echo ""
done
exit $rc
