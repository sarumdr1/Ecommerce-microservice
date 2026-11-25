#!/usr/bin/env bash
# Creates one database + one least-privilege user per service.
# Runs automatically on first container start because it is mounted into
# /docker-entrypoint-initdb.d/ — Postgres executes every *.sh file there
# as the superuser before accepting connections.
set -euo pipefail

create_service_db() {
  local dbname="$1"
  local username="$2"
  local password="$3"

  echo "→ Creating database '${dbname}' and user '${username}'"
  psql -U "$POSTGRES_USER" -d postgres \
    -c "CREATE USER ${username} WITH PASSWORD '${password}';"
  psql -U "$POSTGRES_USER" -d postgres \
    -c "CREATE DATABASE ${dbname} OWNER ${username};"
  # Explicit grant required for Postgres 15+ (public schema privilege revoked by default)
  psql -U "$POSTGRES_USER" -d "${dbname}" \
    -c "GRANT ALL ON SCHEMA public TO ${username};"
}

# ── Domain services ────────────────────────────────────────────────────────────
create_service_db "identity_db"     "identity_user"     "${IDENTITY_DB_PASSWORD}"
create_service_db "catalog_db"      "catalog_user"      "${CATALOG_DB_PASSWORD}"
create_service_db "cart_db"         "cart_user"         "${CART_DB_PASSWORD}"
create_service_db "order_db"        "order_user"        "${ORDER_DB_PASSWORD}"
create_service_db "inventory_db"    "inventory_user"    "${INVENTORY_DB_PASSWORD}"
create_service_db "payment_db"      "payment_user"      "${PAYMENT_DB_PASSWORD}"
create_service_db "notification_db" "notification_user" "${NOTIFICATION_DB_PASSWORD}"

# ── Agent service (needs pgvector extension) ───────────────────────────────────
create_service_db "agent_db" "agent_user" "${AGENT_DB_PASSWORD}"
psql -U "$POSTGRES_USER" -d agent_db -c "CREATE EXTENSION IF NOT EXISTS vector;"
echo "→ pgvector extension enabled in agent_db"

# ── Keycloak (identity provider) ──────────────────────────────────────────────
create_service_db "keycloak_db" "keycloak_user" "${KEYCLOAK_DB_PASSWORD}"

echo "✓ All service databases initialised."
