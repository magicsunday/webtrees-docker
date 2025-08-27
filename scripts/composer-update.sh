#!/usr/bin/env bash

export COMPOSER_AUTH=${COMPOSER_AUTH}
composer update -d "${APP_DIR}"
