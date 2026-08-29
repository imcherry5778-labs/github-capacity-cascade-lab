SHELL := /bin/bash
.DEFAULT_GOAL := help

BINARY ?= bin/auth-sim
IMAGE ?= capacity-cascade/auth-sim:dev
SCENARIO ?=
K6_SCRIPTS := smoke baseline latency bad-retry good-retry probe reset

.PHONY: help doctor fmt fmt-check lint test build run k6-check smoke scenario docker-build docker-smoke verify clean

help: ## Show available targets.
	@awk 'BEGIN {FS = ":.*## "; print "Targets:"} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

doctor: ## Report required local tools and versions.
	@missing=0; \
	for tool in git go k6 docker make; do \
		if ! command -v "$$tool" >/dev/null 2>&1; then \
			printf '%-8s MISSING\n' "$$tool"; missing=1; continue; \
		fi; \
		case "$$tool" in \
			git) version="$$(git --version)" ;; \
			go) version="$$(go version)" ;; \
			k6) version="$$(k6 version | head -n 1)" ;; \
			docker) version="$$(docker --version)" ;; \
			make) version="$$(make --version | head -n 1)" ;; \
		esac; \
		printf '%-8s %s\n' "$$tool" "$$version"; \
	done; \
	exit $$missing

fmt: ## Format Go source.
	gofmt -w cmd internal

fmt-check: ## Fail when Go source is not formatted.
	@files="$$(gofmt -l cmd internal)"; \
	if [[ -n "$$files" ]]; then printf '%s\n' "$$files"; exit 1; fi

lint: ## Run Go vet.
	go vet ./...

test: ## Run Go tests.
	go test ./...

build: ## Build auth-sim.
	@mkdir -p "$(dir $(BINARY))"
	go build -trimpath -o "$(BINARY)" ./cmd/auth-sim

run: build ## Run auth-sim with current LAB_* environment.
	"$(BINARY)"

k6-check: ## Inspect all k6 scripts for syntax and option errors.
	@for script in $(K6_SCRIPTS); do \
		printf 'inspect load/k6/%s.js\n' "$$script"; \
		k6 inspect "load/k6/$$script.js" >/dev/null; \
	done

smoke: build ## Run the short local smoke scenario.
	AUTH_SIM_BIN="$(BINARY)" scripts/run-local-scenario.sh smoke

scenario: build ## Run SCENARIO through the local evidence wrapper.
	@if [[ -z "$(SCENARIO)" ]]; then \
		printf 'SCENARIO is required (baseline|latency|bad-retry|good-retry)\n' >&2; \
		exit 2; \
	fi
	AUTH_SIM_BIN="$(BINARY)" scripts/run-local-scenario.sh "$(SCENARIO)"

docker-build: ## Build the explicit-version auth-sim image.
	docker build --tag "$(IMAGE)" .

docker-smoke: ## Run a minimal health/readiness/token smoke against the image.
	IMAGE="$(IMAGE)" scripts/docker-smoke.sh

verify: fmt-check lint test build k6-check smoke ## Run bounded L00 verification (not load scenarios).

clean: ## Remove generated binaries, preserving evidence.
	rm -f "$(BINARY)"
	@rmdir "$(dir $(BINARY))" 2>/dev/null || true
