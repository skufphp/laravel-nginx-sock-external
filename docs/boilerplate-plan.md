Ниже — **такой же пошаговый план**, но для варианта **`laravel-nginx-sock-external`**: приложение (php+nginx+node для dev) в Compose, а **Postgres — внешний**, и **Redis — внешний Redis Cluster**. Цель — чтобы этот boilerplate можно было вставлять в проекты, где инфраструктура вне Compose, а деплой и миграции идут через CI/CD.

---

## Цель и принципы (external-версия)

### Что хотим получить
- `docker-compose.yml` (base): **только app-скелет** (php + nginx + сеть + unix-socket volume).
- `docker-compose.dev.yml` (dev overlay): **только dev-удобства** (ports, bind-mount кода, node/vite).
- `docker-compose.prod.yml` (prod overlay): **только image + migrate one-off job**.
- Никаких `postgres`, `redis`, `pgadmin` сервисов в compose (иначе “external” перестанет быть external).

### Главная инженерная идея
- Весь доступ к БД/Redis идёт **через переменные окружения** (`.env` в dev, переменные окружения/секреты в CI/CD).
- Миграции запускаются как **one-off job** в том же образе, что и PHP, но подключаются к **внешней БД**.

---

## Шаг 0. Определить контракт внешней инфраструктуры (то, что boilerplate “ожидает”)

Зафиксируйте в документации и переменных:

### Postgres (external)
- `DB_HOST` — DNS/IP внешней БД
- `DB_PORT` — обычно `5432`
- `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`
- Если есть TLS: `DB_SSLMODE` (`require/verify-full`) или аналог (зависит от драйвера/настроек)

### Redis Cluster (external)
Laravel “из коробки” умеет Redis через `phpredis`/`predis`, но **Redis Cluster требует корректной конфигурации**:
- список нод кластера (`host:port,host:port,...`)
- опционально username/password (ACL)
- TLS (если managed cluster)

**Контракт для boilerplate**: вы определяете *какой именно формат переменных* вы хотите поддерживать, например:
- `REDIS_CLUSTER_NODES="<host1>:<port1>,<host2>:<port2>,<host3>:<port3>"`
- `REDIS_PASSWORD="<...>"` (или пусто)
- `REDIS_TLS=true|false`

Это важно, потому что в “external” boilerplate Redis не стартует локально — он должен конфигурироваться чисто через env.

---

## Шаг 1. Привести `docker-compose.yml` (base) к “чистому external”

**Что делаем**
- Убедиться, что в base **нет** сервисов БД/Redis/pgadmin.
- Оставляем только:
    - `laravel-php-nginx-socket`
    - `laravel-nginx-socket`
    - `unix-socket` volume
    - network

> По сути у вас это уже почти так и есть — важно **не добавлять** туда infra.

**Проверка**
- Итоговый `docker compose -f docker-compose.yml config` показывает только php+nginx.

---

## Шаг 2. Переписать `docker-compose.dev.yml`: убрать “internal infra”, оставить dev-надстройки

**Что делаем**
- Удаляем из dev overlay сервисы:
    - `laravel-postgres-nginx-socket`
    - `laravel-pgadmin-nginx-socket`
- Оставляем:
    - bind-mount кода
    - публикации портов nginx/vite
    - node/vite сервис
- Никаких пробросов 5432/6379, потому что сервисов нет (доступ к external идёт по сети).

**Проверка**
- `docker compose -f docker-compose.yml -f docker-compose.dev.yml config` содержит только php/nginx/node.

---

## Шаг 3. Обновить `.env.docker`: из “docker internal services” → в “external endpoints”

**Что делаем**
- В `.env.docker` (как файле-подсказке) меняем комментарии:
    - больше не советуем `DB_HOST=laravel-postgres-nginx-socket`
    - вместо этого даём пример `DB_HOST=<external-db-host>`
- Добавляем переменные для Redis Cluster (как контракт из Шага 0).

Пример того, что должно быть в подсказках (без секретов, только плейсхолдеры):

```dotenv
# --- External PostgreSQL (пример) ---
# DB_CONNECTION=pgsql
# DB_HOST=<external-db-host>
# DB_PORT=5432
# DB_DATABASE=<db_name>
# DB_USERNAME=<db_user>
# DB_PASSWORD=<db_password>

# --- External Redis Cluster (пример) ---
# REDIS_CLIENT=phpredis
# REDIS_CLUSTER=redis
# REDIS_CLUSTER_NODES=<host1>:<port1>,<host2>:<port2>,<host3>:<port3>
# REDIS_PASSWORD=<redis_password_or_empty>
# REDIS_TLS=false
```


> Почему это важно: ваш boilerplate должен “подталкивать” пользователя к правильному типу подключения.

---

## Шаг 4. Добавить миграционный one-off сервис `migrate` в `docker-compose.prod.yml` (external-aware)

**Что делаем**
- Добавляем сервис `migrate`, который запускается в CI/CD после деплоя.
- Он **не зависит** от postgres-сервиса в compose (его нет).
- Он должен:
    1) дождаться доступности внешней БД (минимальный “wait-for”)
    2) выполнить `php artisan migrate --force`

### Как правильно “ждать” внешнюю БД
Варианты, в порядке предпочтения для boilerplate:
1) **Простая проверка через `php artisan migrate --force` с ретраями** (самый переносимый способ)
2) `pg_isready` (нужен клиентский пакет `postgresql-client`, которого может не быть в PHP image)
3) отдельный “wait-for-it” скрипт (лишний файл, но тоже норм)

Для универсальности (чтобы не тянуть `psql` клиент), обычно делают ретраи на уровне shell.

Концептуально для `docker-compose.prod.yml`:
- `migrate` использует тот же `${CI_REGISTRY_IMAGE}/php:${IMAGE_TAG}`
- `restart: "no"`
- `command` с ретраями и потом migrate

---

## Шаг 5. Добавить аналогичный one-off сервис `migrate` для dev (опционально, но удобно)

**Зачем**
В external-модели удобно, чтобы разработчик мог запускать миграции “как в проде”:

```shell script
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm migrate
```


**Как сделать**
- Либо добавить `migrate` в `docker-compose.yml` (base), чтобы он был и в dev, и в prod overlay (но тогда в prod надо будет переопределить image/build).
- Либо держать `migrate` только в prod overlay и в dev использовать `make artisan CMD="migrate"` (тоже ок, но менее “prod-like”).

**Рекомендация для boilerplate external**
Я бы сделал `migrate` **в base**, но:
- в base он `build:` (dev)
- в prod overlay он переопределяется на `image:` (prod)

Так вы получаете одинаковую команду запуска везде.

---

## Шаг 6. Redis Cluster: зафиксировать Laravel-конфигурацию (и решить, что вы поддерживаете)

Это ключевой момент external-boilerplate: пользователи будут страдать не от Docker, а от “как правильно подключить Redis Cluster в Laravel”.

**Что нужно зафиксировать как часть шаблона**
1) Какой клиент вы ожидаете:
    - `phpredis` (предпочтительно для производительности)
    - или `predis/predis` (проще, но это composer-зависимость)
2) Где живёт конфиг:
    - в `config/database.php` (redis section)
3) Как вы задаёте список нод:
    - через одну переменную `REDIS_CLUSTER_NODES` (строка CSV), которую вы парсите в `config/database.php`.

**Рекомендация**
Для boilerplate лучше явно поддержать **один способ**, чтобы документация была чёткой:
- `REDIS_CLUSTER_NODES` как CSV → парсинг → массив нод.

---

## Шаг 7. Обновить `Makefile` под external

**Что делаем**
- Убираем команды, которые предполагают контейнер Postgres (`shell-postgres`, ожидание `pg_isready` в `setup`, `logs-postgres`, pgAdmin-цели).
- Добавляем команды “похожие на прод”:
    - `migrate-prodlike`: `docker compose ... run --rm migrate`
- Оставляем:
    - `up/down/build/logs/shell-php/shell-nginx/shell-node`
    - `artisan`/`composer`

**Идея**
Makefile должен перестать обещать “у нас есть Postgres внутри” — иначе это конфликтует с “external infra” позиционированием.

---

## Шаг 8. Документация (README + SETUP) — это 50% успеха external-boilerplate

**Что обязательно описать**
1) **Prerequisites**:
    - доступ к внешнему Postgres (как минимум host:port и креды)
    - доступ к внешнему Redis Cluster (список нод/пароль/TLS)
2) **Какие переменные нужно заполнить в `.env`** (таблица “переменная → что значит → пример”).
3) **Как запустить dev** (compose base+dev overlay).
4) **Как работает prod деплой**:
    - контейнеры поднимаются
    - миграции запускаются one-off job’ом
    - миграции не должны запускаться параллельно

---

## Шаг 9. CI/CD порядок (канон) для external-boilerplate

Так как вы используете include-шаблон в `.gitlab-ci.yml`, вы, вероятно, управляете деплоем через внешний шаблон/ansible. Но логика команд на сервере должна быть такой:

1) `pull` новых образов
2) `up -d` приложения
3) `run --rm migrate` (one-off)

**Защита от гонок**
- Деплой в одно окружение должен быть **строго последовательным** (1 job за раз).
- Если у вас несколько раннеров/параллельных деплоев — нужен environment lock.

---

## Контрольные проверки (на каждом этапе)

1) Dev:
- контейнеры стартуют без БД/Redis
- приложение падает “понятно”, если не настроен `.env` (это нормально)
- после задания внешних `DB_*` миграции выполняются

2) Prod:
- `migrate` job успешно подключается к внешней БД
- повторный запуск `migrate` не ломает (применяет только новые)

---

## Мини-уточнение (1 вопрос, чтобы план был “каноничным” на 100%)
Для external Redis Cluster вы хотите поддерживать по умолчанию:
1) **`phpredis` + Redis Cluster (нативно)**, или
2) **`predis` (composer) + cluster**?

От этого зависит, нужно ли вам:
- в PHP image гарантировать наличие `ext-redis` (phpredis), и
- какие ровно блоки документации/переменных делать “официальными”.

Если ответите — я в следующем сообщении могу дать “эталонную” схему переменных и кусок конфигурации Laravel (как именно парсить `REDIS_CLUSTER_NODES`), чтобы ваш external-boilerplate был реально plug-and-play.