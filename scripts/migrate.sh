#!/bin/bash
set -e  # Arrêter si erreur

echo "🚀 Début de la migration..."

# Vérifier les variables
if [ -z "$DEV_DATABASE_URL" ] || [ -z "$DEV_TEST_DATABASE_URL" ]; then
    echo "❌ Variables manquantes"
    exit 1
fi

echo "📊 Vérification de la connexion source..."
psql "$DEV_DATABASE_URL" -c "SELECT version();" > /dev/null
echo "✅ Connexion source OK"

echo "📊 Vérification de la connexion destination..."
psql "$DEV_TEST_DATABASE_URL" -c "SELECT version();" > /dev/null
echo "✅ Connexion destination OK"

echo "🗃️ Export des données depuis DEV..."
pg_dump "$DEV_DATABASE_URL" \
    --verbose \
    --no-owner \
    --no-privileges \
    --clean \
    --if-exists > backup.sql

echo "📁 Taille du backup: $(ls -lh backup.sql | awk '{print $5}')"

echo "🔄 Import vers DEV-HDS..."
psql "$DEV_TEST_DATABASE_URL" < backup.sql

echo "🧹 Nettoyage..."
rm backup.sql

echo "✅ Migration terminée avec succès !"