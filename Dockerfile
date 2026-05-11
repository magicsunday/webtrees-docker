#######
# PHP #
#######
ARG PHP_VERSION=8.3
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown

FROM php:${PHP_VERSION}-fpm-alpine AS php-build

# Re-declare ARGs inside the stage so they are in scope for LABEL instructions.
# ARGs declared before the first FROM are only valid in the FROM line itself.
ARG PHP_VERSION
ARG VCS_REF
ARG BUILD_DATE

# docker-entrypoint.sh dependencies
RUN apk update && \
    apk upgrade --no-cache && \
    apk add --no-cache \
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
        zip

LABEL org.opencontainers.image.title="Webtrees PHP-FPM" \
      org.opencontainers.image.description="PHP-FPM runtime for the webtrees genealogy application." \
      org.opencontainers.image.authors="Rico Sonntag <mail@ricosonntag.de>" \
      org.opencontainers.image.vendor="Rico Sonntag" \
      org.opencontainers.image.documentation="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${PHP_VERSION}" \
      org.opencontainers.image.url="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.source="https://github.com/magicsunday/webtrees-docker.git" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.base.name="php:${PHP_VERSION}-fpm-alpine" \
      org.opencontainers.image.ref.name="webtrees/php:${PHP_VERSION}"

# Copy our custom configuration files
COPY rootfs/usr/local/etc/php/conf.d/*.ini $PHP_INI_DIR/conf.d/

# Entrypoint
COPY rootfs/docker-entrypoint.sh /docker-entrypoint.sh

# Set proper permissions for entrypoint
RUN chmod +x /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["php-fpm"]


############
# BUILDBOX #
############
FROM php-build AS build-box

# Re-declare ARGs (same reason as in php-build stage).
ARG PHP_VERSION
ARG VCS_REF
ARG BUILD_DATE
ARG DOCKER_SERVER

ENV COMPOSER_ALLOW_SUPERUSER=1

# Install xdebug (development only) and clean up the extension installer
RUN install-php-extensions xdebug && \
    rm -f /usr/local/bin/install-php-extensions

# Installing required extensions
RUN apk add --no-cache \
        acl \
        bash \
        ca-certificates \
        curl \
        dcron \
        findutils \
        git \
        github-cli \
        jq \
        make \
        ncurses \
        mariadb-client \
        nano \
        nodejs \
        npm \
        openssl \
        openssh \
        shadow \
        sudo \
        zip

# Install composer
COPY --from=composer:latest /usr/bin/composer /usr/local/bin/composer

# Clean up
RUN rm -rf /tmp/* /var/tmp/* && \
    rm -rf /usr/src/* /usr/include/* /usr/lib/*.a && \
    rm -rf /usr/share/doc /usr/share/man /usr/share/info

COPY rootfs/ /

# Set executable permissions for all entrypoint scripts
RUN chmod +x /docker-entrypoint.sh /opt/root-entrypoint.sh /opt/user-entrypoint.sh

LABEL org.opencontainers.image.title="Webtrees Buildbox" \
      org.opencontainers.image.description="Development environment for webtrees with Composer, Node.js, Git and xdebug." \
      org.opencontainers.image.authors="Rico Sonntag <mail@ricosonntag.de>" \
      org.opencontainers.image.vendor="Rico Sonntag" \
      org.opencontainers.image.documentation="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${PHP_VERSION}" \
      org.opencontainers.image.url="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.source="https://github.com/magicsunday/webtrees-docker.git" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.base.name="${DOCKER_SERVER}/webtrees/php:${PHP_VERSION}" \
      org.opencontainers.image.ref.name="webtrees/buildbox:${PHP_VERSION}"

ENTRYPOINT ["/docker-entrypoint.sh", "/opt/user-entrypoint.sh"]
