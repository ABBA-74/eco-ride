#!/bin/bash
set -e

echo "🚀 Démarrage du déploiement Staging..."

# =============================
#  ENVIRONNEMENT CHECK
# =============================
[ -z "$DOCKER_IMAGE" ] && { echo "❌ Erreur: DOCKER_IMAGE non défini."; exit 1; }
[ -z "$CONTAINER_NAME" ] && { echo "❌ Erreur: CONTAINER_NAME non défini."; exit 1; }
[ -z "$DATABASE_URL" ] && { echo "❌ Erreur: DATABASE_URL non défini."; exit 1; }

echo "ℹ️ Image Docker : $DOCKER_IMAGE"
echo "ℹ️ Conteneur : $CONTAINER_NAME"
echo "ℹ️ Fixtures : ${LOAD_FIXTURES:-false}"

# =============================
#  1️⃣ Stop & clean previous container
# =============================
docker stop $CONTAINER_NAME || true
docker rm $CONTAINER_NAME || true

echo "✅ Conteneur précédent arrêté et supprimé."


# =============================
#  2️⃣ Launch new container
# =============================
docker run -d --name $CONTAINER_NAME \
  -e APP_ENV=staging \
  -e APP_DEBUG=0 \
  -e DATABASE_URL="$DATABASE_URL" \
  -p 9001:80 \
  $DOCKER_IMAGE:latest

echo "🕐 Attente du démarrage du conteneur..."
sleep 10

# =============================
#  3️⃣ Create DB & run migrations
# =============================
docker exec $CONTAINER_NAME php bin/console doctrine:database:create --if-not-exists --env=staging
docker exec $CONTAINER_NAME php bin/console doctrine:migrations:migrate --env=staging --no-interaction

echo "✅ Base de données prête et migrations appliquées."

# =============================
#  4️⃣ Fixtures (optional)
# =============================
if [ "$LOAD_FIXTURES" = "true" ]; then
  docker exec $CONTAINER_NAME php bin/console doctrine:fixtures:load --env=staging --no-interaction

  echo "✅ Fixtures chargées avec succès."
else
  echo "⏩ Fixtures désactivées"
fi

echo "✅ Déploiement terminé avec succès !"
