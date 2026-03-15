---
---
description: Back-of-envelope estimation for system capacity, storage, traffic, or cost
---

Given the estimation question in $ARGUMENTS:

1. Identify the key variables: users, requests per user, data per record, retention period, replication factor, peak multiplier.
2. State every assumption explicitly with a reasonable default (e.g., "assuming 1KB per record," "assuming 3x peak factor").
3. Perform the calculation step by step, showing all arithmetic.
4. Use these reference numbers:
   - 1 day = 86,400 seconds
   - 1 year ≈ 31.5 million seconds
   - 1 million requests/day ≈ 12 RPS average
   - SSD read: ~100μs, HDD: ~10ms, network round-trip same region: ~1ms, cross-region: ~50-150ms
   - In-memory lookup: ~100ns, cache (Redis): ~1ms, database query (indexed): ~5ms
   - Hot storage: ~$0.02-0.05/GB/month, cold storage: ~$0.004/GB/month
   - Typical app server: ~5,000 simple requests/second
5. Apply a 2x safety factor on the final number.
6. Present the result as: "Order of magnitude: [X]. With 2x safety: [Y]."
7. Note the single assumption most likely to invalidate the estimate.

---
