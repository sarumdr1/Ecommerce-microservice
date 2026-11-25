# ADR-006 — Data-Store Layout and Accounts

| Field    | Value                                                                     |
|----------|---------------------------------------------------------------------------|
| Status   | Draft                                                                     |
| Decider  | Saru                                                                      |
| Due      | Phase 0 (local layout); Phase 5 (AWS account structure)                   |
| PRD Ref  | Section 12 — "Shared Postgres with per-service DBs vs instance per service; single vs multi-account" |

---

## Context

"Database per service" is the microservices pattern where no two services share tables.
The question here is not *whether* to do database-per-service (the PRD requires it), but
*how* to implement it — and what that looks like locally vs on AWS.

There are two independent sub-decisions:
1. **Local layout:** one Postgres container with separate databases, vs one container per service
2. **AWS layout:** single account vs multi-account (dev/staging/prod in separate accounts)

Both must be decided in Phase 0 because the Terraform modules and Compose files are built
around this choice.

---

## Part 1 — Local Postgres Layout

### Option 1A — Single Postgres Container, Per-Service Databases (PRD default)

**What it is:** One Postgres Docker container. Inside it, each service gets its own database
(e.g. `identity_db`, `catalog_db`, `order_db`). Access is controlled by per-service Postgres
users with grants only to their own database.

**How it works:**
```
postgres container
├── identity_db      (user: identity, password: from .env)
├── catalog_db       (user: catalog)
├── cart_db          (user: cart)
├── order_db         (user: order)
├── inventory_db     (user: inventory)
├── payment_db       (user: payment)
├── notification_db  (user: notification)
└── agent_db         (user: agent, extension: pgvector)
```
One init script creates all databases and users on first start.

**Pros:**
- Single container to manage — `docker compose up postgres` is one line
- Easy to inspect all databases with one `psql` connection
- Low RAM: one Postgres process (~200 MB) instead of eight (~1.6 GB)
- Easy to wipe and reset: `docker compose down -v` removes all data, `up` rebuilds from migrations
- Mirrors the non-prod layout you would use on RDS (one RDS instance, multiple databases,
  per-service users) which saves money on Phase 6
- Database-per-service isolation is enforced by Postgres grants — a service cannot touch
  another service's tables even if the code accidentally tries

**Cons:**
- Not perfectly isolated: a runaway query in one service could consume all Postgres CPU/RAM
  (though this is unlikely in development)
- One container going down takes all databases with it
- The init script that creates all 8 databases and users needs to be maintained

**Complexity for a solo learner:** Low. This is the standard local microservices setup.
One init SQL file, one Compose service entry.

**Estimated resource impact:** ~200 MB RAM for the whole Postgres layer.

---

### Option 1B — One Postgres Container Per Service

**What it is:** Each service runs its own Postgres container: `postgres-identity`,
`postgres-catalog`, `postgres-order`, etc.

**How it works:** Each container is an independent Postgres process. Compose profiles can
start only the databases needed for the current task.

**Pros:**
- True process-level isolation: a crash in `postgres-order` does not affect `postgres-catalog`
- Exactly mirrors a production setup where each service has its own RDS instance
- Easy to vary Postgres versions per service if needed

**Cons:**
- 7–8 Postgres processes × ~200 MB = **~1.4–1.6 GB** just for databases
- 8 sets of connection strings, passwords, and volume mounts in Compose
- Much slower laptop startup — 8 containers initialising simultaneously
- In practice, true database isolation between services is enforced by not writing cross-service
  queries, not by separate processes — Option 1A achieves the same guarantee at 1/8 the RAM cost
- RDS costs scale with number of instances, so this is more expensive in Phase 6 too

**Complexity for a solo learner:** Medium overhead without meaningful learning benefit over 1A.
The database-per-service *pattern* is what you are learning — the number of Postgres processes
does not change that.

**Estimated resource impact:** ~1.4–1.6 GB RAM vs ~200 MB for Option 1A. Difference: ~1.2 GB.

---

## Part 2 — AWS Account Structure (Phase 6)

### Option 2A — Single AWS Account, Environment Separation by Namespace/Tag

**What it is:** One AWS account. All environments (dev, staging, prod-demo) are separate
Terraform workspaces or ECS clusters in the same account. Resources are tagged by environment.

**How it works:**
```
One AWS account
├── ECS cluster: ecommerce-dev
├── ECS cluster: ecommerce-staging
├── ECS cluster: ecommerce-prod-demo
├── RDS: one instance per environment (or shared non-prod)
└── IAM roles scoped by environment tag
```

**Pros:**
- One AWS account to manage, one billing dashboard, one set of IAM users
- Simpler for a solo learner — no cross-account role assumption, no AWS Organizations setup
- Cheaper (AWS Organizations is free, but managing multiple accounts adds ops overhead)
- Perfectly adequate for a learning project where "prod-demo" is not real production

**Cons:**
- A mistake in one Terraform workspace (e.g. `terraform destroy` in the wrong workspace)
  could affect other environments
- IAM boundary between environments is by convention (tagging) not by account wall
- Not how large companies do it — but for a P4 learning project this is fine

**Complexity for a solo learner:** Low. One account, one set of credentials, one billing view.

**Estimated resource impact:** No extra cost from account structure.

---

### Option 2B — Multi-Account (AWS Organizations)

**What it is:** Three AWS accounts: one for dev, one for staging, one for prod-demo.
AWS Organizations ties them together under a management account.

**How it works:**
```
Management account (billing)
├── dev account
├── staging account
└── prod-demo account
```
Terraform uses cross-account roles to deploy to each account.

**Pros:**
- True blast-radius containment: a mistake in dev cannot touch prod-demo
- How large companies actually do it — strong real-world signal
- SCPs (Service Control Policies) can enforce guardrails at the account level

**Cons:**
- Significantly more AWS setup complexity before writing any service code
- Cross-account IAM role assumption adds friction to every CI/CD step
- AWS Organizations + Control Tower setup takes 1–2 days and is easy to misconfigure
- For a learning project where "prod-demo" is not serving real users, the blast-radius benefit
  is theoretical
- The PRD mentions "single vs multi-account" as an option but notes the goal is a demo, not
  a production system

**Complexity for a solo learner:** High. Worth learning eventually, but adds ~1 week of AWS
overhead before any service is deployed. Can always be refactored in later.

**Estimated resource impact:** No direct cost difference, but ~1 extra week of setup time.

---

## Comparison Table

| Criterion                          | 1A: Shared Postgres | 1B: Postgres per Service | 2A: Single Account | 2B: Multi-Account |
|------------------------------------|---------------------|--------------------------|--------------------|-------------------|
| Local RAM (database layer)         | ~200 MB             | ~1.4 GB                  | —                  | —                 |
| Compose complexity                 | Low (1 container)   | High (8 containers)      | —                  | —                 |
| DB isolation enforcement           | By Postgres grants  | By OS process            | —                  | —                 |
| `make reset` simplicity            | Very easy           | Moderate                 | —                  | —                 |
| Phase 6 RDS cost                   | 1 instance/env      | 7–8 instances/env        | —                  | —                 |
| Reflects real non-prod setup       | Yes                 | Overkill                 | —                  | —                 |
| AWS blast-radius containment       | —                   | —                        | Weak (by tag)      | Strong (by account) |
| AWS setup time (Phase 6)           | —                   | —                        | ~1 day             | ~1 week           |
| Cross-account CI/CD complexity     | —                   | —                        | None               | Medium            |
| Appropriate for learning demo      | —                   | —                        | Yes                | Overkill          |

---

## Questions to Help You Decide

**On local Postgres layout:**
1. How much RAM does your Docker Desktop have allocated? If you are running on 8–12 GB allocated
   to Docker, Option 1B might be tight when all Compose profiles are running. What does
   `docker stats` show on your machine when the current stack is up?
2. Do you want the experience of connecting to each service's database independently (useful for
   learning schema migrations per service), or is a single `psql` connection to one container
   with `\c order_db` etc. fine for your workflow?

**On AWS account structure:**
3. Is this purely a portfolio/learning project, or is there any chance a real user will ever
   use the prod-demo environment? If real users are involved, Option 2B's isolation matters more.
4. Do you already have an AWS account? If yes, is it a fresh account or one with existing resources?
   A fresh account makes Option 2A very clean. An account with existing resources makes the
   namespace tagging approach more important.
5. Is learning AWS Organizations/multi-account architecture a specific goal for this project?
   If yes, Option 2B is worth the overhead. If not, you can learn it on a separate short exercise
   and keep this project simpler.

---

## Decision: [TBD]

**Part 1 — Local Postgres layout:** …

**Part 2 — AWS account structure:** …

**Rationale:** …

---

## Consequences

*To be filled in after the decision.*
