-- Insertion données pour campaign_execution_contacts
INSERT INTO public."campaign_execution_contacts" (id,execution_id,contact_id,status,last_error,last_attempted_at,created_at,attempts)
SELECT id,execution_id,contact_id,status,last_error,last_attempted_at,created_at,attempts
FROM dblink('host=aws-0-eu-central-1.pooler.supabase.com port=5432 dbname=postgres user=postgres.bhkgthwppvspndmfaklf password=TxeZLWB1a9CNodmM', 'SELECT id,execution_id,contact_id,status,last_error,last_attempted_at,created_at,attempts FROM public."campaign_execution_contacts"') AS src(id uuid, execution_id uuid, contact_id uuid, status text, last_error text, last_attempted_at timestamptz, created_at timestamptz, attempts bigint)
ON CONFLICT (id) DO UPDATE SET execution_id = EXCLUDED.execution_id, contact_id = EXCLUDED.contact_id, status = EXCLUDED.status, last_error = EXCLUDED.last_error, last_attempted_at = EXCLUDED.last_attempted_at, created_at = EXCLUDED.created_at, attempts = EXCLUDED.attempts;
