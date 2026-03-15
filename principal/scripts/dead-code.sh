#!/usr/bin/env bash
# dead-code.sh — Find potentially dead code (unused exports, functions, types)
# Usage: bash dead-code.sh [path] [--lang=ts|py|java]
# All operations are read-only (grep/find only).
# Supported languages: TypeScript/JavaScript, Python, Java

set -euo pipefail

TARGET="${1:-.}"
LANG_OVERRIDE="${2:-}"
LANG="${LANG_OVERRIDE#--lang=}"

echo "=== Dead Code Analysis ==="
echo "Path: $TARGET"
echo ""

# --- Auto-detect language ---
if [ -z "$LANG" ]; then
  TS_COUNT=$(find "$TARGET" -name "*.ts" -not -path "*/node_modules/*" -not -path "*/dist/*" 2>/dev/null | wc -l | tr -d ' ')
  PY_COUNT=$(find "$TARGET" -name "*.py" -not -path "*/__pycache__/*" -not -path "*/venv/*" 2>/dev/null | wc -l | tr -d ' ')
  JAVA_COUNT=$(find "$TARGET" -name "*.java" -not -path "*/build/*" -not -path "*/target/*" 2>/dev/null | wc -l | tr -d ' ')

  if [ "$TS_COUNT" -gt "$PY_COUNT" ] && [ "$TS_COUNT" -gt "$JAVA_COUNT" ]; then
    LANG="ts"
  elif [ "$PY_COUNT" -gt "$JAVA_COUNT" ]; then
    LANG="py"
  elif [ "$JAVA_COUNT" -gt 0 ]; then
    LANG="java"
  else
    echo "No supported language detected (TypeScript/JavaScript, Python, Java)."
    echo "Provide language explicitly: bash dead-code.sh . --lang=ts|py|java"
    exit 0
  fi
fi

echo "Detected language: $LANG"
echo ""

case "$LANG" in
  ts|typescript|js|javascript)
    # --- TypeScript/JavaScript: Find exported symbols not imported elsewhere ---
    echo "--- Exported but Potentially Unused Symbols ---"
    echo ""
    printf "%-50s %-30s %-5s\n" "Symbol" "Defined in" "Used?"
    printf "%-50s %-30s %-5s\n" "--------------------------------------------------" "------------------------------" "-----"

    # Find all named exports
    grep -rn "export\s\+\(function\|class\|const\|let\|type\|interface\|enum\)\s\+" \
      --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
      "$TARGET" 2>/dev/null | \
      grep -v "node_modules\|dist\|build\|\.test\.\|\.spec\.\|__test__\|__mock__" | \
    while IFS=: read -r file line content; do
      # Extract symbol name
      symbol=$(echo "$content" | sed -E 's/.*export\s+(function|class|const|let|type|interface|enum)\s+([a-zA-Z_][a-zA-Z0-9_]*).*/\2/')

      # Skip common false positives
      if echo "$symbol" | grep -qE "^(default|module|exports|__esModule)$"; then
        continue
      fi

      # Check if symbol is imported/used anywhere else
      usage_count=$(grep -rn "\b${symbol}\b" \
        --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
        "$TARGET" 2>/dev/null | \
        grep -v "node_modules\|dist\|build" | \
        grep -v "$file" | \
        wc -l | tr -d ' ')

      if [ "$usage_count" -eq 0 ]; then
        short_file=$(echo "$file" | sed "s|^$TARGET/||")
        printf "%-50s %-30s %-5s\n" "$symbol" "$short_file" "❌ 0"
      fi
    done | head -30

    echo ""

    # --- Files with zero imports (potentially orphaned) ---
    echo "--- Potentially Orphaned Files (not imported anywhere) ---"
    find "$TARGET" -name "*.ts" -not -name "*.test.*" -not -name "*.spec.*" \
      -not -name "index.ts" -not -name "*.d.ts" \
      -not -path "*/node_modules/*" -not -path "*/dist/*" -not -path "*/build/*" \
      2>/dev/null | while read -r file; do
      basename_no_ext=$(basename "$file" .ts)
      short_path=$(echo "$file" | sed "s|^$TARGET/||")

      # Check if this file is imported anywhere
      import_count=$(grep -rn "from.*['\"].*${basename_no_ext}['\"]" \
        --include="*.ts" --include="*.tsx" \
        "$TARGET" 2>/dev/null | \
        grep -v "node_modules\|dist" | \
        grep -v "$file" | \
        wc -l | tr -d ' ')

      if [ "$import_count" -eq 0 ]; then
        echo "  $short_path (0 imports)"
      fi
    done | head -20
    ;;

  py|python)
    echo "--- Defined but Potentially Unused Functions/Classes ---"
    echo ""

    grep -rn "^def \|^class " \
      --include="*.py" "$TARGET" 2>/dev/null | \
      grep -v "__pycache__\|venv\|\.egg\|test_\|_test\.\|conftest" | \
    while IFS=: read -r file line content; do
      symbol=$(echo "$content" | sed -E 's/^(def|class)\s+([a-zA-Z_][a-zA-Z0-9_]*).*/\2/')

      # Skip private and magic methods
      if echo "$symbol" | grep -qE "^_"; then
        continue
      fi

      usage_count=$(grep -rn "\b${symbol}\b" \
        --include="*.py" "$TARGET" 2>/dev/null | \
        grep -v "__pycache__\|venv" | \
        grep -v "$file" | \
        wc -l | tr -d ' ')

      if [ "$usage_count" -eq 0 ]; then
        short_file=$(echo "$file" | sed "s|^$TARGET/||")
        echo "  $symbol (in $short_file) — 0 external references"
      fi
    done | head -30
    ;;

  java|Java)
    echo "--- Public Methods/Classes Potentially Unused ---"
    echo ""
    echo "Note: Java static analysis is best done with IntelliJ IDEA (Analyze > Inspect Code)"
    echo "or SpotBugs/PMD. This script provides a heuristic grep-based analysis."
    echo ""

    # Find public classes/methods not referenced elsewhere
    grep -rn "public\s\+\(class\|interface\|enum\|static.*void\|static.*String\|static.*int\|static.*boolean\)" \
      --include="*.java" "$TARGET" 2>/dev/null | \
      grep -v "target/\|build/\|Test\.java\|IT\.java\|@Override\|@Test\|@Bean\|@Controller\|@Service\|@Repository\|@Component" | \
    while IFS=: read -r file line content; do
      # Extract class/method name
      symbol=$(echo "$content" | sed -E 's/.*\b(class|interface|enum|void|static)\s+([a-zA-Z_][a-zA-Z0-9_]*).*/\2/' | head -1)

      # Skip common Spring/framework patterns that are referenced by container
      if echo "$symbol" | grep -qE "^(main|Application|Config|Controller|Service|Repository|Entity)"; then
        continue
      fi

      usage_count=$(grep -rn "\b${symbol}\b" \
        --include="*.java" "$TARGET" 2>/dev/null | \
        grep -v "target/\|build/" | \
        grep -v "^${file}:" | \
        wc -l | tr -d ' ')

      if [ "$usage_count" -eq 0 ]; then
        short_file=$(echo "$file" | sed "s|^$TARGET/||")
        echo "  $symbol (in $short_file) — 0 external references"
      fi
    done | head -30

    echo ""
    echo "For comprehensive Java dead code analysis, use:"
    echo "  IntelliJ IDEA: Analyze > Run Inspection by Name > 'Unused declaration'"
    echo "  SpotBugs: https://spotbugs.github.io/"
    echo "  PMD: pmd check -d src/main/java -R rulesets/java/quickstart.xml"
    ;;
esac

echo ""
echo "--- Summary ---"
echo "Note: This is a heuristic analysis. False positives include:"
echo "  - Symbols used via reflection, dynamic import, or string reference"
echo "  - Symbols used by external consumers (published libraries)"
echo "  - Entry points (main, handlers registered at runtime)"
echo "Review each finding before removing code."
