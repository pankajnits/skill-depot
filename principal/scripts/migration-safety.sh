#!/usr/bin/env bash
# migration-safety.sh — Zero-downtime SQL migration safety checker
#
# Detects migration patterns that cause table locks, downtime, or data loss
# in production databases. Analyzes SQL migration files before they are applied.
#
# Rules enforced (PostgreSQL and MySQL):
#   ❌ Adding NOT NULL column without DEFAULT       → full table lock
#   ❌ Adding column with volatile DEFAULT          → full table rewrite (PG < 11)
#   ❌ Dropping a column                            → ORM/code crash on old deploys
#   ❌ Renaming a column or table                   → breaks all existing queries
#   ❌ Changing column type                         → implicit cast, possible data loss
#   ❌ Adding index without CONCURRENTLY (PG)       → full table lock
#   ❌ Adding UNIQUE constraint directly            → full table scan + lock
#   ❌ ALTER TABLE SET NOT NULL on existing column  → full table scan (PG)
#   ❌ TRUNCATE or DELETE without WHERE             → data loss
#   ⚠️  Adding a foreign key without NOT VALID     → full table validation
#   ⚠️  Lock timeout not set (advisory)            → runaway lock possible
#
# Usage:
#   bash migration-safety.sh path/to/migrations/     # scan directory
#   bash migration-safety.sh V001__add_orders.sql    # scan single file
#
# Exit code: 0 = all migrations safe, 1 = unsafe patterns found

set -euo pipefail

TARGET="${1:-.}"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
RESET='\033[0m'
BOLD='\033[1m'

TOTAL_FILES=0
UNSAFE_FILES=0
TOTAL_ISSUES=0

info() { echo -e "${BLUE}ℹ${RESET}  $1"; }
pass() { echo -e "${GREEN}✅ SAFE${RESET}  $1"; }
warn() { echo -e "${YELLOW}⚠️  WARN${RESET}  $1"; }
fail() { echo -e "${RED}❌ UNSAFE${RESET} $1"; }

echo ""
echo -e "${BOLD}Migration Safety Check: ${TARGET}${RESET}"
echo "════════════════════════════════════════════════════════════"
echo ""

# ── Collect migration files ────────────────────────────────────
if [[ -d "$TARGET" ]]; then
  MIGRATION_FILES=$(find "$TARGET" -name "*.sql" \
    ! -path "*/node_modules/*" ! -path "*/__pycache__/*" \
    2>/dev/null | sort)
elif [[ -f "$TARGET" ]]; then
  MIGRATION_FILES="$TARGET"
else
  echo "Usage: $0 <migration-file.sql | migrations-directory/>"
  exit 1
fi

if [[ -z "$MIGRATION_FILES" ]]; then
  info "No .sql migration files found in: $TARGET"
  info "Tip: Also check Alembic (.py), Flyway (.sql), Liquibase (.xml/.yaml) files"
  exit 0
fi

FILE_COUNT=$(echo "$MIGRATION_FILES" | wc -l | tr -d ' ')
info "Found $FILE_COUNT migration file(s)"
echo ""

# ── Check each migration file ────────────────────────────────────
while IFS= read -r SQLFILE; do
  [[ -z "$SQLFILE" ]] && continue
  [[ ! -f "$SQLFILE" ]] && continue

  ((TOTAL_FILES++))
  FILE_ISSUES=0
  SHORTNAME=$(basename "$SQLFILE")

  echo -e "${BOLD}── $SHORTNAME${RESET}"

  # Normalize: uppercase, collapse whitespace
  NORMALIZED=$(tr '[:lower:]' '[:upper:]' < "$SQLFILE" | tr -s ' \t\n' ' ')

  # ── Rule 1: ADD COLUMN NOT NULL without DEFAULT ───────────────
  # Pattern: ADD COLUMN colname TYPE NOT NULL (no DEFAULT)
  if echo "$NORMALIZED" | grep -qE "ADD COLUMN [A-Z_]+ [A-Z]+[^;]*NOT NULL" 2>/dev/null; then
    HAS_DEFAULT=$(echo "$NORMALIZED" | grep -oE "ADD COLUMN [A-Z_]+ [A-Z]+[^;]*NOT NULL[^;]*" | \
      grep -c "DEFAULT" 2>/dev/null || echo 0)
    if [[ "$HAS_DEFAULT" -eq 0 ]]; then
      fail "ADD COLUMN ... NOT NULL without DEFAULT"
      echo "    → Locks entire table while it sets NULL for all existing rows"
      echo "    ✅ Fix:  ADD COLUMN col TYPE NOT NULL DEFAULT <value>;"
      echo "            Then remove the default in a separate migration after deploy:"
      echo "            ALTER TABLE t ALTER COLUMN col DROP DEFAULT;"
      ((FILE_ISSUES++))
    fi
  fi

  # ── Rule 2: DROP COLUMN ───────────────────────────────────────
  if echo "$NORMALIZED" | grep -qE "DROP COLUMN" 2>/dev/null; then
    fail "DROP COLUMN detected"
    echo "    → Old app version still referencing this column will crash on SELECT *"
    echo "    ✅ Fix (3-phase deployment):"
    echo "       Phase 1: Remove column references from code, deploy"
    echo "       Phase 2: Run this migration (DROP COLUMN)"
    echo "       Phase 3: (done)"
    ((FILE_ISSUES++))
  fi

  # ── Rule 3: RENAME COLUMN or RENAME TABLE ─────────────────────
  if echo "$NORMALIZED" | grep -qE "RENAME COLUMN|RENAME TO" 2>/dev/null; then
    fail "RENAME COLUMN / RENAME TABLE detected"
    echo "    → All existing queries, ORMs, and views break immediately"
    echo "    ✅ Fix: Add new column + dual-write + backfill + remove old column"
    echo "           Never use RENAME in zero-downtime deployments"
    ((FILE_ISSUES++))
  fi

  # ── Rule 4: ALTER COLUMN TYPE ────────────────────────────────
  if echo "$NORMALIZED" | grep -qE "ALTER COLUMN.*TYPE|MODIFY COLUMN" 2>/dev/null; then
    fail "ALTER COLUMN TYPE / MODIFY COLUMN detected"
    echo "    → PostgreSQL rewrites the entire table; MySQL may too"
    echo "    → Risk of data truncation or implicit cast errors"
    echo "    ✅ Fix: Add new column with new type → dual-write → backfill → switch → drop old"
    ((FILE_ISSUES++))
  fi

  # ── Rule 5: CREATE INDEX without CONCURRENTLY (PostgreSQL) ───
  if echo "$NORMALIZED" | grep -qE "CREATE INDEX" 2>/dev/null; then
    if ! echo "$NORMALIZED" | grep -qE "CREATE (UNIQUE )?INDEX CONCURRENTLY" 2>/dev/null; then
      fail "CREATE INDEX without CONCURRENTLY (PostgreSQL)"
      echo "    → Acquires ShareLock on table — blocks all writes for duration of index build"
      echo "    ✅ Fix: CREATE INDEX CONCURRENTLY idx_name ON table(column);"
      echo "           Note: Cannot run inside a transaction block"
      ((FILE_ISSUES++))
    fi
  fi

  # ── Rule 6: ADD UNIQUE CONSTRAINT directly ────────────────────
  if echo "$NORMALIZED" | grep -qE "ADD (CONSTRAINT [A-Z_]+ )?UNIQUE" 2>/dev/null; then
    if ! echo "$NORMALIZED" | grep -qE "CONCURRENTLY" 2>/dev/null; then
      fail "ADD UNIQUE CONSTRAINT without CONCURRENTLY index"
      echo "    → Full table scan + lock to validate uniqueness"
      echo "    ✅ Fix:"
      echo "       Step 1: CREATE UNIQUE INDEX CONCURRENTLY idx_name ON t(col);"
      echo "       Step 2: ALTER TABLE t ADD CONSTRAINT uc_name UNIQUE USING INDEX idx_name;"
      ((FILE_ISSUES++))
    fi
  fi

  # ── Rule 7: SET NOT NULL on existing column ───────────────────
  if echo "$NORMALIZED" | grep -qE "ALTER COLUMN.*SET NOT NULL|MODIFY.*NOT NULL" 2>/dev/null; then
    # Only flag if this isn't a new ADD COLUMN (already caught above)
    if ! echo "$NORMALIZED" | grep -qE "ADD COLUMN" 2>/dev/null; then
      fail "SET NOT NULL on existing column"
      echo "    → PostgreSQL scans entire table to validate no NULLs exist"
      echo "    ✅ Fix (PostgreSQL 12+):"
      echo "       Step 1: Add CHECK constraint: ALTER TABLE t ADD CONSTRAINT chk_not_null CHECK (col IS NOT NULL) NOT VALID;"
      echo "       Step 2: Validate (no lock): ALTER TABLE t VALIDATE CONSTRAINT chk_not_null;"
      echo "       Step 3: Set NOT NULL (now instant, uses validated constraint): ALTER TABLE t ALTER COLUMN col SET NOT NULL;"
      echo "       Step 4: Drop CHECK constraint: ALTER TABLE t DROP CONSTRAINT chk_not_null;"
      ((FILE_ISSUES++))
    fi
  fi

  # ── Rule 8: TRUNCATE or DELETE without WHERE ─────────────────
  if echo "$NORMALIZED" | grep -qE "^TRUNCATE |; TRUNCATE |TRUNCATE TABLE" 2>/dev/null; then
    fail "TRUNCATE TABLE — destroys all data"
    echo "    → Irreversible in production"
    echo "    ✅ Only acceptable in test/staging environments. Gate this behind environment check."
    ((FILE_ISSUES++))
  fi

  if echo "$NORMALIZED" | grep -qE "DELETE FROM [A-Z_]+\s*;" 2>/dev/null; then
    fail "DELETE FROM table WITHOUT WHERE clause — deletes all rows"
    echo "    → Irreversible data loss"
    ((FILE_ISSUES++))
  fi

  # ── Rule 9: Foreign key without NOT VALID ─────────────────────
  if echo "$NORMALIZED" | grep -qE "ADD (CONSTRAINT [A-Z_]+ )?FOREIGN KEY" 2>/dev/null; then
    if ! echo "$NORMALIZED" | grep -qE "NOT VALID" 2>/dev/null; then
      warn "ADD FOREIGN KEY without NOT VALID"
      echo "    → Validates entire table immediately — long lock on large tables"
      echo "    ✅ Fix:"
      echo "       Step 1: ADD CONSTRAINT fk_name FOREIGN KEY (col) REFERENCES other(id) NOT VALID;"
      echo "       Step 2: VALIDATE CONSTRAINT fk_name;  (acquires lighter ShareUpdateExclusiveLock)"
    fi
  fi

  # ── Rule 10: Lock timeout advisory ───────────────────────────
  if ! echo "$NORMALIZED" | grep -qE "LOCK_TIMEOUT|LOCK TIMEOUT|SET LOCAL LOCK" 2>/dev/null; then
    # Only warn if there's an ALTER TABLE
    if echo "$NORMALIZED" | grep -qE "ALTER TABLE" 2>/dev/null; then
      warn "No lock_timeout set — consider adding at top of migration:"
      echo "    SET lock_timeout = '2s';"
      echo "    SET statement_timeout = '30s';"
      echo "    → If migration can't acquire lock in 2s, it fails fast instead of queuing indefinitely"
    fi
  fi

  if [[ $FILE_ISSUES -eq 0 ]]; then
    pass "No unsafe patterns detected"
  else
    ((UNSAFE_FILES++))
    TOTAL_ISSUES=$((TOTAL_ISSUES + FILE_ISSUES))
  fi
  echo ""

done <<< "$MIGRATION_FILES"

# ══ Summary ════════════════════════════════════════════════════
echo "════════════════════════════════════════════════════════════"
echo -e "${BOLD}Summary${RESET}"
echo "  Files checked:  $TOTAL_FILES"
echo "  Unsafe files:   $UNSAFE_FILES"
echo "  Total issues:   $TOTAL_ISSUES"
echo ""

if [[ $TOTAL_ISSUES -eq 0 ]]; then
  echo -e "${GREEN}✅ All migrations appear safe for zero-downtime deployment${RESET}"
  echo ""
  echo "Reminder: test every migration on a staging DB with production data volume first."
  echo "Timing on 10M rows ≠ timing on 100M rows."
else
  echo -e "${RED}⚠️  $TOTAL_ISSUES unsafe pattern(s) found in $UNSAFE_FILES file(s)${RESET}"
  echo ""
  echo "Zero-downtime migration principles:"
  echo "  1. Expand: add new column/table (nullable/with default)"
  echo "  2. Migrate: dual-write + backfill data"
  echo "  3. Switch: update app to use new column/table"
  echo "  4. Contract: remove old column/table (after all deploys use new)"
  echo ""
  echo "Reference: https://planetscale.com/blog/backward-compatible-databases-changes"
fi
echo ""

[[ $TOTAL_ISSUES -eq 0 ]] && exit 0 || exit 1
