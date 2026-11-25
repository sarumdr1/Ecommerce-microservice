# ADR-001 — Stack, Transport, and Cost Model

| Field    | Value                                                               |
|----------|---------------------------------------------------------------------|
| Status   | Draft                                                               |
| Decider  | Saru                                                                |
| Due      | Phase 0                                                             |
| PRD Ref  | Section 12 — "4 vs 5 languages; gRPC vs REST internally; local resource budget; Phase 6 cost ceiling" |

---

## Context

Three sub-decisions are bundled here because they are tightly coupled: the language count
determines toolchain overhead, the transport choice determines how much boilerplate each language
needs, and both together drive the local resource budget and eventual AWS cost.

Decide all three before writing any code, because changing the transport protocol mid-project
means regenerating stubs and rewriting interceptors in every service.

---

## Part 1 — Language Count

The PRD proposes 4 languages (Go, Java, TypeScript, Python) with Rust for Inventory as a
"Could-tier stretch" (ADR-001). The question is whether to include Rust from the start.

### Option 1A — 4 Languages (Go, Java, TypeScript, Python)

**What it is:** Each language maps to a natural strength. No Rust.

**How it works:**
- Go: Identity, Catalog, Cart, Inventory
- Java (Spring Boot): Order, Payment
- TypeScript: BFF, Notification
- Python: Agent + MCP server

**Pros:**
- Each language has a clear reason to exist — you learn one thing per language, not one thing
  per service
- All four have mature gRPC libraries, OpenTelemetry SDKs, and testing frameworks
- Python is the strongest ecosystem for LLM/agent work right now — no competition
- Java Spring Boot is the most common enterprise stack you will encounter on the job
- Go is what most cloud-native infrastructure is written in
- TypeScript is what most frontend/BFF teams use

**Cons:**
- Switching mental context between 4 languages adds cognitive load
- Each language requires its own CI toolchain, linting config, and OTel setup
- Debugging a cross-language trace requires knowing all 4 runtimes

**Complexity for a solo learner:** Medium. The key is never working in more than one language
per session. The CLAUDE.md rule "one service or feature per session" handles this.

**Estimated learning time per language:** ~1–2 weeks to reach productive proficiency
for the specific patterns used here (gRPC interceptors, structured logging, testing).

---

### Option 1B — 5 Languages (Add Rust for Inventory)

**What it is:** Inventory is rewritten in Rust instead of Go for memory safety and performance.

**Pros:**
- Rust's ownership model is excellent for the concurrent reservation logic (no data races by design)
- Strong learning signal if Rust is a career goal
- Impressive on a CV

**Cons:**
- Rust has the steepest learning curve of any mainstream language — expect 4–8 weeks before
  you are productive writing async gRPC services with it
- The gRPC + Tokio + Tonic stack in Rust is powerful but verbose compared to Go
- OpenTelemetry Rust SDK is less mature than the Go SDK
- Adds a 5th CI toolchain (cargo, clippy, rustfmt)
- The PRD already lists this as "Could-tier" — it is explicitly lower priority than finishing
  the core system

**Complexity for a solo learner:** Very High. Rust is a language you learn as a project, not
as a side task while building a distributed system in 3 other languages.

**Estimated resource impact:** +3–6 weeks of project timeline if Rust is included from Phase 0.

---

## Part 2 — Internal Transport

### Option 2A — gRPC Internally, REST/JSON at the Edge (PRD default)

**What it is:** All service-to-service calls use gRPC (HTTP/2 + Protobuf). The gateway and BFF
expose REST/JSON to the browser.

**How it works:** One `.proto` file per service defines all RPCs and messages. Tools (Buf)
generate type-safe client/server stubs in every language. The gateway does REST → gRPC translation.

**Pros:**
- **Contracts are enforced by the compiler.** If you rename a field, the build breaks before
  bad code ships. With REST this is a runtime surprise.
- **Protobuf is smaller and faster than JSON** — roughly 3–10× smaller on the wire.
- **Streaming is built in** — the Agent.Chat streaming RPC (AG-01) is natural in gRPC;
  awkward with REST.
- **You learn the industry standard** — most large-scale microservice systems use gRPC or
  similar binary protocols internally.
- Generated stubs mean almost zero boilerplate for making a cross-service call.

**Cons:**
- Steeper initial setup: Buf toolchain, generated stub pipeline, one interceptor set per language
- Cannot `curl` a gRPC endpoint directly — you need `grpcurl` or a Postman gRPC tab
- Gateway must handle REST→gRPC transcoding (Traefik does this, but it needs config)
- Each new language adds an OTel + deadline interceptor to write

**Complexity for a solo learner:** Medium. The first `.proto` file and stub generation setup
takes half a day. After that, adding a new RPC is fast.

---

### Option 2B — REST/JSON Everywhere

**What it is:** All service-to-service calls use HTTP REST with JSON bodies. No Protobuf.

**How it works:** Standard HTTP clients in every language. OpenAPI specs for documentation.
No code generation required.

**Pros:**
- Zero new tooling — every developer already knows how to make a REST call
- Debuggable with `curl` from day one
- No stub generation pipeline to maintain
- Easier for a solo learner to get the first end-to-end flow working fast

**Cons:**
- **No contract enforcement.** A typo in a field name is a runtime bug, not a compile error.
  In a polyglot system this is dangerous — Go and Java will silently ignore unknown JSON fields.
- Slower on the wire for high-throughput calls (catalog reads, inventory checks under load)
- You lose the main lesson of this project: how to design and version typed service contracts
- The streaming requirement for Agent.Chat (AG-01) requires SSE or WebSockets — both are more
  complex to wire correctly than gRPC streaming
- OpenAPI specs must be written and maintained by hand; they drift from the implementation

**Complexity for a solo learner:** Lowest initially. Highest long-term because contract drift
creates bugs that are hard to find.

---

### Option 2C — REST Internally, gRPC Only for Agent Streaming

**What it is:** A hybrid. REST between domain services; gRPC only for the Agent.Chat streaming
RPC because REST streaming is awkward.

**Pros:**
- Simpler for Phases 0–2 (no Protobuf until the agent arrives in Phase 2)
- You still learn gRPC, just only for the agent path

**Cons:**
- Two transport protocols means two interceptor stacks for tracing, deadlines, and error handling
- Contract drift risk on all the REST-only services
- When you reach Phase 5 (resilience), you need deadline propagation on every hop — this is
  much cleaner with gRPC interceptors than with REST middleware
- Halfway house: you get the complexity of both without the full benefit of either

**Complexity for a solo learner:** Medium initially, then confusingly mixed later.

---

## Part 3 — Local Resource Budget and Phase 6 Cost Ceiling

This is not a binary choice but a set of numbers to agree on before Phase 0, so the Compose
profiles are designed correctly from the start.

### Local (Phases 0–5)

The full stack with all services uses approximately:

| Component | Approx. RAM |
|---|---|
| 2 × Java JVM services (Order, Payment) | ~600 MB (300 each with `-Xmx256m`) |
| 4 × Go services | ~200 MB total |
| 1 × TypeScript BFF | ~100 MB |
| 1 × TypeScript Notification | ~80 MB |
| 1 × Python Agent | ~200 MB |
| Postgres (single container, 8 DBs) | ~200 MB |
| Redis | ~50 MB |
| RabbitMQ | ~150 MB |
| MinIO | ~100 MB |
| Traefik + Keycloak | ~400 MB |
| OTel + Jaeger + Prometheus + Grafana | ~600 MB |
| **Total (all profiles)** | **~2.7 GB** |

On a 16 GB laptop with macOS/Windows overhead (~4 GB) and a browser open (~500 MB), this is
comfortable. With Compose profiles you only run the subset you need per task.

### Phase 6 (AWS)

The PRD says the cost ceiling is [TBD $/month] (ADR-001). You need to set this number before
Phase 6 so Terraform modules are designed to stay within it. Typical ranges for a dev/staging
environment with the services above on ECS Fargate:

| Environment | Estimated Monthly AWS Cost |
|---|---|
| `dev` (single task per service, spot) | ~$80–$120/month |
| `staging` (single task, on-demand) | ~$150–$200/month |
| `prod-demo` (2 tasks per service, Multi-AZ RDS) | ~$300–$500/month |

These are rough estimates. The actual cost depends on how often you run load tests and whether
the environment stays up 24/7 or is torn down when not in use.

---

## Comparison Table

| Criterion                     | 4 Languages | 5 Languages | gRPC internal | REST internal | Hybrid |
|-------------------------------|-------------|-------------|---------------|---------------|--------|
| Learning value                | High        | Very high   | High          | Low           | Medium |
| Initial setup time            | 1 week      | +3–6 weeks  | 1 day for Buf | Hours         | Mixed  |
| Contract safety               | —           | —           | Compiler-enforced | Runtime only | Mixed |
| Debuggability (curl etc.)     | —           | —           | Needs grpcurl | Native        | Mixed  |
| Streaming for Agent.Chat      | —           | —           | Native        | Awkward       | gRPC only |
| CI toolchain overhead         | 4 pipelines | 5 pipelines | +Buf step     | None          | +Buf step |
| Reflects real production      | Yes         | Stretch     | Yes           | Partial       | Partial |

---

## Questions to Help You Decide

**On language count:**
1. Is Rust a specific career goal for you, or is it a "nice to have"? If it is a goal, it is
   better learned as its own project first, then applied here. If it is just interesting, 4
   languages is plenty.
2. Have you used Go before? If not, Go is the language you will spend the most time with
   (4 services). It is worth spending one day on a Go tour before Phase 0 so it does not slow
   down Phase 1.

**On transport:**
3. Have you used Protobuf or gRPC before? If yes, Option 2A is straightforward. If no, are you
   comfortable spending the first half of Phase 0 on the Buf setup, knowing it pays off in
   every phase after?
4. How important is "I can curl any endpoint to debug it" to you? If that matters a lot,
   Option 2B or 2C reduces friction in early phases. But consider: `grpcurl` fills this role
   for gRPC and you would learn it anyway.

**On cost:**
5. Do you have an AWS budget in mind for Phase 6? Even a rough number ($50/month vs $200/month)
   determines whether the `prod-demo` environment runs continuously or is spun up only for demos.
6. Are you planning to tear down AWS environments when not actively testing, or leave them
   running? This changes the cost estimate significantly.

---

## Decision: [TBD]

**Part 1 — Language count:** …

**Part 2 — Internal transport:** …

**Part 3 — Monthly AWS cost ceiling:** $… /month for staging; $… /month for prod-demo

**Rationale:** …

---

## Consequences

*To be filled in after the decision.*
