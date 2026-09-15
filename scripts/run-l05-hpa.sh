#!/usr/bin/env bash
# L05 compares a built-in application-container CPU HPA with a bounded
# sidecar-active custom metric HPA. It owns only the exact L05 k3d cluster.
set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ACTION="${1:-pair}"
readonly CLUSTER_NAME="capacity-cascade-l05"
readonly ISTIO_NAMESPACE="istio-system"
readonly LOAD_NAMESPACE="capacity-cascade-l05-load"
readonly BLIND_NAMESPACE="capacity-cascade-l05-blind"
readonly AWARE_NAMESPACE="capacity-cascade-l05-aware"
readonly BLIND_RELEASE="auth-sim-blind"
readonly AWARE_RELEASE="auth-sim-aware"
readonly ADAPTER_NAME="l05-custom-metrics-adapter"
readonly ADAPTER_API_SERVICE="v1beta2.custom.metrics.k8s.io"
readonly ADMIN_SECRET="auth-sim-admin"
readonly CHART_DIR="${PROJECT_ROOT}/charts/auth-sim"
readonly ISTIOD_VALUES="${PROJECT_ROOT}/l04/istiod-values.yaml"
readonly K3S_IMAGE_VALUE="${K3S_IMAGE:-rancher/k3s:v1.35.5-k3s1}"
readonly ISTIO_VERSION_VALUE="${ISTIO_VERSION:-1.30.4}"
readonly ISTIO_CHART_REPOSITORY_VALUE="${ISTIO_CHART_REPOSITORY:-https://blob.istio.io/istio-release/charts}"
readonly ISTIO_IMAGE_HUB_VALUE="${ISTIO_IMAGE_HUB:-docker.io/istio}"
readonly K6_IMAGE_VALUE="${K6_IMAGE:-grafana/k6:2.2.0}"
readonly LOGICAL_RATE_VALUE="${LOGICAL_RATE:-3}"
readonly DURATION_VALUE="${DURATION:-150s}"
readonly REQUEST_TIMEOUT_VALUE="${REQUEST_TIMEOUT:-2s}"
readonly APPLICATION_LATENCY_MS_VALUE="${APPLICATION_LATENCY_MS:-1000}"
readonly FAULT_SEED_VALUE="${FAULT_SEED:-17082026}"
readonly LOGICAL_ID_NAMESPACE_VALUE="${LOGICAL_ID_NAMESPACE:-l05-hpa-pair}"
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
      && /--namespace[[:space:]]+capacity-cascade-l05/ { print $1 }
  '
}

remaining_owned_processes() {
  owned_port_forward_pids | awk 'NF { count++ } END { print count+0 }'
}

clean_owned_cluster() {
  local pid
  while IFS= read -r pid; do
    if [[ -n "${pid}" && "${pid}" != "$$" ]]; then kill -TERM "${pid}" 2>/dev/null || true; fi
  done < <(owned_port_forward_pids)
  if cluster_exists; then k3d cluster delete "${CLUSTER_NAME}"; fi
  local containers networks processes
  containers="$(remaining_cluster_containers)"
  networks="$(remaining_cluster_networks)"
  processes="$(remaining_owned_processes)"
  if [[ "${containers}" -ne 0 || "${networks}" -ne 0 || "${processes}" -ne 0 ]]; then
    printf 'L05 cleanup incomplete: containers=%s networks=%s processes=%s\n' "${containers}" "${networks}" "${processes}" >&2
    return 1
  fi
  printf 'L05 owned cluster resources and port-forward processes are absent; evidence was preserved.\n'
}

if [[ "${ACTION}" == "clean" ]]; then
  for required_tool in docker k3d awk ps; do
    command -v "${required_tool}" >/dev/null 2>&1 || { printf 'required tool is missing: %s\n' "${required_tool}" >&2; exit 127; }
  done
  docker info >/dev/null
  clean_owned_cluster
  exit 0
fi

declare -a RUN_SCENARIOS=()
case "${ACTION}" in
  pair) RUN_SCENARIOS=(hpa-blind hpa-aware) ;;
  smoke|hpa-blind) RUN_SCENARIOS=(hpa-blind) ;;
  hpa-aware) RUN_SCENARIOS=(hpa-aware) ;;
  *) printf 'usage: %s {pair|smoke|hpa-blind|hpa-aware|clean}\n' "$0" >&2; exit 2 ;;
esac

for image in "${K3S_IMAGE_VALUE}" "${K6_IMAGE_VALUE}"; do
  case "${image}" in *:latest|latest) printf 'latest image is forbidden: %s\n' "${image}" >&2; exit 2 ;; *:*) ;; *) printf 'image must have an explicit tag: %s\n' "${image}" >&2; exit 2 ;; esac
done
[[ "${ISTIO_VERSION_VALUE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'ISTIO_VERSION must be an explicit patch version\n' >&2; exit 2; }
[[ "${LOGICAL_RATE_VALUE}" =~ ^[1-9][0-9]*$ ]] || { printf 'LOGICAL_RATE must be a positive integer\n' >&2; exit 2; }
[[ "${APPLICATION_LATENCY_MS_VALUE}" =~ ^[1-9][0-9]*$ ]] || { printf 'APPLICATION_LATENCY_MS must be a positive integer\n' >&2; exit 2; }
[[ "${FAULT_SEED_VALUE}" =~ ^[0-9]+$ ]] || { printf 'FAULT_SEED must be a non-negative integer\n' >&2; exit 2; }
for duration in "${DURATION_VALUE}" "${REQUEST_TIMEOUT_VALUE}"; do
  [[ "${duration}" =~ ^[1-9][0-9]*(ms|s|m)$ ]] || { printf 'duration must be a positive k6 duration: %s\n' "${duration}" >&2; exit 2; }
done
[[ "${SAMPLE_INTERVAL_SECONDS_VALUE}" =~ ^0\.[1-9][0-9]*$|^[1-9][0-9]*(\.[0-9]+)?$ ]] || { printf 'SAMPLE_INTERVAL_SECONDS must be positive\n' >&2; exit 2; }

for required_tool in git go k6 docker kubectl k3d helm curl awk sed grep jq ruby tee wc tr mktemp sha256sum diff cmp sort find ps make; do
  command -v "${required_tool}" >/dev/null 2>&1 || { printf 'required tool is missing: %s\n' "${required_tool}" >&2; exit 127; }
done
docker info >/dev/null
if cluster_exists; then
  printf 'refusing to replace existing exact L05 cluster: %s\nrun make l05-clean after inspecting that cluster\n' "${CLUSTER_NAME}" >&2
  exit 1
fi
if [[ "$(remaining_cluster_containers)" -ne 0 || "$(remaining_cluster_networks)" -ne 0 || "$(remaining_owned_processes)" -ne 0 ]]; then
  printf 'refusing to run while exact L05 resources remain\n' >&2
  exit 1
fi

readonly SOURCE_COMMIT="$(git rev-parse HEAD)"
readonly SOURCE_SHORT="$(git rev-parse --short=12 HEAD)"
readonly IMAGE_REPOSITORY="${AUTH_SIM_REPOSITORY:-capacity-cascade/auth-sim}"
readonly IMAGE_TAG="${AUTH_SIM_TAG:-l05-${SOURCE_SHORT}}"
readonly AUTH_SIM_IMAGE_VALUE="${IMAGE_REPOSITORY}:${IMAGE_TAG}"
case "${AUTH_SIM_IMAGE_VALUE}" in *:latest|latest) printf 'latest auth-sim image is forbidden\n' >&2; exit 2 ;; esac

started_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
result_parent="results/hpa-blind-spot"
result_dir="${result_parent}/${timestamp}"
suffix=1
while [[ -e "${result_dir}" ]]; do result_dir="${result_parent}/${timestamp}-${suffix}"; suffix=$((suffix + 1)); done
mkdir -p "${result_dir}"
for scenario in "${RUN_SCENARIOS[@]}"; do mkdir -p "${result_dir}/${scenario}"; done

original_kubeconfig_set=false
original_kubeconfig_value=""
if [[ -v KUBECONFIG ]]; then original_kubeconfig_set=true; original_kubeconfig_value="${KUBECONFIG}"; fi
read_original_context() {
  local context
  if [[ "${original_kubeconfig_set}" == true ]]; then context="$(KUBECONFIG="${original_kubeconfig_value}" kubectl config current-context 2>/dev/null)" || context="__UNSET__"; else context="$(env -u KUBECONFIG kubectl config current-context 2>/dev/null)" || context="__UNSET__"; fi
  printf '%s' "${context}"
}
file_hash_or_absent() { if [[ -f "$1" ]]; then sha256sum "$1" | awk '{print $1}'; else printf absent; fi; }
original_context="$(read_original_context)"
if [[ "${original_context}" == __UNSET__ ]]; then original_context_state=unset; else original_context_state=set; fi
original_helm_repository_config="$(helm env HELM_REPOSITORY_CONFIG)"
original_helm_repository_hash="$(file_hash_or_absent "${original_helm_repository_config}")"

umask 077
runtime_root="$(mktemp -d "${TMPDIR:-/tmp}/capacity-cascade-l05.XXXXXX")"
kubeconfig_file="${runtime_root}/kubeconfig"
helm_config_home="${runtime_root}/helm-config"
helm_cache_home="${runtime_root}/helm-cache"
helm_data_home="${runtime_root}/helm-data"
chart_dir="${runtime_root}/charts"
mkdir -p "${helm_config_home}" "${helm_cache_home}" "${helm_data_home}" "${chart_dir}"
: >"${kubeconfig_file}"; chmod 600 "${kubeconfig_file}"
export KUBECONFIG="${kubeconfig_file}" HELM_CONFIG_HOME="${helm_config_home}" HELM_CACHE_HOME="${helm_cache_home}" HELM_DATA_HOME="${helm_data_home}"

admin_token="l05-${RANDOM}-${RANDOM}-$$-$(date +%s)"
admin_pf_pid=""; adapter_pf_pid=""; observer_pid=""; observer_stop_file=""
cluster_created=false; istio_base_deployed=false; istiod_deployed=false; load_namespace_created=false
cleanup_started=false; cluster_removed=false; temporary_kubeconfig_removed=false; temporary_helm_state_removed=false
original_context_unchanged=false; original_helm_config_unchanged=false; contract_passed=false
declare -A SCENARIO_NAMESPACE=([hpa-blind]="${BLIND_NAMESPACE}" [hpa-aware]="${AWARE_NAMESPACE}")
declare -A SCENARIO_RELEASE=([hpa-blind]="${BLIND_RELEASE}" [hpa-aware]="${AWARE_RELEASE}")
declare -A scenario_contract=() scenario_desired_max=() scenario_pod_max=() scenario_failure_rate=() scenario_overflow=()
for scenario in "${RUN_SCENARIOS[@]}"; do scenario_contract["${scenario}"]=false; scenario_desired_max["${scenario}"]=0; scenario_pod_max["${scenario}"]=0; scenario_failure_rate["${scenario}"]=0; scenario_overflow["${scenario}"]=0; done

stop_process() { local pid=$1; if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then kill -TERM "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true; fi; }
stop_scenario_backgrounds() {
  [[ -n "${observer_stop_file}" ]] && : >"${observer_stop_file}"
  [[ -n "${observer_pid}" ]] && wait "${observer_pid}" 2>/dev/null || true
  stop_process "${admin_pf_pid}"; stop_process "${adapter_pf_pid}"
  admin_pf_pid=""; adapter_pf_pid=""; observer_pid=""; observer_stop_file=""
}

write_cleanup() {
  local exit_code=$1 containers networks processes context_after helm_hash_after
  containers="$(remaining_cluster_containers)"; networks="$(remaining_cluster_networks)"; processes="$(remaining_owned_processes)"
  if [[ "${original_kubeconfig_set}" == true ]]; then context_after="$(KUBECONFIG="${original_kubeconfig_value}" kubectl config current-context 2>/dev/null)" || context_after="__UNSET__"; else context_after="$(env -u KUBECONFIG kubectl config current-context 2>/dev/null)" || context_after="__UNSET__"; fi
  [[ "${context_after}" == "${original_context}" ]] && original_context_unchanged=true
  helm_hash_after="$(file_hash_or_absent "${original_helm_repository_config}")"
  [[ "${helm_hash_after}" == "${original_helm_repository_hash}" ]] && original_helm_config_unchanged=true
  jq -n --argjson exit_code "${exit_code}" --argjson cluster_removed "${cluster_removed}" --argjson containers "${containers}" --argjson networks "${networks}" --argjson processes "${processes}" --argjson temporary_kubeconfig_removed "${temporary_kubeconfig_removed}" --argjson temporary_helm_state_removed "${temporary_helm_state_removed}" --argjson original_context_unchanged "${original_context_unchanged}" --argjson original_helm_config_unchanged "${original_helm_config_unchanged}" --arg original_context_state "${original_context_state}" '{runner_exit_code:$exit_code,cluster_removed:$cluster_removed,remaining_owned_containers:$containers,remaining_owned_networks:$networks,remaining_owned_port_forwards:$processes,temporary_kubeconfig_removed:$temporary_kubeconfig_removed,temporary_helm_state_removed:$temporary_helm_state_removed,original_context_state:$original_context_state,original_context_unchanged:$original_context_unchanged,original_helm_repository_config_unchanged:$original_helm_config_unchanged}' >"${result_dir}/cleanup.json"
}

cleanup() {
  local exit_code=$?
  if [[ "${cleanup_started}" == true ]]; then exit "${exit_code}"; fi
  cleanup_started=true
  set +e
  stop_scenario_backgrounds
  if [[ "${cluster_created}" == true ]]; then
    kubectl delete apiservice "${ADAPTER_API_SERVICE}" --ignore-not-found >"${result_dir}/apiservice-delete.log" 2>&1
    kubectl delete namespace "${BLIND_NAMESPACE}" "${AWARE_NAMESPACE}" "${LOAD_NAMESPACE}" --ignore-not-found >"${result_dir}/namespace-delete.log" 2>&1
    helm uninstall istiod --namespace "${ISTIO_NAMESPACE}" >"${result_dir}/istiod-uninstall.log" 2>&1
    helm uninstall istio-base --namespace "${ISTIO_NAMESPACE}" >"${result_dir}/istio-base-uninstall.log" 2>&1
    kubectl delete namespace "${ISTIO_NAMESPACE}" --ignore-not-found >"${result_dir}/istio-namespace-delete.log" 2>&1
    k3d cluster delete "${CLUSTER_NAME}" >"${result_dir}/cluster-delete.log" 2>&1 && cluster_removed=true
  else
    cluster_removed=true
  fi
  rm -rf "${runtime_root}"
  [[ ! -e "${runtime_root}" ]] && temporary_kubeconfig_removed=true && temporary_helm_state_removed=true
  write_cleanup "${exit_code}"
  set -e
  exit "${exit_code}"
}
trap cleanup EXIT INT TERM

start_pod_port_forward() {
  local namespace=$1 pod=$2 remote_port=$3 log_file=$4 pid_var=$5 port_var=$6 pid port=""
  kubectl port-forward --namespace "${namespace}" "pod/${pod}" :"${remote_port}" >"${log_file}" 2>&1 & pid=$!
  for _ in {1..80}; do port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) ->.*/\1/p' "${log_file}" | head -n 1)"; [[ -n "${port}" ]] && break; kill -0 "${pid}" 2>/dev/null || break; sleep 0.1; done
  [[ -n "${port}" ]] || { printf 'port-forward did not become ready for %s/%s:%s\n' "${namespace}" "${pod}" "${remote_port}" >&2; return 1; }
  printf -v "${pid_var}" '%s' "${pid}"; printf -v "${port_var}" '%s' "${port}"
}

start_service_port_forward() {
  local namespace=$1 service=$2 remote_port=$3 log_file=$4 pid_var=$5 port_var=$6 pid port=""
  kubectl port-forward --namespace "${namespace}" "service/${service}" :"${remote_port}" >"${log_file}" 2>&1 & pid=$!
  for _ in {1..80}; do port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) ->.*/\1/p' "${log_file}" | head -n 1)"; [[ -n "${port}" ]] && break; kill -0 "${pid}" 2>/dev/null || break; sleep 0.1; done
  [[ -n "${port}" ]] || { printf 'service port-forward did not become ready for %s/%s:%s\n' "${namespace}" "${service}" "${remote_port}" >&2; return 1; }
  printf -v "${pid_var}" '%s' "${pid}"; printf -v "${port_var}" '%s' "${port}"
}

wait_for_url() { local url=$1; for _ in {1..80}; do curl --fail --silent --show-error "${url}" >/dev/null 2>&1 && return 0; sleep 0.25; done; return 1; }
put_application_fault() { local url=$1 body=$2 output=$3; curl --fail --silent --show-error --request PUT --header "Authorization: Bearer ${admin_token}" --header 'Content-Type: application/json' --data "${body}" "${url}/admin/fault" >"${output}"; }
stat_value() { local file=$1 metric=$2; awk -F': ' -v metric="${metric}" '$1 == metric { print $2+0; found=1; exit } END { if (!found) print 0 }' "${file}"; }
collect_proxy_stats() { kubectl exec --namespace "$1" "$2" -c istio-proxy -- pilot-agent request GET 'stats?filter=8080' >"$3"; }

discover_proxy_config() {
  local namespace=$1 pod=$2 scenario_dir=$3 config_dump threshold retry_count retry_budget
  config_dump="${scenario_dir}/proxy-config-dump.json"
  kubectl exec --namespace "${namespace}" "${pod}" -c istio-proxy -- pilot-agent request GET config_dump >"${config_dump}"
  kubectl exec --namespace "${namespace}" "${pod}" -c istio-proxy -- pilot-agent request GET server_info >"${scenario_dir}/proxy-server-info.json"
  kubectl exec --namespace "${namespace}" "${pod}" -c istio-proxy -- pilot-agent request GET stats >"${scenario_dir}/proxy-stats-inventory.txt"
  jq '.. | objects | select((.name? // "") == "inbound|8080||" and has("circuit_breakers"))' "${config_dump}" >"${scenario_dir}/target-inbound-cluster.json"
  threshold="$(jq -r '.circuit_breakers.thresholds[] | select((.priority // "DEFAULT") == "DEFAULT") | .max_requests // empty' "${scenario_dir}/target-inbound-cluster.json" | head -n 1)"
  [[ "${threshold}" == "${SIDECAR_CAPACITY_TARGET}" ]] || { printf 'expected actual max_requests=%s, got %s\n' "${SIDECAR_CAPACITY_TARGET}" "${threshold:-missing}" >&2; return 1; }
  jq '[.. | objects | select(((.filter_chain_match?.destination_port? // "") | tostring) == "8080") | .filters[]?.typed_config? | select((."@type"? // "") | endswith("HttpConnectionManager"))]' "${config_dump}" >"${scenario_dir}/target-inbound-http-config.json"
  retry_count="$(jq '[.. | objects | select(has("retry_policy"))] | length' "${scenario_dir}/target-inbound-http-config.json")"
  retry_budget="$(jq '[.. | objects | .retry_policy?.num_retries? // empty] | max // 0' "${scenario_dir}/target-inbound-http-config.json")"
  jq -n --argjson generated_max_requests "${threshold}" --argjson inbound_route_retry_policy_count "${retry_count}" --argjson inbound_route_retry_budget_max "${retry_budget}" '{cluster:"inbound|8080||",generated_max_requests:$generated_max_requests,inbound_route_retry_policy_count:$inbound_route_retry_policy_count,inbound_route_retry_budget_max:$inbound_route_retry_budget_max}' >"${scenario_dir}/proxy-metric-mapping.json"
  [[ "${retry_count}" -eq 0 && "${retry_budget}" -eq 0 ]] || { printf 'no-retry EnvoyFilter contract failed\n' >&2; return 1; }
}

apply_retry_disable_patch() {
  local namespace=$1 release=$2 manifest=$3 scenario_dir=$4 before_pod after_pod
  before_pod="$(kubectl get pods --namespace "${namespace}" --selector "app.kubernetes.io/instance=${release}" -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 1)][0].metadata.name // empty')"
  kubectl apply -f "${manifest}" >"${scenario_dir}/retry-disabled-apply.log"
  kubectl rollout restart deployment/"${release}" --namespace "${namespace}" >"${scenario_dir}/retry-disabled-rollout-restart.log"
  kubectl rollout status deployment/"${release}" --namespace "${namespace}" --timeout=180s >"${scenario_dir}/retry-disabled-rollout-status.log"
  after_pod="$(kubectl get pods --namespace "${namespace}" --selector "app.kubernetes.io/instance=${release}" -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 1)][0].metadata.name // empty')"
  [[ -n "${after_pod}" ]] || { printf 'no Ready Pod after EnvoyFilter rollout\n' >&2; return 1; }
  [[ "${before_pod}" != "${after_pod}" ]] || { printf 'EnvoyFilter rollout did not replace workload Pod\n' >&2; return 1; }
  printf '%s' "${after_pod}"
}

write_adapter_manifest() {
  local scenario=$1 namespace=$2 release=$3 scenario_dir=$4 rendered="${scenario_dir}/custom-metrics-adapter-rendered.yaml"
  sed -e "s/capacity-cascade-l05-aware/${namespace}/g" -e "s/auth-sim-aware/${release}/g" -e "s#capacity-cascade/auth-sim:l05-placeholder#${AUTH_SIM_IMAGE_VALUE}#g" "${PROJECT_ROOT}/l05/custom-metrics-adapter.yaml" >"${rendered}"
  if [[ "${scenario}" == hpa-blind ]]; then awk '/^apiVersion: apiregistration.k8s.io\/v1$/ { exit } { print }' "${rendered}" >"${scenario_dir}/custom-metrics-adapter-observer.yaml"; else cp "${rendered}" "${scenario_dir}/custom-metrics-adapter-observer.yaml"; fi
  kubectl apply -f "${scenario_dir}/custom-metrics-adapter-observer.yaml" >"${scenario_dir}/custom-metrics-adapter-apply.log"
  kubectl rollout status deployment/"${ADAPTER_NAME}" --namespace "${namespace}" --timeout=180s >"${scenario_dir}/custom-metrics-adapter-rollout.log"
  if [[ "${scenario}" == hpa-aware ]]; then
    kubectl wait --for=condition=Available "apiservice/${ADAPTER_API_SERVICE}" --timeout=120s >"${scenario_dir}/custom-metrics-apiservice-available.log"
    kubectl get apiservice "${ADAPTER_API_SERVICE}" -o json >"${scenario_dir}/custom-metrics-apiservice.json"
  fi
}

append_sample() {
  local scenario=$1 namespace=$2 release=$3 adapter_url=$4 samples_file=$5 hpa_file snapshot_file pods_file endpoints_file timestamp
  hpa_file="${samples_file}.hpa.tmp"; snapshot_file="${samples_file}.snapshot.tmp"; pods_file="${samples_file}.pods.tmp"; endpoints_file="${samples_file}.endpoints.tmp"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  kubectl get hpa auth-sim-scaling --namespace "${namespace}" -o json >"${hpa_file}"
  curl --insecure --fail --silent --show-error "${adapter_url}/snapshot" >"${snapshot_file}"
  kubectl get pods --namespace "${namespace}" --selector "app.kubernetes.io/instance=${release}" -o json >"${pods_file}"
  kubectl get endpointslice --namespace "${namespace}" --selector "kubernetes.io/service-name=${release}" -o json >"${endpoints_file}"
  jq -cn --arg timestamp_utc "${timestamp}" --arg scenario "${scenario}" --slurpfile hpa "${hpa_file}" --slurpfile snapshot "${snapshot_file}" --slurpfile pods "${pods_file}" --slurpfile endpoints "${endpoints_file}" '
    ($hpa[0]) as $h | ($snapshot[0]) as $s | ($pods[0]) as $p | ($endpoints[0]) as $e |
    {timestamp_utc:$timestamp_utc,scenario:$scenario,
     hpa:{current_replicas:($h.status.currentReplicas // 0),desired_replicas:($h.status.desiredReplicas // 0),last_scale_time:($h.status.lastScaleTime // null),current_metrics:($h.status.currentMetrics // []),conditions:($h.status.conditions // [])},
     proxy:$s.proxy,application:$s.application,
     exporter_pods:($s.pods | map({name:.name,upstream_active:.exporter.proxy.upstream_active})),
     pods:($p.items | map({name:.metadata.name,phase:.status.phase,pod_ip:.status.podIP,ready:([.status.conditions[]? | select(.type=="Ready" and .status=="True")] | length == 1)})),
     endpoints_ready:([$e.items[]?.endpoints[]? | select(.conditions.ready == true)] | length)}' >>"${samples_file}"
}

observe_loop() {
  local scenario=$1 namespace=$2 release=$3 adapter_url=$4 samples_file=$5 stop_file=$6
  while [[ ! -e "${stop_file}" ]]; do append_sample "${scenario}" "${namespace}" "${release}" "${adapter_url}" "${samples_file}"; sleep "${SAMPLE_INTERVAL_SECONDS_VALUE}"; done
}

create_k6_job() {
  local scenario=$1 namespace=$2 release=$3 scenario_dir=$4 proxy_image=$5 configmap="l05-k6-${scenario#hpa-}" job="l05-k6-${scenario#hpa-}" service_fqdn="${release}.${namespace}.svc.cluster.local" load_pod
  kubectl create configmap "${configmap}" --namespace "${LOAD_NAMESPACE}" --from-file=l05.js="${PROJECT_ROOT}/load/k6/l05.js" --from-file=config.js="${PROJECT_ROOT}/load/k6/lib/config.js" --from-file=retry.js="${PROJECT_ROOT}/load/k6/lib/retry.js" --from-file=summary.js="${PROJECT_ROOT}/load/k6/lib/summary.js" --dry-run=client -o yaml >"${scenario_dir}/k6-configmap.yaml"
  kubectl apply -f "${scenario_dir}/k6-configmap.yaml" >"${scenario_dir}/k6-configmap-apply.log"
  cat >"${scenario_dir}/k6-job.yaml" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${LOAD_NAMESPACE}
  labels:
    capacity-cascade-lab/owner: l05
    capacity-cascade-lab/scenario: ${scenario}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 420
  template:
    metadata:
      labels:
        capacity-cascade-lab/owner: l05
        capacity-cascade-lab/scenario: ${scenario}
        sidecar.istio.io/inject: "false"
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        fsGroup: 12345
      containers:
        - name: k6
          image: ${K6_IMAGE_VALUE}
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh", "-c"]
          args:
            - |
              set +e
              k6 version > /results/k6-version.txt
              k6 run /scripts/l05.js
              code=\$?
              printf '%s\\n' "\${code}" > /results/k6.exit
              : > /results/k6.done
              while [ ! -f /results/collected ]; do sleep 1; done
              exit "\${code}"
          env:
            - {name: BASE_URL, value: "http://${service_fqdn}:8080"}
            - {name: RESULT_DIR, value: "/results"}
            - {name: STARTED_AT_UTC, value: "${started_at_utc}"}
            - {name: GIT_COMMIT, value: "${SOURCE_COMMIT}"}
            - {name: GIT_DIRTY, value: "false"}
            - {name: GO_VERSION, value: "not-used"}
            - {name: K6_VERSION, value: "${K6_IMAGE_VALUE}"}
            - {name: DOCKER_VERSION, value: "not-used"}
            - {name: LAB_OS, value: "linux-container"}
            - {name: LAB_ARCH, value: "amd64"}
            - {name: L05_SCENARIO, value: "${scenario}"}
            - {name: LOGICAL_RATE, value: "${LOGICAL_RATE_VALUE}"}
            - {name: DURATION, value: "${DURATION_VALUE}"}
            - {name: REQUEST_TIMEOUT, value: "${REQUEST_TIMEOUT_VALUE}"}
            - {name: APPLICATION_LATENCY_MS, value: "${APPLICATION_LATENCY_MS_VALUE}"}
            - {name: FAULT_SEED, value: "${FAULT_SEED_VALUE}"}
            - {name: LOGICAL_ID_NAMESPACE, value: "${LOGICAL_ID_NAMESPACE_VALUE}"}
            - {name: SIDECAR_ACTIVE_REQUEST_TARGET, value: "${SIDECAR_CAPACITY_TARGET}"}
            - {name: REQUEST_PATH, value: "non-injected k6 Job -> ClusterIP Service :8080 -> target Pod istio-proxy -> auth-sim"}
            - {name: AUTH_SIM_IMAGE, value: "${AUTH_SIM_IMAGE_VALUE}"}
            - {name: K6_IMAGE, value: "${K6_IMAGE_VALUE}"}
            - {name: ISTIO_PROXY_IMAGE, value: "${proxy_image}"}
          securityContext:
            runAsNonRoot: true
            runAsUser: 12345
            runAsGroup: 12345
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - {name: scripts, mountPath: /scripts/l05.js, subPath: l05.js, readOnly: true}
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
  kubectl apply -f "${scenario_dir}/k6-job.yaml" >"${scenario_dir}/k6-job-apply.log"
  for _ in {1..60}; do
    load_pod="$(kubectl get pods --namespace "${LOAD_NAMESPACE}" --selector "job-name=${job}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "${load_pod}" ]] && break
    sleep 0.2
  done
  [[ -n "${load_pod}" ]] || { printf 'k6 Job Pod was not created\n' >&2; return 1; }
  kubectl get pod "${load_pod}" --namespace "${LOAD_NAMESPACE}" -o json >"${scenario_dir}/k6-pod.json"
  [[ "$(jq '[.spec.containers[].name] | index("istio-proxy")' "${scenario_dir}/k6-pod.json")" == null ]] || { printf 'load generator must not have an injected sidecar\n' >&2; return 1; }
  local result_ready=false
  for _ in {1..420}; do
    if kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- test -f /results/k6.done >/dev/null 2>&1; then result_ready=true; break; fi
    [[ "$(kubectl get pod "${load_pod}" --namespace "${LOAD_NAMESPACE}" -o jsonpath='{.status.phase}')" == Failed ]] && break
    sleep 0.5
  done
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
  local scenario=$1 scenario_dir=$2 samples="${scenario_dir}/samples.jsonl" summary="${scenario_dir}/k6-summary.json"
  local logical physical retries failures p95 status200 status503 status504 desired_max current_max pod_max overflow_delta downstream_delta upstream_delta app_tokens app_admission samples_count custom_metric_seen passed
  logical="$(jq -r '.metrics.logical_requests.values.count' "${summary}")"; physical="$(jq -r '.metrics.physical_attempts.values.count' "${summary}")"; retries="$(jq -r '.metrics.retry_attempts.values.count' "${summary}")"; failures="$(jq -r '.metrics.logical_failures.values.rate' "${summary}")"; p95="$(jq -r '.metrics.logical_request_duration.values["p(95)"]' "${summary}")"
  status200="$(jq -r '.metrics.downstream_responses_200.values.count // 0' "${summary}")"; status503="$(jq -r '.metrics.downstream_responses_503.values.count // 0' "${summary}")"; status504="$(jq -r '.metrics.downstream_responses_504.values.count // 0' "${summary}")"
  samples_count="$(jq -s 'length' "${samples}")"; desired_max="$(jq -s '[.[].hpa.desired_replicas] | max // 0' "${samples}")"; current_max="$(jq -s '[.[].hpa.current_replicas] | max // 0' "${samples}")"; pod_max="$(jq -s '[.[].pods | length] | max // 0' "${samples}")"
  overflow_delta="$(jq -s '(.[-1].proxy.active_overflow // 0) - (.[0].proxy.active_overflow // 0)' "${samples}")"; downstream_delta="$(jq -s '(.[-1].proxy.downstream_total // 0) - (.[0].proxy.downstream_total // 0)' "${samples}")"; upstream_delta="$(jq -s '(.[-1].proxy.upstream_total // 0) - (.[0].proxy.upstream_total // 0)' "${samples}")"; app_tokens="$(jq -s '(.[-1].application.token_requests // 0) - (.[0].application.token_requests // 0)' "${samples}")"; app_admission="$(jq -s '(.[-1].application.admission_rejections // 0) - (.[0].application.admission_rejections // 0)' "${samples}")"
  custom_metric_seen="$(jq -s '[.[].hpa.current_metrics[]? | select(.type=="Pods" and .pods.metric.name=="sidecar_active_requests")] | length > 0' "${samples}")"
  passed=false
  if [[ "${scenario}" == hpa-blind ]]; then
    if [[ "${logical}" -eq "${physical}" && "${retries}" -eq 0 && "${status503}" -gt 0 && "${overflow_delta}" -gt 0 && "${app_admission}" -eq 0 && "${desired_max}" -eq 1 && "${current_max}" -eq 1 && "${pod_max}" -eq 1 ]]; then passed=true; fi
  else
    if [[ "${logical}" -eq "${physical}" && "${retries}" -eq 0 && "${desired_max}" -gt 1 && "${current_max}" -gt 1 && "${pod_max}" -gt 1 && "${custom_metric_seen}" == true && "${app_admission}" -eq 0 ]]; then passed=true; fi
  fi
  jq -n --argjson passed "${passed}" --arg scenario "${scenario}" --argjson logical_requests "${logical}" --argjson physical_attempts "${physical}" --argjson retry_attempts "${retries}" --argjson logical_failure_rate "${failures}" --argjson logical_p95_ms "${p95}" --argjson status200 "${status200}" --argjson status503 "${status503}" --argjson status504 "${status504}" --argjson hpa_desired_replicas_max "${desired_max}" --argjson hpa_current_replicas_max "${current_max}" --argjson workload_pod_count_max "${pod_max}" --argjson proxy_active_overflow_delta "${overflow_delta}" --argjson proxy_downstream_delta "${downstream_delta}" --argjson proxy_upstream_delta "${upstream_delta}" --argjson application_token_delta "${app_tokens}" --argjson application_admission_rejection_delta "${app_admission}" --argjson timestamped_samples "${samples_count}" --argjson custom_metric_seen "${custom_metric_seen}" '{passed:$passed,scenario:$scenario,k6:{logical_requests:$logical_requests,physical_attempts:$physical_attempts,retry_attempts:$retry_attempts,logical_failure_rate:$logical_failure_rate,logical_p95_ms:$logical_p95_ms,status:{"200":$status200,"503":$status503,"504":$status504}},hpa:{desired_replicas_max:$hpa_desired_replicas_max,current_replicas_max:$hpa_current_replicas_max,custom_metric_seen:$custom_metric_seen},proxy:{active_overflow_delta:$proxy_active_overflow_delta,downstream_delta:$proxy_downstream_delta,upstream_delta:$proxy_upstream_delta},application:{token_delta:$application_token_delta,admission_rejection_delta:$application_admission_rejection_delta},sampling:{total:$timestamped_samples}}' >"${scenario_dir}/contract.json"
  scenario_contract["${scenario}"]="${passed}"; scenario_desired_max["${scenario}"]="${desired_max}"; scenario_pod_max["${scenario}"]="${pod_max}"; scenario_failure_rate["${scenario}"]="${failures}"; scenario_overflow["${scenario}"]="${overflow_delta}"
  cat >"${scenario_dir}/summary.md" <<EOF
# ${scenario} L05 summary

> This is local exploratory evidence, not a production benchmark or GitHub configuration evidence.

| Observation | Value |
| --- | ---: |
| Contract | ${passed} |
| Logical / physical / retry | ${logical} / ${physical} / ${retries} |
| Downstream 200 / 503 / 504 | ${status200} / ${status503} / ${status504} |
| Logical failure / P95 | ${failures} / ${p95} ms |
| HPA desired / current replica peak | ${desired_max} / ${current_max} |
| Ready workload Pod peak | ${pod_max} |
| Proxy active overflow delta | ${overflow_delta} |
| Proxy downstream / upstream delta | ${downstream_delta} / ${upstream_delta} |
| Application token / admission rejection delta | ${app_tokens} / ${app_admission} |
| Timestamped samples | ${samples_count} |
EOF
}

run_scenario() {
  local scenario=$1 namespace="${SCENARIO_NAMESPACE[$1]}" release="${SCENARIO_RELEASE[$1]}" scenario_dir="${result_dir}/$1" sidecar_manifest="${PROJECT_ROOT}/l05/sidecar-${scenario#hpa-}.yaml" retry_manifest="${PROJECT_ROOT}/l05/retry-disabled-${scenario#hpa-}.yaml" hpa_manifest="${PROJECT_ROOT}/l05/hpa-${scenario#hpa-}.yaml"
  local pod admin_port adapter_port admin_url adapter_url proxy_image
  kubectl create namespace "${namespace}" >"${scenario_dir}/namespace-create.log"
  kubectl label namespace "${namespace}" istio-injection=enabled --overwrite >"${scenario_dir}/namespace-injection-label.log"
  kubectl apply --server-side --dry-run=server -f "${sidecar_manifest}" >"${scenario_dir}/sidecar-server-dry-run.log"
  kubectl apply -f "${sidecar_manifest}" >"${scenario_dir}/sidecar-apply.log"
  printf '%s' "${admin_token}" | kubectl create secret generic "${ADMIN_SECRET}" --namespace "${namespace}" --from-file=token=/dev/stdin >"${scenario_dir}/secret-create.log"
  helm template "${release}" "${CHART_DIR}" --namespace "${namespace}" --set-string image.repository="${IMAGE_REPOSITORY}" --set-string image.tag="${IMAGE_TAG}" --set-string adminSecret.name="${ADMIN_SECRET}" --set-string adminSecret.key=token --set sidecarMetricsExporter.enabled=true >"${scenario_dir}/auth-sim-rendered.yaml"
  grep -q 'name: proxy-metrics-exporter' "${scenario_dir}/auth-sim-rendered.yaml"
  helm upgrade --install "${release}" "${CHART_DIR}" --namespace "${namespace}" --set-string image.repository="${IMAGE_REPOSITORY}" --set-string image.tag="${IMAGE_TAG}" --set-string adminSecret.name="${ADMIN_SECRET}" --set-string adminSecret.key=token --set sidecarMetricsExporter.enabled=true --wait --timeout 180s >"${scenario_dir}/auth-sim-helm-install.log" 2>&1
  kubectl rollout status deployment/"${release}" --namespace "${namespace}" --timeout=180s >"${scenario_dir}/auth-sim-rollout.log"
  pod="$(kubectl get pods --namespace "${namespace}" --selector "app.kubernetes.io/instance=${release}" -o jsonpath='{.items[0].metadata.name}')"
  kubectl get pod "${pod}" --namespace "${namespace}" -o json >"${scenario_dir}/pod-before-retry-disable.json"
  pod="$(apply_retry_disable_patch "${namespace}" "${release}" "${retry_manifest}" "${scenario_dir}")"
  kubectl get deployment "${release}" --namespace "${namespace}" -o json >"${scenario_dir}/deployment.json"
  kubectl get service "${release}" --namespace "${namespace}" -o json >"${scenario_dir}/service.json"
  kubectl get pod "${pod}" --namespace "${namespace}" -o json >"${scenario_dir}/pod.json"
  kubectl get pod "${pod}" --namespace "${namespace}" -o wide >"${scenario_dir}/pod-wide.txt"
  [[ "$(jq '[.status.containerStatuses[]?,.status.initContainerStatuses[]? | select(.name=="auth-sim" and .ready==true)] | length' "${scenario_dir}/pod.json")" -eq 1 ]] || { printf 'auth-sim is not Ready\n' >&2; return 1; }
  [[ "$(jq '[.status.containerStatuses[]?,.status.initContainerStatuses[]? | select(.name=="proxy-metrics-exporter" and .ready==true)] | length' "${scenario_dir}/pod.json")" -eq 1 ]] || { printf 'exporter is not Ready\n' >&2; return 1; }
  [[ "$(jq '[.status.containerStatuses[]?,.status.initContainerStatuses[]? | select(.name=="istio-proxy" and .ready==true)] | length' "${scenario_dir}/pod.json")" -eq 1 ]] || { printf 'injected istio-proxy is not Ready\n' >&2; return 1; }
  proxy_image="$(jq -r '[.spec.containers[]?,.spec.initContainers[]? | select(.name=="istio-proxy")][0].image' "${scenario_dir}/pod.json")"
  discover_proxy_config "${namespace}" "${pod}" "${scenario_dir}"
  write_adapter_manifest "${scenario}" "${namespace}" "${release}" "${scenario_dir}"
  start_pod_port_forward "${namespace}" "${pod}" 9090 "${scenario_dir}/port-forward-admin.log" admin_pf_pid admin_port
  start_service_port_forward "${namespace}" "${ADAPTER_NAME}" 443 "${scenario_dir}/port-forward-adapter.log" adapter_pf_pid adapter_port
  admin_url="http://127.0.0.1:${admin_port}"; adapter_url="https://127.0.0.1:${adapter_port}"
  wait_for_url "${admin_url}/admin/fault" || { printf 'admin port-forward unavailable\n' >&2; return 1; }
  for _ in {1..80}; do curl --insecure --fail --silent "${adapter_url}/snapshot" >"${scenario_dir}/adapter-snapshot-before.json" 2>/dev/null && break; sleep 0.5; done
  [[ -s "${scenario_dir}/adapter-snapshot-before.json" ]] || { printf 'adapter snapshot unavailable\n' >&2; return 1; }
  put_application_fault "${admin_url}" '{"latency_ms":0,"error_rate":0,"max_in_flight":0,"seed":17082026}' "${scenario_dir}/application-fault-reset-before.json"
  put_application_fault "${admin_url}" "{\"latency_ms\":${APPLICATION_LATENCY_MS_VALUE},\"error_rate\":0,\"max_in_flight\":0,\"seed\":${FAULT_SEED_VALUE}}" "${scenario_dir}/application-fault-applied.json"
  kubectl apply -f "${hpa_manifest}" >"${scenario_dir}/hpa-apply.log"
  kubectl get hpa auth-sim-scaling --namespace "${namespace}" -o json >"${scenario_dir}/hpa-initial.json"
  if [[ "${scenario}" == hpa-aware ]]; then
    for _ in {1..80}; do kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta2/namespaces/${namespace}/pods/*/sidecar_active_requests" >"${scenario_dir}/custom-metric-before.json" 2>/dev/null && break; sleep 0.5; done
    [[ -s "${scenario_dir}/custom-metric-before.json" ]] || { printf 'custom metric API unavailable\n' >&2; return 1; }
  fi
  : >"${scenario_dir}/samples.jsonl"
  append_sample "${scenario}" "${namespace}" "${release}" "${adapter_url}" "${scenario_dir}/samples.jsonl"
  observer_stop_file="${scenario_dir}/observer.stop"
  observe_loop "${scenario}" "${namespace}" "${release}" "${adapter_url}" "${scenario_dir}/samples.jsonl" "${observer_stop_file}" & observer_pid=$!
  create_k6_job "${scenario}" "${namespace}" "${release}" "${scenario_dir}" "${proxy_image}"
  : >"${observer_stop_file}"; wait "${observer_pid}"; observer_pid=""
  append_sample "${scenario}" "${namespace}" "${release}" "${adapter_url}" "${scenario_dir}/samples.jsonl"
  kubectl get hpa auth-sim-scaling --namespace "${namespace}" -o yaml >"${scenario_dir}/hpa-final.yaml"
  kubectl get events --namespace "${namespace}" --field-selector "involvedObject.kind=HorizontalPodAutoscaler,involvedObject.name=auth-sim-scaling" -o json >"${scenario_dir}/hpa-events.json"
  kubectl get deployment,pods,endpointslice --namespace "${namespace}" -o json >"${scenario_dir}/workload-final.json"
  kubectl top pods --namespace "${namespace}" --containers >"${scenario_dir}/container-usage.txt" 2>"${scenario_dir}/container-usage-error.txt" || true
  put_application_fault "${admin_url}" '{"latency_ms":0,"error_rate":0,"max_in_flight":0,"seed":17082026}' "${scenario_dir}/application-fault-reset-after.json"
  write_scenario_contract "${scenario}" "${scenario_dir}"
  [[ "${scenario_contract[${scenario}]}" == true || "${ACTION}" == smoke ]] || { printf 'scenario contract failed: %s\n' "${scenario}" >&2; return 1; }
  stop_scenario_backgrounds
}

write_root_metadata() {
  local git_dirty=false
  [[ -n "$(git status --porcelain --untracked-files=normal)" ]] && git_dirty=true
  jq -n --arg started_at_utc "${started_at_utc}" --arg git_commit "${SOURCE_COMMIT}" --argjson git_dirty "${git_dirty}" --arg action "${ACTION}" --arg k3s_image "${K3S_IMAGE_VALUE}" --arg istio_version "${ISTIO_VERSION_VALUE}" --arg istio_chart_repository "${ISTIO_CHART_REPOSITORY_VALUE}" --arg istio_image_hub "${ISTIO_IMAGE_HUB_VALUE}" --arg auth_image "${AUTH_SIM_IMAGE_VALUE}" --arg k6_image "${K6_IMAGE_VALUE}" --argjson logical_rate "${LOGICAL_RATE_VALUE}" --arg duration "${DURATION_VALUE}" --arg request_timeout "${REQUEST_TIMEOUT_VALUE}" --argjson application_latency_ms "${APPLICATION_LATENCY_MS_VALUE}" --arg sample_interval "${SAMPLE_INTERVAL_SECONDS_VALUE}s" '{project:"GitHub Capacity Cascade Lab",learning_unit:"L05",classification:"local exploratory evidence",scenario_mode:$action,started_at_utc:$started_at_utc,git_commit:$git_commit,git_dirty:$git_dirty,cluster:{name:"capacity-cascade-l05",servers:1,agents:0,k3s_image:$k3s_image,api_exposure:"dynamic loopback port"},istio:{version:$istio_version,chart_repository:$istio_chart_repository,image_hub:$istio_image_hub,install:"pinned Helm istio-base then istiod; no gateway or CNI"},images:{auth_sim:$auth_image,k6:$k6_image},comparison:{sidecar_active_request_target:1,application_latency_ms:$application_latency_ms,logical_rate:$logical_rate,duration:$duration,request_timeout:$request_timeout,client_retry:"none",proxy_retry:"none",sampling_interval:$sample_interval,blind_metric:"ContainerResource auth-sim CPU utilization 80%",capacity_aware_metric:"Pods custom metric sidecar_active_requests, average value 500m"}}' >"${result_dir}/metadata.json"
}

printf 'L05 result directory: %s\n' "${result_dir}"
helm lint "${CHART_DIR}" --set-string image.repository="${IMAGE_REPOSITORY}" --set-string image.tag="${IMAGE_TAG}" >"${result_dir}/auth-sim-helm-lint.log"
docker build --tag "${AUTH_SIM_IMAGE_VALUE}" . >"${result_dir}/auth-sim-docker-build.log" 2>&1
docker pull "${K6_IMAGE_VALUE}" >"${result_dir}/k6-image-pull.log" 2>&1
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
kubectl create namespace "${LOAD_NAMESPACE}" >"${result_dir}/load-namespace-create.log"; kubectl label namespace "${LOAD_NAMESPACE}" istio-injection=disabled --overwrite >"${result_dir}/load-namespace-label.log"; load_namespace_created=true
write_root_metadata
for scenario in "${RUN_SCENARIOS[@]}"; do run_scenario "${scenario}"; done

if [[ "${ACTION}" == pair ]]; then
  pair_passed=false
  failure_improved=false
  if awk -v blind="${scenario_failure_rate[hpa-blind]}" -v aware="${scenario_failure_rate[hpa-aware]}" 'BEGIN { exit !(aware < blind) }'; then failure_improved=true; fi
  if [[ "${scenario_contract[hpa-blind]}" == true && "${scenario_contract[hpa-aware]}" == true && "${scenario_desired_max[hpa-aware]}" -gt "${scenario_desired_max[hpa-blind]}" && "${scenario_pod_max[hpa-aware]}" -gt "${scenario_pod_max[hpa-blind]}" && "${failure_improved}" == true && "${scenario_overflow[hpa-aware]}" -lt "${scenario_overflow[hpa-blind]}" ]]; then pair_passed=true; fi
  jq -n --argjson passed "${pair_passed}" --argjson blind "$(cat "${result_dir}/hpa-blind/contract.json")" --argjson aware "$(cat "${result_dir}/hpa-aware/contract.json")" '{passed:$passed,blind:$blind,capacity_aware:$aware,comparison:{required:"aware desired/current replicas increase and failure/overflow improve against blind under the fixed workload"}}' >"${result_dir}/contract.json"
  cat >"${result_dir}/summary.md" <<EOF
# L05 HPA blind spot pair summary

> Local exploratory evidence only. The policies, thresholds, local topology and adapter are LAB_IMPLEMENTATION, not GitHub production configuration.

| Scenario | Contract | Desired replica peak | Pod peak | Failure rate | Active overflow delta |
| --- | --- | ---: | ---: | ---: | ---: |
| hpa-blind | ${scenario_contract[hpa-blind]} | ${scenario_desired_max[hpa-blind]} | ${scenario_pod_max[hpa-blind]} | ${scenario_failure_rate[hpa-blind]} | ${scenario_overflow[hpa-blind]} |
| hpa-aware | ${scenario_contract[hpa-aware]} | ${scenario_desired_max[hpa-aware]} | ${scenario_pod_max[hpa-aware]} | ${scenario_failure_rate[hpa-aware]} | ${scenario_overflow[hpa-aware]} |
EOF
  [[ "${pair_passed}" == true ]] || { printf 'L05 paired acceptance contract failed\n' >&2; exit 1; }
  contract_passed=true
fi
