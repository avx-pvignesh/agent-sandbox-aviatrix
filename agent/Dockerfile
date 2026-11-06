# Sample agent image: claude -p inside a Kata/Firecracker microVM.
# Bake every dependency here (setup phase). Attack-phase runs fetch nothing.
FROM node:22-bookworm-slim@sha256:de170b39439eb0e5a3444ad7d60b015614a381e10fecae2e30ec9e735122f38d
# pin CLAUDE_CODE_VERSION to an exact version for reproducibility
ARG CLAUDE_CODE_VERSION=2.1.308
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq python3 python3-pip procps iproute2 \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    && npm cache clean --force \
    && useradd -m -u 10010 agent
USER agent
WORKDIR /home/agent/work
# No credential, no mounts of ~/.aws ~/.ssh .env. All config arrives as env at launch.
ENTRYPOINT ["/bin/bash", "-lc"]
CMD ["claude -p \"$(cat /task/task.md)\" --max-turns ${MAX_TURNS:-30} --permission-mode ${CLAUDE_PERMISSION_MODE:-auto} --output-format stream-json --verbose"]
