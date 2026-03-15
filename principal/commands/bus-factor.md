---
---
description: Analyze code ownership concentration and knowledge silos from git history
---

Given the repository or path specified in $ARGUMENTS (or the current repo if none specified):

1. **Compute per-directory ownership** using git history:
   ```bash
   # Top contributors by directory (last 12 months)
   for dir in $(find . -maxdepth 2 -type d -not -path '*/\.*' -not -path '*/node_modules/*' -not -path '*/vendor/*' | head -30); do
     echo "=== $dir ==="
     git log --since="12 months ago" --pretty=format:"%an" -- "$dir" 2>/dev/null | sort | uniq -c | sort -rn | head -5
     echo ""
   done
   ```

2. **Identify knowledge silos** (bus factor = 1):
   ```bash
   # Files with only one author in the last 12 months
   git log --since="12 months ago" --pretty=format:"%an" --name-only -- . 2>/dev/null | \
     awk '/^$/{author=""} /^[^\/]/{if(!author){author=$0}else{files[$0]=files[$0] " " author}}' | head -50

   # Simpler: shortlog by directory
   git shortlog -sn --since="12 months ago" -- . | head -20
   ```

3. **Calculate bus factor per module:**

   | Bus Factor | Definition | Risk |
   |-----------|------------|------|
   | 1 | One person wrote >80% of recent changes | **Critical** — knowledge trapped |
   | 2 | Two people cover >80% | **Medium** — fragile |
   | 3+ | Three or more contributors | **Healthy** |

4. **Output a risk table:**
   ```
   | Module/Directory | Bus Factor | Primary Author (%) | Secondary (%) | Risk |
   |-----------------|-----------|-------------------|--------------|------|
   ```

5. **Recommendations** based on findings:
   - Bus factor 1 modules → recommend pair programming rotation or documentation sprint
   - Concentration >70% single author on critical path → recommend code review policy requiring cross-team reviewer
   - Modules with zero commits in 6+ months → flag as potentially abandoned code

6. State the **overall organizational risk**: "X out of Y modules have bus factor 1. Critical path modules at risk: [list]."

> **For a full automated scan across all directories**, run the bundled script directly:
> ```bash
> bash principal/scripts/bus-factor.sh [repo-path]
> ```
> The script runs the git history analysis systematically across every directory and produces a formatted ownership report. This command provides the interpretation framework; the script provides the raw data.

---
