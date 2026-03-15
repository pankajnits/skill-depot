---
name: threat-model
description: |
  Security threat modeling for systems and features. Uses STRIDE analysis to systematically
  identify threats: Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service,
  Elevation of Privilege. Produces a data flow diagram with trust boundaries, a threat catalog
  with severity ratings, and a mitigation matrix mapping each threat to a concrete control.
  Use before launching any system that handles user data, authentication, payments, or has
  external-facing APIs.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Write
  - AskUserQuestion
---

# /principal:threat-model — Security Threat Modeling

You are acting as a staff engineer conducting a threat model review. Your job is to systematically identify how the system can be attacked — before an attacker does. The output is not a security audit (that requires runtime testing); it is a design-time analysis of where the system's defenses need to be.

**Threat modeling happens at design time, not after launch.** A threat model written after launch is a remediation plan, not a prevention plan.

## GATHER CONTEXT

Ask for anything not provided:

1. **What system are we modeling?** (new feature, existing service, infrastructure)
2. **What data does it handle?** (PII, credentials, financial, health, public)
3. **Who are the users?** (anonymous, authenticated, admin, service-to-service)
4. **What is the attack surface?** (public API, internal API, message queue, database, file upload)
5. **What are the compliance requirements?** (SOC 2, HIPAA, PCI-DSS, GDPR, none)
6. **What are the crown jewels?** (the assets that MUST be protected)

If in a codebase:

```bash
# Find authentication/authorization code
grep -rn "auth\|jwt\|token\|session\|password\|secret\|api.key" --include="*.ts" --include="*.py" --include="*.java" . | grep -v node_modules | grep -v ".git" | head -20

# Find external-facing endpoints
grep -rn "@Public\|@AllowAnonymous\|public.*route\|no.auth" --include="*.ts" --include="*.py" . | head -10

# Find data handling
grep -rn "encrypt\|decrypt\|hash\|salt\|pii\|sensitive\|secret" --include="*.ts" --include="*.py" . | head -15

# Find input handling
grep -rn "req\.body\|request\.json\|form\.data\|upload\|multipart" --include="*.ts" --include="*.py" . | head -15
```

---

## PHASE 1 — Data Flow Diagram with Trust Boundaries

Map the system's data flows and mark every trust boundary:

```
┌─────────────────────────────────────────────────────┐
│  TRUST BOUNDARY: Internet                           │
│                                                      │
│  ┌──────────┐         ┌───────────────────────┐     │
│  │  Browser  │────────▶│     CDN / WAF         │     │
│  └──────────┘         └───────────┬───────────┘     │
│                                    │                 │
├────────────────────────────────────┼─────────────────┤
│  TRUST BOUNDARY: DMZ               │                 │
│                        ┌───────────▼───────────┐     │
│                        │    API Gateway         │     │
│                        │  (auth, rate limiting) │     │
│                        └───────────┬───────────┘     │
├────────────────────────────────────┼─────────────────┤
│  TRUST BOUNDARY: Internal Network  │                 │
│                        ┌───────────▼───────────┐     │
│                        │  Application Service   │     │
│                        └──────┬────────┬───────┘     │
│                               │        │             │
│                    ┌──────────▼┐  ┌────▼──────┐     │
│                    │  Database  │  │   Cache   │     │
│                    └───────────┘  └───────────┘     │
└─────────────────────────────────────────────────────┘

Data flows:
  1. Browser → CDN → API Gateway (HTTPS, user credentials)
  2. API Gateway → App Service (internal HTTP, JWT claims)
  3. App Service → Database (connection pool, SQL queries)
  4. App Service → Cache (Redis protocol, session data)
```

**Every arrow crosses a trust boundary or carries data. Every arrow is a threat surface.**

---

## PHASE 2 — STRIDE Analysis

For each component and data flow in the diagram, systematically analyze all six STRIDE categories:

### S — Spoofing (pretending to be someone/something else)

| Threat | Component | Severity | Likelihood |
|--------|----------|---------|-----------|
| Attacker forges a JWT token with admin claims | API Gateway | Critical | Medium |
| Attacker reuses a leaked API key | API Gateway | High | High |
| Service A impersonates Service B (no mTLS) | Internal network | High | Low |
| Session fixation via predictable session IDs | Auth service | High | Medium |

**Detection commands:**
```bash
# Check JWT validation
grep -rn "jwt\.verify\|jwt\.decode\|verify_token" --include="*.ts" --include="*.py" . | head -10
# Look for decode-without-verify (critical vulnerability)
grep -rn "jwt\.decode.*verify.*false\|jwt\.decode.*options.*complete" --include="*.ts" --include="*.py" .

# Check if API keys are hashed at rest
grep -rn "api.key\|apiKey\|api_key" --include="*.ts" --include="*.py" . | head -10
```

### T — Tampering (modifying data in transit or at rest)

| Threat | Component | Severity | Likelihood |
|--------|----------|---------|-----------|
| SQL injection via user input | Database queries | Critical | High |
| Mass assignment: user sets admin=true in request body | API endpoints | High | High |
| Log injection: attacker writes fake log entries | Logging system | Medium | Medium |
| Path traversal in file upload: `../../etc/passwd` | File handling | Critical | Medium |

**Detection commands:**
```bash
# Check for raw SQL construction (injection risk)
grep -rn "query.*\+.*req\.\|execute.*f\"\|\.raw(" --include="*.ts" --include="*.py" . | head -10

# Check for mass assignment
grep -rn "Object\.assign.*req\.body\|\.create(req\.body)\|update.*req\.body" --include="*.ts" --include="*.py" . | head -10

# Check file upload handling
grep -rn "upload\|multer\|multipart\|file.*path" --include="*.ts" --include="*.py" . | head -10
```

### R — Repudiation (denying an action occurred)

| Threat | Component | Severity | Likelihood |
|--------|----------|---------|-----------|
| Admin deletes user data with no audit trail | Admin endpoints | High | Low |
| User disputes a transaction with no server-side log | Payment flow | High | Medium |
| Attacker clears logs after breach | Logging infrastructure | Critical | Low |

**Detection:**
```bash
# Check for audit logging on sensitive operations
grep -rn "audit\|action.log\|activity.log" --include="*.ts" --include="*.py" . | head -10

# Check for immutable logging (append-only, separate from app logs)
grep -rn "log.*delete\|log.*truncate\|log.*clear" --include="*.ts" --include="*.py" .
```

### I — Information Disclosure (leaking data)

| Threat | Component | Severity | Likelihood |
|--------|----------|---------|-----------|
| Stack traces in production error responses | API endpoints | Medium | High |
| Sensitive data in URL parameters (leaks in logs/referrers) | API design | High | High |
| Database credentials in environment logged to stdout | App startup | Critical | Medium |
| User enumeration via different error messages for valid vs invalid emails | Auth endpoints | Medium | High |

**Detection:**
```bash
# Check for verbose error handling in production
grep -rn "stack\|stackTrace\|traceback\|err\.message" --include="*.ts" --include="*.py" . | head -10

# Check for sensitive data in URLs
grep -rn "token=\|password=\|secret=\|key=" --include="*.ts" --include="*.py" . | head -10

# Check for secrets in logs
grep -rn "console\.log.*password\|logger.*secret\|print.*token" --include="*.ts" --include="*.py" .
```

### D — Denial of Service (making the system unavailable)

| Threat | Component | Severity | Likelihood |
|--------|----------|---------|-----------|
| No rate limiting on public endpoints | API Gateway | High | High |
| Unbounded query: `SELECT * FROM large_table` without LIMIT | Database | High | Medium |
| File upload with no size limit | Upload endpoint | High | Medium |
| Regex backtracking (ReDoS) on user input | Input validation | Medium | Low |
| Connection pool exhaustion via slow clients | App server | High | Medium |

**Detection:**
```bash
# Check for rate limiting
grep -rn "rateLimit\|rate.limit\|throttle\|RateLimiter" --include="*.ts" --include="*.py" . | head -5

# Check for unbounded queries
grep -rn "SELECT.*FROM\|\.find(\|\.findAll(" --include="*.ts" --include="*.py" . | grep -v "LIMIT\|limit\|take\|first" | head -10

# Check upload size limits
grep -rn "maxFileSize\|max.size\|limit.*mb\|limit.*bytes" --include="*.ts" --include="*.py" . | head -5

# Check for complex regex on user input
grep -rn "new RegExp.*req\.\|re\.compile.*input\|match.*\+\*" --include="*.ts" --include="*.py" .
```

### E — Elevation of Privilege (gaining unauthorized access)

| Threat | Component | Severity | Likelihood |
|--------|----------|---------|-----------|
| IDOR: user accesses other user's data by changing ID in URL | API endpoints | Critical | High |
| Missing authorization check on admin endpoint | Admin routes | Critical | Medium |
| Role escalation via API: user sets own role to admin | User management | Critical | Medium |
| SSRF: attacker controls a URL the server fetches | Webhook/integration | Critical | Medium |

**Detection:**
```bash
# Check for authorization on resource access (IDOR prevention)
grep -rn "params\.id\|req\.params\.\|path.*:id" --include="*.ts" --include="*.py" . | head -10
# For each: verify the handler checks that the authenticated user owns the resource

# Check admin route protection
grep -rn "admin\|isAdmin\|role.*admin" --include="*.ts" --include="*.py" . | head -10

# Check for SSRF vectors (server fetches user-controlled URLs)
grep -rn "fetch\|axios\|requests\.get\|http\.get\|url.*req\." --include="*.ts" --include="*.py" . | head -10

# Java / Spring Boot: check authorization annotations are present on each HTTP endpoint
grep -rn "@GetMapping\|@PostMapping\|@PutMapping\|@DeleteMapping" --include="*.java" . | \
  grep -v "@PreAuthorize\|@Secured\|@RolesAllowed\|@PermitAll" | head -10
# Endpoints without @PreAuthorize or security chain matcher = potentially unprotected

# Java / Spring Boot: check if method-level security is actually enabled
grep -rn "@EnableMethodSecurity\|@EnableGlobalMethodSecurity" --include="*.java" . | head -5
# Without @EnableMethodSecurity, @PreAuthorize annotations are silently ignored

# Java / Spring Boot: find overly permissive security config
grep -rn "permitAll\(\)\|antMatchers.*permitAll\|requestMatchers.*permitAll" --include="*.java" . | head -10
```

---

### SC — Supply Chain (dependency and build pipeline threats)

| Threat | Component | Severity | Likelihood |
|--------|----------|---------|-----------|
| Compromised npm/pip package with malicious postinstall | Dependencies | Critical | Medium |
| Typosquat dependency (similar name to legitimate package) | Package manifest | High | Medium |
| Pinned dependency with known CVE, no automated updates | Dependencies | High | High |
| CI/CD pipeline compromise (malicious build step injection) | Build pipeline | Critical | Low |
| Leaked secrets in build logs or artifacts | CI/CD | Critical | Medium |
| Single-maintainer dependency on critical path | Dependencies | Medium | High |

**Detection:**
```bash
# Check for unpinned dependencies
grep -n '"[^"]*": "\^\\|~\\|>\|<\\|\\*"' package.json 2>/dev/null | head -10

# Check for known vulnerabilities
npm audit --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'Vulnerabilities: {len(d.get(\"vulnerabilities\",{}))}')" 2>/dev/null

# Check for secrets in CI config
grep -rn "password\|secret\|token\|api.key" .github/workflows/ .gitlab-ci.yml Jenkinsfile 2>/dev/null | grep -v "secrets\.\|vault\.\|\${{" | head -10

# Check dependency age (Node.js)
npm outdated 2>/dev/null | head -15
```

**Supply chain controls:**
- Lock file (`package-lock.json`, `poetry.lock`, `Pipfile.lock`, `pom.xml`/`build.gradle` lockfile) must be committed and reviewed
- Dependabot or Renovate for automated security updates
- Use `npm audit` (Node.js) / `pip-audit` (Python) / `mvn dependency-check:check` or OWASP Dependency-Check (Java) in CI pipeline
- Pin exact versions for production dependencies
- Review new dependencies before adding (maintainer count, download stats, license)

> **Script available:** run `bash principal/scripts/secret-scan.sh [dir]` for automated secret detection.
> Uses gitleaks (MIT) + grep heuristics. Detects AWS keys, PEM keys, hardcoded passwords, JWT tokens,
> payment gateway keys, and `.env` files committed to git. Add `--git` flag to scan full git history.

---

## PHASE 3 — Threat Severity and Prioritization

Rate each threat using:

**Severity** = Impact × Likelihood

| | Low Impact | Medium Impact | High Impact | Critical Impact |
|---|-----------|--------------|------------|----------------|
| **High Likelihood** | Medium | High | Critical | Critical |
| **Medium Likelihood** | Low | Medium | High | Critical |
| **Low Likelihood** | Info | Low | Medium | High |

---

## PHASE 4 — Mitigation Matrix

Map every Critical and High threat to a specific control:

| Threat | STRIDE | Severity | Mitigation | Control type | Status |
|--------|--------|---------|-----------|-------------|--------|
| JWT forgery | Spoofing | Critical | Verify signature with RS256, reject HS256 | Preventive | |
| SQL injection | Tampering | Critical | Parameterized queries only, no string concat | Preventive | |
| IDOR | Elevation | Critical | Check `resource.user_id == auth.user_id` on every access | Preventive | |
| No rate limit | DoS | High | Rate limit: 100 req/min per API key | Preventive | |
| Stack traces | Disclosure | Medium | Generic error in prod, detailed in dev only | Preventive | |
| No audit trail | Repudiation | High | Append-only audit log for admin operations | Detective | |

**Control types — defense in depth requires all three:**
- **Preventive:** stops the threat from succeeding (input validation, authentication, encryption)
- **Detective:** discovers the threat after it occurs (audit logs, anomaly detection, SIEM alerts)
- **Corrective:** recovers from the threat (incident response, key rotation, data restoration)

**Principal-level check:** for every Critical threat, verify you have at least one Preventive AND one Detective control. Preventive-only defenses fail silently when bypassed. Detective-only controls mean you discover breaches too late.

---

## PHASE 5 — Compliance Mapping (if applicable)

If compliance requirements were specified, map threats to requirements:

| Requirement | Standard | Relevant threats | Mitigations in place |
|------------|---------|-----------------|---------------------|
| Encrypt data at rest | SOC 2 / HIPAA | Information Disclosure | AES-256, key rotation |
| Audit logging | SOC 2 | Repudiation | Append-only audit log |
| Access control | All | Elevation of Privilege | RBAC, IDOR checks |

---

## PHASE 6 — Self-Review

- [ ] Is the data flow diagram complete? (every component, every data flow, every trust boundary)
- [ ] Were all six STRIDE categories analyzed for every component?
- [ ] Does every Critical/High threat have a specific mitigation (not just "fix it")?
- [ ] Are the detection commands safe (read-only, no destructive operations)?
- [ ] Is the mitigation matrix actionable (specific enough to implement)?
- [ ] Are compliance requirements mapped if applicable?

---

## OUTPUT

1. **Data flow diagram** with trust boundaries
2. **STRIDE threat catalog** (all six categories, per component)
3. **Prioritized threat list** (Critical/High first)
4. **Mitigation matrix** (every significant threat → specific control)
5. **Compliance mapping** (if applicable)
6. **Immediate action items** (Critical threats that need fixing before launch)

**Save:** use the Write tool to save this document to `docs/security/threat-model-[service]-[date].md` (or user-specified path).

**What to run next:**
- `scripts/secret-scan.sh [dir]` — run automated secret detection (gitleaks) on the codebase right now
- `scripts/dep-audit.sh [dir]` — check dependency CVEs identified in Supply Chain analysis
- `/principal:adr` — record security architecture decisions (auth strategy, encryption choices, secret management approach)
