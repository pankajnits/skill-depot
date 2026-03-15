---
---
description: Calculate SLA, SLO, error budget, and composite availability for a system
---

Given the system or availability requirements in $ARGUMENTS:

1. **Single service SLA calculation:**
   ```
   Uptime target: [X]%
   Allowed downtime per year:  (1 - X/100) × 525,960 minutes
   Allowed downtime per month: (1 - X/100) × 43,830 minutes
   Allowed downtime per week:  (1 - X/100) × 10,080 minutes
   ```

   | SLA | Downtime/year | Downtime/month | Downtime/week |
   |-----|-------------|---------------|--------------|
   | 99% | 87.6 hours | 7.3 hours | 1.68 hours |
   | 99.9% | 8.76 hours | 43.8 min | 10.1 min |
   | 99.95% | 4.38 hours | 21.9 min | 5.04 min |
   | 99.99% | 52.6 min | 4.38 min | 1.01 min |
   | 99.999% | 5.26 min | 26.3 sec | 6.05 sec |

2. **Composite availability** (for service chains):
   - Serial (A → B → C): Availability = A × B × C
   - Parallel (redundant): Availability = 1 - (1-A)(1-B)
   - Show the calculation with the user's specific services.

3. **Error budget calculation:**
   ```
   SLO target: [X]%
   Measurement window: [30 days]
   Total requests in window: [N]
   Error budget (requests): N × (1 - X/100)
   Error budget remaining: budget - actual_errors
   Burn rate: actual_errors / budget × 100%
   ```

4. Provide the practical implication: "At current burn rate, your error budget will be exhausted in [Y] days."

5. If the user provides a dependency chain, calculate the composite SLA and note: "To achieve 99.9% end-to-end, each of your [N] dependencies needs [X]% or better."

---
