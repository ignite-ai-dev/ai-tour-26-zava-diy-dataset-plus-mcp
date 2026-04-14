#!/bin/bash
set -e

echo "🚀 Initializing Zava PostgreSQL Database..."

PGUSER="${POSTGRES_USER:-postgres}"
BACKUP_FILE="/docker-entrypoint-initdb.d/zava.backup"

# Create the zava database
psql -v ON_ERROR_STOP=1 --username "$PGUSER" --dbname "postgres" <<-EOSQL
    CREATE DATABASE zava;
    GRANT ALL PRIVILEGES ON DATABASE zava TO "$PGUSER";
EOSQL

# Install pgvector extension (required)
psql -v ON_ERROR_STOP=1 --username "$PGUSER" --dbname "zava" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS vector;
EOSQL

# Try pg_diskann (Azure-only extension — silently skip if unavailable)
psql --username "$PGUSER" --dbname "zava" \
    -c "CREATE EXTENSION IF NOT EXISTS pg_diskann CASCADE;" 2>/dev/null \
    && echo "✅ pg_diskann installed" \
    || echo "⚠️  pg_diskann not available (Azure-only), skipping"

# Create store_manager user for Row Level Security testing
psql -v ON_ERROR_STOP=1 --username "$PGUSER" --dbname "zava" <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'store_manager') THEN
            CREATE USER store_manager WITH PASSWORD 'StoreManager123!';
            GRANT CONNECT ON DATABASE zava TO store_manager;
        END IF;
    END
    \$\$;
EOSQL

# Restore the backup
echo "📂 Restoring Zava data from backup..."
RESTORE_OUTPUT=$(mktemp)
pg_restore --username "$PGUSER" --dbname "zava" \
    --clean --if-exists --no-owner --no-privileges \
    "$BACKUP_FILE" 2>"$RESTORE_OUTPUT" || true

if grep -q "FATAL\|could not connect" "$RESTORE_OUTPUT"; then
    echo "❌ Restoration failed:"
    cat "$RESTORE_OUTPUT" | tail -20
    exit 1
else
    echo "✅ Restoration completed (warnings about RLS policies are normal)"
fi
rm -f "$RESTORE_OUTPUT"

# Re-enable RLS and recreate policies after restoration
psql -v ON_ERROR_STOP=1 --username "$PGUSER" --dbname "zava" <<-EOSQL
    DO \$\$
    BEGIN
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'retail'
              AND table_name = 'customers'
              AND column_name = 'rls_user_id'
        ) THEN
            ALTER TABLE retail.customers ENABLE ROW LEVEL SECURITY;
            DROP POLICY IF EXISTS customers_manager_policy ON retail.customers;
            CREATE POLICY customers_manager_policy ON retail.customers
                FOR ALL TO store_manager
                USING (rls_user_id = current_setting('app.current_rls_user_id')::integer);

            ALTER TABLE retail.orders ENABLE ROW LEVEL SECURITY;
            DROP POLICY IF EXISTS orders_manager_policy ON retail.orders;
            CREATE POLICY orders_manager_policy ON retail.orders
                FOR ALL TO store_manager
                USING (rls_user_id = current_setting('app.current_rls_user_id')::integer);

            ALTER TABLE retail.order_items ENABLE ROW LEVEL SECURITY;
            DROP POLICY IF EXISTS order_items_manager_policy ON retail.order_items;
            CREATE POLICY order_items_manager_policy ON retail.order_items
                FOR ALL TO store_manager
                USING (EXISTS (
                    SELECT 1 FROM retail.orders o
                    WHERE o.order_id = order_items.order_id
                      AND o.rls_user_id = current_setting('app.current_rls_user_id')::integer
                ));

            ALTER TABLE retail.inventory ENABLE ROW LEVEL SECURITY;
            DROP POLICY IF EXISTS inventory_manager_policy ON retail.inventory;
            CREATE POLICY inventory_manager_policy ON retail.inventory
                FOR ALL TO store_manager
                USING (rls_user_id = current_setting('app.current_rls_user_id')::integer);

            RAISE NOTICE 'RLS policies recreated successfully';
        ELSE
            RAISE NOTICE 'No rls_user_id column found, skipping RLS policy setup';
        END IF;
    END
    \$\$;
EOSQL

# Re-grant permissions to store_manager
psql -v ON_ERROR_STOP=1 --username "$PGUSER" --dbname "zava" <<-EOSQL
    GRANT USAGE ON SCHEMA retail TO store_manager;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA retail TO store_manager;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA retail TO store_manager;
EOSQL

echo "🎯 Zava database initialization complete!"
