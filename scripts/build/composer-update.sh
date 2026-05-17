#!/usr/bin/env bash

# Google Shell Style Guide baseline
set -o errexit -o nounset -o pipefail

IFS=$'\n\t'

# Preserve COMPOSER_AUTH if provided
export COMPOSER_AUTH="${COMPOSER_AUTH:-}"

composer update -d "${APP_DIR}"
