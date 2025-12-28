-- Example: Deploying a Materialized View with mvw() and post_mvw()
--
-- Pattern:
-- 1. Call mvw() before dropping to preserve metadata/state
-- 2. Drop and recreate the materialized view
-- 3. Call post_mvw() after creating to restore metadata/state

DO $mvw$
DECLARE
    view_name TEXT := 'materialized_view_name';
BEGIN
    PERFORM pre_mvw_script(view_name);

    DROP MATERIALIZED VIEW IF EXISTS materialized_view_name;

    -- Step 3: Create the materialized view
    CREATE MATERIALIZED VIEW materialized_view_name AS
    SELECT
        column1,
        column2,
        aggregate_function(column3) AS aggregated_column
    FROM
        source_table
    WHERE
        some_condition = true
    GROUP BY
        column1, column2;

    
    -- Step 4: Call post_mvw() to restore state after creating
    PERFORM post_mvw_script(view_name);
END $mvw$;

