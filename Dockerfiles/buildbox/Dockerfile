ARG PHP_VERSION
ARG DOCKER_SERVER

FROM ${DOCKER_SERVER}/webtrees/php:${PHP_VERSION}

ENV COMPOSER_ALLOW_SUPERUSER=1

RUN apk --no-cache --update upgrade

# Installing required extensions
RUN set -e && \
    apk add --no-cache \
        bash \
        build-base \
        ca-certificates \
        curl \
        dcron \
        findutils \
        git \
        make \
        mysql-client \
        nano \
        openssl \
        shadow \
        ssmtp \
        sudo \
        zip

# Install composer
COPY --from=composer:latest /usr/bin/composer /usr/local/bin/composer

# Clean up
RUN set -ex && \
    rm -rf /usr/src/* && \
    rm -rf /tmp/* && \
    rm -rf /var/tmp/* && \
    for logs in `find /var/log -type f`; do > $logs; done && \
    rm -rf /usr/share/locale/* && \
    rm -rf /usr/share/man/* && \
    rm -rf /usr/share/doc/*

COPY rootfs/ /

RUN chmod +x /docker-entrypoint.sh
RUN chmod +x /opt/root-entrypoint.sh
RUN chmod +x /opt/entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh", "/opt/entrypoint.sh"]
