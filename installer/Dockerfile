# syntax=docker/dockerfile:1.7

FROM python:3.12-alpine AS installer

LABEL org.opencontainers.image.source="https://github.com/magicsunday/webtrees-docker"
LABEL org.opencontainers.image.description="Wizard for setting up a self-hosted webtrees stack"
LABEL org.opencontainers.image.licenses="MIT"

# docker CLI client is required so the wizard can invoke `docker compose up`
# and port-conflict probes from inside the container. docker-cli-compose
# provides the v2 compose subcommand.
RUN apk add --no-cache docker-cli docker-cli-compose

WORKDIR /opt/installer

COPY pyproject.toml README.md LICENSE ./
COPY webtrees_installer ./webtrees_installer

RUN pip install --no-cache-dir .

# Mount points the wizard expects at runtime. /work is the user's host
# directory where compose.yaml + .env get written; /var/run/docker.sock is
# the daemon endpoint the embedded docker CLI talks to.
VOLUME ["/work"]
WORKDIR /work

ENTRYPOINT ["python", "-m", "webtrees_installer"]
