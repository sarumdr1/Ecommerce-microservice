## What this PR does

<!-- One sentence: what changed and why. -->

## Related

- PRD section / ADR / issue: <!-- e.g. FR-03, ADR-002 -->
- Phase: <!-- e.g. Phase 1 -->

---

## Security checklist (PRD Section 8.2 — FA1)

Work through every item. Check it off or write N/A with a one-line reason.

### Secrets & credentials
- [ ] No API keys, passwords, tokens, or connection strings in source code, test fixtures, logs, or comments
- [ ] No new `.env` variables that are not documented in `.env.example`
- [ ] Any new external service credentials are referenced via environment variables only

### Authentication & authorisation
- [ ] Every new gRPC RPC is covered by an auth rule (public / shopper / admin) — documented in a comment on the service definition
- [ ] Cross-user data access is impossible: queries are scoped to the caller's `user_id` / `order_id` / etc.
- [ ] Agent tool calls forward the caller's JWT and do not use elevated credentials

### Data handling & PII
- [ ] No PII (name, email, address, payment data) appears in log statements, trace attributes, or error messages
- [ ] Any new field that could hold PII is noted in the service's threat model

### Input validation
- [ ] All inputs entering from outside the service boundary are validated (proto `validate` rules or manual checks) before reaching business logic
- [ ] gRPC error codes match the shared error model in `common/v1/error.proto` — no raw string errors returned

### Mutations & audit
- [ ] Every admin mutation writes an entry to the audit log (actor, action, before, after, timestamp)
- [ ] Agent-proposed writes go through the confirmation protocol (AG-06) — no direct mutations without human approval

### Dependencies
- [ ] Any new direct dependency was checked for known CVEs (`trivy fs` or `make dependency-scan`)
- [ ] New dependencies have been added to the relevant lock file (`go.sum`, `package-lock.json`, `uv.lock`, `pom.xml`)

### Transport & TLS
- [ ] No new service-to-service call uses plain HTTP — all internal calls go over gRPC with TLS
- [ ] No new synchronous call violates the communication matrix in `CLAUDE.md`
- [ ] Deadlines are set on every new outgoing RPC call

### STRIDE — threat check
> Answer each question for the surface area this PR touches.
> Write N/A if the PR does not affect that layer.

| Threat | Question | Answer |
|---|---|---|
| **Spoofing** | Could an attacker impersonate a user or service? | |
| **Tampering** | Could data be modified in transit or at rest? | |
| **Repudiation** | Are actions logged so they can't be denied later? | |
| **Info disclosure** | Could sensitive data leak to an unauthorised caller? | |
| **Denial of service** | Could this endpoint be abused to exhaust resources? | |
| **Elevation of privilege** | Could a shopper gain admin access through this change? | |

---

## Test evidence

- [ ] Unit tests added or updated for new logic
- [ ] Integration test covers the happy path end-to-end
- [ ] Failure / compensation paths have tests (for saga steps)
- [ ] `make proto-lint` passes (if `.proto` files changed)
- [ ] `make proto-breaking` passes (if `.proto` files changed)
- [ ] All existing tests still pass locally

---

## Learning note

<!-- One sentence: which design pattern or PRD concept does this PR demonstrate?
     This feeds the /docs/learning index (Section 10 "Learning loop"). -->
