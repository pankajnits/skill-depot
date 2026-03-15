#!/usr/bin/env bash
# secret-scan.sh — Detect secrets and credentials leaked in source code or git history
#
# Uses gitleaks (https://github.com/gitleaks/gitleaks, MIT license) as the primary scanner.
# Falls back to grep-based heuristic patterns if gitleaks is not installed.
#
# Usage:
#   bash secret-scan.sh [directory]          # Scan working directory
#   bash secret-scan.sh [directory] --git    # Scan full git history (slower, thorough)
#   bash secret-scan.sh [directory] --staged # Scan staged files only (pre-commit hook)
#
# Read-only: makes no changes to any files.
# Exit code: 0 = no secrets found, 1 = secrets detected

set -euo pipefail

TARGET="${1:-.}"
MODE="${2:-}"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
RESET='\033[0m'
BOLD='\033[1m'

SECRETS_FOUND=0

info()  { echo -e "${BLUE}ℹ${RESET}  $1"; }
pass()  { echo -e "${GREEN}✅ PASS${RESET}  $1"; }
warn()  { echo -e "${YELLOW}⚠️  WARN${RESET}  $1"; }
fail()  { echo -e "${RED}❌ FOUND${RESET} $1"; ((SECRETS_FOUND++)); }

echo ""
echo -e "${BOLD}Secret & Credential Scan: ${TARGET}${RESET}"
echo "════════════════════════════════════════════════════════════"
echo ""

cd "$TARGET"

# ── Check for gitleaks ────────────────────────────────────────────
GITLEAKS_AVAILABLE=false
if command -v gitleaks &>/dev/null; then
  GITLEAKS_AVAILABLE=true
  GITLEAKS_VERSION=$(gitleaks version 2>/dev/null || echo "unknown")
  info "gitleaks found: $GITLEAKS_VERSION"
else
  warn "gitleaks not installed — falling back to grep heuristics"
  echo "         Install: brew install gitleaks   # macOS"
  echo "                  or: https://github.com/gitleaks/gitleaks/releases"
  echo ""
fi

# ══ Section 1: gitleaks scan ════════════════════════════════════
echo -e "${BOLD}1. Automated Secret Detection (gitleaks)${RESET}"
echo "────────────────────────────────────────"

if $GITLEAKS_AVAILABLE; then
  # Create a temp file for gitleaks JSON output
  TMPOUT=$(mktemp /tmp/gitleaks-XXXXXX.json)

  if [[ "$MODE" == "--git" ]]; then
    info "Scanning full git history (this may take a while)..."
    gitleaks git --source . --report-format json --report-path "$TMPOUT" --exit-code 0 2>/dev/null || true
  elif [[ "$MODE" == "--staged" ]]; then
    info "Scanning staged files only (pre-commit mode)..."
    gitleaks protect --staged --report-format json --report-path "$TMPOUT" --exit-code 0 2>/dev/null || true
  else
    info "Scanning working directory..."
    gitleaks detect --source . --report-format json --report-path "$TMPOUT" --exit-code 0 2>/dev/null || true
  fi

  if [[ -s "$TMPOUT" ]]; then
    FINDING_COUNT=$(python3 -c "
import json, sys
try:
    data = json.load(open('$TMPOUT'))
    if isinstance(data, list):
        print(len(data))
    else:
        print(0)
except:
    print(0)
" 2>/dev/null || echo 0)

    if [[ "$FINDING_COUNT" -gt 0 ]]; then
      echo -e "${RED}⚠️  $FINDING_COUNT secret(s) detected by gitleaks:${RESET}"
      echo ""
      python3 -c "
import json, sys
try:
    findings = json.load(open('$TMPOUT'))
    if not isinstance(findings, list): findings = []
    for f in findings[:20]:
        rule = f.get('RuleID', f.get('ruleID', 'unknown'))
        file = f.get('File', f.get('file', 'unknown'))
        line = f.get('StartLine', f.get('startLine', '?'))
        secret_partial = (f.get('Secret', f.get('secret', '')) or '')[:8]
        print(f'  [{rule}] {file}:{line}  (starts: {secret_partial}...)')
except Exception as e:
    print(f'  Could not parse gitleaks output: {e}')
" 2>/dev/null
      SECRETS_FOUND=$((SECRETS_FOUND + FINDING_COUNT))
      echo ""
      echo "  Full report saved to: $TMPOUT"
      echo "  Review each finding. For false positives, add to .gitleaks.toml:"
      echo '  [[rules.allowlists]]'
      echo '  description = "test fixture"'
      echo '  paths = ["test/fixtures/*"]'
    else
      pass "No secrets detected by gitleaks"
      rm -f "$TMPOUT"
    fi
  else
    pass "No secrets detected by gitleaks"
    rm -f "$TMPOUT"
  fi
else
  warn "Skipping gitleaks scan (not installed)"
fi

echo ""

# ══ Section 2: Grep heuristics (always runs — catches patterns gitleaks might miss) ══
echo -e "${BOLD}2. Pattern-Based Secret Detection (grep)${RESET}"
echo "────────────────────────────────────────"

# Build exclude pattern
EXCLUDE_DIRS="node_modules|\.git|dist|build|target|__pycache__|\.venv|venv|\.next"

# Function to search for pattern and report
check_pattern() {
  local desc="$1"
  local pattern="$2"
  local safe_pattern="${3:-}"  # pattern that makes it safe (exclude these)

  local results
  if [[ -n "$safe_pattern" ]]; then
    results=$(grep -rn "$pattern" . \
      --include="*.ts" --include="*.js" --include="*.py" --include="*.java" \
      --include="*.env" --include="*.yml" --include="*.yaml" --include="*.json" \
      --include="*.properties" --include="*.xml" --include="*.conf" \
      2>/dev/null | \
      grep -vE "($EXCLUDE_DIRS)" | \
      grep -v "\.test\.\|\.spec\.\|test_\|_test\." | \
      grep -vE "$safe_pattern" | \
      grep -v "example\|sample\|placeholder\|YOUR_\|<.*>\|{.*}\|\${\|process\.env\|os\.environ\|os\.getenv\|@Value\|getenv\|env\[" | \
      head -5 || true)
  else
    results=$(grep -rn "$pattern" . \
      --include="*.ts" --include="*.js" --include="*.py" --include="*.java" \
      --include="*.env" --include="*.yml" --include="*.yaml" --include="*.json" \
      --include="*.properties" --include="*.xml" --include="*.conf" \
      2>/dev/null | \
      grep -vE "($EXCLUDE_DIRS)" | \
      grep -v "\.test\.\|\.spec\.\|test_\|_test\." | \
      grep -v "example\|sample\|placeholder\|YOUR_\|<.*>\|{.*}\|\${\|process\.env\|os\.environ\|os\.getenv\|@Value\|getenv\|env\[" | \
      head -5 || true)
  fi

  if [[ -n "$results" ]]; then
    fail "$desc — potential hardcoded secret:"
    echo "$results" | while IFS= read -r line; do
      echo "    $line"
    done
  fi
}

# High-confidence secret patterns
check_pattern "Hardcoded AWS Access Key" \
  "AKIA[0-9A-Z]{16}" ""

check_pattern "Hardcoded AWS Secret Key" \
  "aws_secret_access_key\s*=\s*['\"][^'\"]{30,}" "=#\|=\s*$\|env\|secret_access_key.*\\\$"

check_pattern "Hardcoded private key (PEM)" \
  "BEGIN.*PRIVATE KEY"  ""

check_pattern "Hardcoded generic API key/secret" \
  "api[_-]?key\s*[=:]\s*['\"][a-zA-Z0-9_\-]{20,}" ""

check_pattern "Hardcoded password in code" \
  "password\s*=\s*['\"][^'\"]{6,}" "bcrypt\|hash\|test\|password123\|changeme\|example"

check_pattern "JWT token hardcoded" \
  "eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*" ""

check_pattern "Hardcoded database URL with credentials" \
  "postgresql://\|mysql://\|mongodb://" "localhost\|127\.0\.0\.1\|@db\|env\|getenv\|\${"

check_pattern "Payment provider live key hardcoded" \
  "rzp_live_\|rzp_test_\|sk_live_\|pk_live_\|payu.*key" ""

check_pattern "Slack/Discord webhook hardcoded" \
  "hooks\.slack\.com/services\|discord.*webhook" ""

check_pattern "Google API key hardcoded" \
  "AIza[0-9A-Za-z_-]{35}" ""

# ── Check .env files committed to git ────────────────────────────
echo ""
echo -e "${BOLD}3. Committed .env Files Check${RESET}"
echo "────────────────────────────────────────"

if git rev-parse --git-dir >/dev/null 2>&1; then
  # Check if any .env files are tracked by git (not in .gitignore)
  TRACKED_ENVS=$(git ls-files | grep -E "^\.env$|^\.env\." | grep -v "example\|sample\|test\|template" || true)
  if [[ -n "$TRACKED_ENVS" ]]; then
    fail ".env file(s) committed to git (should be in .gitignore):"
    echo "$TRACKED_ENVS" | while IFS= read -r f; do echo "    $f"; done
    SECRETS_FOUND=$((SECRETS_FOUND + 1))
  else
    pass "No .env files tracked by git"
  fi

  # Check .gitignore covers .env
  if [[ -f ".gitignore" ]]; then
    if grep -q "^\\.env" .gitignore 2>/dev/null; then
      pass ".env is in .gitignore"
    else
      warn ".env is not in .gitignore — add: echo '.env' >> .gitignore"
    fi
  else
    warn "No .gitignore file found"
  fi
else
  info "Not a git repo — skipping git checks"
fi

echo ""

# ── Check CI/CD configs for leaked secrets ──────────────────────
echo -e "${BOLD}4. CI/CD Configuration Secret Check${RESET}"
echo "────────────────────────────────────────"

CI_SECRETS=$(grep -rn "password\|secret\|token\|api.key\|private.key" \
  .github/workflows/ .gitlab-ci.yml .circleci/ Jenkinsfile \
  2>/dev/null | \
  grep -v "secrets\.\|vault\.\|\${{.*}}\|\$(.*)\|env\.\|variables\.\|#" | \
  grep -v "example\|sample\|placeholder" | \
  head -10 || true)

if [[ -n "$CI_SECRETS" ]]; then
  fail "Potential secrets in CI/CD config (not using secrets manager):"
  echo "$CI_SECRETS" | while IFS= read -r line; do echo "    $line"; done
  SECRETS_FOUND=$((SECRETS_FOUND + 1))
else
  pass "CI/CD configs use secret references (not hardcoded values)"
fi

echo ""

# ══ Summary ════════════════════════════════════════════════════
echo "════════════════════════════════════════════════════════════"
echo -e "${BOLD}Summary${RESET}"
echo ""
if [[ $SECRETS_FOUND -eq 0 ]]; then
  echo -e "${GREEN}✅ No secrets detected${RESET}"
  echo ""
  echo "Best practices checklist:"
  echo "  ✓ Use secrets managers: AWS Secrets Manager, GCP Secret Manager, HashiCorp Vault"
  echo "  ✓ Rotate secrets immediately if any were exposed"
  echo "  ✓ Add gitleaks as pre-commit hook: gitleaks protect --staged"
  echo "  ✓ Run this in CI: gitleaks detect --source . --exit-code 1"
else
  echo -e "${RED}⚠️  $SECRETS_FOUND secret category(ies) detected${RESET}"
  echo ""
  echo "  Immediate actions:"
  echo "  1. Rotate any exposed credentials NOW (before removing from code)"
  echo "  2. Move secrets to env vars or secrets manager"
  echo "  3. If exposed in git history, use git filter-repo to purge:"
  echo "     pip install git-filter-repo"
  echo "     git filter-repo --path path/to/file --invert-paths"
  echo "  4. After rotation, remove from all git commits (not just HEAD)"
  echo ""
  echo "  Tools to prevent recurrence:"
  echo "  - gitleaks pre-commit hook: gitleaks protect --staged"
  echo "  - GitHub secret scanning (free for public repos)"
  echo "  - External Secrets Operator (Kubernetes)"
fi
echo ""

[[ $SECRETS_FOUND -eq 0 ]] && exit 0 || exit 1
