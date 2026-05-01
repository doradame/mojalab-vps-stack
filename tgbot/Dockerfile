# ============================================================================
# Telegram bot for mojalab — answers /stats, /df, /uptime, /help by querying
# the Glances REST API on the lab network.
# ============================================================================
FROM alpine:3.20

RUN apk add --no-cache bash curl jq coreutils ca-certificates tzdata bc

RUN adduser -D -u 1000 bot
USER bot
WORKDIR /home/bot

COPY --chown=bot:bot bot.sh /home/bot/bot.sh
COPY --chown=bot:bot watcher.sh /home/bot/watcher.sh
RUN chmod +x /home/bot/bot.sh /home/bot/watcher.sh

ENTRYPOINT ["/home/bot/bot.sh"]
