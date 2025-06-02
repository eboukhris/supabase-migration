-- Synchronisation de la table agents_organizations
BEGIN;

-- Désactiver temporairement les triggers pour éviter les conflits
SET session_replication_role = replica;

-- Insérer ou mettre à jour les données
INSERT INTO public.agents_organizations 
SELECT * FROM dblink(
    'postgresql://postgres.bhkgthwppvspndmfaklf:TxeZLWB1a9CNodmM@aws-0-eu-central-1.pooler.supabase.com:5432/postgres',
    'SELECT * FROM public.agents_organizations'
) AS t1()
ON CONFLICT (id) DO UPDATE SET
;

-- Réactiver les triggers
SET session_replication_role = DEFAULT;

COMMIT;
