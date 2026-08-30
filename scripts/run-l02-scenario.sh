#!/usr/bin/env bash
# 명령 실패, 미정의 변수, pipeline 중간 실패를 즉시 반영한다.
set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly COMPOSE_FILE="${PROJECT_ROOT}/l02/compose.yaml"
readonly SCENARIO="${1:-}"
readonly AUTH_SIM_IMAGE="${AUTH_SIM_IMAGE:-capacity-cascade/auth-sim:dev}"
readonly ENVOY_IMAGE="${ENVOY_IMAGE:-envoyproxy/envoy:v1.39.1}"
readonly ENVOY_SERVICE_TIME_MS="${ENVOY_SERVICE_TIME_MS:-250}"
readonly LOGICAL_RATE_VALUE="${LOGICAL_RATE:-20}"
readonly DURATION_VALUE="${DURATION:-4s}"
readonly REQUEST_TIMEOUT_VALUE="${REQUEST_TIMEOUT:-1s}"

cd "${PROJECT_ROOT}"

clean_owned_projects() {
  # 고정 prefix의 Compose label을 가진 이 L02 runner의 resource만 정리한다.
  local projects
  projects="$({
    docker ps -a --filter label=com.docker.compose.project --format '{{.Label "com.docker.compose.project"}}'
    docker network ls --filter label=com.docker.compose.project --format '{{.Label "com.docker.compose.project"}}'
  } | awk '/^capacity-cascade-l02-[a-z0-9_-]+$/ && !seen[$0]++')"
  while IFS= read -r project; do
    if [[ -n "${project}" ]]; then
      docker compose --project-name "${project}" --file "${COMPOSE_FILE}" down --remove-orphans --timeout 5
    fi
  done <<<"${projects}"
}

if [[ "${SCENARIO}" == "clean" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    printf 'required tool is missing: docker\n' >&2
    exit 127
  fi
  clean_owned_projects
  exit 0
fi

case "${SCENARIO}" in
  envoy-control|envoy-timeout|envoy-retry-disabled|envoy-retry-bounded|envoy-circuit-breaker) ;;
  *)
    printf 'usage: %s {envoy-control|envoy-timeout|envoy-retry-disabled|envoy-retry-bounded|envoy-circuit-breaker|clean}\n' "$0" >&2
    exit 2
    ;;
esac

if [[ ! "${ENVOY_SERVICE_TIME_MS}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'ENVOY_SERVICE_TIME_MS must be a positive integer\n' >&2
  exit 2
fi
if [[ ! "${LOGICAL_RATE_VALUE}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'LOGICAL_RATE must be a positive integer\n' >&2
  exit 2
fi
if [[ ! "${DURATION_VALUE}" =~ ^[1-9][0-9]*(ms|s|m)$ ]]; then
  printf 'DURATION must be a positive k6 duration such as 500ms, 4s, or 1m\n' >&2
  exit 2
fi
if [[ ! "${REQUEST_TIMEOUT_VALUE}" =~ ^[1-9][0-9]*(ms|s|m)$ ]]; then
  printf 'REQUEST_TIMEOUT must be a positive k6 duration such as 500ms, 1s, or 1m\n' >&2
  exit 2
fi

# Result directory나 container를 만들기 전에 필요한 local tool과 daemon을 확인한다.
for required_tool in git go k6 docker curl awk tee grep sed wc tr; do
  if ! command -v "${required_tool}" >/dev/null 2>&1; then
    printf 'required tool is missing: %s\n' "${required_tool}" >&2
    exit 127
  fi
done
docker info >/dev/null
docker compose version >/dev/null

case "${SCENARIO}" in
  envoy-control)
    listener_port=10000
    listener_name=l02_control_listener
    route_name=l02_control_routes
    cluster_name=l02_control_cluster
    stat_prefix=l02_control
    route_timeout=2s
    retry_on=none
    num_retries=0
    max_requests=100
    application_latency_ms="${ENVOY_SERVICE_TIME_MS}"
    application_error_rate=0
    ;;
  envoy-timeout)
    listener_port=10001
    listener_name=l02_timeout_listener
    route_name=l02_timeout_routes
    cluster_name=l02_timeout_cluster
    stat_prefix=l02_timeout
    route_timeout=100ms
    retry_on=none
    num_retries=0
    max_requests=100
    application_latency_ms="${ENVOY_SERVICE_TIME_MS}"
    application_error_rate=0
    ;;
  envoy-retry-disabled)
    listener_port=10002
    listener_name=l02_retry_disabled_listener
    route_name=l02_retry_disabled_routes
    cluster_name=l02_retry_disabled_cluster
    stat_prefix=l02_retry_disabled
    route_timeout=2s
    retry_on=none
    num_retries=0
    max_requests=100
    application_latency_ms=0
    application_error_rate=1
    ;;
  envoy-retry-bounded)
    listener_port=10003
    listener_name=l02_retry_bounded_listener
    route_name=l02_retry_bounded_routes
    cluster_name=l02_retry_bounded_cluster
    stat_prefix=l02_retry_bounded
    route_timeout=2s
    retry_on=5xx
    num_retries=2
    max_requests=100
    application_latency_ms=0
    application_error_rate=1
    ;;
  envoy-circuit-breaker)
    listener_port=10004
    listener_name=l02_circuit_breaker_listener
    route_name=l02_circuit_breaker_routes
    cluster_name=l02_circuit_breaker_cluster
    stat_prefix=l02_circuit_breaker
    route_timeout=2s
    retry_on=none
    num_retries=0
    max_requests=1
    application_latency_ms="${ENVOY_SERVICE_TIME_MS}"
    application_error_rate=0
    ;;
esac

readonly ENVOY_MAX_CONNECTIONS=100
readonly ENVOY_MAX_PENDING_REQUESTS=100
readonly ENVOY_MAX_RETRIES=100

# 각 실행은 고유 UTC timestamp directory와 Compose project를 사용한다.
started_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
result_parent="results/${SCENARIO}"
result_dir="${result_parent}/${timestamp}"
suffix=1
while [[ -e "${result_dir}" ]]; do
  result_dir="${result_parent}/${timestamp}-${suffix}"
  suffix=$((suffix + 1))
done
mkdir -p "${result_dir}"

project_name="capacity-cascade-l02-${timestamp,,}-$$"
admin_token="local-${RANDOM}-${RANDOM}-$$"
auth_admin_url=""
envoy_admin_url=""
base_url=""
envoy_version="unknown"
envoy_image_digest="unknown"
compose_started=false
auth_reset=null
compose_down=null
scenario_exit=null
contract_exit=null

export AUTH_SIM_IMAGE ENVOY_IMAGE
export LAB_ADMIN_TOKEN="${admin_token}"
compose=(docker compose --project-name "${project_name}" --file "${COMPOSE_FILE}")

cleanup() {
  local original_exit=$?
  local cleanup_failed=false
  local remaining_containers=0
  local remaining_networks=0
  trap - EXIT
  set +e

  # 성공·실패·signal 경로 모두 application fault를 정상 snapshot으로 되돌린다.
  if [[ -n "${auth_admin_url}" ]]; then
    if curl --fail --silent --show-error --request PUT \
      --header "Authorization: Bearer ${admin_token}" \
      --header 'Content-Type: application/json' \
      --data '{"latency_ms":0,"error_rate":0,"max_in_flight":0,"seed":17082026}' \
      "${auth_admin_url}/admin/fault" >"${result_dir}/auth-sim-reset-response.json"; then
      if curl --fail --silent --show-error "${auth_admin_url}/admin/fault" \
        >"${result_dir}/auth-sim-state-after-reset.json" \
        && grep -Eq '"latency_ms"[[:space:]]*:[[:space:]]*0' "${result_dir}/auth-sim-state-after-reset.json" \
        && grep -Eq '"error_rate"[[:space:]]*:[[:space:]]*0' "${result_dir}/auth-sim-state-after-reset.json" \
        && grep -Eq '"max_in_flight"[[:space:]]*:[[:space:]]*0' "${result_dir}/auth-sim-state-after-reset.json"; then
        auth_reset=true
      else
        auth_reset=false
        cleanup_failed=true
      fi
    else
      auth_reset=false
      cleanup_failed=true
    fi
  fi

  # Failed run도 두 component log를 남긴 뒤 이 project만 제거한다.
  if [[ "${compose_started}" == true ]]; then
    "${compose[@]}" logs --no-color auth-sim >"${result_dir}/auth-sim.log" 2>&1
    "${compose[@]}" logs --no-color envoy >"${result_dir}/envoy.log" 2>&1
    if "${compose[@]}" down --remove-orphans --timeout 5 >/dev/null; then
      compose_down=true
    else
      compose_down=false
      cleanup_failed=true
    fi
  fi

  remaining_containers="$(docker ps -a --filter "label=com.docker.compose.project=${project_name}" --quiet | wc -l | tr -d ' ')"
  remaining_networks="$(docker network ls --filter "label=com.docker.compose.project=${project_name}" --quiet | wc -l | tr -d ' ')"
  if [[ "${remaining_containers}" -ne 0 || "${remaining_networks}" -ne 0 ]]; then
    cleanup_failed=true
  fi

  printf '{\n  "scenario_exit": %s,\n  "contract_exit": %s,\n  "runner_exit_before_cleanup": %s,\n  "auth_sim_reset": %s,\n  "compose_down": %s,\n  "remaining_containers": %s,\n  "remaining_networks": %s\n}\n' \
    "${scenario_exit}" "${contract_exit}" "${original_exit}" "${auth_reset}" "${compose_down}" \
    "${remaining_containers}" "${remaining_networks}" >"${result_dir}/cleanup.json"
  printf 'Result: %s\n' "${result_dir}"

  # Scenario가 성공했더라도 reset/down/resource cleanup 실패는 contract 실패다.
  if [[ "${original_exit}" -eq 0 && "${cleanup_failed}" == true ]]; then
    exit 1
  fi
  exit "${original_exit}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

published_port() {
  local service=$1
  local container_port=$2
  local binding
  binding="$("${compose[@]}" port "${service}" "${container_port}")"
  printf '%s' "${binding##*:}"
}

wait_for_url() {
  local url=$1
  for _ in {1..50}; do
    if curl --fail --silent --show-error "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

put_application_fault() {
  local body=$1
  local output=$2
  curl --fail --silent --show-error --request PUT \
    --header "Authorization: Bearer ${admin_token}" \
    --header 'Content-Type: application/json' \
    --data "${body}" "${auth_admin_url}/admin/fault" >"${output}"
}

k6_metric_value() {
  local metric=$1
  local value=$2
  awk -v metric="\"${metric}\"" -v value="\"${value}\"" '
    $0 ~ metric "[[:space:]]*:" { in_metric=1; next }
    in_metric && $0 ~ value "[[:space:]]*:" {
      line=$0
      sub(/^.*:[[:space:]]*/, "", line)
      sub(/,.*/, "", line)
      print line
      exit
    }
  ' "${result_dir}/k6-summary.json"
}

envoy_stat_value() {
  local file=$1
  local metric=$2
  awk -F': ' -v metric="${metric}" '$1 == metric { print $2; found=1; exit } END { if (!found) print 0 }' "${file}"
}

application_metric_sum() {
  local file=$1
  local metric=$2
  local label_filter=$3
  local second_filter=${4:-}
  awk -v metric="${metric}" -v label_filter="${label_filter}" -v second_filter="${second_filter}" '
    index($0, metric) == 1 && index($0, label_filter) > 0 \
      && (second_filter == "" || index($0, second_filter) > 0) && $0 !~ /^#/ { sum += $NF }
    END { printf "%.0f", sum + 0 }
  ' "${file}"
}

collect_envoy_stats() {
  local phase=$1
  local full_file="${result_dir}/envoy-stats-${phase}.txt"
  local filtered_file="${result_dir}/envoy-stats-${phase}-filtered.txt"
  curl --fail --silent --show-error "${envoy_admin_url}/stats" >"${full_file}"
  awk -v cluster="cluster.${cluster_name}." -v http="http.${stat_prefix}." \
    'index($0, cluster) == 1 || index($0, http) == 1' "${full_file}" >"${filtered_file}"
  curl --fail --silent --show-error --get \
    --data-urlencode "filter=^(cluster\\.${cluster_name}\\.|http\\.${stat_prefix}\\.)" \
    --data-urlencode 'format=prometheus' "${envoy_admin_url}/stats" \
    >"${result_dir}/envoy-stats-${phase}.prom"
}

wait_for_envoy_idle() {
  local stats active pending downstream
  for _ in {1..50}; do
    stats="$(curl --fail --silent --show-error --get \
      --data-urlencode "filter=^(cluster\\.${cluster_name}\\.upstream_rq_(active|pending_active)|http\\.${stat_prefix}\\.downstream_rq_active)$" \
      "${envoy_admin_url}/stats")"
    active="$(printf '%s\n' "${stats}" | awk -F': ' -v key="cluster.${cluster_name}.upstream_rq_active" '$1 == key { print $2+0; found=1 } END { if (!found) print 0 }')"
    pending="$(printf '%s\n' "${stats}" | awk -F': ' -v key="cluster.${cluster_name}.upstream_rq_pending_active" '$1 == key { print $2+0; found=1 } END { if (!found) print 0 }')"
    downstream="$(printf '%s\n' "${stats}" | awk -F': ' -v key="http.${stat_prefix}.downstream_rq_active" '$1 == key { print $2+0; found=1 } END { if (!found) print 0 }')"
    if [[ "${active}" -eq 0 && "${pending}" -eq 0 && "${downstream}" -eq 0 ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

compose_started=true
"${compose[@]}" up --detach --no-build auth-sim envoy

admin_port="$(published_port auth-sim 9090)"
envoy_admin_port="$(published_port envoy 9901)"
workload_port="$(published_port envoy "${listener_port}")"
auth_admin_url="http://127.0.0.1:${admin_port}"
envoy_admin_url="http://127.0.0.1:${envoy_admin_port}"
base_url="http://127.0.0.1:${workload_port}"

if ! wait_for_url "${auth_admin_url}/admin/fault"; then
  printf 'auth-sim admin plane did not become ready\n' >&2
  exit 1
fi
if ! wait_for_url "${envoy_admin_url}/ready"; then
  printf 'Envoy admin plane did not become ready\n' >&2
  exit 1
fi

# 이전 application 상태를 먼저 reset한 뒤 scenario의 완전한 fault snapshot을 적용한다.
put_application_fault '{"latency_ms":0,"error_rate":0,"max_in_flight":0,"seed":17082026}' \
  "${result_dir}/auth-sim-reset-before.json"
put_application_fault "{\"latency_ms\":${application_latency_ms},\"error_rate\":${application_error_rate},\"max_in_flight\":0,\"seed\":17082026}" \
  "${result_dir}/auth-sim-state-applied.json"

if ! wait_for_url "${base_url}/readyz"; then
  printf 'selected Envoy workload path did not become ready\n' >&2
  exit 1
fi

envoy_version="$("${compose[@]}" exec --no-TTY envoy envoy --version | awk 'NF { print; exit }')"
envoy_image_digest="$(docker image inspect "${ENVOY_IMAGE}" --format '{{index .RepoDigests 0}}' 2>/dev/null || printf 'unknown')"
printf '%s\n' "${envoy_version}" >"${result_dir}/envoy-version.txt"
printf '%s\n' "${envoy_image_digest}" >"${result_dir}/envoy-image-digest.txt"

# Application snapshot을 먼저 경유시킨 뒤 Envoy before를 찍어 관찰 request가 delta에 포함되지 않게 한다.
curl --fail --silent --show-error "${base_url}/metrics" >"${result_dir}/auth-sim-metrics-before.prom"
collect_envoy_stats before

git_commit="$(git rev-parse HEAD 2>/dev/null || printf 'unborn')"
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then git_dirty=true; else git_dirty=false; fi

export BASE_URL="${base_url}"
export RESULT_DIR="${result_dir}"
export STARTED_AT_UTC="${started_at_utc}"
export GIT_COMMIT="${git_commit}"
export GIT_DIRTY="${git_dirty}"
export GO_VERSION="$(go version)"
export K6_VERSION="$(k6 version | head -n 1)"
export DOCKER_VERSION="$(docker version --format '{{.Client.Version}}')"
export DOCKER_COMPOSE_VERSION="$(docker compose version --short)"
export ENVOY_VERSION="${envoy_version}"
export LAB_OS="$(uname -s)"
export LAB_ARCH="$(uname -m)"
export L02_SCENARIO="${SCENARIO}"
export REQUEST_PATH="k6 -> ${listener_name} -> ${route_name} -> ${cluster_name} -> auth-sim"
export REQUEST_TIMEOUT="${REQUEST_TIMEOUT_VALUE}"
export LOGICAL_RATE="${LOGICAL_RATE_VALUE}"
export DURATION="${DURATION_VALUE}"
export APPLICATION_LATENCY_MS="${application_latency_ms}"
export ENVOY_LISTENER="${listener_name}"
export ENVOY_ROUTE="${route_name}"
export ENVOY_CLUSTER="${cluster_name}"
export ENVOY_STAT_PREFIX="${stat_prefix}"
export ENVOY_ROUTE_TIMEOUT="${route_timeout}"
export ENVOY_RETRY_ON="${retry_on}"
export ENVOY_NUM_RETRIES="${num_retries}"
export ENVOY_MAX_CONNECTIONS
export ENVOY_MAX_PENDING_REQUESTS
export ENVOY_MAX_REQUESTS="${max_requests}"
export ENVOY_MAX_RETRIES

# k6 실패는 orchestration 실패와 분리하고, 이후 snapshot과 contract 수집을 계속한다.
set +e
k6 run load/k6/l02.js 2>&1 | tee "${result_dir}/k6.log"
scenario_exit=${PIPESTATUS[0]}
set -e

if ! wait_for_envoy_idle; then
  printf 'Envoy request gauges did not return to idle before after snapshot\n' >&2
  exit 1
fi
collect_envoy_stats after
curl --fail --silent --show-error "${base_url}/metrics" >"${result_dir}/auth-sim-metrics-after.prom"

before_stats="${result_dir}/envoy-stats-before-filtered.txt"
after_stats="${result_dir}/envoy-stats-after-filtered.txt"
downstream_metric="http.${stat_prefix}.downstream_rq_total"
upstream_metric="cluster.${cluster_name}.upstream_rq_total"
retry_metric="cluster.${cluster_name}.upstream_rq_retry"
retry_limit_metric="cluster.${cluster_name}.upstream_rq_retry_limit_exceeded"
timeout_metric="cluster.${cluster_name}.upstream_rq_timeout"
active_overflow_metric="cluster.${cluster_name}.upstream_rq_active_overflow"
pending_overflow_metric="cluster.${cluster_name}.upstream_rq_pending_overflow"
retry_overflow_metric="cluster.${cluster_name}.upstream_rq_retry_overflow"
pending_total_metric="cluster.${cluster_name}.upstream_rq_pending_total"

downstream_before="$(envoy_stat_value "${before_stats}" "${downstream_metric}")"
downstream_after="$(envoy_stat_value "${after_stats}" "${downstream_metric}")"
upstream_before="$(envoy_stat_value "${before_stats}" "${upstream_metric}")"
upstream_after="$(envoy_stat_value "${after_stats}" "${upstream_metric}")"
retry_before="$(envoy_stat_value "${before_stats}" "${retry_metric}")"
retry_after="$(envoy_stat_value "${after_stats}" "${retry_metric}")"
retry_limit_before="$(envoy_stat_value "${before_stats}" "${retry_limit_metric}")"
retry_limit_after="$(envoy_stat_value "${after_stats}" "${retry_limit_metric}")"
timeout_before="$(envoy_stat_value "${before_stats}" "${timeout_metric}")"
timeout_after="$(envoy_stat_value "${after_stats}" "${timeout_metric}")"
active_overflow_before="$(envoy_stat_value "${before_stats}" "${active_overflow_metric}")"
active_overflow_after="$(envoy_stat_value "${after_stats}" "${active_overflow_metric}")"
pending_overflow_before="$(envoy_stat_value "${before_stats}" "${pending_overflow_metric}")"
pending_overflow_after="$(envoy_stat_value "${after_stats}" "${pending_overflow_metric}")"
retry_overflow_before="$(envoy_stat_value "${before_stats}" "${retry_overflow_metric}")"
retry_overflow_after="$(envoy_stat_value "${after_stats}" "${retry_overflow_metric}")"
pending_total_before="$(envoy_stat_value "${before_stats}" "${pending_total_metric}")"
pending_total_after="$(envoy_stat_value "${after_stats}" "${pending_total_metric}")"

downstream_delta=$((downstream_after - downstream_before))
upstream_delta=$((upstream_after - upstream_before))
retry_delta=$((retry_after - retry_before))
retry_limit_delta=$((retry_limit_after - retry_limit_before))
timeout_delta=$((timeout_after - timeout_before))
active_overflow_delta=$((active_overflow_after - active_overflow_before))
pending_overflow_delta=$((pending_overflow_after - pending_overflow_before))
retry_overflow_delta=$((retry_overflow_after - retry_overflow_before))
pending_total_delta=$((pending_total_after - pending_total_before))
overflow_delta=$((active_overflow_delta + pending_overflow_delta + retry_overflow_delta))

printf '{\n  "scenario": "%s",\n  "stat_prefix": "%s",\n  "cluster": "%s",\n  "metrics": {\n    "downstream_requests": "%s",\n    "upstream_attempts": "%s",\n    "retries": "%s",\n    "retry_limit_exceeded": "%s",\n    "timeouts": "%s",\n    "active_overflow": "%s",\n    "pending_overflow": "%s",\n    "retry_overflow": "%s",\n    "pending_total": "%s"\n  },\n  "delta": {\n    "downstream_requests": %s,\n    "upstream_attempts": %s,\n    "retries": %s,\n    "retry_limit_exceeded": %s,\n    "timeouts": %s,\n    "active_overflow": %s,\n    "pending_overflow": %s,\n    "retry_overflow": %s,\n    "overflow_total": %s,\n    "pending_total": %s\n  }\n}\n' \
  "${SCENARIO}" "${stat_prefix}" "${cluster_name}" "${downstream_metric}" "${upstream_metric}" \
  "${retry_metric}" "${retry_limit_metric}" "${timeout_metric}" "${active_overflow_metric}" "${pending_overflow_metric}" \
  "${retry_overflow_metric}" "${pending_total_metric}" "${downstream_delta}" "${upstream_delta}" \
  "${retry_delta}" "${retry_limit_delta}" "${timeout_delta}" "${active_overflow_delta}" "${pending_overflow_delta}" \
  "${retry_overflow_delta}" "${overflow_delta}" "${pending_total_delta}" \
  >"${result_dir}/envoy-stats-delta.json"

app_before="${result_dir}/auth-sim-metrics-before.prom"
app_after="${result_dir}/auth-sim-metrics-after.prom"
app_token_before="$(application_metric_sum "${app_before}" capacity_cascade_http_requests_total 'route="/token"')"
app_token_after="$(application_metric_sum "${app_after}" capacity_cascade_http_requests_total 'route="/token"')"
app_token_2xx_before="$(application_metric_sum "${app_before}" capacity_cascade_http_requests_total 'route="/token"' 'status_class="2xx"')"
app_token_2xx_after="$(application_metric_sum "${app_after}" capacity_cascade_http_requests_total 'route="/token"' 'status_class="2xx"')"
app_token_5xx_before="$(application_metric_sum "${app_before}" capacity_cascade_http_requests_total 'route="/token"' 'status_class="5xx"')"
app_token_5xx_after="$(application_metric_sum "${app_after}" capacity_cascade_http_requests_total 'route="/token"' 'status_class="5xx"')"
app_token_delta=$((app_token_after - app_token_before))
app_token_2xx_delta=$((app_token_2xx_after - app_token_2xx_before))
app_token_5xx_delta=$((app_token_5xx_after - app_token_5xx_before))

printf '{\n  "metrics": {\n    "token_requests": "capacity_cascade_http_requests_total{route=/token}",\n    "token_2xx": "capacity_cascade_http_requests_total{route=/token,status_class=2xx}",\n    "token_5xx": "capacity_cascade_http_requests_total{route=/token,status_class=5xx}"\n  },\n  "before": {"token_requests": %s, "token_2xx": %s, "token_5xx": %s},\n  "after": {"token_requests": %s, "token_2xx": %s, "token_5xx": %s},\n  "delta": {"token_requests": %s, "token_2xx": %s, "token_5xx": %s}\n}\n' \
  "${app_token_before}" "${app_token_2xx_before}" "${app_token_5xx_before}" \
  "${app_token_after}" "${app_token_2xx_after}" "${app_token_5xx_after}" \
  "${app_token_delta}" "${app_token_2xx_delta}" "${app_token_5xx_delta}" \
  >"${result_dir}/auth-sim-metrics-delta.json"

contract_exit=0
logical_count="$(k6_metric_value logical_requests count)"
physical_count="$(k6_metric_value physical_attempts count)"
retry_count="$(k6_metric_value retry_attempts count)"
logical_failure_rate="$(k6_metric_value logical_failures rate)"
status_200="$(k6_metric_value downstream_responses_200 count)"
status_503="$(k6_metric_value downstream_responses_503 count)"
status_504="$(k6_metric_value downstream_responses_504 count)"
retry_count="${retry_count:-0}"
status_200="${status_200:-0}"
status_503="${status_503:-0}"
status_504="${status_504:-0}"

if [[ -z "${logical_count}" || "${logical_count}" -le 0 || "${logical_count}" != "${physical_count}" ]]; then
  printf 'no-retry counter contract failed: logical=%s physical=%s\n' "${logical_count:-missing}" "${physical_count:-missing}" >&2
  contract_exit=1
fi
if [[ "${retry_count}" != 0 ]]; then
  printf 'k6 retry_attempts must remain zero: %s\n' "${retry_count}" >&2
  contract_exit=1
fi
if [[ -n "${logical_count}" && "${downstream_delta}" -ne "${logical_count}" ]]; then
  printf 'Envoy downstream delta differs from k6 logical count: downstream=%s logical=%s\n' "${downstream_delta}" "${logical_count}" >&2
  contract_exit=1
fi

case "${SCENARIO}" in
  envoy-control)
    if ! awk -v value="${logical_failure_rate:-1}" 'BEGIN { exit !(value == 0) }' \
      || [[ "${retry_delta}" -ne 0 || "${timeout_delta}" -ne 0 || "${overflow_delta}" -ne 0 ]]; then
      printf 'Envoy control signal contract failed\n' >&2
      contract_exit=1
    fi
    ;;
  envoy-timeout)
    if [[ "${timeout_delta}" -le 0 || "${retry_delta}" -ne 0 ]] \
      || ! awk -v value="${logical_failure_rate:-0}" 'BEGIN { exit !(value > 0) }'; then
      printf 'Envoy timeout signal contract failed\n' >&2
      contract_exit=1
    fi
    ;;
  envoy-retry-disabled)
    if [[ "${retry_delta}" -ne 0 || "${upstream_delta}" -ne "${physical_count:-0}" ]]; then
      printf 'Envoy retry-disabled attempt contract failed\n' >&2
      contract_exit=1
    fi
    ;;
  envoy-retry-bounded)
    retry_bound=$((${physical_count:-0} * num_retries))
    if [[ "${retry_delta}" -le 0 || "${retry_limit_delta}" -le 0 \
      || "${upstream_delta}" -le "${physical_count:-0}" || "${retry_delta}" -gt "${retry_bound}" ]]; then
      printf 'Envoy bounded retry attempt contract failed\n' >&2
      contract_exit=1
    fi
    ;;
  envoy-circuit-breaker)
    # v1.39.1에서 max_requests 소진의 authoritative counter는 active_overflow다.
    if [[ "${active_overflow_delta}" -le 0 ]] \
      || ! awk -v value="${logical_failure_rate:-0}" 'BEGIN { exit !(value > 0) }'; then
      printf 'Envoy circuit-breaker signal contract failed\n' >&2
      contract_exit=1
    fi
    ;;
esac

contract_passed=false
if [[ "${contract_exit}" -eq 0 ]]; then contract_passed=true; fi
printf '{\n  "passed": %s,\n  "scenario_exit": %s,\n  "contract_exit": %s,\n  "logical_requests": %s,\n  "physical_attempts": %s,\n  "k6_retry_attempts": %s,\n  "downstream_status": {"200": %s, "503": %s, "504": %s}\n}\n' \
  "${contract_passed}" "${scenario_exit}" "${contract_exit}" "${logical_count:-0}" "${physical_count:-0}" \
  "${retry_count}" "${status_200}" "${status_503}" "${status_504}" >"${result_dir}/contract.json"

upstream_amplification="$(awk -v upstream="${upstream_delta}" -v logical="${logical_count:-0}" 'BEGIN { if (logical > 0) printf "%.3f", upstream/logical; else print "n/a" }')"
cat >>"${result_dir}/summary.md" <<EOF

## Envoy / application delta

| Observer metric | Delta |
| --- | ---: |
| Envoy downstream requests | ${downstream_delta} |
| Envoy upstream attempts | ${upstream_delta} |
| Envoy upstream attempt amplification | ${upstream_amplification}x |
| Envoy retries | ${retry_delta} |
| Envoy retry limit exceeded | ${retry_limit_delta} |
| Envoy timeouts | ${timeout_delta} |
| Envoy active overflow | ${active_overflow_delta} |
| Envoy pending overflow | ${pending_overflow_delta} |
| Envoy retry overflow | ${retry_overflow_delta} |
| Envoy pending requests | ${pending_total_delta} |
| auth-sim token requests | ${app_token_delta} |

Metric 이름과 before/after absolute value는 \`envoy-stats-delta.json\`과
\`auth-sim-metrics-delta.json\`에 보존했다. 이 값은 단일 local exploratory evidence다.
EOF

if [[ "${scenario_exit}" -ne 0 ]]; then
  exit "${scenario_exit}"
fi
exit "${contract_exit}"
