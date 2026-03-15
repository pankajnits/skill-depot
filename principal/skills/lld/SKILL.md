---
name: lld
description: |
  Produce a Low Level Design document from an approved HLD or feature specification.
  Translates high-level system decisions into concrete interface contracts, database schemas,
  class/module designs, error handling strategies, and test plans. Covers API request/response
  contracts with error codes, data model with full DDL, service interfaces, key algorithms
  with complexity analysis, edge cases, and testing strategy. Use after an HLD is approved
  and before engineers begin implementation.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Write
  - AskUserQuestion
---

# /principal:lld — Low Level Design

You are acting as a staff engineer producing a Low Level Design document. An LLD is the implementation blueprint — specific enough that any engineer on the team can pick it up and build their component without ambiguity, but not so specific that it dictates implementation details that don't affect the interface.

**What LLD is NOT:** an LLD is not code. It does not specify variable names, function bodies, or internal implementation details that don't cross a module boundary. Over-specification creates maintenance burden without adding value.

**What LLD IS:** the contract between modules. The interface every component exposes, the data model, the error taxonomy, the edge cases, and the test plan.

## GATHER CONTEXT

Ask the user for anything not provided:

1. **HLD link or description:** what are the high-level design decisions this LLD implements?
2. **Scope:** which component(s) are we designing in detail?
3. **Tech stack:** language, framework, ORM, API style (REST/GraphQL/gRPC)?
4. **Team:** how many engineers, what's their level?
5. **Existing patterns:** are there existing API conventions, error formats, or schema patterns to follow?

If in a repo, read existing API handlers, models, and service interfaces before writing:
```bash
find . -name "*.ts" -o -name "*.java" -o -name "*.py" | xargs grep -l "class\|interface\|@Service\|@Component" 2>/dev/null | head -10
```

---

## PHASE 1 — Component Decomposition

From the HLD, enumerate every component that needs a detailed design. For each:

| Component | Responsibility | Owner team | Dependencies |
|-----------|---------------|-----------|-------------|
| | | | |

Produce a component interaction diagram showing which components call which, and whether calls are sync (→) or async (⇢):

```
┌──────────────┐      ┌──────────────┐      ┌──────────────────┐
│  OrderAPI    │──→───│ OrderService │──⇢───│ NotificationQueue│
└──────────────┘      └──────┬───────┘      └──────────────────┘
                             │ sync
                     ┌───────▼────────┐
                     │   OrderRepo    │
                     └───────┬────────┘
                             │
                     ┌───────▼────────┐
                     │   PostgreSQL   │
                     └────────────────┘
```

---

## PHASE 2 — API Contract Design

For each public API endpoint or service interface:

**REST endpoint format:**

```
[METHOD] /[version]/[resource]

Purpose: [one sentence]

Authentication: [Bearer token / API key / Service-to-service mTLS / Public]

Request headers:
  Content-Type: application/json
  Idempotency-Key: [UUID] (required for POST/PUT)

Request body:
{
  "field_name": type,          // required — description
  "optional_field": type,      // optional — description, default: value
}

Validation rules:
  - field_name: max 255 chars, must match pattern /^[a-zA-Z0-9_-]+$/
  - optional_field: must be one of: [enum values]

Success response 200/201:
{
  "id": "uuid",
  "status": "string",
  "created_at": "ISO8601",
}

Error responses:
  400 Bad Request   — validation failure: { "error": "invalid_field", "field": "name", "message": "..." }
  401 Unauthorized  — missing/invalid auth token
  409 Conflict      — duplicate idempotency_key or resource already exists
  422 Unprocessable — business rule violation: { "error": "insufficient_inventory", "message": "..." }
  429 Too Many Req  — rate limited: { "error": "rate_limited", "retry_after_seconds": 30 }
  503 Unavailable   — dependency failure (transient, safe to retry after back-off)

Idempotency:
  POST endpoints that create resources MUST be idempotent.
  Idempotency-Key: client provides UUID; server caches response for 24h.
  Duplicate request within TTL: return original 201 response, do not create duplicate.

Rate limits: [X] requests per [minute/hour] per [user/IP/tenant]
Timeout: [Xms] server-side
```

**For gRPC services:**
```protobuf
service OrderService {
  rpc CreateOrder(CreateOrderRequest) returns (CreateOrderResponse) {}
  rpc GetOrder(GetOrderRequest) returns (Order) {}
}

message CreateOrderRequest {
  string user_id = 1;          // required, UUID format
  repeated OrderItem items = 2; // required, min 1 item
  string idempotency_key = 3;  // required, UUID format
}

// Error codes:
// INVALID_ARGUMENT (3): validation failure
// ALREADY_EXISTS (6): duplicate idempotency_key
// UNAVAILABLE (14): transient dependency failure
```

---

## PHASE 3 — Data Model (Full DDL)

For every table/collection, produce the complete schema with constraints and indexes:

**PostgreSQL example:**
```sql
-- Orders table
CREATE TABLE orders (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID          NOT NULL REFERENCES users(id),
  status          order_status  NOT NULL DEFAULT 'pending',
  total_amount    NUMERIC(12,2) NOT NULL CHECK (total_amount > 0),
  idempotency_key UUID          NOT NULL,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  deleted_at      TIMESTAMPTZ   -- soft delete; NULL = not deleted
);

CREATE TYPE order_status AS ENUM ('pending', 'confirmed', 'shipped', 'delivered', 'cancelled');

-- Indexes
CREATE UNIQUE INDEX idx_orders_idempotency   ON orders(idempotency_key);
CREATE INDEX idx_orders_user_id              ON orders(user_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_orders_status_created       ON orders(status, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_orders_user_status          ON orders(user_id, status) WHERE deleted_at IS NULL;

-- Trigger: auto-update updated_at
CREATE TRIGGER orders_updated_at
  BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
```

**For each table, document:**
- Why each index exists (which query pattern it serves)
- Which columns are intentionally nullable and why
- Soft delete strategy (partial index `WHERE deleted_at IS NULL`)
- Foreign key constraints and cascade behavior

---

## PHASE 4 — Service Layer Interface

For each service class/module, define the interface contract:

**TypeScript example:**
```typescript
interface OrderService {
  /**
   * Creates a new order. Idempotent: calling with the same idempotencyKey returns
   * the existing order without creating a duplicate.
   *
   * @throws OrderValidationError if items list is empty or item quantities are invalid
   * @throws InventoryUnavailableError if any item is out of stock
   * @throws DuplicateOrderError if idempotencyKey is already used by a different request body
   */
  createOrder(params: CreateOrderParams): Promise<Order>;

  /**
   * Returns order by ID. Respects soft-delete: deleted orders return null, not a 404.
   * Callers must handle the null case explicitly.
   */
  getOrderById(orderId: string, userId: string): Promise<Order | null>;

  /**
   * Cancels an order. Only valid for status: 'pending' | 'confirmed'.
   * Idempotent: cancelling an already-cancelled order is a no-op.
   *
   * @throws OrderNotCancellableError if order is in status 'shipped' or 'delivered'
   */
  cancelOrder(orderId: string, userId: string): Promise<Order>;
}
```

**Java / Spring Boot equivalent:**
```java
// Service interface — framework-agnostic contract
public interface OrderService {
    /**
     * Creates a new order. Idempotent via idempotencyKey.
     *
     * @throws OrderValidationException if items list is empty or quantities invalid
     * @throws InventoryUnavailableException if any SKU is out of stock
     * @throws DuplicateOrderException if idempotencyKey conflicts with a different request
     */
    Order createOrder(CreateOrderRequest request, String idempotencyKey);

    /**
     * Returns order by ID scoped to userId. Returns Optional.empty() for soft-deleted orders
     * — callers must handle the empty case explicitly (do not throw 404 here).
     */
    Optional<Order> getOrderById(String orderId, String userId);

    /**
     * Cancels an order. Only valid for PENDING or CONFIRMED status.
     * Idempotent: cancelling an already-CANCELLED order is a no-op, returns current state.
     *
     * @throws OrderNotCancellableException if status is SHIPPED or DELIVERED
     */
    Order cancelOrder(String orderId, String userId);
}

// Implementation — Spring stereotype for DI
@Service
@Transactional
public class OrderServiceImpl implements OrderService {
    private final OrderRepository orderRepository;
    private final InventoryClient inventoryClient;
    private final EventPublisher eventPublisher;

    // Constructor injection — preferred over @Autowired field injection
    public OrderServiceImpl(OrderRepository orderRepository,
                            InventoryClient inventoryClient,
                            EventPublisher eventPublisher) {
        this.orderRepository = orderRepository;
        this.inventoryClient = inventoryClient;
        this.eventPublisher = eventPublisher;
    }

    @Override
    public Order createOrder(CreateOrderRequest request, String idempotencyKey) {
        // Check idempotency first (before any write)
        return orderRepository.findByIdempotencyKey(idempotencyKey)
            .orElseGet(() -> doCreateOrder(request, idempotencyKey));
    }
    // ... rest of implementation
}
```

**Define a typed exception hierarchy for every service:**
```java
// Base — maps to HTTP 400 in @ControllerAdvice
public class OrderValidationException extends RuntimeException {
    private final String field;
    private final String reason;
    public OrderValidationException(String field, String reason) {
        super(String.format("Validation failed on '%s': %s", field, reason));
        this.field = field;
        this.reason = reason;
    }
}

// Maps to HTTP 409
public class InventoryUnavailableException extends RuntimeException {
    private final List<String> unavailableSkus;
    public InventoryUnavailableException(List<String> skus) {
        super("Inventory unavailable for SKUs: " + skus);
        this.unavailableSkus = skus;
    }
}

// Maps to HTTP 422
public class OrderNotCancellableException extends RuntimeException {
    private final OrderStatus currentStatus;
    public OrderNotCancellableException(OrderStatus status) {
        super("Order cannot be cancelled in status: " + status);
        this.currentStatus = status;
    }
}
```

**Python / FastAPI equivalent:**
```python
# Pydantic models — data contract with automatic validation
from pydantic import BaseModel, Field, validator
from typing import Optional
from enum import Enum

class OrderStatus(str, Enum):
    PENDING = "pending"
    CONFIRMED = "confirmed"
    SHIPPED = "shipped"
    DELIVERED = "delivered"
    CANCELLED = "cancelled"

class CreateOrderRequest(BaseModel):
    items: list[OrderItem] = Field(..., min_items=1)
    shipping_address_id: str
    idempotency_key: str = Field(..., min_length=16, max_length=64)

    @validator('items')
    def validate_quantities(cls, items):
        for item in items:
            if item.quantity <= 0:
                raise ValueError(f"Item {item.sku_id} quantity must be positive")
        return items

class Order(BaseModel):
    id: str
    status: OrderStatus
    items: list[OrderItem]
    total_amount: int  # always store money as paise/cents — never float
    created_at: datetime

# Service interface — abstract base class (Protocol preferred in modern Python)
from abc import ABC, abstractmethod
from typing import Protocol

class OrderService(Protocol):
    """
    Async service interface for order management.
    All methods are idempotent unless otherwise noted.
    """

    async def create_order(
        self,
        request: CreateOrderRequest,
        user_id: str,
    ) -> Order:
        """
        Creates a new order. Idempotent via idempotency_key.

        Raises:
            OrderValidationError: items empty or quantities invalid
            InventoryUnavailableError: one or more SKUs out of stock
            DuplicateOrderError: idempotency_key reused with different payload
        """
        ...

    async def get_order_by_id(
        self,
        order_id: str,
        user_id: str,
    ) -> Optional[Order]:
        """Returns None for soft-deleted orders. Never raises 404."""
        ...

    async def cancel_order(
        self,
        order_id: str,
        user_id: str,
    ) -> Order:
        """
        Cancels an order. Idempotent: cancelling a CANCELLED order returns current state.

        Raises:
            OrderNotCancellableError: status is SHIPPED or DELIVERED
            OrderNotFoundError: order doesn't belong to user_id
        """
        ...

# Implementation with FastAPI dependency injection
from fastapi import Depends
from sqlalchemy.ext.asyncio import AsyncSession

class OrderServiceImpl:
    def __init__(
        self,
        db: AsyncSession,  # injected via Depends(get_db)
        inventory_client: InventoryClient,
        event_publisher: EventPublisher,
    ):
        self.db = db
        self.inventory_client = inventory_client
        self.event_publisher = event_publisher

    async def create_order(self, request: CreateOrderRequest, user_id: str) -> Order:
        # Check idempotency first — before any write
        existing = await self._find_by_idempotency_key(request.idempotency_key)
        if existing:
            return existing
        return await self._do_create_order(request, user_id)

# FastAPI router — thin layer, no business logic here
from fastapi import APIRouter, HTTPException, Header

router = APIRouter(prefix="/orders", tags=["orders"])

@router.post("/", response_model=Order, status_code=201)
async def create_order(
    request: CreateOrderRequest,
    idempotency_key: str = Header(..., alias="Idempotency-Key"),
    order_service: OrderService = Depends(get_order_service),
    current_user: User = Depends(get_current_user),
):
    try:
        return await order_service.create_order(request, current_user.id)
    except OrderValidationError as e:
        raise HTTPException(status_code=422, detail={"field": e.field, "reason": e.reason})
    except InventoryUnavailableError as e:
        raise HTTPException(status_code=409, detail={"unavailable_skus": e.skus})
```

**Python typed exception hierarchy:**
```python
class OrderError(Exception):
    """Base — maps to HTTP 400"""
    pass

class OrderValidationError(OrderError):
    """Maps to HTTP 422"""
    def __init__(self, field: str, reason: str):
        self.field = field
        self.reason = reason
        super().__init__(f"Validation failed on '{field}': {reason}")

class InventoryUnavailableError(OrderError):
    """Maps to HTTP 409"""
    def __init__(self, skus: list[str]):
        self.skus = skus
        super().__init__(f"Inventory unavailable for: {skus}")

class OrderNotCancellableError(OrderError):
    """Maps to HTTP 422"""
    def __init__(self, current_status: OrderStatus):
        self.current_status = current_status
        super().__init__(f"Cannot cancel order in status: {current_status}")

class OrderNotFoundError(OrderError):
    """Maps to HTTP 404"""
    pass
```

**TypeScript / Node.js typed error taxonomy:**
```typescript
class OrderValidationError extends Error {
  constructor(public field: string, public reason: string) { super() }
}
class InventoryUnavailableError extends Error {
  constructor(public skus: string[]) { super() }
}
class OrderNotCancellableError extends Error {
  constructor(public currentStatus: OrderStatus) { super() }
}
```

Every error must map to exactly one HTTP status code. Document the mapping.

---

## PHASE 5 — Key Algorithms and Flows

Only for non-trivial logic that could be implemented multiple ways with meaningfully different behavior:

**Sequence diagram for complex flows:**
```
Client → OrderAPI → OrderService → InventoryService → OrderRepo → DB
  |           |           |               |               |
  |  POST /orders         |               |               |
  |           | validate request          |               |
  |           | create order (pending)    |               |
  |           |           | reserve items |               |
  |           |           |    ←OK        |               |
  |           |           | save order ───────────────────▶|
  |           |           |              ←────────────────|
  |           |           | publish OrderCreated event     |
  |  ←201 Created         |               |               |
```

**Algorithm complexity (for any non-O(1) or O(n) operation):**
- Time complexity: O(?)
- Space complexity: O(?)
- Performance at expected scale (e.g., "O(n log n) sort on 10k items = ~130k operations, <10ms")

---

## PHASE 6 — Error Handling Strategy

Define the system-wide error handling contract:

**Error categories:**
| Category | Retry? | User visible? | Alert? | Example |
|----------|--------|--------------|--------|---------|
| Validation | No | Yes | No | Invalid email format |
| Business rule | No | Yes | No | Insufficient balance |
| Transient | Yes (backoff) | Degraded UI | If prolonged | DB timeout |
| Dependency down | Yes (circuit breaker) | Yes (503) | Yes | Payment service down |
| Data consistency | No | No | Yes (P0) | Duplicate record found |
| Unexpected | No | No | Yes (P0) | NullPointerException |

**Retry policy:**
```
Retryable errors:    503, 429, network timeouts
Not retryable:       400, 401, 403, 409, 422
Backoff:             Initial 100ms, multiplier 2×, max 5 retries, cap 30s, full jitter
Idempotency:         All retried requests must include the same Idempotency-Key
```

---

## PHASE 7 — Edge Cases Inventory

For every component, enumerate the edge cases that must be tested:

| Edge case | Expected behavior | Risk if not handled |
|-----------|-----------------|-------------------|
| Empty items list in CreateOrder | 400, field: items, reason: "must have at least 1 item" | Silent no-op order creation |
| Concurrent CreateOrder with same idempotency_key | First wins; second returns 201 with original response | Duplicate orders, billing issues |
| User creates order then is deleted | Soft-deleted user: return 403, do not process | Data integrity violation |
| Inventory reserved but DB write fails | Roll back inventory reservation | Ghost inventory reservation, oversell |
| Payment succeeds but status update fails | Idempotent retry picks up from payment success checkpoint | Double charge or unfulfilled order |

---

## PHASE 8 — Test Plan

**Unit tests (cover the service layer):**
- Happy path for every public method
- Every error case in the error taxonomy
- Every edge case in the inventory above
- Coverage target: 90% line coverage of service layer

**Integration tests (cover the API layer end-to-end):**
- Every endpoint with a real database (no mocks at this level)
- Concurrency test: simulate simultaneous requests with the same idempotency key
- Boundary tests: maximum payload sizes, empty lists, null values

**Load test plan:**
- Tool: k6, Locust, or equivalent
- Baseline: [N] virtual users, [M] RPS, [T] duration
- Success criteria: P99 < [Xms], error rate < 0.1%, no data corruption

**Contract tests (if service is consumed by other teams):**
- Consumer-driven contracts using Pact or equivalent
- Provider runs contract tests in CI; failing contract tests block deployment

---

## PHASE 9 — Self-Review Checklist

- [ ] Is every public interface fully typed (no `any`, no `object`)?
- [ ] Is every error case named, typed, and mapped to an HTTP status code?
- [ ] Is every index explained (which query pattern it serves)?
- [ ] Are idempotency and concurrency addressed for all write operations?
- [ ] Are the edge cases in Phase 7 comprehensive enough to build test cases from?
- [ ] Is the LLD specific enough to implement without ambiguity, but not so specific it dictates internals?
- [ ] Is the test plan runnable (concrete tools, concrete coverage targets)?

---

## OUTPUT

1. **Component diagram** with sync/async call markers
2. **API contracts** (complete request/response specs, error taxonomy)
3. **Data model** (full DDL with indexes, constraints, and justification)
4. **Service interfaces** (typed, with documented error contracts)
5. **Key algorithm flows** (sequence diagrams for non-trivial flows)
6. **Edge cases inventory** (table format, ready to become test cases)
7. **Test plan** (unit + integration + load + contract testing specs)

**Save:** use the Write tool to save this document to `docs/designs/[feature-name]-lld.md` (or user-specified path).

**What to run next:**
- `/principal:api-design` — finalize the API contract with full versioning, rate limiting, and consumer migration guide
- `/principal:db-review` — deep review of the data model defined here
- `/principal:adr` — record each significant design decision (data model choice, interface pattern, error strategy)
