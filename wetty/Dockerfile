# ============================================================================
# wetty wrapper image — drops a tolerant SSH client config so the wetty user
# can ssh into the zellij sidecar without manual host-key acceptance.
# ============================================================================
FROM wettyoss/wetty:latest

USER root

# Pre-seed an SSH config that disables strict host key checking. This is safe
# because wetty only ever reaches the zellij container over Docker's internal
# 'lab' bridge network; no traffic crosses the host boundary.
RUN mkdir -p /home/node/.ssh \
    && printf 'Host *\n    StrictHostKeyChecking no\n    UserKnownHostsFile /dev/null\n    LogLevel ERROR\n    ServerAliveInterval 30\n' \
       > /home/node/.ssh/config \
    && chown -R node:node /home/node/.ssh \
    && chmod 700 /home/node/.ssh \
    && chmod 600 /home/node/.ssh/config

USER node
