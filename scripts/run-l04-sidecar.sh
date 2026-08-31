#!/usr/bin/env bash
# L04는 pinned Istio sidecar의 control/constrained capacity를 한 lifecycle에서 비교한다.
set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ACTION="${1:-pair}"
readonly CHART_DIR="${PROJECT_ROOT}/charts/auth-sim"
readonly ISTIOD_VALUES="${PROJECT_ROOT}/l04/istiod-values.yaml"
readonly CLUSTER_NAME="capacity-cascade-l04"
readonly ISTIO_NAMESPACE="istio-system"
readonly LOAD_NAMESPACE="capacity-cascade-l04-load"
readonly CONTROL_NAMESPACE="capacity-cascade-l04-control"
readonly CONSTRAINED_NAMESPACE="capacity-cascade-l04-constrained"
readonly CONTROL_RELEASE="auth-sim-control"
readonly CONSTRAINED_RELEASE="auth-sim-constrained"
readonly ADMIN_SECRET="auth-sim-admin"
readonly K3S_IMAGE_VALUE="${K3S_IMAGE:-rancher/k3s:v1.35.5-k3s1}"
readonly ISTIO_VERSION_VALUE="${ISTIO_VERSION:-1.30.4}"
readonly K6_IMAGE_VALUE="${K6_IMAGE:-grafana/k6:2.2.0}"
readonly LOGICAL_RATE_VALUE="${LOGICAL_RATE:-20}"
readonly DURATION_VALUE="${DURATION:-4s}"
readonly REQUEST_TIMEOUT_VALUE="${REQUEST_TIMEOUT:-1s}"
readonly APPLICATION_LATENCY_MS_VALUE="${APPLICATION_LATENCY_MS:-250}"
readonly FAULT_SEED_VALUE="${FAULT_SEED:-17082026}"
readonly LOGICAL_ID_NAMESPACE_VALUE="${LOGICAL_ID_NAMESPACE:-l04-sidecar-pair}"
readonly SAMPLE_INTERVAL_SECONDS_VALUE="${SAMPLE_INTERVAL_SECONDS:-0.5}"
readonly CONTROL_CAPACITY=100
readonly CONSTRAINED_CAPACITY=1

cd "${PROJECT_ROOT}"

cluster_exists() {
  k3d cluster list --no-headers 2>/dev/null \
    | awk -v cluster="${CLUSTER_NAME}" '$1 == cluster { found=1 } END { exit !found }'
}

remaining_cluster_containers() {
  docker ps -a --format '{{.Names}}' \
    | awk -v prefix="k3d-${CLUSTER_NAME}-" 'index($0, prefix) == 1 { count++ } END { print count+0 }'
}

remaining_cluster_networks() {
  docker network ls --format '{{.Name}}' \
    | awk -v network="k3d-${CLUSTER_NAME}" '$0 == network { count++ } END { print count+0 }'
}

owned_port_forward_pids() {
  ps -eo pid=,args= | awk '
    /kubectl/ && /port-forward/ && /--namespace capacity-cascade-l04-(control|constrained)/ {
      print $1
    }
  '
}

remaining_owned_processes() {
  owned_port_forward_pids | awk 'NF { count++ } END { print count+0 }'
}

clean_owned_cluster() {
  local pid
  while IFS= read -r pid; do
    if [[ -n "${pid}" && "${pid}" != "$$" ]]; then
      kill -TERM "${pid}" 2>/dev/null || true
    fi
  done < <(owned_port_forward_pids)
  if cluster_exists; then
    k3d cluster delete "${CLUSTER_NAME}"
  fi
  local containers networks processes
  containers="$(remaining_cluster_containers)"
  networks="$(remaining_cluster_networks)"
  processes="$(remaining_owned_processes)"
  if [[ "${containers}" -ne 0 || "${networks}" -ne 0 || "${processes}" -ne 0 ]]; then
    printf 'L04 cleanup incomplete: containers=%s networks=%s processes=%s\n' \
      "${containers}" "${networks}" "${processes}" >&2
    return 1
  fi
  printf 'L04 owned cluster resources and port-forward processes are absent; evidence was preserved.\n'
}

if [[ "${ACTION}" == "clean" ]]; then
  for required_tool in docker k3d awk ps; do
    if ! command -v "${required_tool}" >/dev/null 2>&1; then
      printf 'required tool is missing: %s\n' "${required_tool}" >&2
      exit 127
    fi
  done
  docker info >/dev/null
  clean_owned_cluster
  exit 0
fi

declare -a RUN_SCENARIOS=()
case "${ACTION}" in
  pair)
    RUN_SCENARIOS=(sidecar-control sidecar-constrained)
    ;;
  smoke|sidecar-control)
    RUN_SCENARIOS=(sidecar-control)
    ;;
  sidecar-constrained)
    RUN_SCENARIOS=(sidecar-constrained)
    ;;
  *)
    printf 'usage: %s {pair|smoke|sidecar-control|sidecar-constrained|clean}\n' "$0" >&2
    exit 2
    ;;
esac

for image in "${K3S_IMAGE_VALUE}" "${K6_IMAGE_VALUE}"; do
  case "${image}" in
    *:latest|latest)
      printf 'latest image is forbidden: %s\n' "${image}" >&2
      exit 2
      ;;
    *:*) ;;
    *)
      printf 'image must have an explicit tag: %s\n' "${image}" >&2
      exit 2
      ;;
  esac
done
if [[ ! "${ISTIO_VERSION_VALUE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'ISTIO_VERSION must be an explicit patch version\n' >&2
  exit 2
fi
if [[ ! "${LOGICAL_RATE_VALUE}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'LOGICAL_RATE must be a positive integer\n' >&2
  exit 2
fi
if [[ ! "${APPLICATION_LATENCY_MS_VALUE}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'APPLICATION_LATENCY_MS must be a positive integer\n' >&2
  exit 2
fi
if [[ ! "${FAULT_SEED_VALUE}" =~ ^[0-9]+$ ]]; then
  printf 'FAULT_SEED must be a non-negative integer\n' >&2
  exit 2
fi
for duration in "${DURATION_VALUE}" "${REQUEST_TIMEOUT_VALUE}"; do
  if [[ ! "${duration}" =~ ^[1-9][0-9]*(ms|s|m)$ ]]; then
    printf 'duration must be a positive k6 duration: %s\n' "${duration}" >&2
    exit 2
  fi
done
if [[ ! "${SAMPLE_INTERVAL_SECONDS_VALUE}" =~ ^0\.[1-9][0-9]*$|^[1-9][0-9]*(\.[0-9]+)?$ ]]; then
  printf 'SAMPLE_INTERVAL_SECONDS must be a positive decimal number\n' >&2
  exit 2
fi

for required_tool in git go k6 docker kubectl k3d helm curl awk sed grep jq tee wc tr \
  mktemp sha256sum diff cmp sort find ps make; do
  if ! command -v "${required_tool}" >/dev/null 2>&1; then
    printf 'required tool is missing: %s\n' "${required_tool}" >&2
    exit 127
  fi
done
docker info >/dev/null
if cluster_exists; then
  printf 'refusing to replace existing exact L04 cluster: %s\n' "${CLUSTER_NAME}" >&2
  printf 'run make l04-clean after inspecting that cluster\n' >&2
  exit 1
fi
if [[ "$(remaining_cluster_containers)" -ne 0 || "$(remaining_cluster_networks)" -ne 0 ]]; then
  printf 'refusing to run while exact L04 Docker resources remain\n' >&2
  exit 1
fi
if [[ "$(remaining_owned_processes)" -ne 0 ]]; then
  printf 'refusing to run while exact L04 port-forward processes remain\n' >&2
  exit 1
fi

readonly SOURCE_COMMIT="$(git rev-parse HEAD)"
readonly SOURCE_SHORT="$(git rev-parse --short=12 HEAD)"
readonly IMAGE_REPOSITORY="${AUTH_SIM_REPOSITORY:-capacity-cascade/auth-sim}"
readonly IMAGE_TAG="${AUTH_SIM_TAG:-l04-${SOURCE_SHORT}}"
readonly AUTH_SIM_IMAGE_VALUE="${IMAGE_REPOSITORY}:${IMAGE_TAG}"
case "${AUTH_SIM_IMAGE_VALUE}" in
  *:latest|latest)
    printf 'latest auth-sim image is forbidden: %s\n' "${AUTH_SIM_IMAGE_VALUE}" >&2
    exit 2
    ;;
esac

started_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
result_parent="results/istio-sidecar"
result_dir="${result_parent}/${timestamp}"
suffix=1
while [[ -e "${result_dir}" ]]; do
  result_dir="${result_parent}/${timestamp}-${suffix}"
  suffix=$((suffix + 1))
done
mkdir -p "${result_dir}"
for scenario in "${RUN_SCENARIOS[@]}"; do
  mkdir -p "${result_dir}/${scenario}"
done

original_kubeconfig_set=false
original_kubeconfig_value=""
if [[ -v KUBECONFIG ]]; then
  original_kubeconfig_set=true
  original_kubeconfig_value="${KUBECONFIG}"
fi

read_original_context() {
  local context
  if [[ "${original_kubeconfig_set}" == true ]]; then
    context="$(KUBECONFIG="${original_kubeconfig_value}" kubectl config current-context 2>/dev/null)" || context="__UNSET__"
  else
    context="$(env -u KUBECONFIG kubectl config current-context 2>/dev/null)" || context="__UNSET__"
  fi
  printf '%s' "${context}"
}

file_hash_or_absent() {
  local path=$1
  if [[ -f "${path}" ]]; then
    sha256sum "${path}" | awk '{print $1}'
  else
    printf 'absent'
  fi
}

original_context="$(read_original_context)"
if [[ "${original_context}" == "__UNSET__" ]]; then
  original_context_state="unset"
else
  original_context_state="set"
fi
original_helm_repository_config="$(helm env HELM_REPOSITORY_CONFIG)"
original_helm_repository_hash="$(file_hash_or_absent "${original_helm_repository_config}")"

umask 077
runtime_root="$(mktemp -d "${TMPDIR:-/tmp}/capacity-cascade-l04.XXXXXX")"
kubeconfig_file="${runtime_root}/kubeconfig"
helm_config_home="${runtime_root}/helm-config"
helm_cache_home="${runtime_root}/helm-cache"
helm_data_home="${runtime_root}/helm-data"
chart_dir="${runtime_root}/charts"
mkdir -p "${helm_config_home}" "${helm_cache_home}" "${helm_data_home}" "${chart_dir}"
: >"${kubeconfig_file}"
chmod 600 "${kubeconfig_file}"
export KUBECONFIG="${kubeconfig_file}"
export HELM_CONFIG_HOME="${helm_config_home}"
export HELM_CACHE_HOME="${helm_cache_home}"
export HELM_DATA_HOME="${helm_data_home}"

admin_token="l04-${RANDOM}-${RANDOM}-$$-$(date +%s)"
admin_pf_pid=""
metrics_pf_pid=""
observer_pid=""
observer_stop_file=""
patched_pod=""

cluster_created=false
node_ready=false
images_imported=false
istio_base_deployed=false
istiod_deployed=false
istio_ready=false
load_namespace_created=false
scenario_resources_removed=false
istiod_removed=false
istio_base_removed=false
namespaces_removed=false
cluster_removed=false
temporary_kubeconfig_removed=false
temporary_helm_state_removed=false
original_context_unchanged=false
original_helm_config_unchanged=false
remaining_containers=0
remaining_networks=0
remaining_processes=0
contract_passed=false

git_dirty=false
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then git_dirty=true; fi
git_version="$(git --version | awk '{print $3}')"
go_version="$(go version | awk '{print $3}')"
local_k6_version="$(k6 version | awk 'NR == 1 {print $2}')"
docker_version="$(docker version --format '{{.Client.Version}}')"
k3d_version="$(k3d version | awk 'NR == 1 {print $3}')"
k3d_default_k3s_version="$(k3d version | awk 'NR == 2 {print $3}')"
kubectl_client_version="$(kubectl version --client --output=yaml | awk '$1 == "gitVersion:" {print $2; exit}')"
helm_version="$(helm version --template '{{.Version}}')"
kubernetes_server_version="not-captured"
auth_sim_image_id="not-captured"
k6_image_id="not-captured"
k6_image_digest="not-captured"
istiod_image="not-captured"
istiod_image_id="not-captured"
proxy_image="not-captured"
proxy_image_id="not-captured"
envoy_version="not-captured"
base_chart_sha256="not-captured"
istiod_chart_sha256="not-captured"

declare -A SCENARIO_NAMESPACE=(
  [sidecar-control]="${CONTROL_NAMESPACE}"
  [sidecar-constrained]="${CONSTRAINED_NAMESPACE}"
)
declare -A SCENARIO_RELEASE=(
  [sidecar-control]="${CONTROL_RELEASE}"
  [sidecar-constrained]="${CONSTRAINED_RELEASE}"
)
declare -A SCENARIO_CAPACITY=(
  [sidecar-control]="${CONTROL_CAPACITY}"
  [sidecar-constrained]="${CONSTRAINED_CAPACITY}"
)
declare -A SCENARIO_MANIFEST=(
  [sidecar-control]="${PROJECT_ROOT}/l04/sidecar-control.yaml"
  [sidecar-constrained]="${PROJECT_ROOT}/l04/sidecar-constrained.yaml"
)
declare -A SCENARIO_RETRY_MANIFEST=(
  [sidecar-control]="${PROJECT_ROOT}/l04/retry-disabled-control.yaml"
  [sidecar-constrained]="${PROJECT_ROOT}/l04/retry-disabled-constrained.yaml"
)
declare -A scenario_deployed=()
declare -A scenario_contract=()
declare -A scenario_threshold=()
declare -A scenario_proxy_image=()
declare -A scenario_auth_image=()
declare -A scenario_logical=()
declare -A scenario_failures=()
declare -A scenario_overflow=()
for scenario in "${RUN_SCENARIOS[@]}"; do
  scenario_deployed["${scenario}"]=false
  scenario_contract["${scenario}"]=false
  scenario_threshold["${scenario}"]=0
  scenario_proxy_image["${scenario}"]="not-captured"
  scenario_auth_image["${scenario}"]="not-captured"
  scenario_logical["${scenario}"]=0
  scenario_failures["${scenario}"]=0
  scenario_overflow["${scenario}"]=0
done

stop_process() {
  local pid=$1
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    kill -TERM "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
}

stop_scenario_backgrounds() {
  if [[ -n "${observer_stop_file}" ]]; then
    : >"${observer_stop_file}"
  fi
  if [[ -n "${observer_pid}" ]] && kill -0 "${observer_pid}" 2>/dev/null; then
    wait "${observer_pid}" 2>/dev/null || true
  fi
  stop_process "${admin_pf_pid}"
  stop_process "${metrics_pf_pid}"
  admin_pf_pid=""
  metrics_pf_pid=""
  observer_pid=""
  observer_stop_file=""
}

write_metadata() {
  jq -n \
    --arg started_at_utc "${started_at_utc}" \
    --arg git_commit "${SOURCE_COMMIT}" \
    --argjson git_dirty "${git_dirty}" \
    --arg action "${ACTION}" \
    --arg git "${git_version}" \
    --arg go "${go_version}" \
    --arg k6 "${local_k6_version}" \
    --arg docker "${docker_version}" \
    --arg k3d "${k3d_version}" \
    --arg k3d_default "${k3d_default_k3s_version}" \
    --arg kubectl "${kubectl_client_version}" \
    --arg kubernetes "${kubernetes_server_version}" \
    --arg helm "${helm_version}" \
    --arg k3s_image "${K3S_IMAGE_VALUE}" \
    --arg istio_version "${ISTIO_VERSION_VALUE}" \
    --arg auth_image "${AUTH_SIM_IMAGE_VALUE}" \
    --arg auth_image_id "${auth_sim_image_id}" \
    --arg k6_image "${K6_IMAGE_VALUE}" \
    --arg k6_image_id "${k6_image_id}" \
    --arg k6_image_digest "${k6_image_digest}" \
    --arg istiod_image "${istiod_image}" \
    --arg istiod_image_id "${istiod_image_id}" \
    --arg proxy_image "${proxy_image}" \
    --arg proxy_image_id "${proxy_image_id}" \
    --arg envoy_version "${envoy_version}" \
    --arg base_chart_sha256 "${base_chart_sha256}" \
    --arg istiod_chart_sha256 "${istiod_chart_sha256}" \
    --arg original_context_state "${original_context_state}" \
    --argjson logical_rate "${LOGICAL_RATE_VALUE}" \
    --arg duration "${DURATION_VALUE}" \
    --arg request_timeout "${REQUEST_TIMEOUT_VALUE}" \
    --argjson application_latency_ms "${APPLICATION_LATENCY_MS_VALUE}" \
    --argjson fault_seed "${FAULT_SEED_VALUE}" \
    --arg logical_id_namespace "${LOGICAL_ID_NAMESPACE_VALUE}" \
    --arg sample_interval "${SAMPLE_INTERVAL_SECONDS_VALUE}s" \
    '{
      project: "GitHub Capacity Cascade Lab",
      learning_unit: "L04",
      classification: "local exploratory evidence",
      scenario_mode: $action,
      started_at_utc: $started_at_utc,
      git_commit: $git_commit,
      git_dirty: $git_dirty,
      tool_versions: {
        git: $git, go: $go, local_k6: $k6, docker: $docker, k3d: $k3d,
        k3d_default_k3s: $k3d_default, kubectl_client: $kubectl,
        kubernetes_server: $kubernetes, helm: $helm
      },
      cluster: {
        name: "capacity-cascade-l04", servers: 1, agents: 0,
        k3s_image: $k3s_image, api_exposure: "dynamic loopback port",
        disabled_packaged_components: ["traefik", "servicelb", "local-storage"]
      },
      istio: {
        version: $istio_version,
        install: "pinned Helm istio-base then istiod; no gateway or CNI",
        chart_sha256: {base: $base_chart_sha256, istiod: $istiod_chart_sha256},
        istiod_image: $istiod_image, istiod_image_id: $istiod_image_id,
        proxy_image: $proxy_image, proxy_image_id: $proxy_image_id,
        envoy_version: $envoy_version,
        injection: "namespace label istio-injection=enabled",
        stats_matcher: "l04/istiod-values.yaml"
      },
      images: {
        auth_sim: {name: $auth_image, id: $auth_image_id, pull_policy: "Never"},
        k6: {name: $k6_image, id: $k6_image_id, digest: $k6_image_digest, pull_policy: "IfNotPresent with immutable digest"}
      },
      comparison: {
        replicas: 1,
        application_fault: {latency_ms: $application_latency_ms, error_rate: 0, max_in_flight: 0, seed: $fault_seed},
        logical_rate: $logical_rate, duration: $duration, request_timeout: $request_timeout,
        logical_id_namespace: $logical_id_namespace,
        client_retry: "none", client_max_attempts: 1, proxy_retry: "none",
        load_path: "non-injected k6 Job -> ClusterIP Service:8080 -> istio-proxy -> auth-sim:8080",
        sampling_interval: $sample_interval,
        only_comparison_variable: "Sidecar ingress port 8080 connectionPool.http.http2MaxRequests",
        targets: {control: 100, constrained: 1}
      },
      access: {
        admin: "runner -> loopback Pod port-forward -> auth-sim:9090",
        application_metrics: "runner -> verified direct Pod port-forward -> auth-sim:8080",
        proxy_observation: "kubectl exec istio-proxy -> pilot-agent request",
        original_context_state: $original_context_state
      }
    }' >"${result_dir}/metadata.json"
}

write_cleanup() {
  jq -n \
    --argjson runner_exit_before_cleanup "$1" \
    --argjson scenario_resources_removed "${scenario_resources_removed}" \
    --argjson istiod_removed "${istiod_removed}" \
    --argjson istio_base_removed "${istio_base_removed}" \
    --argjson namespaces_removed "${namespaces_removed}" \
    --argjson cluster_removed "${cluster_removed}" \
    --argjson remaining_containers "${remaining_containers}" \
    --argjson remaining_networks "${remaining_networks}" \
    --argjson remaining_processes "${remaining_processes}" \
    --argjson temporary_kubeconfig_removed "${temporary_kubeconfig_removed}" \
    --argjson temporary_helm_state_removed "${temporary_helm_state_removed}" \
    --argjson original_context_unchanged "${original_context_unchanged}" \
    --argjson original_helm_config_unchanged "${original_helm_config_unchanged}" \
    '{
      runner_exit_before_cleanup: $runner_exit_before_cleanup,
      scenario_resources_removed: $scenario_resources_removed,
      istiod_removed: $istiod_removed,
      istio_base_removed: $istio_base_removed,
      namespaces_removed: $namespaces_removed,
      cluster_removed: $cluster_removed,
      remaining_cluster_containers: $remaining_containers,
      remaining_cluster_networks: $remaining_networks,
      remaining_owned_processes: $remaining_processes,
      temporary_kubeconfig_removed: $temporary_kubeconfig_removed,
      temporary_helm_state_removed: $temporary_helm_state_removed,
      original_context_unchanged: $original_context_unchanged,
      original_helm_config_unchanged: $original_helm_config_unchanged
    }' >"${result_dir}/cleanup.json"
}

write_pair_contract() {
  local scenarios_passed=true
  local scenario
  for scenario in "${RUN_SCENARIOS[@]}"; do
    if [[ "${scenario_contract[${scenario}]}" != true ]]; then scenarios_passed=false; fi
  done
  local normalized_config_equal=false
  local only_capacity_diff=false
  local control_overflow_zero=false
  local constrained_overflow_positive=false
  local failures_increase=false
  if [[ "${ACTION}" == pair ]]; then
    if [[ -f "${result_dir}/comparison-config-normalized.diff" \
      && ! -s "${result_dir}/comparison-config-normalized.diff" ]]; then
      normalized_config_equal=true
    fi
    if [[ "${scenario_threshold[sidecar-control]}" -eq "${CONTROL_CAPACITY}" \
      && "${scenario_threshold[sidecar-constrained]}" -eq "${CONSTRAINED_CAPACITY}" ]]; then
      only_capacity_diff=true
    fi
    if [[ "${scenario_overflow[sidecar-control]}" -eq 0 ]]; then control_overflow_zero=true; fi
    if [[ "${scenario_overflow[sidecar-constrained]}" -gt 0 ]]; then constrained_overflow_positive=true; fi
    if awk -v control="${scenario_failures[sidecar-control]}" \
      -v constrained="${scenario_failures[sidecar-constrained]}" \
      'BEGIN { exit !(constrained > control) }'; then failures_increase=true; fi
  else
    normalized_config_equal=true
    only_capacity_diff=true
    control_overflow_zero=true
    constrained_overflow_positive=true
    failures_increase=true
  fi

  contract_passed=false
  if [[ "${scenarios_passed}" == true \
    && "${normalized_config_equal}" == true \
    && "${only_capacity_diff}" == true \
    && "${control_overflow_zero}" == true \
    && "${constrained_overflow_positive}" == true \
    && "${failures_increase}" == true \
    && "${scenario_resources_removed}" == true \
    && "${istiod_removed}" == true \
    && "${istio_base_removed}" == true \
    && "${namespaces_removed}" == true \
    && "${cluster_removed}" == true \
    && "${remaining_containers}" -eq 0 \
    && "${remaining_networks}" -eq 0 \
    && "${remaining_processes}" -eq 0 \
    && "${temporary_kubeconfig_removed}" == true \
    && "${temporary_helm_state_removed}" == true \
    && "${original_context_unchanged}" == true \
    && "${original_helm_config_unchanged}" == true ]]; then
    contract_passed=true
  fi

  jq -n \
    --arg action "${ACTION}" \
    --argjson pair_comparison_applicable "$([[ "${ACTION}" == pair ]] && printf true || printf false)" \
    --argjson passed "${contract_passed}" \
    --argjson scenarios_passed "${scenarios_passed}" \
    --argjson normalized_config_equal "${normalized_config_equal}" \
    --argjson only_capacity_diff "${only_capacity_diff}" \
    --argjson control_overflow_zero "${control_overflow_zero}" \
    --argjson constrained_overflow_positive "${constrained_overflow_positive}" \
    --argjson failures_increase "${failures_increase}" \
    --argjson cleanup_passed "$(jq -r '[to_entries[] | select(.key != "runner_exit_before_cleanup") | .value] | all' "${result_dir}/cleanup.json")" \
    '{
      passed: $passed,
      mode: $action,
      scenario_contracts_passed: $scenarios_passed,
      pair_comparison_applicable: $pair_comparison_applicable,
      generated_config_equal_except_max_requests: (if $pair_comparison_applicable then $normalized_config_equal else null end),
      expected_capacity_targets_observed: (if $pair_comparison_applicable then $only_capacity_diff else null end),
      control_overflow_zero: (if $pair_comparison_applicable then $control_overflow_zero else null end),
      constrained_overflow_positive: (if $pair_comparison_applicable then $constrained_overflow_positive else null end),
      constrained_failures_greater_than_control: (if $pair_comparison_applicable then $failures_increase else null end),
      cleanup_passed: $cleanup_passed
    }' >"${result_dir}/contract.json"
}

write_root_summary() {
  local scenario_rows=""
  local scenario
  for scenario in "${RUN_SCENARIOS[@]}"; do
    scenario_rows+="| ${scenario} | ${scenario_contract[${scenario}]} | ${scenario_threshold[${scenario}]} | ${scenario_logical[${scenario}]} | ${scenario_failures[${scenario}]} | ${scenario_overflow[${scenario}]} |"$'\n'
  done
  cat >"${result_dir}/summary.md" <<EOF
# L04 Istio sidecar capacity summary

> 이 실행은 단일 local exploratory evidence이며 production benchmark나 GitHub topology/config evidence가 아니다.

| Scenario | Contract | Generated max requests | Logical requests | Logical failure rate | Active overflow delta |
| --- | --- | ---: | ---: | ---: | ---: |
${scenario_rows}
## Pair and cleanup

- Pair/root contract: ${contract_passed}
- Istio: ${ISTIO_VERSION_VALUE}, pinned Helm base/istiod, gateway/CNI/HPA 없음
- Workload: non-injected pinned k6 Job -> ClusterIP Service -> injected inbound sidecar -> auth-sim
- Application: latency ${APPLICATION_LATENCY_MS_VALUE} ms, error 0, max_in_flight 0/unlimited
- Retry: k6 none/max attempts 1; selected inbound route retry policy 없음; proxy retry delta 0
- Only intended comparison variable: inbound port 8080 http2MaxRequests ${CONTROL_CAPACITY} vs ${CONSTRAINED_CAPACITY}
- Cleanup: scenario resources=${scenario_resources_removed}, Istio=${istiod_removed}/${istio_base_removed}, namespaces=${namespaces_removed}, cluster=${cluster_removed}
- Residue: containers=${remaining_containers}, networks=${remaining_networks}, processes=${remaining_processes}
- Temporary kubeconfig/Helm state removed: ${temporary_kubeconfig_removed}/${temporary_helm_state_removed}
- Original kube context/global Helm repository config unchanged: ${original_context_unchanged}/${original_helm_config_unchanged}

Generated config, actual metric mapping과 timestamped samples는 scenario directory에 보존했다.
EOF
}

cleanup() {
  local original_exit=$?
  local cleanup_failed=false
  local api_available=false
  local scenario namespace release after_context after_helm_hash
  trap - EXIT
  set +e

  stop_scenario_backgrounds

  if cluster_exists && [[ -s "${kubeconfig_file}" ]] \
    && kubectl --kubeconfig "${kubeconfig_file}" get namespace >/dev/null 2>&1; then
    api_available=true
  fi

  if [[ "${api_available}" == true ]]; then
    helm --kubeconfig "${kubeconfig_file}" list --all-namespaces --all \
      >"${result_dir}/helm-list-before-uninstall.txt" 2>&1
    kubectl --kubeconfig "${kubeconfig_file}" logs deployment/istiod --namespace "${ISTIO_NAMESPACE}" \
      --all-containers=true >"${result_dir}/istiod-logs-before-cleanup.txt" 2>&1 || true
    scenario_resources_removed=true
    for scenario in "${RUN_SCENARIOS[@]}"; do
      namespace="${SCENARIO_NAMESPACE[${scenario}]}"
      release="${SCENARIO_RELEASE[${scenario}]}"
      if helm --kubeconfig "${kubeconfig_file}" --namespace "${namespace}" status "${release}" >/dev/null 2>&1; then
        helm --kubeconfig "${kubeconfig_file}" --namespace "${namespace}" uninstall "${release}" \
          >"${result_dir}/${scenario}/helm-uninstall.log" 2>&1 || scenario_resources_removed=false
      fi
      if helm --kubeconfig "${kubeconfig_file}" --namespace "${namespace}" status "${release}" >/dev/null 2>&1; then
        scenario_resources_removed=false
      fi
    done

    if helm --kubeconfig "${kubeconfig_file}" --namespace "${ISTIO_NAMESPACE}" status istiod >/dev/null 2>&1; then
      helm --kubeconfig "${kubeconfig_file}" --namespace "${ISTIO_NAMESPACE}" uninstall istiod \
        >"${result_dir}/istiod-uninstall.log" 2>&1
    fi
    if ! helm --kubeconfig "${kubeconfig_file}" --namespace "${ISTIO_NAMESPACE}" status istiod >/dev/null 2>&1; then
      istiod_removed=true
    fi
    if helm --kubeconfig "${kubeconfig_file}" --namespace "${ISTIO_NAMESPACE}" status istio-base >/dev/null 2>&1; then
      helm --kubeconfig "${kubeconfig_file}" --namespace "${ISTIO_NAMESPACE}" uninstall istio-base \
        >"${result_dir}/istio-base-uninstall.log" 2>&1
    fi
    if ! helm --kubeconfig "${kubeconfig_file}" --namespace "${ISTIO_NAMESPACE}" status istio-base >/dev/null 2>&1; then
      istio_base_removed=true
    fi
    helm --kubeconfig "${kubeconfig_file}" list --all-namespaces --all \
      >"${result_dir}/helm-list-after-uninstall.txt" 2>&1

    for namespace in "${CONTROL_NAMESPACE}" "${CONSTRAINED_NAMESPACE}" "${LOAD_NAMESPACE}" "${ISTIO_NAMESPACE}"; do
      if kubectl --kubeconfig "${kubeconfig_file}" get namespace "${namespace}" >/dev/null 2>&1; then
        kubectl --kubeconfig "${kubeconfig_file}" delete namespace "${namespace}" \
          --wait=true --timeout=180s >>"${result_dir}/namespace-delete.log" 2>&1 || true
      fi
    done
    namespaces_removed=true
    for namespace in "${CONTROL_NAMESPACE}" "${CONSTRAINED_NAMESPACE}" "${LOAD_NAMESPACE}" "${ISTIO_NAMESPACE}"; do
      if kubectl --kubeconfig "${kubeconfig_file}" get namespace "${namespace}" >/dev/null 2>&1; then
        namespaces_removed=false
      fi
    done
  fi

  if cluster_exists; then
    k3d cluster delete "${CLUSTER_NAME}" >"${result_dir}/cluster-delete.log" 2>&1
  fi
  if ! cluster_exists && [[ "${cluster_created}" == true ]]; then cluster_removed=true; fi
  remaining_containers="$(remaining_cluster_containers)"
  remaining_networks="$(remaining_cluster_networks)"
  remaining_processes="$(remaining_owned_processes)"

  find "${runtime_root}" -depth -delete
  if [[ ! -e "${kubeconfig_file}" ]]; then temporary_kubeconfig_removed=true; fi
  if [[ ! -d "${helm_config_home}" && ! -d "${helm_cache_home}" && ! -d "${helm_data_home}" ]]; then
    temporary_helm_state_removed=true
  fi

  after_context="$(read_original_context)"
  if [[ "${after_context}" == "${original_context}" ]]; then original_context_unchanged=true; fi
  after_helm_hash="$(file_hash_or_absent "${original_helm_repository_config}")"
  if [[ "${after_helm_hash}" == "${original_helm_repository_hash}" ]]; then original_helm_config_unchanged=true; fi

  if [[ "${scenario_resources_removed}" != true \
    || "${istiod_removed}" != true \
    || "${istio_base_removed}" != true \
    || "${namespaces_removed}" != true \
    || "${cluster_removed}" != true \
    || "${remaining_containers}" -ne 0 \
    || "${remaining_networks}" -ne 0 \
    || "${remaining_processes}" -ne 0 \
    || "${temporary_kubeconfig_removed}" != true \
    || "${temporary_helm_state_removed}" != true \
    || "${original_context_unchanged}" != true \
    || "${original_helm_config_unchanged}" != true ]]; then
    cleanup_failed=true
  fi

  write_cleanup "${original_exit}"
  write_metadata
  write_pair_contract
  write_root_summary
  printf 'Result: %s\n' "${result_dir}"

  if [[ "${original_exit}" -eq 0 && "${contract_passed}" != true ]]; then exit 1; fi
  if [[ "${original_exit}" -eq 0 && "${cleanup_failed}" == true ]]; then exit 1; fi
  exit "${original_exit}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_url() {
  local url=$1
  for _ in {1..60}; do
    if curl --fail --silent --show-error "${url}" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
  done
  return 1
}

probe_service_datapath() {
  local scenario=$1 namespace=$2 release=$3 scenario_dir=$4
  local safe_name="${scenario#sidecar-}"
  local probe="l04-datapath-${safe_name}"
  local service_fqdn="${release}.${namespace}.svc.cluster.local"
  local phase=""

  kubectl run "${probe}" --namespace "${LOAD_NAMESPACE}" \
    --image="${k6_image_digest}" --image-pull-policy=IfNotPresent --restart=Never \
    --labels="capacity-cascade-lab/owner=l04,capacity-cascade-lab/scenario=${scenario}" \
    --command -- /bin/sh -c "wget -qO- http://${service_fqdn}:8080/readyz" \
    >"${scenario_dir}/datapath-probe-create.log"

  for _ in {1..120}; do
    phase="$(kubectl get pod "${probe}" --namespace "${LOAD_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${phase}" == Succeeded || "${phase}" == Failed ]]; then break; fi
    sleep 0.25
  done
  kubectl get pod "${probe}" --namespace "${LOAD_NAMESPACE}" -o json \
    >"${scenario_dir}/datapath-probe-pod.json"
  kubectl logs "${probe}" --namespace "${LOAD_NAMESPACE}" \
    >"${scenario_dir}/datapath-probe-response.txt" 2>"${scenario_dir}/datapath-probe-logs-error.txt" || true

  if [[ "${phase}" != Succeeded ]]; then
    printf 'non-injected Service datapath probe failed: phase=%s\n' "${phase:-unknown}" >&2
    return 1
  fi
  if [[ "$(jq '[.spec.containers[]?,.spec.initContainers[]? | select(.name=="istio-proxy")] | length' \
    "${scenario_dir}/datapath-probe-pod.json")" -ne 0 ]]; then
    printf 'datapath probe unexpectedly received an Istio sidecar\n' >&2
    return 1
  fi
  if ! jq -e '.status == "ready"' "${scenario_dir}/datapath-probe-response.txt" >/dev/null; then
    printf 'datapath probe did not receive the application readiness response\n' >&2
    return 1
  fi
  kubectl delete pod "${probe}" --namespace "${LOAD_NAMESPACE}" --wait=true --timeout=60s \
    >"${scenario_dir}/datapath-probe-delete.log"
}

apply_retry_disable_patch() {
  local namespace=$1 pod=$2 release=$3 retry_manifest=$4 scenario_dir=$5
  local before_config="${scenario_dir}/proxy-config-before-retry-disable.json"
  local after_config="${scenario_dir}/proxy-config-after-retry-disable.json"
  local before_routes="${scenario_dir}/target-inbound-http-before-retry-disable.json"
  local after_routes="${scenario_dir}/target-inbound-http-after-retry-disable.json"
  local before_budget after_budget=-1 candidate="${after_config}.tmp"

  kubectl exec --namespace "${namespace}" "${pod}" -c istio-proxy -- \
    pilot-agent request GET config_dump >"${before_config}"
  jq '[.. | objects | select((.route_config?.name? // "") == "inbound|8080||") | .route_config]' \
    "${before_config}" >"${before_routes}"
  before_budget="$(jq '[.. | objects | .retry_policy?.num_retries? // empty] | max // 0' "${before_routes}")"
  if [[ "${before_budget}" -le 0 ]]; then
    printf 'selected Istio did not expose the expected generated inbound retry budget before fallback\n' >&2
    return 1
  fi

  kubectl apply --server-side --dry-run=server -f "${retry_manifest}" \
    >"${scenario_dir}/retry-disabled-server-dry-run.log"
  kubectl apply -f "${retry_manifest}" >"${scenario_dir}/retry-disabled-apply.log"
  kubectl get envoyfilter auth-sim-inbound-retry-disabled --namespace "${namespace}" -o json \
    >"${scenario_dir}/retry-disabled-resource.json"

  # EnvoyFilter changes are version-coupled. Start a fresh proxy after applying
  # the patch so the workload run never depends on an in-place LDS refresh.
  kubectl delete pod "${pod}" --namespace "${namespace}" --wait=true --timeout=90s \
    >"${scenario_dir}/pod-before-retry-disable-delete.log"
  kubectl rollout status deployment/"${release}" --namespace "${namespace}" --timeout=180s \
    >"${scenario_dir}/rollout-after-retry-disable.log"
  patched_pod="$(kubectl get pods --namespace "${namespace}" \
    --selector "app.kubernetes.io/instance=${release}" -o jsonpath='{.items[0].metadata.name}')"
  if [[ -z "${patched_pod}" || "${patched_pod}" == "${pod}" ]]; then
    printf 'fresh proxy Pod was not created after applying retry-disable fallback\n' >&2
    return 1
  fi
  kubectl wait pod/"${patched_pod}" --namespace "${namespace}" --for=condition=Ready --timeout=180s \
    >"${scenario_dir}/pod-after-retry-disable-ready.log"

  for _ in {1..80}; do
    kubectl exec --namespace "${namespace}" "${patched_pod}" -c istio-proxy -- \
      pilot-agent request GET config_dump >"${candidate}"
    after_budget="$(jq '[.. | objects
      | select((.route_config?.name? // "") == "inbound|8080||")
      | .route_config | .. | objects | .retry_policy?.num_retries? // empty] | max // 0' "${candidate}")"
    if [[ "${after_budget}" -eq 0 ]]; then break; fi
    sleep 0.25
  done
  mv "${candidate}" "${after_config}"
  jq '[.. | objects | select((.route_config?.name? // "") == "inbound|8080||") | .route_config]' \
    "${after_config}" >"${after_routes}"
  if [[ "${after_budget}" -ne 0 || "$(jq '[.. | objects | select(has("retry_policy"))] | length' "${after_routes}")" -ne 0 ]]; then
    printf 'version-specific retry-disable EnvoyFilter did not remove the actual inbound retry policy\n' >&2
    return 1
  fi
}

start_port_forward() {
  local namespace=$1
  local pod=$2
  local remote_port=$3
  local log_file=$4
  local pid_var=$5
  local port_var=$6
  local pid port=""
  kubectl port-forward --namespace "${namespace}" --address 127.0.0.1 \
    pod/"${pod}" :"${remote_port}" >"${log_file}" 2>&1 &
  pid=$!
  for _ in {1..60}; do
    port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) ->.*/\1/p' "${log_file}" | head -n 1)"
    if [[ -n "${port}" ]]; then break; fi
    if ! kill -0 "${pid}" 2>/dev/null; then break; fi
    sleep 0.1
  done
  if [[ -z "${port}" ]]; then
    printf 'port-forward did not become ready for %s/%s:%s\n' "${namespace}" "${pod}" "${remote_port}" >&2
    return 1
  fi
  printf -v "${pid_var}" '%s' "${pid}"
  printf -v "${port_var}" '%s' "${port}"
}

put_application_fault() {
  local admin_url=$1
  local body=$2
  local output=$3
  curl --fail --silent --show-error --request PUT \
    --header "Authorization: Bearer ${admin_token}" \
    --header 'Content-Type: application/json' \
    --data "${body}" "${admin_url}/admin/fault" >"${output}"
}

prom_metric_sum() {
  local file=$1
  local metric=$2
  local first_filter=${3:-}
  local second_filter=${4:-}
  awk -v metric="${metric}" -v first_filter="${first_filter}" -v second_filter="${second_filter}" '
    index($0, metric) == 1 && $0 !~ /^#/ \
      && (first_filter == "" || index($0, first_filter) > 0) \
      && (second_filter == "" || index($0, second_filter) > 0) { sum += $NF }
    END { printf "%.0f", sum + 0 }
  ' "${file}"
}

stat_value() {
  local file=$1
  local metric=$2
  awk -F': ' -v metric="${metric}" '$1 == metric { print $2+0; found=1; exit } END { if (!found) print 0 }' "${file}"
}

select_actual_stat_name() {
  local file=$1 prefix=$2 suffix=$3
  local matches
  matches="$(awk -F': ' -v prefix="${prefix}" -v suffix="${suffix}" '
    index($1, prefix) == 1 && substr($1, length($1) - length(suffix) + 1) == suffix { print $1 }
  ' "${file}" | sort -u)"
  if [[ "$(printf '%s\n' "${matches}" | awk 'NF {count++} END {print count+0}')" -ne 1 ]]; then
    printf 'expected one actual proxy metric for prefix=%s suffix=%s; found=%s\n' \
      "${prefix}" "${suffix}" "${matches:-none}" >&2
    return 1
  fi
  printf '%s\n' "${matches}"
}

k6_metric_value() {
  local file=$1
  local metric=$2
  local value=$3
  jq -r --arg metric "${metric}" --arg value "${value}" '.metrics[$metric].values[$value] // empty' "${file}"
}

collect_proxy_stats() {
  local namespace=$1
  local pod=$2
  local output=$3
  kubectl exec --namespace "${namespace}" "${pod}" -c istio-proxy -- \
    pilot-agent request GET 'stats?filter=8080' >"${output}"
}

wait_for_proxy_idle() {
  local namespace=$1
  local pod=$2
  local mapping_file=$3
  local temp_file=$4
  local upstream_active_metric downstream_active_metric upstream_active downstream_active
  upstream_active_metric="$(jq -r '.proxy_upstream_active' "${mapping_file}")"
  downstream_active_metric="$(jq -r '.proxy_downstream_active' "${mapping_file}")"
  for _ in {1..80}; do
    collect_proxy_stats "${namespace}" "${pod}" "${temp_file}"
    upstream_active="$(stat_value "${temp_file}" "${upstream_active_metric}")"
    downstream_active="$(stat_value "${temp_file}" "${downstream_active_metric}")"
    if [[ "${upstream_active}" -eq 0 && "${downstream_active}" -eq 0 ]]; then return 0; fi
    sleep 0.1
  done
  return 1
}

append_sample() {
  local phase=$1
  local scenario=$2
  local namespace=$3
  local pod=$4
  local metrics_url=$5
  local mapping_file=$6
  local samples_file=$7
  local proxy_temp app_temp timestamp_utc
  local app_in_flight app_token app_admission
  local downstream_total downstream_active upstream_total upstream_active overflow retry timeout
  proxy_temp="${samples_file}.proxy.tmp"
  app_temp="${samples_file}.app.tmp"
  timestamp_utc="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  curl --fail --silent --show-error "${metrics_url}/metrics" >"${app_temp}"
  collect_proxy_stats "${namespace}" "${pod}" "${proxy_temp}"
  app_in_flight="$(prom_metric_sum "${app_temp}" capacity_cascade_http_in_flight)"
  app_token="$(prom_metric_sum "${app_temp}" capacity_cascade_http_requests_total 'route="/token"')"
  app_admission="$(prom_metric_sum "${app_temp}" capacity_cascade_admission_rejections_total)"
  downstream_total="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_downstream_total' "${mapping_file}")")"
  downstream_active="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_downstream_active' "${mapping_file}")")"
  upstream_total="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_upstream_total' "${mapping_file}")")"
  upstream_active="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_upstream_active' "${mapping_file}")")"
  overflow="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_active_overflow' "${mapping_file}")")"
  retry="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_retry' "${mapping_file}")")"
  timeout="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_timeout' "${mapping_file}")")"
  jq -cn \
    --arg timestamp_utc "${timestamp_utc}" --arg scenario "${scenario}" --arg phase "${phase}" \
    --argjson application_in_flight "${app_in_flight}" --argjson application_token_requests "${app_token}" \
    --argjson application_admission_rejections "${app_admission}" \
    --argjson proxy_downstream_total "${downstream_total}" --argjson proxy_downstream_active "${downstream_active}" \
    --argjson proxy_upstream_total "${upstream_total}" --argjson proxy_upstream_active "${upstream_active}" \
    --argjson proxy_active_overflow "${overflow}" --argjson proxy_retry "${retry}" --argjson proxy_timeout "${timeout}" \
    '{timestamp_utc:$timestamp_utc,scenario:$scenario,phase:$phase,
      application_in_flight:$application_in_flight,
      application_token_requests:$application_token_requests,
      application_admission_rejections:$application_admission_rejections,
      proxy_downstream_total:$proxy_downstream_total,proxy_downstream_active:$proxy_downstream_active,
      proxy_upstream_total:$proxy_upstream_total,proxy_upstream_active:$proxy_upstream_active,
      proxy_active_overflow:$proxy_active_overflow,proxy_retry:$proxy_retry,proxy_timeout:$proxy_timeout}' \
    >>"${samples_file}"
}

observe_loop() {
  local scenario=$1 namespace=$2 pod=$3 metrics_url=$4 mapping_file=$5 samples_file=$6 stop_file=$7
  while [[ ! -e "${stop_file}" ]]; do
    append_sample during "${scenario}" "${namespace}" "${pod}" "${metrics_url}" "${mapping_file}" "${samples_file}"
    sleep "${SAMPLE_INTERVAL_SECONDS_VALUE}"
  done
}

discover_proxy_config() {
  local scenario=$1 namespace=$2 pod=$3 scenario_dir=$4 expected_capacity=$5
  local config_dump="${scenario_dir}/proxy-config-dump.json"
  local cluster_names hcm_prefixes cluster_name hcm_prefix threshold retry_policy_count

  kubectl exec --namespace "${namespace}" "${pod}" -c istio-proxy -- \
    pilot-agent request GET config_dump >"${config_dump}"
  kubectl exec --namespace "${namespace}" "${pod}" -c istio-proxy -- \
    pilot-agent request GET server_info >"${scenario_dir}/proxy-server-info.json"
  kubectl exec --namespace "${namespace}" "${pod}" -c istio-proxy -- \
    pilot-agent version >"${scenario_dir}/pilot-agent-version.txt"
  kubectl exec --namespace "${namespace}" "${pod}" -c istio-proxy -- \
    pilot-agent request GET stats >"${scenario_dir}/proxy-stats-inventory.txt"

  cluster_names="$(jq -r '.. | objects | select(has("circuit_breakers")) | (.name? // empty) | select(test("^inbound[|]8080[|]"))' \
    "${config_dump}" | sort -u)"
  if [[ "$(printf '%s\n' "${cluster_names}" | awk 'NF {count++} END {print count+0}')" -ne 1 ]]; then
    printf 'expected one actual inbound port 8080 cluster, found: %s\n' "${cluster_names:-none}" >&2
    return 1
  fi
  cluster_name="${cluster_names}"
  jq --arg name "${cluster_name}" \
    '.. | objects | select((.name? // "") == $name and has("circuit_breakers"))' \
    "${config_dump}" >"${scenario_dir}/target-inbound-cluster.json"
  jq -S '.' "${scenario_dir}/target-inbound-cluster.json" >"${scenario_dir}/target-inbound-cluster-normalized.json"
  threshold="$(jq -r '.circuit_breakers.thresholds[] | select((.priority // "DEFAULT") == "DEFAULT") | .max_requests // empty' \
    "${scenario_dir}/target-inbound-cluster.json" | head -n 1)"
  if [[ -z "${threshold}" || ! "${threshold}" =~ ^[0-9]+$ ]]; then
    printf 'target inbound cluster max_requests was not found\n' >&2
    return 1
  fi
  scenario_threshold["${scenario}"]="${threshold}"
  if [[ "${threshold}" -ne "${expected_capacity}" ]]; then
    printf 'generated max_requests mismatch for %s: expected=%s actual=%s\n' \
      "${scenario}" "${expected_capacity}" "${threshold}" >&2
    return 1
  fi

  hcm_prefixes="$(jq -r '
    .. | objects
    | select(((.filter_chain_match?.destination_port? // "") | tostring) == "8080")
    | .filters[]?.typed_config?
    | select((."@type"? // "") | endswith("HttpConnectionManager"))
    | .stat_prefix // empty
  ' "${config_dump}" | sort -u)"
  if [[ -z "${hcm_prefixes}" ]]; then
    hcm_prefixes="$(jq -r '
      .. | objects
      | select((."@type"? // "") | endswith("HttpConnectionManager"))
      | .stat_prefix // empty
      | select(contains("8080"))
    ' "${config_dump}" | sort -u)"
  fi
  if [[ "$(printf '%s\n' "${hcm_prefixes}" | awk 'NF {count++} END {print count+0}')" -ne 1 ]]; then
    printf 'expected one actual inbound port 8080 HCM stat prefix, found: %s\n' "${hcm_prefixes:-none}" >&2
    return 1
  fi
  hcm_prefix="${hcm_prefixes}"

  jq '
    [.. | objects
      | select(((.filter_chain_match?.destination_port? // "") | tostring) == "8080")
      | .filters[]?.typed_config?
      | select((."@type"? // "") | endswith("HttpConnectionManager"))]
  ' "${config_dump}" >"${scenario_dir}/target-inbound-http-config.json"
  if [[ "$(jq 'length' "${scenario_dir}/target-inbound-http-config.json")" -eq 0 ]]; then
    jq --arg prefix "${hcm_prefix}" \
      '[.. | objects | select((."@type"? // "") | endswith("HttpConnectionManager")) | select(.stat_prefix == $prefix)]' \
      "${config_dump}" >"${scenario_dir}/target-inbound-http-config.json"
  fi
  retry_policy_count="$(jq '[.. | objects | select(has("retry_policy"))] | length' \
    "${scenario_dir}/target-inbound-http-config.json")"
  local retry_budget_max
  retry_budget_max="$(jq '[.. | objects | .retry_policy?.num_retries? // empty] | max // 0' \
    "${scenario_dir}/target-inbound-http-config.json")"

  # Do not synthesize Envoy stat names. Istio's selected binary applies tag
  # extraction delimiters (for example `;`) to the raw key, so select each
  # authoritative name from the actual inventory using config-derived prefixes.
  local downstream_total downstream_active downstream_5xx
  local upstream_total upstream_active pending_active active_overflow pending_overflow retry timeout
  downstream_total="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" \
    "http.${hcm_prefix}" '.downstream_rq_total')"
  downstream_active="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" \
    "http.${hcm_prefix}" '.downstream_rq_active')"
  downstream_5xx="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" \
    "http.${hcm_prefix}" '.downstream_rq_5xx')"
  upstream_total="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" \
    "cluster.${cluster_name}" '.upstream_rq_total')"
  upstream_active="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" \
    "cluster.${cluster_name}" '.upstream_rq_active')"
  pending_active="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" \
    "cluster.${cluster_name}" '.upstream_rq_pending_active')"
  active_overflow="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" \
    "cluster.${cluster_name}" '.upstream_rq_active_overflow')"
  pending_overflow="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" \
    "cluster.${cluster_name}" '.upstream_rq_pending_overflow')"
  retry="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" \
    "cluster.${cluster_name}" '.upstream_rq_retry')"
  timeout="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" \
    "cluster.${cluster_name}" '.upstream_rq_timeout')"

  jq -n \
    --arg cluster "${cluster_name}" --arg hcm_stat_prefix "${hcm_prefix}" \
    --arg proxy_downstream_total "${downstream_total}" --arg proxy_downstream_active "${downstream_active}" \
    --arg proxy_downstream_5xx "${downstream_5xx}" --arg proxy_upstream_total "${upstream_total}" \
    --arg proxy_upstream_active "${upstream_active}" --arg proxy_pending_active "${pending_active}" \
    --arg proxy_active_overflow "${active_overflow}" --arg proxy_pending_overflow "${pending_overflow}" \
    --arg proxy_retry "${retry}" --arg proxy_timeout "${timeout}" \
    --argjson inbound_retry_policy_count "${retry_policy_count}" \
    --argjson inbound_retry_budget_max "${retry_budget_max}" \
    '{cluster:$cluster,hcm_stat_prefix:$hcm_stat_prefix,
      proxy_downstream_total:$proxy_downstream_total,proxy_downstream_active:$proxy_downstream_active,
      proxy_downstream_5xx:$proxy_downstream_5xx,proxy_upstream_total:$proxy_upstream_total,
      proxy_upstream_active:$proxy_upstream_active,proxy_pending_active:$proxy_pending_active,
      proxy_active_overflow:$proxy_active_overflow,proxy_pending_overflow:$proxy_pending_overflow,
      proxy_retry:$proxy_retry,proxy_timeout:$proxy_timeout,
      inbound_retry_policy_count:$inbound_retry_policy_count,
      inbound_retry_budget_max:$inbound_retry_budget_max}' \
    >"${scenario_dir}/proxy-metric-mapping.json"
}

create_k6_job() {
  local scenario=$1 namespace=$2 release=$3 scenario_dir=$4 expected_capacity=$5 pod=$6
  local safe_name="${scenario#sidecar-}"
  local configmap="l04-k6-${safe_name}"
  local job="l04-k6-${safe_name}"
  local service_fqdn="${release}.${namespace}.svc.cluster.local"
  local job_manifest="${scenario_dir}/k6-job.yaml"
  local configmap_manifest="${scenario_dir}/k6-configmap.yaml"
  local load_pod=""

  kubectl create configmap "${configmap}" --namespace "${LOAD_NAMESPACE}" \
    --from-file=l04.js="${PROJECT_ROOT}/load/k6/l04.js" \
    --from-file=config.js="${PROJECT_ROOT}/load/k6/lib/config.js" \
    --from-file=retry.js="${PROJECT_ROOT}/load/k6/lib/retry.js" \
    --from-file=summary.js="${PROJECT_ROOT}/load/k6/lib/summary.js" \
    --dry-run=client -o yaml >"${configmap_manifest}"
  kubectl apply -f "${configmap_manifest}" >"${scenario_dir}/k6-configmap-apply.log"

  cat >"${job_manifest}" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${LOAD_NAMESPACE}
  labels:
    capacity-cascade-lab/owner: l04
    capacity-cascade-lab/scenario: ${scenario}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 120
  template:
    metadata:
      labels:
        capacity-cascade-lab/owner: l04
        capacity-cascade-lab/scenario: ${scenario}
        sidecar.istio.io/inject: "false"
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        fsGroup: 12345
      containers:
        - name: k6
          image: ${k6_image_digest}
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh", "-c"]
          args:
            - |
              set +e
              k6 version > /results/k6-version.txt
              k6 run /scripts/l04.js
              code=\$?
              printf '%s\n' "\${code}" > /results/k6.exit
              : > /results/k6.done
              while [ ! -f /results/collected ]; do sleep 1; done
              exit "\${code}"
          env:
            - {name: BASE_URL, value: "http://${service_fqdn}:8080"}
            - {name: RESULT_DIR, value: "/results"}
            - {name: STARTED_AT_UTC, value: "${started_at_utc}"}
            - {name: GIT_COMMIT, value: "${SOURCE_COMMIT}"}
            - {name: GIT_DIRTY, value: "${git_dirty}"}
            - {name: GO_VERSION, value: "not-used"}
            - {name: K6_VERSION, value: "${K6_IMAGE_VALUE}"}
            - {name: DOCKER_VERSION, value: "not-used"}
            - {name: LAB_OS, value: "linux-container"}
            - {name: LAB_ARCH, value: "amd64"}
            - {name: L04_SCENARIO, value: "${scenario}"}
            - {name: LOGICAL_RATE, value: "${LOGICAL_RATE_VALUE}"}
            - {name: DURATION, value: "${DURATION_VALUE}"}
            - {name: REQUEST_TIMEOUT, value: "${REQUEST_TIMEOUT_VALUE}"}
            - {name: APPLICATION_LATENCY_MS, value: "${APPLICATION_LATENCY_MS_VALUE}"}
            - {name: FAULT_SEED, value: "${FAULT_SEED_VALUE}"}
            - {name: LOGICAL_ID_NAMESPACE, value: "${LOGICAL_ID_NAMESPACE_VALUE}"}
            - {name: SIDECAR_ACTIVE_REQUEST_TARGET, value: "${expected_capacity}"}
            - {name: REQUEST_PATH, value: "non-injected k6 Job -> ClusterIP Service :8080 -> target Pod istio-proxy -> auth-sim"}
            - {name: AUTH_SIM_IMAGE, value: "${AUTH_SIM_IMAGE_VALUE}"}
            - {name: K6_IMAGE, value: "${K6_IMAGE_VALUE}"}
            - {name: ISTIO_PROXY_IMAGE, value: "${scenario_proxy_image[${scenario}]}"}
          securityContext:
            runAsNonRoot: true
            runAsUser: 12345
            runAsGroup: 12345
            allowPrivilegeEscalation: false
          volumeMounts:
            - {name: scripts, mountPath: /scripts/l04.js, subPath: l04.js, readOnly: true}
            - {name: scripts, mountPath: /scripts/lib/config.js, subPath: config.js, readOnly: true}
            - {name: scripts, mountPath: /scripts/lib/retry.js, subPath: retry.js, readOnly: true}
            - {name: scripts, mountPath: /scripts/lib/summary.js, subPath: summary.js, readOnly: true}
            - {name: results, mountPath: /results}
      volumes:
        - name: scripts
          configMap:
            name: ${configmap}
        - name: results
          emptyDir: {}
EOF
  kubectl apply -f "${job_manifest}" >"${scenario_dir}/k6-job-apply.log"

  for _ in {1..60}; do
    load_pod="$(kubectl get pods --namespace "${LOAD_NAMESPACE}" --selector "job-name=${job}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${load_pod}" ]]; then break; fi
    sleep 0.2
  done
  if [[ -z "${load_pod}" ]]; then
    printf 'k6 Job Pod was not created\n' >&2
    return 1
  fi
  kubectl get pod "${load_pod}" --namespace "${LOAD_NAMESPACE}" -o json >"${scenario_dir}/k6-pod.json"
  if [[ "$(jq '[.spec.containers[].name] | index("istio-proxy")' "${scenario_dir}/k6-pod.json")" != null ]]; then
    printf 'load generator must not have an injected sidecar\n' >&2
    return 1
  fi

  local result_ready=false
  for _ in {1..180}; do
    if kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- \
      test -f /results/k6.done >/dev/null 2>&1; then
      result_ready=true
      break
    fi
    if [[ "$(kubectl get pod "${load_pod}" --namespace "${LOAD_NAMESPACE}" -o jsonpath='{.status.phase}')" == Failed ]]; then
      break
    fi
    sleep 0.5
  done
  kubectl logs --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 >"${scenario_dir}/k6.log" 2>&1 || true
  if [[ "${result_ready}" != true ]]; then
    printf 'k6 result files did not become available\n' >&2
    return 1
  fi

  kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- cat /results/k6.exit \
    >"${scenario_dir}/k6.exit"
  kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- cat /results/k6-version.txt \
    >"${scenario_dir}/k6-version.txt"
  kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- cat /results/metadata.json \
    >"${scenario_dir}/k6-metadata.json"
  kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- cat /results/k6-summary.json \
    >"${scenario_dir}/k6-summary.json"
  kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- cat /results/summary.md \
    >"${scenario_dir}/k6-summary.md"
  kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- touch /results/collected
  kubectl wait --namespace "${LOAD_NAMESPACE}" --for=condition=complete job/"${job}" --timeout=30s \
    >"${scenario_dir}/k6-job-complete.log"
  kubectl get job "${job}" --namespace "${LOAD_NAMESPACE}" -o yaml >"${scenario_dir}/k6-job-state.yaml"
  if [[ "$(tr -d '[:space:]' <"${scenario_dir}/k6.exit")" -ne 0 ]]; then
    printf 'k6 exited non-zero\n' >&2
    return 1
  fi
}

write_scenario_contract() {
  local scenario=$1 scenario_dir=$2 expected_capacity=$3 pod_ready=$4 auto_injected=$5 observation_bypass=$6
  local mapping="${scenario_dir}/proxy-metric-mapping.json"
  local before_proxy="${scenario_dir}/proxy-stats-before.txt"
  local after_proxy="${scenario_dir}/proxy-stats-after.txt"
  local before_app="${scenario_dir}/application-metrics-before.prom"
  local after_app="${scenario_dir}/application-metrics-after.prom"
  local k6_summary="${scenario_dir}/k6-summary.json"
  local logical physical k6_retry failure_rate status_200 status_503 status_504
  local downstream_delta downstream_5xx_delta upstream_delta overflow_delta pending_overflow_delta proxy_retry_delta timeout_delta
  local app_token_delta app_admission_delta sample_count during_count app_peak proxy_peak route_retry_count route_retry_budget
  local passed=false

  logical="$(k6_metric_value "${k6_summary}" logical_requests count)"
  physical="$(k6_metric_value "${k6_summary}" physical_attempts count)"
  k6_retry="$(k6_metric_value "${k6_summary}" retry_attempts count)"
  failure_rate="$(k6_metric_value "${k6_summary}" logical_failures rate)"
  status_200="$(k6_metric_value "${k6_summary}" downstream_responses_200 count)"
  status_503="$(k6_metric_value "${k6_summary}" downstream_responses_503 count)"
  status_504="$(k6_metric_value "${k6_summary}" downstream_responses_504 count)"
  k6_retry="${k6_retry:-0}"
  status_200="${status_200:-0}"
  status_503="${status_503:-0}"
  status_504="${status_504:-0}"

  downstream_delta=$(($(stat_value "${after_proxy}" "$(jq -r '.proxy_downstream_total' "${mapping}")") - $(stat_value "${before_proxy}" "$(jq -r '.proxy_downstream_total' "${mapping}")")))
  downstream_5xx_delta=$(($(stat_value "${after_proxy}" "$(jq -r '.proxy_downstream_5xx' "${mapping}")") - $(stat_value "${before_proxy}" "$(jq -r '.proxy_downstream_5xx' "${mapping}")")))
  upstream_delta=$(($(stat_value "${after_proxy}" "$(jq -r '.proxy_upstream_total' "${mapping}")") - $(stat_value "${before_proxy}" "$(jq -r '.proxy_upstream_total' "${mapping}")")))
  overflow_delta=$(($(stat_value "${after_proxy}" "$(jq -r '.proxy_active_overflow' "${mapping}")") - $(stat_value "${before_proxy}" "$(jq -r '.proxy_active_overflow' "${mapping}")")))
  pending_overflow_delta=$(($(stat_value "${after_proxy}" "$(jq -r '.proxy_pending_overflow' "${mapping}")") - $(stat_value "${before_proxy}" "$(jq -r '.proxy_pending_overflow' "${mapping}")")))
  proxy_retry_delta=$(($(stat_value "${after_proxy}" "$(jq -r '.proxy_retry' "${mapping}")") - $(stat_value "${before_proxy}" "$(jq -r '.proxy_retry' "${mapping}")")))
  timeout_delta=$(($(stat_value "${after_proxy}" "$(jq -r '.proxy_timeout' "${mapping}")") - $(stat_value "${before_proxy}" "$(jq -r '.proxy_timeout' "${mapping}")")))
  app_token_delta=$(($(prom_metric_sum "${after_app}" capacity_cascade_http_requests_total 'route="/token"') - $(prom_metric_sum "${before_app}" capacity_cascade_http_requests_total 'route="/token"')))
  app_admission_delta=$(($(prom_metric_sum "${after_app}" capacity_cascade_admission_rejections_total) - $(prom_metric_sum "${before_app}" capacity_cascade_admission_rejections_total)))
  sample_count="$(wc -l <"${scenario_dir}/samples.jsonl" | tr -d ' ')"
  during_count="$(jq -s '[.[] | select(.phase == "during")] | length' "${scenario_dir}/samples.jsonl")"
  app_peak="$(jq -s '[.[].application_in_flight] | max // 0' "${scenario_dir}/samples.jsonl")"
  proxy_peak="$(jq -s '[.[].proxy_upstream_active] | max // 0' "${scenario_dir}/samples.jsonl")"
  route_retry_count="$(jq -r '.inbound_retry_policy_count' "${mapping}")"
  route_retry_budget="$(jq -r '.inbound_retry_budget_max' "${mapping}")"

  local common_pass=false scenario_signal_pass=false
  if [[ "${pod_ready}" == true \
    && "${auto_injected}" == true \
    && "${observation_bypass}" == true \
    && "${scenario_threshold[${scenario}]}" -eq "${expected_capacity}" \
    && -n "${logical}" && "${logical}" -gt 0 \
    && "${logical}" == "${physical}" \
    && "${k6_retry}" -eq 0 \
    && "${downstream_delta}" -gt 0 \
    && "${proxy_retry_delta}" -eq 0 \
    && "${route_retry_budget}" -eq 0 \
    && "${app_admission_delta}" -eq 0 \
    && "${sample_count}" -ge 3 \
    && "${during_count}" -ge 1 ]]; then
    common_pass=true
  fi
  if [[ "${scenario}" == sidecar-control ]]; then
    if [[ "${overflow_delta}" -eq 0 && "${status_503}" -eq 0 ]] \
      && awk -v rate="${failure_rate}" 'BEGIN {exit !(rate == 0)}'; then
      scenario_signal_pass=true
    fi
  else
    if [[ "${overflow_delta}" -gt 0 && "${status_503}" -gt 0 \
      && "${downstream_5xx_delta}" -gt 0 && "${app_token_delta}" -lt "${logical}" \
      && "${upstream_delta}" -eq "${app_token_delta}" ]] \
      && awk -v rate="${failure_rate}" 'BEGIN {exit !(rate > 0)}'; then
      scenario_signal_pass=true
    fi
  fi
  if [[ "${common_pass}" == true && "${scenario_signal_pass}" == true ]]; then passed=true; fi

  scenario_contract["${scenario}"]="${passed}"
  scenario_logical["${scenario}"]="${logical}"
  scenario_failures["${scenario}"]="${failure_rate}"
  scenario_overflow["${scenario}"]="${overflow_delta}"

  jq -n \
    --arg scenario "${scenario}" --argjson passed "${passed}" \
    --argjson pod_ready "${pod_ready}" --argjson automatic_injection "${auto_injected}" \
    --argjson application_metrics_proxy_bypass "${observation_bypass}" \
    --argjson generated_max_requests "${scenario_threshold[${scenario}]}" \
    --argjson expected_max_requests "${expected_capacity}" \
    --argjson logical_requests "${logical}" --argjson physical_attempts "${physical}" \
    --argjson k6_retry_attempts "${k6_retry}" --argjson logical_failure_rate "${failure_rate}" \
    --argjson status_200 "${status_200}" --argjson status_503 "${status_503}" --argjson status_504 "${status_504}" \
    --argjson proxy_downstream_delta "${downstream_delta}" --argjson proxy_downstream_5xx_delta "${downstream_5xx_delta}" \
    --argjson proxy_upstream_delta "${upstream_delta}" --argjson proxy_active_overflow_delta "${overflow_delta}" \
    --argjson proxy_pending_overflow_delta "${pending_overflow_delta}" --argjson proxy_retry_delta "${proxy_retry_delta}" \
    --argjson proxy_timeout_delta "${timeout_delta}" --argjson inbound_route_retry_policy_count "${route_retry_count}" \
    --argjson inbound_route_retry_budget_max "${route_retry_budget}" \
    --argjson application_token_delta "${app_token_delta}" --argjson application_admission_rejection_delta "${app_admission_delta}" \
    --argjson sample_count "${sample_count}" --argjson during_sample_count "${during_count}" \
    --argjson application_in_flight_peak "${app_peak}" --argjson proxy_upstream_active_peak "${proxy_peak}" \
    '{passed:$passed,scenario:$scenario,pod_ready_2_of_2:$pod_ready,automatic_injection:$automatic_injection,
      application_metrics_proxy_bypass:$application_metrics_proxy_bypass,
      generated_max_requests:$generated_max_requests,expected_max_requests:$expected_max_requests,
      k6:{logical_requests:$logical_requests,physical_attempts:$physical_attempts,retry_attempts:$k6_retry_attempts,
        logical_failure_rate:$logical_failure_rate,status:{"200":$status_200,"503":$status_503,"504":$status_504}},
      proxy:{downstream_delta:$proxy_downstream_delta,downstream_5xx_delta:$proxy_downstream_5xx_delta,
        upstream_delta:$proxy_upstream_delta,active_overflow_delta:$proxy_active_overflow_delta,
        pending_overflow_delta:$proxy_pending_overflow_delta,retry_delta:$proxy_retry_delta,
        timeout_delta:$proxy_timeout_delta,inbound_route_retry_policy_count:$inbound_route_retry_policy_count,
        inbound_route_retry_budget_max:$inbound_route_retry_budget_max,
        upstream_active_peak:$proxy_upstream_active_peak},
      application:{token_delta:$application_token_delta,admission_rejection_delta:$application_admission_rejection_delta,
        max_in_flight:"0/unlimited",in_flight_peak:$application_in_flight_peak},
      sampling:{total:$sample_count,during:$during_sample_count}}' >"${scenario_dir}/contract.json"

  cat >"${scenario_dir}/summary.md" <<EOF
# ${scenario} L04 summary

> 단일 local exploratory evidence이며 production benchmark나 GitHub 설정 evidence가 아니다.

| Observation | Value |
| --- | ---: |
| Contract | ${passed} |
| Generated inbound max requests | ${scenario_threshold[${scenario}]} |
| Logical / physical / k6 retry | ${logical} / ${physical} / ${k6_retry} |
| Logical failure rate | ${failure_rate} |
| Downstream 200 / 503 / 504 | ${status_200} / ${status_503} / ${status_504} |
| Proxy downstream / upstream delta | ${downstream_delta} / ${upstream_delta} |
| Proxy downstream 5xx delta | ${downstream_5xx_delta} |
| Proxy active / pending overflow delta | ${overflow_delta} / ${pending_overflow_delta} |
| Proxy retry / timeout delta | ${proxy_retry_delta} / ${timeout_delta} |
| Inbound route retry policy count / max budget | ${route_retry_count} / ${route_retry_budget} |
| Application token delta | ${app_token_delta} |
| Application admission rejection delta | ${app_admission_delta} |
| Application / proxy active peak | ${app_peak} / ${proxy_peak} |
| Timestamped samples (during) | ${sample_count} (${during_count}) |

Actual metric name은 proxy-metric-mapping.json, absolute before/after는 proxy/application
snapshot, 시간 관계는 samples.jsonl에 보존했다.
EOF
}

run_scenario() {
  local scenario=$1
  local namespace="${SCENARIO_NAMESPACE[${scenario}]}"
  local release="${SCENARIO_RELEASE[${scenario}]}"
  local expected_capacity="${SCENARIO_CAPACITY[${scenario}]}"
  local manifest="${SCENARIO_MANIFEST[${scenario}]}"
  local retry_manifest="${SCENARIO_RETRY_MANIFEST[${scenario}]}"
  local scenario_dir="${result_dir}/${scenario}"
  local pod admin_port metrics_port admin_url metrics_url
  local pod_ready=false auto_injected=false observation_bypass=false
  local mapping_file="${scenario_dir}/proxy-metric-mapping.json"

  kubectl create namespace "${namespace}" >"${scenario_dir}/namespace-create.log"
  kubectl label namespace "${namespace}" istio-injection=enabled --overwrite \
    >"${scenario_dir}/namespace-injection-label.log"
  kubectl get namespace "${namespace}" -o json >"${scenario_dir}/namespace.json"

  kubectl apply --server-side --dry-run=server -f "${manifest}" \
    >"${scenario_dir}/sidecar-server-dry-run.log"
  kubectl apply -f "${manifest}" >"${scenario_dir}/sidecar-apply.log"
  kubectl get sidecar auth-sim-inbound-capacity --namespace "${namespace}" -o json \
    >"${scenario_dir}/sidecar-resource.json"

  printf '%s' "${admin_token}" \
    | kubectl create secret generic "${ADMIN_SECRET}" --namespace "${namespace}" \
      --from-file=token=/dev/stdin >"${scenario_dir}/secret-create.log"

  helm template "${release}" "${CHART_DIR}" --namespace "${namespace}" \
    --set-string image.repository="${IMAGE_REPOSITORY}" \
    --set-string image.tag="${IMAGE_TAG}" \
    --set-string adminSecret.name="${ADMIN_SECRET}" \
    --set-string adminSecret.key=token >"${scenario_dir}/auth-sim-rendered.yaml"
  if grep -q 'name: istio-proxy' "${scenario_dir}/auth-sim-rendered.yaml"; then
    printf 'source Deployment template must not contain a manual istio-proxy container\n' >&2
    return 1
  fi
  helm upgrade --install "${release}" "${CHART_DIR}" --namespace "${namespace}" \
    --set-string image.repository="${IMAGE_REPOSITORY}" \
    --set-string image.tag="${IMAGE_TAG}" \
    --set-string adminSecret.name="${ADMIN_SECRET}" \
    --set-string adminSecret.key=token \
    --wait --timeout 180s >"${scenario_dir}/auth-sim-helm-install.log" 2>&1
  scenario_deployed["${scenario}"]=true
  kubectl rollout status deployment/"${release}" --namespace "${namespace}" --timeout=180s \
    >"${scenario_dir}/rollout.log"
  pod="$(kubectl get pods --namespace "${namespace}" --selector "app.kubernetes.io/instance=${release}" \
    -o jsonpath='{.items[0].metadata.name}')"
  kubectl get deployment "${release}" --namespace "${namespace}" -o json \
    >"${scenario_dir}/deployment.json"
  kubectl get service "${release}" --namespace "${namespace}" -o json \
    >"${scenario_dir}/service.json"
  kubectl get endpointslice --namespace "${namespace}" --selector "kubernetes.io/service-name=${release}" -o json \
    >"${scenario_dir}/endpointslices.json"
  kubectl get pod "${pod}" --namespace "${namespace}" -o json >"${scenario_dir}/pod.json"
  kubectl get pod "${pod}" --namespace "${namespace}" -o wide >"${scenario_dir}/pod-wide.txt"
  kubectl get pod "${pod}" --namespace "${namespace}" \
    -o jsonpath='{range .spec.initContainers[*]}{.name}{"\t"}{.image}{"\t"}{.restartPolicy}{"\n"}{end}' >"${scenario_dir}/init-containers.txt"
  kubectl get pod "${pod}" --namespace "${namespace}" \
    -o jsonpath='{range .spec.containers[*]}{.name}{"\t"}{.image}{"\n"}{end}' >"${scenario_dir}/containers.txt"
  local ready_fraction app_ready proxy_ready proxy_spec_count deployment_proxy_count
  ready_fraction="$(awk 'NR == 2 {print $2}' "${scenario_dir}/pod-wide.txt")"
  app_ready="$(jq '[.status.containerStatuses[]? | select(.name=="auth-sim" and .ready==true)] | length' "${scenario_dir}/pod.json")"
  proxy_ready="$(jq '[.status.containerStatuses[]?,.status.initContainerStatuses[]? | select(.name=="istio-proxy" and .ready==true)] | length' "${scenario_dir}/pod.json")"
  proxy_spec_count="$(jq '[.spec.containers[]?,.spec.initContainers[]? | select(.name=="istio-proxy")] | length' "${scenario_dir}/pod.json")"
  deployment_proxy_count="$(jq '[.spec.template.spec.containers[]?,.spec.template.spec.initContainers[]? | select(.name=="istio-proxy")] | length' "${scenario_dir}/deployment.json")"
  if [[ "${ready_fraction}" == "2/2" && "${app_ready}" -eq 1 && "${proxy_ready}" -eq 1 ]]; then
    pod_ready=true
  fi
  if [[ "${proxy_spec_count}" -eq 1 && "${deployment_proxy_count}" -eq 0 ]]; then
    auto_injected=true
  fi
  if [[ "${pod_ready}" != true || "${auto_injected}" != true ]]; then
    printf 'injected Pod did not meet the Ready 2/2 automatic-injection contract\n' >&2
    return 1
  fi
  cp "${scenario_dir}/pod.json" "${scenario_dir}/pod-before-retry-disable.json"
  cp "${scenario_dir}/pod-wide.txt" "${scenario_dir}/pod-wide-before-retry-disable.txt"
  apply_retry_disable_patch "${namespace}" "${pod}" "${release}" "${retry_manifest}" "${scenario_dir}"
  pod="${patched_pod}"
  kubectl get pod "${pod}" --namespace "${namespace}" -o json >"${scenario_dir}/pod.json"
  kubectl get pod "${pod}" --namespace "${namespace}" -o wide >"${scenario_dir}/pod-wide.txt"
  kubectl get pod "${pod}" --namespace "${namespace}" \
    -o jsonpath='{range .spec.initContainers[*]}{.name}{"\t"}{.image}{"\t"}{.restartPolicy}{"\n"}{end}' >"${scenario_dir}/init-containers.txt"
  kubectl get pod "${pod}" --namespace "${namespace}" \
    -o jsonpath='{range .spec.containers[*]}{.name}{"\t"}{.image}{"\n"}{end}' >"${scenario_dir}/containers.txt"
  scenario_proxy_image["${scenario}"]="$(jq -r '[.spec.containers[]?,.spec.initContainers[]? | select(.name=="istio-proxy")][0].image' "${scenario_dir}/pod.json")"
  scenario_auth_image["${scenario}"]="$(jq -r '.spec.containers[] | select(.name=="auth-sim") | .image' "${scenario_dir}/pod.json")"
  if [[ "${proxy_image}" == not-captured ]]; then
    proxy_image="${scenario_proxy_image[${scenario}]}"
    proxy_image_id="$(jq -r '[.status.containerStatuses[]?,.status.initContainerStatuses[]? | select(.name=="istio-proxy")][0].imageID' "${scenario_dir}/pod.json")"
  fi

  # Envoy cluster stats are allocated lazily. Prime the real Service -> inbound sidecar path
  # from the non-injected load namespace before selecting names from actual proxy output.
  probe_service_datapath "${scenario}" "${namespace}" "${release}" "${scenario_dir}"
  discover_proxy_config "${scenario}" "${namespace}" "${pod}" "${scenario_dir}" "${expected_capacity}"
  if [[ "${envoy_version}" == not-captured ]]; then
    envoy_version="$(jq -r '.version' "${scenario_dir}/proxy-server-info.json")"
  fi

  start_port_forward "${namespace}" "${pod}" 9090 "${scenario_dir}/port-forward-admin.log" admin_pf_pid admin_port
  start_port_forward "${namespace}" "${pod}" 8080 "${scenario_dir}/port-forward-metrics.log" metrics_pf_pid metrics_port
  admin_url="http://127.0.0.1:${admin_port}"
  metrics_url="http://127.0.0.1:${metrics_port}"
  if ! wait_for_url "${admin_url}/admin/fault" || ! wait_for_url "${metrics_url}/metrics"; then
    printf 'application control/observation port-forward did not become ready\n' >&2
    return 1
  fi

  put_application_fault "${admin_url}" \
    '{"latency_ms":0,"error_rate":0,"max_in_flight":0,"seed":17082026}' \
    "${scenario_dir}/application-fault-reset-before.json"
  put_application_fault "${admin_url}" \
    "{\"latency_ms\":${APPLICATION_LATENCY_MS_VALUE},\"error_rate\":0,\"max_in_flight\":0,\"seed\":${FAULT_SEED_VALUE}}" \
    "${scenario_dir}/application-fault-applied.json"
  curl --fail --silent --show-error "${admin_url}/admin/fault" >"${scenario_dir}/application-fault-state.json"

  collect_proxy_stats "${namespace}" "${pod}" "${scenario_dir}/observation-proxy-before.txt"
  curl --fail --silent --show-error "${metrics_url}/metrics" >"${scenario_dir}/observation-application.prom"
  collect_proxy_stats "${namespace}" "${pod}" "${scenario_dir}/observation-proxy-after.txt"
  local proof_before proof_after proof_delta
  proof_before="$(stat_value "${scenario_dir}/observation-proxy-before.txt" "$(jq -r '.proxy_downstream_total' "${mapping_file}")")"
  proof_after="$(stat_value "${scenario_dir}/observation-proxy-after.txt" "$(jq -r '.proxy_downstream_total' "${mapping_file}")")"
  proof_delta=$((proof_after - proof_before))
  if [[ "${proof_delta}" -eq 0 ]]; then observation_bypass=true; fi
  jq -n --argjson proxy_downstream_delta "${proof_delta}" --argjson bypass "${observation_bypass}" \
    '{direct_pod_metrics_scrape_proxy_downstream_delta:$proxy_downstream_delta,bypasses_target_inbound_proxy:$bypass}' \
    >"${scenario_dir}/application-observation-path.json"
  if [[ "${observation_bypass}" != true ]]; then
    printf 'application metrics observation path changes target sidecar counters\n' >&2
    return 1
  fi

  curl --fail --silent --show-error "${metrics_url}/metrics" >"${scenario_dir}/application-metrics-before.prom"
  collect_proxy_stats "${namespace}" "${pod}" "${scenario_dir}/proxy-stats-before.txt"
  : >"${scenario_dir}/samples.jsonl"
  append_sample baseline "${scenario}" "${namespace}" "${pod}" "${metrics_url}" "${mapping_file}" \
    "${scenario_dir}/samples.jsonl"

  observer_stop_file="${scenario_dir}/observer.stop"
  observe_loop "${scenario}" "${namespace}" "${pod}" "${metrics_url}" "${mapping_file}" \
    "${scenario_dir}/samples.jsonl" "${observer_stop_file}" &
  observer_pid=$!

  create_k6_job "${scenario}" "${namespace}" "${release}" "${scenario_dir}" "${expected_capacity}" "${pod}"
  if [[ -n "${observer_stop_file}" ]]; then : >"${observer_stop_file}"; fi
  if ! wait "${observer_pid}"; then
    printf 'bounded observer failed\n' >&2
    return 1
  fi
  observer_pid=""

  if ! wait_for_proxy_idle "${namespace}" "${pod}" "${mapping_file}" "${scenario_dir}/proxy-idle-last.txt"; then
    printf 'target proxy did not return to idle before final snapshot\n' >&2
    return 1
  fi
  collect_proxy_stats "${namespace}" "${pod}" "${scenario_dir}/proxy-stats-after.txt"
  curl --fail --silent --show-error "${metrics_url}/metrics" >"${scenario_dir}/application-metrics-after.prom"
  append_sample after "${scenario}" "${namespace}" "${pod}" "${metrics_url}" "${mapping_file}" \
    "${scenario_dir}/samples.jsonl"

  kubectl top pod "${pod}" --namespace "${namespace}" --containers \
    >"${scenario_dir}/container-usage.txt" 2>"${scenario_dir}/container-usage-error.txt" || true
  put_application_fault "${admin_url}" \
    '{"latency_ms":0,"error_rate":0,"max_in_flight":0,"seed":17082026}' \
    "${scenario_dir}/application-fault-reset-after.json"
  curl --fail --silent --show-error "${admin_url}/admin/fault" >"${scenario_dir}/application-fault-state-after-reset.json"

  write_scenario_contract "${scenario}" "${scenario_dir}" "${expected_capacity}" \
    "${pod_ready}" "${auto_injected}" "${observation_bypass}"
  if [[ "${scenario_contract[${scenario}]}" != true ]]; then
    printf 'scenario contract failed: %s\n' "${scenario}" >&2
    return 1
  fi
  stop_scenario_backgrounds
}

printf 'L04 result directory: %s\n' "${result_dir}"

helm lint "${CHART_DIR}" --set-string image.repository="${IMAGE_REPOSITORY}" \
  --set-string image.tag="${IMAGE_TAG}" >"${result_dir}/auth-sim-helm-lint.log"
docker build --tag "${AUTH_SIM_IMAGE_VALUE}" . >"${result_dir}/auth-sim-docker-build.log" 2>&1
auth_sim_image_id="$(docker image inspect "${AUTH_SIM_IMAGE_VALUE}" --format '{{.Id}}')"
docker pull "${K6_IMAGE_VALUE}" >"${result_dir}/k6-image-pull.log" 2>&1
k6_image_id="$(docker image inspect "${K6_IMAGE_VALUE}" --format '{{.Id}}')"
k6_image_digest="$(docker image inspect "${K6_IMAGE_VALUE}" --format '{{index .RepoDigests 0}}')"

k3d cluster create "${CLUSTER_NAME}" \
  --servers 1 --agents 0 --image "${K3S_IMAGE_VALUE}" \
  --api-port 127.0.0.1:0 \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false \
  --k3s-arg '--disable=traefik@server:0' \
  --k3s-arg '--disable=servicelb@server:0' \
  --k3s-arg '--disable=local-storage@server:0' \
  --wait --timeout 180s >"${result_dir}/cluster-create.log" 2>&1
cluster_created=true
k3d kubeconfig get "${CLUSTER_NAME}" >"${kubeconfig_file}"
chmod 600 "${kubeconfig_file}"
api_binding="$(docker port "k3d-${CLUSTER_NAME}-serverlb" 6443/tcp \
  | awk '$1 ~ /^127\.0\.0\.1:[0-9]+$/ {print; exit}')"
api_port="${api_binding##*:}"
if [[ ! "${api_port}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'failed to resolve dynamic loopback Kubernetes API port\n' >&2
  exit 1
fi
sed -i "s#server: https://127.0.0.1:0#server: https://127.0.0.1:${api_port}#" "${kubeconfig_file}"
if grep -q 'server: https://127.0.0.1:0' "${kubeconfig_file}"; then
  printf 'temporary kubeconfig still contains API port 0\n' >&2
  exit 1
fi
kubectl wait --for=condition=Ready nodes --all --timeout=180s >"${result_dir}/node-ready.log"
node_ready=true
kubectl version --output=json >"${result_dir}/kubernetes-version.json"
kubernetes_server_version="$(jq -r '.serverVersion.gitVersion' "${result_dir}/kubernetes-version.json")"
kubectl get nodes -o wide >"${result_dir}/nodes.txt"

k3d image import "${AUTH_SIM_IMAGE_VALUE}" --cluster "${CLUSTER_NAME}" \
  >"${result_dir}/auth-sim-image-import.log" 2>&1
# k3d가 내부 ctr import 오류를 성공 exit로 감출 수 있으므로 auth-sim의 node runtime inventory를 직접 확인한다.
docker exec "k3d-${CLUSTER_NAME}-server-0" crictl images --output json \
  >"${result_dir}/node-images.json"
if [[ "$(jq --arg image "docker.io/${AUTH_SIM_IMAGE_VALUE}" '[.images[].repoTags[]? | select(. == $image)] | length' "${result_dir}/node-images.json")" -ne 1 ]]; then
  printf 'node runtime does not contain the imported auth-sim image\n' >&2
  exit 1
fi
images_imported=true

helm repo add istio https://istio-release.storage.googleapis.com/charts >"${result_dir}/istio-repo-add.log"
helm repo update istio >"${result_dir}/istio-repo-update.log"
helm pull istio/base --version "${ISTIO_VERSION_VALUE}" --destination "${chart_dir}"
helm pull istio/istiod --version "${ISTIO_VERSION_VALUE}" --destination "${chart_dir}"
base_chart="${chart_dir}/base-${ISTIO_VERSION_VALUE}.tgz"
istiod_chart="${chart_dir}/istiod-${ISTIO_VERSION_VALUE}.tgz"
base_chart_sha256="$(sha256sum "${base_chart}" | awk '{print $1}')"
istiod_chart_sha256="$(sha256sum "${istiod_chart}" | awk '{print $1}')"
jq -n --arg version "${ISTIO_VERSION_VALUE}" --arg base "${base_chart_sha256}" --arg istiod "${istiod_chart_sha256}" \
  '{version:$version,base_sha256:$base,istiod_sha256:$istiod}' >"${result_dir}/istio-chart-digests.json"
helm show chart "${base_chart}" >"${result_dir}/istio-base-chart.yaml"
helm show chart "${istiod_chart}" >"${result_dir}/istiod-chart.yaml"
helm template istio-base "${base_chart}" --namespace "${ISTIO_NAMESPACE}" \
  --set defaultRevision=default --kube-version 1.35.5 >"${result_dir}/istio-base-rendered.yaml"
helm template istiod "${istiod_chart}" --namespace "${ISTIO_NAMESPACE}" \
  --values "${ISTIOD_VALUES}" --kube-version 1.35.5 >"${result_dir}/istiod-rendered.yaml"
if grep -Eq '^kind: (Gateway|HorizontalPodAutoscaler|DaemonSet)$' "${result_dir}/istiod-rendered.yaml"; then
  printf 'out-of-scope Istio resource rendered\n' >&2
  exit 1
fi

helm upgrade --install istio-base "${base_chart}" --namespace "${ISTIO_NAMESPACE}" \
  --create-namespace --set defaultRevision=default --wait --timeout 180s \
  >"${result_dir}/istio-base-install.log" 2>&1
istio_base_deployed=true
helm upgrade --install istiod "${istiod_chart}" --namespace "${ISTIO_NAMESPACE}" \
  --values "${ISTIOD_VALUES}" --wait --timeout 180s >"${result_dir}/istiod-install.log" 2>&1
istiod_deployed=true
kubectl rollout status deployment/istiod --namespace "${ISTIO_NAMESPACE}" --timeout=180s \
  >"${result_dir}/istiod-rollout.log"
istio_ready=true
helm list --namespace "${ISTIO_NAMESPACE}" --output json >"${result_dir}/istio-releases.json"
kubectl get deployment,pod,service --namespace "${ISTIO_NAMESPACE}" -o wide \
  >"${result_dir}/istio-control-plane.txt"
kubectl get deployment istiod --namespace "${ISTIO_NAMESPACE}" -o json \
  >"${result_dir}/istiod-deployment.json"
istiod_image="$(jq -r '.spec.template.spec.containers[0].image' "${result_dir}/istiod-deployment.json")"
istiod_pod="$(kubectl get pod --namespace "${ISTIO_NAMESPACE}" --selector app=istiod -o jsonpath='{.items[0].metadata.name}')"
kubectl get pod "${istiod_pod}" --namespace "${ISTIO_NAMESPACE}" -o json >"${result_dir}/istiod-pod.json"
istiod_image_id="$(jq -r '.status.containerStatuses[0].imageID' "${result_dir}/istiod-pod.json")"
kubectl get crd sidecars.networking.istio.io -o yaml >"${result_dir}/sidecar-crd.yaml"
kubectl explain sidecar.spec.ingress.connectionPool.http.http2MaxRequests \
  --api-version=networking.istio.io/v1 >"${result_dir}/sidecar-field-explain.txt"

kubectl create namespace "${LOAD_NAMESPACE}" >"${result_dir}/load-namespace-create.log"
kubectl label namespace "${LOAD_NAMESPACE}" istio-injection=disabled --overwrite \
  >"${result_dir}/load-namespace-label.log"
kubectl get namespace "${LOAD_NAMESPACE}" -o json >"${result_dir}/load-namespace.json"
load_namespace_created=true

for scenario in "${RUN_SCENARIOS[@]}"; do
  run_scenario "${scenario}"
done

if [[ "${ACTION}" == pair ]]; then
  jq '.circuit_breakers.thresholds |= map(del(.max_requests))
      | .metadata.filter_metadata.istio.services |= map(.host="SCENARIO_SERVICE" | .name="SCENARIO_SERVICE" | .namespace="SCENARIO_NAMESPACE")' \
    "${result_dir}/sidecar-control/target-inbound-cluster-normalized.json" \
    | jq -S '.' >"${result_dir}/sidecar-control/target-inbound-cluster-without-max-requests.json"
  jq '.circuit_breakers.thresholds |= map(del(.max_requests))
      | .metadata.filter_metadata.istio.services |= map(.host="SCENARIO_SERVICE" | .name="SCENARIO_SERVICE" | .namespace="SCENARIO_NAMESPACE")' \
    "${result_dir}/sidecar-constrained/target-inbound-cluster-normalized.json" \
    | jq -S '.' >"${result_dir}/sidecar-constrained/target-inbound-cluster-without-max-requests.json"
  diff -u \
    "${result_dir}/sidecar-control/target-inbound-cluster-without-max-requests.json" \
    "${result_dir}/sidecar-constrained/target-inbound-cluster-without-max-requests.json" \
    >"${result_dir}/comparison-config-normalized.diff" || true
  diff -u \
    "${result_dir}/sidecar-control/target-inbound-cluster-normalized.json" \
    "${result_dir}/sidecar-constrained/target-inbound-cluster-normalized.json" \
    >"${result_dir}/comparison-config-actual.diff" || true
  jq -n \
    '{removed_comparison_field:"circuit_breakers.thresholds[].max_requests",
      normalized_isolation_identity_fields:[
        "metadata.filter_metadata.istio.services[].host",
        "metadata.filter_metadata.istio.services[].name",
        "metadata.filter_metadata.istio.services[].namespace"
      ],
      reason:"Separate namespace and release identities are required for fresh sidecar isolation; all other target cluster fields must remain equal."}' \
    >"${result_dir}/comparison-normalization.json"
  jq -n \
    --arg source_commit "${SOURCE_COMMIT}" --arg auth_image "${AUTH_SIM_IMAGE_VALUE}" \
    --arg k3s_image "${K3S_IMAGE_VALUE}" --arg istio_version "${ISTIO_VERSION_VALUE}" \
    --argjson replicas 1 --argjson application_latency_ms "${APPLICATION_LATENCY_MS_VALUE}" \
    --argjson logical_rate "${LOGICAL_RATE_VALUE}" --arg duration "${DURATION_VALUE}" \
    --arg request_timeout "${REQUEST_TIMEOUT_VALUE}" --argjson fault_seed "${FAULT_SEED_VALUE}" \
    --arg logical_id_namespace "${LOGICAL_ID_NAMESPACE_VALUE}" \
    --arg sample_interval "${SAMPLE_INTERVAL_SECONDS_VALUE}s" \
    '{source_commit:$source_commit,auth_sim_image:$auth_image,k3s_image:$k3s_image,
      istio_version:$istio_version,replicas:$replicas,
      application_fault:{latency_ms:$application_latency_ms,error_rate:0,max_in_flight:0,seed:$fault_seed},
      workload:{logical_rate:$logical_rate,duration:$duration,request_timeout:$request_timeout,
        logical_id_namespace:$logical_id_namespace,client_retry:"none",max_attempts:1,proxy_retry:"none"},
      observation:{method:"pilot-agent actual stats plus direct application metrics",sampling_interval:$sample_interval},
      only_difference:{field:"Sidecar ingress port 8080 connectionPool.http.http2MaxRequests",control:100,constrained:1}}' \
    >"${result_dir}/comparison-fixed-variables.json"
fi

exit 0
