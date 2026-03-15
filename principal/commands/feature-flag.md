---
---
description: Design a feature flag specification for a rollout, migration, or experiment
---

Given the feature or rollout described in $ARGUMENTS:

1. **Determine the flag type:**

   | Type | Use case | Lifecycle |
   |------|---------|-----------|
   | Release flag | Progressive rollout of new feature | Short (remove after 100% and stable) |
   | Experiment flag | A/B test between variants | Short (remove after experiment concludes) |
   | Ops flag | Kill switch for a feature under load | Permanent (stays in codebase) |
   | Permission flag | Enable feature for specific users/tenants | Long (tied to entitlements) |

2. **Generate the flag specification:**

   ```yaml
   flags:
     - name: [snake_case_descriptive_name]
       type: [boolean | percentage | variant]
       description: "[what this flag controls in one sentence]"
       owner: "[team or person responsible]"
       created: "[today's date]"
       expected_removal: "[date or 'permanent']"

       # Rollout plan
       rollout:
         - stage: "internal"
           value: true   # or 1% for percentage
           duration: "2 days"
           success_criteria: "No errors in internal dogfooding"
         - stage: "canary"
           value: 5%
           duration: "3 days"
           success_criteria: "Error rate < 0.1%, P99 < 200ms"
         - stage: "partial"
           value: 25%
           duration: "5 days"
           success_criteria: "No regressions in core metrics"
         - stage: "full"
           value: 100%
           duration: "7 days soak"
           success_criteria: "All metrics stable for 7 days"

       # Rollback
       rollback:
         trigger: "[error rate > X% OR P99 > Yms OR manual]"
         action: "Set to false/0% immediately"
         notification: "[Slack channel or PagerDuty]"

       # Cleanup
       cleanup:
         - "Remove flag checks from code"
         - "Remove flag from configuration"
         - "Delete dead code path (old behavior)"
         - "Update tests to remove flag-dependent branches"
   ```

3. **Implementation checklist:**
   - [ ] Flag has a descriptive name (not `flag1` or `new_feature`)
   - [ ] Default value is the SAFE value (existing behavior, not new behavior)
   - [ ] Flag is evaluated at the right granularity (per-user, per-tenant, global)
   - [ ] Flag is logged with every request that evaluates it (for debugging)
   - [ ] Rollback can be done in <1 minute (config change, not deploy)
   - [ ] Monitoring includes flag-specific dashboards (metrics split by flag state)
   - [ ] Expected removal date is set (tech debt: stale flags accumulate)

4. **Stale flag audit** (if in a codebase):
   ```bash
   # Find existing feature flag references
   grep -rn "feature.flag\|featureFlag\|feature_flag\|isEnabled\|is_enabled" --include="*.ts" --include="*.py" --include="*.go" . | grep -v node_modules | grep -v test | head -20

   # Count total flags (estimate)
   grep -rn "feature.flag\|featureFlag" --include="*.ts" --include="*.py" . | grep -v node_modules | sort -t: -k1,1 -u | wc -l
   ```
   Flag any feature flags older than 90 days that are still at 100% — these should be cleaned up.

---
