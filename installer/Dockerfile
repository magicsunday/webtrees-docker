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

COPY installer/pyproject.toml installer/README.md installer/LICENSE ./
COPY installer/webtrees_installer ./webtrees_installer
COPY dev/versions.json dev/nginx-version.json dev/installer-version.json ./versions/

RUN pip install --no-cache-dir .

ENV WEBTREES_INSTALLER_MANIFEST_DIR=/opt/installer/versions

VOLUME ["/work"]
WORKDIR /work

ENTRYPOINT ["python", "-m", "webtrees_installer"]
