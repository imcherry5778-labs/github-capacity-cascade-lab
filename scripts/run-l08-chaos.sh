#!/usr/bin/env bash
# L08 executes a scoped, declarative Chaos Mesh NetworkChaos experiment
# on top of the established k6 -> HAProxy -> ClusterIP -> Sidecar -> auth-sim path.
set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ACTION="${1:-verify}"
readonly CLUSTER_NAME="capacity-cascade-l08"
readonly ISTIO_NAMESPACE="istio-system"
readonly CHAOS_NAMESPACE="chaos-mesh"
readonly LOAD_NAMESPACE="capacity-cascade-l08-load"
readonly TARGET_NAMESPACE="capacity-cascade-l08-target"
readonly ADMIN_SECRET="auth-sim-admin"
readonly CHART_DIR="${PROJECT_ROOT}/charts/auth-sim"
readonly ISTIOD_VALUES="${PROJECT_ROOT}/l04/istiod-values.yaml"
readonly CHAOS_VALUES="${PROJECT_ROOT}/l08/chaos-values.yaml"

readonly K3S_IMAGE_VALUE="${K3S_IMAGE:-rancher/k3s:v1.35.5-k3s1}"
readonly ISTIO_VERSION_VALUE="${ISTIO_VERSION:-1.30.4}"
readonly CHAOS_MESH_VERSION_VALUE="${CHAOS_MESH_VERSION:-2.8.4}"
readonly K6_IMAGE_VALUE="${K6_IMAGE:-grafana/k6:2.2.0}"
readonly HAPROXY_IMAGE_VALUE="${HAPROXY_IMAGE:-haproxy:3.2.23-alpine}"

GIT_DIRTY=false
[[ -n "$(git status --porcelain --untracked-files=normal)" ]] && GIT_DIRTY=true
readonly GIT_DIRTY

# Workload and fault parameters
readonly RATE_VALUE="${RATE:-3}"
readonly FAULT_LATENCY_VALUE="${FAULT_LATENCY:-600ms}"
readonly REQUEST_TIMEOUT_VALUE="${REQUEST_TIMEOUT:-2s}"
readonly SIDECAR_CAPACITY_TARGET=1
readonly SAMPLE_INTERVAL_SECONDS_VALUE="${SAMPLE_INTERVAL_SECONDS:-1}"

if [[ "${ACTION}" == "smoke" ]]; then
  readonly PRE_FAULT_DURATION_VALUE="${PRE_FAULT_DURATION:-5}"
  readonly FAULT_DURATION_VALUE="${FAULT_DURATION:-8}"
  readonly POST_FAULT_DURATION_VALUE="${POST_FAULT_DURATION:-5}"
elif [[ "${ACTION}" == "abort-smoke" ]]; then
  readonly PRE_FAULT_DURATION_VALUE="${PRE_FAULT_DURATION:-5}"
  readonly FAULT_DURATION_VALUE="${FAULT_DURATION:-15}"
  readonly POST_FAULT_DURATION_VALUE="${POST_FAULT_DURATION:-5}"
else
  readonly PRE_FAULT_DURATION_VALUE="${PRE_FAULT_DURATION:-20}"
  readonly FAULT_DURATION_VALUE="${FAULT_DURATION:-25}"
  readonly POST_FAULT_DURATION_VALUE="${POST_FAULT_DURATION:-25}"
fi
readonly TOTAL_DURATION_SECONDS=$((PRE_FAULT_DURATION_VALUE + FAULT_DURATION_VALUE + POST_FAULT_DURATION_VALUE))
readonly DURATION_VALUE="${TOTAL_DURATION_SECONDS}s"

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
      && /--namespace[[:space:]]+capacity-cascade-l08/ { print $1 }
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
  cluster_exists && k3d cluster delete "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  containers="$(remaining_cluster_containers)"
  networks="$(remaining_cluster_networks)"
  processes="$(remaining_owned_processes)"
  if [[ "${containers}" -ne 0 || "${networks}" -ne 0 || "${processes}" -ne 0 ]]; then
    printf 'L08 cleanup incomplete: containers=%s networks=%s processes=%s\n' "${containers}" "${networks}" "${processes}" >&2
    return 1
  fi
  printf 'L08 owned cluster resources and port-forward processes are absent; evidence was preserved.\n'
}

if [[ "${ACTION}" == "clean" ]]; then
  for required_tool in docker k3d awk ps; do
    command -v "${required_tool}" >/dev/null 2>&1 || { printf 'required tool is missing: %s\n' "${required_tool}" >&2; exit 127; }
  done
  docker info >/dev/null
  clean_owned_cluster
  exit 0
fi

if [[ "${ACTION}" == "doctor" ]]; then
  missing=0
  for tool in git go k6 docker kubectl k3d helm curl awk sed grep jq ruby ps make; do
    if ! command -v "${tool}" >/dev/null 2>&1; then printf '%-16s MISSING\n' "${tool}"; missing=1; else printf '%-16s OK\n' "${tool}"; fi
  done
  if ! docker info >/dev/null 2>&1; then printf '%-16s UNAVAILABLE\n' 'docker daemon'; missing=1; else printf '%-16s OK\n' 'docker daemon'; fi
  if grep -q 'iptable_filter' /proc/modules 2>/dev/null; then printf '%-16s OK\n' 'kernel iptable_filter'; else printf '%-16s MISSING (will be loaded)\n' 'kernel iptable_filter'; fi
  if grep -q 'sch_netem' /proc/modules 2>/dev/null; then printf '%-16s OK\n' 'kernel sch_netem'; else printf '%-16s MISSING (will be loaded)\n' 'kernel sch_netem'; fi
  exit "${missing}"
fi

case "${ACTION}" in
  verify|run|smoke|abort-smoke) ;;
  *) printf 'usage: %s {verify|run|smoke|abort-smoke|doctor|clean}\n' "$0" >&2; exit 2 ;;
esac

for image in "${K3S_IMAGE_VALUE}" "${K6_IMAGE_VALUE}" "${HAPROXY_IMAGE_VALUE}"; do
  case "${image}" in *:latest|latest) printf 'latest image is forbidden: %s\n' "${image}" >&2; exit 2 ;; *:*) ;; *) printf 'image must have an explicit tag: %s\n' "${image}" >&2; exit 2 ;; esac
done
[[ "${ISTIO_VERSION_VALUE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'ISTIO_VERSION must be an explicit patch version\n' >&2; exit 2; }
[[ "${CHAOS_MESH_VERSION_VALUE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'CHAOS_MESH_VERSION must be an explicit patch version\n' >&2; exit 2; }

for required_tool in git go k6 docker kubectl k3d helm make curl awk sed grep jq ruby ps mktemp; do
  command -v "${required_tool}" >/dev/null 2>&1 || { printf 'required tool is missing: %s\n' "${required_tool}" >&2; exit 127; }
done
docker info >/dev/null

# Kernel module check: ensure iptable_filter and sch_netem are loaded
if ! grep -q 'iptable_filter' /proc/modules 2>/dev/null; then
  docker run --rm --privileged -v /lib/modules:/lib/modules alpine:3.21.3 sh -c "which modprobe || apk add kmod >/dev/null 2>&1; modprobe iptable_filter" >/dev/null 2>&1 || true
fi
if ! grep -q 'sch_netem' /proc/modules 2>/dev/null; then
  docker run --rm --privileged -v /lib/modules:/lib/modules alpine:3.21.3 sh -c "which modprobe || apk add kmod >/dev/null 2>&1; modprobe sch_netem" >/dev/null 2>&1 || true
fi
grep -q 'iptable_filter' /proc/modules 2>/dev/null || { printf 'iptable_filter kernel module could not be loaded\n' >&2; exit 1; }
grep -q 'sch_netem' /proc/modules 2>/dev/null || { printf 'sch_netem kernel module could not be loaded\n' >&2; exit 1; }

if cluster_exists; then
  printf 'refusing to replace existing exact L08 cluster: %s\n' "${CLUSTER_NAME}" >&2
  printf 'run make l08-clean after inspecting that cluster\n' >&2
  exit 1
fi
if [[ "$(remaining_cluster_containers)" -ne 0 || "$(remaining_cluster_networks)" -ne 0 || "$(remaining_owned_processes)" -ne 0 ]]; then
  printf 'refusing to run while exact L08 Docker or port-forward resources remain\n' >&2
  exit 1
fi

readonly SOURCE_COMMIT="$(git rev-parse HEAD)"
readonly SOURCE_SHORT="$(git rev-parse --short=12 HEAD)"
readonly IMAGE_REPOSITORY="${AUTH_SIM_REPOSITORY:-capacity-cascade/auth-sim}"
readonly IMAGE_TAG="${AUTH_SIM_TAG:-l08-${SOURCE_SHORT}}"
readonly AUTH_SIM_IMAGE_VALUE="${IMAGE_REPOSITORY}:${IMAGE_TAG}"

readonly STARTED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
readonly TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
result_parent="results/chaos-mesh"
result_dir="${result_parent}/${TIMESTAMP}"
suffix=1
while [[ -e "${result_dir}" ]]; do
  result_dir="${result_parent}/${TIMESTAMP}-${suffix}"
  suffix=$((suffix + 1))
done
mkdir -p "${result_dir}"

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
original_context="$(read_original_context)"

original_helm_repository_config="$(helm env HELM_REPOSITORY_CONFIG 2>/dev/null || echo '')"
file_hash_or_absent() {
  local file=$1
  if [[ -n "${file}" && -f "${file}" ]]; then
    sha256sum "${file}" | awk '{print $1}'
  else
    printf '__ABSENT__'
  fi
}
original_helm_repository_hash="$(file_hash_or_absent "${original_helm_repository_config}")"

umask 077
runtime_root="$(mktemp -d "${TMPDIR:-/tmp}/capacity-cascade-l08.XXXXXX")"
kubeconfig_file="${runtime_root}/kubeconfig"
: >"${kubeconfig_file}"
chmod 600 "${kubeconfig_file}"
export KUBECONFIG="${kubeconfig_file}"

helm_config_home="${runtime_root}/helm-config"
helm_cache_home="${runtime_root}/helm-cache"
helm_data_home="${runtime_root}/helm-data"
chart_cache_dir="${runtime_root}/charts"
mkdir -p "${helm_config_home}" "${helm_cache_home}" "${helm_data_home}" "${chart_cache_dir}"
export HELM_CONFIG_HOME="${helm_config_home}"
export HELM_CACHE_HOME="${helm_cache_home}"
export HELM_DATA_HOME="${helm_data_home}"

admin_token="l08-${RANDOM}-${RANDOM}-$$-$(date +%s)"
admin_pf_pid=""
metrics_pf_pid=""
haproxy_pf_pid=""
observer_pid=""
admin_port=""
metrics_port=""
haproxy_port=""
workload_start_epoch=0
t_injected_epoch=0
t_recovered_epoch=0
t_injected_utc=""
t_recovered_utc=""
fault_applied=false
fault_injected=false
fault_recovered=false
abort_triggered=false
scenario_passed=false

stop_background_processes() {
  local pid
  for pid in "${admin_pf_pid}" "${metrics_pf_pid}" "${haproxy_pf_pid}" "${observer_pid}"; do
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill -TERM "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
  admin_pf_pid=""; metrics_pf_pid=""; haproxy_pf_pid=""; observer_pid=""
}

cleanup_chaos_cr() {
  if [[ -f "${kubeconfig_file}" ]] && cluster_exists; then
    kubectl delete networkchaos --all --all-namespaces --timeout=15s >/dev/null 2>&1 || true
  fi
}

on_exit() {
  local exit_code=$?
  trap - EXIT
  set +e
  stop_background_processes
  cleanup_chaos_cr
  clean_owned_cluster

  local temp_kube_removed=false temp_helm_removed=false orig_context_unchanged=false orig_helm_unchanged=false
  if [[ -d "${runtime_root}" ]]; then
    rm -rf "${runtime_root}"
  fi
  [[ ! -d "${runtime_root}" ]] && temp_kube_removed=true && temp_helm_removed=true

  local cur_context
  cur_context="$(read_original_context)"
  [[ "${cur_context}" == "${original_context}" ]] && orig_context_unchanged=true

  local cur_helm_hash
  cur_helm_hash="$(file_hash_or_absent "${original_helm_repository_config}")"
  [[ "${cur_helm_hash}" == "${original_helm_repository_hash}" ]] && orig_helm_unchanged=true

  local remaining_containers remaining_networks remaining_procs
  remaining_containers="$(remaining_cluster_containers)"
  remaining_networks="$(remaining_cluster_networks)"
  remaining_procs="$(remaining_owned_processes)"

  jq -n \
    --argjson exit_code "${exit_code}" \
    --argjson cluster_removed "$([[ ! $(cluster_exists) ]] && echo true || echo false)" \
    --argjson remaining_containers "${remaining_containers}" \
    --argjson remaining_networks "${remaining_networks}" \
    --argjson remaining_processes "${remaining_procs}" \
    --argjson temporary_kubeconfig_removed "${temp_kube_removed}" \
    --argjson temporary_helm_state_removed "${temp_helm_removed}" \
    --argjson original_context_unchanged "${orig_context_unchanged}" \
    --argjson original_helm_repository_config_unchanged "${orig_helm_unchanged}" \
    '{
      runner_exit_code: $exit_code,
      cluster_removed: $cluster_removed,
      remaining_owned_containers: $remaining_containers,
      remaining_owned_networks: $remaining_networks,
      remaining_owned_port_forwards: $remaining_processes,
      temporary_kubeconfig_removed: $temporary_kubeconfig_removed,
      temporary_helm_state_removed: $temporary_helm_state_removed,
      original_context_unchanged: $original_context_unchanged,
      original_helm_repository_config_unchanged: $original_helm_repository_config_unchanged
    }' > "${result_dir}/cleanup.json"

  exit "${exit_code}"
}
trap on_exit EXIT

# Start Port forward helper
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

phase_for_now() {
  local now elapsed
  now="$(date +%s)"; elapsed=$((now - workload_start_epoch))
  if (( elapsed < 0 )); then
    printf baseline
  elif (( elapsed < PRE_FAULT_DURATION_VALUE )); then
    printf pre-fault
  elif (( elapsed < PRE_FAULT_DURATION_VALUE + FAULT_DURATION_VALUE )); then
    printf fault
  elif (( elapsed < TOTAL_DURATION_SECONDS )); then
    printf post-fault
  else
    printf after
  fi
}

append_sample() {
  local scenario=$1 namespace=$2 pod=$3 metrics_url=$4 haproxy_url=$5 mapping_file=$6 samples_file=$7 phase=${8:-}
  local proxy_temp app_temp haproxy_temp hpa_temp pods_temp endpoints_temp chaos_temp timestamp_utc
  [[ -n "${phase}" ]] || phase="$(phase_for_now)"
  proxy_temp="${samples_file}.proxy.tmp"; app_temp="${samples_file}.app.tmp"; haproxy_temp="${samples_file}.haproxy.tmp"
  hpa_temp="${samples_file}.hpa.tmp"; pods_temp="${samples_file}.pods.tmp"; endpoints_temp="${samples_file}.endpoints.tmp"
  chaos_temp="${samples_file}.chaos.tmp"
  timestamp_utc="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"

  curl --fail --silent --show-error "${metrics_url}/metrics" >"${app_temp}" 2>/dev/null || echo "" >"${app_temp}"
  collect_proxy_stats "${namespace}" "${pod}" "${proxy_temp}" 2>/dev/null || echo "" >"${proxy_temp}"
  curl --fail --silent --show-error "${haproxy_url}/stats;csv" >"${haproxy_temp}" 2>/dev/null || echo "" >"${haproxy_temp}"
  kubectl get hpa auth-sim-scaling --namespace "${namespace}" -o json >"${hpa_temp}" 2>/dev/null || echo "{}" >"${hpa_temp}"
  kubectl get pods --namespace "${namespace}" --selector 'app.kubernetes.io/name=auth-sim' -o json >"${pods_temp}" 2>/dev/null || echo "{}" >"${pods_temp}"
  kubectl get endpointslice --namespace "${namespace}" --selector 'kubernetes.io/service-name=auth-sim' -o json >"${endpoints_temp}" 2>/dev/null || echo "{}" >"${endpoints_temp}"
  kubectl get networkchaos auth-sim-delay --namespace "${namespace}" -o json >"${chaos_temp}" 2>/dev/null || echo "{}" >"${chaos_temp}"

  local app_in_flight app_token app_admission downstream_total downstream_active downstream_5xx upstream_total upstream_active overflow pending_overflow proxy_retry proxy_timeout hqcur hqmax hscur hsmax hstot h5xx hecon heresp
  app_in_flight="$(prom_metric_sum "${app_temp}" capacity_cascade_http_in_flight)"
  app_token="$(prom_metric_sum "${app_temp}" capacity_cascade_http_requests_total 'route="/token"')"
  app_admission="$(prom_metric_sum "${app_temp}" capacity_cascade_admission_rejections_total)"

  downstream_total="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_downstream_total' "${mapping_file}")")"
  downstream_active="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_downstream_active' "${mapping_file}")")"
  downstream_5xx="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_downstream_5xx' "${mapping_file}")")"
  upstream_total="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_upstream_total' "${mapping_file}")")"
  upstream_active="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_upstream_active' "${mapping_file}")")"
  overflow="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_active_overflow' "${mapping_file}")")"
  pending_overflow="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_pending_overflow' "${mapping_file}")")"
  proxy_retry="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_retry' "${mapping_file}")")"
  proxy_timeout="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_timeout' "${mapping_file}")")"

  hqcur="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND qcur)"
  hqmax="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND qmax)"
  hscur="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND scur)"
  hsmax="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND smax)"
  hstot="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND stot)"
  h5xx="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND hrsp_5xx)"
  hecon="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND econ)"
  heresp="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND eresp)"

  jq -cn \
    --arg timestamp_utc "${timestamp_utc}" \
    --arg scenario "${scenario}" \
    --arg phase "${phase}" \
    --argjson app_in_flight "${app_in_flight}" \
    --argjson app_token "${app_token}" \
    --argjson app_admission "${app_admission}" \
    --argjson downstream_total "${downstream_total}" \
    --argjson downstream_active "${downstream_active}" \
    --argjson downstream_5xx "${downstream_5xx}" \
    --argjson upstream_total "${upstream_total}" \
    --argjson upstream_active "${upstream_active}" \
    --argjson overflow "${overflow}" \
    --argjson pending_overflow "${pending_overflow}" \
    --argjson proxy_retry "${proxy_retry}" \
    --argjson proxy_timeout "${proxy_timeout}" \
    --argjson hqcur "${hqcur}" \
    --argjson hqmax "${hqmax}" \
    --argjson hscur "${hscur}" \
    --argjson hsmax "${hsmax}" \
    --argjson hstot "${hstot}" \
    --argjson h5xx "${h5xx}" \
    --argjson hecon "${hecon}" \
    --argjson heresp "${heresp}" \
    --slurpfile hpa "${hpa_temp}" \
    --slurpfile pods "${pods_temp}" \
    --slurpfile endpoints "${endpoints_temp}" \
    --slurpfile chaos "${chaos_temp}" \
    '
      ($hpa[0]) as $h | ($pods[0]) as $p | ($endpoints[0]) as $e | ($chaos[0]) as $c |
      {
        timestamp_utc: $timestamp_utc,
        scenario: $scenario,
        phase: $phase,
        chaos: {
          applied: ($c.metadata?.name != null),
          selected: (([$c.status?.conditions[]? | select(.type=="Selected" and .status=="True")] | length) > 0),
          injected: (([$c.status?.conditions[]? | select(.type=="AllInjected" and .status=="True")] | length) > 0),
          recovered: (([$c.status?.conditions[]? | select(.type=="AllRecovered" and .status=="True")] | length) > 0),
          phase: ($c.status?.experiment?.containerRecords[0]?.phase // "None")
        },
        hpa: {
          current_replicas: ($h.status?.currentReplicas // 0),
          desired_replicas: ($h.status?.desiredReplicas // 0),
          conditions: ($h.status?.conditions // [])
        },
        haproxy: {
          backend: "auth_sim",
          queue_current: $hqcur,
          queue_max: $hqmax,
          sessions_current: $hscur,
          sessions_max: $hsmax,
          sessions_total: $hstot,
          responses_5xx: $h5xx,
          connection_errors: $hecon,
          response_errors: $heresp
        },
        proxy: {
          downstream_total: $downstream_total,
          downstream_active: $downstream_active,
          downstream_5xx: $downstream_5xx,
          upstream_total: $upstream_total,
          upstream_active: $upstream_active,
          active_overflow: $overflow,
          pending_overflow: $pending_overflow,
          retry: $proxy_retry,
          timeout: $proxy_timeout
        },
        application: {
          in_flight: $app_in_flight,
          token_requests: $app_token,
          admission_rejections: $app_admission
        },
        pods: (($p.items // []) | map({name:.metadata.name, phase:.status.phase, ready:([.status?.conditions[]? | select(.type=="Ready" and .status=="True")] | length == 1)})),
        endpoints_ready: (([($e.items // [])[]?.endpoints[]? | select(.conditions?.ready == true)] | length))
      }
    ' >>"${samples_file}"
}

observe_loop() {
  local scenario=$1 namespace=$2 pod=$3 metrics_url=$4 haproxy_url=$5 mapping_file=$6 samples_file=$7 stop_file=$8
  while [[ ! -e "${stop_file}" ]]; do
    append_sample "${scenario}" "${namespace}" "${pod}" "${metrics_url}" "${haproxy_url}" "${mapping_file}" "${samples_file}"
    sleep "${SAMPLE_INTERVAL_SECONDS_VALUE}"
  done
}

wait_for_idle() {
  local namespace=$1 pod=$2 mapping_file=$3 output=$4 upstream_active downstream_active
  for _ in {1..80}; do
    collect_proxy_stats "${namespace}" "${pod}" "${output}"
    upstream_active="$(stat_value "${output}" "$(jq -r '.proxy_upstream_active' "${mapping_file}")")"
    downstream_active="$(stat_value "${output}" "$(jq -r '.proxy_downstream_active' "${mapping_file}")")"
    [[ "${upstream_active}" -eq 0 && "${downstream_active}" -eq 0 ]] && return 0
    sleep 0.1
  done
  return 1
}

probe_service_datapath() {
  local namespace=$1 scenario_dir=$2 probe="l08-datapath-probe" phase=""
  kubectl run "${probe}" --namespace "${LOAD_NAMESPACE}" \
    --image="${K6_IMAGE_VALUE}" --image-pull-policy=IfNotPresent --restart=Never \
    --labels="capacity-cascade-lab/owner=l08" \
    --command -- /bin/sh -c "wget -qO- http://l08-haproxy.${namespace}.svc.cluster.local:8080/readyz" \
    >"${scenario_dir}/datapath-probe-create.log"
  for _ in {1..120}; do
    phase="$(kubectl get pod "${probe}" --namespace "${LOAD_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "${phase}" == Succeeded || "${phase}" == Failed ]] && break
    sleep 0.25
  done
  kubectl get pod "${probe}" --namespace "${LOAD_NAMESPACE}" -o json >"${scenario_dir}/datapath-probe-pod.json"
  kubectl logs "${probe}" --namespace "${LOAD_NAMESPACE}" >"${scenario_dir}/datapath-probe-response.txt" 2>"${scenario_dir}/datapath-probe-logs-error.txt" || true
  [[ "${phase}" == Succeeded ]] || { printf 'datapath probe failed: phase=%s\n' "${phase:-unknown}" >&2; return 1; }
  [[ "$(jq '[.spec.containers[]?,.spec.initContainers[]? | select(.name=="istio-proxy")] | length' "${scenario_dir}/datapath-probe-pod.json")" -eq 0 ]] || { printf 'datapath probe unexpectedly received an Istio sidecar\n' >&2; return 1; }
  jq -e '.status == "ready"' "${scenario_dir}/datapath-probe-response.txt" >/dev/null || { printf 'datapath probe did not receive readiness response\n' >&2; return 1; }
  kubectl delete pod "${probe}" --namespace "${LOAD_NAMESPACE}" --wait=true --timeout=60s >"${scenario_dir}/datapath-probe-delete.log"
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
  local pod_ip
  pod_ip="$(kubectl get pod --namespace "${namespace}" "${pod}" -o jsonpath='{.status.podIP}')"
  hcm_prefixes="$(jq -r '.. | objects | select(((.filter_chain_match?.destination_port? // "") | tostring) == "8080") | .filters[]?.typed_config? | select((."@type"? // "") | endswith("HttpConnectionManager")) | .stat_prefix // empty' "${config_dump}" | sort -u)"
  if [[ "$(printf '%s\n' "${hcm_prefixes}" | awk 'NF{count++}END{print count+0}')" -eq 1 ]]; then
    hcm_prefix="${hcm_prefixes}"
  else
    for candidate in ${hcm_prefixes}; do
      if [[ -n "${pod_ip}" && "${candidate}" == *"inbound_${pod_ip}_8080"* ]]; then
        hcm_prefix="${candidate}"
        break
      fi
    done
    if [[ -z "${hcm_prefix}" ]]; then
      for candidate in ${hcm_prefixes}; do
        local candidate_clean="${candidate%;}"
        if grep -q "http\.${candidate_clean}" "${scenario_dir}/proxy-stats-inventory.txt"; then
          hcm_prefix="${candidate}"
          break
        fi
      done
    fi
  fi
  [[ -n "${hcm_prefix}" ]] || { printf 'expected valid inbound HCM stat prefix, found %s\n' "${hcm_prefixes:-none}" >&2; return 1; }
  jq --arg prefix "${hcm_prefix}" '[.. | objects | select((."@type"? // "") | endswith("HttpConnectionManager")) | select(.stat_prefix == $prefix)]' "${config_dump}" >"${scenario_dir}/target-inbound-http-config.json"
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
  jq -n \
    --arg cluster "${cluster_name}" \
    --arg hcm_stat_prefix "${hcm_prefix}" \
    --arg proxy_downstream_total "${downstream_total}" \
    --arg proxy_downstream_active "${downstream_active}" \
    --arg proxy_downstream_5xx "${downstream_5xx}" \
    --arg proxy_upstream_total "${upstream_total}" \
    --arg proxy_upstream_active "${upstream_active}" \
    --arg proxy_active_overflow "${active_overflow}" \
    --arg proxy_pending_overflow "${pending_overflow}" \
    --arg proxy_retry "${retry}" \
    --arg proxy_timeout "${timeout}" \
    --argjson inbound_retry_policy_count "${retry_count}" \
    --argjson inbound_retry_budget_max "${retry_budget}" \
    '{
      cluster: $cluster,
      hcm_stat_prefix: $hcm_stat_prefix,
      proxy_downstream_total: $proxy_downstream_total,
      proxy_downstream_active: $proxy_downstream_active,
      proxy_downstream_5xx: $proxy_downstream_5xx,
      proxy_upstream_total: $proxy_upstream_total,
      proxy_upstream_active: $proxy_upstream_active,
      proxy_active_overflow: $proxy_active_overflow,
      proxy_pending_overflow: $proxy_pending_overflow,
      proxy_retry: $proxy_retry,
      proxy_timeout: $proxy_timeout,
      inbound_retry_policy_count: $inbound_retry_policy_count,
      inbound_retry_budget_max: $inbound_retry_budget_max
    }' >"${scenario_dir}/proxy-metric-mapping.json"
}

create_k6_job() {
  local namespace=$1 scenario_dir=$2 proxy_image=$3 configmap="l08-k6-scripts" job="l08-k6-workload"
  local haproxy_fqdn="l08-haproxy.${namespace}.svc.cluster.local" load_pod result_ready=false
  kubectl create configmap "${configmap}" --namespace "${LOAD_NAMESPACE}" \
    --from-file="l08.js=${PROJECT_ROOT}/load/k6/l08.js" \
    --from-file="config.js=${PROJECT_ROOT}/load/k6/lib/config.js" \
    --from-file="retry.js=${PROJECT_ROOT}/load/k6/lib/retry.js" \
    --from-file="summary.js=${PROJECT_ROOT}/load/k6/lib/summary.js" \
    >"${scenario_dir}/k6-configmap.log"
  cat <<EOF >"${scenario_dir}/k6-job.yaml"
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${LOAD_NAMESPACE}
  labels: {capacity-cascade-lab/owner: l08}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: $((TOTAL_DURATION_SECONDS + 120))
  template:
    metadata:
      labels: {capacity-cascade-lab/owner: l08, sidecar.istio.io/inject: "false"}
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
              k6 run /scripts/l08.js
              code=\$?
              printf '%s\\n' "\${code}" > /results/k6.exit
              : > /results/k6.done
              while [ ! -f /results/collected ]; do sleep 1; done
              exit "\${code}"
          env:
            - {name: BASE_URL, value: "http://${haproxy_fqdn}:8080"}
            - {name: RESULT_DIR, value: "/results"}
            - {name: STARTED_AT_UTC, value: "${STARTED_AT_UTC}"}
            - {name: GIT_COMMIT, value: "${SOURCE_COMMIT}"}
            - {name: GIT_DIRTY, value: "${GIT_DIRTY}"}
            - {name: RATE, value: "${RATE_VALUE}"}
            - {name: DURATION, value: "${DURATION_VALUE}"}
            - {name: REQUEST_TIMEOUT, value: "${REQUEST_TIMEOUT_VALUE}"}
            - {name: FAULT_LATENCY, value: "${FAULT_LATENCY_VALUE}"}
            - {name: FAULT_DURATION, value: "${FAULT_DURATION_VALUE}s"}
            - {name: SIDECAR_ACTIVE_REQUEST_TARGET, value: "${SIDECAR_CAPACITY_TARGET}"}
            - {name: LOGICAL_ID_NAMESPACE, value: "l08-chaos"}
            - {name: L08_SCENARIO, value: "chaos-network-delay"}
            - {name: REQUEST_PATH, value: "non-injected k6 Job -> HAProxy -> ClusterIP Service :8080 -> target Pod istio-proxy -> auth-sim"}
          securityContext:
            runAsNonRoot: true
            runAsUser: 12345
            runAsGroup: 12345
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
          volumeMounts:
            - {name: scripts, mountPath: /scripts/l08.js, subPath: l08.js, readOnly: true}
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
  kubectl apply -f "${scenario_dir}/k6-job.yaml" >"${scenario_dir}/k6-job-apply.log"
  for _ in {1..60}; do
    load_pod="$(kubectl get pods --namespace "${LOAD_NAMESPACE}" --selector "job-name=${job}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "${load_pod}" ]] && break
    sleep 0.2
  done
  [[ -n "${load_pod}" ]] || { printf 'k6 Job Pod was not created\n' >&2; return 1; }
  printf '%s' "${load_pod}"
}

# Pre-build auth-sim image
docker build --tag "${AUTH_SIM_IMAGE_VALUE}" . >"${result_dir}/docker-build.log" 2>&1

# Create k3d cluster
printf 'Creating k3d cluster %s...\n' "${CLUSTER_NAME}"
k3d cluster create "${CLUSTER_NAME}" \
  --servers 1 \
  --agents 0 \
  --image "${K3S_IMAGE_VALUE}" \
  --api-port 127.0.0.1:0 \
  --kubeconfig-update-default=false \
  --kubeconfig-switch-context=false \
  --k3s-arg '--disable=traefik@server:0' \
  --k3s-arg '--disable=servicelb@server:0' \
  --k3s-arg '--disable=local-storage@server:0' \
  --wait --timeout 120s >"${result_dir}/cluster-create.log" 2>&1

k3d kubeconfig get "${CLUSTER_NAME}" >"${kubeconfig_file}"
chmod 600 "${kubeconfig_file}"
api_binding="$(docker port "k3d-${CLUSTER_NAME}-serverlb" 6443/tcp | awk '$1 ~ /^127\.0\.0\.1:[0-9]+$/ {print; exit}')"
api_port="${api_binding##*:}"
sed -i -E "s#(server: https://0\.0\.0\.0:)[0-9]+#\1${api_port}#" "${kubeconfig_file}"
sed -i -E "s#(server: https://127\.0\.0\.1:)[0-9]+#\1${api_port}#" "${kubeconfig_file}"
kubectl wait --for=condition=Ready node --all --timeout=60s >"${result_dir}/node-ready.log"

# Verify containerd socket path on node directly
containerd_socket_verified=false
if docker exec "k3d-${CLUSTER_NAME}-server-0" test -S /run/k3s/containerd/containerd.sock; then
  containerd_socket_verified=true
fi
[[ "${containerd_socket_verified}" == true ]] || { printf 'runtime socket verification failed on node\n' >&2; exit 1; }

# Import images
k3d image import "${AUTH_SIM_IMAGE_VALUE}" -c "${CLUSTER_NAME}" >"${result_dir}/image-import-auth.log" 2>&1
for img in "${K6_IMAGE_VALUE}" "${HAPROXY_IMAGE_VALUE}" "ghcr.io/chaos-mesh/chaos-mesh:${CHAOS_MESH_VERSION_VALUE}" "ghcr.io/chaos-mesh/chaos-daemon:${CHAOS_MESH_VERSION_VALUE}"; do
  k3d image import "${img}" -c "${CLUSTER_NAME}" >>"${result_dir}/image-import-cached.log" 2>&1 || true
done

# Install Istio
printf 'Installing pinned Istio %s...\n' "${ISTIO_VERSION_VALUE}"
helm repo add istio https://istio-release.storage.googleapis.com/charts >"${result_dir}/istio-repo-add.log" 2>&1
helm repo update istio >"${result_dir}/istio-repo-update.log" 2>&1
helm pull istio/base --version "${ISTIO_VERSION_VALUE}" --destination "${chart_cache_dir}"
helm pull istio/istiod --version "${ISTIO_VERSION_VALUE}" --destination "${chart_cache_dir}"
base_chart="${chart_cache_dir}/base-${ISTIO_VERSION_VALUE}.tgz"
istiod_chart="${chart_cache_dir}/istiod-${ISTIO_VERSION_VALUE}.tgz"

helm upgrade --install istio-base "${base_chart}" --namespace "${ISTIO_NAMESPACE}" \
  --create-namespace --set defaultRevision=default --wait --timeout 180s \
  >"${result_dir}/istio-base-install.log" 2>&1
helm upgrade --install istiod "${istiod_chart}" --namespace "${ISTIO_NAMESPACE}" \
  --values "${ISTIOD_VALUES}" --wait --timeout 180s >"${result_dir}/istiod-install.log" 2>&1
kubectl rollout status deployment/istiod --namespace "${ISTIO_NAMESPACE}" --timeout=180s >"${result_dir}/istiod-rollout.log"

# Install Chaos Mesh
printf 'Installing pinned Chaos Mesh %s...\n' "${CHAOS_MESH_VERSION_VALUE}"
helm repo add chaos-mesh https://charts.chaos-mesh.org >"${result_dir}/chaos-repo-add.log" 2>&1
helm repo update chaos-mesh >"${result_dir}/chaos-repo-update.log" 2>&1
helm pull chaos-mesh/chaos-mesh --version "${CHAOS_MESH_VERSION_VALUE}" --destination "${chart_cache_dir}"
chaos_chart="${chart_cache_dir}/chaos-mesh-${CHAOS_MESH_VERSION_VALUE}.tgz"

helm upgrade --install chaos-mesh "${chaos_chart}" \
  --namespace "${CHAOS_NAMESPACE}" \
  --create-namespace \
  --values "${CHAOS_VALUES}" \
  --wait --timeout 180s >"${result_dir}/chaos-mesh-install.log" 2>&1
kubectl rollout status deployment/chaos-controller-manager --namespace "${CHAOS_NAMESPACE}" --timeout=180s >"${result_dir}/chaos-controller-rollout.log"
kubectl rollout status daemonset/chaos-daemon --namespace "${CHAOS_NAMESPACE}" --timeout=180s >"${result_dir}/chaos-daemon-rollout.log"

# Prepare Target and Load namespaces
printf 'Configuring target namespace %s with injection filter...\n' "${TARGET_NAMESPACE}"
kubectl create namespace "${TARGET_NAMESPACE}"
kubectl label namespace "${TARGET_NAMESPACE}" istio-injection=enabled
# Blast radius restriction: only this annotated namespace allows chaos injection
kubectl annotate namespace "${TARGET_NAMESPACE}" "chaos-mesh.org/inject=enabled"
kubectl create namespace "${LOAD_NAMESPACE}"

# Ephemeral admin secret
kubectl create secret generic "${ADMIN_SECRET}" --namespace "${TARGET_NAMESPACE}" \
  --from-literal=admin-token="${admin_token}" >"${result_dir}/admin-secret.log"

# Deploy auth-sim
printf 'Deploying auth-sim with inbound sidecar capacity target...\n'
helm upgrade --install auth-sim "${CHART_DIR}" --namespace "${TARGET_NAMESPACE}" \
  --set-string image.repository="${IMAGE_REPOSITORY}" \
  --set-string image.tag="${IMAGE_TAG}" \
  --set replicaCount=1 \
  --set "adminSecret.name=${ADMIN_SECRET}" \
  --set "adminSecret.key=admin-token" \
  --wait --timeout 180s >"${result_dir}/auth-sim-install.log" 2>&1

kubectl rollout status deployment/auth-sim --namespace "${TARGET_NAMESPACE}" --timeout=180s >"${result_dir}/auth-sim-rollout.log"
pod="$(kubectl get pods --namespace "${TARGET_NAMESPACE}" --selector 'app.kubernetes.io/name=auth-sim' -o jsonpath='{.items[0].metadata.name}')"
proxy_image="$(kubectl get pod "${pod}" --namespace "${TARGET_NAMESPACE}" -o jsonpath='{.spec.containers[?(@.name=="istio-proxy")].image}')"

# Apply Sidecar, EnvoyFilter, HPA, HAProxy
sed -e "s/TARGET_NAMESPACE/${TARGET_NAMESPACE}/g" -e "s/SIDECAR_CAPACITY_TARGET/${SIDECAR_CAPACITY_TARGET}/g" \
  "${PROJECT_ROOT}/l08/sidecar.yaml" >"${result_dir}/sidecar-rendered.yaml"
kubectl apply -f "${result_dir}/sidecar-rendered.yaml" >"${result_dir}/sidecar-apply.log"

sed "s/TARGET_NAMESPACE/${TARGET_NAMESPACE}/g" "${PROJECT_ROOT}/l08/retry-disabled.yaml" >"${result_dir}/retry-disabled-rendered.yaml"
kubectl apply -f "${result_dir}/retry-disabled-rendered.yaml" >"${result_dir}/retry-disabled-apply.log"

sed "s/TARGET_NAMESPACE/${TARGET_NAMESPACE}/g" "${PROJECT_ROOT}/l08/hpa-blind.yaml" >"${result_dir}/hpa-rendered.yaml"
kubectl apply -f "${result_dir}/hpa-rendered.yaml" >"${result_dir}/hpa-apply.log"

sed -e "s/TARGET_NAMESPACE/${TARGET_NAMESPACE}/g" \
    -e "s/AUTH_SIM_SERVICE_FQDN/auth-sim.${TARGET_NAMESPACE}.svc.cluster.local/g" \
    -e "s#HAPROXY_IMAGE#${HAPROXY_IMAGE_VALUE}#g" \
  "${PROJECT_ROOT}/l08/haproxy.yaml" >"${result_dir}/haproxy-rendered.yaml"
kubectl apply -f "${result_dir}/haproxy-rendered.yaml" >"${result_dir}/haproxy-apply.log"
kubectl rollout status deployment/l08-haproxy --namespace "${TARGET_NAMESPACE}" --timeout=180s >"${result_dir}/haproxy-rollout.log"

# Prepare NetworkChaos rendered manifest
sed -e "s/TARGET_NAMESPACE/${TARGET_NAMESPACE}/g" \
    -e "s/FAULT_LATENCY/${FAULT_LATENCY_VALUE}/g" \
    -e "s/FAULT_DURATION/${FAULT_DURATION_VALUE}s/g" \
  "${PROJECT_ROOT}/l08/network-delay.yaml" >"${result_dir}/chaos-resource-applied.yaml"

# Datapath probe
probe_service_datapath "${TARGET_NAMESPACE}" "${result_dir}"

# Discover proxy config and ensure counter mapping
discover_proxy_config "${TARGET_NAMESPACE}" "${pod}" "${result_dir}"

# Start Port-Forwards for direct observation
start_port_forward "${TARGET_NAMESPACE}" "pod/${pod}" 9090 "${result_dir}/port-forward-admin.log" admin_pf_pid admin_port
start_port_forward "${TARGET_NAMESPACE}" "pod/${pod}" 8080 "${result_dir}/port-forward-metrics.log" metrics_pf_pid metrics_port
start_port_forward "${TARGET_NAMESPACE}" service/l08-haproxy 8404 "${result_dir}/port-forward-haproxy-stats.log" haproxy_pf_pid haproxy_port
admin_url="http://127.0.0.1:${admin_port}"; metrics_url="http://127.0.0.1:${metrics_port}"; haproxy_url="http://127.0.0.1:${haproxy_port}"
wait_for_url "${admin_url}/admin/fault" && wait_for_url "${metrics_url}/metrics" && wait_for_url "${haproxy_url}/stats;csv"

# Verify direct application observation bypasses sidecar proxy
collect_proxy_stats "${TARGET_NAMESPACE}" "${pod}" "${result_dir}/observation-proxy-before.txt"
curl --fail --silent --show-error "${metrics_url}/metrics" >"${result_dir}/observation-application.prom"
collect_proxy_stats "${TARGET_NAMESPACE}" "${pod}" "${result_dir}/observation-proxy-after.txt"
obs_before="$(stat_value "${result_dir}/observation-proxy-before.txt" "$(jq -r '.proxy_downstream_total' "${result_dir}/proxy-metric-mapping.json")")"
obs_after="$(stat_value "${result_dir}/observation-proxy-after.txt" "$(jq -r '.proxy_downstream_total' "${result_dir}/proxy-metric-mapping.json")")"
obs_delta=$((obs_after - obs_before))
jq -n --argjson delta "${obs_delta}" --argjson bypass "$([[ "${obs_delta}" -eq 0 ]] && echo true || echo false)" \
  '{direct_pod_metrics_scrape_proxy_downstream_delta:$delta, bypasses_target_inbound_proxy:$bypass}' >"${result_dir}/application-observation-path.json"
[[ "${obs_delta}" -eq 0 ]] || { printf 'direct scrape changed target proxy counters\n' >&2; exit 1; }

# Reset application fault to baseline (0 latency, 0 error, unlimited admission)
put_application_fault "${admin_url}" '{"latency_ms":0,"error_rate":0,"max_in_flight":0,"seed":17082026}' "${result_dir}/app-fault-reset.json"
curl --fail --silent --show-error "${haproxy_url}/stats;csv" >"${result_dir}/haproxy-stats-before.csv"

# Start sample observation
: >"${result_dir}/samples.jsonl"
workload_start_epoch="$(date +%s)"
append_sample "chaos-network-delay" "${TARGET_NAMESPACE}" "${pod}" "${metrics_url}" "${haproxy_url}" "${result_dir}/proxy-metric-mapping.json" "${result_dir}/samples.jsonl" baseline
observer_stop_file="${result_dir}/observer.stop"
observe_loop "chaos-network-delay" "${TARGET_NAMESPACE}" "${pod}" "${metrics_url}" "${haproxy_url}" "${result_dir}/proxy-metric-mapping.json" "${result_dir}/samples.jsonl" "${observer_stop_file}" & observer_pid=$!

# Launch k6 Job
printf 'Starting k6 workload (%s, rate %s/s)...\n' "${DURATION_VALUE}" "${RATE_VALUE}"
load_pod="$(create_k6_job "${TARGET_NAMESPACE}" "${result_dir}" "${proxy_image}")"

if [[ "${ACTION}" == "abort-smoke" ]]; then
  printf 'Running abort-smoke: waiting %ss pre-fault then injecting...\n' "${PRE_FAULT_DURATION_VALUE}"
  sleep "${PRE_FAULT_DURATION_VALUE}"
  kubectl apply -f "${result_dir}/chaos-resource-applied.yaml" >"${result_dir}/chaos-apply.log"
  fault_applied=true
  # Wait for injection to become active
  for _ in {1..30}; do
    injected="$(kubectl get networkchaos auth-sim-delay -n "${TARGET_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="AllInjected")].status}' 2>/dev/null || echo '')"
    if [[ "${injected}" == "True" ]]; then
      fault_injected=true
      t_injected_epoch="$(date +%s)"
      t_injected_utc="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
      kubectl get networkchaos auth-sim-delay -n "${TARGET_NAMESPACE}" -o yaml >"${result_dir}/chaos-resource-active.yaml"
      break
    fi
    sleep 0.5
  done
  [[ "${fault_injected}" == true ]] || { printf 'fault was not injected in abort-smoke\n' >&2; exit 1; }

  printf 'Controlled abort triggered while fault is active!\n'
  abort_triggered=true
  # Clean Chaos CR immediately
  kubectl delete networkchaos auth-sim-delay -n "${TARGET_NAMESPACE}" --timeout=15s >"${result_dir}/chaos-abort-delete.log"
  chaos_remaining="$(kubectl get networkchaos -n "${TARGET_NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${chaos_remaining}" -eq 0 ]] || { printf 'Chaos CR remained after abort cleanup\n' >&2; exit 1; }

  touch "${observer_stop_file}"; wait "${observer_pid}" 2>/dev/null || true; observer_pid=""
  stop_background_processes

  jq -n \
    --argjson fault_applied "${fault_applied}" \
    --argjson fault_injected "${fault_injected}" \
    --argjson abort_triggered "${abort_triggered}" \
    --argjson chaos_remaining "${chaos_remaining}" \
    '{
      passed: true,
      fault_applied: $fault_applied,
      fault_injected: $fault_injected,
      abort_triggered: $abort_triggered,
      chaos_resources_remaining_after_abort: $chaos_remaining,
      abort_contract_satisfied: true
    }' > "${result_dir}/abort-contract.json"
  printf 'Abort smoke test PASSED. Chaos CR was safely cleared upon abort.\n'
  exit 0
fi

# Main experiment flow (verify / smoke)
printf 'Workload running. Waiting %ss pre-fault...\n' "${PRE_FAULT_DURATION_VALUE}"
sleep "${PRE_FAULT_DURATION_VALUE}"

printf 'Applying declarative NetworkChaos resource...\n'
kubectl apply -f "${result_dir}/chaos-resource-applied.yaml" >"${result_dir}/chaos-apply.log"
fault_applied=true

# Wait for AllInjected: True
for _ in {1..30}; do
  injected="$(kubectl get networkchaos auth-sim-delay -n "${TARGET_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="AllInjected")].status}' 2>/dev/null || echo '')"
  if [[ "${injected}" == "True" ]]; then
    fault_injected=true
    t_injected_epoch="$(date +%s)"
    t_injected_utc="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    kubectl get networkchaos auth-sim-delay -n "${TARGET_NAMESPACE}" -o yaml >"${result_dir}/chaos-resource-active.yaml"
    break
  fi
  sleep 0.5
done
[[ "${fault_injected}" == true ]] || { printf 'Chaos Mesh did not report AllInjected=True\n' >&2; exit 1; }
printf 'Chaos fault active at %s (phase: Injected)\n' "${t_injected_utc}"

# Wait for fault duration to expire
printf 'Fault window active for %ss. Waiting for recovery...\n' "${FAULT_DURATION_VALUE}"
sleep "${FAULT_DURATION_VALUE}"

# Wait for AllRecovered: True
for _ in {1..40}; do
  recovered="$(kubectl get networkchaos auth-sim-delay -n "${TARGET_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="AllRecovered")].status}' 2>/dev/null || echo '')"
  if [[ "${recovered}" == "True" ]]; then
    fault_recovered=true
    t_recovered_epoch="$(date +%s)"
    t_recovered_utc="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
    kubectl get networkchaos auth-sim-delay -n "${TARGET_NAMESPACE}" -o yaml >"${result_dir}/chaos-resource-recovered.yaml"
    break
  fi
  sleep 0.5
done
[[ "${fault_recovered}" == true ]] || { printf 'Chaos Mesh did not report AllRecovered=True\n' >&2; exit 1; }
printf 'Chaos fault recovered at %s (phase: Recovered)\n' "${t_recovered_utc}"

# Wait for k6 to finish
printf 'Waiting for k6 workload completion...\n'
result_ready=false
for _ in {1..720}; do
  kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- test -f /results/k6.done >/dev/null 2>&1 && { result_ready=true; break; }
  [[ "$(kubectl get pod "${load_pod}" --namespace "${LOAD_NAMESPACE}" -o jsonpath='{.status.phase}')" == Failed ]] && break
  sleep 0.5
done
[[ "${result_ready}" == true ]] || { printf 'k6 execution failed or timed out\n' >&2; exit 1; }

# Collect k6 outputs
kubectl logs --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 >"${result_dir}/k6-console.log" 2>&1 || true
kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- cat /results/k6.exit >"${result_dir}/k6.exit"
kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- cat /results/k6-version.txt >"${result_dir}/k6-version.txt"
kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- cat /results/metadata.json >"${result_dir}/k6-metadata.json"
kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- cat /results/k6-summary.json >"${result_dir}/k6-summary.json"
kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- cat /results/summary.md >"${result_dir}/k6-summary.md"
kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- touch /results/collected >"${result_dir}/k6-collected.log"

# Stop observer
touch "${observer_stop_file}"; wait "${observer_pid}" 2>/dev/null || true; observer_pid=""

# Wait for sidecar idle
wait_for_idle "${TARGET_NAMESPACE}" "${pod}" "${result_dir}/proxy-metric-mapping.json" "${result_dir}/proxy-idle-last.txt"
append_sample "chaos-network-delay" "${TARGET_NAMESPACE}" "${pod}" "${metrics_url}" "${haproxy_url}" "${result_dir}/proxy-metric-mapping.json" "${result_dir}/samples.jsonl" after

# Capture final resource states
kubectl get networkchaos auth-sim-delay --namespace "${TARGET_NAMESPACE}" -o yaml >"${result_dir}/chaos-resource-final.yaml" 2>/dev/null || true
kubectl get events --namespace "${TARGET_NAMESPACE}" -o json >"${result_dir}/chaos-events.json" 2>/dev/null || true
curl --fail --silent --show-error "${haproxy_url}/stats;csv" >"${result_dir}/haproxy-stats-after.csv"
kubectl get hpa auth-sim-scaling --namespace "${TARGET_NAMESPACE}" -o yaml >"${result_dir}/hpa-final.yaml"
kubectl get events --namespace "${TARGET_NAMESPACE}" --field-selector 'involvedObject.kind=HorizontalPodAutoscaler,involvedObject.name=auth-sim-scaling' -o json >"${result_dir}/hpa-events.json"
kubectl get deployment,pods,endpointslice --namespace "${TARGET_NAMESPACE}" -o json >"${result_dir}/workload-final.json"
kubectl top pods --namespace "${TARGET_NAMESPACE}" --containers >"${result_dir}/container-usage.txt" 2>/dev/null || true

# Delete Chaos CR and verify absence
kubectl delete networkchaos auth-sim-delay --namespace "${TARGET_NAMESPACE}" --timeout=30s >"${result_dir}/chaos-delete.log"
chaos_final_remaining="$(kubectl get networkchaos -n "${TARGET_NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[[ "${chaos_final_remaining}" -eq 0 ]] || { printf 'Chaos CR remained after final deletion\n' >&2; exit 1; }

stop_background_processes

# Evaluate Completion Contract
printf 'Evaluating L08 completion contract...\n'
samples_file="${result_dir}/samples.jsonl"
k6_summary="${result_dir}/k6-summary.json"

dropped_iterations="$(jq -r '.metrics.dropped_iterations.values.count // 0' "${k6_summary}")"
logical_requests="$(jq -r '.metrics.logical_requests.values.count // 0' "${k6_summary}")"
physical_attempts="$(jq -r '.metrics.physical_attempts.values.count // 0' "${k6_summary}")"
status_200="$(jq -r '.metrics.downstream_responses_200.values.count // 0' "${k6_summary}")"
status_503="$(jq -r '.metrics.downstream_responses_503.values.count // 0' "${k6_summary}")"
p95_duration="$(jq -r '.metrics.http_req_duration.values["p(95)"] // 0' "${k6_summary}")"

# Per-phase sample statistics
pre_samples="$(jq -s '[.[] | select(.phase=="pre-fault")]' "${samples_file}")"
fault_samples="$(jq -s '[.[] | select(.phase=="fault")]' "${samples_file}")"
post_samples="$(jq -s '[.[] | select(.phase=="post-fault")]' "${samples_file}")"

pre_overflow_max="$(echo "${pre_samples}" | jq '[.[].proxy.active_overflow] | max // 0')"
pre_503_max="$(echo "${pre_samples}" | jq '[.[].haproxy.responses_5xx] | max // 0')"

fault_injected_count="$(echo "${fault_samples}" | jq '[.[] | select(.chaos.injected==true)] | length')"
fault_overflow_max="$(echo "${fault_samples}" | jq '[.[].proxy.active_overflow] | max // 0')"
fault_503_max="$(echo "${fault_samples}" | jq '[.[].haproxy.responses_5xx] | max // 0')"

post_recovered_count="$(echo "${post_samples}" | jq '[.[] | select(.chaos.recovered==true)] | length')"
post_overflow_delta="$(( $(echo "${post_samples}" | jq '.[-1].proxy.active_overflow // 0') - $(echo "${post_samples}" | jq '.[0].proxy.active_overflow // 0') ))"
post_idle_active="$(echo "${post_samples}" | jq '.[-1].proxy.upstream_active // 0')"

pre_healthy=false
[[ "${pre_overflow_max}" -eq 0 && "${pre_503_max}" -eq 0 ]] && pre_healthy=true

fault_effect_observed=false
if [[ "${fault_overflow_max}" -gt 0 || "${fault_503_max}" -gt 0 || "${status_503}" -gt 0 ]]; then
  fault_effect_observed=true
fi

post_recovered=false
if [[ "${post_recovered_count}" -gt 0 && "${post_overflow_delta}" -le 1 && "${post_idle_active}" -eq 0 ]]; then
  post_recovered=true
fi

contract_passed=false
if [[ "${fault_injected}" == true \
   && "${fault_recovered}" == true \
   && "${pre_healthy}" == true \
   && "${fault_effect_observed}" == true \
   && "${post_recovered}" == true \
   && "${dropped_iterations}" -eq 0 \
   && "${chaos_final_remaining}" -eq 0 ]]; then
  contract_passed=true
fi

jq -n \
  --argjson passed "${contract_passed}" \
  --argjson chaos_installed true \
  --argjson namespace_filtering_enabled true \
  --argjson containerd_socket_verified "${containerd_socket_verified}" \
  --argjson pre_fault_healthy "${pre_healthy}" \
  --argjson fault_injected "${fault_injected}" \
  --argjson fault_effect_observed "${fault_effect_observed}" \
  --argjson fault_recovered "${fault_recovered}" \
  --argjson post_fault_recovered "${post_recovered}" \
  --argjson dropped_iterations_zero "$([[ "${dropped_iterations}" -eq 0 ]] && echo true || echo false)" \
  --argjson chaos_resource_deleted "$([[ "${chaos_final_remaining}" -eq 0 ]] && echo true || echo false)" \
  --arg t_injected "${t_injected_utc}" \
  --arg t_recovered "${t_recovered_utc}" \
  --argjson logical_requests "${logical_requests}" \
  --argjson physical_attempts "${physical_attempts}" \
  --argjson status_200 "${status_200}" \
  --argjson status_503 "${status_503}" \
  --argjson p95_ms "${p95_duration}" \
  --argjson fault_overflow_max "${fault_overflow_max}" \
  --argjson fault_503_max "${fault_503_max}" \
  '{
    passed: $passed,
    conditions: {
      chaos_installed: $chaos_installed,
      namespace_filtering_enabled: $namespace_filtering_enabled,
      containerd_socket_verified: $containerd_socket_verified,
      pre_fault_healthy: $pre_fault_healthy,
      fault_injected: $fault_injected,
      fault_effect_observed: $fault_effect_observed,
      fault_recovered: $fault_recovered,
      post_fault_recovered: $post_fault_recovered,
      dropped_iterations_zero: $dropped_iterations_zero,
      chaos_resource_deleted: $chaos_resource_deleted
    },
    timeline: {
      fault_injected_utc: $t_injected,
      fault_recovered_utc: $t_recovered
    },
    measurements: {
      logical_requests: $logical_requests,
      physical_attempts: $physical_attempts,
      downstream_200: $status_200,
      downstream_503: $status_503,
      http_req_duration_p95_ms: $p95_ms,
      fault_sidecar_overflow_peak: $fault_overflow_max,
      fault_haproxy_5xx_peak: $fault_503_max
    }
  }' > "${result_dir}/contract.json"

jq -n \
  --arg started_at_utc "${STARTED_AT_UTC}" \
  --arg git_commit "${SOURCE_COMMIT}" \
  --argjson git_dirty "${GIT_DIRTY}" \
  --arg action "${ACTION}" \
  --arg k3s_image "${K3S_IMAGE_VALUE}" \
  --arg istio_version "${ISTIO_VERSION_VALUE}" \
  --arg chaos_version "${CHAOS_MESH_VERSION_VALUE}" \
  --arg haproxy_image "${HAPROXY_IMAGE_VALUE}" \
  --arg k6_image "${K6_IMAGE_VALUE}" \
  --arg auth_image "${AUTH_SIM_IMAGE_VALUE}" \
  --arg duration "${DURATION_VALUE}" \
  --argjson rate "${RATE_VALUE}" \
  --arg fault_latency "${FAULT_LATENCY_VALUE}" \
  --arg fault_duration "${FAULT_DURATION_VALUE}s" \
  --arg t_injected "${t_injected_utc}" \
  --arg t_recovered "${t_recovered_utc}" \
  '{
    project: "GitHub Capacity Cascade Lab",
    learning_unit: "L08",
    classification: "local exploratory evidence",
    scenario: "chaos-network-delay",
    scenario_mode: $action,
    started_at_utc: $started_at_utc,
    git_commit: $git_commit,
    git_dirty: $git_dirty,
    cluster: {
      name: "capacity-cascade-l08",
      k3s_image: $k3s_image,
      container_runtime: "containerd",
      socket_path: "/run/k3s/containerd/containerd.sock"
    },
    istio: {
      version: $istio_version,
      mode: "sidecar",
      inbound_capacity_target: 1,
      inbound_retry: "off"
    },
    chaos_mesh: {
      version: $chaos_version,
      fault_type: "NetworkChaos",
      action: "delay",
      mode: "all",
      target_selector: {
        namespace: "capacity-cascade-l08-target",
        label: "app.kubernetes.io/name=auth-sim"
      },
      namespace_filtering: true,
      daemon_privileged: true
    },
    workload: {
      rate: $rate,
      duration: $duration,
      fault_latency: $fault_latency,
      fault_duration: $fault_duration,
      client_retry: "none",
      haproxy_retry: "off"
    },
    timeline: {
      injected_utc: $t_injected,
      recovered_utc: $t_recovered
    },
    source_boundary: {
      fact: "GitHub official RCA described cascade effects; incident facts documented in docs/facts-and-assumptions.md",
      inference: "Declarative fault window directly correlates with user-facing and proxy saturation signals",
      lab_implementation: "Chaos Mesh 2.8.4 NetworkChaos delay on local k3d cluster with Istio sidecar",
      unknown: "Whether GitHub utilized Chaos Mesh or specific chaos tooling during incident analysis"
    }
  }' >"${result_dir}/metadata.json"

cat <<EOF >"${result_dir}/summary.md"
# L08 Chaos Mesh Reproduction Summary

> 이 결과는 로컬 ephemeral k3d 환경에서 측정된 local exploratory evidence이며,
> GitHub production benchmark나 실제 장애 복제가 아닙니다.

| 관측 항목 | 측정값 / 상태 |
| --- | --- |
| Contract Passed | ${contract_passed} |
| Chaos Mesh Version | ${CHAOS_MESH_VERSION_VALUE} |
| Runtime Socket Verified | ${containerd_socket_verified} |
| Namespace Blast-Radius Protected | true (enableFilterNamespace=true) |
| Fault Type & Target | NetworkChaos delay (${FAULT_LATENCY_VALUE}) on auth-sim |
| Injection Injected Timestamp | ${t_injected_utc} |
| Recovery Timestamp | ${t_recovered_utc} |
| Pre-fault Healthy | ${pre_healthy} (overflow peak: ${pre_overflow_max}) |
| Fault Window Observed Peak Overflow | ${fault_overflow_max} |
| Fault Window Observed 5xx | ${fault_503_max} (k6 503 total: ${status_503}) |
| Post-fault Recovery | ${post_recovered} |
| Dropped Iterations | ${dropped_iterations} |
| Chaos CR Deleted | true |
EOF

printf 'L08 run finished. Result directory: %s\n' "${result_dir}"
if [[ "${contract_passed}" != true && "${ACTION}" != "smoke" ]]; then
  printf 'L08 completion contract failed\n' >&2
  exit 1
fi
