#!/usr/bin/env bash
# ============================================================================
# Tiny Telegram bot — long-polls getUpdates, answers a handful of commands
# with Glances data. Single-user: only TELEGRAM_CHAT_ID is allowed to talk.
# ============================================================================
set -euo pipefail

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is required}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is required}"
GLANCES_URL="${GLANCES_URL:-http://glances:61208}"
API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

STATE_DIR="${STATE_DIR:-/tmp/tgbot}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
MUTE_FILE="${STATE_DIR}/mute_until"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

# --- Telegram helpers --------------------------------------------------------
send() {
    local chat_id="$1" text="$2"
    curl -fsS -X POST "${API}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "parse_mode=Markdown" >/dev/null || \
    curl -fsS -X POST "${API}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${text}" >/dev/null || true
}

# --- Glances queries ---------------------------------------------------------
glances() {
    # glances <endpoint>  ->  raw JSON, or empty on failure
    curl -fsS --max-time 5 "${GLANCES_URL}/api/4/$1" 2>/dev/null || true
}

cmd_help() {
    cat <<'EOF'
*mojalab bot* — available commands:
/stats    CPU, RAM, swap, load, uptime
/df       disk usage per filesystem
/uptime   uptime + load averages
/ping     is the bot alive?
/alerts   show alert thresholds
/mute N   silence proactive alerts for N minutes (default 60)
/resume   un-mute alerts
/help     this message
EOF
}

cmd_ping() { echo "pong 🏓 ($(date -u +%FT%TZ))"; }

cmd_stats() {
    local cpu mem swap load up
    cpu=$(glances cpu | jq -r '.total // empty' 2>/dev/null)
    mem=$(glances mem)
    swap=$(glances memswap | jq -r '.percent // empty' 2>/dev/null)
    load=$(glances load | jq -r '"\(.min1) \(.min5) \(.min15)"' 2>/dev/null)
    up=$(glances uptime | jq -r '. // empty' 2>/dev/null)

    local mem_pct mem_used mem_total
    mem_pct=$(jq -r '.percent // empty'             <<<"$mem")
    mem_used=$(jq -r '(.used // 0)/1024/1024/1024 | (.*100|round)/100' <<<"$mem")
    mem_total=$(jq -r '(.total // 0)/1024/1024/1024 | (.*100|round)/100' <<<"$mem")

    cat <<EOF
*📊 mojalab stats*

🖥  CPU      : ${cpu:-?}%
🧠  RAM      : ${mem_pct:-?}%   (${mem_used:-?} / ${mem_total:-?} GiB)
💱  Swap     : ${swap:-?}%
⚖️  Load     : ${load:-?}
⏱  Uptime   : ${up:-?}
EOF
}

cmd_df() {
    local fs
    fs=$(glances fs)
    [[ -z "$fs" ]] && { echo "Glances unreachable."; return; }
    {
        echo '*💾 disks*'
        echo '```'
        printf '%-20s %6s %6s %6s\n' MOUNT USED FREE PCT
        jq -r '.[] | [.mnt_point, (.used/1024/1024/1024|floor|tostring+"G"), ((.size-.used)/1024/1024/1024|floor|tostring+"G"), (.percent|tostring+"%")] | @tsv' <<<"$fs" \
            | awk -F'\t' '{ printf "%-20s %6s %6s %6s\n", $1,$2,$3,$4 }'
        echo '```'
    }
}

cmd_uptime() {
    local up load
    up=$(glances uptime | jq -r '. // empty')
    load=$(glances load | jq -r '"\(.min1)  \(.min5)  \(.min15)"')
    printf '⏱ uptime: %s\n⚖️ load:   %s\n' "${up:-?}" "${load:-?}"
}

cmd_alerts() {
    local mute_status="off"
    if [[ -f "$MUTE_FILE" ]]; then
        local until_ts now_ts
        until_ts=$(cat "$MUTE_FILE" 2>/dev/null || echo 0)
        now_ts=$(date +%s)
        if (( now_ts < until_ts )); then
            mute_status="muted for $(( (until_ts - now_ts) / 60 )) more min"
        fi
    fi
    cat <<EOF
*🔔 alert configuration*
disk threshold : ${ALERT_DISK_PCT:-85}%
mem threshold  : ${ALERT_MEM_PCT:-90}%
load threshold : ${ALERT_LOAD:-0} (0=off)
heartbeat      : every ${HEARTBEAT_HOURS:-3}h (0=off)
SSH logins     : ${ALERT_SSH:-1} (1=on)
Authelia       : ${ALERT_AUTHELIA:-1} (1=on)
cooldown       : ${ALERT_COOLDOWN:-3600}s
status         : ${mute_status}
EOF
}

cmd_mute() {
    local mins="${1:-60}"
    if [[ ! "$mins" =~ ^[0-9]+$ ]] || (( mins < 1 )); then
        echo "Usage: /mute <minutes>"; return
    fi
    local until_ts=$(( $(date +%s) + mins * 60 ))
    echo "$until_ts" > "$MUTE_FILE"
    echo "🔕 alerts muted for ${mins} minutes"
}

cmd_resume() {
    rm -f "$MUTE_FILE"
    echo "🔔 alerts resumed"
}

dispatch() {
    local text="$1"
    # Strip a possible @botname suffix and arguments.
    local cmd="${text%% *}"
    cmd="${cmd%@*}"
    local arg=""
    [[ "$text" == *" "* ]] && arg="${text#* }"
    case "$cmd" in
        /start|/help)  cmd_help     ;;
        /ping)         cmd_ping     ;;
        /stats)        cmd_stats    ;;
        /df)           cmd_df       ;;
        /uptime)       cmd_uptime   ;;
        /alerts)       cmd_alerts   ;;
        /mute)         cmd_mute "$arg" ;;
        /resume|/unmute) cmd_resume ;;
        *)             printf 'Unknown command: %s\nType /help for the list.\n' "$cmd" ;;
    esac
}

# --- Main loop ---------------------------------------------------------------
log "Bot starting. Authorized chat_id=${TELEGRAM_CHAT_ID}, glances=${GLANCES_URL}"
send "${TELEGRAM_CHAT_ID}" "🐸 mojalab bot online. /help for commands."

# Start the proactive watcher (disk/mem/load/heartbeat/SSH alerts).
if [[ -x /home/bot/watcher.sh ]]; then
    /home/bot/watcher.sh &
    WATCHER_PID=$!
    log "watcher started pid=${WATCHER_PID}"
    trap 'kill ${WATCHER_PID} 2>/dev/null || true' EXIT
fi

offset=0
while :; do
    resp=$(curl -fsS --max-time 65 "${API}/getUpdates?timeout=60&offset=${offset}" 2>/dev/null || true)
    if [[ -z "$resp" ]] || ! jq -e '.ok' <<<"$resp" >/dev/null 2>&1; then
        log "getUpdates failed; retrying in 5s"
        sleep 5
        continue
    fi

    while IFS= read -r upd; do
        [[ -z "$upd" ]] && continue
        update_id=$(jq -r '.update_id' <<<"$upd")
        offset=$((update_id + 1))
        chat_id=$(jq -r '.message.chat.id // empty' <<<"$upd")
        text=$(jq -r '.message.text // empty' <<<"$upd")
        [[ -z "$chat_id" || -z "$text" ]] && continue

        if [[ "$chat_id" != "$TELEGRAM_CHAT_ID" ]]; then
            log "Ignoring message from unauthorized chat_id=${chat_id}"
            send "$chat_id" "Not authorized."
            continue
        fi

        log "cmd: ${text}"
        reply=$(dispatch "$text")
        send "$chat_id" "$reply"
    done < <(jq -c '.result[]?' <<<"$resp")
done
