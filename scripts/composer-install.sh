#!/usr/bin/env bash

export COMPOSER_AUTH=${COMPOSER_AUTH}
composer install -d "${APP_DIR}"
