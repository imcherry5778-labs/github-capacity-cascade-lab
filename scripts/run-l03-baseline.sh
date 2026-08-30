#!/usr/bin/env bash
# L03는 clean bootstrap부터 cleanup까지 한 실행 단위로 기록한다.
set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ACTION="${1:-run}"
readonly CHART_DIR="${PROJECT_ROOT}/charts/auth-sim"
readonly CLUSTER_NAME="capacity-cascade-l03"
readonly NAMESPACE="capacity-cascade-l03"
readonly RELEASE="auth-sim"
readonly ADMIN_SECRET="auth-sim-admin"
readonly K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.35.5-k3s1}"

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

clean_owned_cluster() {
  if cluster_exists; then
    k3d cluster delete "${CLUSTER_NAME}"
  fi
  local containers networks
  containers="$(remaining_cluster_containers)"
  networks="$(remaining_cluster_networks)"
  if [[ "${containers}" -ne 0 || "${networks}" -ne 0 ]]; then
    printf 'L03 cleanup incomplete: containers=%s networks=%s\n' "${containers}" "${networks}" >&2
    return 1
  fi
  printf 'L03 owned cluster resources are absent; evidence was preserved.\n'
}

if [[ "${ACTION}" == "clean" ]]; then
  for required_tool in docker k3d awk; do
    if ! command -v "${required_tool}" >/dev/null 2>&1; then
      printf 'required tool is missing: %s\n' "${required_tool}" >&2
      exit 127
    fi
  done
  docker info >/dev/null
  clean_owned_cluster
  exit 0
fi

if [[ "${ACTION}" != "run" ]]; then
  printf 'usage: %s {run|clean}\n' "$0" >&2
  exit 2
fi

case "${K3S_IMAGE}" in
  *:latest|latest)
    printf 'latest K3s image is forbidden: %s\n' "${K3S_IMAGE}" >&2
    exit 2
    ;;
  *:*) ;;
  *)
    printf 'K3S_IMAGE must have an explicit tag: %s\n' "${K3S_IMAGE}" >&2
    exit 2
    ;;
esac

# Resource를 만들기 전에 모든 필수 tool과 Docker daemon을 확인한다.
for required_tool in git go k6 docker kubectl k3d helm make curl awk sed grep wc tr mktemp; do
  if ! command -v "${required_tool}" >/dev/null 2>&1; then
    printf 'required tool is missing: %s\n' "${required_tool}" >&2
    exit 127
  fi
done
docker info >/dev/null
if cluster_exists; then
  printf 'refusing to replace existing exact L03 cluster: %s\n' "${CLUSTER_NAME}" >&2
  printf 'run make l03-clean after inspecting that cluster\n' >&2
  exit 1
fi
if [[ "$(remaining_cluster_containers)" -ne 0 || "$(remaining_cluster_networks)" -ne 0 ]]; then
  printf 'refusing to run while exact L03 Docker resources remain\n' >&2
  exit 1
fi

readonly SOURCE_COMMIT="$(git rev-parse HEAD)"
readonly SOURCE_SHORT="$(git rev-parse --short=12 HEAD)"
readonly IMAGE_REPOSITORY="${AUTH_SIM_REPOSITORY:-capacity-cascade/auth-sim}"
readonly IMAGE_TAG="${AUTH_SIM_TAG:-l03-${SOURCE_SHORT}}"
readonly AUTH_SIM_IMAGE_VALUE="${IMAGE_REPOSITORY}:${IMAGE_TAG}"
case "${AUTH_SIM_IMAGE_VALUE}" in
  *:latest|latest)
    printf 'latest auth-sim image is forbidden: %s\n' "${AUTH_SIM_IMAGE_VALUE}" >&2
    exit 2
    ;;
esac

started_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
result_parent="results/k3d-helm-baseline"
result_dir="${result_parent}/${timestamp}"
suffix=1
while [[ -e "${result_dir}" ]]; do
  result_dir="${result_parent}/${timestamp}-${suffix}"
  suffix=$((suffix + 1))
done
mkdir -p "${result_dir}/smoke"

# 현재 context 값은 비교에만 사용하고 이름이나 kubeconfig 경로는 evidence에 쓰지 않는다.
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
if [[ "${original_context}" == "__UNSET__" ]]; then
  original_context_state="unset"
else
  original_context_state="set"
fi

umask 077
kubeconfig_dir="$(mktemp -d "${TMPDIR:-/tmp}/capacity-cascade-l03.XXXXXX")"
kubeconfig_file="${kubeconfig_dir}/kubeconfig"
: >"${kubeconfig_file}"
chmod 600 "${kubeconfig_file}"
export KUBECONFIG="${kubeconfig_file}"

admin_token="l03-${RANDOM}-${RANDOM}-$$-$(date +%s)"
public_pf_pid=""
admin_pf_pid=""
public_port=""
admin_port=""

cluster_created=false
node_ready=false
image_built=false
image_imported=false
namespace_created=false
helm_release_deployed=false
deployment_available=false
initial_pod_ready=false
pod_replaced=false
replacement_pod_ready=false
pod_uid_changed=false
service_backend_ready=false
resource_usage_captured=false
smoke_passed=false
helm_release_removed=false
namespace_or_owned_resources_removed=false
cluster_removed=false
temporary_kubeconfig_removed=false
original_context_unchanged=false
remaining_containers=0
remaining_networks=0
remaining_port_forwards=0
smoke_logical_requests=0
smoke_physical_attempts=0
smoke_retry_attempts=0
smoke_exit=1
initial_pod_name="not-captured"
initial_pod_uid="not-captured"
replacement_pod_name="not-captured"
replacement_pod_uid="not-captured"
server_version="not-captured"
image_id="not-captured"

git_dirty=false
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then git_dirty=true; fi
git_version="$(git --version | awk '{print $3}')"
go_version="$(go version | awk '{print $3}')"
k6_version="$(k6 version | awk 'NR == 1 {print $2}')"
docker_version="$(docker version --format '{{.Client.Version}}')"
k3d_version="$(k3d version | awk 'NR == 1 {print $3}')"
k3d_default_k3s_version="$(k3d version | awk 'NR == 2 {print $3}')"
kubectl_client_version="$(kubectl version --client --output=yaml | awk '$1 == "gitVersion:" {print $2; exit}')"
helm_version="$(helm version --template '{{.Version}}')"

metric_value() {
  local file=$1
  local metric=$2
  local value=$3
  awk -v metric="\"${metric}\"" -v value="\"${value}\"" '
    $0 ~ metric "[[:space:]]*:" { in_metric=1; next }
    in_metric && $0 ~ value "[[:space:]]*:" {
      line=$0
      sub(/^.*:[[:space:]]*/, "", line)
      sub(/,.*/, "", line)
      print line
      exit
    }
  ' "${file}"
}

stop_port_forward() {
  local pid=$1
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    kill -TERM "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
}

write_metadata() {
  cat >"${result_dir}/metadata.json" <<EOF
{
  "project": "GitHub Capacity Cascade Lab",
  "learning_unit": "L03",
  "classification": "local exploratory evidence",
  "scenario": "k3d-helm-baseline",
  "started_at_utc": "${started_at_utc}",
  "git_commit": "${SOURCE_COMMIT}",
  "git_dirty": ${git_dirty},
  "tool_versions": {
    "git": "${git_version}",
    "go": "${go_version}",
    "k6": "${k6_version}",
    "docker": "${docker_version}",
    "k3d": "${k3d_version}",
    "k3d_default_k3s": "${k3d_default_k3s_version}",
    "kubectl_client": "${kubectl_client_version}",
    "kubernetes_server": "${server_version}",
    "helm": "${helm_version}"
  },
  "cluster": {
    "name": "${CLUSTER_NAME}",
    "servers": 1,
    "agents": 0,
    "k3s_image": "${K3S_IMAGE}",
    "api_exposure": "dynamic loopback port",
    "disabled_packaged_components": ["traefik", "servicelb", "local-storage"]
  },
  "workload": {
    "chart": "charts/auth-sim",
    "release": "${RELEASE}",
    "namespace": "${NAMESPACE}",
    "image": "${AUTH_SIM_IMAGE_VALUE}",
    "image_id": "${image_id}",
    "image_pull_policy": "Never",
    "replicas": 1,
    "resources": {
      "requests": {"cpu": "25m", "memory": "32Mi"},
      "limits": {"cpu": "250m", "memory": "128Mi"}
    }
  },
  "access": {
    "public": "host k6 -> loopback kubectl port-forward -> ClusterIP Service -> auth-sim Pod:8080",
    "admin": "runner -> loopback kubectl port-forward -> Deployment-selected auth-sim Pod:9090",
    "original_context_state": "${original_context_state}"
  }
}
EOF
}

write_contract() {
  local passed=false
  if [[ "${cluster_created}" == true \
    && "${node_ready}" == true \
    && "${image_imported}" == true \
    && "${helm_release_deployed}" == true \
    && "${deployment_available}" == true \
    && "${initial_pod_ready}" == true \
    && "${pod_replaced}" == true \
    && "${replacement_pod_ready}" == true \
    && "${pod_uid_changed}" == true \
    && "${service_backend_ready}" == true \
    && "${resource_usage_captured}" == true \
    && "${smoke_passed}" == true \
    && "${smoke_logical_requests}" -gt 0 \
    && "${smoke_logical_requests}" -eq "${smoke_physical_attempts}" \
    && "${smoke_retry_attempts}" -eq 0 \
    && "${helm_release_removed}" == true \
    && "${namespace_or_owned_resources_removed}" == true \
    && "${cluster_removed}" == true \
    && "${remaining_containers}" -eq 0 \
    && "${remaining_networks}" -eq 0 \
    && "${remaining_port_forwards}" -eq 0 \
    && "${temporary_kubeconfig_removed}" == true \
    && "${original_context_unchanged}" == true ]]; then
    passed=true
  fi
  contract_passed="${passed}"
  cat >"${result_dir}/contract.json" <<EOF
{
  "passed": ${passed},
  "cluster_created": ${cluster_created},
  "node_ready": ${node_ready},
  "image_imported": ${image_imported},
  "helm_release_deployed": ${helm_release_deployed},
  "deployment_available": ${deployment_available},
  "initial_pod_ready": ${initial_pod_ready},
  "pod_replaced": ${pod_replaced},
  "replacement_pod_ready": ${replacement_pod_ready},
  "pod_uid_changed": ${pod_uid_changed},
  "service_backend_ready": ${service_backend_ready},
  "resource_usage_captured": ${resource_usage_captured},
  "smoke_passed": ${smoke_passed},
  "smoke_logical_requests": ${smoke_logical_requests},
  "smoke_physical_attempts": ${smoke_physical_attempts},
  "smoke_retry_attempts": ${smoke_retry_attempts},
  "helm_release_removed": ${helm_release_removed},
  "namespace_or_owned_resources_removed": ${namespace_or_owned_resources_removed},
  "cluster_removed": ${cluster_removed},
  "remaining_cluster_containers": ${remaining_containers},
  "remaining_cluster_networks": ${remaining_networks},
  "remaining_port_forwards": ${remaining_port_forwards},
  "temporary_kubeconfig_removed": ${temporary_kubeconfig_removed},
  "original_context_unchanged": ${original_context_unchanged}
}
EOF
}

write_summary() {
  local node_usage="not captured"
  local pod_usage="not captured"
  if [[ -s "${result_dir}/top-nodes.txt" ]]; then
    node_usage="$(awk 'NR == 2 {printf "%s CPU, %s memory", $2, $4}' "${result_dir}/top-nodes.txt")"
  fi
  if [[ -s "${result_dir}/top-pods.txt" ]]; then
    pod_usage="$(awk 'NR == 2 {printf "%s CPU, %s memory", $2, $3}' "${result_dir}/top-pods.txt")"
  fi
  cat >"${result_dir}/summary.md" <<EOF
# L03 k3d and Helm baseline summary

> 이 실행은 단일 local exploratory evidence이며 performance benchmark나 production sizing 근거가 아니다.

| Observation | Result |
| --- | --- |
| Contract | ${contract_passed} |
| Node Ready | ${node_ready} |
| Deployment Available | ${deployment_available} |
| Initial Pod | ${initial_pod_name} / ${initial_pod_uid} / ready=${initial_pod_ready} |
| Replacement Pod | ${replacement_pod_name} / ${replacement_pod_uid} / ready=${replacement_pod_ready} |
| Pod UID changed | ${pod_uid_changed} |
| Service backend ready after replacement | ${service_backend_ready} |
| Node usage snapshot | ${node_usage} |
| Pod usage snapshot | ${pod_usage} |
| L00 smoke logical / physical / retry | ${smoke_logical_requests} / ${smoke_physical_attempts} / ${smoke_retry_attempts} |
| Helm release removed | ${helm_release_removed} |
| Namespace removed | ${namespace_or_owned_resources_removed} |
| Cluster removed | ${cluster_removed} |
| Remaining cluster containers / networks | ${remaining_containers} / ${remaining_networks} |
| Remaining tracked port-forwards | ${remaining_port_forwards} |
| Temporary kubeconfig removed | ${temporary_kubeconfig_removed} |
| Original kube context unchanged | ${original_context_unchanged} |

## Interpretation boundary

- k3d/K3s topology, Helm resources, requests/limits와 port-forward access model은 모두 \`LAB_IMPLEMENTATION\`이다.
- \`kubectl top\` 값은 Metrics API의 단일 시점 local snapshot이며 historical monitoring, benchmark, production sizing이 아니다.
- Public path는 host의 loopback-only port-forward를 사용하므로 production ingress 또는 external network path를 검증하지 않는다.
- Restart observation은 container crash restart count가 아니라 Deployment-driven Pod replacement다.
EOF
}

cleanup() {
  local original_exit=$?
  local cleanup_failed=false
  local api_available=false
  local after_context
  trap - EXIT
  set +e

  stop_port_forward "${public_pf_pid}"
  stop_port_forward "${admin_pf_pid}"
  remaining_port_forwards=0
  if [[ -n "${public_pf_pid}" ]] && kill -0 "${public_pf_pid}" 2>/dev/null; then
    remaining_port_forwards=$((remaining_port_forwards + 1))
  fi
  if [[ -n "${admin_pf_pid}" ]] && kill -0 "${admin_pf_pid}" 2>/dev/null; then
    remaining_port_forwards=$((remaining_port_forwards + 1))
  fi

  if cluster_exists && [[ -s "${kubeconfig_file}" ]] \
    && kubectl --kubeconfig "${kubeconfig_file}" get namespace >/dev/null 2>&1; then
    api_available=true
  fi

  if [[ "${api_available}" == true ]]; then
    helm --kubeconfig "${kubeconfig_file}" --namespace "${NAMESPACE}" list --all \
      >"${result_dir}/helm-list-before-uninstall.txt" 2>&1
    if helm --kubeconfig "${kubeconfig_file}" --namespace "${NAMESPACE}" status "${RELEASE}" >/dev/null 2>&1; then
      if helm --kubeconfig "${kubeconfig_file}" --namespace "${NAMESPACE}" uninstall "${RELEASE}" \
        >"${result_dir}/helm-uninstall.log" 2>&1; then
        if ! helm --kubeconfig "${kubeconfig_file}" --namespace "${NAMESPACE}" status "${RELEASE}" >/dev/null 2>&1; then
          helm_release_removed=true
        fi
      fi
    elif [[ "${helm_release_deployed}" == false ]]; then
      printf 'release was not deployed before cleanup\n' >"${result_dir}/helm-uninstall.log"
    fi
    helm --kubeconfig "${kubeconfig_file}" --namespace "${NAMESPACE}" list --all \
      >"${result_dir}/helm-list-after-uninstall.txt" 2>&1

    if kubectl --kubeconfig "${kubeconfig_file}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
      kubectl --kubeconfig "${kubeconfig_file}" delete namespace "${NAMESPACE}" \
        --wait=true --timeout=120s >"${result_dir}/namespace-delete.log" 2>&1
    fi
    if ! kubectl --kubeconfig "${kubeconfig_file}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
      namespace_or_owned_resources_removed=true
    fi
  fi

  if cluster_exists; then
    k3d cluster delete "${CLUSTER_NAME}" >"${result_dir}/cluster-delete.log" 2>&1
  fi
  if ! cluster_exists && [[ "${cluster_created}" == true ]]; then
    cluster_removed=true
  fi

  remaining_containers="$(remaining_cluster_containers)"
  remaining_networks="$(remaining_cluster_networks)"

  rm -f "${kubeconfig_file}"
  rmdir "${kubeconfig_dir}" 2>/dev/null
  if [[ ! -e "${kubeconfig_file}" && ! -d "${kubeconfig_dir}" ]]; then
    temporary_kubeconfig_removed=true
  fi

  after_context="$(read_original_context)"
  if [[ "${after_context}" == "${original_context}" ]]; then
    original_context_unchanged=true
  fi

  if [[ "${remaining_port_forwards}" -ne 0 \
    || "${remaining_containers}" -ne 0 \
    || "${remaining_networks}" -ne 0 \
    || "${temporary_kubeconfig_removed}" != true \
    || "${original_context_unchanged}" != true ]]; then
    cleanup_failed=true
  fi
  if [[ "${cluster_created}" == true \
    && ( "${helm_release_removed}" != true \
      || "${namespace_or_owned_resources_removed}" != true \
      || "${cluster_removed}" != true ) ]]; then
    cleanup_failed=true
  fi

  cat >"${result_dir}/cleanup.json" <<EOF
{
  "runner_exit_before_cleanup": ${original_exit},
  "helm_release_removed": ${helm_release_removed},
  "namespace_or_owned_resources_removed": ${namespace_or_owned_resources_removed},
  "cluster_removed": ${cluster_removed},
  "remaining_cluster_containers": ${remaining_containers},
  "remaining_cluster_networks": ${remaining_networks},
  "remaining_port_forwards": ${remaining_port_forwards},
  "temporary_kubeconfig_removed": ${temporary_kubeconfig_removed},
  "original_context_unchanged": ${original_context_unchanged}
}
EOF
  write_metadata
  write_contract
  write_summary
  printf 'Result: %s\n' "${result_dir}"

  if [[ "${original_exit}" -eq 0 && "${contract_passed}" != true ]]; then
    exit 1
  fi
  if [[ "${original_exit}" -eq 0 && "${cleanup_failed}" == true ]]; then
    exit 1
  fi
  exit "${original_exit}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'L03 result directory: %s\n' "${result_dir}"

# Chart에는 Secret object나 credential을 넣지 않고 구조만 먼저 검증한다.
helm lint "${CHART_DIR}" \
  --set-string image.repository="${IMAGE_REPOSITORY}" \
  --set-string image.tag="${IMAGE_TAG}" >"${result_dir}/helm-lint.log"
helm template "${RELEASE}" "${CHART_DIR}" --namespace "${NAMESPACE}" \
  --set-string image.repository="${IMAGE_REPOSITORY}" \
  --set-string image.tag="${IMAGE_TAG}" >"${result_dir}/helm-template.yaml"

docker build --tag "${AUTH_SIM_IMAGE_VALUE}" . >"${result_dir}/docker-build.log" 2>&1
image_built=true
image_id="$(docker image inspect "${AUTH_SIM_IMAGE_VALUE}" --format '{{.Id}}')"

k3d cluster create "${CLUSTER_NAME}" \
  --servers 1 \
  --agents 0 \
  --image "${K3S_IMAGE}" \
  --api-port 127.0.0.1:0 \
  --kubeconfig-update-default=false \
  --kubeconfig-switch-context=false \
  --k3s-arg '--disable=traefik@server:0' \
  --k3s-arg '--disable=servicelb@server:0' \
  --k3s-arg '--disable=local-storage@server:0' \
  --wait \
  --timeout 120s >"${result_dir}/cluster-create.log" 2>&1
cluster_created=true

k3d kubeconfig get "${CLUSTER_NAME}" >"${kubeconfig_file}"
chmod 600 "${kubeconfig_file}"
# k3d v5.9.0은 host port 0을 Docker에 동적 publish하지만 kubeconfig에는 0을 남긴다.
# 실제 loopback binding만 읽어 실행별 임시 kubeconfig의 server port를 교정한다.
api_binding="$(docker port "k3d-${CLUSTER_NAME}-serverlb" 6443/tcp \
  | awk '$1 ~ /^127\.0\.0\.1:[0-9]+$/ {print; exit}')"
api_port="${api_binding##*:}"
if [[ ! "${api_port}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'failed to resolve the dynamic loopback Kubernetes API port\n' >&2
  exit 1
fi
sed -i "s#server: https://127.0.0.1:0#server: https://127.0.0.1:${api_port}#" "${kubeconfig_file}"
if grep -q 'server: https://127.0.0.1:0' "${kubeconfig_file}"; then
  printf 'temporary kubeconfig still contains unresolved API port 0\n' >&2
  exit 1
fi

kubectl wait --for=condition=Ready nodes --all --timeout=120s >"${result_dir}/node-ready.log"
node_ready=true
kubectl version --output=json >"${result_dir}/kubernetes-version.json"
server_version="$(awk '/"gitVersion"/ {count++; if (count == 2) {gsub(/[",]/, "", $2); print $2; exit}}' "${result_dir}/kubernetes-version.json")"
kubectl get nodes -o wide >"${result_dir}/nodes.txt"
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY_CPU:.status.capacity.cpu,CAPACITY_MEMORY:.status.capacity.memory,ALLOCATABLE_CPU:.status.allocatable.cpu,ALLOCATABLE_MEMORY:.status.allocatable.memory' \
  >"${result_dir}/node-capacity-allocatable.txt"

k3d image import "${AUTH_SIM_IMAGE_VALUE}" --cluster "${CLUSTER_NAME}" \
  >"${result_dir}/image-import.log" 2>&1
image_imported=true

kubectl create namespace "${NAMESPACE}" >"${result_dir}/namespace-create.log"
namespace_created=true
# Credential은 stdin으로만 Secret API에 전달하고 manifest나 command argument로 남기지 않는다.
printf '%s' "${admin_token}" \
  | kubectl create secret generic "${ADMIN_SECRET}" --namespace "${NAMESPACE}" \
      --from-file=token=/dev/stdin >"${result_dir}/secret-create.log"

helm upgrade --install "${RELEASE}" "${CHART_DIR}" \
  --namespace "${NAMESPACE}" \
  --set-string image.repository="${IMAGE_REPOSITORY}" \
  --set-string image.tag="${IMAGE_TAG}" \
  --set-string adminSecret.name="${ADMIN_SECRET}" \
  --set-string adminSecret.key=token \
  --wait \
  --timeout 120s >"${result_dir}/helm-upgrade-install.log" 2>&1
helm status "${RELEASE}" --namespace "${NAMESPACE}" --output json >"${result_dir}/helm-status.json"
if grep -Eq '"status"[[:space:]]*:[[:space:]]*"deployed"' "${result_dir}/helm-status.json"; then
  helm_release_deployed=true
fi
if [[ "${helm_release_deployed}" != true ]]; then
  printf 'Helm release did not reach deployed status\n' >&2
  exit 1
fi

kubectl rollout status deployment/"${RELEASE}" --namespace "${NAMESPACE}" --timeout=120s \
  >"${result_dir}/rollout-initial.log"
if [[ "$(kubectl get deployment "${RELEASE}" --namespace "${NAMESPACE}" -o jsonpath='{.status.availableReplicas}')" == "1" ]]; then
  deployment_available=true
fi

initial_pod_name="$(kubectl get pods --namespace "${NAMESPACE}" \
  --selector "app.kubernetes.io/instance=${RELEASE}" \
  -o jsonpath='{.items[0].metadata.name}')"
initial_pod_uid="$(kubectl get pod "${initial_pod_name}" --namespace "${NAMESPACE}" \
  -o jsonpath='{.metadata.uid}')"
if [[ "$(kubectl get pod "${initial_pod_name}" --namespace "${NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == "True" ]]; then
  initial_pod_ready=true
fi
printf '{"name":"%s","uid":"%s","ready":%s}\n' \
  "${initial_pod_name}" "${initial_pod_uid}" "${initial_pod_ready}" >"${result_dir}/initial-pod.json"

kubectl get deployment,replicaset,pod,service --namespace "${NAMESPACE}" -o wide \
  >"${result_dir}/workload-initial.txt"
kubectl get service "${RELEASE}" --namespace "${NAMESPACE}" -o yaml \
  >"${result_dir}/service.yaml"
kubectl get endpointslice --namespace "${NAMESPACE}" \
  --selector "kubernetes.io/service-name=${RELEASE}" -o yaml \
  >"${result_dir}/endpointslices-initial.yaml"
kubectl get pod "${initial_pod_name}" --namespace "${NAMESPACE}" \
  -o custom-columns='NAME:.metadata.name,CPU_REQUEST:.spec.containers[0].resources.requests.cpu,MEMORY_REQUEST:.spec.containers[0].resources.requests.memory,CPU_LIMIT:.spec.containers[0].resources.limits.cpu,MEMORY_LIMIT:.spec.containers[0].resources.limits.memory' \
  >"${result_dir}/pod-resources.txt"

# K3s packaged metrics-server가 bounded wait 안에 실제 snapshot을 제공해야 완료로 판정한다.
metrics_ready=false
for _ in {1..60}; do
  if kubectl top node >"${result_dir}/top-nodes.txt" 2>"${result_dir}/metrics-last-error.log" \
    && kubectl top pod --namespace "${NAMESPACE}" >"${result_dir}/top-pods.txt" 2>>"${result_dir}/metrics-last-error.log"; then
    metrics_ready=true
    break
  fi
  sleep 2
done
kubectl get apiservice v1beta1.metrics.k8s.io -o yaml >"${result_dir}/metrics-api.yaml"
if [[ "${metrics_ready}" != true ]]; then
  printf 'Metrics API did not produce node and Pod usage within the bounded wait\n' >&2
  exit 1
fi
resource_usage_captured=true

# 이 단계는 crash restart count가 아니라 Deployment가 관리하는 Pod 교체를 관찰한다.
kubectl rollout restart deployment/"${RELEASE}" --namespace "${NAMESPACE}" \
  >"${result_dir}/rollout-restart-command.log"
kubectl rollout status deployment/"${RELEASE}" --namespace "${NAMESPACE}" --timeout=120s \
  >"${result_dir}/rollout-replacement.log"

for _ in {1..60}; do
  replacement_line="$(kubectl get pods --namespace "${NAMESPACE}" \
    --selector "app.kubernetes.io/instance=${RELEASE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.uid}{"\t"}{.status.phase}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
    | awk -F '\t' -v old_uid="${initial_pod_uid}" '$2 != old_uid && $3 == "Running" && $4 == "True" {print $1 "\t" $2; exit}')"
  if [[ -n "${replacement_line}" ]]; then
    replacement_pod_name="${replacement_line%%$'\t'*}"
    replacement_pod_uid="${replacement_line#*$'\t'}"
    break
  fi
  sleep 1
done
if [[ "${replacement_pod_name}" == "not-captured" ]]; then
  printf 'replacement Pod did not become Ready\n' >&2
  exit 1
fi
replacement_pod_ready=true
pod_replaced=true
if [[ "${replacement_pod_uid}" != "${initial_pod_uid}" ]]; then pod_uid_changed=true; fi
printf '{"name":"%s","uid":"%s","ready":%s}\n' \
  "${replacement_pod_name}" "${replacement_pod_uid}" "${replacement_pod_ready}" \
  >"${result_dir}/replacement-pod.json"

kubectl get deployment,replicaset,pod,service --namespace "${NAMESPACE}" -o wide \
  >"${result_dir}/workload-after-replacement.txt"
kubectl get endpointslice --namespace "${NAMESPACE}" \
  --selector "kubernetes.io/service-name=${RELEASE}" -o yaml \
  >"${result_dir}/endpointslices-after-replacement.yaml"
endpoint_uid="$(kubectl get endpointslice --namespace "${NAMESPACE}" \
  --selector "kubernetes.io/service-name=${RELEASE}" \
  -o jsonpath='{.items[0].endpoints[0].targetRef.uid}')"
endpoint_ready="$(kubectl get endpointslice --namespace "${NAMESPACE}" \
  --selector "kubernetes.io/service-name=${RELEASE}" \
  -o jsonpath='{.items[0].endpoints[0].conditions.ready}')"
if [[ "${endpoint_uid}" == "${replacement_pod_uid}" && "${endpoint_ready}" == "true" ]]; then
  service_backend_ready=true
fi
if [[ "${service_backend_ready}" != true ]]; then
  printf 'Service EndpointSlice does not reference the Ready replacement Pod\n' >&2
  exit 1
fi

# Public와 admin은 별도 process와 dynamic loopback port를 사용한다.
kubectl port-forward --namespace "${NAMESPACE}" --address 127.0.0.1 \
  service/"${RELEASE}" :8080 >"${result_dir}/port-forward-public.log" 2>&1 &
public_pf_pid=$!
kubectl port-forward --namespace "${NAMESPACE}" --address 127.0.0.1 \
  deployment/"${RELEASE}" :9090 >"${result_dir}/port-forward-admin.log" 2>&1 &
admin_pf_pid=$!

for _ in {1..50}; do
  public_port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) ->.*/\1/p' \
    "${result_dir}/port-forward-public.log" | head -n 1)"
  admin_port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) ->.*/\1/p' \
    "${result_dir}/port-forward-admin.log" | head -n 1)"
  if [[ -n "${public_port}" && -n "${admin_port}" ]]; then break; fi
  if ! kill -0 "${public_pf_pid}" 2>/dev/null || ! kill -0 "${admin_pf_pid}" 2>/dev/null; then break; fi
  sleep 0.1
done
if [[ -z "${public_port}" || -z "${admin_port}" ]]; then
  printf 'loopback port-forward did not become ready\n' >&2
  exit 1
fi
for _ in {1..50}; do
  if curl --fail --silent --show-error "http://127.0.0.1:${public_port}/readyz" >/dev/null 2>&1 \
    && curl --fail --silent --show-error "http://127.0.0.1:${admin_port}/admin/fault" >/dev/null 2>&1; then
    port_forward_ready=true
    break
  fi
  sleep 0.1
done
if [[ "${port_forward_ready:-false}" != true ]]; then
  printf 'forwarded public/admin HTTP paths did not become ready\n' >&2
  exit 1
fi

set +e
BASE_URL="http://127.0.0.1:${public_port}" \
ADMIN_URL="http://127.0.0.1:${admin_port}" \
LAB_ADMIN_TOKEN="${admin_token}" \
RESULT_DIR="${result_dir}/smoke" \
STARTED_AT_UTC="${started_at_utc}" \
GIT_COMMIT="${SOURCE_COMMIT}" \
GIT_DIRTY="${git_dirty}" \
GO_VERSION="$(go version)" \
K6_VERSION="$(k6 version | head -n 1)" \
DOCKER_VERSION="${docker_version}" \
LEARNING_UNIT=L03 \
REQUEST_PATH='host k6 -> loopback kubectl port-forward -> ClusterIP Service -> auth-sim Pod' \
AUTH_SIM_IMAGE="${AUTH_SIM_IMAGE_VALUE}" \
LAB_OS="$(uname -s)" \
LAB_ARCH="$(uname -m)" \
  k6 run load/k6/smoke.js >"${result_dir}/smoke/k6.log" 2>&1
smoke_exit=$?
set -e

if [[ -s "${result_dir}/smoke/k6-summary.json" ]]; then
  smoke_logical_requests="$(metric_value "${result_dir}/smoke/k6-summary.json" logical_requests count)"
  smoke_physical_attempts="$(metric_value "${result_dir}/smoke/k6-summary.json" physical_attempts count)"
  smoke_retry_attempts="$(metric_value "${result_dir}/smoke/k6-summary.json" retry_attempts count)"
  smoke_logical_requests="${smoke_logical_requests:-0}"
  smoke_physical_attempts="${smoke_physical_attempts:-0}"
  smoke_retry_attempts="${smoke_retry_attempts:-0}"
fi
if [[ "${smoke_exit}" -eq 0 \
  && "${smoke_logical_requests}" -gt 0 \
  && "${smoke_logical_requests}" -eq "${smoke_physical_attempts}" \
  && "${smoke_retry_attempts}" -eq 0 ]]; then
  smoke_passed=true
fi
if [[ "${smoke_passed}" != true ]]; then
  printf 'L00 smoke contract failed: exit=%s logical=%s physical=%s retry=%s\n' \
    "${smoke_exit}" "${smoke_logical_requests}" "${smoke_physical_attempts}" "${smoke_retry_attempts}" >&2
  exit 1
fi

exit 0
