#!/bin/bash
set -e

echo "🔍 Vérification post-migration..."

# Compter les tables
SOURCE_TABLES=$(psql "$DEV_DATABASE_URL" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" | xargs)
TARGET_TABLES=$(psql "$DEV_TEST_DATABASE_URL" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" | xargs)

echo "📊 Nombre de tables - Source: $SOURCE_TABLES, Destination: $TARGET_TABLES"

if [ "$SOURCE_TABLES" -eq "$TARGET_TABLES" ]; then
    echo "✅ Nombre de tables OK"
else
    echo "⚠️ Différence dans le nombre de tables"
fi

echo ""
echo "📋 Vérification des lignes dans chaque table..."

TABLES=$(psql "$DEV_DATABASE_URL" -t -c "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public';" | xargs)

for TABLE in $TABLES; do
    SRC_COUNT=$(psql "$DEV_DATABASE_URL" -t -c "SELECT COUNT(*) FROM \"$TABLE\";" | xargs)
    DST_COUNT=$(psql "$DEV_TEST_DATABASE_URL" -t -c "SELECT COUNT(*) FROM \"$TABLE\";" | xargs)
    if [ "$SRC_COUNT" -eq "$DST_COUNT" ]; then
        echo "✅ [$TABLE] $SRC_COUNT lignes - OK"
    else
        echo "⚠️ [$TABLE] Différence de lignes: source=$SRC_COUNT, destination=$DST_COUNT"
    fi
done

echo ""
echo "🔍 Vérification des fonctions..."

SRC_FUNCS=$(psql "$DEV_DATABASE_URL" -t -c "SELECT routine_name, routine_type FROM information_schema.routines WHERE routine_schema = 'public' ORDER BY routine_name;" | sed 's/^ *//')
DST_FUNCS=$(psql "$DEV_TEST_DATABASE_URL" -t -c "SELECT routine_name, routine_type FROM information_schema.routines WHERE routine_schema = 'public' ORDER BY routine_name;" | sed 's/^ *//')

if [ "$SRC_FUNCS" == "$DST_FUNCS" ]; then
    echo "✅ Fonctions synchronisées"
else
    echo "⚠️ Différence dans les fonctions"
    echo "🔎 Fonctions dans Source:"
    echo "$SRC_FUNCS"
    echo "🔎 Fonctions dans Destination:"
    echo "$DST_FUNCS"
fi
