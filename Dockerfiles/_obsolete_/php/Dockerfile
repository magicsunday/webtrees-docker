ARG PHP_VERSION=8.3
ARG VERSION=1.0.0

FROM php:${PHP_VERSION}-fpm-alpine AS php

# docker-entrypoint.sh dependencies
RUN apk add --no-cache \
    bash \
    tzdata

ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/

# Install additionally required php extensions
RUN chmod +x /usr/local/bin/install-php-extensions
RUN install-php-extensions exif
RUN install-php-extensions gd
RUN install-php-extensions imagick
RUN install-php-extensions intl
RUN install-php-extensions opcache
RUN install-php-extensions pdo_mysql
RUN install-php-extensions xdebug
RUN install-php-extensions zip

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
RUN chmod +x /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["php-fpm"]
