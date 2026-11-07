# Local infrastructure of Laba services: Traefik + laba_network + the service registry
# (services.yaml, personal overrides in services.local.yaml). See README.md.
#
# SERVICES: services and/or groups from services.yaml, `all` for every service;
# default: the services listed in services.local.yaml. BRANCH=...: force a branch for all of them.

NETWORK      := laba_network
SVC_FIELD    := python3 bin/svc-field
BRANCH       ?=

SERVICES ?= $(shell $(SVC_FIELD) --list-local | tr '\n' ' ')
override SERVICES := $(shell $(SVC_FIELD) --expand $(SERVICES))

# Where a service's repo is cloned: ../<dir>/<service> (`dir:` in services.yaml, default Services).
define dir_for
$(SVC_FIELD) --dir $(1)
endef

# Branch of a service: BRANCH=... for all, else its `branch:` from services.local.yaml (empty: leave as is).
define branch_for
if [ -n "$(BRANCH)" ]; then echo "$(BRANCH)"; else $(SVC_FIELD) $(1) branch; fi
endef

.DEFAULT_GOAL := help
.PHONY: help network gen traefik-up traefik-down redis-cli status check clone checkout run up stop down ps secrets rekey claude-md

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "SERVICES=$(SERVICES)"

claude-md: ## Create ../CLAUDE.md: every Claude Code session under Laba/ then loads AGENTS.md of this repo
	@if [ -e ../CLAUDE.md ]; then echo "../CLAUDE.md already exists, left as is"; \
	else printf '# CLAUDE.md\n\n@Traefik/AGENTS.md\n' > ../CLAUDE.md && echo "created ../CLAUDE.md -> Traefik/AGENTS.md"; fi

network: ## Create laba_network if it does not exist
	@docker network inspect $(NETWORK) >/dev/null 2>&1 || docker network create $(NETWORK)

gen: ## Generate the Traefik aliases and staging fallback routers from services.yaml
	@python3 bin/gen-traefik

traefik-up: network gen ## Start (or update) Traefik, the shared Redis (laba_redis) and its UI: used by all services
	docker compose up -d
	@echo "Traefik dashboard: http://traefik.localhost:$${TRAEFIK_DASHBOARD_PORT:-8080}/dashboard/"
	@echo "Shared Redis: redis://laba_redis:6379 (services), 127.0.0.1:$${REDIS_PORT:-6379} (host)"
	@echo "Redis UI (Redis Insight): http://redis.localhost"
	@echo "Mails of development (Mailpit): http://mail.localhost, SMTP laba_mailpit:1025"

traefik-down: ## Stop Traefik, the shared Redis and its UI
	docker compose down

redis-cli: ## Open redis-cli of the shared Redis (laba_redis)
	docker exec -it laba_redis redis-cli

status: ## State of every Laba repository: uncommitted, unpushed, commits after the last tag
	@python3 bin/laba-status

check: ## Check services.yaml: duplicate db_port / host, unknown group members
	@$(SVC_FIELD) --check

clone: ## Clone the SERVICES not cloned yet into ../<dir>/ (default ../Services/), at their branch
	@for s in $(SERVICES); do \
		d=$$($(call dir_for,$$s)) || exit 1; \
		of=$$($(SVC_FIELD) $$s instance_of); \
		if [ -n "$$of" ]; then echo "--- $$s: an instance of $$of, run from its repo"; continue; fi; \
		if [ -d "$$d" ]; then \
			echo "--- $$s: already cloned in $$d (branch $$(git -C $$d branch --show-current)), 'make checkout' switches it"; \
			continue; \
		fi; \
		repo=$$($(SVC_FIELD) $$s repo) || exit 1; \
		[ -n "$$repo" ] || { echo "$$s: no 'repo' in services.yaml" >&2; exit 1; }; \
		b=$$($(call branch_for,$$s)); \
		echo "--- $$s: cloning git@github.com:$$repo.git $${b:+@ $$b}"; \
		mkdir -p "$$(dirname "$$d")"; \
		git clone $${b:+-b "$$b"} "git@github.com:$$repo.git" "$$d" || exit 1; \
	done

checkout: ## Switch the cloned SERVICES to their branch (services.local.yaml or BRANCH=...)
	@for s in $(SERVICES); do \
		d=$$($(call dir_for,$$s)) || exit 1; \
		[ -d "$$d" ] || { echo "$$s: not cloned, 'make clone' uses its branch" >&2; exit 1; }; \
		[ -z "$$($(SVC_FIELD) $$s instance_of)" ] || continue; \
		b=$$($(call branch_for,$$s)); \
		if [ -z "$$b" ]; then echo "--- $$s: no branch set, left as is"; continue; fi; \
		echo "--- $$s: checkout $$b"; \
		git -C "$$d" fetch origin "$$b" && git -C "$$d" checkout "$$b" || exit 1; \
	done

run: clone up ## Clone what is missing, then start Traefik + SERVICES

up: check traefik-up secrets ## Start Traefik + SERVICES (each through its own `make up`)
	@for s in $(SERVICES); do \
		d=$$($(call dir_for,$$s)) || exit 1; \
		[ -d "$$d" ] || { echo "$$s: not cloned, run: make clone SERVICES=$$s" >&2; exit 1; }; \
		b=$$($(call branch_for,$$s)); current=$$(git -C "$$d" branch --show-current); \
		if [ -n "$$b" ] && [ "$$current" != "$$b" ]; then echo "WARNING: $$s is on '$$current', not '$$b': make checkout SERVICES=$$s"; fi; \
		echo "--- $$s: up"; \
		r=$$($(SVC_FIELD) $$s region); \
		if [ -n "$$($(SVC_FIELD) $$s instance_of)" ]; then \
			$(MAKE) --no-print-directory -C "$$d" region-up r=$$r cpus=$$($(SVC_FIELD) $$s cpus) || exit 1; \
		else \
			$(MAKE) --no-print-directory -C "$$d" up NO_TRAEFIK=1 || exit 1; \
		fi; \
		echo "    http://$$($(SVC_FIELD) $$s local_host)"; \
	done

stop: ## Stop SERVICES, keeping their containers (Docker Desktop still lists them)
	@for s in $(SERVICES); do \
		r=$$($(SVC_FIELD) $$s region); \
		$(MAKE) --no-print-directory -C "$$($(call dir_for,$$s))" $$([ -n "$$($(SVC_FIELD) $$s instance_of)" ] && echo "region-stop r=$$r" || echo stop) || exit 1; \
	done

down: ## Stop and remove SERVICES' containers (Traefik keeps running)
	@for s in $(SERVICES); do \
		r=$$($(SVC_FIELD) $$s region); \
		$(MAKE) --no-print-directory -C "$$($(call dir_for,$$s))" $$([ -n "$$($(SVC_FIELD) $$s instance_of)" ] && echo "region-down r=$$r" || echo down) || exit 1; \
	done

ps: ## Containers on laba_network
	@docker network inspect $(NETWORK) --format '{{range .Containers}}{{println .Name}}{{end}}' 2>/dev/null | sort

secrets: ## Write the inter-service API keys of SERVICES into their .env.local
	@for s in $(SERVICES); do python3 bin/svc-secret $$s || true; done

rekey: ## After changing SERVICE's api_keys in services.local.yaml: update it and its callers (make rekey SERVICE=cms)
	@[ -n "$(SERVICE)" ] || { echo "usage: make rekey SERVICE=<service whose api_keys changed>" >&2; exit 1; }
	python3 bin/svc-secret --changed $(SERVICE)
