---
---
description: Generate an architecture diagram in ASCII or Mermaid from a description
---

Given the system description in $ARGUMENTS:

1. If the user is in a codebase, read relevant source files (routes, services, configs, docker-compose) to understand the actual architecture before drawing.
2. Produce TWO diagram formats:

   **ASCII diagram** (copy-pasteable into any doc, chat, or code comment):
   ```
   ┌──────────┐      ┌──────────┐      ┌──────────┐
   │ Client   │─────▶│ Service  │─────▶│ Database │
   └──────────┘      └──────────┘      └──────────┘
   ```
   Use: ─ │ ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼ ▶ ▼ for lines and arrows.
   Use: ──→ for sync calls, ══⇒ for async/event flows.

   **Mermaid diagram** (renderable in GitHub, Notion, Confluence):
   ```mermaid
   graph LR
     Client --> Service --> Database
   ```

3. Include in the diagram:
   - All services/components mentioned or discovered in code
   - Data stores (databases, caches, queues)
   - External dependencies
   - Communication protocols on arrows (HTTP, gRPC, async/queue)
   - Trust boundaries if security-relevant

4. After the diagram, add a **Component Legend** listing each component with a one-line description of its responsibility.

---
