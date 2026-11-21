-- KFL: fonctions d'administration securisees pour le schema existant.
-- Executer dans Supabase > SQL Editor avec un compte administrateur du projet.
-- Aucune cle service_role ne doit etre placee dans le site web.

BEGIN;

CREATE TABLE IF NOT EXISTS public.kfl_admins (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.kfl_admins ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.kfl_admins FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.kfl_admin_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id uuid NOT NULL REFERENCES auth.users(id),
  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id text,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.kfl_admin_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.kfl_admin_audit FROM PUBLIC, anon, authenticated;

ALTER TABLE public.player_documents
  ADD COLUMN IF NOT EXISTS review_note text;

CREATE OR REPLACE FUNCTION public.is_kfl_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.kfl_admins a
    WHERE a.user_id = auth.uid()
  );
$function$;

REVOKE ALL ON FUNCTION public.is_kfl_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_kfl_admin() TO authenticated;

CREATE OR REPLACE FUNCTION public.kfl_admin_dashboard()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  result jsonb;
BEGIN
  IF NOT public.is_kfl_admin() THEN
    RAISE EXCEPTION 'Acces admin refuse' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'requests', COALESCE((
      SELECT jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC)
      FROM public.school_requests r
    ), '[]'::jsonb),
    'schools', COALESCE((
      SELECT jsonb_agg(to_jsonb(s) ORDER BY s.name)
      FROM public.schools s
    ), '[]'::jsonb),
    'matches', COALESCE((
      SELECT jsonb_agg(to_jsonb(m) ORDER BY m.match_date NULLS LAST, m.matchday, m.id)
      FROM public.matches m
    ), '[]'::jsonb),
    'players', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'school_id', p.school_id,
          'school_name', s.name,
          'full_name', p.full_name,
          'birth_date', p.birth_date,
          'jersey_number', p.jersey_number,
          'position', p.position,
          'docs_status', p.docs_status,
          'documents', COALESCE((
            SELECT jsonb_agg(
              jsonb_build_object(
                'id', d.id,
                'kind', d.kind::text,
                'file_path', d.file_path,
                'status', d.status::text,
                'review_note', d.review_note,
                'uploaded_at', d.uploaded_at
              )
              ORDER BY d.kind::text
            )
            FROM public.player_documents d
            WHERE d.player_id = p.id
          ), '[]'::jsonb)
        )
        ORDER BY s.name, p.jersey_number
      )
      FROM public.players p
      JOIN public.schools s ON s.id = p.school_id
    ), '[]'::jsonb),
    'match_stats', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', ms.id,
          'match_id', ms.match_id,
          'player_id', ms.player_id,
          'school_id', p.school_id,
          'full_name', p.full_name,
          'jersey_number', p.jersey_number,
          'goals', ms.goals,
          'assists', ms.assists,
          'yellow_cards', ms.yellow_cards,
          'red_cards', ms.red_cards
        )
        ORDER BY ms.match_id, p.full_name
      )
      FROM public.match_stats ms
      JOIN public.players p ON p.id = ms.player_id
    ), '[]'::jsonb),
    'audit', COALESCE((
      SELECT jsonb_agg(to_jsonb(a) ORDER BY a.created_at DESC)
      FROM (
        SELECT id, admin_id, action, entity_type, entity_id, details, created_at
        FROM public.kfl_admin_audit
        ORDER BY created_at DESC
        LIMIT 100
      ) a
    ), '[]'::jsonb)
  ) INTO result;

  RETURN result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.kfl_admin_review_school_request(
  p_request_id uuid,
  p_decision text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  req public.school_requests%ROWTYPE;
  new_school public.schools%ROWTYPE;
BEGIN
  IF NOT public.is_kfl_admin() THEN
    RAISE EXCEPTION 'Acces admin refuse' USING ERRCODE = '42501';
  END IF;
  IF p_decision IS NULL OR p_decision NOT IN ('validee', 'refusee') THEN
    RAISE EXCEPTION 'Decision invalide';
  END IF;

  SELECT * INTO req
  FROM public.school_requests
  WHERE id = p_request_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Demande introuvable';
  END IF;
  IF req.status IN ('validee', 'refusee') THEN
    RAISE EXCEPTION 'Cette demande a deja ete traitee';
  END IF;

  IF p_decision = 'refusee' THEN
    UPDATE public.school_requests SET status = 'refusee' WHERE id = req.id;
    INSERT INTO public.kfl_admin_audit(admin_id, action, entity_type, entity_id)
    VALUES (auth.uid(), 'refuse_school_request', 'school_request', req.id::text);
    RETURN jsonb_build_object('request_id', req.id, 'status', 'refusee');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.schools s
    WHERE lower(s.name) = lower(req.school_name)
      AND s.district = req.district
  ) THEN
    RAISE EXCEPTION 'Une ecole de ce nom existe deja dans ce district';
  END IF;

  INSERT INTO public.schools(name, district, status)
  VALUES (req.school_name, req.district, 'en_attente')
  RETURNING * INTO new_school;

  UPDATE public.school_requests SET status = 'validee' WHERE id = req.id;

  INSERT INTO public.kfl_admin_audit(admin_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'approve_school_request',
    'school_request',
    req.id::text,
    jsonb_build_object('school_id', new_school.id)
  );

  RETURN jsonb_build_object(
    'request_id', req.id,
    'school_id', new_school.id,
    'school_name', new_school.name,
    'access_code', new_school.code_10_char,
    'status', 'validee'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.kfl_admin_set_school_status(
  p_school_id uuid,
  p_status text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  updated_id uuid;
BEGIN
  IF NOT public.is_kfl_admin() THEN
    RAISE EXCEPTION 'Acces admin refuse' USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('incomplet', 'en_attente', 'valide') THEN
    RAISE EXCEPTION 'Statut invalide';
  END IF;

  UPDATE public.schools
  SET status = p_status::public.school_status
  WHERE id = p_school_id
  RETURNING id INTO updated_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Ecole introuvable';
  END IF;

  INSERT INTO public.kfl_admin_audit(admin_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'set_school_status', 'school', updated_id::text,
    jsonb_build_object('status', p_status)
  );
  RETURN jsonb_build_object('school_id', updated_id, 'status', p_status);
END;
$function$;

CREATE OR REPLACE FUNCTION public.kfl_admin_delete_school(p_school_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  school_name text;
BEGIN
  IF NOT public.is_kfl_admin() THEN
    RAISE EXCEPTION 'Acces admin refuse' USING ERRCODE = '42501';
  END IF;

  SELECT name INTO school_name
  FROM public.schools
  WHERE id = p_school_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Ecole introuvable';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.matches
    WHERE team_a_id = p_school_id OR team_b_id = p_school_id
  ) OR EXISTS (
    SELECT 1 FROM public.players WHERE school_id = p_school_id
  ) THEN
    RAISE EXCEPTION 'Suppression refusee : cette ecole a un roster ou des matchs. Desactivez-la plutot.';
  END IF;

  INSERT INTO public.kfl_admin_audit(admin_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'delete_school', 'school', p_school_id::text,
    jsonb_build_object('school_name', school_name)
  );
  DELETE FROM public.schools WHERE id = p_school_id;
  RETURN jsonb_build_object('school_id', p_school_id, 'deleted', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.kfl_admin_review_document(
  p_document_id uuid,
  p_approved boolean,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  doc public.player_documents%ROWTYPE;
BEGIN
  IF NOT public.is_kfl_admin() THEN
    RAISE EXCEPTION 'Acces admin refuse' USING ERRCODE = '42501';
  END IF;
  IF p_approved IS NULL OR (NOT p_approved AND length(trim(COALESCE(p_note, ''))) = 0) THEN
    RAISE EXCEPTION 'Une raison est requise pour demander une correction';
  END IF;

  UPDATE public.player_documents
  SET status = CASE WHEN p_approved THEN 'valide' ELSE 'fourni' END::public.doc_state,
      review_note = CASE WHEN p_approved THEN NULL ELSE left(trim(p_note), 1000) END
  WHERE id = p_document_id
  RETURNING * INTO doc;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Document introuvable';
  END IF;

  INSERT INTO public.kfl_admin_audit(admin_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    CASE WHEN p_approved THEN 'approve_document' ELSE 'request_document_correction' END,
    'player_document',
    doc.id::text,
    jsonb_build_object('player_id', doc.player_id, 'kind', doc.kind::text)
  );
  RETURN jsonb_build_object(
    'document_id', doc.id,
    'status', doc.status::text,
    'review_note', doc.review_note
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.kfl_admin_save_match(
  p_id uuid,
  p_district text,
  p_group_stage text,
  p_matchday integer,
  p_team_a_id uuid,
  p_team_b_id uuid,
  p_match_date timestamptz,
  p_status text,
  p_score_a integer,
  p_score_b integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  saved public.matches%ROWTYPE;
BEGIN
  IF NOT public.is_kfl_admin() THEN
    RAISE EXCEPTION 'Acces admin refuse' USING ERRCODE = '42501';
  END IF;
  IF p_district NOT IN ('Lukunga', 'Funa', 'Mont-Amba', 'Tshangu')
     OR p_group_stage NOT IN ('A', 'B', 'C', 'D')
     OR p_matchday IS NULL OR p_matchday < 1
     OR p_team_a_id IS NULL OR p_team_b_id IS NULL
     OR p_team_a_id = p_team_b_id
     OR p_status IS NULL OR p_status NOT IN ('programme', 'en_cours', 'termine', 'reporte')
     OR ((p_score_a IS NULL) <> (p_score_b IS NULL))
     OR (p_score_a IS NOT NULL AND (p_score_a < 0 OR p_score_b < 0))
     OR (p_status = 'termine' AND p_score_a IS NULL) THEN
    RAISE EXCEPTION 'Donnees du match invalides';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.schools a
    JOIN public.schools b ON b.id = p_team_b_id
    WHERE a.id = p_team_a_id
      AND a.district = p_district::public.district_t
      AND b.district = p_district::public.district_t
  ) THEN
    RAISE EXCEPTION 'Les deux ecoles doivent appartenir au district du match';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.matches(
      district, group_stage, matchday, team_a_id, team_b_id,
      match_date, status, score_a, score_b
    )
    VALUES (
      p_district::public.district_t, p_group_stage, p_matchday,
      p_team_a_id, p_team_b_id, p_match_date,
      p_status::public.match_status_t, p_score_a, p_score_b
    )
    RETURNING * INTO saved;
  ELSE
    UPDATE public.matches
    SET district = p_district::public.district_t,
        group_stage = p_group_stage,
        matchday = p_matchday,
        team_a_id = p_team_a_id,
        team_b_id = p_team_b_id,
        match_date = p_match_date,
        status = p_status::public.match_status_t,
        score_a = p_score_a,
        score_b = p_score_b
    WHERE id = p_id
    RETURNING * INTO saved;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Match introuvable';
    END IF;
  END IF;

  INSERT INTO public.kfl_admin_audit(admin_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    CASE WHEN p_id IS NULL THEN 'create_match' ELSE 'update_match' END,
    'match',
    saved.id::text,
    jsonb_build_object(
      'status', saved.status::text,
      'score_a', saved.score_a,
      'score_b', saved.score_b
    )
  );
  RETURN to_jsonb(saved);
END;
$function$;

CREATE OR REPLACE FUNCTION public.kfl_admin_delete_match(p_match_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF NOT public.is_kfl_admin() THEN
    RAISE EXCEPTION 'Acces admin refuse' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.matches WHERE id = p_match_id) THEN
    RAISE EXCEPTION 'Match introuvable';
  END IF;

  INSERT INTO public.kfl_admin_audit(admin_id, action, entity_type, entity_id)
  VALUES (auth.uid(), 'delete_match', 'match', p_match_id::text);
  DELETE FROM public.matches WHERE id = p_match_id;
  RETURN jsonb_build_object('match_id', p_match_id, 'deleted', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.kfl_admin_save_match_stat(
  p_match_id uuid,
  p_player_id uuid,
  p_goals integer,
  p_assists integer,
  p_yellow_cards integer,
  p_red_cards integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  saved public.match_stats%ROWTYPE;
BEGIN
  IF NOT public.is_kfl_admin() THEN
    RAISE EXCEPTION 'Acces admin refuse' USING ERRCODE = '42501';
  END IF;
  IF p_goals IS NULL OR p_assists IS NULL OR p_yellow_cards IS NULL OR p_red_cards IS NULL
     OR p_goals < 0 OR p_assists < 0 OR p_yellow_cards < 0 OR p_red_cards < 0 THEN
    RAISE EXCEPTION 'Les statistiques ne peuvent pas etre negatives';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.matches m
    JOIN public.players p ON p.id = p_player_id
    WHERE m.id = p_match_id
      AND p.school_id IN (m.team_a_id, m.team_b_id)
  ) THEN
    RAISE EXCEPTION 'Le joueur ne fait pas partie des deux ecoles du match';
  END IF;

  INSERT INTO public.match_stats(
    match_id, player_id, goals, assists, yellow_cards, red_cards
  )
  VALUES (
    p_match_id, p_player_id, p_goals, p_assists, p_yellow_cards, p_red_cards
  )
  ON CONFLICT (match_id, player_id)
  DO UPDATE SET
    goals = EXCLUDED.goals,
    assists = EXCLUDED.assists,
    yellow_cards = EXCLUDED.yellow_cards,
    red_cards = EXCLUDED.red_cards
  RETURNING * INTO saved;

  INSERT INTO public.kfl_admin_audit(admin_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'update_match_stats', 'match', p_match_id::text,
    jsonb_build_object('player_id', p_player_id)
  );
  RETURN to_jsonb(saved);
END;
$function$;

REVOKE ALL ON FUNCTION public.kfl_admin_dashboard() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.kfl_admin_review_school_request(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.kfl_admin_set_school_status(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.kfl_admin_delete_school(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.kfl_admin_review_document(uuid, boolean, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.kfl_admin_save_match(uuid, text, text, integer, uuid, uuid, timestamptz, text, integer, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.kfl_admin_delete_match(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.kfl_admin_save_match_stat(uuid, uuid, integer, integer, integer, integer) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.kfl_admin_dashboard() TO authenticated;
GRANT EXECUTE ON FUNCTION public.kfl_admin_review_school_request(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.kfl_admin_set_school_status(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.kfl_admin_delete_school(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.kfl_admin_review_document(uuid, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.kfl_admin_save_match(uuid, text, text, integer, uuid, uuid, timestamptz, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.kfl_admin_delete_match(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.kfl_admin_save_match_stat(uuid, uuid, integer, integer, integer, integer) TO authenticated;

-- Les dossiers des joueurs doivent rester prives. Les administrateurs peuvent
-- lire les objets uniquement afin de generer des liens signes temporaires.
DO $block$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'school-docs') THEN
    RAISE EXCEPTION 'Le bucket Storage school-docs est introuvable';
  END IF;
  UPDATE storage.buckets SET public = false WHERE id = 'school-docs';
END;
$block$;

DROP POLICY IF EXISTS kfl_admin_read_school_docs ON storage.objects;
CREATE POLICY kfl_admin_read_school_docs
ON storage.objects
FOR SELECT
TO authenticated
USING (bucket_id = 'school-docs' AND public.is_kfl_admin());

COMMIT;

-- Pour l'acces username « Joachimdik »:
-- 1. Creer l'utilisateur dans Supabase Dashboard > Authentication > Users,
--    avec l'adresse joachimdik@kfl-admin.com et definir son mot de passe
--    directement dans Supabase. Ne jamais inscrire le mot de passe dans ce fichier.
-- 2. Executer ce bloc pour autoriser ce compte comme administrateur:
-- DO $$
-- DECLARE admin_user_id uuid;
-- BEGIN
--   SELECT id INTO admin_user_id
--   FROM auth.users
--   WHERE email = lower('joachimdik@kfl-admin.com');
--   IF admin_user_id IS NULL THEN
--     RAISE EXCEPTION 'Creer d abord joachimdik@kfl-admin.com dans Supabase Auth';
--   END IF;
--   INSERT INTO public.kfl_admins (user_id)
--   VALUES (admin_user_id)
--   ON CONFLICT (user_id) DO NOTHING;
-- END
-- $$;
