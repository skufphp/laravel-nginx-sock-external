Вы как раз упёрлись в типичную “боль”: **Redis Cluster в PHP чаще всего нормально заводится именно через `Redis` класс (phpredis extension)**. Поэтому для вашего `laravel-nginx-sock-external` я рекомендую **по умолчанию поддерживать**:

## Рекомендация по умолчанию: `phpredis + Redis Cluster`
Почему это “канонично” для boilerplate:

- **Это нативный клиент на уровне расширения PHP** (обычно быстрее и предсказуемее, чем pure-PHP).
- В managed Redis Cluster’ах (особенно с TLS/ACL) меньше сюрпризов, если вы опираетесь на стандартные возможности `phpredis`.
- В проде вам всё равно придётся контролировать PHP image → логично “гарантировать” наличие `ext-redis` в образе.

`predis` имеет право на жизнь, но как дефолт для “external infra” boilerplate я бы не ставил: это ещё одна composer-зависимость и отдельный класс проблем/настроек.

---

## Что именно добавить в ваш PHP image (чтобы Cluster вообще было чем подключать)

Сейчас в вашем PHP Dockerfile уже используется PIE, значит проще всего **вшить установку `ext-redis`** рядом с Xdebug-блоком (или отдельным блоком).

```dockerfile
# ==============================================================================
# PHP base runtime (no node) — used for dev target and as base for production
# ==============================================================================
FROM php:8.5-fpm-alpine AS php-base

# ... existing code ...

# 3) PIE (PHP Installer for Extensions) + Xdebug (dev only)
COPY --from=ghcr.io/php/pie:bin /pie /usr/bin/pie

# Redis (phpredis) — нужен для внешнего Redis/Redis Cluster
RUN set -eux; \
    pie install redis/phpredis; \
    docker-php-ext-enable redis

ARG INSTALL_XDEBUG=false
RUN set -eux; \
    if [ "${INSTALL_XDEBUG}" = "true" ]; then \
      pie install xdebug/xdebug; \
      docker-php-ext-enable xdebug; \
    fi

# ... existing code ...
```


**Итог:** в вашем `php:${IMAGE_TAG}` образе гарантированно есть `ext-redis`, и Laravel может работать с Redis/Cluster без дополнительных PHP пакетов.

---

## “Официальные” переменные окружения для external Redis Cluster (которые я бы закрепил в boilerplate)

В `.env` проекта (dev) / в CI/CD variables (prod):

```dotenv
REDIS_CLIENT=phpredis
REDIS_CLUSTER=redis

# CSV список нод кластера:
REDIS_CLUSTER_NODES=<host1>:<port1>,<host2>:<port2>,<host3>:<port3>

# Если нужен пароль:
REDIS_PASSWORD=<redis_password_or_empty>

# Если managed cluster с TLS:
REDIS_TLS=false
```


> Заметьте: это именно “контракт” вашего boilerplate. В документации так и пишете: “мы ожидаем `REDIS_CLUSTER_NODES` в таком формате”.

---

## Как это обычно “подключают” в Laravel (концепт)

В Laravel Redis-конфигурация живёт в `config/database.php` в секции `redis`.  
Для cluster-режима в большинстве проектов делают одно из двух:

1) **Патч в `config/database.php`**, который парсит `REDIS_CLUSTER_NODES` (CSV) в массив хостов/портов.  
2) **Отдельный config-файл/хелпер**, чтобы `database.php` не разрастался.

Я предлагаю для boilerplate вариант (1): проще копировать между проектами.

Если хотите — в следующем сообщении дам вам **готовый фрагмент для `config/database.php`**, который:
- парсит `REDIS_CLUSTER_NODES`,
- поддерживает `REDIS_PASSWORD`,
- опционально включает TLS,
- и работает с `phpredis`.

---

## Маленькое уточнение, чтобы я дал вам точный “боевой” конфиг
Ваш внешний Redis Cluster в проде будет:
1) **обычный TCP без TLS**, или  
2) **TLS обязателен** (типично для managed)?

От этого зависит, какие параметры “по умолчанию” включать в шаблон, чтобы он заводился без шаманства.