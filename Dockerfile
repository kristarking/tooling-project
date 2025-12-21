# ==============================================================================
# Stage 1: Base image with runtime dependencies
# ==============================================================================
FROM php:7.4-apache AS base

# hadolint ignore=DL3008,DL3015
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libpng-dev \
        libjpeg-dev \
        libfreetype6-dev \
        curl \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        mysqli \
        pdo \
        pdo_mysql \
        gd \
    && a2enmod rewrite \
    && rm -rf /var/lib/apt/lists/*

# ==============================================================================
# Stage 2: Development image (optional, not used in prod)
# ==============================================================================
FROM base AS development

# hadolint ignore=DL3059
RUN pecl install xdebug \
    && docker-php-ext-enable xdebug

# ==============================================================================
# Stage 3: Production image
# ==============================================================================
FROM base AS production

# Apache config
COPY apache-config.conf /etc/apache2/sites-available/000-default.conf

# Application source
COPY html /var/www

# Permissions (Apache runs as www-data)
# hadolint ignore=DL3059
RUN chown -R www-data:www-data /var/www \
    && chmod -R 755 /var/www

# Healthcheck
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/ || exit 1

EXPOSE 80

CMD ["apache2-foreground"]
