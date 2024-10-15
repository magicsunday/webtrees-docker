# PHP development images for Webtrees

## php/Dockerfile-7.4-fpm
PHP 7.4 FPM with custom modules installed.

## php/Dockerfile-7.4-fpm-alpine
PHP 7.4 FPM (based on alpine) with custom modules instaled.

# Build image

## PHP 7.4 FPM
docker build -t webtrees/php:7.4-fpm -f Dockerfile-7.4-fpm .

## PHP 7.4 FPM based an alpine
docker build -t webtrees/php:7.4-fpm-alpine -f Dockerfile-7.4-fpm-alpine .


# Portainer

Image name:

	192.168.178.25:5000/webtrees/php:8.1-fpm

URL:

	https://github.com/magicsunday/webtrees-docker.git

Dockerfile path:

	Dockerfile-8.1-fpm

Tag the image:

	Registry: Select your custom registry
	Image: webtrees/php:8.1-fpm
	