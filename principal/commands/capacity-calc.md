---
---
description: Calculate system capacity requirements — RPS, servers, bandwidth, storage, and cost
---

Given the capacity requirements described in $ARGUMENTS:

1. **Gather inputs** (ask user if not provided):
   - Daily Active Users (DAU)
   - Average requests per user per day
   - Average request size (KB)
   - Average response size (KB)
   - Peak-to-average ratio (typical: 2x–5x, flash sales: 10x+)
   - Data retention period
   - Target latency (p99)

2. **Calculate traffic:**
   ```
   Daily requests    = DAU × requests_per_user
   Average RPS       = daily_requests / 86,400
   Peak RPS          = average_RPS × peak_ratio
   ```

3. **Calculate bandwidth:**
   ```
   Ingress (avg)     = average_RPS × request_size_KB / 1024  (MB/s)
   Egress (avg)      = average_RPS × response_size_KB / 1024  (MB/s)
   Peak ingress      = ingress × peak_ratio
   Peak egress       = egress × peak_ratio
   ```

4. **Calculate storage:**
   ```
   Daily storage     = daily_requests × (request_size + metadata_overhead)
   Monthly storage   = daily_storage × 30
   Total storage     = monthly_storage × retention_months
   ```
   Add 30% overhead for indexes, replicas, and operational headroom.

5. **Calculate server count:**
   ```
   RPS per server    = 1000 / p99_latency_ms  (simplified)
   Servers needed    = peak_RPS / RPS_per_server
   With redundancy   = servers × 1.5  (N+1 or 50% headroom)
   ```

6. **Cost estimate** (approximate cloud pricing):
   | Resource | Unit cost | Monthly cost |
   |----------|----------|-------------|
   | Compute (servers × hours) | ~$0.05/hr per vCPU | |
   | Storage (GB/month) | ~$0.023/GB (S3-class) | |
   | Bandwidth egress | ~$0.09/GB | |
   | Database (managed) | ~$0.10/hr per instance | |

7. **Present results:**
   ```
   Traffic:   [X] avg RPS → [Y] peak RPS
   Bandwidth: [A] MB/s in, [B] MB/s out (peak)
   Storage:   [C] TB over [N] months
   Servers:   [D] instances (with redundancy)
   Est. cost: $[E]/month
   ```

8. State the **single assumption most likely to invalidate this estimate** and what it would change.

---
