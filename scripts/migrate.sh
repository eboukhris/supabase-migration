#!/bin/bash
# scripts/migrate.sh - Version incrémentale
set -e

echo "🚀 Début de la migration incrémentale..."

# Vérifier les variables
if [ -z "$DEV_DATABASE_URL" ] || [ -z "$DEV_TEST_DATABASE_URL" ]; then
    echo "❌ Variables manquantes"
    exit 1
fi

echo "📊 Vérification des connexions..."
psql "$DEV_DATABASE_URL" -c "SELECT version();" > /dev/null
echo "✅ Connexion source OK"

psql "$DEV_TEST_DATABASE_URL" -c "SELECT version();" > /dev/null
echo "✅ Connexion destination OK"

# Créer un fichier de log pour tracer les opérations
LOG_FILE="migration_$(date +%Y%m%d_%H%M%S).log"

echo "📋 Analyse des différences entre source et destination..."

# Comparer les structures de tables
echo "🔍 Comparaison des structures..." | tee -a $LOG_FILE

# Obtenir la liste des tables de chaque côté
psql "$DEV_DATABASE_URL" -t -c "
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'public' 
ORDER BY table_name;" > source_tables.txt

psql "$DEV_TEST_DATABASE_URL" -t -c "
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'public' 
ORDER BY table_name;" > target_tables.txt

# Nettoyer les espaces
sed -i 's/^[[:space:]]*//' source_tables.txt target_tables.txt
sed -i '/^$/d' source_tables.txt target_tables.txt

# Comparer les listes
echo "📊 Tables source: $(wc -l < source_tables.txt)" | tee -a $LOG_FILE
echo "📊 Tables destination: $(wc -l < target_tables.txt)" | tee -a $LOG_FILE

# Tables manquantes dans la destination
comm -23 source_tables.txt target_tables.txt > missing_tables.txt
MISSING_COUNT=$(wc -l < missing_tables.txt)

if [ $MISSING_COUNT -gt 0 ]; then
    echo "📋 $MISSING_COUNT tables manquantes dans la destination:" | tee -a $LOG_FILE
    cat missing_tables.txt | tee -a $LOG_FILE
    
    echo "🔧 Création des tables manquantes..." | tee -a $LOG_FILE
    
    # Exporter et importer seulement les nouvelles tables
    while IFS= read -r table_name; do
        if [ ! -z "$table_name" ]; then
            echo "📦 Export de la table: $table_name" | tee -a $LOG_FILE
            
            # Exporter la structure ET les données de la table manquante
            pg_dump "$DEV_DATABASE_URL" \
                --verbose \
                --no-owner \
                --no-privileges \
                --table="public.$table_name" > "table_${table_name}.sql"
            
            # Importer la table
            echo "📥 Import de la table: $table_name" | tee -a $LOG_FILE
            psql "$DEV_TEST_DATABASE_URL" < "table_${table_name}.sql" || {
                echo "❌ Erreur lors de l'import de $table_name" | tee -a $LOG_FILE
            }
            
            rm "table_${table_name}.sql"
        fi
    done < missing_tables.txt
else
    echo "✅ Toutes les tables existent déjà dans la destination" | tee -a $LOG_FILE
fi

# Pour les tables existantes, faire une synchronisation incrémentale
echo "🔄 Synchronisation incrémentale des données..." | tee -a $LOG_FILE

# Tables communes
comm -12 source_tables.txt target_tables.txt > common_tables.txt

# Fonction pour synchroniser une table
sync_table_data() {
    local table_name=$1
    echo "🔄 Synchronisation: $table_name" | tee -a $LOG_FILE
    
    # Vérifier si la table a une clé primaire
    PRIMARY_KEY=$(psql "$DEV_DATABASE_URL" -t -c "
        SELECT column_name 
        FROM information_schema.key_column_usage 
        WHERE table_name = '$table_name' 
        AND constraint_name LIKE '%_pkey'
        LIMIT 1;
    " | xargs)
    
    if [ ! -z "$PRIMARY_KEY" ]; then
        echo "  🔑 Clé primaire détectée: $PRIMARY_KEY" | tee -a $LOG_FILE
        
        # Export avec UPSERT (INSERT ... ON CONFLICT)
        cat > sync_${table_name}.sql << EOF
-- Synchronisation de la table $table_name
BEGIN;

-- Désactiver temporairement les triggers pour éviter les conflits
SET session_replication_role = replica;

-- Insérer ou mettre à jour les données
INSERT INTO public.$table_name 
SELECT * FROM dblink(
    '$DEV_DATABASE_URL',
    'SELECT * FROM public.$table_name'
) AS t1($(psql "$DEV_DATABASE_URL" -t -c "
    SELECT string_agg(column_name || ' ' || data_type, ', ')
    FROM information_schema.columns 
    WHERE table_name = '$table_name' 
    AND table_schema = 'public'
    ORDER BY ordinal_position;
"))
ON CONFLICT ($PRIMARY_KEY) DO UPDATE SET
$(psql "$DEV_DATABASE_URL" -t -c "
    SELECT string_agg(column_name || ' = EXCLUDED.' || column_name, ', ')
    FROM information_schema.columns 
    WHERE table_name = '$table_name' 
    AND table_schema = 'public'
    AND column_name != '$PRIMARY_KEY'
    ORDER BY ordinal_position;
");

-- Réactiver les triggers
SET session_replication_role = DEFAULT;

COMMIT;
EOF
        
        # Méthode alternative plus simple si dblink ne fonctionne pas
        if ! psql "$DEV_TEST_DATABASE_URL" < sync_${table_name}.sql 2>/dev/null; then
            echo "  ⚠️ Méthode dblink échouée, utilisation du dump..." | tee -a $LOG_FILE
            
            # Export des données seulement
            pg_dump "$DEV_DATABASE_URL" \
                --data-only \
                --no-owner \
                --no-privileges \
                --table="public.$table_name" \
                --on-conflict-do-nothing > data_${table_name}.sql
            
            psql "$DEV_TEST_DATABASE_URL" < data_${table_name}.sql || {
                echo "  ❌ Erreur sync $table_name, mais on continue..." | tee -a $LOG_FILE
            }
            rm data_${table_name}.sql
        fi
        
        rm sync_${table_name}.sql
    else
        echo "  ⚠️ Pas de clé primaire, sync basique..." | tee -a $LOG_FILE
        
        # Pour tables sans clé primaire, on vide et recharge
        psql "$DEV_TEST_DATABASE_URL" -c "TRUNCATE TABLE public.$table_name CASCADE;" || true
        
        pg_dump "$DEV_DATABASE_URL" \
            --data-only \
            --no-owner \
            --no-privileges \
            --table="public.$table_name" > data_${table_name}.sql
        
        psql "$DEV_TEST_DATABASE_URL" < data_${table_name}.sql || {
            echo "  ❌ Erreur sync $table_name" | tee -a $LOG_FILE
        }
        rm data_${table_name}.sql
    fi
}

# Synchroniser toutes les tables communes
if [ -s common_tables.txt ]; then
    while IFS= read -r table_name; do
        if [ ! -z "$table_name" ]; then
            sync_table_data "$table_name"
        fi
    done < common_tables.txt
fi

# Synchroniser les séquences
echo "🔢 Synchronisation des séquences..." | tee -a $LOG_FILE
psql "$DEV_DATABASE_URL" -t -c "
SELECT 'SELECT setval(''' || schemaname||'.'||sequencename ||''', '|| last_value || ');'
FROM pg_sequences WHERE schemaname = 'public';
" > sequences.sql

if [ -s sequences.sql ]; then
    psql "$DEV_TEST_DATABASE_URL" < sequences.sql
    echo "✅ Séquences synchronisées" | tee -a $LOG_FILE
fi

# Nettoyage
rm -f source_tables.txt target_tables.txt missing_tables.txt common_tables.txt sequences.sql

echo "✅ Migration incrémentale terminée avec succès !" | tee -a $LOG_FILE
echo "📋 Log détaillé: $LOG_FILE"