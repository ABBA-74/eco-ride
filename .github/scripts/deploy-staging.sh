#!/bin/bash
set -e

echo "🚀 Starting Staging Deployment..."


# =============================
#  0️⃣ Environment Variables Check
# =============================
[ -z "$DOCKER_IMAGE" ] && { echo "❌ Error: DOCKER_IMAGE not defined."; exit 1; }
[ -z "$CONTAINER_NAME" ] && { echo "❌ Error: CONTAINER_NAME not defined."; exit 1; }

APP_DIR="/var/www/ecoride"
ENV_FILE="$APP_DIR/.env.staging"
COMPOSE_FILE="$APP_DIR/compose.staging.yaml"

if [ ! -f "$ENV_FILE" ]; then
  echo "❌ Error: $ENV_FILE not found!"
  exit 1
fi

echo "ℹ️ Docker Image: $DOCKER_IMAGE"
echo "ℹ️ Container: $CONTAINER_NAME"
echo "ℹ️ Env File: $ENV_FILE"
echo "ℹ️ Compose File: $COMPOSE_FILE"
echo "ℹ️ Fixtures: ${LOAD_FIXTURES:-false}"

cd "$APP_DIR"

COMPOSE_CMD="docker compose --env-file $ENV_FILE -f $COMPOSE_FILE"

# =============================
#  0️⃣ Cleanup legacy container
# =============================
echo "🧹 Removing legacy container (if exists)..."
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true
echo "✅ Legacy container removed."


# =============================
#  1️⃣ Pull latest image
# =============================
echo "🐳 Pulling latest image for app_staging..."
$COMPOSE_CMD pull app_staging


# =============================
#  2️⃣ Stop previous stack
# =============================
echo "🛑 Stopping previous stack..."
$COMPOSE_CMD down || true
echo "✅ Previous stack stopped."


# =============================
#  3️⃣ Start database only
# =============================
echo "🗄️ Starting database_staging..."
$COMPOSE_CMD up -d database_staging

echo "⏳ Waiting for database to be healthy..."
for i in {1..10}; do
  STATUS=$(docker inspect -f '{{.State.Health.Status}}' ecoride_db_staging 2>/dev/null || echo "unknown")
  if [ "$STATUS" = "healthy" ]; then
    echo "✅ Database is healthy."
    break
  fi
  echo "⏳ DB status: $STATUS ($i/10)"
  sleep 3
done

STATUS=$(docker inspect -f '{{.State.Health.Status}}' ecoride_db_staging 2>/dev/null || echo "unknown")
if [ "$STATUS" != "healthy" ]; then
  echo "❌ Database is not healthy (status: $STATUS). Aborting."
  exit 1
fi


# =============================
#  4️⃣ Start app + web containers
# =============================
echo "🚀 Starting app_staging and web_staging..."
$COMPOSE_CMD up -d app_staging web_staging

echo "🕐 Checking app_staging startup.."
for i in {1..10}; do
  if $COMPOSE_CMD exec -T app_staging php -v >/dev/null 2>&1; then
    echo "✅ App container is ready."
    break
  fi
  echo "⏳ Waiting for app... ($i/10)"
  sleep 3
done

if ! $COMPOSE_CMD exec -T app_staging php -v >/dev/null 2>&1; then
  echo "❌ App container did not start correctly."
  $COMPOSE_CMD logs app_staging || true
  exit 1
fi

echo "📄 Ensuring .env exists inside app container..."
$COMPOSE_CMD exec -T app_staging sh -lc 'if [ ! -f .env ]; then echo "# dummy env for Symfony (staging uses real env vars)" > .env; fi'


# =============================
#  5️⃣ Create DB & run migrations (staging)
# =============================
echo "🗄️ Creating database (if not exists)..."
$COMPOSE_CMD exec -T app_staging php bin/console doctrine:database:create --if-not-exists --env=staging

echo "🚧 Running migrations..."
$COMPOSE_CMD exec -T app_staging php bin/console doctrine:migrations:migrate --env=staging --no-interaction

echo "✅ Database ready & migrations applied."


# =============================
#  6️⃣ Fixtures
# =============================
if [ "$LOAD_FIXTURES" = "true" ]; then
  echo "📥 Loading fixtures..."
  $COMPOSE_CMD exec -T app_staging php bin/console doctrine:fixtures:load --env=staging --no-interaction
  echo "✅ Fixtures loaded."
else
  echo "⏩ Fixtures disabled, skipping."
fi


# =============================
#  7️⃣ Clear cache
# =============================
echo "🧹 Clearing cache..."
$COMPOSE_CMD exec -T app_staging php bin/console cache:clear --env=staging --no-interaction
$COMPOSE_CMD exec -T app_staging php bin/console cache:warmup --env=staging --no-interaction

# =============================
#  8️⃣ Cleanup old images
# =============================
echo "🧹 Cleaning up old Docker images..."
docker image prune -f || true

# ============================
#  9️⃣ HTTP health check
# ============================
echo "🌐 Testing HTTP endpoint (http://localhost:9001)..."
if curl -sSf http://localhost:9001 > /dev/null; then
  echo "✅ Application responded successfully over HTTP"
else
  echo "❌ Application did not respond over HTTP"
  $COMPOSE_CMD logs app_staging || true
  exit 1
fi

echo "🎉 Staging deployment completed successfully!"
exit 0
