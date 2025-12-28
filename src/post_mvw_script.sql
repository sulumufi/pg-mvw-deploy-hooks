-- DROP FUNCTION dbo.post_mvw_script(varchar);

CREATE OR REPLACE FUNCTION dbo.post_mvw_script(p_view_name character varying)
 RETURNS TABLE(r_mvw_name character varying, r_level integer, r_defenition character varying, r_drop_command character varying)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_drop_command varchar;
  v_create_command varchar;
  v_mvw_name varchar;
  v_index_def varchar;
  v_policy_def varchar;
BEGIN
	set schema '<your_schema>';
	if not exists (SELECT * FROM pg_class WHERE relname = 'dependent_views') then
        return;
    end if;
    for v_create_command, v_mvw_name
    in
    WITH cte AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY mvw_name ORDER BY level DESC) AS rn
    FROM dependent_views
	)
	SELECT  defenition, mvw_name
	FROM cte
	WHERE rn = 1
	ORDER BY level ASC
    loop
		raise notice '-- Creating MVW : %', v_mvw_name;
		raise notice '%;', v_create_command;
		execute(v_create_command);
		raise notice '--Creating indexes for MVW : %',  v_mvw_name;
		for v_index_def in select indexdef from index_def_tbl where tablename = v_mvw_name loop
			raise notice '%;',  v_index_def;
			execute(v_index_def);

			if (v_mvw_name ilike 'mvw%') then
				execute ('refresh materialized view dbo.'||v_mvw_name||';');
			end if;

		end loop;
	end loop;

	-- Recreate RLS policies
	if exists (SELECT * FROM pg_class WHERE relname = 'policy_def_tbl') then
		raise notice '--Recreating RLS policies';
		for v_policy_def in select policy_def from policy_def_tbl loop
			raise notice '%;', v_policy_def;
			execute(v_policy_def);
		end loop;
		raise notice '--Successfully Recreated RLS policies';
		drop table if exists policy_def_tbl;
	end if;

	drop table if exists dependent_views;
END;
$function$
;
