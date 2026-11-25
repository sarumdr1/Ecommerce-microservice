# Polyglot gRPC E-Commerce Platform with Agentic AI

**PRODUCT REQUIREMENTS DOCUMENT · IDP P4 REFERENCE BUILD**

Local-first build with Docker Compose, agentic AI as a first-class service, AWS deployment as the final phase. Built with Claude Code.

| Field | Value | Field | Value |
|---|---|---|---|
| Product & Tech Lead | Saru | Document Status | Draft — Ready for Technical Review |
| Cloud Platform | AWS, single region, three Availability Zones (Phase 6) | Build Environment | Local Docker Compose (Phases 0–5); AWS from Phase 6 |
| Service Protocol | gRPC (HTTP/2 + Protobuf) internally; REST/JSON at the edge; RabbitMQ events (EventBridge + SQS on AWS) | System Topology | Gateway, Web BFF, 7 domain services, Agent service, MCP server, event backbone |
| Team | Saru (lead) + optional mentee; Claude Code as pair programmer | Delivery Window | 22 weeks (including 1 buffer week) |
| Learning Goal | Agentic AI, polyglot microservices, distributed systems, then AWS | Technical Reviewer | [TBD] / Review Date [TBD] |

**Conventions.** "Must" denotes a requirement verified at an exit gate; "should" denotes a target that may be cut under Section 11.2. Local performance targets are laptop-scale learning targets; cloud capacity figures (Section 8.3) apply only from Phase 6. Items marked [TBD] need a decision before the phase that depends on them.

---

## 1. Problem Statement & Product Objective

E-commerce demand is skewed and bursty. Routine traffic may sit around 10,000 users per hour, while promotions and flash drops multiply load and concentrate contention on a single SKU within seconds. Tightly coupled synchronous systems either over-provision all year or suffer cascading timeouts, oversold inventory and duplicate charges when a surge arrives.

This PRD specifies a polyglot e-commerce platform supporting catalog browsing, carts, checkout, order history and notifications, plus admin catalog and order operations. It adds an **agentic AI layer**: agents that use the platform's own services as tools to help shoppers find products, explain order status, and help administrators with catalog work, always behind guardrails and human approval for any write. The system is first built and verified locally, then deployed to AWS. Evidence is produced for security by default (FA1), architectural and economic ownership (FA2), observability (FA3) and AWS Well-Architected capability (Section 3 of the IDP).

### 1.1 Success Metrics

| Metric | Target | Measured By |
|---|---|---|
| Oversell under concurrency load | 0 (stock never negative; confirmed orders ≤ available units) | Oversell test reports; inventory reconciliation query |
| Lost orders | 0 accepted orders without a terminal state after 5 minutes | Saga reconciliation report across load and chaos tests |
| Duplicate charges | 0 across retry, replay and provider-timeout tests | Payment ledger reconciliation |
| Checkout completion | ≥ 99.5% of accepted orders reach CONFIRMED or clean FAILED | Order state counts during load tests |
| Agent task success | ≥ 85% on the shopping-assistant eval set (≥ 50 labelled tasks); ≥ 90% correct tool selection | Agent eval harness (Section 7.4) |
| Agent safety | 0 unconfirmed write actions; 0 cross-user data disclosures in red-team set | Guardrail test suite; audit log |
| Agent cost | Cost per 100 agent conversations within budget [TBD $] | Token usage metrics per agent and model |
| Infrastructure cost (Phase 6) | Within the ADR-001 ceiling [TBD $/month] | AWS cost dashboard tagged by service and environment |
| Mentee independence (if assigned) | Mentee deploys, debugs and rolls back Notification alone | Recorded solo deployment and trace walkthrough |

---

## 2. Scope

### 2.1 In Scope

- **Commerce.** Sign-in and profile/addresses; catalog browse and keyword search with an advisory stock badge; admin catalog and image CRUD; guest browsing with anonymous cart merged at sign-in; authenticated checkout through an asynchronous saga with compensation; order status and history; event-driven email notifications; admin order inspection with an audit log.
- **Agentic AI.** Agent service with three agents (shopping assistant, order-support agent, admin catalog agent); an MCP server exposing platform capabilities as tools; semantic product search as an agent tool; offline evaluation, guardrails, human-in-the-loop approval for writes, token/cost tracking and automatic fallback when the model is unavailable.
- **Transport and contracts.** gRPC with versioned Protobuf contracts (Buf) between services; REST/JSON at the gateway; RabbitMQ with a dead-letter queue per consumer queue locally.
- **Resilience, security, observability.** Deadlines, retry budgets, circuit breakers, bulkheads; TLS on internal gRPC; OpenTelemetry tracing across sync, async and agent hops; RED metrics, dashboards and SLO alerts; STRIDE threat models including prompt injection; supply-chain scanning.
- **Cloud (Phase 6).** Terraform modules, AWS deployment of the verified system, cloud load and chaos tests, restore drill, Well-Architected review, cost dashboard with unit cost per 1,000 orders and per 100 agent conversations.

### 2.2 Out of Scope

- **Money movement.** Real settlement (controllable stub only), stored card data, customer refunds, post-confirmation cancellation. Agents never initiate payments.
- **Fulfillment.** Shipping, carrier tracking, warehouse workflows; orders end at CONFIRMED.
- **Commerce extensions.** Guest checkout, multi-currency (single currency, integer minor units), tax/VAT engines.
- **Platform extensions.** Mobile BFF, Kubernetes locally, multi-region, custom model training or fine-tuning, fully autonomous agents that act without human confirmation.

### 2.3 Assumptions & Constraints

- The whole system must start with one command (`docker compose up`) on a developer laptop with 16 GB RAM; services that are not needed for a task can be started with Compose profiles.
- Team capacity is the binding constraint. Code is written primarily through Claude Code; the lead reviews and must be able to explain every merged change.
- The payment stub can approve, decline, time out or return 5xx on demand so every failure path is testable.
- Agents call a hosted LLM API (provider and model decided in ADR-009); an API key with a hard monthly spending limit is set before Phase 2. Local tests can swap in a recorded-response or small local model to avoid cost.
- AWS account, Amazon SES production access and the certification exam are arranged during Phase 5 so they are ready for Phase 6.

---

## 3. Actors & Core User Journeys

### 3.1 Actors

| Actor | Capabilities | Authorization |
|---|---|---|
| Shopper — guest | Browse, search, anonymous cart, ask the shopping assistant product questions | Public routes; signed anonymous cart token; agent limited to public catalog tools |
| Shopper — authenticated | Guest capabilities plus checkout, order status/history, profile, notifications, order-support agent | Keycloak user (Cognito in Phase 6); access to own resources only, including through agents |
| Store Administrator | SKU and price CRUD, images, stock adjustment, order and saga inspection, admin catalog agent | Admin role; every mutation audited; agent-proposed writes need explicit approval |
| AI agents (system actor) | Call platform tools on behalf of a user | Act with the calling user's token and scopes only; never elevated privileges |
| Lead Architect (Saru) | Boundaries, ADRs, threat models, dashboards, cost model, agent evals | Engineering role |
| Mentee Engineer (optional) | Owns Notification end to end | Engineering role |

### 3.2 Core Journeys & Edge Cases

| Journey | Happy Path | Edge Cases the System Must Handle |
|---|---|---|
| J1 Browse & cart | Browse and search, view SKU and stock badge, add/update/remove cart items; anonymous cart merges at sign-in. | Protected routes without a valid token return 401 at the gateway. Unknown SKUs and invalid quantities return structured INVALID_ARGUMENT/NOT_FOUND. Merge sums quantities and caps at per-SKU limits. |
| J2 Checkout | Submit checkout, receive 202 with order ID; stock reserved, payment authorized, stock committed, payment captured, confirmation sent; status shows CONFIRMED. | Double-submit returns the same order (idempotency key). Price changed since add-to-cart: order uses the authoritative price snapshot. |
| J3 Payment failure | — | Decline, provider timeout or outage triggers compensation: stock released, authorization voided, order FAILED, shopper notified, cart preserved. No stranded reservations, no charge. |
| J4 Flash sale | Shopper is admitted under admission control and checks out a hot SKU. | Concurrent buyers never oversell; sold-out fails fast; per-customer limits enforced server-side; overload returns 429 with Retry-After. |
| J5 Admin operations | Admin edits a SKU, uploads an image via presigned URL, changes a price; new price visible within cache TTL. | Non-admins get 403. Every mutation is audited. Oversized or wrong-type uploads rejected by the presigned policy. |
| J6 Upstream degradation | — | Payment provider down: circuit opens, orders compensate quickly. Payment workers down: checkout still acknowledges, backlog alert fires, backlog drains on recovery with zero lost or duplicate charges. |
| J7 Shopping assistant | Shopper asks "waterproof running shoes under 80, size 42"; agent calls search and SKU tools, returns grounded suggestions with links; on request, adds an item to the cart after the shopper confirms. | Agent only recommends SKUs returned by tools (no invented products or prices). Out-of-stock items flagged. Cart writes require an explicit confirm step. LLM timeout or outage falls back to keyword search results with no user-visible error. |
| J8 Order support | Signed-in shopper asks "where is my order?"; agent reads order status and saga history and explains it in plain language. | Agent can only read the caller's own orders. It never promises refunds or cancellations (out of scope); it hands off with a support reference. Prompt-injection text in product data or messages cannot change its tools or scope. |
| J9 Admin catalog agent | Admin asks the agent to draft descriptions for 10 new SKUs or summarize low-stock items; agent proposes changes as a reviewable diff. | No change is applied without admin approval in the UI; approved changes go through the normal Catalog API and appear in the audit log with the agent recorded as proposer and the admin as approver. |

---

## 4. System Architecture & Service Boundaries

The system has a gateway and one Web BFF, seven domain services that each own their data (database-per-service), an Agent service with an MCP server, and an asynchronous backbone: RabbitMQ exchanges with one queue per consumer and a dead-letter queue per queue. Every service that publishes events does so through a transactional outbox. Locally, each service runs as one container; the same images deploy to ECS in Phase 6.

```
[Web client (TS)]
   | HTTPS / REST (JSON)
   v
[Traefik gateway + Keycloak JWT check]      (AWS: CloudFront + WAF + API Gateway + Cognito)
   v
[Web BFF (TS) incl. /admin and /assistant routes]
   | gRPC over TLS, relayed JWT, traceparent, x-correlation-id, deadline
   +----------+----------+---- --------+-----------------------------+
   v          v          v             v                             v
1.Identity  2.Catalog  3.Cart    4.Order (Java)        8.Agent service (Python)
   (Go)       (Go)      (Go)      saga orchestrator      shopping / order-support / admin agents
                           ^            |                v
                           +----------+------------+ [MCP server] --gRPC--> Catalog, Cart,
                             read-only SKU/price                  Order (read), Inventory (read)
                             reads
   [Outbox relay] in Order, Inventory, Payment
   v
[RabbitMQ topic exchange] --> [queue per consumer + DLQ each]    (AWS: EventBridge + SQS)
   |                |                |
   v                v                v
5.Inventory (Go) 6.Payment (Java)  7.Notification (TS) --> Mailpit (AWS: SES)
   Postgres+Redis   Postgres + stub  Postgres
```

**Languages.** Four languages: Go for low-overhead RPC and high-concurrency state, Java (Spring Boot) for transactional saga and payment logic, TypeScript for the BFF and async I/O, Python for the Agent service and MCP server (where agent frameworks and SDKs are most mature). Every added language adds a toolchain, OpenTelemetry and gRPC interceptor set; Rust for Inventory stays a Could-tier stretch.

| # | Service | Stack | Owned Data (local) | Responsibilities | Acceptance Criteria |
|---|---|---|---|---|---|
| — | Gateway & Web BFF | Traefik; Keycloak; TS BFF | Stateless | JWT validation, routing, rate limits, API composition, deadline budget, trace start, admin and assistant routes. | Invalid JWTs fail at the gateway; one correlation ID spans all hops. |
| 1 | Identity | Go + Keycloak | Postgres | Profile, addresses and roles alongside Keycloak; anonymous-cart merge trigger at sign-in. | Own-profile read/update works; cross-user access returns PERMISSION_DENIED. |
| 2 | Catalog | Go | Postgres + Redis + MinIO | Listings, keyword search, pricing, admin CRUD, presigned uploads, stock-badge projection, cached SKU/price API; publishes PriceChanged. | Browse and SKU lookup end to end; uploads never proxy binaries. |
| 3 | Cart | Go | Postgres (or DynamoDB Local) | User and anonymous carts, merge, TTL on abandoned carts, SKU validation via Catalog. | Add/update/remove/fetch persist; merge caps at per-SKU limits. |
| 4 | Order | Java (Spring Boot) | Postgres | CreateOrder with idempotency key and price snapshot; saga orchestrator; outbox; expiry sweeper; history read model. | Orders reach CONFIRMED or FAILED per Section 6.3. |
| 5 | Inventory | Go | Postgres + Redis | Stock, TTL soft reservations, commit/release, per-customer limits, optional Redis gate; outbox. | Concurrent reservations never drive stock below zero. |
| 6 | Payment | Java (Spring Boot) | Postgres | Anti-corruption layer over provider stub; authorize, capture, void; idempotency; append-only ledger; outbox. | Same key never charges twice; simulated failures are deterministic. |
| 7 | Notification | TypeScript (Node.js) | Postgres | Idempotent consumer of order events; email via Mailpit locally; DLQ handling. | Redelivered events send no duplicates; poison messages land in the DLQ. |
| 8 | Agent service + MCP server | Python | Postgres + pgvector | Agent loops for J7–J9; MCP server exposing scoped tools; semantic search embeddings; conversation state; evals; token metering; model fallback. | Eval targets met (Section 1.1); writes only after confirmation; model outage falls back cleanly. |

### 4.1 Synchronous Communication Matrix

A request may make at most two sequential hops after the BFF, and the second may only be a read-only call to a cached snapshot API. Inventory, Payment and Notification are never called synchronously for writes. Agent tool calls follow the same rules as the BFF. Any call not listed is prohibited and rejected in code review.

| Caller | Callee & RPCs | Purpose | Deadline / Retry | Fallback |
|---|---|---|---|---|
| Web BFF | Identity, Catalog, Cart, Order (CreateOrder, GetOrder, ListOrders), Agent | API composition | From BFF budget; reads retry once; CreateOrder retries only with same idempotency key | Partial response or 503 with Retry-After |
| Cart | Catalog.BatchGetSkus (cached) | Validate SKU and display price | 100 ms; 1 retry | Accept with last-known price flagged unverified |
| Order | Catalog.BatchGetSkus (cached) | Authoritative price snapshot | 150 ms; 1 retry | Fail closed: 503 retryable |
| Order | Cart.GetCheckoutSnapshot | Read cart lines at CreateOrder | 100 ms; 1 retry | Fail closed: 503 retryable |
| Web BFF | Agent.Chat (streaming) | Assistant conversations | First token ≤ 3 s; total 30 s; no retry | Keyword search results or "assistant unavailable" notice |
| MCP server | Catalog (search, GetSku), Cart (Get, Add after confirm), Order (GetOrder, ListOrders), Inventory (read-only GetAvailability) | Agent tools | Per-tool 300–500 ms; reads retry once | Tool returns structured error the agent must report, never invent around |
| Payment (egress) | Provider stub | Authorize, capture, void, status | 2 s; idempotent calls only, with key | Circuit opens; saga treats as payment failure |

---

## 5. Environments: Local-First, Then AWS

### 5.1 Local Development Environment (Phases 0–5)

- Monorepo: `/proto` (Buf), `/services/<name>`, `/agent`, `/infra/compose`, `/infra/terraform` (Phase 6), `/docs/adr`, `/docs/threat-models`, `/tests/load`, `CLAUDE.md`.
- One Postgres container with a database and credentials per service (database-per-service by grants), mirroring the ADR-006 non-prod layout.
- Compose profiles: `core` (gateway, BFF, Identity, Catalog, Cart), `checkout` (Order, Inventory, Payment, RabbitMQ), `async` (Notification, Mailpit), `agent`, `observability` (OTel Collector, Jaeger, Prometheus, Grafana).
- Secrets in a git-ignored `.env` with a committed `.env.example`; no secret ever in code, logs, prompts or CLAUDE.md.

### 5.2 Phase 6 AWS Target

Single region, three Availability Zones, ECS Fargate, environments dev / staging / prod-demo per ADR-006. All infrastructure in Terraform modules; no console changes in staging or prod. CI/CD via GitHub Actions with OIDC federation and no long-lived keys.

### 5.3 Local → AWS Component Mapping

| Concern | Local (Phases 0–5) | AWS (Phase 6) | Migration notes |
|---|---|---|---|
| Edge & gateway | Traefik | CloudFront + AWS WAF + API Gateway HTTP API + internal ALB | Rate and bot rules re-tuned for cloud load tests |
| Identity | Keycloak | Amazon Cognito | Services validate JWTs against JWKS, so only issuer config changes |
| Relational data | Postgres container | RDS PostgreSQL via RDS Proxy (Multi-AZ in prod) | Same schemas and migrations |
| Cache | Redis container | ElastiCache for Redis | Disposable; rebuilt from Postgres |
| Object storage | MinIO | S3 (versioned) | Presigned URL code uses the S3 API in both |
| Events | RabbitMQ (topic exchange, queue per consumer, DLX) | EventBridge + SQS (FIFO for saga) + DLQ per queue | Publish/consume behind a thin messaging interface per language so the swap is an adapter change (ADR-010) |
| Email | Mailpit | Amazon SES | Request SES production access in Phase 5 |
| Vector store | Postgres + pgvector | RDS PostgreSQL + pgvector | Same extension |
| Feature flags | Flag file / env reload | AWS AppConfig | Flag interface wraps both |
| Tracing & metrics | OTel Collector, Jaeger, Prometheus, Grafana | OTel → X-Ray or Grafana Cloud; CloudWatch | Instrumentation unchanged; only exporter config |
| L7 gRPC balancing | Single instance per service | ECS Service Connect or internal ALB gRPC target groups (ADR-005) | Must be in place before any cloud load test |
| Secrets | .env file | AWS Secrets Manager with rotation | Loaded via the same config interface |

---

## 6. Functional Requirements & Contracts

| ID | Ph. | Capability | Specification | Acceptance Criteria |
|---|---|---|---|---|
| FR-01 | 1 | Authentication & token relay | Keycloak sign-in; gateway verifies JWT; BFF relays the token in gRPC metadata; services validate locally against cached JWKS and authorize on subject and roles. Bare identity headers never trusted. | Missing/forged/expired tokens get 401; valid token on another user's resource gets PERMISSION_DENIED. |
| FR-02 | 1 | Catalog browse & admin upload | Paginated browse and SKU detail via Redis cache-aside; admins create/edit SKUs and upload images via presigned MinIO/S3 PUT (5-min expiry, type and size constrained). | Cache-hit p95 ≤ 25 ms locally; uploads never transit app servers; non-admin upload gets 403. |
| FR-03 | 1 | Cart operations | Add, update, remove, get; anonymous cart via signed token, merged at sign-in; SKU validation via Catalog.BatchGetSkus. | Browse → add-to-cart integration test passes; merge test passes; unknown SKU rejected. |
| FR-04 | 1 | BFF composition | BFF composes gRPC responses, sets deadline budget, propagates W3C trace; x-correlation-id equals trace ID. | Every log line for a request carries one correlation ID across sync and async hops. |
| FR-05 | 3 | Checkout idempotency | CreateOrder requires an Idempotency-Key, retained 24 h. | Double submit creates exactly one order. |
| FR-06 | 3 | Checkout saga & compensation | As in Sections 6.2–6.4, with outbox publishing in Order, Inventory, Payment. | Happy path reaches CONFIRMED; decline, outage and commit failure reach FAILED with stock released, no net charge. |
| FR-07 | 3 | Inventory anti-oversell | Optimistic-concurrency reservations with TTL, per-customer limits, idempotent commit/release. | 100 concurrent checkouts for 5 units → exactly 5 CONFIRMED; 1,000 → 50 variant in Phase 5, zero oversell. |
| FR-08 | 3 | Payment idempotency | ACL over stub; key scoped to order_id + operation; append-only ledger; status query on unknown outcome. | Three replays → one ledger entry; provider-timeout case never double-charges. |
| FR-09 | 4 | Async notifications | Competing consumers deduplicated by event_id; DLQ after 5 deliveries. | Duplicates send at most one email; malformed messages land in the DLQ and alert. |
| FR-10 | 4 | Order status | GET /orders/{id} returns state and failure-reason category; documented polling backoff. | Terminal state within async completion target. |
| FR-11 | 4 | Admin order view & audit | Admins filter orders, view saga history and DLQ status; admin mutations write to an append-only audit log (actor, proposer, action, before/after, time). | Every admin and agent-proposed change appears in the audit log; non-admins get 403. |
| FR-12 | 1 | Stock badge | Advisory in stock / low / sold out from an Inventory-fed projection; never used by checkout. | Reflects a stock change within 10 s. |
| FR-13 | 5 | CQRS order history | Read model updated from order events; history queries use only the read model. | History reads never touch checkout write tables. |

### 6.1 Contract Discipline

- **gRPC.** All RPCs in one versioned Protobuf repo; Buf lint and breaking-change checks in CI; generated stubs per language; grpc.health.v1 on every service; message validation (protovalidate) before business logic; reflection off outside dev; mandatory deadlines; shared error model mapping domain errors to gRPC status codes.
- **Events.** Protobuf-defined, JSON-serialized; additive changes only within a major version (order.created.v2 for breaking changes); envelope with event_id, event_type, schema_version, occurred_at, producer, aggregate_id, aggregate_version, correlation_id, traceparent.
- **Delivery.** At-least-once; every consumer deduplicates on event_id and ignores stale aggregate_version. Saga command and reply queues preserve per-order ordering (single-active-consumer or consistent-hash routing on order_id in RabbitMQ; SQS FIFO with MessageGroupId = order_id on AWS).
- **Outbox and DLQs.** Order, Inventory and Payment write events in the same transaction as state changes; a polling relay publishes them (CDC evaluated in ADR-007). Every queue has a DLQ (5 deliveries); a replay tool and runbook exist before Phase 4 exits.
- **Agent tools.** MCP tool schemas are generated from or validated against the Protobuf contracts so a breaking RPC change fails the agent contract test in CI.

### 6.2 Checkout Sequence

- Client submits checkout with an Idempotency-Key; BFF calls Order.CreateOrder(cart_id, key); a repeated key returns the original order.
- Order reads the cart snapshot and Catalog prices in parallel, writes the order (CREATED, price snapshot in minor units) and a ReserveStock command to the outbox in one transaction, and returns 202 with order ID and status URL.
- Inventory reserves with an optimistic version check and per-customer limit, replying StockReserved or StockRejected.
- On StockReserved, Order sends AuthorizePayment; Payment replies PaymentAuthorized or PaymentFailed.
- On PaymentAuthorized, Order sends CommitStock; on StockCommitted it sends CapturePayment, moves to CONFIRMED and publishes OrderConfirmed.
- Clients poll GET /orders/{id} with exponential backoff; email is sent on CONFIRMED or FAILED.

### 6.3 Order State Machine

| State | Entered When | Exits To | Step Timeout |
|---|---|---|---|
| CREATED | Order and ReserveStock command committed | STOCK_RESERVED, FAILED | 30 s → FAILED |
| STOCK_RESERVED | StockReserved received | PAYMENT_AUTHORIZED, COMPENSATING | 60 s → COMPENSATING |
| PAYMENT_AUTHORIZED | PaymentAuthorized received | CONFIRMED, COMPENSATING | 30 s → COMPENSATING |
| CONFIRMED (terminal) | StockCommitted received; capture requested | — | Capture retried until success; failures alert; stock never reverted |
| COMPENSATING | Any failure or timeout after stock reserved | FAILED | Compensations retried with backoff until acknowledged |
| FAILED (terminal) | Rejection, or all compensations acknowledged | — | Shopper notified with a reason category |

An expiry sweeper advances orders past their step timeout. Order deadline is 5 minutes; reservation TTL is 10 minutes. If CommitStock finds the reservation gone, Inventory replies StockCommitFailed and Order voids the authorization.

### 6.4 Failure Modes & Expected Outcomes

| Failure | Mechanism | Expected Outcome |
|---|---|---|
| DB commit vs. event loss | Transactional outbox | State and event commit atomically; relay publishes after a crash. |
| Duplicate events or retries | Idempotency keys; idempotent consumers; version checks | At-least-once delivery is side-effect safe. |
| Double checkout submit | CreateOrder idempotency key | One order; second call returns the first order. |
| Stock unavailable | Optimistic concurrency; per-customer limits | StockRejected → FAILED (sold out); nothing to compensate. |
| Payment declined / provider down | Compensation; egress circuit breaker | ReleaseStock; FAILED; shopper notified; cart preserved. |
| Commit fails after authorization | Compensation | VoidPayment, then ReleaseStock if needed; FAILED; no charge. |
| Capture fails after commit | Retry with backoff; alert after 3 failures | Stays CONFIRMED; operator investigates. |
| Provider outcome unknown | Status query by key; reconciliation job | Resolved to authorized or failed; never double-charged. |
| Saga participant down | Durable queues; step timeouts; queue-age alert | Checkout still acknowledges; backlog drains or orders compensate. |
| Poison message | DLQ after 5 deliveries | Isolated without blocking; alert; replay via runbook. |
| LLM provider slow or down | Agent deadline; model fallback chain; circuit breaker | Keyword search or "assistant unavailable"; commerce flows unaffected. |
| Agent hallucinates a product or price | Grounding check: every SKU and price in a reply must come from a tool result in the same turn | Ungrounded items stripped before display; eval regression fails CI. |
| Prompt injection (product text, user message) | Tool allow-list per agent; user-scoped tokens; untrusted-content tagging; confirmation for writes | Injected instructions cannot add tools, widen scope or trigger writes. |
| Agent loop runaway | Max steps (8) and max tokens per conversation | Conversation ends with a clean summary; metric and alert on limit hits. |

---

## 7. Agentic AI Requirements

The Agent service is built incrementally so each step teaches one agentic concept: tool calling (Phase 2), retrieval and multi-step planning (Phase 4), human-in-the-loop and multi-agent routing (Phase 4), evaluation and observability throughout.

### 7.1 Agents

| Agent | Phase | Tools (via MCP) | Autonomy Level | Concepts Learned |
|---|---|---|---|---|
| Shopping assistant | 2 (basic), 4 (extended) | catalog.search, catalog.semantic_search, catalog.get_sku, inventory.get_availability, cart.get, cart.add_item (confirm) | Read freely; cart writes only after shopper confirms | Tool calling, grounding, structured outputs, streaming, fallback |
| Order-support agent | 4 | order.get, order.list (own orders), order.get_saga_history, notification.get_status | Read-only; escalates with a support reference | User-scoped authorization, explaining system state, handoff |
| Admin catalog agent | 4 | catalog.list_low_stock, catalog.get_sku, catalog.propose_update (creates a draft, never applies) | Proposes; admin approves in UI | Human-in-the-loop, audit, batch tasks, planning |
| Router (optional) | 4 | Delegates to the agents above | No tools of its own | Multi-agent orchestration |

### 7.2 Agent Requirements

| ID | Ph. | Requirement | Acceptance Criteria |
|---|---|---|---|
| AG-01 | 2 | Agent service exposes Chat (streaming) over gRPC; BFF exposes it as /assistant (server-sent events). | First token ≤ 3 s p95 locally; conversation persists across page reloads. |
| AG-02 | 2 | MCP server exposes only Catalog and Inventory tools generated from Protobuf contracts; tools carry the caller's JWT. | MCP inspector lists tools; a guest token cannot reach authenticated tools. |
| AG-03 | 2 | Basic shopping assistant answers product questions using only tool results. | ≥ 85% task success on ≥ 50 labelled tasks; 0 ungrounded SKUs or prices in eval output. |
| AG-04 | 2 | Fallback: model timeout, outage or flag-off returns keyword search results. | Chaos test with LLM endpoint blocked shows no user-visible error. |
| AG-05 | 4 | Semantic search tool over catalog embeddings (pgvector); embeddings refreshed on PriceChanged / SKU events. | Beats keyword baseline on nDCG@10 by agreed margin [TBD] on ≥ 100 labelled queries. |
| AG-06 | 4 | Confirmation protocol: any write tool returns a pending action the UI must confirm; confirmed actions execute through normal APIs. | Write without confirmation impossible in tests; every executed action audited with proposer and approver. |
| AG-07 | 4 | Order-support and admin catalog agents per Section 7.1. | Cross-user access attempts return PERMISSION_DENIED and are refused politely by the agent. |
| AG-08 | 2–5 | Guardrails: tool allow-list per agent, max 8 steps, token budget per conversation, PII redaction in logs and traces, untrusted-content tagging for tool results. | Red-team set (≥ 30 injection and jailbreak prompts) passes with 0 policy violations. |
| AG-09 | 2–5 | Agent observability: every LLM call and tool call is an OTel span with model, tokens, latency, cost, tool name and outcome. | One trace shows browser → BFF → agent → MCP → Catalog for a single question. |
| AG-10 | 6 | Cost governance: token cost per agent on the cost dashboard; hard monthly spending limit on the API key. | Cost per 100 conversations reported for each load profile. |

### 7.3 Agent Security (extends STRIDE)

- Threat model for the Agent service covers prompt injection (direct and via product data), tool misuse, data exfiltration through responses, excessive agency, denial of wallet (token cost attacks) and model supply chain.
- Agents never hold service credentials of their own; they forward the end user's token, so authorization is enforced by the same service checks as the UI.
- System prompts and tool definitions are versioned in git; changes go through review and must pass the eval suite.

### 7.4 Agent Evaluation

- Eval harness in `/agent/evals`: labelled tasks with expected tool calls and answer checks; runs in CI on every prompt, tool or model change against a seeded catalog.
- Metrics: task success, tool-selection accuracy, grounding violations, steps per task, latency, tokens and cost per task.
- Regression rule: a change that lowers task success by more than 3 points or introduces any grounding or safety violation blocks merge.

---

## 8. Non-Functional Requirements

### 8.1 Local Targets (Phases 1–5)

| Area | Target | How Verified |
|---|---|---|
| Startup | Full stack healthy within 3 minutes of docker compose up | Compose health checks |
| Catalog read | p95 ≤ 25 ms cache hit; ≤ 80 ms miss (service-side) | k6 at 50 RPS on laptop |
| Checkout acknowledgement | p99 ≤ 800 ms to 202 | k6 checkout script |
| Async completion | p95 ≤ 5 s; 100% terminal within 5 min | Order state timestamps |
| Oversell | 100 → 5 (Phase 3), 1,000 → 50 (Phase 5): zero oversell | Concurrency test + reconciliation query |
| Queue health | 0 DLQ messages in happy path; alert on DLQ ≥ 1 | RabbitMQ metrics in Grafana |
| Agent | First token ≤ 3 s p95; tool call p95 ≤ 500 ms | OTel spans |

### 8.2 Resilience, Security and Observability

- **Resilience.** Deadline budget set at the BFF (checkout 700 ms, reads 400 ms) and propagated; retries at exactly one layer with full jitter and a 20% retry budget; circuit breakers on Payment egress and the LLM client; separate pools per downstream (bulkheads). Envoy sidecars are optional locally and decided for AWS in ADR-003.
- **Security (FA1).** STRIDE per service, the edge and the Agent service; TLS on internal gRPC; least-privilege DB users per service; PII never logged (redaction middleware + CI test); SAST, dependency, image and IaC scanning with SBOMs; PR security checklist from PR #1; retroactive security review of Cart in Phase 5.
- **Observability (FA3).** OpenTelemetry across gRPC, events (traceparent in envelope) and agent calls; RED metrics per RPC; saga state counts, compensations, stuck orders, queue depth/age, outbox lag, circuit state, cache hit ratio, token usage. Dashboards: Checkout Health, Async Backbone, Agent Quality & Cost, Burst Readiness (Phase 6), Cost (Phase 6). Every alert links to a runbook.

### 8.3 Cloud Capacity Model & SLOs (Phase 6)

Phase 6 sizing basis: ~10,000 sessions/hour (60 RPS design peak at the edge, ~26 origin RPS, ~90 internal gRPC RPS, ~0.1 orders/s), seasonal 5–10× over hours, and flash spikes up to 50× (≤ 3,000 edge RPS) for ≤ 5 minutes. SLOs: catalog availability 99.9%; catalog CDN-miss p95 ≤ 80 ms; checkout acknowledgement p99 ≤ 800 ms; checkout availability 99.5% (shedding reported separately); async completion p95 ≤ 5 s baseline, ≤ 30 s flash; payment non-decline errors < 0.5%; DLQ = 0. Burst rules for Phase 6: L7 balancing on every gRPC edge, bounded synchronous depth, CDN + Redis before compute, admission control for flash sales (ADR-008), per-customer limits, scheduled pre-scaling, RDS Proxy, WAF rate rules. Agent traffic is rate-limited per user and excluded from flash-sale admission so it cannot compete with checkout.

### 8.4 Data Durability (Phase 6)

RDS Multi-AZ in prod with 7-day PITR (RPO ≤ 5 min, RTO ≤ 4 h); S3 versioning (RPO 0); ElastiCache disposable. Locally, a `make reset` target rebuilds all data from migrations and seed scripts.

---

## 9. Verification Strategy

| Layer | Scope | Phase |
|---|---|---|
| Unit & component | Domain logic, state machine, idempotency, agent tool wrappers | 1+ |
| Contract | Buf breaking checks; event schema compatibility; MCP tool schema vs. Protobuf | 0+ |
| Integration | docker compose test profile: browse → cart → checkout → email; assistant question end to end | 1+ |
| Agent evals | Task success, tool accuracy, grounding, red-team set | 2+ |
| Concurrency | Oversell: 100 → 5 (Phase 3); 1,000 → 50 (Phase 5) | 3, 5 |
| Local load (k6) | Baseline 50 RPS for 15 min; checkout burst at laptop scale | 5 |
| Local chaos | A: provider stub 5xx → circuit opens, orders compensate. B: Payment container killed → backlog drains, no lost or duplicate charges. C: LLM endpoint blocked → fallback. | 5 |
| Cloud load | Baseline 60 RPS 30 min; seasonal ramp to 600 RPS; flash 0 → 3,000 RPS in 60 s; 8 h soak | 6 |
| Cloud chaos & recovery | AZ task loss, Redis node failure; restore Order from PITR and rebuild read model | 6 |
| Security | Per-RPC authorization, token tampering, oversized payloads, DLQ replay authorization, prompt injection | 1+ |

---

## 10. Build Method: Claude Code Workflow

- **CLAUDE.md** at the repo root records: architecture summary, service-language map, folder layout, commands (build, test, run), coding standards per language, the synchronous communication matrix, and the rule that Claude explains each change and never writes secrets. Each service folder may add its own CLAUDE.md.
- **Plan mode first.** Every task starts with a plan that the lead reviews before files are written.
- **Contract-first sessions.** Protobuf and event schemas are written and reviewed before service code; Claude Code generates stubs from them.
- **One service or one feature per session.** Small scope keeps context focused and diffs reviewable.
- **Green tests before commit.** Each session ends with tests passing and a commit; the lead must be able to explain the diff.
- **Learning loop.** After each milestone, the lead writes a short note in `/docs/learning` explaining what was built and why, which also feeds the 52-pattern index.

---

## 11. Delivery Plan (22 Weeks)

| Phase & Weeks | Build Deliverables | Learning & IDP Focus | Exit Gate |
|---|---|---|---|
| Phase 0 — Foundations (W1-2) | Repo and CLAUDE.md; Compose skeleton (Postgres, Redis, Traefik, Keycloak); proto repo with Buf; CI with lint, tests, security scans; ADR-000, 001, 006, 009 drafts. | Agent concepts course; Docker; gRPC basics. FA2 ownership. | docker compose up brings infra healthy; CI green on an empty service; STRIDE template agreed. |
| Phase 1 — Core browse path (W3-5) | Catalog (cache-aside, presigned uploads, stock badge), Cart (anonymous + merge), Identity profile, Web BFF, Keycloak auth, TLS, health checks. | API Gateway, BFF, Database per Service, Cache-Aside, Token Relay. FA1 checklist from PR #1. | Authenticated browse → add-to-cart through the BFF; STRIDE for Identity, Catalog, Cart, edge. |
| Phase 2 — First agent (W6-7) | Agent service (Python), MCP server with read-only Catalog/Inventory tools, basic shopping assistant, /assistant route, first eval harness, fallback. | Tool calling, MCP, grounding, evals. Courses: agent and MCP short courses. | AG-01 to AG-04 pass; one trace spans browser → agent → Catalog. |
| Phase 3 — Saga core (W8-10) | Order, Inventory, Payment stub, RabbitMQ with DLX, outbox relays, idempotency, state machine. | Saga, Outbox, Idempotency Key, Competing Consumer, Async Request-Reply. ADR-002 defended. | Happy path reaches CONFIRMED; 100 → 5 oversell test passes; decline compensates. |
| Phase 4 — Async edges + agentic depth (W11-14) | Notification + Mailpit; order status; admin order view and audit; DLQ replay tool; semantic search; confirmation protocol; order-support and admin catalog agents; red-team set. | Pub/Sub, Competing Consumers, DLQ; human-in-the-loop, multi-agent routing, agent security. | AG-05 to AG-08 pass; provider outage compensates deterministically; mentee (if any) deploys Notification. |
| Phase 5 — Resilience & observability (W15-17) | Deadlines, retry budgets, circuit breakers, bulkheads; OTel, Jaeger, Prometheus, Grafana dashboards and alerts; CQRS read model; local load and chaos A/B/C; 1,000 → 50 test; Cart security review; AWS account and SES request. | Circuit Breaker, Retry, Timeout, Bulkhead, Distributed Tracing, RED + SLOs, CQRS. FA3. | Chaos A, B, C pass with dashboard-led retro; zero oversell; local targets in 8.1 met. |
| Phase 6 — AWS deployment (W18-21) | Terraform modules; messaging adapter swap to EventBridge/SQS; Cognito; ECS Fargate with L7 gRPC balancing; CloudFront/WAF/API Gateway; cloud load, flash, soak, chaos; restore drill; cost dashboard; Well-Architected review; admission control. | Section 3 WA review; FA2 economic review; certification exam. | Cloud SLOs met; flash spike shows zero oversell and lost orders; WA review shared (3+ areas, 1+ in sprint). |
| Week 22 — Buffer | Slip absorption, documentation, final demo. | All IDP evidence closed. | Section 13 checklist signed off. |

### 11.1 Schedule Risk Control

Phase 3 (saga) and Phase 6 (cloud migration) carry the most risk. If Phase 3 slips by more than one week, the cut line is applied before Phase 5 rather than compressing resilience work. Phase 6 may be split into a later quarter without invalidating Phases 0–5.

### 11.2 Scope Cut Line

| Priority | Items |
|---|---|
| Must | Phases 0–5 core paths; saga with compensation; anti-oversell; idempotency; shopping assistant with evals, grounding and fallback; confirmation protocol for agent writes; TLS; tracing; dashboards; local chaos A, B, C. |
| Should | Admin catalog agent; semantic search; CQRS read model (fallback: indexed queries); Phase 6 AWS deployment within this plan; admission control; soak test. |
| Could | Router agent; Rust Inventory; Redis stock gate if optimistic locking passes the 1,000 → 50 test; Envoy sidecars locally; push notifications. |
| Won't (this plan) | Mobile BFF; guest checkout; fulfillment; multi-currency; multi-region; refunds or cancellations; autonomous agent writes; model fine-tuning. |

---

## 12. Architecture Decisions & Open Risks

| ADR | Decision | Options | Due |
|---|---|---|---|
| 000 | Domain boundaries | Services as specified; Inventory in Catalog; Payment in Order | Phase 0 |
| 001 | Stack, transport, cost model | 4 vs 5 languages; gRPC vs REST internally; local resource budget; Phase 6 cost ceiling | Phase 0 |
| 002 | Saga: orchestration vs choreography | Orchestrated in Order; choreography; (Step Functions in Phase 6) | Phase 3 |
| 003 | Envoy scope | None locally; sidecar on Order; egress ambassador on Payment | Phase 5 |
| 004 | Flash-sale inventory locking | Postgres optimistic concurrency; Redis Lua gate; per-SKU serialized queue | Phase 3, revisited Phase 5 |
| 005 | Compute and L7 gRPC balancing (AWS) | ECS Fargate vs EKS; Service Connect vs internal ALB vs Envoy | Phase 5 |
| 006 | Data-store layout and accounts | Shared Postgres with per-service DBs vs instance per service; single vs multi-account | Phase 0 (local), Phase 5 (AWS) |
| 007 | Outbox relay | Polling vs Debezium CDC | Phase 5 |
| 008 | Flash-sale admission control | Waiting room vs BFF token bucket vs shedding only | Phase 6 |
| 009 | LLM provider, models and agent framework | Provider and model tiers; framework (direct SDK vs LangGraph vs other); MCP library; local fallback model | Phase 0 |
| 010 | Messaging abstraction | Thin adapter per language over RabbitMQ / EventBridge+SQS vs separate code paths | Phase 3 |
| 011 | Agent autonomy and confirmation protocol | Which actions may run without confirmation (proposed: reads only) | Phase 4 |

### 12.1 Open Risks

| Risk | Tension | Proposed Position |
|---|---|---|
| Learning load | Four languages, gRPC, sagas and agents at once | Phase order puts one new concept per phase; Claude Code handles boilerplate; lead must explain every diff. |
| Local resource limits | Many containers on one laptop | Compose profiles; JVM memory caps; run only the profiles a task needs. |
| Local-to-AWS drift | Local equivalents behave differently (RabbitMQ vs SQS FIFO, Keycloak vs Cognito) | Adapters behind interfaces (ADR-010); contract tests run against LocalStack before Phase 6. |
| Agent quality | LLM answers vary run to run | Eval suite in CI; grounding check; temperature and model pinned per agent. |
| Agent cost | Token spend can grow with traffic and attacks | Spending limit on key; per-user rate limits; token budgets; cost dashboard. |
| Over-reliance on AI-generated code | Working code the lead cannot debug | Small sessions, plan review, learning notes, and manual debugging exercises in Phase 5 chaos tests. |
| Schedule | 22 weeks for a learner-led build | Cut line; buffer week; Phase 6 movable to a later quarter. |

---

## 13. Acceptance & IDP P4 Evidence Sign-Off

| Done | Evidence Item | Phase | Artifact |
|---|---|---|---|
| ☐ | Service boundary map + ADR-000 | 0 | Diagram + signed ADR |
| ☐ | Stack, data-store, LLM ADRs with cost math (001, 006, 009) | 0 | Signed ADRs |
| ☐ | STRIDE threat model per service, edge and Agent service | 1–5 | Threat models in repo |
| ☐ | Unprompted security comments in 3+ PRs | 1–4 | PR review links |
| ☐ | Retroactive security review of Cart (2+ findings closed) | 5 | Audit report + tickets |
| ☐ | ADR-002 defended through pushback | 3 | ADR + review notes |
| ☐ | Agent eval report and red-team results | 2, 4 | Eval summaries in CI |
| ☐ | Dashboard or alert used in a retrospective | 5 | Chaos A/B/C retro |
| ☐ | Load test reports (local and cloud) with cost per 1,000 orders and per 100 conversations | 5–6 | Reports |
| ☐ | Zero oversell, lost orders, duplicate charges under flash spike | 6 | Reconciliation output |
| ☐ | Restore drill completed | 6 | Drill record with RTO |
| ☐ | Mentee solo deploy and rollback of Notification (if assigned) | 4–6 | Recording |
| ☐ | Well-Architected review; Skill Builder module; certification booked | 5–6 | WA report; course record; booking |
| ☐ | Design-pattern notes for all 52 topics, including agentic patterns | 1–6 | Pattern index |

### 13.1 Document Approval

| Role | Name | Decision | Date |
|---|---|---|---|
| Product & Tech Lead | Saru | Author | |
| Lead Engineer (Technical Reviewer) | [TBD] | ☐ Approved ☐ Approved with changes ☐ Rework | |
| Engineering Manager | [TBD] | ☐ Approved ☐ Approved with changes ☐ Rework | |
