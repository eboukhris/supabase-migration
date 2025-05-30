#!/bin/bash
set -e

echo "🔍 Vérification post-migration..."

# Compter les tables
SOURCE_TABLES=$(psql "$DEV_DATABASE_URL" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';")
TARGET_TABLES=$(psql "$DEV_HDS_DATABASE_URL" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';")

echo "📊 Nombre de tables - Source: $SOURCE_TABLES, Destination: $TARGET_TABLES"

if [ "$SOURCE_TABLES" -eq "$TARGET_TABLES" ]; then
    echo "✅ Nombre de tables OK"
else
    echo "⚠️ Différence dans le nombre de tables"
fi

# Lister les tables pour comparaison
echo "📋 Tables dans DEV-HDS:"
psql "$DEV_HDS_DATABASE_URL" -c "\dt"