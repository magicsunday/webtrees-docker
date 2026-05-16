####################
# WEBTREES BUILD   #
####################
# Throwaway stage that composer-installs webtrees from setup/composer-core.json,
# applies the upgrade-lock patch via cweagans/composer-patches, and prepares
# the public/ + html→public layout the entrypoint copies into /var/www.
ARG PHP_VERSION=8.3
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
ARG WEBTREES_VERSION=2.2.6

# Major-pin: `composer:2` auto-rolls within the 2.x line so patch and
# minor bumps land without a manual update. A stricter pin would block
# them; loosening to `composer:latest` would let a 3.x release land
# silently and break this build.
FROM composer:2 AS webtrees-build

# pipefail catches `find … | grep -q .` failures in the RUN below; without
# it, a broken find with empty output would let the negated grep guard
# silently pass and ship an unintended file layout.
SHELL ["/bin/ash", "-o", "pipefail", "-c"]

# Re-declare with a default so an empty --build-arg from compose does not
# collapse the JSON values when composer reads them.
ARG WEBTREES_VERSION=2.2.6
ARG PHP_VERSION=8.3

WORKDIR /build

# Copy the same setup files the dev install consumes: the composer manifest,
# the patches directory referenced from composer.json's extra.patches, and
# the front-controller wrapper that bootstraps webtrees from vendor/.
COPY setup/composer-core.json /build/composer.json
COPY setup/patches /build/patches
COPY setup/public /build/public

# SC2016: the later `grep -q 'merge($this->vendorModules())'` quotes the
# literal PHP expression — `$this` must NOT be shell-expanded. False
# positive; suppress.
# hadolint ignore=SC2016
RUN [ -n "${WEBTREES_VERSION}" ] || { echo "WEBTREES_VERSION cannot be empty" >&2; exit 1; } \
 # Pin fisharebest/webtrees to the exact version this image bundles.
 # setup/composer-core.json carries a "~2.2.0" range for the dev bootstrap; the
 # image must lock to one version so the OCI label and the on-disk install
 # cannot drift.
 && sed -i "s|\"fisharebest/webtrees\": \"[^\"]*\"|\"fisharebest/webtrees\": \"${WEBTREES_VERSION}\"|" composer.json \
 # Pin composer's resolution platform to the target image's PHP version.
 # The composer:2 image ships whatever PHP version Alpine packages (currently
 # 8.5.x); without an explicit platform, composer resolves transitive deps
 # against that latest version and bakes a `>= 8.5` platform-check into
 # vendor/composer/platform_check.php — which then refuses to load at runtime
 # on the php:${PHP_VERSION}-fpm-alpine image (HTTP 500 before webtrees ever
 # starts). The pin makes resolution match the deployment target.
 && composer config platform.php "${PHP_VERSION}.0" \
 # --ignore-platform-req=ext-*: the composer:2 image lacks the PHP extensions
 # webtrees needs (gd, intl, exif, ...). The php-base stage installs them;
 # we only need composer to resolve and unpack here.
 && composer install \
        --no-dev \
        --no-scripts \
        --no-progress \
        --no-interaction \
        --classmap-authoritative \
        --prefer-dist \
        --ignore-platform-req=ext-gd \
        --ignore-platform-req=ext-intl \
        --ignore-platform-req=ext-exif \
        --ignore-platform-req=ext-imagick \
        --ignore-platform-req=ext-zip \
 # Verify both patches actually applied. composer-patches only logs a
 # warning when a patch fails to apply, so we grep for the sentinels we
 # ourselves planted in the patch files. If a future webtrees release
 # moves the patched code, this fail-fasts the build.
 # Patch-applied guards: composer-patches only warns on failure, so we
 # verify each hunk landed by grepping for a sentinel unique to that hunk.
 && grep -q "Upgrade-lock: bundled image is immutable" \
        vendor/fisharebest/webtrees/app/Services/UpgradeService.php \
 && test -f vendor/fisharebest/webtrees/app/Services/Composer/VendorModuleService.php \
 && grep -q 'merge($this->vendorModules())' \
        vendor/fisharebest/webtrees/app/Services/ModuleService.php \
 # Reject stray files in patches/ — only .patch files should land there.
 && ! find patches -mindepth 1 -type f ! -name '*.patch' | grep -q . \
 # composer install --prefer-dist pulls fisharebest/webtrees from packagist,
 # which strips resources/lang/<locale>/messages.po via .gitattributes
 # export-ignore. Without those files webtrees' SetupWizard fatals on the
 # very first non-English request (file(.../messages.po): No such file). The
 # dev workflow handles this via scripts/update-languages.sh as a
 # post-autoload-dump composer script, but the build runs `composer install
 # --no-scripts` (composer:2 image lacks the PHP extensions some webtrees
 # scripts could need) so the lang dir stays empty unless we fetch it
 # explicitly. Sparse-checkout `/resources/lang` from upstream's git at the
 # pinned WEBTREES_VERSION tag and overlay the files; everything else stays
 # composer-managed.
 && git clone --quiet --no-checkout --depth=1 --filter=tree:0 \
        --branch "${WEBTREES_VERSION}" \
        https://github.com/fisharebest/webtrees.git /tmp/webtrees-lang \
 && git -C /tmp/webtrees-lang sparse-checkout set --no-cone /resources/lang \
 && git -C /tmp/webtrees-lang checkout --quiet \
 && cp -rf /tmp/webtrees-lang/resources/lang/* vendor/fisharebest/webtrees/resources/lang/ \
 && rm -rf /tmp/webtrees-lang \
 # Promote webtrees' data/ directory out of vendor/ and replace it with a
 # relative symlink. Webtrees' Webtrees::DATA_DIR is hardcoded to
 # vendor/fisharebest/webtrees/data/; the symlink redirects that to the
 # top-level /var/www/html/data, which is the path end-users actually mount.
 # Result: no INDEX_DIRECTORY site-setting override needed for the
 # mount to work — webtrees' default resolves to the user's volume.
 && mv vendor/fisharebest/webtrees/data data \
 && ln -s ../../../data vendor/fisharebest/webtrees/data \
 # Stage the final layout under html/. The entrypoint copies /opt/webtrees-dist/.
 # into /var/www/ so the result lands at /var/www/html/{composer.json,vendor,public,data},
 # matching the classic PHP-hosting convention end-users expect. nginx serves
 # /var/www/html/public — no symlink trickery needed there. The patches/ directory
 # is intentionally not carried over; patches were applied at build time and
 # are not needed at runtime.
 && mkdir -p /opt/webtrees-dist/html \
 && mv composer.json composer.lock vendor public data /opt/webtrees-dist/html/ \
 && rm -rf /build/patches \
 && test -f /opt/webtrees-dist/html/public/index.php \
 && test -d /opt/webtrees-dist/html/vendor/fisharebest/webtrees \
 && test -L /opt/webtrees-dist/html/vendor/fisharebest/webtrees/data \
 && test -f /opt/webtrees-dist/html/data/.htaccess


##########################
# WEBTREES BUILD (FULL)  #
##########################
# Magic-Sunday-Edition: webtrees core + fan/pedigree/descendants charts.
# Same install pipeline as webtrees-build, different composer manifest.
# webtrees-statistics is deferred until the module is published to Packagist.
# Major-pin — same rationale as webtrees-build above.
FROM composer:2 AS webtrees-build-full

# pipefail — same rationale as webtrees-build above.
SHELL ["/bin/ash", "-o", "pipefail", "-c"]

ARG WEBTREES_VERSION=2.2.6
ARG PHP_VERSION=8.3

WORKDIR /build

COPY setup/composer-full.json /build/composer.json
COPY setup/patches /build/patches
COPY setup/public /build/public

# SC2016: see the webtrees-build stage above — `$this` in the grep
# pattern is the literal PHP expression, intentionally single-quoted.
# hadolint ignore=SC2016
RUN [ -n "${WEBTREES_VERSION}" ] || { echo "WEBTREES_VERSION cannot be empty" >&2; exit 1; } \
 && sed -i "s|\"fisharebest/webtrees\": \"[^\"]*\"|\"fisharebest/webtrees\": \"${WEBTREES_VERSION}\"|" composer.json \
 # Mirror the platform-pin from webtrees-build (see comment there) so the
 # full edition's transitive deps resolve against the deployment PHP
 # version, not the composer:2 image's PHP version.
 && composer config platform.php "${PHP_VERSION}.0" \
 && composer install \
        --no-dev \
        --no-scripts \
        --no-progress \
        --no-interaction \
        --classmap-authoritative \
        --prefer-dist \
        --ignore-platform-req=ext-gd \
        --ignore-platform-req=ext-intl \
        --ignore-platform-req=ext-exif \
        --ignore-platform-req=ext-imagick \
        --ignore-platform-req=ext-zip \
 # Patch-applied guards (same sentinels as core)
 && grep -q "Upgrade-lock: bundled image is immutable" \
        vendor/fisharebest/webtrees/app/Services/UpgradeService.php \
 && test -f vendor/fisharebest/webtrees/app/Services/Composer/VendorModuleService.php \
 && grep -q 'merge($this->vendorModules())' \
        vendor/fisharebest/webtrees/app/Services/ModuleService.php \
 && ! find patches -mindepth 1 -type f ! -name '*.patch' | grep -q . \
 # Verify Magic-Sunday charts landed in vendor/ (NOT modules_v4/)
 && test -d vendor/magicsunday/webtrees-fan-chart \
 && test -d vendor/magicsunday/webtrees-pedigree-chart \
 && test -d vendor/magicsunday/webtrees-descendants-chart \
 # composer install --prefer-dist pulls fisharebest/webtrees from packagist,
 # which strips resources/lang/<locale>/messages.po via .gitattributes
 # export-ignore. Without those files webtrees' SetupWizard fatals on the
 # very first non-English request (file(.../messages.po): No such file). The
 # dev workflow handles this via scripts/update-languages.sh as a
 # post-autoload-dump composer script, but the build runs `composer install
 # --no-scripts` (composer:2 image lacks the PHP extensions some webtrees
 # scripts could need) so the lang dir stays empty unless we fetch it
 # explicitly. Sparse-checkout `/resources/lang` from upstream's git at the
 # pinned WEBTREES_VERSION tag and overlay the files; everything else stays
 # composer-managed.
 && git clone --quiet --no-checkout --depth=1 --filter=tree:0 \
        --branch "${WEBTREES_VERSION}" \
        https://github.com/fisharebest/webtrees.git /tmp/webtrees-lang \
 && git -C /tmp/webtrees-lang sparse-checkout set --no-cone /resources/lang \
 && git -C /tmp/webtrees-lang checkout --quiet \
 && cp -rf /tmp/webtrees-lang/resources/lang/* vendor/fisharebest/webtrees/resources/lang/ \
 && rm -rf /tmp/webtrees-lang \
 # Layout promotion (same as core)
 && mv vendor/fisharebest/webtrees/data data \
 && ln -s ../../../data vendor/fisharebest/webtrees/data \
 && mkdir -p /opt/webtrees-dist/html \
 && mv composer.json composer.lock vendor public data /opt/webtrees-dist/html/ \
 && rm -rf /build/patches \
 && test -f /opt/webtrees-dist/html/public/index.php \
 && test -d /opt/webtrees-dist/html/vendor/fisharebest/webtrees \
 && test -L /opt/webtrees-dist/html/vendor/fisharebest/webtrees/data \
 && test -f /opt/webtrees-dist/html/data/.htaccess


###############
# PHP RUNTIME #
###############
# Shared base: PHP-FPM, extensions, entrypoint. Both production tracks
# (php-build core, php-build-full Magic-Sunday-Edition) derive from this
# stage so the PHP runtime is built once.
FROM php:${PHP_VERSION}-fpm-alpine AS php-base

# docker-entrypoint.sh dependencies.
#
# DL3018 (pin apk versions) intentionally suppressed: this image tracks a
# rolling Alpine base (see check-alpine.yml), so pinning every package
# patch version would generate churn on every base bump without
# reproducibility gain — the next bump rotates all packages anyway.
# hadolint ignore=DL3018
RUN apk update && \
    apk upgrade --no-cache && \
    apk add --no-cache \
    bash \
    tzdata

# Add PHP extension installer
ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/

# Install required PHP extensions.
# pdo_sqlite is included even though the default compose uses MariaDB — keeps
# the SQLite variant from Cluster B as an env-var-only switch later.
RUN chmod +x /usr/local/bin/install-php-extensions && \
    install-php-extensions \
        apcu \
        exif \
        gd \
        imagick \
        intl \
        opcache \
        pdo_mysql \
        pdo_sqlite \
        zip

# Custom PHP configuration
COPY rootfs/usr/local/etc/php/conf.d/*.ini $PHP_INI_DIR/conf.d/

# php-fpm pool overrides — `zz-catch-workers-output.conf` makes the FPM
# master forward worker stdout/stderr to docker logs so php errors and
# any sendmail_path-invoked subprocess output stay visible.
COPY rootfs/usr/local/etc/php-fpm.d/*.conf /usr/local/etc/php-fpm.d/

# Entrypoint
COPY rootfs/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["php-fpm"]


#######################
# WEBTREES CORE IMAGE #
#######################
FROM php-base AS php-build

# Re-declare ARGs (out of scope across FROM boundaries)
ARG PHP_VERSION=8.3
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
ARG WEBTREES_VERSION=2.2.6

LABEL org.opencontainers.image.title="Webtrees PHP-FPM" \
      org.opencontainers.image.description="PHP-FPM runtime with bundled webtrees ${WEBTREES_VERSION}." \
      org.opencontainers.image.authors="Rico Sonntag <mail@ricosonntag.de>" \
      org.opencontainers.image.vendor="Rico Sonntag" \
      org.opencontainers.image.documentation="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WEBTREES_VERSION}-php${PHP_VERSION}" \
      org.opencontainers.image.url="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.source="https://github.com/magicsunday/webtrees-docker.git" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.base.name="php:${PHP_VERSION}-fpm-alpine" \
      org.opencontainers.image.ref.name="webtrees-php:${PHP_VERSION}" \
      net.webtrees.upgrade-locked="true"

# Bundle the composer-installed webtrees for first-run initialisation.
COPY --from=webtrees-build /opt/webtrees-dist /opt/webtrees-dist


##############################
# WEBTREES FULL EDITION      #
##############################
FROM php-base AS php-build-full

ARG PHP_VERSION=8.3
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
ARG WEBTREES_VERSION=2.2.6

LABEL org.opencontainers.image.title="Webtrees PHP-FPM (Magic-Sunday-Edition)" \
      org.opencontainers.image.description="PHP-FPM runtime with bundled webtrees ${WEBTREES_VERSION} + Magic-Sunday charts (fan, pedigree, descendants)." \
      org.opencontainers.image.authors="Rico Sonntag <mail@ricosonntag.de>" \
      org.opencontainers.image.vendor="Rico Sonntag" \
      org.opencontainers.image.documentation="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WEBTREES_VERSION}-php${PHP_VERSION}" \
      org.opencontainers.image.url="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.source="https://github.com/magicsunday/webtrees-docker.git" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.base.name="php:${PHP_VERSION}-fpm-alpine" \
      org.opencontainers.image.ref.name="webtrees-php-full:${PHP_VERSION}" \
      net.webtrees.upgrade-locked="true" \
      net.webtrees.edition="full"

COPY --from=webtrees-build-full /opt/webtrees-dist /opt/webtrees-dist


############
# BUILDBOX #
############
FROM php-build AS build-box

# Re-declare ARGs (same reason as in php-build stage).
ARG PHP_VERSION=8.3
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
ARG WEBTREES_VERSION=2.2.6
ARG DOCKER_SERVER=ghcr.io/magicsunday

ENV COMPOSER_ALLOW_SUPERUSER=1

# Install xdebug (development only) and clean up the extension installer
RUN install-php-extensions xdebug && \
    rm -f /usr/local/bin/install-php-extensions

# Installing required extensions
# DL3018 (pin apk versions) intentionally suppressed: this image tracks a
# rolling Alpine base (see check-alpine.yml), so pinning every package
# patch version would generate churn on every base bump without
# reproducibility gain — the next bump rotates all packages anyway.
# hadolint ignore=DL3018
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
      org.opencontainers.image.version="${WEBTREES_VERSION}-php${PHP_VERSION}" \
      org.opencontainers.image.url="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.source="https://github.com/magicsunday/webtrees-docker.git" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.base.name="${DOCKER_SERVER}/webtrees-php:${PHP_VERSION}" \
      org.opencontainers.image.ref.name="webtrees/buildbox:${PHP_VERSION}"

ENTRYPOINT ["/docker-entrypoint.sh", "/opt/user-entrypoint.sh"]


##################
# NGINX          #
##################
# Pre-baked nginx with webtrees configs and an empty /etc/nginx/conf.d/custom/
# directory that users override-mount for their own snippets.
FROM nginx:1.30-alpine AS nginx-build

# pipefail makes a failing `nginx -t` surface at the pipe rather than
# being masked by tee's exit. The grep guards below would also catch the
# same case downstream, but pipefail keeps the failure attributed to
# nginx itself and satisfies DL4006.
SHELL ["/bin/ash", "-o", "pipefail", "-c"]

ARG NGINX_CONFIG_REVISION=1
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="Webtrees nginx" \
      org.opencontainers.image.description="nginx with webtrees configs and override-hook." \
      org.opencontainers.image.authors="Rico Sonntag <mail@ricosonntag.de>" \
      org.opencontainers.image.vendor="Rico Sonntag" \
      org.opencontainers.image.documentation="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="1.30-r${NGINX_CONFIG_REVISION}" \
      org.opencontainers.image.url="https://github.com/magicsunday/webtrees-docker#readme" \
      org.opencontainers.image.source="https://github.com/magicsunday/webtrees-docker.git" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.base.name="nginx:1.30-alpine" \
      org.opencontainers.image.ref.name="webtrees-nginx:1.30-r${NGINX_CONFIG_REVISION}"

# Baked configs: conf.d, includes, templates.
COPY rootfs/etc/nginx/conf.d /etc/nginx/conf.d
COPY rootfs/etc/nginx/includes /etc/nginx/includes
COPY rootfs/etc/nginx/templates /etc/nginx/templates

# Entrypoint hooks that the upstream nginx:1.30-alpine image runs from
# /docker-entrypoint.d/ before exec'ing nginx. Used to render
# operator-supplied NGINX_TRUSTED_PROXIES into trust-proxy-extra.conf.
COPY rootfs/docker-entrypoint.d /docker-entrypoint.d
RUN chmod +x /docker-entrypoint.d/*.sh

# Empty override directory — users mount their own snippets in.
RUN mkdir -p /etc/nginx/conf.d/custom

# Validate config at build time so syntax errors fail the build.
# Two prep steps are needed before `nginx -t` works:
#   1. Run the upstream image's envsubst script so the templates/ directory
#      becomes a concrete /etc/nginx/conf.d/10-variables.conf — otherwise
#      $enforce_https resolves to an unknown variable.
#   2. Stub the `phpfpm` upstream to loopback. nginx -t resolves upstream
#      hostnames; the build network has no DNS for the compose service name.
#      The stub is supplied by the CI build step as a buildx --add-host
#      (`add-hosts: phpfpm=127.0.0.1`), which buildkit injects into the
#      RUN sandbox's /etc/hosts without making the file writable. Docker
#      overrides /etc/hosts at runtime with the real network entry, so the
#      build-time stub never reaches a running container.
RUN ENFORCE_HTTPS=FALSE /docker-entrypoint.d/20-envsubst-on-templates.sh \
 && nginx -t -c /etc/nginx/nginx.conf 2>&1 | tee /tmp/nginx-t.log \
 && grep -q "syntax is ok" /tmp/nginx-t.log \
 && grep -q "test is successful" /tmp/nginx-t.log \
 && rm -f /etc/nginx/conf.d/10-variables.conf /tmp/nginx-t.log
