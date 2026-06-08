#!/usr/bin/env bash

# Google Shell Style Guide baseline
set -o errexit -o nounset -o pipefail

IFS=$'\n\t'

# Unlike the sibling build scripts this one does not `source
# scripts/configuration` (it must NOT see the DB env that validate
# pulls in — it only needs COMPOSER_AUTH), so guard APP_DIR explicitly:
# a mis-wired invocation fails with a clear message instead of a raw
# `APP_DIR: unbound variable` from `set -o nounset`.
: "${APP_DIR:?APP_DIR must be set by the build environment}"

# Preserve COMPOSER_AUTH if provided
export COMPOSER_AUTH="${COMPOSER_AUTH:-}"

composer install -d "${APP_DIR}"
