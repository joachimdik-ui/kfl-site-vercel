-- Diagnostic en lecture seule : ne lit aucune donnee metier et ne modifie rien.
-- Executer ce SELECT dans Supabase > SQL Editor, puis partager le JSON retourne.
SELECT jsonb_pretty(
  jsonb_build_object(
    'tables', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'table', format('%I.%I', n.nspname, c.relname),
            'rls_enabled', c.relrowsecurity,
            'rls_forced', c.relforcerowsecurity,
            'columns', COALESCE(
              (
                SELECT jsonb_agg(
                  jsonb_build_object(
                    'name', a.attname,
                    'type', format_type(a.atttypid, a.atttypmod),
                    'nullable', NOT a.attnotnull,
                    'default', pg_get_expr(d.adbin, d.adrelid)
                  )
                  ORDER BY a.attnum
                )
                FROM pg_attribute a
                LEFT JOIN pg_attrdef d
                  ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                WHERE a.attrelid = c.oid
                  AND a.attnum > 0
                  AND NOT a.attisdropped
              ),
              '[]'::jsonb
            ),
            'constraints', COALESCE(
              (
                SELECT jsonb_agg(
                  jsonb_build_object(
                    'name', con.conname,
                    'type', con.contype,
                    'definition', pg_get_constraintdef(con.oid, true)
                  )
                  ORDER BY con.conname
                )
                FROM pg_constraint con
                WHERE con.conrelid = c.oid
              ),
              '[]'::jsonb
            ),
            'policies', COALESCE(
              (
                SELECT jsonb_agg(
                  jsonb_build_object(
                    'name', p.policyname,
                    'command', p.cmd,
                    'roles', p.roles,
                    'using', p.qual,
                    'check', p.with_check
                  )
                  ORDER BY p.policyname
                )
                FROM pg_policies p
                WHERE p.schemaname = n.nspname
                  AND p.tablename = c.relname
              ),
              '[]'::jsonb
            )
          )
          ORDER BY c.relname
        )
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p', 'v', 'm')
      ),
      '[]'::jsonb
    ),
    'functions', COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'name', p.proname,
            'arguments', pg_get_function_identity_arguments(p.oid),
            'returns', pg_get_function_result(p.oid),
            'security_definer', p.prosecdef
          )
          ORDER BY p.proname, pg_get_function_identity_arguments(p.oid)
        )
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.prokind = 'f'
      ),
      '[]'::jsonb
    )
  )
) AS schema_for_admin;
