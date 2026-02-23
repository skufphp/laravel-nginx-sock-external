# ==============================================================================
# Многоэтапный образ PHP-FPM (Unix Socket) — PHP 8.5 Alpine (Laravel)
# ==============================================================================
# Назначение:
# - Сборка фронтенда (Node.js)
# - Базовая среда PHP (FPM)
# - Поддержка Xdebug для разработки
# - Оптимизированный Production образ
# ==============================================================================
FROM node:24-alpine AS frontend-build
WORKDIR /app

# Ставим зависимости фронта отдельно для лучшего кеширования
COPY ../package*.json ./
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi

# Копируем проект и собираем ассеты
COPY ../ ./
RUN npm run build


# ==============================================================================
# Базовая среда PHP (без node) — используется для разработки и как основа для продакшена
# ==============================================================================
FROM php:8.5-fpm-alpine AS php-base

# 1) Зависимости времени выполнения + Зависимости для сборки (удалим после компиляции)
RUN set -eux; \
    apk add --no-cache \
      curl git zip unzip fcgi \
      icu-libs libzip libpng libjpeg-turbo freetype mariadb-connector-c libxml2 oniguruma \
    && apk add --no-cache --virtual .build-deps \
      $PHPIZE_DEPS linux-headers \
      icu-dev libzip-dev libpng-dev libjpeg-turbo-dev freetype-dev \
      libxml2-dev oniguruma-dev

# 2) PHP-расширения
RUN set -eux; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" \
      pdo \
      pdo_mysql \
      mbstring \
      xml \
      gd \
      bcmath \
      zip \
      intl

# 3) PIE (PHP Installer for Extensions) + Xdebug (только для разработки)
COPY --from=ghcr.io/php/pie:bin /pie /usr/bin/pie

ARG INSTALL_XDEBUG=false
RUN set -eux; \
    if [ "${INSTALL_XDEBUG}" = "true" ]; then \
      pie install xdebug/xdebug; \
      docker-php-ext-enable xdebug; \
    fi

# 4) Очистка временных файлов
RUN set -eux; \
    apk del .build-deps; \
    rm -rf /tmp/pear ~/.pearrc /var/cache/apk/*

# 5) Конфигурация PHP-FPM (unix socket) + php.ini
RUN rm -f \
      /usr/local/etc/php-fpm.d/www.conf.default \
      /usr/local/etc/php-fpm.d/zz-docker.conf \
      /usr/local/etc/php-fpm.d/www.conf

COPY ./php/www.conf /usr/local/etc/php-fpm.d/www.conf
COPY ./php/php.ini /usr/local/etc/php/conf.d/local.ini

RUN mkdir -p /var/run/php && chown -R www-data:www-data /var/run/php

# 6) Установка Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/laravel
RUN chown -R www-data:www-data /var/www/laravel

CMD ["php-fpm", "-F"]


# ==============================================================================
# Production образ: код + собранные ассеты (идеально для деплоя)
# ==============================================================================
FROM php-base AS production
WORKDIR /var/www/laravel

COPY ../ ./
COPY --from=frontend-build /app/public/build /var/www/laravel/public/build