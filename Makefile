SHELL := /bin/bash
.DEFAULT_GOAL := help

BINARY ?= bin/auth-sim
IMAGE ?= capacity-cascade/auth-sim:dev
SCENARIO ?=
K6_SCRIPTS := smoke baseline latency bad-retry good-retry probe reset l01 l02
L01_HAPROXY_IMAGE ?= haproxy:3.2.23-alpine
L01_TOXIPROXY_IMAGE ?= ghcr.io/shopify/toxiproxy:2.12.0
L02_ENVOY_IMAGE ?= envoyproxy/envoy:v1.39.1

.PHONY: help doctor fmt fmt-check lint test build run k6-check smoke scenario docker-build docker-smoke verify clean l01-doctor l01-check l01-smoke l01-verify l01-scenario l01-clean l02-doctor l02-check l02-smoke l02-verify l02-scenario l02-clean

help: ## 사용 가능한 대상을 표시합니다.
	@awk 'BEGIN {FS = ":.*## "; print "대상:"} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

doctor: ## 필요한 로컬 도구와 버전을 확인합니다.
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

fmt: ## Go 소스 코드의 형식을 맞춥니다.
	gofmt -w cmd internal

fmt-check: ## Go 소스 코드의 형식이 맞지 않으면 실패합니다.
	@files="$$(gofmt -l cmd internal)"; \
	if [[ -n "$$files" ]]; then printf '%s\n' "$$files"; exit 1; fi

lint: ## go vet을 실행합니다.
	go vet ./...

test: ## Go 테스트를 실행합니다.
	go test ./...

build: ## auth-sim을 빌드합니다.
	@mkdir -p "$(dir $(BINARY))"
	go build -trimpath -o "$(BINARY)" ./cmd/auth-sim

run: build ## 현재 LAB_* 환경 변수로 auth-sim을 실행합니다.
	"$(BINARY)"

k6-check: ## 모든 k6 스크립트의 문법과 옵션 오류를 검사합니다.
	@for script in $(K6_SCRIPTS); do \
		printf 'inspect load/k6/%s.js\n' "$$script"; \
		k6 inspect "load/k6/$$script.js" >/dev/null; \
	done

smoke: build ## 짧은 로컬 smoke 시나리오를 실행합니다.
	AUTH_SIM_BIN="$(BINARY)" scripts/run-local-scenario.sh smoke

scenario: build ## 로컬 증거 수집 래퍼로 SCENARIO를 실행합니다.
	@if [[ -z "$(SCENARIO)" ]]; then \
		printf 'SCENARIO is required (baseline|latency|bad-retry|good-retry)\n' >&2; \
		exit 2; \
	fi
	AUTH_SIM_BIN="$(BINARY)" scripts/run-local-scenario.sh "$(SCENARIO)"

docker-build: ## 버전이 명시된 auth-sim 이미지를 빌드합니다.
	docker build --tag "$(IMAGE)" .

docker-smoke: ## 이미지에 health/readiness/token 최소 smoke를 실행합니다.
	IMAGE="$(IMAGE)" scripts/docker-smoke.sh

verify: fmt-check lint test build k6-check smoke ## 부하 시나리오를 제외한 L00 검증을 실행합니다.

l01-doctor: ## L01에 필요한 Docker Compose와 HTTP 도구를 확인합니다.
	@missing=0; \
	for tool in git go k6 docker curl awk tee make; do \
		if ! command -v "$$tool" >/dev/null 2>&1; then printf '%-16s MISSING\n' "$$tool"; missing=1; else printf '%-16s OK\n' "$$tool"; fi; \
	done; \
	if ! docker compose version >/dev/null 2>&1; then printf '%-16s MISSING\n' 'docker compose'; missing=1; else printf '%-16s OK\n' 'docker compose'; fi; \
	if ! docker info >/dev/null 2>&1; then printf '%-16s UNAVAILABLE\n' 'docker daemon'; missing=1; else printf '%-16s OK\n' 'docker daemon'; fi; \
	exit $$missing

l01-check: l01-doctor ## L01 Compose, HAProxy, k6, shell 구성을 정적으로 검사합니다.
	AUTH_SIM_IMAGE="$(IMAGE)" HAPROXY_IMAGE="$(L01_HAPROXY_IMAGE)" TOXIPROXY_IMAGE="$(L01_TOXIPROXY_IMAGE)" docker compose --file l01/compose.yaml config --quiet
	docker run --rm --entrypoint haproxy --volume "$(CURDIR)/l01/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" "$(L01_HAPROXY_IMAGE)" -c -f /usr/local/etc/haproxy/haproxy.cfg
	k6 inspect load/k6/l01.js >/dev/null
	bash -n scripts/run-l01-scenario.sh

l01-smoke: docker-build ## 두 L01 정상 경로를 짧게 실행하고 cleanup contract를 확인합니다.
	LOGICAL_RATE=1 DURATION=1s AUTH_SIM_IMAGE="$(IMAGE)" HAPROXY_IMAGE="$(L01_HAPROXY_IMAGE)" TOXIPROXY_IMAGE="$(L01_TOXIPROXY_IMAGE)" scripts/run-l01-scenario.sh haproxy-control
	LOGICAL_RATE=1 DURATION=1s AUTH_SIM_IMAGE="$(IMAGE)" HAPROXY_IMAGE="$(L01_HAPROXY_IMAGE)" TOXIPROXY_IMAGE="$(L01_TOXIPROXY_IMAGE)" scripts/run-l01-scenario.sh toxiproxy-control

l01-verify: l01-check l01-smoke ## 정적 검사와 두 정상 경로 smoke를 bounded 실행합니다.

l01-scenario: docker-build ## SCENARIO으로 독립 L01 scenario와 evidence 수집을 실행합니다.
	@if [[ -z "$(SCENARIO)" ]]; then \
		printf 'SCENARIO is required (haproxy-control|haproxy-constrained|toxiproxy-control|toxiproxy-latency|toxiproxy-reset-peer)\n' >&2; \
		exit 2; \
	fi
	AUTH_SIM_IMAGE="$(IMAGE)" HAPROXY_IMAGE="$(L01_HAPROXY_IMAGE)" TOXIPROXY_IMAGE="$(L01_TOXIPROXY_IMAGE)" scripts/run-l01-scenario.sh "$(SCENARIO)"

l01-clean: ## 이 repository의 L01 Compose project만 정리하고 evidence는 보존합니다.
	@scripts/run-l01-scenario.sh clean

l02-doctor: ## L02에 필요한 Docker Compose와 HTTP/stat 처리 도구를 확인합니다.
	@missing=0; \
	for tool in git go k6 docker curl awk tee grep sed wc tr make; do \
		if ! command -v "$$tool" >/dev/null 2>&1; then printf '%-16s MISSING\n' "$$tool"; missing=1; else printf '%-16s OK\n' "$$tool"; fi; \
	done; \
	if ! docker compose version >/dev/null 2>&1; then printf '%-16s MISSING\n' 'docker compose'; missing=1; else printf '%-16s OK\n' 'docker compose'; fi; \
	if ! docker info >/dev/null 2>&1; then printf '%-16s UNAVAILABLE\n' 'docker daemon'; missing=1; else printf '%-16s OK\n' 'docker daemon'; fi; \
	exit $$missing

l02-check: l02-doctor ## L02 Compose, Envoy config, k6, shell 구성을 정적으로 검사합니다.
	AUTH_SIM_IMAGE="$(IMAGE)" ENVOY_IMAGE="$(L02_ENVOY_IMAGE)" docker compose --file l02/compose.yaml config --quiet
	docker run --rm --volume "$(CURDIR)/l02/envoy.yaml:/etc/envoy/envoy.yaml:ro" "$(L02_ENVOY_IMAGE)" --mode validate -c /etc/envoy/envoy.yaml
	k6 inspect load/k6/l02.js >/dev/null
	bash -n scripts/run-l02-scenario.sh

l02-smoke: docker-build ## Envoy control path를 1 ops/s, 1s로 실행하고 cleanup contract를 확인합니다.
	LOGICAL_RATE=1 DURATION=1s AUTH_SIM_IMAGE="$(IMAGE)" ENVOY_IMAGE="$(L02_ENVOY_IMAGE)" scripts/run-l02-scenario.sh envoy-control

l02-verify: l02-check l02-smoke ## L02 정적 검사와 bounded control smoke를 실행합니다.

l02-scenario: docker-build ## SCENARIO으로 독립 L02 scenario와 evidence 수집을 실행합니다.
	@if [[ -z "$(SCENARIO)" ]]; then \
		printf 'SCENARIO is required (envoy-control|envoy-timeout|envoy-retry-disabled|envoy-retry-bounded|envoy-circuit-breaker)\n' >&2; \
		exit 2; \
	fi
	AUTH_SIM_IMAGE="$(IMAGE)" ENVOY_IMAGE="$(L02_ENVOY_IMAGE)" scripts/run-l02-scenario.sh "$(SCENARIO)"

l02-clean: ## 이 repository의 L02 Compose project만 정리하고 evidence는 보존합니다.
	@scripts/run-l02-scenario.sh clean

clean: ## 실험 증거를 보존하고 생성된 바이너리를 제거합니다.
	rm -f "$(BINARY)"
	@rmdir "$(dir $(BINARY))" 2>/dev/null || true
