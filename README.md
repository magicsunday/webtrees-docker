# Customized docker images

## php/Dockerfile-7.4-fpm
PHP 7.4 FPM with custom modules installed.

## php/Dockerfile-7.4-fpm-alpine
PHP 7.4 FPM (based on alpine) with custom modules instaled.

# Build image

## PHP 7.4 FPM
docker build -t webtrees/php:7.4-fpm -f Dockerfile-7.4-fpm .

## PHP 7.4 FPM based an alpine
docker build -t webtrees/php:7.4-fpm-alpine -f Dockerfile-7.4-fpm-alpine .
