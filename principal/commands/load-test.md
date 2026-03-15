---
---
description: Generate a production-grade load test script (k6 or vegeta) for an endpoint
---

Given the endpoint and requirements described in $ARGUMENTS:

1. **Gather test parameters** (ask if not provided):
   - Target URL and method (GET/POST/PUT)
   - Request body (for POST/PUT)
   - Authentication (Bearer token, API key, or none)
   - Virtual users (VUs) or target RPS
   - Duration
   - Success criteria (P99 latency, error rate threshold)

2. **Generate a k6 script** (preferred for scripted scenarios):

   ```javascript
   import http from 'k6/http';
   import { check, sleep } from 'k6';
   import { Rate, Trend } from 'k6/metrics';

   const errorRate = new Rate('errors');
   const latency = new Trend('request_duration', true);

   export const options = {
     stages: [
       { duration: '30s', target: 10 },   // ramp up
       { duration: '2m',  target: TARGET_VUS },  // sustained load
       { duration: '30s', target: 0 },    // ramp down
     ],
     thresholds: {
       http_req_duration: ['p(99)<TARGET_P99_MS'],
       errors: ['rate<0.01'],  // <1% error rate
     },
   };

   const headers = {
     'Content-Type': 'application/json',
     // 'Authorization': 'Bearer TOKEN',
   };

   export default function () {
     const res = http.get('TARGET_URL', { headers });
     // For POST: const res = http.post('TARGET_URL', JSON.stringify(BODY), { headers });

     check(res, {
       'status is 200': (r) => r.status === 200,
       'latency < TARGET_P99_MS': (r) => r.timings.duration < TARGET_P99_MS,
     });

     errorRate.add(res.status >= 400);
     latency.add(res.timings.duration);
     sleep(1);
   }
   ```

   **Run with:** `k6 run loadtest.js` (install: `brew install k6`)

3. **Generate a vegeta command** (preferred for constant-rate testing):

   ```bash
   # Constant-rate load test — avoids coordinated omission bias
   echo "METHOD TARGET_URL" | vegeta attack \
     -rate=TARGET_RPS/s \
     -duration=120s \
     -header="Content-Type: application/json" \
     -header="Authorization: Bearer TOKEN" | \
   vegeta report

   # With histogram:
   echo "METHOD TARGET_URL" | vegeta attack -rate=TARGET_RPS/s -duration=120s | \
   vegeta report -type=hist[0,5ms,10ms,25ms,50ms,100ms,250ms,500ms,1s]

   # Save for later comparison:
   echo "METHOD TARGET_URL" | vegeta attack -rate=TARGET_RPS/s -duration=120s > results.bin
   vegeta report < results.bin
   vegeta plot < results.bin > latency.html
   ```

   **Install:** `brew install vegeta` or `go install github.com/tsenart/vegeta@latest`

4. **Include pre-test checklist:**
   - [ ] Running against staging/test environment (NOT production unless explicitly approved)
   - [ ] Monitoring dashboards open for the target service
   - [ ] Team notified of load test window
   - [ ] Abort plan: Ctrl+C stops both k6 and vegeta immediately

5. **Include post-test analysis template:**
   ```
   Results:
     P50: [X]ms  P95: [Y]ms  P99: [Z]ms  Max: [W]ms
     Success rate: [X]%
     Throughput: [X] RPS achieved

   Verdict: [PASS/FAIL]
     P99 < TARGET_P99_MS: [✅/❌]
     Error rate < 1%:     [✅/❌]
     No timeout errors:   [✅/❌]
   ```

---
