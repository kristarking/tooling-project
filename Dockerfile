# Stage 1: Base image with dependencies
FROM php:7.4-apache AS base

# Fix DL3008 (Pinning), DL3015 (Recommends), and DL3059 (Consolidation)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpng-dev=1.6.37-3 \
    libjpeg-dev=8c-2ubuntu10 \
    libfreetype6-dev=2.11.1+dfsg-1ubuntu0.2 \
    && docker-php-ext-install mysqli pdo pdo_mysql \
    && a2enmod rewrite \
    && rm -rf /var/lib/apt/lists/*

# Stage 2: Production image
FROM base AS production

# Copy configuration and source code
COPY apache-config.conf /etc/apache2/sites-available/000-default.conf
COPY html /var/www

# Fix permissions for the default www-data user
RUN chown -R www-data:www-data /var/www \
    && chmod -R 755 /var/www

# Copy startup script and set permissions in one RUN to avoid DL3059
COPY start-apache /usr/local/bin/
RUN chmod +x /usr/local/bin/start-apache

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/ || exit 1

EXPOSE 80

CMD ["start-apache"]