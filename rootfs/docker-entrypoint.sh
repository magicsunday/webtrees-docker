#!/usr/bin/env bash

set -e # Instructs a shell to exit if a command fails, i.e., if it outputs a non-zero exit status.
set -u # Treats unset or undefined variables as an error when substituting (during parameter expansion).

###############
# Environment #
###############

# Set default ENVIRONMENT
if [ -z "$ENVIRONMENT" ]; then
    ENVIRONMENT="production"
fi

# Disable https enforcement
if [[ "${ENFORCE_HTTPS}" != "true" ]]; then
    echo "Disable HTTPS enforcement"
    echo " " >/etc/nginx/includes/enforce-https.conf
fi

################
# PHP settings #
################

# Setup config for selected environment
if [ "production" == "$ENVIRONMENT" ]; then
    mv "$PHP_INI_DIR/conf.d/webtrees-xdebug.ini" "$PHP_INI_DIR/conf.d/webtrees-xdebug.disabled"
fi

# Use the default PHP configuration depending on selected environment
cp "$PHP_INI_DIR/php.ini-${ENVIRONMENT}" "$PHP_INI_DIR/php.ini"

# Setup max_execution_time
if [ -z "$PHP_MAX_EXECUTION_TIME" ]; then
    PHP_MAX_EXECUTION_TIME=30
fi

# Setup max_input_vars
if [ -z "$PHP_MAX_INPUT_VARS" ]; then
    PHP_MAX_INPUT_VARS=1000
fi

# Setup memory_limit
if [ -z "$PHP_MEMORY_LIMIT" ]; then
    PHP_MEMORY_LIMIT=128M
fi

sed -i "/^max_execution_time =/s/=.*/= $PHP_MAX_EXECUTION_TIME/" "$PHP_INI_DIR/conf.d/webtrees-php.ini"
sed -i "/^max_input_vars =/s/=.*/= $PHP_MAX_INPUT_VARS/" "$PHP_INI_DIR/conf.d/webtrees-php.ini"
sed -i "/^memory_limit =/s/=.*/= $PHP_MEMORY_LIMIT/" "$PHP_INI_DIR/conf.d/webtrees-php.ini"

# Setup post_max_size
if [ -n "$PHP_POST_MAX_SIZE" ]; then
    sed -i "/^post_max_size =/s/=.*/= $PHP_POST_MAX_SIZE/" "$PHP_INI_DIR/conf.d/webtrees-php.ini"
fi

# Setup upload_max_filesize
if [ -n "$PHP_UPLOAD_MAX_FILESIZE" ]; then
    sed -i "/^upload_max_filesize =/s/=.*/= $PHP_UPLOAD_MAX_FILESIZE/" "$PHP_INI_DIR/conf.d/webtrees-php.ini"
fi

#################
# Mail settings #
#################

#if [ -n "$MAIL_SMTP" ]; then
#    echo "mailhub = $MAIL_SMTP" >>/etc/ssmtp/ssmtp.conf
#fi
#
#if [ -n "$MAIL_DOMAIN" ]; then
#    echo "rewriteDomain = $MAIL_DOMAIN" >>/etc/ssmtp/ssmtp.conf
#fi
#
#if [ -n "$MAIL_HOST" ]; then
#    echo "hostname = $MAIL_HOST" >>/etc/ssmtp/ssmtp.conf
#fi
#
## Allow overwriting FROM Header by PHP
#echo "FromLineOverride = YES" >>"/etc/ssmtp/ssmtp.conf"

#"$@"

exec "$@"
