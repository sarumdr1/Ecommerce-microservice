# Platform Explained — Plain Language Guide

> This file is a study companion for `docs/PRD.md` and `CLAUDE.md`.
> Read those for the full spec; read this when you want to understand *why*.

---

## What Are We Building?

An **online store** (think a mini Amazon). Customers can browse products, add to cart, and checkout.
Admins manage products. And there is an **AI assistant** baked in — to help customers find products
and check order status.

The twist: instead of one big app, it is split into **small, independent services** (microservices)
that talk to each other. This makes it resilient — if one part breaks, the rest keep running.

---

## Why Is It Built This Way?

Imagine a flash sale. 10,000 people hit "Buy" at the same second. A single monolithic app would
crash or oversell stock. This design handles that by:

- Each service scales independently
- Checkout uses a **saga** (a chain of steps with automatic undo if something fails)
- Inventory uses locks so stock never goes negative

---

## The Services — What Each One Does

Think of each service as a small app with its own database. They talk to each other via **gRPC**
(a fast, typed messaging protocol — like a phone call with a strict script).

| Service | Plain-English Job |
|---|---|
| **Gateway** | The front door. Checks your login token. Blocks bad requests. |
| **Web BFF** | The "waiter". Takes your browser request, calls the right services, assembles the response. |
| **Identity** | Handles user accounts, profiles, addresses. Works with Keycloak (a dedicated login server). |
| **Catalog** | The product database. Search, browse, images, prices. Admins edit things here. |
| **Cart** | Your shopping cart. Works even before you log in (anonymous cart merges when you sign in). |
| **Order** | The checkout brain. Runs the saga — coordinates stock reservation, payment, confirmation. |
| **Inventory** | Tracks how many units are left. Prevents overselling under heavy load. |
| **Payment** | Talks to the payment provider. Never charges twice (idempotent). |
| **Notification** | Sends emails (order confirmed, order failed). Uses Mailpit locally, Amazon SES in production. |
| **Agent + MCP** | The AI layer. Three AI agents powered by an LLM. Uses the other services as tools. |

---

## The Three AI Agents

| Agent | What It Does |
|---|---|
| **Shopping assistant** | Answers "find me waterproof shoes under $80 size 42". Searches catalog, checks stock, adds to cart — only after you confirm. |
| **Order support** | Answers "where is my order?". Reads your order history, explains what happened in plain language. Never promises refunds. |
| **Admin catalog agent** | Helps admins — drafts product descriptions, flags low stock. Proposes changes; admin must approve before anything is saved. |

**Key safety rule:** agents only act with *your* login token. They can never see another user's
data or do anything you did not approve first.

---

## The Tech Stack — Why These Languages?

The project uses 4 languages on purpose (to learn each one's strengths):

| Language | Used For | Why |
|---|---|---|
| **Go** | Identity, Catalog, Cart, Inventory | Fast, low memory, great for high-concurrency |
| **Java (Spring Boot)** | Order, Payment | Strong transaction support, good for sagas and financial logic |
| **TypeScript** | BFF, Notification | Natural for async I/O and web APIs |
| **Python** | Agent + MCP server | Best ecosystem for AI/LLM tooling |

---

## How Services Talk to Each Other

There are two ways services communicate:

### 1. Synchronous (Direct Call)
Like a phone call — you wait for the answer before continuing.

Used when you need an immediate response.

**Example:** Cart calls Catalog to check that a SKU exists before adding it.

**Hard rules:**
- At most 2 hops after the BFF
- Every call has a timeout
- Retries happen at only one layer (never retry in multiple places — it multiplies load)

### 2. Asynchronous (Events via RabbitMQ)
Like dropping a letter in a mailbox — you send it and move on; the receiver processes it later.

Used for things that can happen in the background.

**Example:** When an order is confirmed, Order publishes an event → Notification picks it up → sends email.

This means if Notification is down, no orders are lost — the event waits in the queue.

---

## What Is the Outbox Pattern?

**The problem:** when Order saves to its database AND sends an event to RabbitMQ, what if the
database save succeeds but the event send crashes? You have an order with no email sent.

**The solution (Outbox):** Order writes the event to a special `outbox` table in the *same database
transaction* as the order itself. A separate relay process reads that table and sends events to
RabbitMQ. If the relay crashes, it just re-reads and resends — the event was already safely saved.

```
Order service writes:
  [orders table]  ←— same transaction —→  [outbox table]
                                                ↓
                                        [Relay process]
                                                ↓
                                          [RabbitMQ]
                                                ↓
                                      [Notification service]
```

---

## The Checkout Flow (The Saga)

This is the most complex part. Here is what happens when you click "Buy":

```
Step 1: You submit checkout
        → Order service creates the order (status: CREATED)
        → Writes a "ReserveStock" command to its outbox

Step 2: Inventory receives ReserveStock
        → Reserves 1 unit with a time limit (TTL)
        → Replies: StockReserved (or StockRejected if sold out)

Step 3: Order receives StockReserved
        → Sends "AuthorizePayment" to Payment

Step 4: Payment authorizes with the provider
        → Replies: PaymentAuthorized (or PaymentFailed)

Step 5: Order receives PaymentAuthorized
        → Sends "CommitStock" to Inventory

Step 6: Inventory commits the reservation permanently
        → Replies: StockCommitted

Step 7: Order sends "CapturePayment" to Payment
        → Moves to status: CONFIRMED
        → Publishes OrderConfirmed event → email sent
```

### What If Something Goes Wrong?

The saga automatically compensates (undoes steps):

| What Fails | What Happens |
|---|---|
| Stock unavailable | StockRejected → order goes straight to FAILED, nothing to undo |
| Payment declined | ReleaseStock → FAILED → email sent, cart preserved |
| Provider times out | Same compensation flow as decline |
| Commit fails after auth | VoidPayment → ReleaseStock → FAILED, no charge |

**Key guarantee:** you are never charged without stock being committed, and stock is never
committed without payment succeeding.

---

## The Order State Machine

An order moves through these states:

```
CREATED
   ↓ (stock reserved)
STOCK_RESERVED
   ↓ (payment authorized)
PAYMENT_AUTHORIZED
   ↓ (stock committed + payment captured)
CONFIRMED  ← terminal, happy path

— OR —

Any failure after CREATED →
COMPENSATING
   ↓ (all compensations done)
FAILED  ← terminal, unhappy path
```

Each state has a timeout. If the timeout expires, the order moves to COMPENSATING automatically
(an "expiry sweeper" process handles this).

---

## The 6 Delivery Phases (22 Weeks)

| Phase | Weeks | What Gets Built | Key Learning |
|---|---|---|---|
| **0 — Foundations** | 1–2 | Repo, Docker Compose, Protobuf repo, CI, first ADRs | Docker, gRPC basics |
| **1 — Browse** | 3–5 | Catalog, Cart, Identity, BFF, login, TLS | API Gateway, BFF pattern, caching |
| **2 — First AI Agent** | 6–7 | Agent service, MCP server, shopping assistant, eval harness | Tool calling, grounding, fallback |
| **3 — Checkout** | 8–10 | Order, Inventory, Payment, RabbitMQ, the full saga | Saga, Outbox, Idempotency |
| **4 — Notifications + Deeper AI** | 11–14 | Email notifications, order status, admin agent, semantic search | Pub/Sub, DLQ, human-in-the-loop |
| **5 — Resilience** | 15–17 | Circuit breakers, retries, dashboards, load + chaos tests | Circuit Breaker, Tracing, SLOs |
| **6 — AWS** | 18–21 | Deploy everything to AWS with Terraform | Cloud, IaC, Well-Architected |

---

## The ADRs — Architecture Decision Records

An ADR is a written answer to "why did we do it this way?" There are 12 (ADR-000 to ADR-011).
They live in `/docs/adr/`. Key ones to know:

| ADR | Decision | Short Reason |
|---|---|---|
| ADR-000 | Service boundaries | Inventory is its own service (not inside Catalog) so it can scale independently |
| ADR-001 | 4 languages, gRPC internally | Each language teaches something; gRPC is typed and fast |
| ADR-002 | Saga orchestrated in Order | One service is in charge of checkout; easier to debug than choreography |
| ADR-006 | One Postgres with per-service databases | Simpler locally; same schema migrations work on RDS in Phase 6 |
| ADR-009 | LLM provider + model (TBD) | Decided before Phase 2; API key with hard spending limit |
| ADR-010 | Thin messaging adapter | Swapping RabbitMQ → SQS (for AWS) is a config change, not a rewrite |

---

## Local vs AWS — What Changes in Phase 6?

The same code runs locally and in the cloud. Only infrastructure components swap:

| Local (Phases 0–5) | AWS (Phase 6) | What You Change |
|---|---|---|
| Traefik | CloudFront + API Gateway | Rate/bot rules re-tuned |
| Keycloak | Amazon Cognito | Only the JWT issuer URL in config |
| Postgres container | RDS PostgreSQL | Same schemas, same migrations |
| Redis container | ElastiCache | Disposable cache; rebuilt from Postgres |
| MinIO | S3 | Same presigned URL API |
| RabbitMQ | EventBridge + SQS | Adapter swap (ADR-010) |
| Mailpit | Amazon SES | Email sender config only |

This "local-first" approach means you can build and test everything on a laptop before spending
money on cloud resources.

---

## What Is gRPC and Why Not REST?

**REST** (what most web APIs use): sends JSON text over HTTP. Easy to read, flexible, but slower
and there is no enforced contract — any field can be missing.

**gRPC**: sends binary (Protobuf) over HTTP/2. Faster, smaller payloads, and the contract is
*enforced* — if you change a field name, the CI build breaks before bad code ships.

We use REST/JSON only at the edge (browser → gateway) because browsers speak REST naturally.
Everything internal uses gRPC.

---

## What Is Protobuf?

Protobuf (Protocol Buffers) is a language for describing data structures and service calls.
You write a `.proto` file once; a tool generates client and server code in Go, Java, TypeScript,
and Python automatically. All services use the same generated code, so they can never disagree
on field names or types.

```
Example .proto file:
  message Product {
    string id = 1;
    string name = 2;
    int64 price_minor_units = 3;  // e.g. 4999 means $49.99
  }
```

Rule: **contracts (`.proto` files) are written before any service code**. Claude generates the
stubs; you never write them by hand.

---

## What Is OpenTelemetry?

A standard way to record what your system is doing. Every request gets a **trace ID** that travels
through every service it touches. You can open a dashboard (Jaeger or Grafana) and see:

```
Browser request
  └─ BFF (12 ms)
       └─ Catalog.GetSku (3 ms)
       └─ Cart.AddItem (5 ms)
            └─ Catalog.BatchGetSkus (2 ms)  ← validation
```

This is how you debug "the checkout feels slow" — you find the slow span in the trace.

---

## What CLAUDE.md Is For

`CLAUDE.md` is the **working contract between you and Claude Code** for every session.
It is 127 lines (kept short on purpose) and tells Claude:

1. What the system looks like — architecture summary and service map
2. Where things live — folder layout
3. What calls are allowed between services — communication rules
4. How to work — plan first, contracts before code, one feature per session
5. Coding standards per language
6. Special rules — explain every change, never write secrets, tests must pass before committing

Claude reads it at the start of every session. It stays in sync with the PRD so Claude always
has the right context without reading all 13 pages each time.

---

## The 6 Rules Claude Must Always Follow

These are in `CLAUDE.md` under "Rules for Claude":

1. **Explain every change** — you are learning; every edit comes with a "why"
2. **Never write secrets** — no passwords, keys, or tokens anywhere in code, comments, or files
3. **Contracts before code** — Protobuf schema must exist in `/proto` before service code
4. **One service or feature per session** — no scope creep; flag it and stop
5. **Tests must pass before suggesting a commit** — show the test output first
6. **No invented agent responses** — every product or price the AI mentions must come from an
   actual tool call result, not from the LLM's memory

---

## Glossary

| Term | Meaning |
|---|---|
| **Microservice** | A small, independent app that does one job and owns its own database |
| **gRPC** | A fast, typed way for services to call each other (uses Protobuf over HTTP/2) |
| **Protobuf** | A file format for describing data structures; generates code in any language |
| **Saga** | A multi-step transaction across services with automatic compensation (undo) on failure |
| **Outbox pattern** | Write events to your own DB in the same transaction as state changes; a relay sends them |
| **Idempotency** | Doing something twice gives the same result as doing it once — safe to retry |
| **DLQ (Dead Letter Queue)** | A holding queue for messages that failed too many times; prevents one bad message blocking everything |
| **BFF (Backend for Frontend)** | A service that sits between the browser and all the microservices; assembles responses |
| **MCP (Model Context Protocol)** | A standard way to give an AI agent a set of tools (functions it can call) |
| **ADR** | Architecture Decision Record — a short document explaining why a technical choice was made |
| **OTel / OpenTelemetry** | A standard for tracing, metrics, and logs across services |
| **STRIDE** | A threat-modelling framework: Spoofing, Tampering, Repudiation, Info disclosure, DoS, Elevation of privilege |
| **Circuit breaker** | Automatically stops calling a failing service to give it time to recover |
| **Bulkhead** | Separate connection pools per downstream so one slow service cannot exhaust all connections |
| **CQRS** | Command Query Responsibility Segregation — write path and read path use separate models |
| **TLS** | Transport Layer Security — encryption for data in transit (HTTPS is HTTP + TLS) |
| **p95 / p99** | Percentile latency: "95% of requests finish within X ms"; p99 is the slowest 1% |
| **ECS Fargate** | AWS managed container service — you give it a Docker image, it runs it without managing servers |
| **Terraform** | Infrastructure-as-code tool — describes AWS resources in files so they can be versioned and reproduced |

---

> For full requirements, acceptance criteria, and ADR detail see `docs/PRD.md`.
> For the working session contract see `CLAUDE.md`.
