# Local infrastructure of Laba services: Traefik + laba_network + the service registry
# (services.yaml, personal overrides in services.local.yaml). See README.md.
#
# SERVICES: services and/or groups from services.yaml, `all` for every service;
# default: the services listed in services.local.yaml. BRANCH=...: force a branch for all of them.

NETWORK      := laba_network
SERVICES_DIR := ../Services
SVC_FIELD    := python3 bin/svc-field
BRANCH       ?=

SERVICES ?= $(shell $(SVC_FIELD) --list-local | tr '\n' ' ')
override SERVICES := $(shell $(SVC_FIELD) --expand $(SERVICES))

# Branch of a service: BRANCH=... for all, else its `branch:` from services.local.yaml (empty: leave as is).
define branch_for
if [ -n "$(BRANCH)" ]; then echo "$(BRANCH)"; else $(SVC_FIELD) $(1) branch; fi
endef

.DEFAULT_GOAL := help
.PHONY: help network gen traefik-up traefik-down check clone checkout run up stop down ps secrets rekey

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "SERVICES=$(SERVICES)"

network: ## Create laba_network if it does not exist
	@docker network inspect $(NETWORK) >/dev/null 2>&1 || docker network create $(NETWORK)

gen: ## Generate the Traefik aliases and staging fallback routers from services.yaml
	@python3 bin/gen-traefik

traefik-up: network gen ## Start (or update) Traefik: shared by all services
	docker compose up -d
	@echo "Traefik dashboard: http://traefik.localhost:$${TRAEFIK_DASHBOARD_PORT:-8080}/dashboard/"

traefik-down: ## Stop Traefik
	docker compose down

check: ## Check services.yaml: duplicate db_port / host, unknown group members
	@$(SVC_FIELD) --check

clone: ## Clone the SERVICES not cloned yet into ../Services/, at their branch
	@mkdir -p $(SERVICES_DIR)
	@for s in $(SERVICES); do \
		if [ -d "$(SERVICES_DIR)/$$s" ]; then \
			echo "--- $$s: already cloned (branch $$(git -C $(SERVICES_DIR)/$$s branch --show-current)), 'make checkout' switches it"; \
			continue; \
		fi; \
		repo=$$($(SVC_FIELD) $$s repo) || exit 1; \
		[ -n "$$repo" ] || { echo "$$s: no 'repo' in services.yaml" >&2; exit 1; }; \
		b=$$($(call branch_for,$$s)); \
		echo "--- $$s: cloning git@github.com:$$repo.git $${b:+@ $$b}"; \
		git clone $${b:+-b "$$b"} "git@github.com:$$repo.git" "$(SERVICES_DIR)/$$s" || exit 1; \
	done

checkout: ## Switch the cloned SERVICES to their branch (services.local.yaml or BRANCH=...)
	@for s in $(SERVICES); do \
		[ -d "$(SERVICES_DIR)/$$s" ] || { echo "$$s: not cloned, 'make clone' uses its branch" >&2; exit 1; }; \
		b=$$($(call branch_for,$$s)); \
		if [ -z "$$b" ]; then echo "--- $$s: no branch set, left as is"; continue; fi; \
		echo "--- $$s: checkout $$b"; \
		git -C "$(SERVICES_DIR)/$$s" fetch origin "$$b" && git -C "$(SERVICES_DIR)/$$s" checkout "$$b" || exit 1; \
	done

run: clone up ## Clone what is missing, then start Traefik + SERVICES

up: check traefik-up secrets ## Start Traefik + SERVICES (each through its own `make up`)
	@for s in $(SERVICES); do \
		[ -d "$(SERVICES_DIR)/$$s" ] || { echo "$$s: not cloned, run: make clone SERVICES=$$s" >&2; exit 1; }; \
		b=$$($(call branch_for,$$s)); current=$$(git -C "$(SERVICES_DIR)/$$s" branch --show-current); \
		if [ -n "$$b" ] && [ "$$current" != "$$b" ]; then echo "WARNING: $$s is on '$$current', not '$$b': make checkout SERVICES=$$s"; fi; \
		echo "--- $$s: up"; \
		$(MAKE) --no-print-directory -C "$(SERVICES_DIR)/$$s" up NO_TRAEFIK=1 || exit 1; \
		echo "    http://$$($(SVC_FIELD) $$s local_host)"; \
	done

stop: ## Stop SERVICES, keeping their containers (Docker Desktop still lists them)
	@for s in $(SERVICES); do $(MAKE) --no-print-directory -C "$(SERVICES_DIR)/$$s" stop || exit 1; done

down: ## Stop and remove SERVICES' containers (Traefik keeps running)
	@for s in $(SERVICES); do $(MAKE) --no-print-directory -C "$(SERVICES_DIR)/$$s" down || exit 1; done

ps: ## Containers on laba_network
	@docker network inspect $(NETWORK) --format '{{range .Containers}}{{println .Name}}{{end}}' 2>/dev/null | sort

secrets: ## Write the inter-service API keys of SERVICES into their .env.local
	@for s in $(SERVICES); do python3 bin/svc-secret $$s || true; done

rekey: ## After changing SERVICE's api_key in services.local.yaml: update its consumers (make rekey SERVICE=cms)
	@[ -n "$(SERVICE)" ] || { echo "usage: make rekey SERVICE=<service whose api_key changed>" >&2; exit 1; }
	python3 bin/svc-secret --changed $(SERVICE)
