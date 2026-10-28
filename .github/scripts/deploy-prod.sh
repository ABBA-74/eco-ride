#!/usr/bin/env bash
set -Eeuo pipefail

echo "🚀 Starting Ecoride Production Deployment..."

APP_DIR="/var/www/ecoride"
COMPOSE_FILE="$APP_DIR/compose.prod.yaml"
ENV_FILE="$APP_DIR/.env.prod"

# =============================
# 1. Prerequisite checks
# =============================
for file in "$COMPOSE_FILE" "$ENV_FILE" "$APP_DIR/docker/nginx/prod.conf"; do
    if [ ! -f "$file" ]; then
        echo "❌ Missing required file: $file"
        exit 1
    fi
done

cd "$APP_DIR"

compose() {
    docker compose \
        --env-file "$ENV_FILE" \
        -f "$COMPOSE_FILE" \
        "$@"
}

echo "🔍 Validating Docker Compose configuration..."
compose config --quiet

# =============================
# 2. Pull images
# =============================
echo "🐳 Pulling production images..."
compose pull app_prod database_prod web_prod

# =============================
# 3. Start PostgreSQL
# =============================
echo "🗄️ Starting PostgreSQL..."
compose up -d database_prod

echo "⏳ Waiting for PostgreSQL health check..."

DB_READY=false

for i in {1..30}; do
    STATUS=$(docker inspect \
        --format '{{.State.Health.Status}}' \
        ecoride_db_prod 2>/dev/null || echo "unknown")

    if [ "$STATUS" = "healthy" ]; then
        DB_READY=true
        break
    fi

    echo "⏳ PostgreSQL: $STATUS ($i/30)"
    sleep 3
done

if [ "$DB_READY" != "true" ]; then
    echo "❌ PostgreSQL is not healthy."
    compose logs --tail=50 database_prod
    exit 1
fi

echo "✅ PostgreSQL is healthy."

# =============================
# 4. Remove legacy Docker container
# =============================
# The previous deployment used docker run with
# the same container name as the new Compose service.

if docker ps -a --format '{{.Names}}' | grep -Fxq "ecoride_app_prod"; then
    COMPOSE_PROJECT=$(docker inspect \
        --format '{{index .Config.Labels "com.docker.compose.project"}}' \
        ecoride_app_prod 2>/dev/null || true)

    if [ -z "$COMPOSE_PROJECT" ] || [ "$COMPOSE_PROJECT" = "<no value>" ]; then
        echo "🧹 Removing legacy Docker container..."
        docker stop ecoride_app_prod
        docker rm ecoride_app_prod
    elif [ "$COMPOSE_PROJECT" != "ecoride-prod" ]; then
        echo "❌ Container belongs to another Compose project: $COMPOSE_PROJECT"
        exit 1
    else
        echo "✅ Production container already managed by Docker Compose."
    fi
fi

# =============================
# 5. Start Symfony
# =============================
echo "🚀 Starting Symfony..."
compose up -d --no-deps app_prod

echo "⏳ Checking Symfony startup..."

APP_READY=false

for i in {1..20}; do
    if compose exec -T app_prod php bin/console --version >/dev/null 2>&1; then
        APP_READY=true
        break
    fi

    echo "⏳ Symfony startup ($i/20)"
    sleep 3
done

if [ "$APP_READY" != "true" ]; then
    echo "❌ Symfony failed to start."
    compose logs --tail=50 app_prod
    exit 1
fi

echo "✅ Symfony is ready."

# =============================
# 6. Database migrations
# =============================
echo "⚙️ Running Doctrine migrations..."

compose exec -T app_prod \
    php bin/console doctrine:migrations:migrate \
    --env=prod \
    --no-interaction

echo "✅ Migrations completed."

# =============================
# 7. Importmap and assets
# =============================
echo "📦 Installing Importmap dependencies..."

compose exec -T app_prod \
    php bin/console importmap:install \
    --env=prod \
    --no-interaction

echo "🎨 Compiling Symfony assets..."

compose exec -T app_prod \
    php bin/console asset-map:compile \
    --env=prod

# =============================
# 8. Symfony cache
# =============================
echo "🧹 Clearing Symfony cache..."

compose exec -T app_prod \
    php bin/console cache:clear \
    --env=prod \
    --no-interaction

compose exec -T app_prod \
    php bin/console cache:warmup \
    --env=prod \
    --no-interaction

# =============================
# 9. Synchronize public files
# =============================
echo "📁 Synchronizing public files to Nginx volume..."

compose exec -T -u 0 app_prod sh -ec '
    # Verify Symfony public directory
    test -f /app/public/index.php

    # Prepare shared directory
    mkdir -p /shared-public

    # Copy public files and compiled assets
    cp -a /app/public/. /shared-public/

    # Verify synchronization
    test -f /shared-public/index.php
    test -d /shared-public/assets
'

echo "✅ Public files synchronized and verified."

# =============================
# 10. Start Nginx
# =============================
echo "🌐 Starting production Nginx..."

compose up -d --no-deps web_prod

# =============================
# 11. HTTP health check
# =============================
echo "🔎 Testing production on localhost:9002..."

HTTP_READY=false

for i in {1..15}; do
    if curl --silent --show-error --fail \
        --max-time 5 \
        http://127.0.0.1:9002/ \
        >/dev/null 2>&1;
        then
        HTTP_READY=true
        break
    fi

    echo "⏳ HTTP check ($i/15)"
    sleep 3
done

if [ "$HTTP_READY" != "true" ]; then
    echo "❌ HTTP health check failed."
    compose logs --tail=50 web_prod app_prod
    exit 1
fi

echo "✅ Production HTTP check passed."
echo "🎉 Ecoride Production Docker deployment completed!"
echo "ℹ️ Public domain remains unchanged until Nginx cutover."
