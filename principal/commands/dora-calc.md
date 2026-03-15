---
---
description: Classify team performance against DORA benchmarks and recommend which metric to improve first
---

Given the team metrics described in $ARGUMENTS:

1. **Gather the four DORA metrics** (ask user if not provided):
   - **Deployment Frequency** — How often does the team deploy to production?
   - **Lead Time for Changes** — Time from code commit to running in production?
   - **Change Failure Rate** — What percentage of deployments cause a failure requiring remediation?
   - **Mean Time to Restore (MTTR)** — How long to recover from a production failure?

2. **Classify against DORA benchmarks:**

   | Metric | Elite | High | Medium | Low |
   |--------|-------|------|--------|-----|
   | Deploy frequency | On demand (multiple/day) | Weekly to monthly | Monthly to 6-monthly | >6 months |
   | Lead time | < 1 hour | 1 day – 1 week | 1 week – 1 month | > 1 month |
   | Change failure rate | < 5% | 5% – 10% | 10% – 15% | > 15% |
   | MTTR | < 1 hour | < 1 day | 1 day – 1 week | > 1 week |

3. **Score each metric** and classify overall team performance:
   - **Elite**: All four metrics at Elite level
   - **High**: Majority at High or above
   - **Medium**: Mix of Medium and High
   - **Low**: Any metric at Low

4. **Identify the bottleneck metric** — the single metric furthest from Elite — and recommend improvement:

   | Bottleneck | Common root cause | Recommended action |
   |-----------|-------------------|-------------------|
   | Deploy frequency | Manual release process, large batch sizes | Automate CI/CD, reduce batch size, feature flags |
   | Lead time | Long review cycles, manual testing, environment bottlenecks | Parallelize reviews, automated testing, self-service environments |
   | Change failure rate | Insufficient testing, no canary deploys, tight coupling | Expand test coverage, implement canary/progressive rollout |
   | MTTR | Poor observability, no runbooks, complex rollback | Improve alerting, write runbooks (`/principal:runbook-gen`), automate rollback |

5. **Output format:**
   ```
   Team classification: [Elite/High/Medium/Low]

   Metric breakdown:
     Deploy frequency:    [value] → [Elite/High/Medium/Low]
     Lead time:           [value] → [Elite/High/Medium/Low]
     Change failure rate: [value] → [Elite/High/Medium/Low]
     MTTR:                [value] → [Elite/High/Medium/Low]

   Bottleneck: [metric name]
   Recommended action: [specific recommendation]
   Expected impact: Moving [metric] from [current tier] to [next tier] typically correlates with [X]% improvement in overall delivery performance.
   ```

6. Note: DORA metrics are **correlated** — improving one often improves others. Teams that deploy more frequently tend to have lower change failure rates (smaller batches = less risk).

---
