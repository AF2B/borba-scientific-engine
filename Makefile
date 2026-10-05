# Developer workflow for the Borba Scientific Engine. Run `make help` to list the available targets.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

# --- Tooling -------------------------------------------------------------------------------------------
SWIFT     ?= swift
DOCKER    ?= docker
COMPOSE   ?= $(DOCKER) compose
SWIFTLINT ?= swiftlint

# --- Project layout ------------------------------------------------------------------------------------
PRODUCT          := borba-scientific-engine
IMAGE_REPOSITORY ?= $(PRODUCT)
ARTIFACTS_DIR    := .artifacts
BENCHMARK_DIR    := $(ARTIFACTS_DIR)/benchmarks
ENV_FILE         := .env
ENV_EXAMPLE      := .env.example
FORMAT_PATHS     := Package.swift Sources Tests

# The integration tests create and drop their own databases on this server, so it needs a role that may do so.
TEST_DATABASE_URL ?= $(DATABASE_URL)

# --- Build metadata baked into the container image -----------------------------------------------------
APP_VERSION    ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo 0.0.0-dev)
APP_COMMIT     ?= $(shell git rev-parse HEAD 2>/dev/null || echo unknown)
APP_BUILD_DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
IMAGE          ?= $(IMAGE_REPOSITORY):$(APP_VERSION)

# Load .env (when present) so `make run` works without exporting variables by hand.
ifneq (,$(wildcard $(ENV_FILE)))
include $(ENV_FILE)
export
endif

.DEFAULT_GOAL := help

##@ Help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN { FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n" } \
		/^[a-zA-Z0-9_-]+:.*##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Setup

.PHONY: setup
setup: ## Prepare a fresh checkout: toolchain check, .env file and dependency resolution
	@./Scripts/check-toolchain.sh
	@test -f $(ENV_FILE) || { cp $(ENV_EXAMPLE) $(ENV_FILE); echo "Created $(ENV_FILE) from $(ENV_EXAMPLE)"; }
	$(SWIFT) package resolve

$(ENV_FILE):
	cp $(ENV_EXAMPLE) $(ENV_FILE)

##@ Build and run

.PHONY: build
build: ## Compile the debug configuration
	$(SWIFT) build

.PHONY: build-release
build-release: ## Compile the release configuration shipped in the container image
	$(SWIFT) build --configuration release --product $(PRODUCT)

.PHONY: run
run: $(ENV_FILE) migrate ## Run the API locally against the Compose PostgreSQL (applies migrations first)
	$(SWIFT) run $(PRODUCT) serve

.PHONY: migrate
migrate: $(ENV_FILE) db-up ## Apply the database migrations to the local PostgreSQL
	$(SWIFT) run $(PRODUCT) migrate --yes

.PHONY: db-up
db-up: $(ENV_FILE) ## Start PostgreSQL only and wait until it is healthy
	$(COMPOSE) up --detach --wait postgres

##@ Quality

.PHONY: test
test: test-unit test-contract test-integration ## Run every test suite

.PHONY: test-unit
test-unit: ## Run the unit tests (no external services required)
	$(SWIFT) test --filter UnitTests

.PHONY: test-contract
test-contract: ## Run the HTTP contract tests against the OpenAPI document (in-memory adapters, no services needed)
	$(SWIFT) test --filter ContractTests

.PHONY: test-report
test-report: ## Run the fast suites and report the slowest tests and the time per suite (XML in .artifacts/test-reports)
	Scripts/test-report.sh

.PHONY: coverage
coverage: db-up ## Run every suite with coverage and enforce the minimum line coverage per source target
	TEST_DATABASE_URL="$(TEST_DATABASE_URL)" Scripts/coverage.sh

.PHONY: benchmark
benchmark: db-up ## Run the benchmarks in release mode; tables are printed and JSON is written to .artifacts/benchmarks
	rm -rf $(BENCHMARK_DIR)
	TEST_DATABASE_URL="$(TEST_DATABASE_URL)" BENCHMARK_OUTPUT_DIR="$(abspath $(BENCHMARK_DIR))" \
		$(SWIFT) test --configuration release -Xswiftc -enable-testing --filter PerformanceTests

.PHONY: smoke-shutdown
smoke-shutdown: build migrate ## Check graceful shutdown: SIGTERM with requests in flight must drop none of them
	DATABASE_URL="$(DATABASE_URL)" Scripts/smoke-graceful-shutdown.sh

.PHONY: test-integration
test-integration: db-up ## Run the integration tests against a real PostgreSQL (starts it when needed)
	TEST_DATABASE_URL="$(TEST_DATABASE_URL)" $(SWIFT) test --filter IntegrationTests

.PHONY: lint
lint: ## Run SwiftLint in strict mode
	$(SWIFTLINT) lint --strict

.PHONY: format
format: ## Format the sources in place
	$(SWIFT) format format --in-place --recursive $(FORMAT_PATHS)

.PHONY: format-check
format-check: ## Fail when the sources are not formatted
	$(SWIFT) format lint --strict --recursive $(FORMAT_PATHS)

.PHONY: ci
ci: format-check lint build test ## Run the checks the CI pipeline enforces

##@ Container

.PHONY: docker-build
docker-build: ## Build the production container image
	$(DOCKER) build \
		--build-arg APP_VERSION=$(APP_VERSION) \
		--build-arg APP_COMMIT=$(APP_COMMIT) \
		--build-arg APP_BUILD_DATE=$(APP_BUILD_DATE) \
		--tag $(IMAGE) \
		.

.PHONY: smoke-container
smoke-container: docker-build ## Check the image through Compose: unprivileged, read-only, healthy, stops gracefully
	IMAGE="$(IMAGE)" Scripts/smoke-container.sh

.PHONY: docker-up
docker-up: $(ENV_FILE) ## Build and start the full stack (API + PostgreSQL) in the background
	$(COMPOSE) up --build --detach --wait

.PHONY: up
up: docker-up ## Alias for docker-up

.PHONY: docker-down
docker-down: ## Stop the stack and remove its containers (data volume is kept)
	$(COMPOSE) down

.PHONY: down
down: docker-down ## Alias for docker-down

.PHONY: logs
logs: ## Follow the logs of the stack
	$(COMPOSE) logs --follow --tail=100

##@ Housekeeping

.PHONY: clean
clean: ## Remove build output and generated reports
	$(SWIFT) package clean
	rm -rf .build $(ARTIFACTS_DIR)
