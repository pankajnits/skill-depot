---
---
description: Audit dependencies for supply chain risk — CVEs, staleness, single-maintainer, and license issues
---

Given the project or dependency specified in $ARGUMENTS (or the current project if none specified):

1. **Detect the package ecosystem** and run the appropriate audit:
   ```bash
   # Node.js / npm
   npm audit --json 2>/dev/null | head -100

   # Node.js / yarn
   yarn audit --json 2>/dev/null | head -100

   # Python / pip
   pip-audit --format=json 2>/dev/null || pip list --outdated --format=json 2>/dev/null | head -50

   # Go
   govulncheck ./... 2>/dev/null | head -50

   # Rust
   cargo audit --json 2>/dev/null | head -100
   ```

2. **Check dependency freshness:**
   ```bash
   # Node.js — find outdated packages
   npm outdated --json 2>/dev/null | head -50

   # Python
   pip list --outdated --format=columns 2>/dev/null | head -30
   ```

3. **Assess supply chain risk signals** for each critical dependency:

   | Signal | Risk indicator | How to check |
   |--------|---------------|--------------|
   | Maintainer count | Single maintainer = bus factor 1 | Check GitHub contributors |
   | Last publish date | >12 months = potentially abandoned | `npm view PACKAGE time.modified` |
   | Download trend | Declining = ecosystem moving away | npm trends / PyPI stats |
   | License | Copyleft in commercial project = legal risk | `npm view PACKAGE license` |
   | Typosquat risk | Similar name to popular package | Manual review |

4. **Classify findings:**

   | Severity | Criteria | Action |
   |----------|----------|--------|
   | **Critical** | Known exploited CVE, no patch available | Immediate: find alternative or apply workaround |
   | **High** | CVE with patch available, or abandoned dependency in critical path | This sprint: upgrade or replace |
   | **Medium** | Outdated (>2 major versions behind), single maintainer | Next quarter: plan migration |
   | **Low** | Minor version behind, license review needed | Track: add to tech debt backlog |

5. **Output a prioritized remediation table:**
   ```
   | Package | Current | Latest | Risk | CVEs | Action |
   |---------|---------|--------|------|------|--------|
   ```

6. State the **overall supply chain health score**: Critical / At Risk / Healthy.

> **For a full automated scan with enriched output**, run the bundled script directly:
> ```bash
> bash principal/scripts/dep-audit.sh [project-path]
> ```
> The script wraps `npm audit`/`pip-audit`/OWASP Dependency-Check with formatted risk output, dep count, and freshness analysis. This command provides the interpretation framework; the script provides the raw data.

---
