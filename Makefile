SHELL := /bin/bash
.DEFAULT_GOAL := help

BINARY ?= bin/auth-sim
IMAGE ?= capacity-cascade/auth-sim:dev
SCENARIO ?=
K6_SCRIPTS := smoke baseline latency bad-retry good-retry probe reset

.PHONY: help doctor fmt fmt-check lint test build run k6-check smoke scenario docker-build docker-smoke verify clean

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

clean: ## 실험 증거를 보존하고 생성된 바이너리를 제거합니다.
	rm -f "$(BINARY)"
	@rmdir "$(dir $(BINARY))" 2>/dev/null || true
