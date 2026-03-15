---
---
description: Assess the blast radius of a proposed change — affected services, consumers, and risk tier
---

Given the proposed change described in $ARGUMENTS:

1. **Identify the change scope:**
   - What files, services, APIs, or schemas are being modified?
   - If a file path is given, read it and identify what it exports/exposes.

2. **Trace downstream dependents** by running:
   ```bash
   # Find all files importing/referencing the changed module
   grep -rn "import.*CHANGED_MODULE\|require.*CHANGED_MODULE\|from.*CHANGED_MODULE" --include="*.ts" --include="*.py" --include="*.go" --include="*.java" . | grep -v node_modules | grep -v __pycache__

   # Find API consumers (if changing an API endpoint)
   grep -rn "ENDPOINT_PATH" --include="*.ts" --include="*.py" --include="*.yaml" --include="*.json" . | grep -v node_modules

   # Find database table references (if changing schema)
   grep -rn "TABLE_NAME" --include="*.ts" --include="*.py" --include="*.go" --include="*.sql" . | grep -v node_modules
   ```

3. **Classify affected consumers into tiers:**

   | Tier | Impact | Examples |
   |------|--------|---------|
   | Direct | Code that directly calls/imports the changed component | Same-service callers, direct importers |
   | Transitive | Code that depends on a direct consumer | Downstream services, API clients |
   | Data | Systems that read/write the same data store | Analytics pipelines, reporting, caches |

4. **Assess risk level:**

   | Risk | Criteria |
   |------|----------|
   | **Low** | Change is additive, no existing behavior modified, <3 direct consumers |
   | **Medium** | Existing behavior modified, 3–10 consumers, all within same team's ownership |
   | **High** | Breaking change, >10 consumers, crosses team boundaries, touches auth/payments/data pipeline |
   | **Critical** | Schema migration on high-traffic table, public API breaking change, security-sensitive path |

5. **Output format:**
   ```
   Change: [what's changing]
   Risk tier: [Low/Medium/High/Critical]
   Direct consumers: [count] ([list])
   Transitive consumers: [count] ([list])
   Data consumers: [count] ([list])
   Rollback complexity: [trivial/moderate/hard/requires coordination]
   Recommendation: [proceed / proceed with feature flag / requires RFC / requires migration plan]
   ```

6. If risk is High or Critical, recommend which principal skill to use next (`/principal:migration`, `/principal:rfc`, or `/principal:api-design`).

---
