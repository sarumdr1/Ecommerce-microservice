# CLAUDE.md — Polyglot gRPC E-Commerce Platform

Full spec: `docs/PRD.md`. This file is the working contract for every session.

---

## Architecture Summary

Traefik gateway → TypeScript Web BFF → 7 domain services over internal gRPC (HTTP/2 + Protobuf).
Services own their data (database-per-service). Async backbone: RabbitMQ (EventBridge + SQS on AWS).
Every service that publishes events uses a transactional outbox; a polling relay sends them.
Checkout is an asynchronous saga orchestrated by the Order service (not choreography — ADR-002).
The Agent service (Python) exposes three agents via an MCP server; agents act with the caller's token only.
All gRPC contracts live in `/proto` (Buf); stubs are generated — never hand-written.
Local: Docker Compose, one Postgres container with per-service databases, MinIO, Redis, RabbitMQ.
Cloud (Phase 6): ECS Fargate, RDS, ElastiCache, S3, EventBridge + SQS, Cognito, CloudFront.
Observability: OpenTelemetry traces across gRPC, events and agent hops; RED metrics; Grafana dashboards.
Security by default (FA1): STRIDE per service, TLS on internal gRPC, least-privilege DB users, PII never logged.

---

## Service → Language → Data Store

| # | Service        | Language              | Data Store(s)         |
|---|----------------|-----------------------|-----------------------|
| — | Gateway + BFF  | Traefik; TypeScript   | Stateless             |
| 1 | Identity       | Go + Keycloak         | Postgres              |
| 2 | Catalog        | Go                    | Postgres + Redis + MinIO |
| 3 | Cart           | Go                    | Postgres              |
| 4 | Order          | Java (Spring Boot)    | Postgres              |
| 5 | Inventory      | Go                    | Postgres + Redis      |
| 6 | Payment        | Java (Spring Boot)    | Postgres              |
| 7 | Notification   | TypeScript (Node.js)  | Postgres              |
| 8 | Agent + MCP    | Python                | Postgres + pgvector   |

---

## Monorepo Folder Layout

```
/proto              Protobuf definitions (Buf); source of truth for all contracts
/services/<name>    One folder per service; may contain its own CLAUDE.md
/agent              Agent service and MCP server
/infra/compose      Docker Compose files and profiles
/infra/terraform    Terraform modules (Phase 6)
/docs/adr           Architecture Decision Records (ADR-000 … ADR-011)
/docs/threat-models STRIDE threat models per service
/tests/load         k6 load and chaos scripts
CLAUDE.md           This file
```

Secrets go in a git-ignored `.env`; a committed `.env.example` documents every variable.
Never put secrets in code, logs, prompts, or this file.

---

## Synchronous Communication — Hard Rules

These rules are enforced in code review. Any call not in the table below is prohibited.

| Caller       | May Call                                                        | Deadline / Retry             |
|--------------|-----------------------------------------------------------------|------------------------------|
| Web BFF      | Identity, Catalog, Cart, Order (read + CreateOrder), Agent.Chat | BFF budget; idempotent retry |
| Cart         | Catalog.BatchGetSkus (cached, read-only)                        | 100 ms; 1 retry              |
| Order        | Catalog.BatchGetSkus (cached), Cart.GetCheckoutSnapshot         | 150 ms / 100 ms; 1 retry     |
| MCP server   | Catalog, Cart (Add after confirm), Order (read), Inventory (read) | 300–500 ms; 1 retry         |
| Payment      | Provider stub only (egress)                                     | 2 s; idempotent with key     |

- **No service calls Inventory, Payment, or Notification synchronously for writes.**
- At most two sequential hops after the BFF; the second hop must be read-only cached.
- Every call carries a deadline; retries happen at exactly one layer with full jitter.

---

## Claude Code Workflow Rules

1. **Plan mode first.** Start every task by writing a plan. Wait for review before touching files.
2. **Contract before code.** Write and review Protobuf / event schemas in `/proto` before any service code. Generate stubs — never write them by hand.
3. **One service or one feature per session.** Keep scope small so diffs stay reviewable.
4. **Tests must pass before suggesting a commit.** Run the relevant test suite; report results.
5. **Explain every change and why.** I am learning — describe what changed, the tradeoff chosen, and which pattern or PRD section it satisfies.
6. **Green CI before merge.** Buf lint, breaking-change checks, unit tests, and security scans must all pass.
7. **Learning loop.** After each milestone note what was built and why in `/docs/learning/`; tag the design pattern.

---

## Coding Standards

### Go (Identity, Catalog, Cart, Inventory)
- Standard project layout: `cmd/`, `internal/`, generated stubs under `internal/gen/`.
- Errors: `fmt.Errorf("…: %w", err)` — no bare `errors.New` in business logic.
- gRPC interceptors for deadline propagation, structured logging (zerolog), and OTel tracing.
- Table-driven tests with `t.Run`; integration tests use a real Postgres (no mocks for DB).
- `golangci-lint` in CI; `go vet` and `staticcheck` required.

### Java / Spring Boot (Order, Payment)
- Java 21; Spring Boot 3; use virtual threads (`spring.threads.virtual.enabled=true`).
- gRPC via `grpc-spring-boot-starter`; interceptors for deadlines and OTel.
- Domain events published through the outbox — never direct RabbitMQ calls in domain code.
- Tests: JUnit 5 + Testcontainers for Postgres; Mockito only for external stubs.
- Checkstyle + SpotBugs in CI; JVM heap capped in Compose (`-Xmx256m` default).

### TypeScript / Node.js (BFF, Notification)
- TypeScript strict mode; ESM modules; Node 20 LTS.
- BFF: `@grpc/grpc-js` + `@grpc/proto-loader`; never import generated `.js` stubs directly — use the typed wrappers in `internal/clients/`.
- `zod` for validating all inbound REST bodies; never `any`.
- Tests: Vitest; integration tests with Testcontainers.
- ESLint + Prettier enforced in CI.

### Python (Agent + MCP server)
- Python 3.12+; `uv` for dependency management; `pyproject.toml` only.
- Type hints everywhere; `mypy --strict` in CI.
- Agent framework and LLM provider decided in ADR-009; wrap in an interface so the provider is swappable.
- PII redaction middleware on every LLM call; never log raw user messages or tool results.
- Tests: `pytest`; agent evals in `/agent/evals` run on every CI push.

---

## Rules for Claude

- **Explain every change.** For each edit describe what it does, why this approach, and which PRD/ADR section it satisfies.
- **Never write secrets.** No API keys, passwords, tokens, or credentials in code, comments, logs, prompts, or this file — ever.
- **Contracts first.** Do not write service code until the relevant Protobuf or event schema exists in `/proto` and has been reviewed.
- **One service or feature per session.** Refuse scope creep; flag it and stop.
- **Tests before commit.** Do not suggest `git commit` until the test suite passes and you have shown the output.
- **No invented tool calls.** Agent grounding rule: every SKU or price in an agent response must come from a tool result in the same turn.
- For full requirements, acceptance criteria, and ADRs see `docs/PRD.md`.
