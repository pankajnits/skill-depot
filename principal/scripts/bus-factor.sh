#!/usr/bin/env bash
# bus-factor.sh — Analyze code ownership concentration from git history
# Usage: bash bus-factor.sh [path] [--months=12]
# All operations are read-only (git log only).

set -euo pipefail

TARGET="${1:-.}"
MONTHS="${2:-12}"
MONTHS="${MONTHS#--months=}"

echo "=== Bus Factor Analysis ==="
echo "Path: $TARGET"
echo "Window: last $MONTHS months"
echo ""

# Per-directory ownership
echo "--- Per-Directory Ownership ---"
echo ""
printf "%-40s %-6s %-25s %-5s\n" "Directory" "Factor" "Top Contributor" "%"
printf "%-40s %-6s %-25s %-5s\n" "----------------------------------------" "------" "-------------------------" "-----"

find "$TARGET" -maxdepth 2 -type d \
  -not -path '*/\.*' \
  -not -path '*/node_modules/*' \
  -not -path '*/vendor/*' \
  -not -path '*/__pycache__/*' \
  -not -path '*/dist/*' \
  -not -path '*/build/*' | sort | while read -r dir; do

  total=$(git log --since="${MONTHS} months ago" --pretty=format:"%an" -- "$dir" 2>/dev/null | wc -l | tr -d ' ')

  if [ "$total" -lt 5 ]; then
    continue  # Skip directories with too few commits
  fi

  # Get unique contributors and their commit counts
  top_author=$(git log --since="${MONTHS} months ago" --pretty=format:"%an" -- "$dir" 2>/dev/null | sort | uniq -c | sort -rn | head -1)
  top_count=$(echo "$top_author" | awk '{print $1}')
  top_name=$(echo "$top_author" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')

  unique_authors=$(git log --since="${MONTHS} months ago" --pretty=format:"%an" -- "$dir" 2>/dev/null | sort -u | wc -l | tr -d ' ')

  # Calculate percentage
  if [ "$total" -gt 0 ]; then
    pct=$((top_count * 100 / total))
  else
    pct=0
  fi

  # Determine bus factor (authors covering 80% of commits)
  bus_factor=0
  cumulative=0
  threshold=$((total * 80 / 100))
  while IFS= read -r line; do
    count=$(echo "$line" | awk '{print $1}')
    cumulative=$((cumulative + count))
    bus_factor=$((bus_factor + 1))
    if [ "$cumulative" -ge "$threshold" ]; then
      break
    fi
  done < <(git log --since="${MONTHS} months ago" --pretty=format:"%an" -- "$dir" 2>/dev/null | sort | uniq -c | sort -rn)

  # Risk indicator
  if [ "$bus_factor" -le 1 ]; then
    risk="CRITICAL"
  elif [ "$bus_factor" -le 2 ]; then
    risk="MEDIUM"
  else
    risk="OK"
  fi

  printf "%-40s %-6s %-25s %3s%%  [%s]\n" "$dir" "$bus_factor" "$top_name" "$pct" "$risk"
done

echo ""
echo "--- Summary ---"
echo "Bus Factor 1 = CRITICAL (knowledge trapped in one person)"
echo "Bus Factor 2 = MEDIUM (fragile, one departure away from risk)"
echo "Bus Factor 3+ = OK (healthy knowledge distribution)"
