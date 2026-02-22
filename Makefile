# ==========================================
# Laravel PHP-FPM Nginx Socket (Boilerplate)
# ==========================================

.PHONY: help up down restart build rebuild logs status shell-php shell-nginx clean setup artisan migrate

# Цвета для вывода
YELLOW=\033[0;33m
GREEN=\033[0;32m
RED=\033[0;31m
NC=\033[0m

# Переменные Compose (используем merge для разработки)
COMPOSE_DEV = docker compose -f docker-compose.yml -f docker-compose.dev.yml
COMPOSE_PROD = docker compose -f docker-compose.yml -f docker-compose.prod.yml
COMPOSE = $(COMPOSE_DEV)

# Сервисы (имена сервисов из compose-файлов)
PHP_SERVICE=laravel-php-nginx-socket
NGINX_SERVICE=laravel-nginx-socket
NODE_SERVICE=laravel-node-nginx-socket

help: ## Показать справку
	@echo "$(YELLOW)Laravel Docker Boilerplate (Unix Socket)$(NC)"
	@echo "======================================"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "$(GREEN)%-20s$(NC) %s\n", $$1, $$2}'

check-files: ## Проверить наличие всех необходимых файлов
	@echo "$(YELLOW)Проверка файлов конфигурации...$(NC)"
	@test -f docker-compose.yml || (echo "$(RED)✗ docker-compose.yml не найден$(NC)" && exit 1)
	@test -f docker-compose.dev.yml || (echo "$(RED)✗ docker-compose.dev.yml не найден$(NC)" && exit 1)
	@test -f docker-compose.prod.yml || (echo "$(RED)✗ docker-compose.prod.yml не найден$(NC)" && exit 1)
	@test -f .env || (echo "$(RED)✗ .env не найден. Убедитесь, что вы настроили проект Laravel$(NC)" && exit 1)
	@test -f docker/php.Dockerfile || (echo "$(RED)✗ docker/php.Dockerfile не найден$(NC)" && exit 1)
	@test -f docker/nginx.Dockerfile || (echo "$(RED)✗ docker/nginx.Dockerfile не найден$(NC)" && exit 1)
	@test -f docker/nginx/conf.d/laravel.conf || (echo "$(RED)✗ docker/nginx/conf.d/laravel.conf не найден$(NC)" && exit 1)
	@test -f docker/php/php.ini || (echo "$(RED)✗ docker/php/php.ini не найден$(NC)" && exit 1)
	@test -f docker/php/www.conf || (echo "$(RED)✗ docker/php/www.conf не найден$(NC)" && exit 1)
	@echo "$(GREEN)✓ Все файлы на месте$(NC)"

up: check-files ## Запустить контейнеры (Dev)
	$(COMPOSE) up -d
	@echo "$(GREEN)✓ Проект запущен на http://localhost$(NC)"

up-prod: check-files ## Запустить контейнеры (Prod)
	$(COMPOSE_PROD) up -d
	@echo "$(GREEN)✓ Проект (Prod) запущен$(NC)"

down: ## Остановить контейнеры
	$(COMPOSE) down

restart: ## Перезапустить контейнеры
	$(COMPOSE) restart

build: ## Собрать образы (Dev)
	$(COMPOSE) build

rebuild: ## Пересобрать образы без кэша (Dev)
	$(COMPOSE) build --no-cache

logs: ## Показать логи
	$(COMPOSE) logs -f

logs-php: ## Просмотр логов PHP-FPM
	$(COMPOSE) logs -f $(PHP_SERVICE)

logs-nginx: ## Просмотр логов Nginx
	$(COMPOSE) logs -f $(NGINX_SERVICE)

logs-node: ## Просмотр логов Node (HMR)
	$(COMPOSE) logs -f $(NODE_SERVICE)

status: ## Статус контейнеров
	$(COMPOSE) ps

shell-php: ## Войти в контейнер PHP
	$(COMPOSE) exec $(PHP_SERVICE) sh

shell-nginx: ## Подключиться к контейнеру Nginx
	$(COMPOSE) exec $(NGINX_SERVICE) sh

shell-node: ## Подключиться к контейнеру Node
	$(COMPOSE) exec $(NODE_SERVICE) sh

# --- Команды Laravel ---
setup: ## Полная инициализация проекта с нуля (без internal infra)
	@make build
	@make up
	@make install-deps
	@make artisan CMD="key:generate"
	@make migrate
	@make permissions
	@make cleanup-nginx
	@echo "$(GREEN)✓ Проект готов: http://localhost$(NC)"

install-deps: ## Установка всех зависимостей (Composer + NPM)
	@echo "$(YELLOW)Установка зависимостей...$(NC)"
	@$(MAKE) composer-install
	@$(MAKE) npm-install

# --- Команды Composer ---
composer-install: ## Установить зависимости через Composer
	$(COMPOSE) exec $(PHP_SERVICE) composer install

composer-update: ## Обновить зависимости через Composer
	$(COMPOSE) exec $(PHP_SERVICE) composer update

composer-require: ## Установить пакет через Composer (make composer-require PACKAGE=vendor/package)
	$(COMPOSE) exec $(PHP_SERVICE) composer require $(PACKAGE)

npm-install: ## Установить NPM зависимости
	$(COMPOSE) exec $(NODE_SERVICE) npm install

npm-dev: ## Запустить Vite в режиме разработки (hot reload)
	$(COMPOSE) exec $(NODE_SERVICE) npm run dev

npm-build: ## Собрать фронтенд (внутри PHP контейнера для prod-like билда или dev)
	$(COMPOSE) exec $(NODE_SERVICE) npm run build

artisan: ## Запустить команду artisan (make artisan CMD="migrate")
	$(COMPOSE) exec $(PHP_SERVICE) php artisan $(CMD)

composer: ## Запустить команду composer (make composer CMD="install")
	$(COMPOSE) exec $(PHP_SERVICE) composer $(CMD)

migrate: ## Запустить миграции
	$(COMPOSE) exec $(PHP_SERVICE) php artisan migrate

rollback: ## Откатить миграции
	$(COMPOSE) exec $(PHP_SERVICE) php artisan migrate:rollback

fresh: ## Пересоздать базу и запустить сиды
	$(COMPOSE) exec $(PHP_SERVICE) php artisan migrate:fresh --seed

tinker: ## Запустить Laravel Tinker
	$(COMPOSE) exec $(PHP_SERVICE) php artisan tinker

test-php: ## Запустить тесты PHP (PHPUnit)
	$(COMPOSE) exec $(PHP_SERVICE) php artisan test

permissions: ## Исправить права доступа для Laravel (storage/cache)
	@echo "$(YELLOW)Исправление прав доступа...$(NC)"
	$(COMPOSE) exec $(PHP_SERVICE) sh -c "if [ -d storage ]; then chown -R www-data:www-data storage bootstrap/cache && chmod -R ug+rwX storage bootstrap/cache; fi"
	@echo "$(GREEN)✓ Права доступа исправлены$(NC)"

cleanup-nginx: ## Удалить .htaccess (не нужен для Nginx)
	@echo "$(YELLOW)Удаление .htaccess (не используется с Nginx)...$(NC)"
	@if [ -f public/.htaccess ]; then \
		rm public/.htaccess && echo "$(GREEN)✓ .htaccess удален$(NC)"; \
	else \
		echo "$(GREEN)✓ .htaccess уже отсутствует$(NC)"; \
	fi

clean: ## Удалить контейнеры и тома
	$(COMPOSE) down -v
	@echo "$(RED)! Контейнеры и тома удалены$(NC)"

clean-all: ## Полная очистка (контейнеры, образы, тома)
	@echo "$(YELLOW)Полная очистка...$(NC)"
	$(COMPOSE) down -v --rmi all
	@echo "$(GREEN)✓ Выполнена полная очистка$(NC)"

dev-reset: clean-all build up ## Сброс среды разработки
	@echo "$(GREEN)✓ Среда разработки сброшена и перезапущена!$(NC)"

.DEFAULT_GOAL := help