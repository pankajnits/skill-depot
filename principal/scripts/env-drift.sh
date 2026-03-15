#!/usr/bin/env bash
# env-drift.sh — Detect environment variable drift between .env.example and code
#
# Finds all environment variables referenced in source code and compares
# them against .env.example (or .env.sample / .env.template).
#
# Why this matters: Missing env vars = silent failures or crashes at startup.
# Teams add env vars to code but forget to document them in .env.example.
# New developers and deployments then fail mysteriously.
#
# Usage:
#   bash env-drift.sh [project-directory]    # defaults to current directory
#
# Supports: Node.js (process.env), Python (os.environ/os.getenv), Java (@Value/@ConfigurationProperties)
# Read-only: makes no changes to any files.
# Exit code: 0 = no drift, 1 = drift found

set -euo pipefail

TARGET="${1:-.}"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
RESET='\033[0m'
BOLD='\033[1m'

DRIFT_COUNT=0

info() { echo -e "${BLUE}ℹ${RESET}  $1"; }
pass() { echo -e "${GREEN}✅ PASS${RESET}  $1"; }
warn() { echo -e "${YELLOW}⚠️  WARN${RESET}  $1"; }
fail() { echo -e "${RED}❌ DRIFT${RESET} $1"; ((DRIFT_COUNT++)); }

echo ""
echo -e "${BOLD}Environment Variable Drift Check: ${TARGET}${RESET}"
echo "════════════════════════════════════════════════════════════"
echo ""

cd "$TARGET"

# ── Find .env.example file ────────────────────────────────────────
ENV_EXAMPLE=""
for candidate in ".env.example" ".env.sample" ".env.template" ".env.defaults" ".env.dist"; do
  if [[ -f "$candidate" ]]; then
    ENV_EXAMPLE="$candidate"
    break
  fi
done

if [[ -z "$ENV_EXAMPLE" ]]; then
  warn "No .env.example found (looked for: .env.example, .env.sample, .env.template)"
  echo "         This is itself a documentation debt — create .env.example with all required vars"
  echo ""
  info "Listing all env vars referenced in code (no baseline to compare against):"
  echo ""
else
  info "Baseline file: $ENV_EXAMPLE"
  DOCUMENTED_COUNT=$(grep -v "^#\|^$" "$ENV_EXAMPLE" 2>/dev/null | grep "=" | wc -l | tr -d ' ')
  info "Documented variables: $DOCUMENTED_COUNT"
fi

echo ""

# ── Extract env vars from source code ────────────────────────────
TMP_USED=$(mktemp /tmp/env-used-XXXXXX.txt)
TMP_DOCUMENTED=$(mktemp /tmp/env-documented-XXXXXX.txt)

# Node.js: process.env.VAR_NAME or process.env['VAR_NAME']
grep -rn "process\.env\.\([A-Z_][A-Z0-9_]*\)\|process\.env\['\([A-Z_][A-Z0-9_]*\)'\]\|process\.env\[\"\([A-Z_][A-Z0-9_]*\)\"\]" \
  --include="*.ts" --include="*.js" --include="*.tsx" --include="*.jsx" \
  . 2>/dev/null | \
  grep -vE "node_modules|dist/|build/|\.test\.|\.spec\." | \
  grep -oE "process\.env[.\[]+'?\"?([A-Z_][A-Z0-9_]*)" | \
  sed -E "s/process\.env[.\[]+['\"]?//" | \
  sort -u >> "$TMP_USED" 2>/dev/null || true

# Python: os.environ['VAR'] or os.environ.get('VAR') or os.getenv('VAR')
grep -rn "os\.environ\['\([A-Z_][A-Z0-9_]*\)'\]\|os\.environ\.get('\([A-Z_][A-Z0-9_]*\)'\|os\.getenv('\([A-Z_][A-Z0-9_]*\)'" \
  --include="*.py" \
  . 2>/dev/null | \
  grep -vE "__pycache__|venv/|\.venv/|test_|_test\." | \
  grep -oE "(os\.environ\[|os\.environ\.get\(|os\.getenv\()['\"]([A-Z_][A-Z0-9_]*)" | \
  sed -E "s/(os\.environ\[|os\.environ\.get\(|os\.getenv\()['\"]//g" | \
  sort -u >> "$TMP_USED" 2>/dev/null || true

# Python: UPPER_CASE = os.environ... at module level (settings files)
grep -rn "^[A-Z_][A-Z0-9_]*\s*=\s*os\.environ" \
  --include="*.py" \
  . 2>/dev/null | \
  grep -vE "__pycache__|venv/|\.venv/" | \
  grep -oE "^[A-Z_][A-Z0-9_]*" | \
  sort -u >> "$TMP_USED" 2>/dev/null || true

# Java Spring Boot: @Value("${VAR_NAME}") or @Value("${VAR_NAME:default}")
grep -rn '@Value("\${[^}:]*' \
  --include="*.java" \
  . 2>/dev/null | \
  grep -vE "target/|build/|Test\.java" | \
  grep -oE '\$\{[A-Z_][A-Z0-9_.]*' | \
  sed 's/\${//' | \
  tr '.' '_' | \
  sort -u >> "$TMP_USED" 2>/dev/null || true

# Java Spring Boot: application.properties / application.yml references
grep -rn "^\([A-Z_][A-Z0-9_.]*\)\s*=" \
  src/main/resources/application*.properties \
  2>/dev/null | \
  grep -oE "^[A-Z_][A-Z0-9_.]*" | \
  tr '.' '_' | \
  sort -u >> "$TMP_USED" 2>/dev/null || true

# Node.js Next.js: NEXT_PUBLIC_ vars and env() from @vercel/env
grep -rn "env\.[A-Z_][A-Z0-9_]*\|NEXT_PUBLIC_[A-Z_][A-Z0-9_]*" \
  --include="*.ts" --include="*.tsx" \
  . 2>/dev/null | \
  grep -vE "node_modules|dist/" | \
  grep -oE "NEXT_PUBLIC_[A-Z_][A-Z0-9_]*" | \
  sort -u >> "$TMP_USED" 2>/dev/null || true

# Deduplicate all referenced vars
sort -u "$TMP_USED" -o "$TMP_USED"

USED_COUNT=$(wc -l < "$TMP_USED" | tr -d ' ')
info "Environment variables referenced in code: $USED_COUNT"
echo ""

# ── Extract documented vars from .env.example ──────────────────
if [[ -n "$ENV_EXAMPLE" ]]; then
  grep -v "^#\|^$" "$ENV_EXAMPLE" 2>/dev/null | \
    grep "=" | \
    cut -d'=' -f1 | \
    tr -d ' ' | \
    sort -u > "$TMP_DOCUMENTED"

  # ── Section 1: Vars in code but NOT in .env.example ────────────
  echo -e "${BOLD}1. Used in code but NOT documented in ${ENV_EXAMPLE}${RESET}"
  echo "────────────────────────────────────────"
  MISSING=$(comm -23 "$TMP_USED" "$TMP_DOCUMENTED" 2>/dev/null || true)
  if [[ -n "$MISSING" ]]; then
    fail "The following vars are used in code but missing from ${ENV_EXAMPLE}:"
    echo "$MISSING" | while IFS= read -r var; do
      # Find where it's referenced
      LOCATION=$(grep -rn "$var" \
        --include="*.ts" --include="*.js" --include="*.py" --include="*.java" \
        . 2>/dev/null | \
        grep -vE "node_modules|dist/|build/|__pycache__" | \
        head -1 | cut -d: -f1-2 || echo "unknown")
      echo "    $var  ← $LOCATION"
    done
    DRIFT_COUNT=$((DRIFT_COUNT + $(echo "$MISSING" | wc -l | tr -d ' ')))
  else
    pass "All code-referenced vars are documented in ${ENV_EXAMPLE}"
  fi

  echo ""

  # ── Section 2: Vars in .env.example NOT used in code (stale docs) ──
  echo -e "${BOLD}2. Documented in ${ENV_EXAMPLE} but NOT found in code (stale)${RESET}"
  echo "────────────────────────────────────────"
  STALE=$(comm -13 "$TMP_USED" "$TMP_DOCUMENTED" 2>/dev/null || true)
  if [[ -n "$STALE" ]]; then
    warn "These vars are documented but no code references found:"
    echo "$STALE" | while IFS= read -r var; do
      echo "    $var"
    done
    echo ""
    echo "    Note: These may be legitimate (used by scripts, Docker, infrastructure)"
    echo "          or they may be stale documentation. Review manually."
  else
    pass "All documented vars are referenced in code"
  fi

  echo ""
fi

# ── Section 3: Full env var inventory ────────────────────────────
echo -e "${BOLD}3. Full Environment Variable Inventory${RESET}"
echo "────────────────────────────────────────"
if [[ -s "$TMP_USED" ]]; then
  echo "Variables referenced in this codebase:"
  echo ""
  printf "  %-45s %-10s\n" "Variable" "Documented?"
  printf "  %-45s %-10s\n" "---------------------------------------------" "----------"

  while IFS= read -r var; do
    if [[ -n "$ENV_EXAMPLE" ]] && grep -qE "^${var}=" "$ENV_EXAMPLE" 2>/dev/null; then
      DOCUMENTED="${GREEN}✅ yes${RESET}"
    elif [[ -n "$ENV_EXAMPLE" ]]; then
      DOCUMENTED="${RED}❌ NO${RESET}"
    else
      DOCUMENTED="${YELLOW}?${RESET}"
    fi
    printf "  %-45s " "$var"
    echo -e "$DOCUMENTED"
  done < "$TMP_USED"
else
  info "No environment variables detected in code"
  info "Checked patterns: process.env.X, os.environ['X'], os.getenv('X'), @Value(\"\${X}\")"
fi

echo ""

# ── Section 4: .env files that should not be committed ───────────
echo -e "${BOLD}4. .env Security Check${RESET}"
echo "────────────────────────────────────────"

# Check actual .env files exist and what's in them
for envfile in ".env" ".env.local" ".env.production" ".env.staging"; do
  if [[ -f "$envfile" ]]; then
    warn "$envfile exists — verify it's NOT committed to git"
    if git rev-parse --git-dir >/dev/null 2>&1; then
      if git ls-files --error-unmatch "$envfile" >/dev/null 2>&1; then
        fail "$envfile is TRACKED by git — contains real credentials?"
      else
        pass "$envfile is untracked (not committed)"
      fi
    fi
  fi
done

if [[ -f ".gitignore" ]]; then
  if grep -qE "^\.env$|^\.env\b" .gitignore 2>/dev/null; then
    pass ".env is in .gitignore"
  else
    warn ".env not in .gitignore — add: echo '.env*' >> .gitignore  (but NOT .env.example)"
  fi
fi

# Cleanup
rm -f "$TMP_USED" "$TMP_DOCUMENTED"

echo ""

# ══ Summary ════════════════════════════════════════════════════
echo "════════════════════════════════════════════════════════════"
echo -e "${BOLD}Summary${RESET}"
echo ""
if [[ $DRIFT_COUNT -eq 0 ]]; then
  echo -e "${GREEN}✅ No env var drift detected${RESET}"
else
  echo -e "${RED}⚠️  $DRIFT_COUNT undocumented environment variable(s) found${RESET}"
  echo ""
  echo "  Fix: Add each missing var to ${ENV_EXAMPLE:-'.env.example'}:"
  echo "       VAR_NAME=your_description_or_placeholder_value"
  echo ""
  echo "  Best practice template for .env.example entries:"
  echo "    # Required: description of what this is and where to get it"
  echo "    DATABASE_URL=postgresql://user:password@localhost:5432/dbname"
  echo "    # Optional (default: 3000)"
  echo "    PORT=3000"
fi
echo ""

[[ $DRIFT_COUNT -eq 0 ]] && exit 0 || exit 1
