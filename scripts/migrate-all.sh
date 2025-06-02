#!/bin/bash
# scripts/migrate.sh - Migration incrémentale SLTP (ne touche pas la base source)
set -euo pipefail

echo "🚀 Début de la migration incrémentale SLTP..."

# Fonction pour convertir une URI PostgreSQL en chaîne de connexion libpq compatible dblink
function parse_pg_uri() {
  local uri=$1
  if [[ $uri =~ postgresql://([^:]+):([^@]+)@([^:/]+):([0-9]+)/(.+) ]]; then
    local user="${BASH_REMATCH[1]}"
    local pass="${BASH_REMATCH[2]}"
    local host="${BASH_REMATCH[3]}"
    local port="${BASH_REMATCH[4]}"
    local dbname="${BASH_REMATCH[5]}"
    # Attention aux guillemets dans le password
    echo "host=$host port=$port dbname=$dbname user=$user password=$pass"
  else
    echo "Erreur : format DEV_DATABASE_URL non reconnu" >&2
    exit 1
  fi
}

# Vérifier les variables d'environnement
if [ -z "${DEV_DATABASE_URL:-}" ] || [ -z "${DEV_TEST_DATABASE_URL:-}" ]; then
    echo "❌ Variables d'environnement manquantes : DEV_DATABASE_URL ou DEV_TEST_DATABASE_URL"
    exit 1
fi

# Convertir DEV_DATABASE_URL pour dblink
DEV_DB_CONN=$(parse_pg_uri "$DEV_DATABASE_URL")

echo "📊 Vérification des connexions..."
psql "$DEV_DATABASE_URL" -c "SELECT 1;" > /dev/null
echo "✅ Connexion à la base source OK"
psql "$DEV_TEST_DATABASE_URL" -c "SELECT 1;" > /dev/null
echo "✅ Connexion à la base destination OK"

# Créer le fichier log
LOG_FILE="migration_sltp_$(date +%Y%m%d_%H%M%S).log"
touch "$LOG_FILE"

# Obtenir la liste des tables dans le schéma public des deux bases
psql "$DEV_DATABASE_URL" -At -c "
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;" > source_tables.txt

psql "$DEV_TEST_DATABASE_URL" -At -c "
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;" > target_tables.txt

# Tables manquantes dans la base destination
comm -23 <(sort source_tables.txt) <(sort target_tables.txt) > missing_tables.txt
# Tables communes
comm -12 <(sort source_tables.txt) <(sort target_tables.txt) > common_tables.txt

echo "📊 Tables source: $(wc -l < source_tables.txt)" | tee -a "$LOG_FILE"
echo "📊 Tables destination: $(wc -l < target_tables.txt)" | tee -a "$LOG_FILE"

# Étape 1 : Créer les tables manquantes dans la base destination
if [ -s missing_tables.txt ]; then
    echo "🆕 Création des tables manquantes..." | tee -a "$LOG_FILE"
    while IFS= read -r table; do
        echo "📦 Export de la table $table" | tee -a "$LOG_FILE"
        pg_dump "$DEV_DATABASE_URL" --no-owner --no-privileges --schema=public --table="public.$table" > "$table.sql"
        psql "$DEV_TEST_DATABASE_URL" < "$table.sql"
        rm -f "$table.sql"
    done < missing_tables.txt
else
    echo "✅ Aucune table manquante" | tee -a "$LOG_FILE"
fi

# Étape 2 : Migration incrémentale des données (INSERT uniquement si non existant)
while IFS= read -r table; do
    echo "🔄 Synchronisation de la table $table" | tee -a "$LOG_FILE"

    PRIMARY_KEY=$(psql "$DEV_DATABASE_URL" -At -c "
        SELECT string_agg(quote_ident(a.attname), ', ')
        FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indrelid = 'public.$table'::regclass AND i.indisprimary;
    ")

    if [ -z "$PRIMARY_KEY" ]; then
        echo "⚠️ Table $table ignorée (pas de clé primaire)" | tee -a "$LOG_FILE"
        continue
    fi
    echo "🔑 Clé primaire : $PRIMARY_KEY" | tee -a "$LOG_FILE"

    COLUMNS=$(psql "$DEV_DATABASE_URL" -At -c "
        SELECT string_agg(quote_ident(column_name), ', ')
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = '$table';
    ")

    COL_TYPES=$(psql "$DEV_DATABASE_URL" -At -c "
        SELECT string_agg(
          quote_ident(column_name) || ' ' ||
          CASE 
            WHEN data_type = 'ARRAY' THEN
              replace(replace(udt_name,'_',''), 'int4', 'integer') || '[]'
            WHEN data_type = 'USER-DEFINED' THEN 'text'
            ELSE
              CASE
                WHEN data_type = 'character varying' THEN 'varchar'
                WHEN data_type = 'timestamp without time zone' THEN 'timestamp'
                WHEN data_type = 'timestamp with time zone' THEN 'timestamptz'
                ELSE data_type
              END
          END
          , ', ')
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = '$table';
    ")

    QUERY="SELECT $COLUMNS FROM public.\"$table\""
    QUERY_ESCAPED=${QUERY//\'/\'\'}

    cat > "insert_$table.sql" <<EOF
-- Insertion données pour $table
INSERT INTO public."$table" ($COLUMNS)
SELECT $COLUMNS
FROM dblink('$DEV_DB_CONN', '$QUERY_ESCAPED') AS src($COL_TYPES)
ON CONFLICT ($PRIMARY_KEY) DO NOTHING;
EOF

    echo "⏳ Exécution de l'insertion pour $table ..." | tee -a "$LOG_FILE"
    if ! psql "$DEV_TEST_DATABASE_URL" < "insert_$table.sql"; then
        echo "❌ Erreur pendant l'insertion de $table" | tee -a "$LOG_FILE"
    else
        echo "✅ Données synchronisées pour $table" | tee -a "$LOG_FILE"
        SRC_COUNT=$(psql "$DEV_DATABASE_URL" -At -c "SELECT COUNT(*) FROM public.\"$table\";")
        DEST_COUNT=$(psql "$DEV_TEST_DATABASE_URL" -At -c "SELECT COUNT(*) FROM public.\"$table\";")
        echo "📊 $table : source=$SRC_COUNT, destination=$DEST_COUNT" | tee -a "$LOG_FILE"
    fi

    rm -f "insert_$table.sql"
done < common_tables.txt

# Étape 3 : Synchroniser les séquences dans la base destination
echo "🔢 Synchronisation des séquences..." | tee -a "$LOG_FILE"
psql "$DEV_DATABASE_URL" -At -c "
SELECT 'SELECT setval(''' || quote_ident(schemaname) || '.' || quote_ident(sequencename) || ''', ' || last_value || ', true);'
FROM pg_sequences
WHERE schemaname = 'public';" > sequences.sql

if [ -s sequences.sql ]; then
    psql "$DEV_TEST_DATABASE_URL" < sequences.sql
    echo "✅ Séquences synchronisées" | tee -a "$LOG_FILE"
else
    echo "⚠️ Aucune séquence à synchroniser" | tee -a "$LOG_FILE"
fi

# Nettoyage
rm -f source_tables.txt target_tables.txt missing_tables.txt common_tables.txt sequences.sql

echo "✅ Migration SLTP terminée avec succès !" | tee -a "$LOG_FILE"
echo "📋 Log disponible : $LOG_FILE"