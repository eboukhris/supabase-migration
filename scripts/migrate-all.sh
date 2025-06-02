#!/bin/bash
# scripts/migrate.sh - Migration incrémentale SLTP
set -euo pipefail

echo "🚀 Début de la migration incrémentale SLTP..."

function parse_pg_uri() {
  local uri=$1
  if [[ $uri =~ postgresql://([^:]+):([^@]+)@([^:/]+):([0-9]+)/(.+) ]]; then
    local user="${BASH_REMATCH[1]}"
    local pass="${BASH_REMATCH[2]}"
    local host="${BASH_REMATCH[3]}"
    local port="${BASH_REMATCH[4]}"
    local dbname="${BASH_REMATCH[5]}"
    echo "host=$host port=$port dbname=$dbname user=$user password=$pass"
  else
    echo "Erreur : format DEV_DATABASE_URL non reconnu" >&2
    exit 1
  fi
}

if [ -z "${DEV_DATABASE_URL:-}" ] || [ -z "${DEV_TEST_DATABASE_URL:-}" ]; then
    echo "❌ Variables d'environnement manquantes"
    exit 1
fi

DEV_DB_CONN=$(parse_pg_uri "$DEV_DATABASE_URL")

LOG_FILE="migration_sltp_$(date +%Y%m%d_%H%M%S).log"
touch "$LOG_FILE"

echo "📊 Vérification des connexions..."
psql "$DEV_DATABASE_URL" -c "SELECT 1;" > /dev/null
psql "$DEV_TEST_DATABASE_URL" -c "SELECT 1;" > /dev/null
# --- Étape 1 : Migration des ENUM ---
echo "🔤 Migration des types ENUM..." | tee -a "$LOG_FILE"

pg_dump "$DEV_DATABASE_URL" --schema=public --section=pre-data | grep -iE 'CREATE TYPE .* AS ENUM' > enums.sql

if [ -s enums.sql ]; then
  psql "$DEV_TEST_DATABASE_URL" < enums.sql
  echo "✅ ENUMs migrés" | tee -a "$LOG_FILE"
else
  echo "ℹ️ Aucun ENUM trouvé." | tee -a "$LOG_FILE"
fi

rm -f enums.sql

# --- Étape 3 : Migration des tables stables (ordre SLTP prioritaire) ---
echo "📂 Migration des tables stables (ordre SLTP)..." | tee -a "$LOG_FILE"
ORDERED_TABLES=("campaigns"
  "campaign_executions"
  "campaign_execution_contacts") # À ajuster

for table in "${ORDERED_TABLES[@]}"; do
  echo "📦 Export de la table $table" | tee -a "$LOG_FILE"

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

  COLUMNS=$(psql "$DEV_DATABASE_URL" -At -c "
    SELECT string_agg(quote_ident(column_name), ', ')
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = '$table';
  ")

  COL_TYPES=$(psql "$DEV_DATABASE_URL" -At -c "
    SELECT string_agg(
      quote_ident(column_name) || ' ' ||
      CASE
        WHEN data_type = 'ARRAY' THEN 'text'
        WHEN data_type = 'USER-DEFINED' THEN 'text'
        WHEN data_type = 'character varying' THEN 'varchar'
        WHEN data_type = 'timestamp without time zone' THEN 'timestamp'
        WHEN data_type = 'timestamp with time zone' THEN 'timestamptz'
        ELSE data_type
      END, ', ')
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = '$table';
  ")

  QUERY="SELECT $COLUMNS FROM public.\"$table\""
  QUERY_ESCAPED=${QUERY//\'/\'\'}

  cat > "insert_$table.sql" <<EOF
INSERT INTO public."$table" ($COLUMNS)
SELECT $COLUMNS
FROM dblink('$DEV_DB_CONN', '$QUERY_ESCAPED') AS src($COL_TYPES)
ON CONFLICT ($PRIMARY_KEY) DO NOTHING;
EOF

  if psql "$DEV_TEST_DATABASE_URL" < "insert_$table.sql"; then
    echo "✅ Données synchronisées pour $table" | tee -a "$LOG_FILE"
  else
    echo "❌ Erreur dans $table" | tee -a "$LOG_FILE"
  fi

  rm -f "insert_$table.sql"
done

# --- Étape 4 : Migration des autres tables communes ---
echo "📃 Tables restantes..." | tee -a "$LOG_FILE"
psql "$DEV_DATABASE_URL" -At -c "
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public';" | sort > all_tables.txt

for t in "${ORDERED_TABLES[@]}"; do echo "$t"; done | sort > ordered.txt
comm -23 all_tables.txt ordered.txt > remaining.txt

for table in $(cat remaining.txt); do
  echo "🔁 Table: $table" | tee -a "$LOG_FILE"

  PRIMARY_KEY=$(psql "$DEV_DATABASE_URL" -At -c "
    SELECT string_agg(quote_ident(a.attname), ', ')
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
    WHERE i.indrelid = 'public.$table'::regclass AND i.indisprimary;
  ")

  [ -z "$PRIMARY_KEY" ] && echo "⚠️ Ignorée : pas de PK" && continue

  COLUMNS=$(psql "$DEV_DATABASE_URL" -At -c "
    SELECT string_agg(quote_ident(column_name), ', ')
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = '$table';
  ")

  COL_TYPES=$(psql "$DEV_DATABASE_URL" -At -c "
    SELECT string_agg(
      quote_ident(column_name) || ' ' ||
      CASE
        WHEN data_type = 'ARRAY' THEN 'text'
        WHEN data_type = 'USER-DEFINED' THEN 'text'
        WHEN data_type = 'character varying' THEN 'varchar'
        WHEN data_type = 'timestamp without time zone' THEN 'timestamp'
        WHEN data_type = 'timestamp with time zone' THEN 'timestamptz'
        ELSE data_type
      END, ', ')
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = '$table';
  ")

  QUERY="SELECT $COLUMNS FROM public.\"$table\""
  QUERY_ESCAPED=${QUERY//\'/\'\'}

  cat > "insert_$table.sql" <<EOF
INSERT INTO public."$table" ($COLUMNS)
SELECT $COLUMNS
FROM dblink('$DEV_DB_CONN', '$QUERY_ESCAPED') AS src($COL_TYPES)
ON CONFLICT ($PRIMARY_KEY) DO NOTHING;
EOF

  psql "$DEV_TEST_DATABASE_URL" < "insert_$table.sql" && echo "✅ $table OK" | tee -a "$LOG_FILE"
  rm -f "insert_$table.sql"
done

# --- Étape 5 : Séquences ---
echo "🔢 Synchronisation des séquences..." | tee -a "$LOG_FILE"
psql "$DEV_DATABASE_URL" -At -c "
SELECT 'SELECT setval(''' || quote_ident(schemaname) || '.' || quote_ident(sequencename) || ''', ' || last_value || ', true);'
FROM pg_sequences
WHERE schemaname = 'public';" > sequences.sql

[ -s sequences.sql ] && psql "$DEV_TEST_DATABASE_URL" < sequences.sql && echo "✅ Séquences OK" | tee -a "$LOG_FILE"
rm -f sequences.sql enums.txt all_tables.txt ordered.txt remaining.txt

echo "🎉 Migration terminée ! Log : $LOG_FILE"
