---
---
description: Generate a structured operational runbook for a service and failure mode
---

Given the service and failure mode described in $ARGUMENTS:

1. If in a codebase, read relevant files to understand the service:
   ```bash
   # Find service configuration
   find . -name "docker-compose*" -o -name "Dockerfile" -o -name "*.yaml" -path "*/k8s/*" -o -name "*.yaml" -path "*/deploy/*" | head -10

   # Find health check endpoints
   grep -rn "health\|readiness\|liveness" --include="*.ts" --include="*.py" --include="*.go" --include="*.yaml" . | grep -v node_modules | head -10
   ```

2. **Generate the runbook** with this structure:

   ## Runbook: [Service Name] — [Failure Mode]

   **Last updated:** [today's date]
   **Owner:** [team name]
   **Severity:** [SEV1/SEV2/SEV3/SEV4]

   ### 1. Detection
   - What alerts fire for this failure mode?
   - What dashboard to check first?
   - What does the user experience look like?

   ### 2. Quick Assessment (first 2 minutes)
   ```bash
   # Check service health
   curl -s http://SERVICE_HOST:PORT/health | jq .

   # Check recent logs for errors
   journalctl -u SERVICE_NAME --since "10 min ago" --no-pager | grep -i "error\|fatal\|panic" | tail -20

   # Check pod/container status (if k8s)
   kubectl get pods -n NAMESPACE -l app=SERVICE_NAME
   kubectl logs -n NAMESPACE -l app=SERVICE_NAME --tail=50 --since=5m | grep -i error

   # Check resource usage
   kubectl top pods -n NAMESPACE -l app=SERVICE_NAME
   ```

   ### 3. Common Causes & Fixes
   For each likely cause, provide:
   - **Symptom**: What you'll see in logs/metrics
   - **Diagnosis**: Specific command to confirm
   - **Fix**: Step-by-step remediation
   - **Rollback**: How to undo the fix if it makes things worse

   ### 4. Escalation
   | Condition | Action |
   |-----------|--------|
   | Not resolved in 15 min | Page secondary on-call |
   | Customer-facing impact | Notify incident commander |
   | Data loss suspected | Page database team + engineering lead |

   ### 5. Post-Resolution
   - [ ] Verify service health restored
   - [ ] Check dependent services recovered
   - [ ] Update incident timeline
   - [ ] Schedule postmortem if SEV1/SEV2

3. All diagnostic commands must be **read-only**. Any remediation commands that modify state must be prefixed with:
   ```
   # ⚠️ DESTRUCTIVE — confirm with user before running
   ```

4. Include rollback steps for every remediation action.

---
