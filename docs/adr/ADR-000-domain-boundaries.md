# ADR-000 — Domain Boundaries

| Field    | Value                                      |
|----------|--------------------------------------------|
| Status   | Draft                                      |
| Decider  | Saru                                       |
| Due      | Phase 0                                    |
| PRD Ref  | Section 12 — "Services as specified; Inventory in Catalog; Payment in Order" |

---

## Context

Before writing a single line of code, we must decide how many services exist and where the
boundaries sit. This decision shapes every other choice: how many databases, how many repos,
how much Docker Compose RAM, how many things you have to understand at once.

The PRD proposes 7 domain services. The question is whether Inventory and Payment deserve
their own services or whether folding them into neighbouring services simplifies the build
without losing the important lessons.

---

## Options

### Option A — All Services Separate (PRD default)

**What it is:** 7 independent domain services — Identity, Catalog, Cart, Order, Inventory,
Payment, Notification — each with its own database.

**How it works:** Inventory and Payment are standalone gRPC services. Order calls them via the
saga. Each service is deployed, scaled, and debugged independently.

**Pros:**
- Each service has a single, clear responsibility — easy to reason about in isolation
- You learn the full complexity of distributed systems: independent failure modes, independent
  databases, independent deployments
- Inventory can use Redis for high-concurrency locking without dragging that complexity into Catalog
- Payment can have its own append-only ledger with no risk of coupling to order state
- Exactly mirrors the real-world pattern you would see in a production e-commerce system

**Cons:**
- More containers running locally — higher RAM usage on a 16 GB laptop
- More Compose profiles, more CI jobs, more Protobuf stubs to generate
- When something goes wrong, you must look in 3 places instead of 1
- Steeper initial setup — you need all services at least stubbed before you can test checkout end-to-end

**Complexity for a solo learner:** Medium-High. The first three phases are manageable. Phase 3
(the saga) is where it feels complex — you are coordinating 4 services for one checkout.

**Estimated resource impact:**
- Local RAM: ~6–8 GB for the full stack with JVM services and Postgres
- Learning overhead: ~1 extra week to understand service-to-service debugging

---

### Option B — Inventory Inside Catalog

**What it is:** Inventory (stock counts, reservations) lives inside the Catalog service.
No separate Inventory service or database.

**How it works:** Catalog owns both product data and stock levels. The saga step "ReserveStock"
becomes a Catalog RPC. Redis-based locking lives in Catalog.

**Pros:**
- One fewer service to run, debug, and deploy
- Catalog already reads stock for the badge (FR-12) — collocating removes a network hop
- Simpler Phase 1 (no Inventory stub needed for the browse path)

**Cons:**
- Catalog becomes responsible for two very different things: product display (read-heavy,
  cacheable) and stock reservation (write-heavy, concurrency-sensitive). These fight each other.
- You cannot scale stock reservation independently from catalog reads during a flash sale
- The most important learning — handling concurrent inventory under load — gets buried inside
  a larger service, making it harder to study
- If you later need to separate them (likely at Phase 5 or 6), it is a painful split

**Complexity for a solo learner:** Lower initially, higher later. The complexity does not
disappear — it just moves inside Catalog and becomes harder to isolate when debugging.

**Estimated resource impact:**
- Saves ~200 MB RAM locally (no separate Go process + Postgres DB)
- Loses approximately 2 weeks of focused distributed-systems learning on inventory concurrency

---

### Option C — Payment Inside Order

**What it is:** Payment logic (authorize, capture, void) lives directly inside the Order service.
No separate Payment service.

**How it works:** Order calls the payment provider stub directly. The append-only ledger is a
table in Order's Postgres database.

**Pros:**
- One fewer service — simpler saga (3 participants instead of 4)
- Easier to trace a checkout in one place
- Payment stub is simpler to wire up

**Cons:**
- Order becomes responsible for saga orchestration AND financial record-keeping — two
  very different concerns
- The idempotency and anti-double-charge logic is harder to test when it is buried in Order
- In any real system, payment is always a separate domain because it has its own compliance,
  audit, and retry requirements — you lose that lesson
- Financial ledger isolation (the append-only write-once pattern, FR-08) is a key learning goal;
  collocation obscures it

**Complexity for a solo learner:** Slightly lower in Phase 3, but you lose one of the most
important patterns: how to build a payment anti-corruption layer safely.

**Estimated resource impact:**
- Saves ~300 MB RAM locally
- Loses the payment idempotency and ACL pattern as a first-class learning unit

---

### Option D — Combine B + C (Minimal Split: 5 services)

**What it is:** Inventory in Catalog + Payment in Order = 5 services total.

**Pros:** Lowest complexity and RAM at the start. Good for getting the demo working fast.

**Cons:** You lose two of the most important distributed-systems lessons: inventory concurrency
and payment idempotency. The PRD explicitly calls these out as learning targets (FR-07, FR-08).
Separating them later is significantly more work than starting separate.

**Complexity for a solo learner:** Lowest initially, highest if you try to separate later.

---

## Comparison Table

| Criterion                        | A — All Separate | B — Inventory in Catalog | C — Payment in Order | D — 5 Services |
|----------------------------------|------------------|--------------------------|----------------------|----------------|
| Services to run locally          | 7 + infra        | 6 + infra                | 6 + infra            | 5 + infra      |
| Local RAM (approx.)              | ~7 GB            | ~6.8 GB                  | ~6.7 GB              | ~6.5 GB        |
| Saga complexity                  | High (4 actors)  | Medium (3 actors)        | Medium (3 actors)    | Low (2 actors) |
| Inventory concurrency lesson     | Full             | Buried in Catalog        | Full                 | Buried         |
| Payment idempotency lesson       | Full             | Full                     | Buried in Order      | Buried         |
| Debug difficulty (Phase 3)       | Higher           | Medium                   | Medium               | Lower          |
| Reflects real-world patterns     | Yes              | Partial                  | Partial              | No             |
| Risk of painful split later      | None             | High (if you outgrow it) | High                 | Very high      |

---

## Questions to Help You Decide

1. **How important is realism to you?** Option A mirrors what you would see at a real company.
   If your goal is to put this on a CV and explain the design in an interview, Option A gives
   you the most to talk about. Options B–D simplify the demo but reduce that signal.

2. **What is your laptop's RAM?** If you have exactly 16 GB and are running other apps alongside
   Docker, the ~1.5 GB difference between Option A and D could matter. Have you checked your
   current Docker Desktop memory limit setting?

3. **Which learning goal matters more to you right now?**
   - "I want to deeply understand concurrent inventory management (the flash-sale problem)" → keep Inventory separate
   - "I want to deeply understand payment safety and double-charge prevention" → keep Payment separate
   - "I just want to get a working checkout demo as fast as possible" → Option D is fine

4. **Are you comfortable starting Phase 3 with more complexity?** The saga in Option A has 4
   participants. If Phase 3 feels like a bottleneck, you could start with Option D for Phases 0–2
   and then split services out in Phase 3 as a deliberate refactoring exercise. Would that work?

---

## Decision: [TBD]

*Answer the questions above and fill this in.*

**Chosen option:** …

**Rationale:** …

---

## Consequences

*To be filled in after the decision.*
