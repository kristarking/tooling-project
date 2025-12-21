# Multi-stage build for optimized image
# Stage 1: Base image with dependencies
FROM php:7.4-apache AS base

# Install system dependencies
RUN apt-get update && apt-get install -y \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    && rm -rf /var/lib/apt/lists/*

# Install PHP extensions
RUN docker-php-ext-install mysqli pdo pdo_mysql

# Enable Apache modules
RUN a2enmod rewrite

# Stage 2: Development image (optional)
FROM base AS development

# Install development tools
RUN pecl install xdebug \
    && docker-php-ext-enable xdebug

# Stage 3: Production image
FROM base AS production

# Security: Run as non-root user
RUN useradd -u 1000 -m appuser

# Copy Apache configuration
COPY apache-config.conf /etc/apache2/sites-available/000-default.conf

# Copy application source
COPY --chown=appuser:appuser html /var/www

# Copy startup script
COPY start-apache /usr/local/bin/
RUN chmod +x /usr/local/bin/start-apache

# Security: Set proper permissions
RUN chown -R appuser:www-data /var/www \
    && chmod -R 755 /var/www

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/ || exit 1

# Expose port
EXPOSE 80

CMD ["start-apache"]