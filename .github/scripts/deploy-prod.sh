#!/bin/bash
set -e

echo "🚀 Starting Production Deployment..."

# =============================
#  0️⃣ Environment Variables Check
# =============================
[ -z "$DOCKER_IMAGE" ] && { echo "❌ Error: DOCKER_IMAGE not defined."; exit 1; }
[ -z "$CONTAINER_NAME" ] && { echo "❌ Error: CONTAINER_NAME not defined."; exit 1; }
[ -z "$DATABASE_URL" ] && { echo "❌ Error: DATABASE_URL not defined."; exit 1; }

echo "ℹ️ Docker image: $DOCKER_IMAGE"
echo "ℹ️ Container name: $CONTAINER_NAME"

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
  -e APP_ENV=prod \
  -e APP_DEBUG=0 \
  -e DATABASE_URL="$DATABASE_URL" \
  -p 9000:80 \
  $DOCKER_IMAGE:latest

# =============================
#  4️⃣ Wait for Container Readiness
# =============================
echo "🕐 Checking container startup..."
for i in {1..10}; do
  if docker exec $CONTAINER_NAME php -v >/dev/null 2>&1; then
    echo "✅ Container is ready."
    break
  fi
  echo "⏳ Waiting for container... ($i/10)"
  sleep 3
done

# =============================
#  5️⃣ Run Database Migrations
# =============================
echo "⚙️ Running database migrations..."
docker exec $CONTAINER_NAME php bin/console doctrine:database:create --if-not-exists --env=prod
docker exec $CONTAINER_NAME php bin/console doctrine:migrations:migrate --env=prod --no-interaction
echo "✅ Database is ready and migrations have been applied."

# =============================
#  6️⃣ Cleanup Old Docker Images
# =============================
echo "🧹 Cleaning up old Docker images..."
docker image prune -f
echo "✅ Old Docker images cleaned up."

# =============================
#  7️⃣ Deployment Complete
# =============================
echo "🎉 Production deployment completed successfully!"
exit 0
