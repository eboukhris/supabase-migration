#!/bin/bash
# scripts/migrate-storage-files.sh
set -e

echo "📁 Migration des fichiers Storage..."

# Vérifier les variables d'environnement
if [ -z "$SOURCE_SUPABASE_URL" ] || [ -z "$SOURCE_SUPABASE_SERVICE_KEY" ] || 
   [ -z "$TARGET_SUPABASE_URL" ] || [ -z "$TARGET_SUPABASE_SERVICE_KEY" ]; then
    echo "❌ Variables d'environnement Supabase manquantes"
    echo "Nécessaires: SOURCE_SUPABASE_URL, SOURCE_SUPABASE_SERVICE_KEY, TARGET_SUPABASE_URL, TARGET_SUPABASE_SERVICE_KEY"
    exit 1
fi

# Créer le script Node.js pour migrer les fichiers
cat > migrate_files.js << 'EOF'
const { createClient } = require('@supabase/supabase-js')
const fs = require('fs')
const path = require('path')

const sourceSupabase = createClient(
  process.env.SOURCE_SUPABASE_URL, 
  process.env.SOURCE_SUPABASE_SERVICE_KEY
)

const targetSupabase = createClient(
  process.env.TARGET_SUPABASE_URL, 
  process.env.TARGET_SUPABASE_SERVICE_KEY
)

async function migrateBucketFiles(bucketId) {
  console.log(`📂 Migration du bucket: ${bucketId}`)
  
  try {
    // Lister tous les fichiers du bucket source
    const { data: files, error: listError } = await sourceSupabase
      .storage
      .from(bucketId)
      .list('', {
        limit: 1000,
        offset: 0,
      })

    if (listError) {
      console.error(`❌ Erreur listage bucket ${bucketId}:`, listError)
      return
    }

    if (!files || files.length === 0) {
      console.log(`ℹ️ Aucun fichier dans le bucket ${bucketId}`)
      return
    }

    console.log(`📊 ${files.length} fichiers trouvés dans ${bucketId}`)

    // Migrer chaque fichier
    for (const file of files) {
      if (file.name === '.emptyFolderPlaceholder') continue
      
      try {
        console.log(`📄 Migration: ${file.name}`)
        
        // Télécharger depuis la source
        const { data: fileData, error: downloadError } = await sourceSupabase
          .storage
          .from(bucketId)
          .download(file.name)

        if (downloadError) {
          console.error(`❌ Erreur téléchargement ${file.name}:`, downloadError)
          continue
        }

        // Uploader vers la destination
        const { data: uploadData, error: uploadError } = await targetSupabase
          .storage
          .from(bucketId)
          .upload(file.name, fileData, {
            contentType: file.metadata?.mimetype,
            upsert: true
          })

        if (uploadError) {
          console.error(`❌ Erreur upload ${file.name}:`, uploadError)
        } else {
          console.log(`✅ ${file.name} migré avec succès`)
        }

      } catch (error) {
        console.error(`❌ Erreur migration ${file.name}:`, error)
      }
    }

  } catch (error) {
    console.error(`❌ Erreur migration bucket ${bucketId}:`, error)
  }
}

async function migrateAllStorageFiles() {
  console.log('🚀 Début migration des fichiers Storage')
  
  try {
    // Récupérer la liste des buckets
    const { data: buckets, error: bucketsError } = await sourceSupabase
      .storage
      .listBuckets()

    if (bucketsError) {
      console.error('❌ Erreur récupération buckets:', bucketsError)
      return
    }

    console.log(`📊 ${buckets.length} buckets trouvés`)

    // Migrer chaque bucket
    for (const bucket of buckets) {
      await migrateBucketFiles(bucket.id)
    }

    console.log('🎉 Migration des fichiers terminée !')

  } catch (error) {
    console.error('❌ Erreur générale:', error)
    process.exit(1)
  }
}

migrateAllStorageFiles()
EOF

# Installer les dépendances Node.js
echo "📦 Installation des dépendances..."
npm init -y > /dev/null 2>&1
npm install @supabase/supabase-js > /dev/null 2>&1

# Exécuter la migration
echo "🚀 Lancement de la migration des fichiers..."
node migrate_files.js

# Nettoyage
rm migrate_files.js package.json package-lock.json
rm -rf node_modules

echo "✅ Migration des fichiers Storage terminée !"