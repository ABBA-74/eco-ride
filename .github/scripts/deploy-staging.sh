#!/bin/bash
set -e

echo "🚀 Starting Staging Deployment..."

# =============================
#  0️⃣ Environment Variables Check
# =============================
[ -z "$DOCKER_IMAGE" ] && { echo "❌ Error: DOCKER_IMAGE not defined."; exit 1; }
[ -z "$CONTAINER_NAME" ] && { echo "❌ Error: CONTAINER_NAME not defined."; exit 1; }
[ -z "$DATABASE_URL" ] && { echo "❌ Error: DATABASE_URL not defined."; exit 1; }

echo "ℹ️ Docker Image: $DOCKER_IMAGE"
echo "ℹ️ Container: $CONTAINER_NAME"
echo "ℹ️ Fixtures: ${LOAD_FIXTURES:-false}"

# =============================
#  1️⃣ Retrieve Latest Docker Image
# =============================
echo "🐳 Pulling the latest Docker image..."
docker pull "$DOCKER_IMAGE:latest"

# =============================
#  2️⃣ Stop & Clean Previous Container
# =============================
docker stop $CONTAINER_NAME || true
docker rm $CONTAINER_NAME || true

echo "✅ Previous container stopped and removed."

# =============================
#  3️⃣ Launch New Container
# =============================
echo "🚀 Launching new container..."
docker run -d --name $CONTAINER_NAME \
  --restart always \
  -e APP_ENV=staging \
  -e APP_DEBUG=0 \
  -e DATABASE_URL="$DATABASE_URL" \
  -p 9001:80 \
  $DOCKER_IMAGE:latest

echo "🕐 Checking container startup..."
for i in {1..10}; do
  if docker exec $CONTAINER_NAME php -v >/dev/null 2>&1; then
    echo "✅ Container is ready."
    break
  fi
  echo "⏳ Waiting for container... ($i/10)"
  sleep 3
done

# If still not ready, exit with error
if ! docker exec $CONTAINER_NAME php -v >/dev/null 2>&1; then
  echo "❌ Container did not start successfully after 10 attempts."
  docker logs $CONTAINER_NAME
  exit 1
fi

# =============================
#  4️⃣ Create Database & Run Migrations
# =============================
docker exec $CONTAINER_NAME php bin/console doctrine:database:create --if-not-exists --env=staging
docker exec $CONTAINER_NAME php bin/console doctrine:migrations:migrate --env=staging --no-interaction

echo "✅ Database is ready and migrations have been applied."

# =============================
#  5️⃣ Fixtures
# =============================
if [ "$LOAD_FIXTURES" = "true" ]; then
  docker exec $CONTAINER_NAME php bin/console doctrine:fixtures:load --env=staging --no-interaction

  echo "✅ Fixtures loaded successfully."
else
  echo "⏩ Fixtures disabled, skipping."
fi

# =============================
#  6️⃣ Clear Cache
# =============================
echo "🧹 Clearing application cache..."
docker exec $CONTAINER_NAME php bin/console cache:clear --env=staging --no-interaction
docker exec $CONTAINER_NAME php bin/console cache:warmup --env=staging --no-interaction

# =============================
#  7️⃣ Cleanup Old Images
# =============================
echo "🧹 Cleaning up old Docker images..."
docker image prune -f
echo "✅ Old images cleaned up."

# ============================
#  Test HTTP Endpoint
# ============================
echo "🌐 Testing HTTP endpoint..."
if curl -sSf http://localhost:9001 > /dev/null; then
  echo "✅ Application responded successfully over HTTP"
else
  echo "❌ Application did not respond over HTTP"
  docker logs $CONTAINER_NAME
  exit 1
fi

# =============================
#  Deployment Complete
# =============================
echo "🎉 Staging deployment completed successfully!"
exit 0
