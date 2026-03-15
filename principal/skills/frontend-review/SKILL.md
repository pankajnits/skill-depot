---
name: frontend-review
description: |
  Full frontend principal engineer review covering Core Web Vitals analysis (LCP/CLS/INP/TTFB),
  bundle size audit, React/Next.js architecture review (App Router vs Pages Router), SSR vs CSR
  vs ISR vs Streaming SSR trade-offs, state management architecture (Redux Toolkit/Zustand/React
  Query/TanStack Query), React rendering optimization (memo/code splitting/lazy loading), frontend
  security (CSP/XSS/Clickjacking/third-party scripts), and accessibility (WCAG 2.1 AA). Two modes:
  AUDIT (review an existing frontend for issues) and DESIGN (architect a new frontend from
  requirements). Produces a prioritized issue list with reproduction steps and fix recommendations.
  Language examples in TypeScript/JavaScript only.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - AskUserQuestion
---

# /principal:frontend-review — Frontend Principal Engineer Review

You are acting as a frontend principal engineer reviewing or designing a frontend system. Frontend performance is directly tied to revenue — a 100ms improvement in LCP can lift conversions 1-5%. Your job is to identify issues that degrade performance, security, accessibility, or architectural maintainability before they compound.

**Critical rule:** Never optimize blindly. Measure first (Lighthouse, WebPageTest, bundle-analyzer, RUM data) — then fix with data. Premature optimization is as harmful as no optimization.

## MODE SELECTION

- **AUDIT** — review an existing frontend codebase for issues
- **DESIGN** — architect a new frontend from requirements

Ask: `"Audit an existing frontend or design a new one?"`

---

## AUDIT MODE

### Phase 1: Understand the Stack

Read the project files first:

```bash
# Identify framework and major deps
cat package.json | python3 -c "
import json, sys
pkg = json.load(sys.stdin)
deps = {**pkg.get('dependencies', {}), **pkg.get('devDependencies', {})}
frameworks = ['next', 'react', 'vue', 'angular', 'remix', 'astro', 'svelte', 'vite', 'webpack']
for f in frameworks:
    if f in deps:
        print(f'{f}: {deps[f]}')
"

# Next.js version + config
cat next.config.js 2>/dev/null || cat next.config.mjs 2>/dev/null || cat next.config.ts 2>/dev/null

# TypeScript config
cat tsconfig.json 2>/dev/null | head -30

# Entry points
ls src/ app/ pages/ 2>/dev/null | head -20
```

Determine:
- Framework: Next.js App Router / Pages Router / Vite+React / CRA / Remix / Astro
- Bundler: Webpack 5 / Turbopack / Vite / esbuild / Rollup
- TypeScript: yes/no + strictness level
- CSS approach: Tailwind / CSS Modules / styled-components / Emotion / vanilla-extract
- State: Redux / Zustand / Jotai / React Query / SWR / Context-only

---

### Phase 2: Core Web Vitals Analysis

**Target thresholds (Google PageSpeed Insights "Good" rating):**

| Metric | Good | Needs Improvement | Poor |
|--------|------|-------------------|------|
| LCP (Largest Contentful Paint) | < 2.5s | 2.5s–4.0s | > 4.0s |
| CLS (Cumulative Layout Shift) | < 0.1 | 0.1–0.25 | > 0.25 |
| INP (Interaction to Next Paint) | < 200ms | 200ms–500ms | > 500ms |
| TTFB (Time to First Byte) | < 800ms | 800ms–1800ms | > 1800ms |
| FCP (First Contentful Paint) | < 1.8s | 1.8s–3.0s | > 3.0s |

**Commands (read-only, safe to run):**

```bash
# Check if Lighthouse CI is configured
cat .lighthouserc.json 2>/dev/null || cat .lighthouserc.js 2>/dev/null
cat lighthouserc.yml 2>/dev/null

# Check for Web Vitals instrumentation in code
grep -r "web-vitals\|getCLS\|getLCP\|getINP\|getTTFB\|onLCP\|onCLS\|onINP" src/ app/ --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" -l

# Check if RUM (Real User Monitoring) is set up
grep -r "reportWebVitals\|Datadog RUM\|newrelic\|dynatrace\|SpeedCurve\|@vercel/analytics" src/ app/ --include="*.ts" --include="*.tsx" -l

# Check for Next.js Analytics or Vercel Speed Insights
grep -r "SpeedInsights\|Analytics" src/ app/ --include="*.tsx" --include="*.ts" -l
```

**LCP Root Causes — check these:**

```bash
# 1. Hero images — are they preloaded?
grep -r "priority\|fetchpriority\|preload" src/ app/ --include="*.tsx" --include="*.jsx" -l
grep -r '<Image' src/ app/ --include="*.tsx" --include="*.jsx" | grep -v "priority" | head -10

# 2. LCP element — is it an unoptimized <img>?
grep -rn "<img " src/ app/ --include="*.tsx" --include="*.jsx" | grep -v "next/image" | head -10
# Every <img> should be next/image for automatic optimization

# 3. Fonts — blocking render?
grep -r "font-display\|next/font\|@font-face" src/ app/ --include="*.ts" --include="*.tsx" --include="*.css" -l

# 4. Server response time (TTFB) — check for slow data fetching
grep -rn "fetch\|axios\|prisma\|db\." app/ --include="*.ts" --include="*.tsx" | grep -E "async|await" | head -20
```

**CLS Root Causes — check these:**

```bash
# Images without explicit dimensions — CLS killer
grep -rn "width\|height" src/ app/ --include="*.tsx" | grep -i "image\|img" | head -10
grep -rn '<Image' src/ app/ --include="*.tsx" | grep -v "width\|fill" | head -10

# Dynamic content injected above fold (ads, banners)
grep -rn "dangerouslySetInnerHTML\|insertBefore\|prepend" src/ app/ --include="*.tsx" --include="*.ts" | head -10

# Fonts causing layout shift — check font-display
grep -rn "font-display" src/ app/ --include="*.css" --include="*.ts" --include="*.tsx"
# Should use font-display: optional or swap for body text, never block
```

**INP Root Causes — check these:**

```bash
# Long event handlers (synchronous heavy work on click/input)
grep -rn "onClick\|onChange\|onSubmit" src/ app/ --include="*.tsx" | head -20

# Check for startTransition usage (defers non-urgent updates)
grep -r "startTransition\|useTransition\|useDeferredValue" src/ app/ --include="*.tsx" -l

# Check for useEffect with heavy deps
grep -rn "useEffect" src/ app/ --include="*.tsx" | wc -l

# Check for web workers (CPU-heavy work offloaded)
grep -r "Worker\|Comlink\|workerize" src/ --include="*.ts" --include="*.tsx" -l
```

---

### Phase 3: Bundle Size Audit

```bash
# Check bundle analyzer setup
grep -r "bundle-analyzer\|BundleAnalyzerPlugin\|@next/bundle-analyzer" package.json

# Check .next/analyze if already built
ls .next/analyze/ 2>/dev/null

# source-map-explorer (if installed)
npx source-map-explorer 'build/static/js/*.js' --no-border-checks 2>/dev/null | head -30

# Check for large deps that have smaller alternatives
cat package.json | python3 -c "
import json, sys
pkg = json.load(sys.stdin)
deps = pkg.get('dependencies', {})
HEAVY = {
    'moment': 'use date-fns or dayjs (~2KB) instead',
    'lodash': 'use lodash-es or native ES6 methods',
    'jquery': 'not needed in React apps',
    'axios': 'fetch API is sufficient for most cases',
    'styled-components': 'large runtime; consider CSS Modules or Tailwind',
    '@mui/material': 'tree-shake properly or use headless (Radix/shadcn)',
    'antd': 'use modular imports, configure babel-plugin-import',
}
for dep, alt in HEAVY.items():
    if dep in deps:
        print(f'⚠ {dep}: {alt}')
"

# Check if tree-shaking is likely broken
grep -r "import \* as\|require(" src/ app/ --include="*.ts" --include="*.tsx" | grep -v "node_modules\|test\|spec" | head -10

# Check for dynamic imports (code splitting)
grep -r "dynamic(\|React.lazy\|import(" src/ app/ --include="*.ts" --include="*.tsx" | grep -v "node_modules" | head -20
```

**Bundle size thresholds:**

| Asset | Good | Warning | Critical |
|-------|------|---------|----------|
| Initial JS (gzipped) | < 100KB | 100–300KB | > 300KB |
| First route total | < 200KB | 200–500KB | > 500KB |
| Image (hero, above fold) | < 100KB (WebP/AVIF) | 100–300KB | > 300KB |

```bash
# Check Next.js build output (if .next exists)
ls -lh .next/static/chunks/*.js 2>/dev/null | sort -k5 -rh | head -15

# Check if image optimization is configured
grep -r "images:" next.config.* 2>/dev/null
grep -r "formats\|remotePatterns\|domains" next.config.* 2>/dev/null
```

---

### Phase 4: Next.js Architecture Review

#### App Router vs Pages Router

```bash
# Detect which router
ls app/ 2>/dev/null && echo "App Router detected"
ls pages/ 2>/dev/null && echo "Pages Router detected"
ls app/ pages/ 2>/dev/null && echo "⚠ HYBRID — mixing App + Pages Router (avoid)"

# Check for correct 'use client' / 'use server' boundaries
grep -r '"use client"' app/ --include="*.tsx" --include="*.ts" -l | wc -l
grep -r '"use server"' app/ --include="*.tsx" --include="*.ts" -l | wc -l

# Find components that should NOT be client components (static/no interaction)
grep -rn '"use client"' app/ --include="*.tsx" | head -20
# Review: are these truly interactive? Server Components are cheaper.
```

**App Router Client/Server boundary rules:**

| Component Has | Should Be |
|--------------|-----------|
| useState, useEffect, event handlers | `'use client'` |
| Data fetching, no interactivity | Server Component (default) |
| Browser APIs (window, localStorage) | `'use client'` |
| Heavy computation, no user interaction | Server Component |
| Context providers with state | `'use client'` |

```bash
# Check for data fetching anti-patterns
# BAD: useEffect + fetch in client component (no streaming, no caching)
grep -rn "useEffect" app/ --include="*.tsx" | xargs grep -l "fetch\|axios" 2>/dev/null | head -5

# GOOD: Server Component async fetch
grep -rn "async function\|export default async" app/ --include="*.tsx" | head -10

# Check for proper Suspense boundaries (streaming SSR)
grep -r "<Suspense\|Suspense>" app/ --include="*.tsx" -l

# Check for loading.tsx files (streaming)
find app/ -name "loading.tsx" 2>/dev/null
```

#### SSR / CSR / ISR / Streaming SSR Decision Matrix

| Pattern | When to Use | Next.js API |
|---------|-------------|-------------|
| **Server Component (RSC)** | Read-only data, SEO critical, no interactivity | Default in `app/` |
| **Client Component** | Interactive (forms, charts, modals) | `'use client'` |
| **Static (SSG)** | Content doesn't change per user (blog, docs) | `generateStaticParams` |
| **ISR** | Content changes but can be stale briefly (product catalog) | `revalidate: 3600` |
| **SSR** | Per-request personalized data (cart, auth state) | `no-store` fetch |
| **Streaming SSR** | Heavy data load, show skeleton immediately | `<Suspense>` + async RSC |
| **PPR (Partial Pre-rendering)** | Static shell + dynamic islands (Next.js 14+) | `experimental.ppr` |

```bash
# Check fetch cache strategies
grep -rn "cache:\|revalidate:\|next:" app/ --include="*.ts" --include="*.tsx" | head -20

# Flag uncached fetches in server components (will be called on every request)
grep -rn "fetch(" app/ --include="*.ts" --include="*.tsx" | grep -v "cache\|revalidate\|no-store\|test\|spec" | head -10
```

---

### Phase 5: State Management Architecture Review

```bash
# Identify state libraries in use
grep -r "redux\|@reduxjs/toolkit\|zustand\|jotai\|recoil\|react-query\|@tanstack/react-query\|swr\|xstate" package.json

# Check for global state anti-patterns
grep -rn "useContext" src/ app/ --include="*.tsx" | wc -l
grep -r "createContext" src/ app/ --include="*.tsx" -l

# Check for Redux store structure
ls src/store/ src/redux/ src/features/ app/store/ 2>/dev/null

# Check React Query / TanStack Query setup
grep -r "QueryClient\|QueryClientProvider\|useQuery\|useMutation" src/ app/ --include="*.tsx" -l | head -10
```

**State management decision matrix:**

| State Type | Right Tool | Wrong Tool |
|------------|-----------|------------|
| Server data (API responses) | React Query / SWR | Redux, useState |
| Global UI state (modal open, theme) | Zustand / Jotai | Redux (overengineered) |
| Complex workflows with transitions | XState | useState with booleans |
| Local component state | useState | Redux (always) |
| URL state (filters, pagination) | useSearchParams | useState |
| Form state | React Hook Form | useState per field |

**Anti-patterns to flag:**

```bash
# 1. Storing server data in Redux (React Query makes this redundant)
grep -rn "isLoading\|isFetching\|data:" src/store/ src/redux/ --include="*.ts" 2>/dev/null | head -10

# 2. Prop drilling > 2 levels (should use composition or context)
# Check: find components passed 5+ props
grep -rn "props\." src/ --include="*.tsx" | awk -F: '{print $1}' | sort | uniq -c | sort -rn | head -10

# 3. Context for high-frequency updates (causes re-render of all consumers)
grep -rn "createContext\|useContext" src/ app/ --include="*.tsx" -l

# 4. Missing staleTime in React Query (hammers API on every mount)
grep -rn "useQuery" src/ app/ --include="*.tsx" | grep -v "staleTime\|gcTime" | head -10
```

**React Query best practices check:**

```typescript
// BAD — refetches on every mount, no deduplication
const { data } = useQuery({ queryKey: ['products'], queryFn: fetchProducts })

// GOOD — cached 5min, background refetch after 1min
const { data } = useQuery({
  queryKey: ['products'],
  queryFn: fetchProducts,
  staleTime: 60_000,       // 1min before refetch
  gcTime: 5 * 60_000,      // 5min cache lifetime
})
```

---

### Phase 6: React Rendering Optimization

```bash
# Find potential unnecessary re-render sources

# 1. Inline object/array in JSX (new reference every render)
grep -rn "style={{" src/ app/ --include="*.tsx" | wc -l
grep -rn "={{" src/ app/ --include="*.tsx" | grep -v "className\|data-\|aria-\|href\|src\|alt\|type\|key\|id\|name\|value\|placeholder" | head -20

# 2. Missing useCallback on event handlers passed to children
grep -rn "const handle\|const on" src/ app/ --include="*.tsx" | grep -v "useCallback" | head -20

# 3. Missing useMemo on expensive computations
grep -rn "\.filter(\|\.map(\|\.reduce(\|\.sort(" src/ app/ --include="*.tsx" | grep -v "useMemo\|test\|spec" | head -20

# 4. React.memo usage
grep -r "React.memo\|memo(" src/ app/ --include="*.tsx" -l

# 5. Key prop issues (using index as key — causes re-render problems)
grep -rn "key={index}\|key={i}" src/ app/ --include="*.tsx" | head -10
```

**Code splitting audit:**

```bash
# Dynamic imports for heavy components
grep -r "dynamic(\|React.lazy(" src/ app/ --include="*.tsx" -l

# Heavy libraries loaded eagerly (should be dynamic)
grep -rn "import.*chart\|import.*editor\|import.*map\|import.*pdf\|import.*monaco\|import.*quill" src/ app/ --include="*.tsx" | grep -v "dynamic\|lazy" | head -10
# Chart.js, Monaco Editor, PDF.js, map libraries should always be dynamically imported

# Check for barrel file anti-pattern (breaks tree shaking)
find src/ -name "index.ts" -o -name "index.tsx" 2>/dev/null | xargs grep -l "export \*\|export {" 2>/dev/null | head -10
```

**Virtualization for long lists:**

```bash
# Lists that likely need virtualization (> 100 items)
grep -rn "\.map(" src/ app/ --include="*.tsx" | grep -i "product\|item\|list\|row\|result" | head -10

# Check for virtualization libraries
grep -r "react-virtual\|@tanstack/virtual\|react-window\|react-virtualized\|virtua" package.json
```

---

### Phase 7: Frontend Security Review

```bash
# 1. Content Security Policy
grep -r "Content-Security-Policy\|CSP\|contentSecurityPolicy" next.config.* src/ app/ --include="*.ts" --include="*.tsx" --include="*.js" -l

# Check headers in next.config
grep -A 20 "headers" next.config.* 2>/dev/null | head -30

# 2. XSS vectors
grep -rn "dangerouslySetInnerHTML" src/ app/ --include="*.tsx" --include="*.ts" | head -10
# Each instance needs manual review — is the content sanitized?
grep -rn "innerHTML\|document.write\|eval(" src/ app/ --include="*.ts" --include="*.tsx" | head -10

# 3. Third-party scripts — CSP bypass risk
grep -r "script\|<Script" src/ app/ --include="*.tsx" | grep -v "//\|test\|spec" | head -10
grep -r "src=\"https://\|src='https://" src/ app/ --include="*.tsx" --include="*.html" | head -10

# 4. Exposed secrets in frontend code
grep -rn "NEXT_PUBLIC_" src/ app/ --include="*.ts" --include="*.tsx" | grep -i "secret\|key\|password\|token\|private" | head -10
# NEXT_PUBLIC_ vars are exposed to browsers — never put secrets here

# 5. CORS — check for overly permissive API routes
grep -rn "Access-Control-Allow-Origin\|cors\|CORS" app/ --include="*.ts" | head -10

# 6. Clickjacking — X-Frame-Options / frame-ancestors
grep -rn "X-Frame-Options\|frame-ancestors" next.config.* src/ app/ --include="*.ts" -l

# 7. Open redirects
grep -rn "redirect(\|router.push\|window.location" src/ app/ --include="*.ts" --include="*.tsx" | head -20
# Check if redirect destinations are validated
```

**Recommended security headers for Next.js:**

```typescript
// next.config.ts — security headers
const securityHeaders = [
  { key: 'X-DNS-Prefetch-Control', value: 'on' },
  { key: 'X-Frame-Options', value: 'SAMEORIGIN' },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
  {
    key: 'Content-Security-Policy',
    value: [
      "default-src 'self'",
      "script-src 'self' 'unsafe-eval' 'unsafe-inline'",  // tighten in prod
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: https:",
      "font-src 'self'",
      "connect-src 'self' https://api.yourdomain.com",
    ].join('; '),
  },
]
```

```bash
# 8. Dependency vulnerabilities
npm audit --audit-level=high 2>/dev/null | head -30
# ⚠️ Ask user before running — reads local package-lock.json, no network writes
```

---

### Phase 8: Accessibility (WCAG 2.1 AA) Review

```bash
# 1. Check for a11y tooling
grep -r "eslint-plugin-jsx-a11y\|axe-core\|@axe-core\|cypress-axe\|jest-axe\|pa11y\|playwright-axe" package.json

# 2. Semantic HTML — landmark elements
grep -rn "<div.*onClick\|<span.*onClick" src/ app/ --include="*.tsx" | head -10
# Divs/spans with onClick should be <button> elements

# 3. Missing ARIA labels
grep -rn "<button\|<a " src/ app/ --include="*.tsx" | grep -v "aria-label\|aria-labelledby\|children\|text" | head -10

# 4. Image alt text
grep -rn "<img\|<Image" src/ app/ --include="*.tsx" | grep -v "alt=" | head -10
# Every image needs alt text (empty "" for decorative images)

# 5. Form labels
grep -rn "<input\|<select\|<textarea" src/ app/ --include="*.tsx" | grep -v "aria-label\|aria-labelledby\|<label\|id=" | head -10

# 6. Focus management (modals, dialogs)
grep -r "focus-trap\|FocusTrap\|Dialog\|Modal" src/ app/ --include="*.tsx" -l

# 7. Color contrast — automated check needs browser tool
# Manual: check via Chrome DevTools > Accessibility > Contrast Ratio

# 8. Keyboard navigation
grep -rn "tabIndex\|onKeyDown\|onKeyPress\|onKeyUp" src/ app/ --include="*.tsx" | head -10

# 9. Skip navigation link (bypass navigation for keyboard users)
grep -rn "skip.*nav\|skip.*link\|skipnav\|sr-only" src/ app/ --include="*.tsx" --include="*.css" | head -5
```

**WCAG 2.1 AA — Critical checklist:**

| Criterion | Level | How to Verify |
|-----------|-------|--------------|
| Text alternatives (images) | A | `grep -rn "<img" | grep -v "alt="` |
| Keyboard accessible | A | Tab through entire page |
| No keyboard trap | A | Verify modal closes with Esc |
| Contrast ratio 4.5:1 (text) | AA | Chrome DevTools Accessibility panel |
| Contrast ratio 3:1 (UI components) | AA | Chrome DevTools |
| Focus visible | AA | Tab — is outline visible? |
| Labels for form fields | A | `grep -rn "<input" | grep -v "aria-label\|<label"` |
| Error messages in text (not color only) | A | Check form validation UX |
| Reflow at 400% zoom | AA | Browser zoom test |
| ARIA roles used correctly | - | axe DevTools browser extension |

---

### Phase 9: Performance Budget & Monitoring

```bash
# Check if performance budget is defined
cat .lighthouserc.json 2>/dev/null | python3 -m json.tool 2>/dev/null
grep -r "budget\|budgets\|performanceBudget" next.config.* webpack.config.* 2>/dev/null

# Check for RUM setup (Real User Monitoring — most important, CrUX data)
grep -r "reportWebVitals\|onINP\|onLCP\|onCLS\|onTTFB" src/ app/ pages/ --include="*.ts" --include="*.tsx" -l

# Check for error boundary coverage
grep -r "ErrorBoundary\|componentDidCatch\|error.tsx\|global-error.tsx" src/ app/ --include="*.tsx" -l
```

**Without RUM, you're flying blind.** Lab data (Lighthouse) != field data (CrUX).

---

### Phase 10: Self-Review Before Reporting

Before producing findings, verify:

- [ ] Ran Phase 1–9 commands — not guessing from memory
- [ ] All findings have exact file + line number references
- [ ] LCP/CLS/INP issues: identified the specific component/element causing them
- [ ] Bundle issues: named the exact package causing bloat
- [ ] Security issues: included reproduction steps, not just "XSS possible"
- [ ] Accessibility issues: listed specific WCAG criterion violated
- [ ] No Go language examples anywhere — TypeScript/JavaScript only
- [ ] Recommendations are specific to THIS project's stack, not generic

---

### Findings Format

Produce output in this structure:

```
## Frontend Review — [Project Name]

### Stack
- Framework: Next.js 14.2 (App Router)
- Bundler: Webpack 5 (Turbopack in dev)
- State: React Query v5 + Zustand
- CSS: Tailwind CSS 3.4 + CSS Modules
- TypeScript: strict mode enabled

### Critical (fix before next release)
1. **[Category] [Metric/Rule]** — [Specific finding]
   - File: `src/components/Hero.tsx:34`
   - Impact: [measured or estimated]
   - Fix: [exact code change or command]

### High (fix this sprint)
...

### Medium (backlog)
...

### Low (nice to have)
...

### What's Working Well
- [Don't only report problems — call out good patterns]
```

---

## DESIGN MODE

### Step 1: Requirements Gathering

Ask:
1. "What type of application? (ecommerce storefront, admin dashboard, content site, SaaS app)"
2. "Expected traffic? (DAU, peak concurrent users)"
3. "SEO requirements? (full SEO = SSR/SSG, internal tool = CSR ok)"
4. "Authentication? (session-based, JWT, OAuth)"
5. "Real-time features? (live updates, chat, notifications)"
6. "Target devices? (mobile-first, desktop, both)"
7. "Performance targets? (LCP goal, geographic regions)"

### Step 2: Framework & Rendering Strategy

**Decision tree for Next.js ecommerce:**

```
Is content SEO-critical?
  YES → Next.js App Router
    Is content personalized per user?
      YES → SSR (no-store fetch) + React Query for client state
      NO  → ISR with revalidate (product catalog: 1h, inventory: 30s)
    Is content static? (blog, docs)
      YES → SSG with generateStaticParams
  NO  → CSR (admin dashboard, internal tools)
```

**Architecture template (Next.js ecommerce):**

```
app/
├── (auth)/                # Route group — auth layout
│   ├── login/
│   └── register/
├── (shop)/                # Route group — shop layout
│   ├── page.tsx           # Home — ISR revalidate 3600
│   ├── products/
│   │   ├── page.tsx       # Product listing — ISR revalidate 1800
│   │   └── [slug]/
│   │       └── page.tsx   # Product detail — ISR revalidate 300
│   └── cart/
│       └── page.tsx       # Cart — SSR (personalized)
├── api/                   # API routes (BFF pattern)
│   └── [...]/route.ts
├── layout.tsx             # Root layout — Providers here
└── globals.css

src/
├── components/
│   ├── ui/                # shadcn/Radix primitives
│   ├── features/          # Feature-specific components
│   └── layouts/
├── lib/
│   ├── api/               # API client functions
│   ├── hooks/             # Custom hooks
│   └── utils/
├── store/                 # Zustand stores (UI state only)
└── types/                 # TypeScript interfaces
```

### Step 3: State Architecture

```typescript
// Layer 1: Server state — React Query (TanStack Query)
// Never put API responses in Redux or Zustand
const { data: products } = useQuery({
  queryKey: ['products', filters],
  queryFn: () => fetchProducts(filters),
  staleTime: 60_000,
})

// Layer 2: Global UI state — Zustand (lightweight)
const useCartStore = create<CartState>((set) => ({
  isOpen: false,
  openCart: () => set({ isOpen: true }),
  closeCart: () => set({ isOpen: false }),
}))

// Layer 3: URL state — useSearchParams (shareable, bookmarkable)
const searchParams = useSearchParams()
const category = searchParams.get('category')

// Layer 4: Form state — React Hook Form (isolated, performant)
const { register, handleSubmit } = useForm<CheckoutForm>()

// Layer 5: Local state — useState (component-scoped)
const [isExpanded, setIsExpanded] = useState(false)
```

### Step 4: Performance Architecture

**Image optimization:**
```typescript
// next/image with priority for LCP element
<Image
  src="/hero.webp"
  alt="Product hero"
  width={1200}
  height={630}
  priority           // Preloads — use for above-fold LCP element ONLY
  sizes="(max-width: 768px) 100vw, 1200px"
  quality={85}
/>
```

**Font loading (zero CLS):**
```typescript
// next/font — self-hosted, zero layout shift
import { Inter } from 'next/font/google'
const inter = Inter({
  subsets: ['latin'],
  display: 'swap',     // or 'optional' for CLS=0
  preload: true,
})
```

**Code splitting pattern:**
```typescript
// Dynamic import for below-fold heavy components
const ProductReviews = dynamic(() => import('@/components/ProductReviews'), {
  loading: () => <ReviewsSkeleton />,
  ssr: false,  // Client-only (uses browser APIs)
})

// Dynamic import with SSR for SEO-critical content
const ProductDescription = dynamic(() => import('@/components/ProductDescription'))
```

### Step 5: Security Architecture

```typescript
// Middleware — auth protection + CSP nonce
// middleware.ts
export function middleware(request: NextRequest) {
  // 1. Auth check
  const token = request.cookies.get('auth-token')
  if (!token && isProtectedRoute(request.nextUrl.pathname)) {
    return NextResponse.redirect(new URL('/login', request.url))
  }

  // 2. Security headers (CSP with nonce for inline scripts)
  const nonce = Buffer.from(crypto.randomUUID()).toString('base64')
  const response = NextResponse.next()
  response.headers.set('x-nonce', nonce)
  response.headers.set('Content-Security-Policy',
    `default-src 'self'; script-src 'self' 'nonce-${nonce}'; ...`
  )
  return response
}
```

### Step 6: Produce Architecture Document

Output:
1. Component hierarchy diagram (ASCII)
2. State management map (which state lives where)
3. Data fetching strategy per route
4. Performance budget per route
5. Security checklist
6. Accessibility requirements
7. Open questions requiring product decisions

---

**Save:** use the Write tool to save this document to `docs/reviews/frontend-review-[date].md` (or user-specified path).

**What to run next:**
- `/principal:perf-audit` — if Core Web Vitals or bundle size issues were found, run a full performance audit
- `/principal:threat-model` — if auth flows, file uploads, or third-party scripts were reviewed
- `/principal:tech-debt` — if systematic frontend debt patterns were found that need sprint allocation

---

## Common Frontend Debt Patterns in Ecommerce

| Anti-Pattern | Symptom | Fix |
|-------------|---------|-----|
| `useEffect` for server data | Network waterfall, no caching | React Query + Server Components |
| Redux for everything | 3000-line reducers, boilerplate | Zustand (UI) + React Query (server) |
| No ISR on product pages | Every hit → DB query | `revalidate: 300` on product pages |
| `<img>` instead of `<Image>` | No optimization, CLS, slow LCP | Replace with `next/image` + `priority` |
| Missing Suspense boundaries | All-or-nothing page load | Wrap async components with `<Suspense>` |
| Barrel file re-exports (`export *`) | Can't tree-shake | Named imports from specific files |
| `key={index}` in lists | List re-renders on sort/filter | Use stable IDs as keys |
| No error boundaries | White screen on API failure | `error.tsx` per route segment |
| `any` type everywhere | Runtime crashes in prod | Enable strict TypeScript |
| Third-party scripts in `<head>` | Render-blocking | Next.js `<Script strategy="lazyOnload">` |
