##############################################
# === STAGE 1: BASE IMAGE ====================
# This stage defines the common base for both
# development and production environments.
# It installs PHP 8.4, common extensions,
# and Composer for dependency management.
##############################################
FROM php:8.4-fpm-alpine AS base

# Set default working directory inside the container
ENV APP_HOME=/app
ENV APP_USER=ecoride

WORKDIR $APP_HOME

# Install system dependencies and PHP extensions
# - acl, git: common utilities
# - fcgi: required by PHP-FPM
# - libzip-dev, icu-dev: for zip & intl PHP extensions
# - docker-php-ext-install: compile PHP extensions
RUN apk add --no-cache \
        acl \
        fcgi \
        git \
        libzip-dev \
        zip \
        icu-dev \
        postgresql-dev \
    && docker-php-ext-install -j$(nproc) \
        intl \
        opcache \
        pdo_mysql \
        pdo_pgsql \
        pgsql \
        zip

# Copy Composer binary from the official Composer image
# This avoids installing Composer manually inside the container.
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Add a non-root user for all stages and give permission to /app
RUN addgroup -S $APP_USER && adduser -S -G $APP_USER $APP_USER \
    && mkdir -p /app && chown -R $APP_USER:$APP_USER /app

##############################################
# === STAGE 2: PRODUCTION IMAGE ==============
# This image is optimized for production use.
# It contains only what is strictly necessary
# to run the Symfony application efficiently.
##############################################
FROM base AS prod

# Set environment variables for production
ENV APP_ENV=prod
ENV DEBUG=0

ENV COMPOSER_ALLOW_SUPERUSER=1

# Copy the entire Symfony project into the container
COPY . $APP_HOME

# Ensure necessary directories exist and have correct permissions
RUN mkdir -p var/cache var/log \
    && chown -R $APP_USER:$APP_USER var \
    && chmod -R 775 var

# Install PHP dependencies (without dev packages)
# --no-dev: excludes dev dependencies
# --optimize-autoloader: improves performance
# --no-interaction, --no-progress: cleaner logs
RUN composer install --no-dev --optimize-autoloader --no-scripts --no-interaction --no-progress

# Clear and warm up Symfony cache done during deployment script
# RUN php bin/console cache:clear --no-warmup --env=prod
# RUN php bin/console cache:warmup --env=prod

# Use the non-root user for the rest of the container execution
USER $APP_USER

##############################################
# === STAGE 3: DEVELOPMENT IMAGE ============
# This image is used locally by developers.
# It includes Xdebug for debugging and
# mounts the source code as a volume.
##############################################
FROM base AS dev

# Set environment variables for development
ENV APP_ENV=dev
ENV DEBUG=1

# Install build dependencies (needed for compiling Xdebug)
RUN apk add --no-cache --virtual .build-deps autoconf g++ make linux-headers

# Install and enable Xdebug for remote debugging
RUN pecl install xdebug \
    && docker-php-ext-enable xdebug

# Remove build dependencies to keep the image light
RUN apk del .build-deps

# Configure Xdebug for remote connections.
# 'host.docker.internal' allows the container
# to communicate with the host machine (works
# on Windows, macOS, and Docker Desktop).
RUN echo "xdebug.mode=debug" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini \
    && echo "xdebug.client_host=host.docker.internal" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini

# You can uncomment the next line if you need Xdebug logs:
# RUN echo "xdebug.log=/tmp/xdebug.log" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini

# Use the non-root user for the rest of the container execution
USER $APP_USER
