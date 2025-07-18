#######
# PHP #
#######
ARG PHP_VERSION=8.3
ARG VERSION=1.0.0

FROM php:${PHP_VERSION}-fpm-alpine AS php-build

# docker-entrypoint.sh dependencies
RUN apk add --no-cache \
    bash \
    tzdata

# Add PHP extension installer
ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/

# Install additionally required php extensions
RUN chmod +x /usr/local/bin/install-php-extensions && \
    install-php-extensions \
        apcu \
        exif \
        gd \
        imagick \
        intl \
        opcache \
        pdo_mysql \
        xdebug \
        zip

LABEL org.opencontainers.image.title="Webtrees docker image" \
      org.opencontainers.image.description="Run webtrees with Alpine, Nginx and PHP FPM." \
      org.opencontainers.image.authors="Rico Sonntag <mail@ricosonntag.de>" \
      org.opencontainers.image.vendor="Rico Sonntag" \
      org.opencontainers.image.documentation="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.url="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.source="https://github.com/magicsunday/webtrees-docker.git"

# Copy our custom configuration files
COPY rootfs/usr/local/etc/php/conf.d $PHP_INI_DIR/conf.d

COPY rootfs/docker-entrypoint.sh /docker-entrypoint.sh

# Set proper permissions for entrypoint
RUN chmod +x /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["php-fpm"]


############
# BUILDBOX #
############
FROM php-build AS build-box

ARG PHP_VERSION
ARG DOCKER_SERVER

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
        nodejs \
        npm \
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

# Set executable permissions for all entrypoint scripts
RUN chmod +x /docker-entrypoint.sh && \
    chmod +x /opt/root-entrypoint.sh && \
    chmod +x /opt/user-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh", "/opt/user-entrypoint.sh"]
