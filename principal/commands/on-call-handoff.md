---
---
description: Generate an on-call handoff document for the incoming rotation
---

Given the service or context in $ARGUMENTS (or the current repo if none):

1. If in a codebase, gather context:
   ```bash
   # Recent deploys in the last 7 days
   git log --oneline --since="7 days ago" origin/main | head -20

   # Recent changes to critical paths
   git log --oneline --since="7 days ago" -- "**/*migration*" "**/*schema*" "**/config*" | head -10

   # Find open TODO/FIXME/HACK markers (things to watch)
   grep -rn "TODO\|FIXME\|HACK\|XXX\|WORKAROUND" --include="*.ts" --include="*.py" --include="*.go" . | grep -v node_modules | tail -20
   ```

2. **Generate the handoff document:**

   ```markdown
   # On-Call Handoff: [Service/Team Name]

   **Outgoing:** [name] | **Incoming:** [name]
   **Rotation:** [date range]
   **Last updated:** [today's date]

   ## Active Issues
   | Issue | Severity | Status | What to watch |
   |-------|----------|--------|---------------|
   | | | | |

   ## Recent Changes (last 7 days)
   | Date | Change | Risk level | Rollback? |
   |------|--------|-----------|-----------|
   | | | Low/Med/High | Yes/No + how |

   ## Known Risks This Rotation
   - [Upcoming migration, traffic event, dependency maintenance window, etc.]
   - [Feature flags that are partially rolled out]

   ## Things That Might Page You
   | Alert | What it means | First action |
   |-------|-------------|-------------|
   | [alert name] | [plain English] | [specific command or dashboard to check] |

   ## Key Contacts
   | Role | Person | When to escalate |
   |------|--------|-----------------|
   | Backend | | Service-specific issues |
   | Database | | Schema/query issues |
   | Infra/SRE | | Infrastructure issues |
   | Product | | Customer-facing decisions |

   ## Dashboards & Runbooks
   - Primary dashboard: [URL]
   - Service runbooks: [URL or path]
   - Incident channel: [Slack channel]
   ```

3. Ask the user for any active incidents, upcoming events, or known issues to include.

4. If there are feature flags partially rolled out, flag them:
   ```bash
   # Search for feature flag references
   grep -rn "feature.flag\|featureFlag\|feature_flag\|LaunchDarkly\|unleash\|flagsmith" --include="*.ts" --include="*.py" --include="*.go" --include="*.yaml" . | grep -v node_modules | head -15
   ```

---
