SHELL := /bin/bash
.DEFAULT_GOAL := help

BINARY ?= bin/auth-sim
IMAGE ?= capacity-cascade/auth-sim:dev
SCENARIO ?=
K6_SCRIPTS := smoke baseline latency bad-retry good-retry probe reset l01 l02 l04
L01_HAPROXY_IMAGE ?= haproxy:3.2.23-alpine
L01_TOXIPROXY_IMAGE ?= ghcr.io/shopify/toxiproxy:2.12.0
L02_ENVOY_IMAGE ?= envoyproxy/envoy:v1.39.1
L03_K3S_IMAGE ?= rancher/k3s:v1.35.5-k3s1
L03_CHART ?= charts/auth-sim
L03_RENDER_REPOSITORY ?= capacity-cascade/auth-sim
L03_RENDER_TAG ?= l03-dev
L04_ISTIO_VERSION ?= 1.30.4
L04_K6_IMAGE ?= grafana/k6:2.2.0
L04_K3S_IMAGE ?= $(L03_K3S_IMAGE)

.PHONY: help doctor fmt fmt-check lint test build run k6-check smoke scenario docker-build docker-smoke verify clean l01-doctor l01-check l01-smoke l01-verify l01-scenario l01-clean l02-doctor l02-check l02-smoke l02-verify l02-scenario l02-clean l03-doctor l03-check l03-smoke l03-verify l03-clean l04-doctor l04-check l04-smoke l04-scenario l04-verify l04-clean

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

l03-doctor: ## L03에 필요한 k3d, Kubernetes, Helm, Docker와 기존 도구를 확인합니다.
	@missing=0; \
	for tool in git go k6 docker kubectl k3d helm make curl awk sed grep wc tr; do \
		if ! command -v "$$tool" >/dev/null 2>&1; then printf '%-16s MISSING\n' "$$tool"; missing=1; else printf '%-16s OK\n' "$$tool"; fi; \
	done; \
	if ! docker info >/dev/null 2>&1; then printf '%-16s UNAVAILABLE\n' 'docker daemon'; missing=1; else printf '%-16s OK\n' 'docker daemon'; fi; \
	if command -v k3d >/dev/null 2>&1; then k3d version; fi; \
	if command -v kubectl >/dev/null 2>&1; then kubectl version --client; fi; \
	if command -v helm >/dev/null 2>&1; then helm version --short; fi; \
	exit $$missing

l03-check: l03-doctor ## L03 chart, rendered manifest, k6 재사용과 runner를 정적으로 검사합니다.
	@set -euo pipefail; \
	rendered="$$(mktemp)"; \
	trap 'rm -f "$$rendered"' EXIT; \
	helm lint "$(L03_CHART)" --set-string image.repository="$(L03_RENDER_REPOSITORY)" --set-string image.tag="$(L03_RENDER_TAG)"; \
	helm template auth-sim "$(L03_CHART)" --namespace capacity-cascade-l03 \
		--set-string image.repository="$(L03_RENDER_REPOSITORY)" \
		--set-string image.tag="$(L03_RENDER_TAG)" >"$$rendered"; \
	if grep -Eq 'image:[[:space:]].*:latest([[:space:]]|$$)' "$$rendered"; then printf 'latest image is forbidden\n' >&2; exit 1; fi; \
	if grep -Eq '^kind:[[:space:]]+Secret$$' "$$rendered"; then printf 'chart must not render Secret data\n' >&2; exit 1; fi; \
	grep -q 'name: LAB_ADMIN_TOKEN' "$$rendered"; \
	grep -q 'secretKeyRef:' "$$rendered"; \
	grep -q 'type: ClusterIP' "$$rendered"; \
	if grep -Eq 'replace-with|LAB_ADMIN_TOKEN_PLACEHOLDER|local-[0-9]+-[0-9]+' "$$rendered"; then printf 'secret placeholder rendered\n' >&2; exit 1; fi
	@case "$(L03_K3S_IMAGE)" in *:latest|latest) printf 'latest K3s image is forbidden\n' >&2; exit 1 ;; *:*) ;; *) printf 'K3s image must have an explicit tag\n' >&2; exit 1 ;; esac
	k6 inspect load/k6/smoke.js >/dev/null
	bash -n scripts/run-l03-baseline.sh

l03-smoke: l03-check ## Clean bootstrap부터 L00 smoke와 L03 cleanup contract까지 실행합니다.
	K3S_IMAGE="$(L03_K3S_IMAGE)" scripts/run-l03-baseline.sh run

l03-verify: l03-smoke ## L03 static check와 bounded lifecycle을 한 번 실행합니다.

l03-clean: ## exact L03 cluster만 정리하고 evidence는 보존합니다.
	@K3S_IMAGE="$(L03_K3S_IMAGE)" scripts/run-l03-baseline.sh clean

l04-doctor: ## L04에 필요한 Istio/sidecar lifecycle 및 JSON/stat 처리 도구를 확인합니다.
	@missing=0; \
	for tool in git go k6 docker kubectl k3d helm curl awk sed grep jq ruby tee wc tr mktemp sha256sum diff cmp sort find ps make; do \
		if ! command -v "$$tool" >/dev/null 2>&1; then printf '%-16s MISSING\n' "$$tool"; missing=1; else printf '%-16s OK\n' "$$tool"; fi; \
	done; \
	if ! docker info >/dev/null 2>&1; then printf '%-16s UNAVAILABLE\n' 'docker daemon'; missing=1; else printf '%-16s OK\n' 'docker daemon'; fi; \
	if command -v k3d >/dev/null 2>&1; then k3d version; fi; \
	if command -v kubectl >/dev/null 2>&1; then kubectl version --client; fi; \
	if command -v helm >/dev/null 2>&1; then helm version --short; fi; \
	if command -v k6 >/dev/null 2>&1; then k6 version | head -n 1; fi; \
	exit $$missing

l04-check: l04-doctor ## L04 pinned charts, manifests, k6, scope와 runner를 정적으로 검사합니다.
	@set -euo pipefail; \
	tmp="$$(mktemp -d "$${TMPDIR:-/tmp}/capacity-cascade-l04-check.XXXXXX")"; \
	cleanup_l04_check() { find "$$tmp" -depth -delete; }; \
	trap cleanup_l04_check EXIT; \
	export HELM_CONFIG_HOME="$$tmp/helm-config" HELM_CACHE_HOME="$$tmp/helm-cache" HELM_DATA_HOME="$$tmp/helm-data"; \
	mkdir -p "$$HELM_CONFIG_HOME" "$$HELM_CACHE_HOME" "$$HELM_DATA_HOME"; \
	helm lint "$(L03_CHART)" --set-string image.repository="$(L03_RENDER_REPOSITORY)" --set-string image.tag="l04-check"; \
	helm template auth-sim-control "$(L03_CHART)" --namespace capacity-cascade-l04-control \
		--set-string image.repository="$(L03_RENDER_REPOSITORY)" --set-string image.tag="l04-check" >"$$tmp/auth-sim.yaml"; \
	helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null; \
	helm repo update istio >/dev/null; \
	helm show chart istio/base --version "$(L04_ISTIO_VERSION)" >"$$tmp/base-chart.yaml"; \
	helm show chart istio/istiod --version "$(L04_ISTIO_VERSION)" >"$$tmp/istiod-chart.yaml"; \
	helm template istio-base istio/base --version "$(L04_ISTIO_VERSION)" --namespace istio-system \
		--set defaultRevision=default --kube-version 1.35.5 >"$$tmp/base.yaml"; \
	helm template istiod istio/istiod --version "$(L04_ISTIO_VERSION)" --namespace istio-system \
		--values l04/istiod-values.yaml --kube-version 1.35.5 >"$$tmp/istiod.yaml"; \
	grep -q "version: $(L04_ISTIO_VERSION)" "$$tmp/base-chart.yaml"; \
	grep -q "version: $(L04_ISTIO_VERSION)" "$$tmp/istiod-chart.yaml"; \
	if grep -ERq ':latest|[[:space:]]latest[[:space:]]' l04 load/k6/l04.js; then printf 'latest is forbidden in L04\n' >&2; exit 1; fi; \
	if grep -Eq 'image:[[:space:]].*:latest' "$$tmp/base.yaml" "$$tmp/istiod.yaml" "$$tmp/auth-sim.yaml"; then printf 'rendered latest image is forbidden\n' >&2; exit 1; fi; \
	if grep -Eq '^kind: (Gateway|GatewayClass|HorizontalPodAutoscaler|DaemonSet|ScaledObject)$$' "$$tmp/base.yaml" "$$tmp/istiod.yaml" l04/*.yaml; then printf 'out-of-scope resource rendered\n' >&2; exit 1; fi; \
	if grep -ERq '^kind: (ProxyConfig|VirtualService|DestinationRule)$$' l04; then printf 'unexpected L04 traffic/proxy resource\n' >&2; exit 1; fi; \
	if [[ "$$(grep -ERc '^kind: EnvoyFilter$$' l04/retry-disabled-*.yaml | awk -F: '{sum += $$2} END {print sum+0}')" -ne 2 ]]; then printf 'expected the bounded retry-disable EnvoyFilter pair\n' >&2; exit 1; fi; \
	grep -q 'context: SIDECAR_INBOUND' l04/retry-disabled-control.yaml; \
	grep -q 'applyTo: VIRTUAL_HOST' l04/retry-disabled-control.yaml; \
	grep -q 'operation: REPLACE' l04/retry-disabled-control.yaml; \
	if grep -q 'retry_policy:' l04/retry-disabled-*.yaml; then printf 'retry-disable replacement must omit retry_policy\n' >&2; exit 1; fi; \
	if grep -ERq '(^|[[:space:]])concurrency:' l04; then printf 'ProxyConfig concurrency is not an active-request limit\n' >&2; exit 1; fi; \
	if grep -ERq 'replace-with|LAB_ADMIN_TOKEN_PLACEHOLDER|local-[0-9]+-[0-9]+' l04 "$$tmp/auth-sim.yaml"; then printf 'secret literal or placeholder found\n' >&2; exit 1; fi; \
	grep -q 'http2MaxRequests: 100' l04/sidecar-control.yaml; \
	grep -q 'http2MaxRequests: 1' l04/sidecar-constrained.yaml; \
	sed -E '/namespace:/d; /app.kubernetes.io\/instance:/d; s/http2MaxRequests: [0-9]+/http2MaxRequests: TARGET/' l04/sidecar-control.yaml >"$$tmp/control-normalized.yaml"; \
	sed -E '/namespace:/d; /app.kubernetes.io\/instance:/d; s/http2MaxRequests: [0-9]+/http2MaxRequests: TARGET/' l04/sidecar-constrained.yaml >"$$tmp/constrained-normalized.yaml"; \
	cmp -s "$$tmp/control-normalized.yaml" "$$tmp/constrained-normalized.yaml"; \
	sed -E '/namespace:/d; /app.kubernetes.io\/instance:/d; /# Istio 1.30.4 HTTP_ROUTE/,/# inbound virtual host preserves its one route without retry_policy./d; /# Control과 동일한/,/# Comparison variable은 inbound active-request capacity 하나다./d; s/capacity-cascade-l04-(control|constrained)/capacity-cascade-l04-SCENARIO/' l04/retry-disabled-control.yaml >"$$tmp/retry-control-normalized.yaml"; \
	sed -E '/namespace:/d; /app.kubernetes.io\/instance:/d; /# Istio 1.30.4 HTTP_ROUTE/,/# inbound virtual host preserves its one route without retry_policy./d; /# Control과 동일한/,/# Comparison variable은 inbound active-request capacity 하나다./d; s/capacity-cascade-l04-(control|constrained)/capacity-cascade-l04-SCENARIO/' l04/retry-disabled-constrained.yaml >"$$tmp/retry-constrained-normalized.yaml"; \
	cmp -s "$$tmp/retry-control-normalized.yaml" "$$tmp/retry-constrained-normalized.yaml"; \
	ruby -e 'require "yaml"; ARGV.each { |f| d=YAML.safe_load_file(f, aliases: true); abort("invalid Sidecar manifest: #{f}") unless d["apiVersion"]=="networking.istio.io/v1" && d["kind"]=="Sidecar" && d.dig("spec","ingress",0,"port","number")==8080 && d.dig("spec","ingress",0,"connectionPool","http","http2MaxRequests").is_a?(Integer) }' l04/sidecar-control.yaml l04/sidecar-constrained.yaml; \
	ruby -e 'require "yaml"; ARGV.each { |f| d=YAML.safe_load_file(f, aliases: true); p=d.dig("spec","configPatches",0); route=p.dig("patch","value","routes",0,"route"); abort("invalid retry-disable manifest: #{f}") unless d["apiVersion"]=="networking.istio.io/v1alpha3" && d["kind"]=="EnvoyFilter" && p["applyTo"]=="VIRTUAL_HOST" && p.dig("match","context")=="SIDECAR_INBOUND" && p.dig("patch","operation")=="REPLACE" && route["cluster"]=="inbound|8080||" && !route.key?("retry_policy") }' l04/retry-disabled-control.yaml l04/retry-disabled-constrained.yaml; \
	k6 inspect load/k6/l04.js >/dev/null; \
	bash -n scripts/run-l04-sidecar.sh

l04-smoke: l04-check ## Control sidecar injection/datapath와 cleanup을 1 ops/s, 1s lifecycle로 확인합니다.
	LOGICAL_RATE=1 DURATION=1s ISTIO_VERSION="$(L04_ISTIO_VERSION)" K6_IMAGE="$(L04_K6_IMAGE)" K3S_IMAGE="$(L04_K3S_IMAGE)" scripts/run-l04-sidecar.sh smoke

l04-scenario: l04-check ## SCENARIO의 fresh sidecar 단일 lifecycle과 evidence를 생성합니다.
	@if [[ "$(SCENARIO)" != "sidecar-control" && "$(SCENARIO)" != "sidecar-constrained" ]]; then \
		printf 'SCENARIO is required (sidecar-control|sidecar-constrained)\n' >&2; \
		exit 2; \
	fi
	ISTIO_VERSION="$(L04_ISTIO_VERSION)" K6_IMAGE="$(L04_K6_IMAGE)" K3S_IMAGE="$(L04_K3S_IMAGE)" scripts/run-l04-sidecar.sh "$(SCENARIO)"

l04-verify: l04-check ## Control/constrained pair를 한 cluster lifecycle에서 한 번 실행합니다.
	ISTIO_VERSION="$(L04_ISTIO_VERSION)" K6_IMAGE="$(L04_K6_IMAGE)" K3S_IMAGE="$(L04_K3S_IMAGE)" scripts/run-l04-sidecar.sh pair

l04-clean: ## exact L04 cluster/process만 정리하고 evidence는 보존합니다.
	@ISTIO_VERSION="$(L04_ISTIO_VERSION)" K6_IMAGE="$(L04_K6_IMAGE)" K3S_IMAGE="$(L04_K3S_IMAGE)" scripts/run-l04-sidecar.sh clean

clean: ## 실험 증거를 보존하고 생성된 바이너리를 제거합니다.
	rm -f "$(BINARY)"
	@rmdir "$(dir $(BINARY))" 2>/dev/null || true
