-- DROP FUNCTION dbo.pre_mvw_script(varchar);

CREATE OR REPLACE FUNCTION dbo.pre_mvw_script(p_view_name character varying)
 RETURNS TABLE(r_mvw_name character varying, r_level integer, r_defenition character varying, r_drop_command character varying)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_drop_command varchar;
    v_policy_drop varchar;
BEGIN
    set schema '<your_schema>';
    if not exists (SELECT * FROM pg_class WHERE relname = p_view_name) then
        return;
    end if;
    drop table if exists dependent_views;
    create temp table dependent_views
    as
    WITH RECURSIVE views AS
    (
            SELECT
                v.oid::regclass AS view,
                v.relkind = 'm' AS is_materialized,
                1 AS level
            FROM pg_depend AS d
            JOIN pg_rewrite AS r
                ON r.oid = d.objid
            JOIN pg_class AS v
                ON v.oid = r.ev_class
            WHERE v.relkind IN ('v', 'm')
                AND d.classid = 'pg_rewrite'::regclass
                AND d.refclassid = 'pg_class'::regclass
                AND d.deptype = 'n'
                AND d.refobjid = p_view_name::regclass

        UNION

            -- add the views that depend on these
            SELECT
                v.oid::regclass,
                v.relkind = 'm',
                views.level + 1
            FROM views
                JOIN pg_depend AS d
                    ON d.refobjid = views.view
                JOIN pg_rewrite AS r
                    ON r.oid = d.objid
                JOIN pg_class AS v
                    ON v.oid = r.ev_class
            WHERE v.relkind IN ('v', 'm')
                AND d.classid = 'pg_rewrite'::regclass
                AND d.refclassid = 'pg_class'::regclass
                AND d.deptype = 'n'
                AND v.oid <> views.view
    )
    SELECT
        view::varchar as mvw_name,
        level,
            format('CREATE%s VIEW %s AS%s',
                    CASE
                        WHEN is_materialized THEN
                            ' MATERIALIZED'
                        ELSE ''
                    END,
                    view,
                    pg_get_viewdef(view)
                )::varchar
        as defenition,
            format('DROP%s VIEW if exists %s',
                    CASE
                        WHEN is_materialized THEN
                            ' MATERIALIZED'
                        ELSE ''
                    END,
                    view
                )::varchar
        as drop_command
    FROM views
    GROUP BY view,level, is_materialized
    ORDER BY max(level);

    drop table if exists index_def_tbl;
    create temp table index_def_tbl
    as
    SELECT tablename,indexname, indexdef
    FROM pg_indexes
    WHERE tablename in (select mvw_name from dependent_views);

    -- Save RLS policies that depend on the views being dropped (including the main view)
    drop table if exists policy_def_tbl;
    create temp table policy_def_tbl as
    SELECT DISTINCT
        p.polname::varchar as policy_name,
        c.relname::varchar as table_name,
        n.nspname::varchar as schema_name,
        format(
            'CREATE POLICY %I ON %I.%I %s %s %s %s',
            p.polname,
            n.nspname,
            c.relname,
            CASE p.polcmd
                WHEN 'r' THEN 'FOR SELECT'
                WHEN 'a' THEN 'FOR INSERT'
                WHEN 'w' THEN 'FOR UPDATE'
                WHEN 'd' THEN 'FOR DELETE'
                WHEN '*' THEN 'FOR ALL'
            END,
            CASE
                WHEN p.polroles = '{0}' THEN 'TO PUBLIC'
                ELSE 'TO ' || array_to_string(ARRAY(
                    SELECT rolname FROM pg_roles WHERE oid = ANY(p.polroles)
                ), ', ')
            END,
            CASE
                WHEN p.polqual IS NOT NULL THEN 'USING (' || pg_get_expr(p.polqual, p.polrelid) || ')'
                ELSE ''
            END,
            CASE
                WHEN p.polwithcheck IS NOT NULL THEN 'WITH CHECK (' || pg_get_expr(p.polwithcheck, p.polrelid) || ')'
                ELSE ''
            END
        )::varchar as policy_def,
        format('DROP POLICY IF EXISTS %I ON %I.%I', p.polname, n.nspname, c.relname)::varchar as drop_command
    FROM pg_policy p
    JOIN pg_class c ON c.oid = p.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_depend d ON d.objid = p.oid
    WHERE d.refobjid IN (
        SELECT (mvw_name)::regclass FROM dependent_views
        UNION
        SELECT p_view_name::regclass
    )
    AND d.deptype = 'n';

    -- Drop RLS policies first (before dropping views)
    for v_policy_drop in select drop_command from policy_def_tbl loop
        raise notice '%;', v_policy_drop;
        execute(v_policy_drop);
    end loop;
    if exists (select 1 from policy_def_tbl) then
        raise notice '--Successfully Dropped RLS policies';
    end if;

    for v_drop_command in select drop_command from dependent_views order by level desc loop
        raise notice '%;', v_drop_command;
        execute(v_drop_command);
    end loop;
    raise notice '--Successfully Dropped views';
END;
$function$
;
