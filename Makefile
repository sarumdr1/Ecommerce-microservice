# =============================================================================
# Makefile — E-Commerce Platform
# =============================================================================
# Prerequisites: Docker with Compose plugin (v2), a filled-in .env file.
#
# Quick start:
#   cp .env.example .env   # then edit passwords
#   make up                # starts postgres + redis + traefik + keycloak
#
# Profile reference (from docs/PRD.md Section 5.1):
#   core          — Traefik, Keycloak  (Phase 0–)
#   checkout      — RabbitMQ           (Phase 3–)
#   async         — Mailpit            (Phase 4–)
#   agent         — Agent service      (Phase 2–)
#   observability — OTel, Jaeger, Grafana (Phase 5–)
#
# Run multiple profiles:
#   make up PROFILES="core checkout"
# =============================================================================

PROFILES ?= core

# Build --profile flags from space-separated PROFILES variable
# e.g. PROFILES="core checkout" → --profile core --profile checkout
PROFILE_FLAGS := $(foreach p,$(PROFILES),--profile $(p))

.DEFAULT_GOAL := help

# ── Main targets ──────────────────────────────────────────────────────────────

.PHONY: up
up: check-env          ## Start services  [PROFILES=core]
	docker compose $(PROFILE_FLAGS) up -d
	@echo ""
	@echo "Services starting. Run 'make ps' to check health."
	@echo "  Postgres:  localhost:5433  (host port; container is 5432)"
	@echo "  Redis:     localhost:6380  (host port; container is 6379)"
	@echo "  Traefik:   http://localhost:8000  (dashboard: http://localhost:8888/dashboard/)"
	@echo "  Keycloak:  http://localhost:8081  (admin / \$$KEYCLOAK_ADMIN_PASSWORD)"

.PHONY: down
down:                  ## Stop and remove containers, keep volumes  [PROFILES=core]
	docker compose $(PROFILE_FLAGS) down --remove-orphans

.PHONY: reset
reset: check-env       ## Destroy EVERYTHING (containers + volumes) and restart fresh
	@echo "⚠️  This deletes all data in Postgres and Redis volumes."
	@read -p "Continue? [y/N] " ans && [ "$$ans" = "y" ] || exit 1
	docker compose down --remove-orphans --volumes
	docker compose $(PROFILE_FLAGS) up -d
	@echo "✓ Fresh start complete."

.PHONY: logs
logs:                  ## Follow logs  [SVC= to tail one service, e.g. make logs SVC=keycloak]
	docker compose logs -f $(SVC)

# ── Status / inspection ───────────────────────────────────────────────────────

.PHONY: ps
ps:                    ## Show container status and health
	docker compose ps

.PHONY: psql
psql:                  ## Open a psql shell as the postgres superuser
	@echo "Connecting to postgres as superuser. Use \\c <dbname> to switch databases."
	docker compose exec postgres psql -U postgres

# ── Proto / Buf ───────────────────────────────────────────────────────────────

.PHONY: proto-install
proto-install:         ## Install Buf CLI into ~/.local/bin (no sudo needed)
	@mkdir -p ~/.local/bin
	@echo "Installing Buf CLI..."
	curl -sSL https://github.com/bufbuild/buf/releases/latest/download/buf-Linux-x86_64 \
		-o ~/.local/bin/buf
	chmod +x ~/.local/bin/buf
	@echo "✓ buf installed to ~/.local/bin/buf"
	@echo ""
	@echo "If 'buf' is not found after this, add ~/.local/bin to your PATH:"
	@echo "  echo 'export PATH=\"\$$HOME/.local/bin:\$$PATH\"' >> ~/.bashrc && source ~/.bashrc"
	@echo ""
	~/.local/bin/buf --version

.PHONY: proto-deps
proto-deps:            ## Download and lock Buf dependencies (run after editing buf.yaml)
	cd proto && buf dep update

.PHONY: proto-lint
proto-lint:            ## Lint all .proto files
	cd proto && buf lint

.PHONY: proto-breaking
proto-breaking:        ## Check for breaking changes against main branch
	cd proto && buf breaking --against '.git#branch=main'

.PHONY: proto-gen
proto-gen:             ## Generate Go + TypeScript stubs into gen/
	cd proto && buf generate
	@echo "✓ Stubs written to gen/go and gen/ts"

.PHONY: proto-check
proto-check: proto-lint proto-breaking  ## Lint + breaking check (run in CI)

# ── Utilities ─────────────────────────────────────────────────────────────────

.PHONY: check-env
check-env:
	@test -f .env || { echo "ERROR: .env not found. Run: cp .env.example .env"; exit 1; }

.PHONY: help
help:                  ## Show this help
	@echo "Usage: make [target] [PROFILES=core] [SVC=service-name]"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make up                          # start core (Traefik + Keycloak)"
	@echo "  make up PROFILES='core checkout' # also start RabbitMQ"
	@echo "  make logs SVC=keycloak           # tail Keycloak logs only"
	@echo "  make reset                       # wipe all volumes and restart"
