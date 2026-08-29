#!/usr/bin/env bash
# 명령 실패, 미정의 변수, pipeline 중간 실패를 즉시 반영한다.
set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly COMPOSE_FILE="${PROJECT_ROOT}/l01/compose.yaml"
readonly SCENARIO="${1:-}"
readonly AUTH_SIM_IMAGE="${AUTH_SIM_IMAGE:-capacity-cascade/auth-sim:dev}"
readonly HAPROXY_IMAGE="${HAPROXY_IMAGE:-haproxy:3.2.23-alpine}"
readonly TOXIPROXY_IMAGE="${TOXIPROXY_IMAGE:-ghcr.io/shopify/toxiproxy:2.12.0}"
readonly HAPROXY_SERVICE_TIME_MS="${HAPROXY_SERVICE_TIME_MS:-250}"
readonly TOXIPROXY_LATENCY_MS_VALUE="${TOXIPROXY_LATENCY_MS:-150}"

cd "${PROJECT_ROOT}"

clean_owned_projects() {
  # 고정 prefix의 Compose label을 가진 이 runner의 resource만 정리한다.
  local projects
  projects="$({
    docker ps -a --filter label=com.docker.compose.project --format '{{.Label "com.docker.compose.project"}}'
    docker network ls --filter label=com.docker.compose.project --format '{{.Label "com.docker.compose.project"}}'
  } | awk '/^capacity-cascade-l01-[a-z0-9_-]+$/ && !seen[$0]++')"
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
  haproxy-control|haproxy-constrained|toxiproxy-control|toxiproxy-latency|toxiproxy-reset-peer) ;;
  *)
    printf 'usage: %s {haproxy-control|haproxy-constrained|toxiproxy-control|toxiproxy-latency|toxiproxy-reset-peer|clean}\n' "$0" >&2
    exit 2
    ;;
esac

if [[ ! "${HAPROXY_SERVICE_TIME_MS}" =~ ^[0-9]+$ ]] || [[ ! "${TOXIPROXY_LATENCY_MS_VALUE}" =~ ^[0-9]+$ ]]; then
  printf 'latency settings must be non-negative integer milliseconds\n' >&2
  exit 2
fi

# Result directory나 container를 만들기 전에 모든 local dependency와 daemon을 확인한다.
for required_tool in git go k6 docker curl awk tee; do
  if ! command -v "${required_tool}" >/dev/null 2>&1; then
    printf 'required tool is missing: %s\n' "${required_tool}" >&2
    exit 127
  fi
done
docker info >/dev/null
docker compose version >/dev/null

# 각 실행은 고유 UTC timestamp directory와 Compose project를 사용해 다른 실행과 격리한다.
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

project_name="capacity-cascade-l01-${timestamp,,}-$$"
admin_token="local-${RANDOM}-${RANDOM}-$$"
admin_url=""
toxiproxy_api_url=""
base_url=""
stats_url=""
haproxy_version="not-used"
compose_started=false
auth_reset=null
toxiproxy_reset=null
toxics_empty=null

export AUTH_SIM_IMAGE HAPROXY_IMAGE TOXIPROXY_IMAGE
export LAB_ADMIN_TOKEN="${admin_token}"
compose=(docker compose --project-name "${project_name}" --file "${COMPOSE_FILE}")

cleanup() {
  local original_exit=$?
  local cleanup_failed=false
  local compose_down=false
  local remaining_containers=0
  local remaining_networks=0
  trap - EXIT
  set +e

  # 성공·실패·signal 경로 모두 application fault를 먼저 정상 상태로 되돌린다.
  if [[ -n "${admin_url}" ]]; then
    if curl --fail --silent --show-error --request PUT \
      --header "Authorization: Bearer ${admin_token}" \
      --header 'Content-Type: application/json' \
      --data '{"latency_ms":0,"error_rate":0,"max_in_flight":0,"seed":17082026}' \
      "${admin_url}/admin/fault" >"${result_dir}/auth-sim-reset-response.json"; then
      if curl --fail --silent --show-error "${admin_url}/admin/fault" >"${result_dir}/auth-sim-state-after-reset.json" \
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

  # Toxiproxy는 /reset 후 실제 proxy state의 toxic 배열이 비었는지 별도로 확인한다.
  if [[ -n "${toxiproxy_api_url}" ]]; then
    reset_code="$(curl --silent --show-error --output "${result_dir}/toxiproxy-reset-response.txt" \
      --write-out '%{http_code}' --request POST "${toxiproxy_api_url}/reset")"
    if [[ "${reset_code}" == "200" || "${reset_code}" == "204" ]]; then
      toxiproxy_reset=true
    else
      toxiproxy_reset=false
      cleanup_failed=true
    fi
    if curl --fail --silent --show-error "${toxiproxy_api_url}/proxies/auth-sim" \
      >"${result_dir}/toxiproxy-state-after-reset.json" \
      && grep -Eq '"enabled"[[:space:]]*:[[:space:]]*true' "${result_dir}/toxiproxy-state-after-reset.json" \
      && grep -Eq '"toxics"[[:space:]]*:[[:space:]]*\[\]' "${result_dir}/toxiproxy-state-after-reset.json"; then
      toxics_empty=true
    else
      toxics_empty=false
      cleanup_failed=true
    fi
  fi

  # Failed run도 logs와 reset 결과를 남긴 뒤 이 project의 resource만 제거한다.
  if [[ "${compose_started}" == true ]]; then
    "${compose[@]}" logs --no-color auth-sim >"${result_dir}/auth-sim.log" 2>&1
    if [[ "${SCENARIO}" == haproxy-* ]]; then
      "${compose[@]}" logs --no-color haproxy >"${result_dir}/haproxy.log" 2>&1
    else
      "${compose[@]}" logs --no-color toxiproxy >"${result_dir}/toxiproxy.log" 2>&1
    fi
    if "${compose[@]}" down --remove-orphans --timeout 5 >/dev/null; then
      compose_down=true
    else
      cleanup_failed=true
    fi
  fi

  remaining_containers="$(docker ps -a --filter "label=com.docker.compose.project=${project_name}" --quiet | wc -l | tr -d ' ')"
  remaining_networks="$(docker network ls --filter "label=com.docker.compose.project=${project_name}" --quiet | wc -l | tr -d ' ')"
  if [[ "${remaining_containers}" -ne 0 || "${remaining_networks}" -ne 0 ]]; then
    cleanup_failed=true
  fi

  # Secret이나 개인 절대 경로 없이 cleanup contract만 machine-readable evidence로 기록한다.
  printf '{\n  "auth_sim_reset": %s,\n  "toxiproxy_reset": %s,\n  "toxics_empty": %s,\n  "compose_down": %s,\n  "remaining_containers": %s,\n  "remaining_networks": %s\n}\n' \
    "${auth_reset}" "${toxiproxy_reset}" "${toxics_empty}" "${compose_down}" \
    "${remaining_containers}" "${remaining_networks}" >"${result_dir}/cleanup.json"
  printf 'Result: %s\n' "${result_dir}"

  # Scenario가 성공했더라도 reset/cleanup 실패는 L01 contract 실패로 반환한다.
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
    --data "${body}" "${admin_url}/admin/fault" >"${output}"
}

metric_value() {
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

haproxy_queue_was_observed() {
  awk -F, '
    NR == 1 {
      sub(/^#[[:space:]]*/, "", $1)
      for (i=1; i<=NF; i++) column[$i]=i
      next
    }
    $column["pxname"] == "be_l01_constrained" && $column["svname"] == "BACKEND" {
      backend_found=1
      if ($(column["qmax"]) + 0 > 0) queued=1
    }
    $column["pxname"] == "be_l01_constrained" && $column["svname"] == "auth_sim" {
      server_found=1
      if ($(column["smax"]) + 0 >= 2) capacity_reached=1
    }
    END { exit !(backend_found && server_found && queued && capacity_reached) }
  ' "${result_dir}/haproxy-stats.csv"
}

# Scenario마다 필요한 proxy만 시작해 HAProxy와 Toxiproxy를 한 request path에 섞지 않는다.
compose_started=true
if [[ "${SCENARIO}" == haproxy-* ]]; then
  "${compose[@]}" up --detach --no-build auth-sim haproxy
else
  "${compose[@]}" up --detach --no-build auth-sim toxiproxy
fi

admin_port="$(published_port auth-sim 9090)"
admin_url="http://127.0.0.1:${admin_port}"
if ! wait_for_url "${admin_url}/admin/fault"; then
  printf 'auth-sim admin plane did not become ready\n' >&2
  exit 1
fi

# 이전 설정을 먼저 지우고 완전한 application snapshot을 적용한다.
put_application_fault '{"latency_ms":0,"error_rate":0,"max_in_flight":0,"seed":17082026}' \
  "${result_dir}/auth-sim-reset-before.json"
if [[ "${SCENARIO}" == haproxy-* ]]; then
  application_latency_ms="${HAPROXY_SERVICE_TIME_MS}"
else
  application_latency_ms=0
fi
put_application_fault "{\"latency_ms\":${application_latency_ms},\"error_rate\":0,\"max_in_flight\":0,\"seed\":17082026}" \
  "${result_dir}/auth-sim-state-applied.json"

if [[ "${SCENARIO}" == haproxy-* ]]; then
  if [[ "${SCENARIO}" == "haproxy-control" ]]; then
    workload_port="$(published_port haproxy 8080)"
    request_path='k6 -> HAProxy control -> auth-sim'
  else
    workload_port="$(published_port haproxy 8081)"
    request_path='k6 -> HAProxy constrained -> auth-sim'
  fi
  stats_port="$(published_port haproxy 8404)"
  base_url="http://127.0.0.1:${workload_port}"
  stats_url="http://127.0.0.1:${stats_port}"
  if ! wait_for_url "${base_url}/healthz" || ! wait_for_url "${stats_url}/stats;csv"; then
    printf 'HAProxy path or stats plane did not become ready\n' >&2
    exit 1
  fi
  haproxy_version="$("${compose[@]}" exec --no-TTY haproxy haproxy -v | head -n 1)"
  curl --fail --silent --show-error "${stats_url}/stats;csv" >"${result_dir}/haproxy-stats-before.csv"
else
  toxiproxy_api_port="$(published_port toxiproxy 8474)"
  toxiproxy_workload_port="$(published_port toxiproxy 8666)"
  toxiproxy_api_url="http://127.0.0.1:${toxiproxy_api_port}"
  base_url="http://127.0.0.1:${toxiproxy_workload_port}"
  request_path='k6 -> Toxiproxy -> auth-sim'
  if ! wait_for_url "${toxiproxy_api_url}/version"; then
    printf 'Toxiproxy control API did not become ready\n' >&2
    exit 1
  fi
  toxiproxy_version="$(curl --fail --silent --show-error "${toxiproxy_api_url}/version" \
    | awk -F'"' '/"version"/ { print $4 }')"
  curl --fail --silent --show-error --request POST "${toxiproxy_api_url}/reset" >/dev/null
  curl --fail --silent --show-error --request POST \
    --header 'Content-Type: application/json' \
    --data '[{"name":"auth-sim","listen":"0.0.0.0:8666","upstream":"auth-sim:8080","enabled":true}]' \
    "${toxiproxy_api_url}/populate" >"${result_dir}/toxiproxy-state-before.json"
  if ! wait_for_url "${base_url}/healthz"; then
    printf 'Toxiproxy workload path did not become ready\n' >&2
    exit 1
  fi

  if [[ "${SCENARIO}" == "toxiproxy-latency" ]]; then
    curl --fail --silent --show-error --request POST \
      --header 'Content-Type: application/json' \
      --data "{\"name\":\"l01_latency_downstream\",\"type\":\"latency\",\"stream\":\"downstream\",\"toxicity\":1,\"attributes\":{\"latency\":${TOXIPROXY_LATENCY_MS_VALUE},\"jitter\":0}}" \
      "${toxiproxy_api_url}/proxies/auth-sim/toxics" >/dev/null
  elif [[ "${SCENARIO}" == "toxiproxy-reset-peer" ]]; then
    curl --fail --silent --show-error --request POST \
      --header 'Content-Type: application/json' \
      --data '{"name":"l01_reset_peer_downstream","type":"reset_peer","stream":"downstream","toxicity":1,"attributes":{"timeout":0}}' \
      "${toxiproxy_api_url}/proxies/auth-sim/toxics" >/dev/null
  fi
  curl --fail --silent --show-error "${toxiproxy_api_url}/proxies/auth-sim" \
    >"${result_dir}/toxiproxy-state-applied.json"
fi

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
export HAPROXY_VERSION="${haproxy_version}"
export TOXIPROXY_VERSION="${toxiproxy_version:-not-used}"
export LAB_OS="$(uname -s)"
export LAB_ARCH="$(uname -m)"
export L01_SCENARIO="${SCENARIO}"
export REQUEST_PATH="${request_path}"
export REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-1s}"
export APPLICATION_LATENCY_MS="${application_latency_ms}"
export TOXIPROXY_LATENCY_MS="${TOXIPROXY_LATENCY_MS_VALUE}"

# k6 실패 뒤에도 proxy state와 failed evidence를 보존하도록 exit code를 직접 관리한다.
set +e
k6 run load/k6/l01.js 2>&1 | tee "${result_dir}/k6.log"
scenario_exit=${PIPESTATUS[0]}
set -e

if [[ "${SCENARIO}" == haproxy-* ]]; then
  curl --fail --silent --show-error "${stats_url}/stats;csv" >"${result_dir}/haproxy-stats.csv"
  curl --fail --silent --show-error "${stats_url}/metrics" >"${result_dir}/haproxy-metrics.prom"
else
  curl --fail --silent --show-error "${toxiproxy_api_url}/proxies/auth-sim" >"${result_dir}/toxiproxy-state.json"
fi

contract_exit=0
logical_count="$(metric_value logical_requests count)"
physical_count="$(metric_value physical_attempts count)"
logical_failure_rate="$(metric_value logical_failures rate)"
if [[ -z "${logical_count}" || "${logical_count}" != "${physical_count}" ]]; then
  printf 'no-retry counter contract failed: logical=%s physical=%s\n' "${logical_count:-missing}" "${physical_count:-missing}" >&2
  contract_exit=1
fi

if [[ "${SCENARIO}" == "haproxy-constrained" ]]; then
  if ! haproxy_queue_was_observed; then
    printf 'HAProxy constrained run did not record qmax > 0\n' >&2
    contract_exit=1
  fi
  if ! awk -v value="${logical_failure_rate:-0}" 'BEGIN { exit !(value > 0) }'; then
    printf 'HAProxy constrained run did not affect logical outcomes\n' >&2
    contract_exit=1
  fi
elif [[ "${SCENARIO}" == "toxiproxy-latency" ]]; then
  if ! grep -Eq '"type"[[:space:]]*:[[:space:]]*"latency"' "${result_dir}/toxiproxy-state-applied.json" \
    || ! grep -Eq "\"latency\"[[:space:]]*:[[:space:]]*${TOXIPROXY_LATENCY_MS_VALUE}" "${result_dir}/toxiproxy-state-applied.json"; then
    printf 'Toxiproxy latency toxic state does not match requested settings\n' >&2
    contract_exit=1
  fi
elif [[ "${SCENARIO}" == "toxiproxy-reset-peer" ]]; then
  if ! grep -Eq '"type"[[:space:]]*:[[:space:]]*"reset_peer"' "${result_dir}/toxiproxy-state-applied.json"; then
    printf 'Toxiproxy reset_peer toxic was not applied\n' >&2
    contract_exit=1
  fi
  if ! awk -v value="${logical_failure_rate:-0}" 'BEGIN { exit !(value > 0) }'; then
    printf 'Toxiproxy reset_peer did not affect logical outcomes\n' >&2
    contract_exit=1
  fi
fi

if [[ "${scenario_exit}" -ne 0 ]]; then
  exit "${scenario_exit}"
fi
exit "${contract_exit}"
