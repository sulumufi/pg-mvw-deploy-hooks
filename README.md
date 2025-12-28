# PostgreSQL Materialized View Automation

A pair of PostgreSQL functions that automate the process of dropping and recreating materialized views while preserving their dependent objects (views, indexes, and Row-Level Security policies).

## Overview

When you need to modify a materialized view's definition in PostgreSQL, you must drop and recreate it. However, this becomes complex when other views depend on it, or when it has indexes and RLS policies. This automation handles the entire dependency chain automatically.

## Components

### 1. `pre_mvw_script(p_view_name)`

Called **BEFORE** dropping the materialized view. This function:

- Discovers all dependent views (recursively) that rely on the target materialized view
- Stores view definitions, indexes, and RLS policies in temporary tables
- Drops RLS policies and dependent views in the correct order (deepest dependencies first)

**What it preserves:**
- Dependent view definitions (both regular and materialized views)
- Index definitions for all dependent materialized views
- Row-Level Security (RLS) policies attached to dependent views
- Dependency hierarchy (level/depth information)

**Temporary tables created:**
- `dependent_views` - Stores view metadata and definitions
- `index_def_tbl` - Stores index definitions
- `policy_def_tbl` - Stores RLS policy definitions

### 2. `post_mvw_script(p_view_name)`

Called **AFTER** recreating the materialized view. This function:

- Recreates all dependent views in the correct order (shallowest dependencies first)
- Recreates indexes for materialized views
- Refreshes materialized views that follow the naming convention `mvw%`
- Recreates RLS policies
- Cleans up temporary tables

## How It Works

### Dependency Discovery

The `pre_mvw_script` uses a recursive Common Table Expression (CTE) to traverse the entire dependency tree:

```sql
WITH RECURSIVE views AS (
    -- Start with direct dependencies
    SELECT view, is_materialized, level=1
    FROM pg_depend WHERE refobjid = target_view

    UNION

    -- Add views that depend on those views
    SELECT view, is_materialized, level+1
    FROM views JOIN pg_depend ON ...
)
```

This discovers:
- **Level 1**: Views directly depending on your materialized view
- **Level 2**: Views depending on level 1 views
- **Level N**: Continue until no more dependencies found

### Drop Order (pre_mvw_script)

1. **RLS Policies** - Dropped first (they depend on views)
2. **Dependent Views** - Dropped in reverse order (level DESC)
   - Level 3 views first
   - Level 2 views second
   - Level 1 views last

### Recreate Order (post_mvw_script)

1. **Dependent Views** - Recreated in forward order (level ASC)
   - Level 1 views first
   - Level 2 views second
   - Level 3 views last
2. **Indexes** - Recreated for each materialized view
3. **Materialized View Refresh** - Refresh views matching `mvw%` pattern
4. **RLS Policies** - Recreated last

## Setup

### Prerequisites

- PostgreSQL 9.3+ (for materialized views)
- Appropriate schema permissions

### Installation

1. Edit both SQL files and replace `<your_schema>` with your actual schema name:

```sql
set schema 'your_actual_schema';
```

2. Execute the SQL files to create the functions:

```bash
psql -d your_database -f src/pre_mvw_script.sql
psql -d your_database -f src/post_mvw_script.sql
```

Or within psql:

```sql
\i src/pre_mvw_script.sql
\i src/post_mvw_script.sql
```

## Usage

### Basic Template

```sql
DO $$
DECLARE
    view_name TEXT := 'your_materialized_view_name';
BEGIN
    -- Step 1: Preserve dependencies and drop them
    PERFORM pre_mvw_script(view_name);

    -- Step 2: Drop the materialized view
    DROP MATERIALIZED VIEW IF EXISTS your_materialized_view_name;

    -- Step 3: Recreate the materialized view with new definition
    CREATE MATERIALIZED VIEW your_materialized_view_name AS
    SELECT
        column1,
        column2,
        aggregate_function(column3) AS aggregated_column
    FROM
        source_table
    WHERE
        some_condition = true
    GROUP BY
        column1, column2
    WITH DATA;

    -- Step 4: Recreate all dependencies
    PERFORM post_mvw_script(view_name);
END $$;
```

### Example: Updating Sales Summary View

```sql
DO $$
DECLARE
    view_name TEXT := 'mvw_sales_summary';
BEGIN
    PERFORM pre_mvw_script(view_name);

    DROP MATERIALIZED VIEW IF EXISTS mvw_sales_summary;

    CREATE MATERIALIZED VIEW mvw_sales_summary AS
    SELECT
        product_id,
        date_trunc('month', order_date) AS month,
        SUM(amount) AS total_sales,
        COUNT(*) AS order_count,
        AVG(amount) AS avg_order_value
    FROM
        orders
    WHERE
        status = 'completed'
    GROUP BY
        product_id,
        date_trunc('month', order_date)
    WITH DATA;

    PERFORM post_mvw_script(view_name);
END $$;
```

## Important Notes

### Configuration Required

**Before using these functions, you MUST update the schema name:**

In both `pre_mvw_script.sql` and `post_mvw_script.sql`, replace:
```sql
set schema '<your_schema>';
```
with:
```sql
set schema 'dbo';  -- or your actual schema name
```

### Naming Convention

The `post_mvw_script` function refreshes materialized views that match the pattern `mvw%`. If your materialized views use a different naming convention, you may need to modify line 39-41 in `post_mvw_script.sql`.

### Temporary Tables

The functions use temporary tables that persist for the session:
- `dependent_views`
- `index_def_tbl`
- `policy_def_tbl`

These are automatically cleaned up at the end of `post_mvw_script`, but will also be dropped at session end.

### Permissions

Ensure the executing role has:
- `SELECT` on system catalogs (`pg_class`, `pg_depend`, `pg_rewrite`, etc.)
- `CREATE` and `DROP` permissions on views and materialized views
- Ability to create and drop RLS policies
- Ability to create temporary tables

### Limitations

1. **Same Session Required**: Both functions must run in the same session (the temp tables are session-scoped)
2. **Schema Assumption**: Views are assumed to be in the configured schema
3. **Single View**: Designed for one materialized view at a time
4. **Return Values Unused**: Functions return tables but these are not currently utilized

## Troubleshooting

### "relation does not exist" errors

Check that:
1. The view name is spelled correctly
2. The schema is set correctly in both functions
3. The view exists before calling `pre_mvw_script`

### RLS policy recreation fails

Ensure that:
1. Roles referenced in policies still exist
2. You have permission to create policies
3. RLS is enabled on the table if needed

### Dependent views not recreating

Check the `dependent_views` temp table before it's dropped:
```sql
SELECT * FROM dependent_views ORDER BY level;
```

This shows the dependency hierarchy and definitions being used.

## How It Handles Edge Cases

- **No dependencies**: Functions return early without errors
- **Missing temp tables**: `post_mvw_script` checks for temp table existence
- **Duplicate dependencies**: Uses `ROW_NUMBER()` to deduplicate view definitions
- **Circular dependencies**: PostgreSQL's catalog prevents true circular view dependencies

## Advanced: Understanding the Dependency Query

The recursive CTE in `pre_mvw_script` queries:

- **pg_depend**: Tracks dependencies between database objects
- **pg_rewrite**: Stores view rewrite rules (view definitions)
- **pg_class**: Catalog of all relations (tables, views, materialized views)

Filters:
- `relkind IN ('v', 'm')`: Only views (v) and materialized views (m)
- `deptype = 'n'`: Normal dependencies (not automatic/internal)
- `classid = 'pg_rewrite'::regclass`: Dependency source is a rewrite rule

## Contributing

When modifying these functions:
1. Test thoroughly with complex dependency chains
2. Verify RLS policies are preserved correctly
3. Check that indexes are recreated with the same definitions
4. Test with both regular and materialized dependent views

## See Also

- [PostgreSQL Materialized Views Documentation](https://www.postgresql.org/docs/current/sql-creatematerializedview.html)
- [PostgreSQL System Catalogs](https://www.postgresql.org/docs/current/catalogs.html)
- [Row Level Security](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
