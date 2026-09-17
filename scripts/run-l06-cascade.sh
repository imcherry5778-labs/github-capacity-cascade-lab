#!/usr/bin/env bash
# L06 connects the existing HAProxy, constrained inbound-sidecar, blind-HPA,
# and k6 retry mechanisms without claiming a production topology.
set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ACTION="${1:-pair}"
readonly CLUSTER_NAME="capacity-cascade-l06"
readonly ISTIO_NAMESPACE="istio-system"
readonly LOAD_NAMESPACE="capacity-cascade-l06-load"
readonly TARGET_NAMESPACE_PREFIX="capacity-cascade-l06"
readonly ADMIN_SECRET="auth-sim-admin"
readonly CHART_DIR="${PROJECT_ROOT}/charts/auth-sim"
readonly ISTIOD_VALUES="${PROJECT_ROOT}/l04/istiod-values.yaml"
readonly K3S_IMAGE_VALUE="${K3S_IMAGE:-rancher/k3s:v1.35.5-k3s1}"
readonly ISTIO_VERSION_VALUE="${ISTIO_VERSION:-1.30.4}"
readonly ISTIO_CHART_REPOSITORY_VALUE="${ISTIO_CHART_REPOSITORY:-https://blob.istio.io/istio-release/charts}"
readonly ISTIO_IMAGE_HUB_VALUE="${ISTIO_IMAGE_HUB:-docker.io/istio}"
readonly K6_IMAGE_VALUE="${K6_IMAGE:-grafana/k6:2.2.0}"
readonly HAPROXY_IMAGE_VALUE="${HAPROXY_IMAGE:-haproxy:3.2.23-alpine}"
readonly STABLE_RATE_VALUE="${STABLE_RATE:-1}"
readonly PEAK_RATE_VALUE="${PEAK_RATE:-4}"
readonly RECOVERY_RATE_VALUE="${RECOVERY_RATE:-1}"
readonly STABLE_DURATION_VALUE="${PHASE_STABLE_DURATION:-20s}"
readonly PEAK_DURATION_VALUE="${PHASE_PEAK_DURATION:-60s}"
readonly RECOVERY_DURATION_VALUE="${PHASE_RECOVERY_DURATION:-20s}"
readonly REQUEST_TIMEOUT_VALUE="${REQUEST_TIMEOUT:-2s}"
readonly APPLICATION_LATENCY_MS_VALUE="${APPLICATION_LATENCY_MS:-1000}"
readonly FAULT_SEED_VALUE="${FAULT_SEED:-17082026}"
readonly LOGICAL_ID_NAMESPACE_VALUE="${LOGICAL_ID_NAMESPACE:-l06-cascade-pair}"
readonly MAX_ATTEMPTS_VALUE="${MAX_ATTEMPTS:-3}"
readonly SAMPLE_INTERVAL_SECONDS_VALUE="${SAMPLE_INTERVAL_SECONDS:-1}"
readonly SIDECAR_CAPACITY_TARGET=1

cd "${PROJECT_ROOT}"

cluster_exists() {
  k3d cluster list --no-headers 2>/dev/null | awk -v cluster="${CLUSTER_NAME}" '$1 == cluster { found=1 } END { exit !found }'
}

remaining_cluster_containers() {
  docker ps -a --format '{{.Names}}' | awk -v prefix="k3d-${CLUSTER_NAME}-" 'index($0, prefix) == 1 { count++ } END { print count+0 }'
}

remaining_cluster_networks() {
  docker network ls --format '{{.Name}}' | awk -v network="k3d-${CLUSTER_NAME}" '$0 == network { count++ } END { print count+0 }'
}

owned_port_forward_pids() {
  ps -eo pid=,args= | awk '
    /(^|[[:space:]])kubectl([[:space:]]|$)/ \
      && /(^|[[:space:]])port-forward([[:space:]]|$)/ \
      && /--namespace[[:space:]]+capacity-cascade-l06/ { print $1 }
  '
}

remaining_owned_processes() {
  owned_port_forward_pids | awk 'NF { count++ } END { print count+0 }'
}

clean_owned_cluster() {
  local pid containers networks processes
  while IFS= read -r pid; do
    [[ -n "${pid}" && "${pid}" != "$$" ]] && kill -TERM "${pid}" 2>/dev/null || true
  done < <(owned_port_forward_pids)
  cluster_exists && k3d cluster delete "${CLUSTER_NAME}"
  containers="$(remaining_cluster_containers)"
  networks="$(remaining_cluster_networks)"
  processes="$(remaining_owned_processes)"
  if [[ "${containers}" -ne 0 || "${networks}" -ne 0 || "${processes}" -ne 0 ]]; then
    printf 'L06 cleanup incomplete: containers=%s networks=%s processes=%s\n' "${containers}" "${networks}" "${processes}" >&2
    return 1
  fi
  printf 'L06 owned cluster resources and port-forward processes are absent; evidence was preserved.\n'
}

if [[ "${ACTION}" == clean ]]; then
  for required_tool in docker k3d awk ps; do command -v "${required_tool}" >/dev/null 2>&1 || { printf 'required tool is missing: %s\n' "${required_tool}" >&2; exit 127; }; done
  docker info >/dev/null
  clean_owned_cluster
  exit 0
fi

declare -a RUN_SCENARIOS=()
case "${ACTION}" in
  pair) RUN_SCENARIOS=(cascade-no-retry cascade-retry) ;;
  smoke|cascade-no-retry) RUN_SCENARIOS=(cascade-no-retry) ;;
  cascade-retry) RUN_SCENARIOS=(cascade-retry) ;;
  *) printf 'usage: %s {pair|smoke|cascade-no-retry|cascade-retry|clean}\n' "$0" >&2; exit 2 ;;
esac

for image in "${K3S_IMAGE_VALUE}" "${K6_IMAGE_VALUE}" "${HAPROXY_IMAGE_VALUE}"; do
  case "${image}" in *:latest|latest) printf 'latest image is forbidden: %s\n' "${image}" >&2; exit 2 ;; *:*) ;; *) printf 'image must have an explicit tag: %s\n' "${image}" >&2; exit 2 ;; esac
done
[[ "${ISTIO_VERSION_VALUE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'ISTIO_VERSION must be an explicit patch version\n' >&2; exit 2; }
for rate in "${STABLE_RATE_VALUE}" "${PEAK_RATE_VALUE}" "${RECOVERY_RATE_VALUE}"; do [[ "${rate}" =~ ^[1-9][0-9]*$ ]] || { printf 'phase rates must be positive integers\n' >&2; exit 2; }; done
[[ "${PEAK_RATE_VALUE}" -ge "${STABLE_RATE_VALUE}" && "${PEAK_RATE_VALUE}" -ge "${RECOVERY_RATE_VALUE}" ]] || { printf 'PEAK_RATE must be at least each stable/recovery rate\n' >&2; exit 2; }
for duration in "${STABLE_DURATION_VALUE}" "${PEAK_DURATION_VALUE}" "${RECOVERY_DURATION_VALUE}" "${REQUEST_TIMEOUT_VALUE}"; do [[ "${duration}" =~ ^[1-9][0-9]*s$ ]] || { printf 'duration must be whole positive seconds: %s\n' "${duration}" >&2; exit 2; }; done
[[ "${APPLICATION_LATENCY_MS_VALUE}" =~ ^[1-9][0-9]*$ ]] || { printf 'APPLICATION_LATENCY_MS must be positive\n' >&2; exit 2; }
[[ "${FAULT_SEED_VALUE}" =~ ^[0-9]+$ && "${MAX_ATTEMPTS_VALUE}" =~ ^[2-9][0-9]*$ ]] || { printf 'FAULT_SEED/MAX_ATTEMPTS are invalid\n' >&2; exit 2; }
[[ "${SAMPLE_INTERVAL_SECONDS_VALUE}" =~ ^0\.[1-9][0-9]*$|^[1-9][0-9]*(\.[0-9]+)?$ ]] || { printf 'SAMPLE_INTERVAL_SECONDS must be positive\n' >&2; exit 2; }

for required_tool in git go k6 docker kubectl k3d helm curl awk sed grep jq ruby tee wc tr mktemp sha256sum diff cmp sort find ps make; do
  command -v "${required_tool}" >/dev/null 2>&1 || { printf 'required tool is missing: %s\n' "${required_tool}" >&2; exit 127; }
done
docker info >/dev/null
if cluster_exists; then
  printf 'refusing to replace existing exact L06 cluster: %s\nrun make l06-clean after inspecting it\n' "${CLUSTER_NAME}" >&2
  exit 1
fi
if [[ "$(remaining_cluster_containers)" -ne 0 || "$(remaining_cluster_networks)" -ne 0 || "$(remaining_owned_processes)" -ne 0 ]]; then
  printf 'refusing to run while exact L06 resources remain\n' >&2
  exit 1
fi

readonly SOURCE_COMMIT="$(git rev-parse HEAD)"
readonly SOURCE_SHORT="$(git rev-parse --short=12 HEAD)"
readonly IMAGE_REPOSITORY="${AUTH_SIM_REPOSITORY:-capacity-cascade/auth-sim}"
readonly IMAGE_TAG="${AUTH_SIM_TAG:-l06-${SOURCE_SHORT}}"
readonly AUTH_SIM_IMAGE_VALUE="${IMAGE_REPOSITORY}:${IMAGE_TAG}"
case "${AUTH_SIM_IMAGE_VALUE}" in *:latest|latest) printf 'latest auth-sim image is forbidden\n' >&2; exit 2 ;; esac

started_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
result_parent="results/full-capacity-cascade"
result_dir="${result_parent}/${timestamp}"
suffix=1
while [[ -e "${result_dir}" ]]; do result_dir="${result_parent}/${timestamp}-${suffix}"; suffix=$((suffix + 1)); done
mkdir -p "${result_dir}"
for scenario in "${RUN_SCENARIOS[@]}"; do mkdir -p "${result_dir}/${scenario}"; done

original_kubeconfig_set=false
original_kubeconfig_value=""
if [[ -v KUBECONFIG ]]; then original_kubeconfig_set=true; original_kubeconfig_value="${KUBECONFIG}"; fi
read_original_context() {
  if [[ "${original_kubeconfig_set}" == true ]]; then KUBECONFIG="${original_kubeconfig_value}" kubectl config current-context 2>/dev/null || printf __UNSET__; else env -u KUBECONFIG kubectl config current-context 2>/dev/null || printf __UNSET__; fi
}
file_hash_or_absent() { [[ -f "$1" ]] && sha256sum "$1" | awk '{print $1}' || printf absent; }
original_context="$(read_original_context)"
[[ "${original_context}" == __UNSET__ ]] && original_context_state=unset || original_context_state=set
original_helm_repository_config="$(helm env HELM_REPOSITORY_CONFIG)"
original_helm_repository_hash="$(file_hash_or_absent "${original_helm_repository_config}")"

umask 077
runtime_root="$(mktemp -d "${TMPDIR:-/tmp}/capacity-cascade-l06.XXXXXX")"
kubeconfig_file="${runtime_root}/kubeconfig"
helm_config_home="${runtime_root}/helm-config"
helm_cache_home="${runtime_root}/helm-cache"
helm_data_home="${runtime_root}/helm-data"
chart_dir="${runtime_root}/charts"
mkdir -p "${helm_config_home}" "${helm_cache_home}" "${helm_data_home}" "${chart_dir}"
: >"${kubeconfig_file}"; chmod 600 "${kubeconfig_file}"
export KUBECONFIG="${kubeconfig_file}" HELM_CONFIG_HOME="${helm_config_home}" HELM_CACHE_HOME="${helm_cache_home}" HELM_DATA_HOME="${helm_data_home}"

admin_token="l06-${RANDOM}-${RANDOM}-$$-$(date +%s)"
admin_pf_pid=""; metrics_pf_pid=""; haproxy_pf_pid=""; observer_pid=""; observer_stop_file=""
cluster_created=false; istio_base_deployed=false; istiod_deployed=false; cleanup_started=false; cluster_removed=false
temporary_kubeconfig_removed=false; temporary_helm_state_removed=false; original_context_unchanged=false; original_helm_config_unchanged=false
declare -A scenario_contract=() scenario_logical=() scenario_physical=() scenario_retry=() scenario_overflow=() scenario_haproxy_sessions=() scenario_haproxy_5xx=()
for scenario in "${RUN_SCENARIOS[@]}"; do scenario_contract["${scenario}"]=false; done

stop_process() { local pid=$1; [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null && { kill -TERM "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true; }; }
stop_scenario_backgrounds() {
  [[ -n "${observer_stop_file}" ]] && : >"${observer_stop_file}"
  [[ -n "${observer_pid}" ]] && wait "${observer_pid}" 2>/dev/null || true
  stop_process "${admin_pf_pid}"; stop_process "${metrics_pf_pid}"; stop_process "${haproxy_pf_pid}"
  admin_pf_pid=""; metrics_pf_pid=""; haproxy_pf_pid=""; observer_pid=""; observer_stop_file=""
}

write_cleanup() {
  local exit_code=$1 containers networks processes context_after helm_hash_after
  containers="$(remaining_cluster_containers)"; networks="$(remaining_cluster_networks)"; processes="$(remaining_owned_processes)"
  context_after="$(read_original_context)"; [[ "${context_after}" == "${original_context}" ]] && original_context_unchanged=true
  helm_hash_after="$(file_hash_or_absent "${original_helm_repository_config}")"; [[ "${helm_hash_after}" == "${original_helm_repository_hash}" ]] && original_helm_config_unchanged=true
  jq -n --argjson exit_code "${exit_code}" --argjson cluster_removed "${cluster_removed}" --argjson containers "${containers}" --argjson networks "${networks}" --argjson processes "${processes}" --argjson temporary_kubeconfig_removed "${temporary_kubeconfig_removed}" --argjson temporary_helm_state_removed "${temporary_helm_state_removed}" --argjson original_context_unchanged "${original_context_unchanged}" --argjson original_helm_config_unchanged "${original_helm_config_unchanged}" --arg original_context_state "${original_context_state}" '{runner_exit_code:$exit_code,cluster_removed:$cluster_removed,remaining_owned_containers:$containers,remaining_owned_networks:$networks,remaining_owned_port_forwards:$processes,temporary_kubeconfig_removed:$temporary_kubeconfig_removed,temporary_helm_state_removed:$temporary_helm_state_removed,original_context_state:$original_context_state,original_context_unchanged:$original_context_unchanged,original_helm_repository_config_unchanged:$original_helm_config_unchanged}' >"${result_dir}/cleanup.json"
}

cleanup() {
  local exit_code=$?
  [[ "${cleanup_started}" == true ]] && exit "${exit_code}"
  cleanup_started=true
  set +e
  stop_scenario_backgrounds
  if [[ "${cluster_created}" == true ]]; then
    kubectl delete namespace "${LOAD_NAMESPACE}" "${TARGET_NAMESPACE_PREFIX}-no-retry" "${TARGET_NAMESPACE_PREFIX}-retry" --ignore-not-found >"${result_dir}/namespace-delete.log" 2>&1
    [[ "${istiod_deployed}" == true ]] && helm uninstall istiod --namespace "${ISTIO_NAMESPACE}" >"${result_dir}/istiod-uninstall.log" 2>&1
    [[ "${istio_base_deployed}" == true ]] && helm uninstall istio-base --namespace "${ISTIO_NAMESPACE}" >"${result_dir}/istio-base-uninstall.log" 2>&1
    k3d cluster delete "${CLUSTER_NAME}" >"${result_dir}/cluster-delete.log" 2>&1 && cluster_removed=true
  else
    cluster_removed=true
  fi
  rm -rf "${runtime_root}"
  [[ ! -e "${runtime_root}" ]] && temporary_kubeconfig_removed=true && temporary_helm_state_removed=true
  write_cleanup "${exit_code}"
  exit "${exit_code}"
}
trap cleanup EXIT INT TERM

start_port_forward() {
  local namespace=$1 target=$2 remote_port=$3 log_file=$4 pid_var=$5 port_var=$6 pid port=""
  kubectl port-forward --namespace "${namespace}" "${target}" :"${remote_port}" >"${log_file}" 2>&1 & pid=$!
  for _ in {1..80}; do
    port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) ->.*/\1/p' "${log_file}" | head -n 1)"
    [[ -n "${port}" ]] && break
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.1
  done
  [[ -n "${port}" ]] || { printf 'port-forward did not become ready for %s/%s:%s\n' "${namespace}" "${target}" "${remote_port}" >&2; return 1; }
  printf -v "${pid_var}" '%s' "${pid}"; printf -v "${port_var}" '%s' "${port}"
}

wait_for_url() { local url=$1; for _ in {1..80}; do curl --fail --silent --show-error "${url}" >/dev/null 2>&1 && return 0; sleep 0.25; done; return 1; }
put_application_fault() { local url=$1 body=$2 output=$3; curl --fail --silent --show-error --request PUT --header "Authorization: Bearer ${admin_token}" --header 'Content-Type: application/json' --data "${body}" "${url}/admin/fault" >"${output}"; }
prom_metric_sum() { local file=$1 metric=$2 first_filter=${3:-}; awk -v metric="${metric}" -v first_filter="${first_filter}" 'index($0, metric) == 1 && $0 !~ /^#/ && (first_filter == "" || index($0, first_filter) > 0) { sum += $NF } END { printf "%.0f", sum+0 }' "${file}"; }
stat_value() { local file=$1 metric=$2; awk -F': ' -v metric="${metric}" '$1 == metric { print $2+0; found=1; exit } END { if (!found) print 0 }' "${file}"; }
select_actual_stat_name() { local file=$1 prefix=$2 suffix=$3 matches; matches="$(awk -F': ' -v prefix="${prefix}" -v suffix="${suffix}" 'index($1,prefix)==1 && substr($1,length($1)-length(suffix)+1)==suffix {print $1}' "${file}" | sort -u)"; [[ "$(printf '%s\n' "${matches}" | awk 'NF{count++}END{print count+0}')" -eq 1 ]] || { printf 'expected one actual proxy metric for %s%s, found %s\n' "${prefix}" "${suffix}" "${matches:-none}" >&2; return 1; }; printf '%s\n' "${matches}"; }
collect_proxy_stats() { kubectl exec --namespace "$1" "$2" -c istio-proxy -- pilot-agent request GET 'stats?filter=8080' >"$3"; }

haproxy_value() {
  local file=$1 pxname=$2 svname=$3 field=$4
  awk -F, -v pxname="${pxname}" -v svname="${svname}" -v field="${field}" '
    NR==1 { sub(/^#[[:space:]]*/, "", $1); for (i=1;i<=NF;i++) col[$i]=i; next }
    $col["pxname"]==pxname && $col["svname"]==svname { print $(col[field])+0; found=1; exit }
    END { if (!found) print 0 }
  ' "${file}"
}

phase_seconds() { local value=$1; printf '%s' "${value%s}"; }
phase_for_now() {
  local now elapsed stable peak
  now="$(date +%s)"; elapsed=$((now - workload_start_epoch)); stable="$(phase_seconds "${STABLE_DURATION_VALUE}")"; peak="$(phase_seconds "${PEAK_DURATION_VALUE}")"
  if (( elapsed < 0 )); then printf baseline; elif (( elapsed < stable )); then printf stable; elif (( elapsed < stable + peak )); then printf peak; elif (( elapsed < stable + peak + $(phase_seconds "${RECOVERY_DURATION_VALUE}") )); then printf recovery; else printf after; fi
}

discover_proxy_config() {
  local namespace=$1 pod=$2 scenario_dir=$3 config_dump cluster_names cluster_name hcm_prefixes hcm_prefix threshold retry_count retry_budget
  config_dump="${scenario_dir}/proxy-config-dump.json"
  kubectl exec --namespace "${namespace}" "${pod}" -c istio-proxy -- pilot-agent request GET config_dump >"${config_dump}"
  kubectl exec --namespace "${namespace}" "${pod}" -c istio-proxy -- pilot-agent request GET server_info >"${scenario_dir}/proxy-server-info.json"
  kubectl exec --namespace "${namespace}" "${pod}" -c istio-proxy -- pilot-agent request GET stats >"${scenario_dir}/proxy-stats-inventory.txt"
  cluster_names="$(jq -r '.. | objects | select(has("circuit_breakers")) | (.name? // empty) | select(test("^inbound[|]8080[|]"))' "${config_dump}" | sort -u)"
  [[ "$(printf '%s\n' "${cluster_names}" | awk 'NF{count++}END{print count+0}')" -eq 1 ]] || { printf 'expected one inbound 8080 cluster, found %s\n' "${cluster_names:-none}" >&2; return 1; }
  cluster_name="${cluster_names}"
  jq --arg name "${cluster_name}" '.. | objects | select((.name? // "") == $name and has("circuit_breakers"))' "${config_dump}" >"${scenario_dir}/target-inbound-cluster.json"
  threshold="$(jq -r '.circuit_breakers.thresholds[] | select((.priority // "DEFAULT") == "DEFAULT") | .max_requests // empty' "${scenario_dir}/target-inbound-cluster.json" | head -n 1)"
  [[ "${threshold}" == "${SIDECAR_CAPACITY_TARGET}" ]] || { printf 'expected actual max_requests=%s, got %s\n' "${SIDECAR_CAPACITY_TARGET}" "${threshold:-missing}" >&2; return 1; }
  hcm_prefixes="$(jq -r '.. | objects | select(((.filter_chain_match?.destination_port? // "") | tostring) == "8080") | .filters[]?.typed_config? | select((."@type"? // "") | endswith("HttpConnectionManager")) | .stat_prefix // empty' "${config_dump}" | sort -u)"
  [[ "$(printf '%s\n' "${hcm_prefixes}" | awk 'NF{count++}END{print count+0}')" -eq 1 ]] || { printf 'expected one inbound HCM stat prefix, found %s\n' "${hcm_prefixes:-none}" >&2; return 1; }
  hcm_prefix="${hcm_prefixes}"
  jq '[.. | objects | select(((.filter_chain_match?.destination_port? // "") | tostring) == "8080") | .filters[]?.typed_config? | select((."@type"? // "") | endswith("HttpConnectionManager"))]' "${config_dump}" >"${scenario_dir}/target-inbound-http-config.json"
  retry_count="$(jq '[.. | objects | select(has("retry_policy"))] | length' "${scenario_dir}/target-inbound-http-config.json")"
  retry_budget="$(jq '[.. | objects | .retry_policy?.num_retries? // empty] | max // 0' "${scenario_dir}/target-inbound-http-config.json")"
  [[ "${retry_count}" -eq 0 && "${retry_budget}" -eq 0 ]] || { printf 'no-proxy-retry contract failed\n' >&2; return 1; }
  local downstream_total downstream_active downstream_5xx upstream_total upstream_active active_overflow pending_overflow retry timeout
  downstream_total="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" "http.${hcm_prefix}" '.downstream_rq_total')"
  downstream_active="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" "http.${hcm_prefix}" '.downstream_rq_active')"
  downstream_5xx="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" "http.${hcm_prefix}" '.downstream_rq_5xx')"
  upstream_total="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" "cluster.${cluster_name}" '.upstream_rq_total')"
  upstream_active="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" "cluster.${cluster_name}" '.upstream_rq_active')"
  active_overflow="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" "cluster.${cluster_name}" '.upstream_rq_active_overflow')"
  pending_overflow="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" "cluster.${cluster_name}" '.upstream_rq_pending_overflow')"
  retry="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" "cluster.${cluster_name}" '.upstream_rq_retry')"
  timeout="$(select_actual_stat_name "${scenario_dir}/proxy-stats-inventory.txt" "cluster.${cluster_name}" '.upstream_rq_timeout')"
  jq -n --arg cluster "${cluster_name}" --arg hcm_stat_prefix "${hcm_prefix}" --arg proxy_downstream_total "${downstream_total}" --arg proxy_downstream_active "${downstream_active}" --arg proxy_downstream_5xx "${downstream_5xx}" --arg proxy_upstream_total "${upstream_total}" --arg proxy_upstream_active "${upstream_active}" --arg proxy_active_overflow "${active_overflow}" --arg proxy_pending_overflow "${pending_overflow}" --arg proxy_retry "${retry}" --arg proxy_timeout "${timeout}" --argjson inbound_retry_policy_count "${retry_count}" --argjson inbound_retry_budget_max "${retry_budget}" '{cluster:$cluster,hcm_stat_prefix:$hcm_stat_prefix,proxy_downstream_total:$proxy_downstream_total,proxy_downstream_active:$proxy_downstream_active,proxy_downstream_5xx:$proxy_downstream_5xx,proxy_upstream_total:$proxy_upstream_total,proxy_upstream_active:$proxy_upstream_active,proxy_active_overflow:$proxy_active_overflow,proxy_pending_overflow:$proxy_pending_overflow,proxy_retry:$proxy_retry,proxy_timeout:$proxy_timeout,inbound_retry_policy_count:$inbound_retry_policy_count,inbound_retry_budget_max:$inbound_retry_budget_max}' >"${scenario_dir}/proxy-metric-mapping.json"
}

append_sample() {
  local scenario=$1 namespace=$2 pod=$3 metrics_url=$4 haproxy_url=$5 mapping_file=$6 samples_file=$7 phase=${8:-} proxy_temp app_temp haproxy_temp hpa_temp pods_temp endpoints_temp timestamp_utc
  [[ -n "${phase}" ]] || phase="$(phase_for_now)"
  proxy_temp="${samples_file}.proxy.tmp"; app_temp="${samples_file}.app.tmp"; haproxy_temp="${samples_file}.haproxy.tmp"; hpa_temp="${samples_file}.hpa.tmp"; pods_temp="${samples_file}.pods.tmp"; endpoints_temp="${samples_file}.endpoints.tmp"
  timestamp_utc="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  curl --fail --silent --show-error "${metrics_url}/metrics" >"${app_temp}"
  collect_proxy_stats "${namespace}" "${pod}" "${proxy_temp}"
  curl --fail --silent --show-error "${haproxy_url}/stats;csv" >"${haproxy_temp}"
  kubectl get hpa auth-sim-scaling --namespace "${namespace}" -o json >"${hpa_temp}"
  kubectl get pods --namespace "${namespace}" --selector 'app.kubernetes.io/instance=auth-sim' -o json >"${pods_temp}"
  kubectl get endpointslice --namespace "${namespace}" --selector 'kubernetes.io/service-name=auth-sim' -o json >"${endpoints_temp}"
  local app_in_flight app_token app_admission downstream_total downstream_active downstream_5xx upstream_total upstream_active overflow pending_overflow proxy_retry proxy_timeout hqcur hqmax hscur hsmax hstot h5xx hecon heresp
  app_in_flight="$(prom_metric_sum "${app_temp}" capacity_cascade_http_in_flight)"; app_token="$(prom_metric_sum "${app_temp}" capacity_cascade_http_requests_total 'route="/token"')"; app_admission="$(prom_metric_sum "${app_temp}" capacity_cascade_admission_rejections_total)"
  downstream_total="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_downstream_total' "${mapping_file}")")"; downstream_active="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_downstream_active' "${mapping_file}")")"; downstream_5xx="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_downstream_5xx' "${mapping_file}")")"; upstream_total="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_upstream_total' "${mapping_file}")")"; upstream_active="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_upstream_active' "${mapping_file}")")"; overflow="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_active_overflow' "${mapping_file}")")"; pending_overflow="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_pending_overflow' "${mapping_file}")")"; proxy_retry="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_retry' "${mapping_file}")")"; proxy_timeout="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_timeout' "${mapping_file}")")"
  hqcur="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND qcur)"; hqmax="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND qmax)"; hscur="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND scur)"; hsmax="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND smax)"; hstot="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND stot)"; h5xx="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND hrsp_5xx)"; hecon="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND econ)"; heresp="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND eresp)"
  jq -cn --arg timestamp_utc "${timestamp_utc}" --arg scenario "${scenario}" --arg phase "${phase}" --argjson app_in_flight "${app_in_flight}" --argjson app_token "${app_token}" --argjson app_admission "${app_admission}" --argjson downstream_total "${downstream_total}" --argjson downstream_active "${downstream_active}" --argjson downstream_5xx "${downstream_5xx}" --argjson upstream_total "${upstream_total}" --argjson upstream_active "${upstream_active}" --argjson overflow "${overflow}" --argjson pending_overflow "${pending_overflow}" --argjson proxy_retry "${proxy_retry}" --argjson proxy_timeout "${proxy_timeout}" --argjson hqcur "${hqcur}" --argjson hqmax "${hqmax}" --argjson hscur "${hscur}" --argjson hsmax "${hsmax}" --argjson hstot "${hstot}" --argjson h5xx "${h5xx}" --argjson hecon "${hecon}" --argjson heresp "${heresp}" --slurpfile hpa "${hpa_temp}" --slurpfile pods "${pods_temp}" --slurpfile endpoints "${endpoints_temp}" '($hpa[0]) as $h | ($pods[0]) as $p | ($endpoints[0]) as $e | {timestamp_utc:$timestamp_utc,scenario:$scenario,phase:$phase,hpa:{current_replicas:($h.status.currentReplicas // 0),desired_replicas:($h.status.desiredReplicas // 0),last_scale_time:($h.status.lastScaleTime // null),current_metrics:($h.status.currentMetrics // []),conditions:($h.status.conditions // [])},haproxy:{backend:"auth_sim",queue_current:$hqcur,queue_max:$hqmax,sessions_current:$hscur,sessions_max:$hsmax,sessions_total:$hstot,responses_5xx:$h5xx,connection_errors:$hecon,response_errors:$heresp},proxy:{downstream_total:$downstream_total,downstream_active:$downstream_active,downstream_5xx:$downstream_5xx,upstream_total:$upstream_total,upstream_active:$upstream_active,active_overflow:$overflow,pending_overflow:$pending_overflow,retry:$proxy_retry,timeout:$proxy_timeout},application:{in_flight:$app_in_flight,token_requests:$app_token,admission_rejections:$app_admission},pods:($p.items | map({name:.metadata.name,phase:.status.phase,ready:([.status.conditions[]? | select(.type=="Ready" and .status=="True")] | length == 1)})),endpoints_ready:([$e.items[]?.endpoints[]? | select(.conditions.ready == true)] | length)}' >>"${samples_file}"
}

observe_loop() { local scenario=$1 namespace=$2 pod=$3 metrics_url=$4 haproxy_url=$5 mapping_file=$6 samples_file=$7 stop_file=$8; while [[ ! -e "${stop_file}" ]]; do append_sample "${scenario}" "${namespace}" "${pod}" "${metrics_url}" "${haproxy_url}" "${mapping_file}" "${samples_file}"; sleep "${SAMPLE_INTERVAL_SECONDS_VALUE}"; done; }

wait_for_idle() {
  local namespace=$1 pod=$2 mapping_file=$3 output=$4 stats upstream_active downstream_active
  for _ in {1..80}; do
    collect_proxy_stats "${namespace}" "${pod}" "${output}"; upstream_active="$(stat_value "${output}" "$(jq -r '.proxy_upstream_active' "${mapping_file}")")"; downstream_active="$(stat_value "${output}" "$(jq -r '.proxy_downstream_active' "${mapping_file}")")"
    [[ "${upstream_active}" -eq 0 && "${downstream_active}" -eq 0 ]] && return 0
    sleep 0.1
  done
  return 1
}

probe_service_datapath() {
  local scenario=$1 namespace=$2 scenario_dir=$3 probe phase=""
  probe="l06-datapath-${scenario#cascade-}"
  kubectl run "${probe}" --namespace "${LOAD_NAMESPACE}" \
    --image="${K6_IMAGE_VALUE}" --image-pull-policy=IfNotPresent --restart=Never \
    --labels="capacity-cascade-lab/owner=l06,capacity-cascade-lab/scenario=${scenario}" \
    --command -- /bin/sh -c "wget -qO- http://l06-haproxy.${namespace}.svc.cluster.local:8080/readyz" \
    >"${scenario_dir}/datapath-probe-create.log"
  for _ in {1..120}; do
    phase="$(kubectl get pod "${probe}" --namespace "${LOAD_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "${phase}" == Succeeded || "${phase}" == Failed ]] && break
    sleep 0.25
  done
  kubectl get pod "${probe}" --namespace "${LOAD_NAMESPACE}" -o json >"${scenario_dir}/datapath-probe-pod.json"
  kubectl logs "${probe}" --namespace "${LOAD_NAMESPACE}" >"${scenario_dir}/datapath-probe-response.txt" 2>"${scenario_dir}/datapath-probe-logs-error.txt" || true
  [[ "${phase}" == Succeeded ]] || { printf 'non-injected HAProxy datapath probe failed: phase=%s\n' "${phase:-unknown}" >&2; return 1; }
  [[ "$(jq '[.spec.containers[]?,.spec.initContainers[]? | select(.name=="istio-proxy")] | length' "${scenario_dir}/datapath-probe-pod.json")" -eq 0 ]] || { printf 'datapath probe unexpectedly received an Istio sidecar\n' >&2; return 1; }
  jq -e '.status == "ready"' "${scenario_dir}/datapath-probe-response.txt" >/dev/null || { printf 'datapath probe did not receive readiness response\n' >&2; return 1; }
  kubectl delete pod "${probe}" --namespace "${LOAD_NAMESPACE}" --wait=true --timeout=60s >"${scenario_dir}/datapath-probe-delete.log"
}

create_k6_job() {
  local scenario=$1 namespace=$2 scenario_dir=$3 proxy_image=$4 configmap job haproxy_fqdn load_pod result_ready=false
  configmap="l06-k6-${scenario#cascade-}"
  job="l06-k6-${scenario#cascade-}"
  haproxy_fqdn="l06-haproxy.${namespace}.svc.cluster.local"
  kubectl create configmap "${configmap}" --namespace "${LOAD_NAMESPACE}" --from-file=l06.js="${PROJECT_ROOT}/load/k6/l06.js" --from-file=config.js="${PROJECT_ROOT}/load/k6/lib/config.js" --from-file=retry.js="${PROJECT_ROOT}/load/k6/lib/retry.js" --from-file=summary.js="${PROJECT_ROOT}/load/k6/lib/summary.js" --dry-run=client -o yaml >"${scenario_dir}/k6-configmap.yaml"
  kubectl apply -f "${scenario_dir}/k6-configmap.yaml" >"${scenario_dir}/k6-configmap-apply.log"
  cat >"${scenario_dir}/k6-job.yaml" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${LOAD_NAMESPACE}
  labels: {capacity-cascade-lab/owner: l06, capacity-cascade-lab/scenario: ${scenario}}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 360
  template:
    metadata:
      labels: {capacity-cascade-lab/owner: l06, capacity-cascade-lab/scenario: ${scenario}, sidecar.istio.io/inject: "false"}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext: {fsGroup: 12345}
      containers:
        - name: k6
          image: ${K6_IMAGE_VALUE}
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh", "-c"]
          args:
            - |
              set +e
              k6 version > /results/k6-version.txt
              k6 run /scripts/l06.js
              code=\$?
              printf '%s\\n' "\${code}" > /results/k6.exit
              : > /results/k6.done
              while [ ! -f /results/collected ]; do sleep 1; done
              exit "\${code}"
          env:
            - {name: BASE_URL, value: "http://${haproxy_fqdn}:8080"}
            - {name: RESULT_DIR, value: "/results"}
            - {name: STARTED_AT_UTC, value: "${started_at_utc}"}
            - {name: GIT_COMMIT, value: "${SOURCE_COMMIT}"}
            - {name: GIT_DIRTY, value: "${git_dirty}"}
            - {name: GO_VERSION, value: "not-used"}
            - {name: K6_VERSION, value: "${K6_IMAGE_VALUE}"}
            - {name: DOCKER_VERSION, value: "not-used"}
            - {name: LAB_OS, value: "linux-container"}
            - {name: LAB_ARCH, value: "amd64"}
            - {name: L06_SCENARIO, value: "${scenario}"}
            - {name: STABLE_RATE, value: "${STABLE_RATE_VALUE}"}
            - {name: PEAK_RATE, value: "${PEAK_RATE_VALUE}"}
            - {name: RECOVERY_RATE, value: "${RECOVERY_RATE_VALUE}"}
            - {name: PHASE_STABLE_DURATION, value: "${STABLE_DURATION_VALUE}"}
            - {name: PHASE_PEAK_DURATION, value: "${PEAK_DURATION_VALUE}"}
            - {name: PHASE_RECOVERY_DURATION, value: "${RECOVERY_DURATION_VALUE}"}
            - {name: REQUEST_TIMEOUT, value: "${REQUEST_TIMEOUT_VALUE}"}
            - {name: APPLICATION_LATENCY_MS, value: "${APPLICATION_LATENCY_MS_VALUE}"}
            - {name: FAULT_SEED, value: "${FAULT_SEED_VALUE}"}
            - {name: LOGICAL_ID_NAMESPACE, value: "${LOGICAL_ID_NAMESPACE_VALUE}"}
            - {name: MAX_ATTEMPTS, value: "${MAX_ATTEMPTS_VALUE}"}
            - {name: SIDECAR_ACTIVE_REQUEST_TARGET, value: "${SIDECAR_CAPACITY_TARGET}"}
            - {name: REQUEST_PATH, value: "non-injected k6 Job -> HAProxy -> ClusterIP Service :8080 -> target Pod istio-proxy -> auth-sim"}
            - {name: AUTH_SIM_IMAGE, value: "${AUTH_SIM_IMAGE_VALUE}"}
            - {name: HAPROXY_IMAGE, value: "${HAPROXY_IMAGE_VALUE}"}
            - {name: K6_IMAGE, value: "${K6_IMAGE_VALUE}"}
            - {name: ISTIO_PROXY_IMAGE, value: "${proxy_image}"}
          securityContext:
            runAsNonRoot: true
            runAsUser: 12345
            runAsGroup: 12345
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
          volumeMounts:
            - {name: scripts, mountPath: /scripts/l06.js, subPath: l06.js, readOnly: true}
            - {name: scripts, mountPath: /scripts/lib/config.js, subPath: config.js, readOnly: true}
            - {name: scripts, mountPath: /scripts/lib/retry.js, subPath: retry.js, readOnly: true}
            - {name: scripts, mountPath: /scripts/lib/summary.js, subPath: summary.js, readOnly: true}
            - {name: results, mountPath: /results}
      volumes:
        - name: scripts
          configMap: {name: ${configmap}}
        - name: results
          emptyDir: {}
EOF
  workload_start_epoch="$(date +%s)"
  kubectl apply -f "${scenario_dir}/k6-job.yaml" >"${scenario_dir}/k6-job-apply.log"
  for _ in {1..60}; do load_pod="$(kubectl get pods --namespace "${LOAD_NAMESPACE}" --selector "job-name=${job}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"; [[ -n "${load_pod}" ]] && break; sleep 0.2; done
  [[ -n "${load_pod}" ]] || { printf 'k6 Job Pod was not created\n' >&2; return 1; }
  kubectl get pod "${load_pod}" --namespace "${LOAD_NAMESPACE}" -o json >"${scenario_dir}/k6-pod.json"
  [[ "$(jq '[.spec.containers[].name] | index("istio-proxy")' "${scenario_dir}/k6-pod.json")" == null ]] || { printf 'load generator must not have an injected sidecar\n' >&2; return 1; }
  for _ in {1..720}; do kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- test -f /results/k6.done >/dev/null 2>&1 && { result_ready=true; break; }; [[ "$(kubectl get pod "${load_pod}" --namespace "${LOAD_NAMESPACE}" -o jsonpath='{.status.phase}')" == Failed ]] && break; sleep 0.5; done
  kubectl logs --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 >"${scenario_dir}/k6-console.log" 2>&1 || true
  [[ "${result_ready}" == true ]] || { printf 'k6 result files did not become available\n' >&2; return 1; }
  kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- cat /results/k6.exit >"${scenario_dir}/k6.exit"
  kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- cat /results/k6-version.txt >"${scenario_dir}/k6-version.txt"
  kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- cat /results/metadata.json >"${scenario_dir}/k6-metadata.json"
  kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- cat /results/k6-summary.json >"${scenario_dir}/k6-summary.json"
  kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- cat /results/summary.md >"${scenario_dir}/k6-summary.md"
  kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- touch /results/collected >"${scenario_dir}/k6-collected.log"
  kubectl wait --for=condition=complete "job/${job}" --namespace "${LOAD_NAMESPACE}" --timeout=60s >"${scenario_dir}/k6-job-wait.log"
  kubectl get job "${job}" --namespace "${LOAD_NAMESPACE}" -o json >"${scenario_dir}/k6-job-state.json"
  [[ "$(tr -d '[:space:]' <"${scenario_dir}/k6.exit")" == 0 ]] || { printf 'k6 exited non-zero\n' >&2; return 1; }
}

write_scenario_contract() {
  local scenario=$1 scenario_dir=$2 samples="${scenario_dir}/samples.jsonl" summary="${scenario_dir}/k6-summary.json" logical physical retries failures p95 dropped status200 status503 status504 desired_max current_max pod_max overflow downstream upstream app_tokens app_admission haproxy_sessions haproxy_5xx phases final_proxy_active final_haproxy_sessions final_haproxy_queue passed=false
  logical="$(jq -r '.metrics.logical_requests.values.count' "${summary}")"; physical="$(jq -r '.metrics.physical_attempts.values.count' "${summary}")"; retries="$(jq -r '.metrics.retry_attempts.values.count // 0' "${summary}")"; failures="$(jq -r '.metrics.logical_failures.values.rate' "${summary}")"; p95="$(jq -r '.metrics.logical_request_duration.values["p(95)"]' "${summary}")"; dropped="$(jq -r '.metrics.dropped_iterations.values.count // 0' "${summary}")"
  status200="$(jq -r '.metrics.downstream_responses_200.values.count // 0' "${summary}")"; status503="$(jq -r '.metrics.downstream_responses_503.values.count // 0' "${summary}")"; status504="$(jq -r '.metrics.downstream_responses_504.values.count // 0' "${summary}")"
  desired_max="$(jq -s '[.[].hpa.desired_replicas] | max // 0' "${samples}")"; current_max="$(jq -s '[.[].hpa.current_replicas] | max // 0' "${samples}")"; pod_max="$(jq -s '[.[].pods | length] | max // 0' "${samples}")"
  overflow="$(jq -s '(.[-1].proxy.active_overflow // 0) - (.[0].proxy.active_overflow // 0)' "${samples}")"; downstream="$(jq -s '(.[-1].proxy.downstream_total // 0) - (.[0].proxy.downstream_total // 0)' "${samples}")"; upstream="$(jq -s '(.[-1].proxy.upstream_total // 0) - (.[0].proxy.upstream_total // 0)' "${samples}")"; app_tokens="$(jq -s '(.[-1].application.token_requests // 0) - (.[0].application.token_requests // 0)' "${samples}")"; app_admission="$(jq -s '(.[-1].application.admission_rejections // 0) - (.[0].application.admission_rejections // 0)' "${samples}")"; haproxy_sessions="$(jq -s '(.[-1].haproxy.sessions_total // 0) - (.[0].haproxy.sessions_total // 0)' "${samples}")"; haproxy_5xx="$(jq -s '(.[-1].haproxy.responses_5xx // 0) - (.[0].haproxy.responses_5xx // 0)' "${samples}")"
  phases="$(jq -s '[.[].phase] | unique' "${samples}")"; final_proxy_active="$(jq -s '.[-1].proxy.upstream_active + .[-1].proxy.downstream_active' "${samples}")"; final_haproxy_sessions="$(jq -s '.[-1].haproxy.sessions_current' "${samples}")"; final_haproxy_queue="$(jq -s '.[-1].haproxy.queue_current' "${samples}")"
  if [[ "${scenario}" == cascade-no-retry ]]; then
    [[ "${logical}" -eq "${physical}" && "${retries}" -eq 0 && "${dropped}" -eq 0 && "${status503}" -gt 0 && "${overflow}" -gt 0 && "${app_admission}" -eq 0 && "${desired_max}" -eq 1 && "${current_max}" -eq 1 && "${pod_max}" -eq 1 && "${final_proxy_active}" -eq 0 && "${final_haproxy_sessions}" -eq 0 && "${final_haproxy_queue}" -eq 0 && "${phases}" == *'"peak"'* && "${phases}" == *'"recovery"'* ]] && passed=true
  else
    [[ "${physical}" -gt "${logical}" && "${retries}" -gt 0 && "${dropped}" -eq 0 && "${status503}" -gt 0 && "${overflow}" -gt 0 && "${app_admission}" -eq 0 && "${desired_max}" -eq 1 && "${current_max}" -eq 1 && "${pod_max}" -eq 1 && "${final_proxy_active}" -eq 0 && "${final_haproxy_sessions}" -eq 0 && "${final_haproxy_queue}" -eq 0 && "${phases}" == *'"peak"'* && "${phases}" == *'"recovery"'* ]] && passed=true
  fi
  jq -n --argjson passed "${passed}" --arg scenario "${scenario}" --argjson logical "${logical}" --argjson physical "${physical}" --argjson retries "${retries}" --argjson failures "${failures}" --argjson p95 "${p95}" --argjson dropped "${dropped}" --argjson status200 "${status200}" --argjson status503 "${status503}" --argjson status504 "${status504}" --argjson desired_max "${desired_max}" --argjson current_max "${current_max}" --argjson pod_max "${pod_max}" --argjson overflow "${overflow}" --argjson downstream "${downstream}" --argjson upstream "${upstream}" --argjson app_tokens "${app_tokens}" --argjson app_admission "${app_admission}" --argjson haproxy_sessions "${haproxy_sessions}" --argjson haproxy_5xx "${haproxy_5xx}" --argjson phases "${phases}" '{passed:$passed,scenario:$scenario,k6:{logical_requests:$logical,physical_attempts:$physical,retry_attempts:$retries,logical_failure_rate:$failures,logical_p95_ms:$p95,dropped_iterations:$dropped,status:{"200":$status200,"503":$status503,"504":$status504}},hpa:{desired_replicas_max:$desired_max,current_replicas_max:$current_max,workload_pod_count_max:$pod_max},sidecar:{active_overflow_delta:$overflow,downstream_delta:$downstream,upstream_delta:$upstream},haproxy:{backend_sessions_delta:$haproxy_sessions,backend_responses_5xx_delta:$haproxy_5xx},application:{token_delta:$app_tokens,admission_rejection_delta:$app_admission},sampling:{phases:$phases,recovery_idle:true}}' >"${scenario_dir}/contract.json"
  scenario_contract["${scenario}"]="${passed}"; scenario_logical["${scenario}"]="${logical}"; scenario_physical["${scenario}"]="${physical}"; scenario_retry["${scenario}"]="${retries}"; scenario_overflow["${scenario}"]="${overflow}"; scenario_haproxy_sessions["${scenario}"]="${haproxy_sessions}"; scenario_haproxy_5xx["${scenario}"]="${haproxy_5xx}"
}

run_scenario() {
  local scenario=$1 suffix namespace scenario_dir service_fqdn pod old_pod proxy_image admin_port metrics_port haproxy_port admin_url metrics_url haproxy_url
  suffix="${scenario#cascade-}"
  namespace="${TARGET_NAMESPACE_PREFIX}-${suffix}"
  scenario_dir="${result_dir}/${scenario}"
  service_fqdn="auth-sim.${namespace}.svc.cluster.local"
  kubectl create namespace "${namespace}" >"${scenario_dir}/namespace-create.log"
  kubectl label namespace "${namespace}" istio-injection=enabled --overwrite >"${scenario_dir}/namespace-injection-label.log"
  sed "s/capacity-cascade-l06-target/${namespace}/g" "${PROJECT_ROOT}/l06/sidecar.yaml" >"${scenario_dir}/sidecar-rendered.yaml"
  sed "s/capacity-cascade-l06-target/${namespace}/g" "${PROJECT_ROOT}/l06/retry-disabled.yaml" >"${scenario_dir}/retry-disabled-rendered.yaml"
  sed "s/capacity-cascade-l06-target/${namespace}/g" "${PROJECT_ROOT}/l06/hpa-blind.yaml" >"${scenario_dir}/hpa-rendered.yaml"
  sed -e "s/capacity-cascade-l06-target/${namespace}/g" -e "s/AUTH_SIM_SERVICE_FQDN/${service_fqdn}/g" -e "s#HAPROXY_IMAGE#${HAPROXY_IMAGE_VALUE}#g" "${PROJECT_ROOT}/l06/haproxy.yaml" >"${scenario_dir}/haproxy-rendered.yaml"
  kubectl apply --server-side --dry-run=server -f "${scenario_dir}/sidecar-rendered.yaml" >"${scenario_dir}/sidecar-server-dry-run.log"
  kubectl apply -f "${scenario_dir}/sidecar-rendered.yaml" >"${scenario_dir}/sidecar-apply.log"
  printf '%s' "${admin_token}" | kubectl create secret generic "${ADMIN_SECRET}" --namespace "${namespace}" --from-file=token=/dev/stdin >"${scenario_dir}/secret-create.log"
  helm template auth-sim "${CHART_DIR}" --namespace "${namespace}" --set-string image.repository="${IMAGE_REPOSITORY}" --set-string image.tag="${IMAGE_TAG}" --set-string adminSecret.name="${ADMIN_SECRET}" --set-string adminSecret.key=token --set sidecarMetricsExporter.enabled=true >"${scenario_dir}/auth-sim-rendered.yaml"
  helm upgrade --install auth-sim "${CHART_DIR}" --namespace "${namespace}" --set-string image.repository="${IMAGE_REPOSITORY}" --set-string image.tag="${IMAGE_TAG}" --set-string adminSecret.name="${ADMIN_SECRET}" --set-string adminSecret.key=token --set sidecarMetricsExporter.enabled=true --wait --timeout 180s >"${scenario_dir}/auth-sim-helm-install.log" 2>&1
  kubectl rollout status deployment/auth-sim --namespace "${namespace}" --timeout=180s >"${scenario_dir}/auth-sim-rollout.log"
  old_pod="$(kubectl get pods --namespace "${namespace}" --selector 'app.kubernetes.io/instance=auth-sim' -o jsonpath='{.items[0].metadata.name}')"
  kubectl apply -f "${scenario_dir}/retry-disabled-rendered.yaml" >"${scenario_dir}/retry-disabled-apply.log"
  kubectl rollout restart deployment/auth-sim --namespace "${namespace}" >"${scenario_dir}/retry-disabled-rollout-restart.log"
  kubectl rollout status deployment/auth-sim --namespace "${namespace}" --timeout=180s >"${scenario_dir}/retry-disabled-rollout-status.log"
  pod="$(kubectl get pods --namespace "${namespace}" --selector 'app.kubernetes.io/instance=auth-sim' -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 1)][0].metadata.name // empty')"
  [[ -n "${pod}" && "${pod}" != "${old_pod}" ]] || { printf 'retry-disable rollout did not replace auth-sim Pod\n' >&2; return 1; }
  kubectl get deployment auth-sim --namespace "${namespace}" -o json >"${scenario_dir}/deployment.json"
  kubectl get service auth-sim --namespace "${namespace}" -o json >"${scenario_dir}/service.json"
  kubectl get pod "${pod}" --namespace "${namespace}" -o json >"${scenario_dir}/pod.json"
  [[ "$(jq '[.status.containerStatuses[]?,.status.initContainerStatuses[]? | select(.name=="auth-sim" and .ready==true)] | length' "${scenario_dir}/pod.json")" -eq 1 && "$(jq '[.status.containerStatuses[]?,.status.initContainerStatuses[]? | select(.name=="istio-proxy" and .ready==true)] | length' "${scenario_dir}/pod.json")" -eq 1 ]] || { printf 'injected target Pod is not Ready\n' >&2; return 1; }
  proxy_image="$(jq -r '[.spec.containers[]?,.spec.initContainers[]? | select(.name=="istio-proxy")][0].image' "${scenario_dir}/pod.json")"
  kubectl apply -f "${scenario_dir}/hpa-rendered.yaml" >"${scenario_dir}/hpa-apply.log"
  kubectl get hpa auth-sim-scaling --namespace "${namespace}" -o json >"${scenario_dir}/hpa-initial.json"
  kubectl apply -f "${scenario_dir}/haproxy-rendered.yaml" >"${scenario_dir}/haproxy-apply.log"
  kubectl rollout status deployment/l06-haproxy --namespace "${namespace}" --timeout=180s >"${scenario_dir}/haproxy-rollout.log"
  kubectl get deployment,pod,service --namespace "${namespace}" -l capacity-cascade-lab/owner=l06 -o json >"${scenario_dir}/haproxy-state.json"
  probe_service_datapath "${scenario}" "${namespace}" "${scenario_dir}"
  discover_proxy_config "${namespace}" "${pod}" "${scenario_dir}"
  start_port_forward "${namespace}" "pod/${pod}" 9090 "${scenario_dir}/port-forward-admin.log" admin_pf_pid admin_port
  start_port_forward "${namespace}" "pod/${pod}" 8080 "${scenario_dir}/port-forward-metrics.log" metrics_pf_pid metrics_port
  start_port_forward "${namespace}" service/l06-haproxy 8404 "${scenario_dir}/port-forward-haproxy-stats.log" haproxy_pf_pid haproxy_port
  admin_url="http://127.0.0.1:${admin_port}"; metrics_url="http://127.0.0.1:${metrics_port}"; haproxy_url="http://127.0.0.1:${haproxy_port}"
  wait_for_url "${admin_url}/admin/fault" && wait_for_url "${metrics_url}/metrics" && wait_for_url "${haproxy_url}/stats;csv" || { printf 'local observation path is unavailable\n' >&2; return 1; }
  collect_proxy_stats "${namespace}" "${pod}" "${scenario_dir}/observation-proxy-before.txt"
  curl --fail --silent --show-error "${metrics_url}/metrics" >"${scenario_dir}/observation-application.prom"
  collect_proxy_stats "${namespace}" "${pod}" "${scenario_dir}/observation-proxy-after.txt"
  local observation_before observation_after observation_delta
  observation_before="$(stat_value "${scenario_dir}/observation-proxy-before.txt" "$(jq -r '.proxy_downstream_total' "${scenario_dir}/proxy-metric-mapping.json")")"
  observation_after="$(stat_value "${scenario_dir}/observation-proxy-after.txt" "$(jq -r '.proxy_downstream_total' "${scenario_dir}/proxy-metric-mapping.json")")"
  observation_delta=$((observation_after - observation_before))
  jq -n --argjson proxy_downstream_delta "${observation_delta}" --argjson bypass "$( [[ "${observation_delta}" -eq 0 ]] && printf true || printf false )" '{direct_pod_metrics_scrape_proxy_downstream_delta:$proxy_downstream_delta,bypasses_target_inbound_proxy:$bypass}' >"${scenario_dir}/application-observation-path.json"
  [[ "${observation_delta}" -eq 0 ]] || { printf 'application observation path changes target sidecar counters\n' >&2; return 1; }
  put_application_fault "${admin_url}" '{"latency_ms":0,"error_rate":0,"max_in_flight":0,"seed":17082026}' "${scenario_dir}/application-fault-reset-before.json"
  put_application_fault "${admin_url}" "{\"latency_ms\":${APPLICATION_LATENCY_MS_VALUE},\"error_rate\":0,\"max_in_flight\":0,\"seed\":${FAULT_SEED_VALUE}}" "${scenario_dir}/application-fault-applied.json"
  curl --fail --silent --show-error "${admin_url}/admin/fault" >"${scenario_dir}/application-fault-state.json"
  curl --fail --silent --show-error "${haproxy_url}/stats;csv" >"${scenario_dir}/haproxy-stats-before.csv"
  : >"${scenario_dir}/samples.jsonl"
  # The observer is a background subshell, so set this before it starts rather
  # than inside create_k6_job where the later assignment would not propagate.
  workload_start_epoch="$(date +%s)"
  append_sample "${scenario}" "${namespace}" "${pod}" "${metrics_url}" "${haproxy_url}" "${scenario_dir}/proxy-metric-mapping.json" "${scenario_dir}/samples.jsonl" baseline
  observer_stop_file="${scenario_dir}/observer.stop"
  observe_loop "${scenario}" "${namespace}" "${pod}" "${metrics_url}" "${haproxy_url}" "${scenario_dir}/proxy-metric-mapping.json" "${scenario_dir}/samples.jsonl" "${observer_stop_file}" & observer_pid=$!
  create_k6_job "${scenario}" "${namespace}" "${scenario_dir}" "${proxy_image}"
  : >"${observer_stop_file}"; wait "${observer_pid}"; observer_pid=""
  wait_for_idle "${namespace}" "${pod}" "${scenario_dir}/proxy-metric-mapping.json" "${scenario_dir}/proxy-idle-last.txt" || { printf 'target sidecar did not return to idle\n' >&2; return 1; }
  append_sample "${scenario}" "${namespace}" "${pod}" "${metrics_url}" "${haproxy_url}" "${scenario_dir}/proxy-metric-mapping.json" "${scenario_dir}/samples.jsonl" after
  curl --fail --silent --show-error "${haproxy_url}/stats;csv" >"${scenario_dir}/haproxy-stats-after.csv"
  kubectl get hpa auth-sim-scaling --namespace "${namespace}" -o yaml >"${scenario_dir}/hpa-final.yaml"
  kubectl get events --namespace "${namespace}" --field-selector 'involvedObject.kind=HorizontalPodAutoscaler,involvedObject.name=auth-sim-scaling' -o json >"${scenario_dir}/hpa-events.json"
  kubectl get deployment,pods,endpointslice --namespace "${namespace}" -o json >"${scenario_dir}/workload-final.json"
  kubectl top pods --namespace "${namespace}" --containers >"${scenario_dir}/container-usage.txt" 2>"${scenario_dir}/container-usage-error.txt" || true
  put_application_fault "${admin_url}" '{"latency_ms":0,"error_rate":0,"max_in_flight":0,"seed":17082026}' "${scenario_dir}/application-fault-reset-after.json"
  write_scenario_contract "${scenario}" "${scenario_dir}"
  [[ "${scenario_contract[${scenario}]}" == true || "${ACTION}" == smoke ]] || { printf 'scenario contract failed: %s\n' "${scenario}" >&2; return 1; }
  stop_scenario_backgrounds
}

git_dirty=false
[[ -n "$(git status --porcelain --untracked-files=normal)" ]] && git_dirty=true
write_root_metadata() {
  jq -n --arg started_at_utc "${started_at_utc}" --arg git_commit "${SOURCE_COMMIT}" --argjson git_dirty "${git_dirty}" --arg action "${ACTION}" --arg k3s_image "${K3S_IMAGE_VALUE}" --arg istio_version "${ISTIO_VERSION_VALUE}" --arg istio_chart_repository "${ISTIO_CHART_REPOSITORY_VALUE}" --arg istio_image_hub "${ISTIO_IMAGE_HUB_VALUE}" --arg auth_image "${AUTH_SIM_IMAGE_VALUE}" --arg haproxy_image "${HAPROXY_IMAGE_VALUE}" --arg k6_image "${K6_IMAGE_VALUE}" --argjson stable_rate "${STABLE_RATE_VALUE}" --argjson peak_rate "${PEAK_RATE_VALUE}" --argjson recovery_rate "${RECOVERY_RATE_VALUE}" --arg stable_duration "${STABLE_DURATION_VALUE}" --arg peak_duration "${PEAK_DURATION_VALUE}" --arg recovery_duration "${RECOVERY_DURATION_VALUE}" --arg request_timeout "${REQUEST_TIMEOUT_VALUE}" --argjson application_latency_ms "${APPLICATION_LATENCY_MS_VALUE}" --arg sample_interval "${SAMPLE_INTERVAL_SECONDS_VALUE}s" --argjson max_attempts "${MAX_ATTEMPTS_VALUE}" '{project:"GitHub Capacity Cascade Lab",learning_unit:"L06",classification:"local exploratory evidence",scenario_mode:$action,started_at_utc:$started_at_utc,git_commit:$git_commit,git_dirty:$git_dirty,cluster:{name:"capacity-cascade-l06",servers:1,agents:0,k3s_image:$k3s_image,api_exposure:"dynamic loopback port"},istio:{version:$istio_version,chart_repository:$istio_chart_repository,image_hub:$istio_image_hub,install:"pinned Helm istio-base then istiod; no gateway or CNI"},images:{auth_sim:$auth_image,haproxy:$haproxy_image,k6:$k6_image},topology:"non-injected k6 Job -> HAProxy -> ClusterIP Service -> inbound istio-proxy -> auth-sim",comparison:{only_difference:"client retry policy",no_retry:{client_retry:"none",max_attempts:1},retry:{client_retry:"bad-immediate-retry",max_attempts:$max_attempts},haproxy_retry:"off (retries 0, no redispatch)",envoy_retry:"off (selected-version inbound EnvoyFilter)",sidecar_active_request_target:1,blind_hpa_metric:"ContainerResource auth-sim CPU utilization 80%",application_latency_ms:$application_latency_ms,request_timeout:$request_timeout,sampling_interval:$sample_interval,workload_stages:[{phase:"stable",rate:$stable_rate,duration:$stable_duration},{phase:"peak",rate:$peak_rate,duration:$peak_duration},{phase:"recovery",rate:$recovery_rate,duration:$recovery_duration}]},recovery_criterion:"After peak, selected sidecar active requests and HAProxy current queue/sessions return to zero in a timestamped final sample."}' >"${result_dir}/metadata.json"
}

printf 'L06 result directory: %s\n' "${result_dir}"
helm lint "${CHART_DIR}" --set-string image.repository="${IMAGE_REPOSITORY}" --set-string image.tag="${IMAGE_TAG}" >"${result_dir}/auth-sim-helm-lint.log"
docker build --tag "${AUTH_SIM_IMAGE_VALUE}" . >"${result_dir}/auth-sim-docker-build.log" 2>&1
docker pull "${K6_IMAGE_VALUE}" >"${result_dir}/k6-image-pull.log" 2>&1
docker pull "${HAPROXY_IMAGE_VALUE}" >"${result_dir}/haproxy-image-pull.log" 2>&1
k3d cluster create "${CLUSTER_NAME}" --servers 1 --agents 0 --image "${K3S_IMAGE_VALUE}" --api-port 127.0.0.1:0 --kubeconfig-update-default=false --kubeconfig-switch-context=false --k3s-arg '--disable=traefik@server:0' --k3s-arg '--disable=servicelb@server:0' --k3s-arg '--disable=local-storage@server:0' --wait --timeout 180s >"${result_dir}/cluster-create.log" 2>&1
cluster_created=true
k3d kubeconfig get "${CLUSTER_NAME}" >"${kubeconfig_file}"; chmod 600 "${kubeconfig_file}"
api_binding="$(docker port "k3d-${CLUSTER_NAME}-serverlb" 6443/tcp | awk '$1 ~ /^127\.0\.0\.1:[0-9]+$/ {print; exit}')"; api_port="${api_binding##*:}"
[[ "${api_port}" =~ ^[1-9][0-9]*$ ]] || { printf 'failed to resolve dynamic loopback Kubernetes API port\n' >&2; exit 1; }
sed -i "s#server: https://127.0.0.1:0#server: https://127.0.0.1:${api_port}#" "${kubeconfig_file}"
kubectl wait --for=condition=Ready nodes --all --timeout=180s >"${result_dir}/node-ready.log"
kubectl version --output=json >"${result_dir}/kubernetes-version.json"
k3d image import "${AUTH_SIM_IMAGE_VALUE}" --cluster "${CLUSTER_NAME}" >"${result_dir}/auth-sim-image-import.log" 2>&1
docker exec "k3d-${CLUSTER_NAME}-server-0" crictl images --output json >"${result_dir}/node-images.json"
[[ "$(jq --arg image "docker.io/${AUTH_SIM_IMAGE_VALUE}" '[.images[].repoTags[]? | select(. == $image)] | length' "${result_dir}/node-images.json")" -eq 1 ]] || { printf 'node runtime lacks imported auth-sim image\n' >&2; exit 1; }
helm repo add istio "${ISTIO_CHART_REPOSITORY_VALUE}" >"${result_dir}/istio-repo-add.log"
helm repo update istio >"${result_dir}/istio-repo-update.log"
helm pull istio/base --version "${ISTIO_VERSION_VALUE}" --destination "${chart_dir}"; helm pull istio/istiod --version "${ISTIO_VERSION_VALUE}" --destination "${chart_dir}"
base_chart="${chart_dir}/base-${ISTIO_VERSION_VALUE}.tgz"; istiod_chart="${chart_dir}/istiod-${ISTIO_VERSION_VALUE}.tgz"
helm upgrade --install istio-base "${base_chart}" --namespace "${ISTIO_NAMESPACE}" --create-namespace --set defaultRevision=default --wait --timeout 180s >"${result_dir}/istio-base-install.log" 2>&1; istio_base_deployed=true
helm upgrade --install istiod "${istiod_chart}" --namespace "${ISTIO_NAMESPACE}" --values "${ISTIOD_VALUES}" --set hub="${ISTIO_IMAGE_HUB_VALUE}" --set tag="${ISTIO_VERSION_VALUE}" --set global.hub="${ISTIO_IMAGE_HUB_VALUE}" --set global.tag="${ISTIO_VERSION_VALUE}" --wait --timeout 180s >"${result_dir}/istiod-install.log" 2>&1; istiod_deployed=true
kubectl rollout status deployment/istiod --namespace "${ISTIO_NAMESPACE}" --timeout=180s >"${result_dir}/istiod-rollout.log"
kubectl create namespace "${LOAD_NAMESPACE}" >"${result_dir}/load-namespace-create.log"; kubectl label namespace "${LOAD_NAMESPACE}" istio-injection=disabled --overwrite >"${result_dir}/load-namespace-label.log"
write_root_metadata
for scenario in "${RUN_SCENARIOS[@]}"; do run_scenario "${scenario}"; done

if [[ "${ACTION}" == pair ]]; then
  pair_passed=false
  if [[ "${scenario_contract[cascade-no-retry]}" == true && "${scenario_contract[cascade-retry]}" == true && "${scenario_physical[cascade-retry]}" -gt "${scenario_logical[cascade-retry]}" && "${scenario_retry[cascade-retry]}" -gt 0 && "${scenario_overflow[cascade-retry]}" -gt "${scenario_overflow[cascade-no-retry]}" && "${scenario_haproxy_sessions[cascade-retry]}" -gt "${scenario_haproxy_sessions[cascade-no-retry]}" && "${scenario_haproxy_5xx[cascade-retry]}" -gt "${scenario_haproxy_5xx[cascade-no-retry]}" ]]; then pair_passed=true; fi
  jq -n --argjson passed "${pair_passed}" --argjson no_retry "$(cat "${result_dir}/cascade-no-retry/contract.json")" --argjson retry "$(cat "${result_dir}/cascade-retry/contract.json")" '{passed:$passed,no_retry:$no_retry,retry:$retry,comparison:{only_difference:"client retry policy",required:"retry adds physical attempts and increases selected sidecar overflow plus HAProxy backend sessions/5xx under the fixed logical schedule"}}' >"${result_dir}/contract.json"
  [[ "${pair_passed}" == true ]] || { printf 'L06 paired acceptance contract failed\n' >&2; exit 1; }
fi

exit 0
