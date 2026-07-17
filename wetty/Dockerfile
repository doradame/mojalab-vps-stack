# ============================================================================
# wetty wrapper image — drops a tolerant SSH client config so the wetty user
# can ssh into the zellij sidecar without manual host-key acceptance.
# ============================================================================
# wetty publishes no current version tags (semver stops at 3.0.0, 'latest'
# tracks main), so we pin by digest. To update:
#   curl -fsS https://hub.docker.com/v2/repositories/wettyoss/wetty/tags/latest | jq -r .digest
FROM wettyoss/wetty:latest@sha256:7423b3d40ba25521105bb2796a0de903fd52dee6c20f6983b5ae145e29131aa9

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
