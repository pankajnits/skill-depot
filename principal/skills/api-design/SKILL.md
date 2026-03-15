---
name: api-design
description: |
  Design or review an API with staff-engineer rigor. Covers REST, gRPC, and GraphQL conventions,
  backward compatibility analysis, versioning strategy, rate limiting design, pagination patterns,
  error taxonomy, idempotency, and contract testing requirements. Two modes: DESIGN (create an
  API from requirements) and REVIEW (audit an existing API for breaking changes, consistency,
  and scalability issues). Produces an API specification with concrete examples, error catalog,
  and consumer migration guide.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Write
  - AskUserQuestion
---

# /principal:api-design — API Design & Review

You are acting as a staff engineer designing or reviewing an API. APIs are contracts — once published, they're hard to change. Your job is to get the contract right before consumers depend on it, and to protect backward compatibility after they do.

**Critical rule:** with a sufficient number of consumers, every observable behavior of your API becomes a de facto contract — not just the documented fields. Side effects, error message text, response timing, undocumented fields — someone depends on all of it.

## MODE SELECTION

- **DESIGN** — create a new API from requirements
- **REVIEW** — audit an existing API for issues

---

## MODE: DESIGN

### GATHER CONTEXT

1. **What does this API do?** (domain, resources, operations)
2. **Who consumes it?** (internal services, mobile apps, third-party developers, public)
3. **Protocol:** REST / gRPC / GraphQL?
4. **Scale:** expected RPS, number of consumers
5. **Auth model:** API key, OAuth 2.0, mTLS, JWT?
6. **Existing patterns:** are there existing API conventions in this codebase to follow?

```bash
# Find existing API definitions
find . -name "*.yaml" -o -name "*.json" | xargs grep -l "openapi\|swagger\|paths:" 2>/dev/null
find . -name "*.proto" | head -5
find . -name "*.graphql" -o -name "*.gql" | head -5

# Find existing route definitions
grep -rn "router\.\|app\.\(get\|post\|put\|delete\|patch\)\|@GetMapping\|@PostMapping\|@RequestMapping" --include="*.ts" --include="*.py" --include="*.java" . | head -20
```

### API DESIGN PRINCIPLES

Apply these in order of priority:

**1. Consistency over cleverness**
- Follow existing conventions in the codebase
- If no conventions exist, establish them now and document
- Every endpoint should feel like it was designed by the same person

**2. Additive-only evolution**
- New fields: always optional with defaults
- Removed fields: deprecate with sunset date, never delete without a major version
- Changed semantics: new endpoint, not changed behavior on existing endpoint

**3. Explicit over implicit**
- Every field has a documented type, whether it's required/optional, and what values are valid
- Error responses name the specific field and reason, not "Bad Request"
- Pagination has explicit cursors/offsets, not hidden defaults

### REST API TEMPLATE

For each resource, specify:

```markdown
## Resource: [name]

### POST /v1/[resources]

**Purpose:** Create a new [resource]
**Auth:** Bearer token (scope: [resource]:write)
**Idempotency:** Required — `Idempotency-Key` header (UUID, TTL: 24h)
**Rate limit:** 100 req/min per API key

**Request:**
```json
{
  "name": "string",              // required, 1-255 chars, UTF-8
  "type": "enum",                // required, one of: ["standard", "premium"]
  "metadata": {                  // optional, max 50 keys
    "key": "value"               // key: 1-40 chars, value: 1-500 chars
  }
}
```

**Response 201 Created:**
```json
{
  "id": "res_01H2X3Y4Z5",       // prefixed ID for debuggability
  "name": "string",
  "type": "standard",
  "metadata": {},
  "created_at": "2026-03-15T10:30:00Z",   // ISO 8601, always UTC
  "updated_at": "2026-03-15T10:30:00Z"
}
```

**Headers:**
```
Location: /v1/resources/res_01H2X3Y4Z5
X-Request-Id: req_abc123
X-RateLimit-Remaining: 99
X-RateLimit-Reset: 1710500400
```

**Errors:**
| Status | Error code | When |
|--------|-----------|------|
| 400 | `invalid_field` | Validation failure: `{"error": "invalid_field", "field": "name", "message": "must be 1-255 characters"}` |
| 401 | `unauthorized` | Missing or invalid auth token |
| 409 | `duplicate` | Idempotency key already used with different request body |
| 422 | `business_rule` | Domain validation: `{"error": "quota_exceeded", "message": "..."}` |
| 429 | `rate_limited` | `{"error": "rate_limited", "retry_after_seconds": 30}` |
| 503 | `service_unavailable` | Transient — safe to retry with backoff |
```

### PAGINATION DESIGN

Choose one pattern and apply consistently:

**Cursor-based (recommended for large/dynamic datasets):**
```json
// Request
GET /v1/resources?limit=25&cursor=eyJpZCI6MTIzfQ==

// Response
{
  "data": [...],
  "pagination": {
    "next_cursor": "eyJpZCI6MTQ4fQ==",  // opaque, base64-encoded
    "has_more": true
  }
}
```

**Offset-based (acceptable for small, static datasets):**
```json
// Request
GET /v1/resources?limit=25&offset=50

// Response
{
  "data": [...],
  "pagination": {
    "total": 342,
    "limit": 25,
    "offset": 50
  }
}
```

**Avoid:** page-number pagination (`?page=3`) — it's ambiguous when data changes between pages.

### ID FORMAT

Use prefixed IDs for debuggability:
```
User:    usr_01H2X3Y4Z5
Order:   ord_01H2X3Y4Z5
Invoice: inv_01H2X3Y4Z5
```

Benefits:
- Log search: `grep ord_01H2X3` immediately tells you it's an order
- Prevents cross-resource ID confusion (passing a user ID where an order ID is expected)
- Implementation: ULID or UUID v7 with a prefix

### ERROR TAXONOMY

Define a system-wide error contract. Every API uses the same error shape:

```json
{
  "error": {
    "code": "invalid_field",
    "message": "Human-readable description",
    "field": "email",                    // optional: which field
    "details": [                         // optional: for multi-error validation
      {"field": "name", "message": "required"},
      {"field": "email", "message": "invalid format"}
    ],
    "request_id": "req_abc123",          // always present for debugging
    "doc_url": "https://docs.api.com/errors/invalid_field"  // optional
  }
}
```

Error categories:
| HTTP Status | Category | Retryable? | Client action |
|------------|---------|-----------|---------------|
| 400 | Client error — fix request | No | Fix input and retry |
| 401 | Auth — refresh token | No | Refresh token, retry once |
| 403 | Forbidden — no access | No | Request access |
| 404 | Not found | No | Check ID |
| 409 | Conflict — state conflict | No | Read current state, resolve |
| 422 | Business rule | No | Read error details |
| 429 | Rate limited | Yes | Wait `retry_after_seconds`, then retry |
| 500 | Server error | Yes | Retry with backoff |
| 503 | Unavailable | Yes | Retry with backoff |

### RATE LIMITING DESIGN

```yaml
rate_limits:
  default:
    requests_per_minute: 60
    burst: 10   # allow 10 requests above limit before throttling

  per_endpoint:
    POST /v1/resources:
      requests_per_minute: 30   # writes are more expensive
    GET /v1/resources:
      requests_per_minute: 120  # reads can be more generous

  response_headers:
    X-RateLimit-Limit: 60
    X-RateLimit-Remaining: 45
    X-RateLimit-Reset: 1710500400   # Unix epoch when limit resets

  # When rate limit exceeded:
  # Return 429 with Retry-After header
  # Body: {"error": "rate_limited", "retry_after_seconds": 15}
```

### VERSIONING STRATEGY

**Recommended:** URL path versioning with additive-only within a version.

```
/v1/resources  — current
/v2/resources  — breaking changes only
```

**Version lifecycle:**
```
v1 Active     → v2 introduced → v1 Deprecated → v1 Sunset
                                 (6-month warning)  (removed)
```

**What constitutes a breaking change (requires new version):**
- Removing a field from a response
- Changing a field's type
- Making an optional field required
- Changing error codes or HTTP status codes for existing scenarios
- Changing the semantic meaning of a field

**What is NOT a breaking change (safe within existing version):**
- Adding new optional fields to requests
- Adding new fields to responses
- Adding new endpoints
- Adding new enum values (IF consumers use tolerant readers)
- Adding new optional query parameters

### IDEMPOTENCY DESIGN

Idempotency is non-negotiable for any write operation that involves money, side effects, or network retries. Without it, network failures cause duplicate charges, duplicate orders, and duplicate notifications.

**The core pattern:**
```
Client generates UUID → sends request with Idempotency-Key header →
Server checks if key exists in store →
  If YES (same body): return cached response (do NOT re-execute)
  If YES (different body): return 422 (key reuse with different params)
  If NO: execute, store (key → response), return response
```

**Implementation — what to store and for how long:**
```typescript
// Idempotency record schema
interface IdempotencyRecord {
  key: string;                    // UUID from client
  request_hash: string;           // SHA256 of normalized request body
  response_status: number;        // HTTP status code stored
  response_body: string;          // serialized response (JSON)
  created_at: Date;
  expires_at: Date;               // key TTL: 24h is industry standard for idempotency keys
}

// Database: Redis is the right store for idempotency keys
// - Set with NX (only if not exists) + TTL atomically
// - Atomic check-and-set prevents race conditions on concurrent retries
SETNX idempotency:{api_key}:{idempotency_key} LOCK_VALUE EX 30  // phase 1: acquire
SET   idempotency:{api_key}:{idempotency_key} {response_json} EX 86400  // phase 2: store result

// Redis: atomic pattern for idempotency (Lua script for atomicity)
const script = `
  local existing = redis.call('GET', KEYS[1])
  if existing then return existing end
  redis.call('SET', KEYS[1], ARGV[1], 'EX', ARGV[2])
  return nil
`;
```

**API contract for idempotency:**
```
Request header:
  Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000   (UUID, client-generated)

Responses:
  First call:    201 Created — executes and caches
  Retry (same):  201 Created — returns cached response (no re-execution)
  Retry (diff body): 422 Unprocessable — {"error": "idempotency_key_reused", "message": "Key already used with different request body"}
  Expired key:   Treated as new request — fresh execution

Required:
  Response header: Idempotency-Replayed: true  (on cache hits — lets clients know it was replayed)
```

**What operations MUST be idempotent:**
| Operation | Why | Key scope |
|-----------|-----|-----------|
| Payment charge | Duplicate charges destroy trust | `api_key + idempotency_key` |
| Order placement | Duplicate orders lose money | `api_key + idempotency_key` |
| Wallet debit | Same as payment | `api_key + idempotency_key` |
| Email/SMS send | Duplicate notifications annoy users | `api_key + idempotency_key` |
| Refund | Duplicate refunds lose money | `api_key + idempotency_key` |
| Inventory reservation | Overselling prevention | `api_key + idempotency_key` |

**What operations need NOT be idempotent:**
- GET, HEAD — already idempotent by HTTP semantics
- Search queries — no side effects
- Analytics events — duplicates acceptable, aggregate anyway

**The race condition problem (concurrent retries):**
```
Two identical requests arrive simultaneously (mobile client with poor connectivity):
  Request 1: GET → not found, begin execution
  Request 2: GET → not found, begin execution ← DUPLICATE!

Fix: Use distributed lock (Redis SETNX) BEFORE executing.
  Request 1: SETNX → success → execute → store result
  Request 2: SETNX → fails → wait → poll for result → return stored result
```

**Idempotency and at-least-once delivery (Kafka/queues):**
- Message queue delivers at-least-once — consumers MUST be idempotent
- Use business ID as idempotency key (order_id, payment_id, event_id)
- Store processed event IDs in Redis or DB with TTL matching queue retention period
- Pattern: `if already_processed(event_id): return; process(event); mark_processed(event_id)`

---

## MODE: REVIEW

### STEP 1 — Read the API

```bash
# Find API spec files
find . -name "openapi*" -o -name "swagger*" -o -name "*.proto" | head -5

# Read route handlers
grep -rn "router\.\|@app\.\|@Get\|@Post\|@Put\|@Delete" --include="*.ts" --include="*.py" . | head -30

# Find request/response types
grep -rn "interface.*Request\|interface.*Response\|class.*DTO" --include="*.ts" . | head -20
```

### STEP 2 — Consistency Audit

| Check | Pass? | Issue |
|-------|-------|-------|
| All endpoints follow same naming convention (plural nouns, kebab-case) | | |
| All responses use same envelope format | | |
| All errors use same error shape | | |
| All dates are ISO 8601 UTC | | |
| All IDs use same format | | |
| All list endpoints use same pagination pattern | | |
| All write endpoints require Idempotency-Key | | |
| All responses include request_id for tracing | | |
| All rate limit headers present on every response | | |

### STEP 3 — Backward Compatibility Check

```bash
# Compare current API spec with previous version
# Look for removed fields, changed types, new required fields

# If using OpenAPI:
diff <(yq eval '.paths' old-openapi.yaml) <(yq eval '.paths' new-openapi.yaml)

# If using TypeScript interfaces:
grep -rn "interface.*Response" --include="*.ts" . | sort
```

Flag any change that:
- Removes a field consumers may depend on
- Changes a field's type
- Adds a required field to a request
- Changes error semantics

### STEP 4 — Security Review

- [ ] Auth is required on every non-public endpoint
- [ ] Auth tokens are validated server-side, not just checked for presence
- [ ] Rate limiting prevents abuse
- [ ] Input validation prevents injection (SQL, XSS, command injection)
- [ ] Sensitive fields are never in URL parameters (they leak in logs and referrer headers)
- [ ] CORS is configured explicitly (not `*` in production)
- [ ] Response doesn't leak internal implementation details (stack traces, internal IDs)

### STEP 5 — Produce Review

```markdown
## API Review: [Title]

### Breaking Changes Detected
[List any changes that will break existing consumers]

### Consistency Issues
[Deviations from established patterns]

### Security Concerns
[Any security issues found]

### Missing Contract Elements
[Missing pagination, missing error details, missing idempotency, etc.]

### Recommendations
[Prioritized list of suggested improvements]
```

---

## OUTPUT

**DESIGN:** Complete API specification with resource endpoints, error taxonomy, pagination, rate limiting, versioning strategy, and concrete request/response examples.

**REVIEW:** Structured review with consistency audit, backward compatibility analysis, security check, and prioritized recommendations.

**Save:** use the Write tool to save this document to `docs/api/[service-name]-api-spec.md` (or user-specified path).

**What to run next:**
- `/principal:threat-model` — security review of the API surface (auth flows, input validation, rate limiting gaps)
- `/principal:lld` — if DESIGN mode, produce the full implementation blueprint
- `scripts/api-diff.sh` — detect breaking changes after future API revisions
