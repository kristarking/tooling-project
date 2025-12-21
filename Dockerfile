# ==============================================================================
# Stage 1: Base image with runtime dependencies
# ==============================================================================
FROM php:7.4-apache AS base

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpng-dev \
        libjpeg-dev \
        libfreetype6-dev \
        curl \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) mysqli pdo pdo_mysql gd \
    && a2enmod rewrite \
    && rm -rf /var/lib/apt/lists/*

# ==============================================================================
# Stage 2: Development image (optional)
# ==============================================================================
FROM base AS development

RUN pecl install xdebug \
    && docker-php-ext-enable xdebug

# ==============================================================================
# Stage 3: Production image
# ==============================================================================
FROM base AS production

# Copy Apache configuration
COPY apache-config.conf /etc/apache2/sites-available/000-default.conf

# Copy application source
COPY html /var/www

# Ensure correct permissions (Apache runs as www-data internally)
RUN chown -R www-data:www-data /var/www \
    && chmod -R 755 /var/www

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/ || exit 1

EXPOSE 80

CMD ["apache2-foreground"]
