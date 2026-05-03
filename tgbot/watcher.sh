#!/usr/bin/env bash
# ============================================================================
# Proactive alert watcher — runs in background alongside bot.sh.
# Sends Telegram messages when something is wrong, plus a periodic heartbeat.
# ============================================================================
set -uo pipefail

: "${TELEGRAM_BOT_TOKEN:?}"
: "${TELEGRAM_CHAT_ID:?}"
GLANCES_URL="${GLANCES_URL:-http://glances:61208}"
API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

# Tunables (all overridable via env). 0 disables that watcher.
ALERT_DISK_PCT="${ALERT_DISK_PCT:-85}"     # filesystem usage threshold
ALERT_MEM_PCT="${ALERT_MEM_PCT:-90}"       # RAM usage threshold
ALERT_LOAD="${ALERT_LOAD:-0}"              # 1-min load avg (0 = off)
HEARTBEAT_HOURS="${HEARTBEAT_HOURS:-3}"    # 0 = no heartbeat
ALERT_SSH="${ALERT_SSH:-1}"                # 1 = tail /var/log/auth.log if mounted
ALERT_AUTHELIA="${ALERT_AUTHELIA:-1}"      # 1 = stream authelia logs via dockerproxy
DOCKER_HOST="${DOCKER_HOST:-tcp://dockerproxy:2375}"
WATCH_INTERVAL="${WATCH_INTERVAL:-60}"     # seconds between resource checks
ALERT_COOLDOWN="${ALERT_COOLDOWN:-3600}"   # seconds between repeats of same alert

STATE_DIR="${STATE_DIR:-/tmp/tgbot}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
MUTE_FILE="${STATE_DIR}/mute_until"

log() { printf '%s [watcher] %s\n' "$(date -u +%FT%TZ)" "$*"; }

send() {
    local text="$1"
    # Honour the mute file written by bot.sh /mute command.
    if [[ -f "$MUTE_FILE" ]]; then
        local until_ts now_ts
        until_ts=$(cat "$MUTE_FILE" 2>/dev/null || echo 0)
        now_ts=$(date +%s)
        if (( now_ts < until_ts )); then
            log "muted until $(date -d "@$until_ts" -u +%FT%TZ 2>/dev/null || echo "$until_ts"); dropping alert"
            return 0
        fi
    fi
    curl -fsS --max-time 10 -X POST "${API}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "parse_mode=Markdown" >/dev/null 2>&1 || \
    curl -fsS --max-time 10 -X POST "${API}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${text}" >/dev/null 2>&1 || \
    log "send failed"
}

# Cooldown: returns 0 if the alert key has not fired within $ALERT_COOLDOWN.
should_fire() {
    local key="$1"
    local f="${STATE_DIR}/last_${key}"
    local now last
    now=$(date +%s)
    last=$(cat "$f" 2>/dev/null || echo 0)
    if (( now - last >= ALERT_COOLDOWN )); then
        echo "$now" > "$f"
        return 0
    fi
    return 1
}

glances() {
    curl -fsS --max-time 5 "${GLANCES_URL}/api/4/$1" 2>/dev/null || true
}

# --- Watcher: filesystems ----------------------------------------------------
watch_disks() {
    (( ALERT_DISK_PCT > 0 )) || return 0
    local fs offenders
    fs=$(glances fs)
    [[ -z "$fs" ]] && return 0
    offenders=$(jq -r --argjson t "$ALERT_DISK_PCT" \
        '.[] | select(.percent >= $t) | "\(.mnt_point) \(.percent)%"' <<<"$fs" 2>/dev/null)
    [[ -z "$offenders" ]] && return 0
    if should_fire "disk"; then
        send "🔴 *Disk usage high* (>= ${ALERT_DISK_PCT}%)
\`\`\`
${offenders}
\`\`\`"
    fi
}

# --- Watcher: memory ---------------------------------------------------------
watch_mem() {
    (( ALERT_MEM_PCT > 0 )) || return 0
    local pct
    pct=$(glances mem | jq -r '.percent // empty' 2>/dev/null)
    [[ -z "$pct" ]] && return 0
    # bash doesn't do floats; integer-compare on the floor.
    local pct_int="${pct%.*}"
    [[ -z "$pct_int" ]] && pct_int=0
    if (( pct_int >= ALERT_MEM_PCT )); then
        if should_fire "mem"; then
            send "🟠 *Memory high*: ${pct}% (threshold ${ALERT_MEM_PCT}%)"
        fi
    fi
}

# --- Watcher: load -----------------------------------------------------------
watch_load() {
    (( ALERT_LOAD > 0 )) || return 0
    local m1
    m1=$(glances load | jq -r '.min1 // empty' 2>/dev/null)
    [[ -z "$m1" ]] && return 0
    local m1_int="${m1%.*}"
    [[ -z "$m1_int" ]] && m1_int=0
    if (( m1_int >= ALERT_LOAD )); then
        if should_fire "load"; then
            send "🟡 *Load high*: 1m=${m1} (threshold ${ALERT_LOAD})"
        fi
    fi
}

# --- Watcher: SSH logins -----------------------------------------------------
# Tails /var/log/auth.log (Debian/Ubuntu) and alerts on Accepted lines.
# Requires the host's /var/log to be bind-mounted read-only into the container.
ssh_tail() {
    [[ "$ALERT_SSH" == "1" ]] || return 0
    local AUTHLOG=/var/log/auth.log
    if [[ ! -r "$AUTHLOG" ]]; then
        log "auth.log not readable; skipping SSH login alerts"
        return 0
    fi
    log "tailing $AUTHLOG for SSH logins"
    # --pid=$$ keeps tail tied to this script's lifetime.
    tail -F -n0 --pid=$$ "$AUTHLOG" 2>/dev/null | \
    while IFS= read -r line; do
        # Examples:
        #   sshd[1234]: Accepted publickey for alice from 1.2.3.4 port 5555 ssh2
        #   sshd[1234]: Accepted password for alice from 1.2.3.4 port 5555 ssh2
        if [[ "$line" =~ sshd.*Accepted\ ([a-z]+)\ for\ ([^ ]+)\ from\ ([0-9a-fA-F:.]+)\ port\ ([0-9]+) ]]; then
            local method="${BASH_REMATCH[1]}"
            local user="${BASH_REMATCH[2]}"
            local ip="${BASH_REMATCH[3]}"
            local port="${BASH_REMATCH[4]}"
            send "🔑 *SSH login* on \`$(hostname)\`
user: \`${user}\`
from: \`${ip}\`:${port}
method: ${method}"
        fi
    done &
}

# --- Watcher: Authelia web logins -------------------------------------------
# Streams the authelia container's stdout/stderr through dockerproxy (LOGS=1)
# and alerts on successful 1FA / 2FA authentication events. No socket mount
# required: tgbot only ever sees the proxied, read-only Docker API.
authelia_tail() {
    [[ "$ALERT_AUTHELIA" == "1" ]] || return 0
    local host="${DOCKER_HOST#tcp://}"
    local url="http://${host}/containers/authelia/logs?follow=1&stdout=1&stderr=1&tail=0&timestamps=0"
    log "tailing authelia logs via ${host}"
    (
        # The Docker logs stream is multiplexed binary frames (8-byte header
        # then payload). Strip non-printables with `tr` so jq/grep see clean
        # text. Auto-reconnect on disconnect.
        while :; do
            curl -fsSN --max-time 0 "$url" 2>/dev/null \
                | while IFS= read -r line; do
                    [[ -z "$line" ]] && continue

                    # Extract fields from logfmt or JSON.
                    msg=""; user=""; ip=""; path=""; level=""
                    if printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
                        msg=$(jq -r '.msg // .message // empty'   <<<"$line")
                        user=$(jq -r '.username // .user // empty' <<<"$line")
                        ip=$(jq -r '.remote_ip // .ip // empty'    <<<"$line")
                        path=$(jq -r '.path // empty'              <<<"$line")
                        level=$(jq -r '.level // empty'            <<<"$line")
                    else
                        msg=$(sed -n   's/.*msg="\([^"]*\)".*/\1/p'        <<<"$line")
                        user=$(sed -n  "s/.*user '\([^']*\)'.*/\1/p"       <<<"$line")
                        [[ -z "$user" ]] && user=$(sed -n 's/.*to user \([^ ,]*\).*/\1/p' <<<"$line")
                        ip=$(sed -n    's/.* remote_ip=\([^ ]*\).*/\1/p'   <<<"$line")
                        path=$(sed -n  's/.* path=\([^ ]*\).*/\1/p'        <<<"$line")
                        level=$(sed -n 's/.* level=\([^ ]*\).*/\1/p'       <<<"$line")
                    fi
                    [[ -z "$msg" ]] && continue

                    # Uncomment to debug pattern matching:
                    # log "authelia: level='$level' path='$path' user='$user' ip='$ip' msg='$msg'"

                    # Failures (TOTP / 1FA) — both surface as "Unsuccessful ..."
                    case "$msg" in
                        *Unsuccessful*|*authentication\ attempt*ail*|*nvalid\ credentials*|*ncorrect\ password*)
                            if should_fire "authelia_fail"; then
                                send "⚠️ *Authelia login failed*
user: \`${user:-?}\`  from: \`${ip:-?}\`
reason: ${msg}
(further failures muted for ${ALERT_COOLDOWN}s)"
                            fi
                            continue
                            ;;
                    esac

                    # 1FA success: password was correct, user now needs 2FA.
                    # Authelia logs: "<url> requires 2FA, cannot be redirected yet"
                    if [[ "$msg" == *"requires 2FA"* ]]; then
                        if should_fire "authelia_1fa_${user:-x}_${ip:-x}"; then
                            send "🔓 *Authelia 1FA ok* (password)
user: \`${user:-?}\`
from: \`${ip:-?}\`"
                        fi
                        continue
                    fi

                    # 2FA success: a successful POST to /api/secondfactor/* at
                    # info level with no "Unsuccessful" earlier in the line.
                    if [[ "$path" == /api/secondfactor/* && "$level" == "info" ]]; then
                        if should_fire "authelia_2fa_${user:-x}_${ip:-x}"; then
                            send "🔐 *Authelia 2FA ok*
user: \`${user:-?}\`
from: \`${ip:-?}\`"
                        fi
                        continue
                    fi
                done
            log "authelia log stream ended; reconnecting in 10s"
            sleep 10
        done
    ) &
}

# --- Watcher: heartbeat ------------------------------------------------------
heartbeat_loop() {
    (( HEARTBEAT_HOURS > 0 )) || return 0
    log "heartbeat every ${HEARTBEAT_HOURS}h"
    while :; do
        sleep $((HEARTBEAT_HOURS * 3600))
        local cpu mem disk up
        cpu=$(glances cpu | jq -r '.total // "?"' 2>/dev/null)
        mem=$(glances mem | jq -r '.percent // "?"' 2>/dev/null)
        disk=$(glances fs | jq -r 'map(.percent) | max // "?"' 2>/dev/null)
        up=$(glances uptime | jq -r '. // "?"' 2>/dev/null)
        send "💚 *heartbeat* — all good
CPU ${cpu}%  ·  RAM ${mem}%  ·  disk ${disk}%
uptime: ${up}"
    done &
}

# --- Resource polling loop ---------------------------------------------------
poll_loop() {
    while :; do
        watch_disks
        watch_mem
        watch_load
        sleep "$WATCH_INTERVAL"
    done &
}

# --- Main --------------------------------------------------------------------
log "watcher starting (disk>=${ALERT_DISK_PCT}% mem>=${ALERT_MEM_PCT}% load>=${ALERT_LOAD} hb=${HEARTBEAT_HOURS}h ssh=${ALERT_SSH} authelia=${ALERT_AUTHELIA})"
ssh_tail
authelia_tail
heartbeat_loop
poll_loop
wait
