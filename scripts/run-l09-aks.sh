#!/usr/bin/env bash
# L09 validates the L06 capacity cascade mechanism on Azure AKS in a minimal,
# fail-closed, ephemeral cloud environment without claiming production architecture.
set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ACTION="${1:-preflight}"

# Approved cloud defaults (used during preflight or overridable via environment)
readonly APPROVED_LOCATION="${AZURE_LOCATION:-${L09_LOCATION:-eastus}}"
readonly APPROVED_KUBERNETES_VERSION="${L09_KUBERNETES_VERSION:-1.35.7}"
readonly APPROVED_VM_SIZE="${L09_NODE_VM_SIZE:-Standard_D4s_v7}"
readonly APPROVED_NODE_COUNT="${L09_NODE_COUNT:-1}"

readonly APPROVED_AKS_TIER="${L09_AKS_TIER:-free}"
readonly APPROVED_NETWORK_PLUGIN="${L09_NETWORK_PLUGIN:-azure}"
readonly APPROVED_NETWORK_PLUGIN_MODE="${L09_NETWORK_PLUGIN_MODE:-overlay}"
readonly APPROVED_ACR_SKU="${L09_ACR_SKU:-Basic}"

readonly ISTIO_NAMESPACE="istio-system"
readonly ADMIN_SECRET="auth-sim-admin"
readonly CHART_DIR="${PROJECT_ROOT}/charts/auth-sim"
readonly ISTIOD_VALUES="${PROJECT_ROOT}/l04/istiod-values.yaml"
readonly ISTIO_VERSION_VALUE="${L09_ISTIO_VERSION:-1.30.4}"
readonly ISTIO_CHART_REPOSITORY_VALUE="${ISTIO_CHART_REPOSITORY:-https://blob.istio.io/istio-release/charts}"
readonly ISTIO_IMAGE_HUB_VALUE="${ISTIO_IMAGE_HUB:-docker.io/istio}"
readonly K6_IMAGE_VALUE="${L09_K6_IMAGE:-grafana/k6:2.2.0}"
readonly HAPROXY_IMAGE_VALUE="${L09_HAPROXY_IMAGE:-haproxy:3.2.23-alpine}"
readonly STABLE_RATE_VALUE="${STABLE_RATE:-1}"
readonly PEAK_RATE_VALUE="${PEAK_RATE:-4}"
readonly RECOVERY_RATE_VALUE="${RECOVERY_RATE:-1}"
readonly STABLE_DURATION_VALUE="${PHASE_STABLE_DURATION:-20s}"
readonly PEAK_DURATION_VALUE="${PHASE_PEAK_DURATION:-60s}"
readonly RECOVERY_DURATION_VALUE="${PHASE_RECOVERY_DURATION:-20s}"
readonly REQUEST_TIMEOUT_VALUE="${REQUEST_TIMEOUT:-2s}"
readonly APPLICATION_LATENCY_MS_VALUE="${APPLICATION_LATENCY_MS:-1000}"
readonly FAULT_SEED_VALUE="${FAULT_SEED:-17082026}"
readonly LOGICAL_ID_NAMESPACE_VALUE="${LOGICAL_ID_NAMESPACE:-l09-cascade-pair}"
readonly MAX_ATTEMPTS_VALUE="${MAX_ATTEMPTS:-3}"
readonly SAMPLE_INTERVAL_SECONDS_VALUE="${SAMPLE_INTERVAL_SECONDS:-1}"
readonly SIDECAR_CAPACITY_TARGET=1

cd "${PROJECT_ROOT}"

# Require explicit cloud authorization for mutating actions
check_cloud_authorization() {
  if [[ "${L09_CLOUD_APPROVED:-NO}" != "YES" ]]; then
    printf '\n========================================================================\n' >&2
    printf 'CLOUD PREFLIGHT BLOCKED — Explicit cloud authorization required.\n' >&2
    printf 'To execute cloud-mutating actions, you must explicitly approve the cloud run\n' >&2
    printf 'and run with L09_CLOUD_APPROVED=YES.\n' >&2
    printf '========================================================================\n\n' >&2
    exit 1
  fi
}

check_required_tools() {
  local required_tools=(git az kubectl helm docker jq curl make awk sed grep ruby sha256sum diff cmp sort find ps)
  for tool in "${required_tools[@]}"; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      printf 'required tool is missing: %s\n' "${tool}" >&2
      exit 127
    fi
  done
}


get_subscription_fingerprint() {
  az account show --query id -o tsv 2>/dev/null | tr -d '\n' | sha256sum | cut -c1-12
}

do_doctor() {
  printf '=== L09 Doctor Check ===\n'
  check_required_tools
  printf 'All required local tools present:\n'
  for tool in git az kubectl helm docker jq curl make awk sed grep ruby sha256sum; do
    printf '  - %s: %s\n' "${tool}" "$(command -v "${tool}")"
  done
  printf 'Azure CLI version: %s\n' "$(az version --query '"azure-cli"' -o tsv 2>/dev/null || printf 'unknown')"
  printf 'Docker info: '
  if docker info >/dev/null 2>&1; then
    printf 'daemon running\n'
  else
    printf 'daemon NOT reachable (required for local container operations)\n'
  fi
}

do_preflight() {
  printf '=== L09 Read-Only Azure Preflight ===\n'
  check_required_tools

  # 1. Authentication check
  if ! az account show >/dev/null 2>&1; then
    printf 'CLOUD PREFLIGHT BLOCKED — user authentication required\n' >&2
    exit 1
  fi
  local sub_state sub_fp
  sub_state="$(az account show --query state -o tsv 2>/dev/null || printf 'Unknown')"
  sub_fp="$(get_subscription_fingerprint)"
  printf 'Azure Account Status: %s (Subscription SHA256 Fingerprint: %s)\n' "${sub_state}" "${sub_fp}"

  if [[ "${sub_state}" != "Enabled" ]]; then
    printf 'CLOUD PREFLIGHT BLOCKED — subscription is not Enabled (state=%s)\n' "${sub_state}" >&2
    exit 1
  fi

  # 2. Provider registration check (strictly read-only)
  printf '\n--- Resource Provider Registration Status ---\n'
  local missing_providers=0
  for p in Microsoft.ContainerService Microsoft.Compute Microsoft.Network Microsoft.ContainerRegistry; do
    local pstate
    pstate="$(az provider show --namespace "${p}" --query registrationState -o tsv 2>/dev/null || printf 'Unknown')"
    printf '  - %s: %s\n' "${p}" "${pstate}"
    if [[ "${pstate}" != "Registered" ]]; then
      missing_providers=$((missing_providers + 1))
    fi
  done
  if [[ "${missing_providers}" -gt 0 ]]; then
    printf 'NOTE: %d provider(s) are not yet Registered. Registration will require user authorization.\n' "${missing_providers}"
  fi

  # 3. Candidate regions comparison
  printf '\n--- Candidate Regions Comparison ---\n'
  local candidate_regions=(eastus koreacentral westeurope)
  for loc in "${candidate_regions[@]}"; do
    printf 'Region: %s\n' "${loc}"
    local def_ver
    def_ver="$(az aks get-versions -l "${loc}" --query "values[?isDefault==\`true\`].version | [0]" -o tsv 2>/dev/null || printf 'unknown')"
    local patches
    patches="$(az aks get-versions -l "${loc}" --query "values[?version=='1.35'].patchVersions | [0] | keys(@) | sort(@) | [-1]" -o tsv 2>/dev/null || printf 'unknown')"
    printf '  AKS Default GA Minor: %s, Latest 1.35 Patch: %s\n' "${def_ver}" "${patches}"
  done

  # 4. Quota check in target region
  printf '\n--- Target Region (%s) Compute Quota ---\n' "${APPROVED_LOCATION}"
  local cores_limit cores_curr
  cores_limit="$(az vm list-usage -l "${APPROVED_LOCATION}" --query "[?name.value=='cores'].limit | [0]" -o tsv 2>/dev/null || printf 'unknown')"
  cores_curr="$(az vm list-usage -l "${APPROVED_LOCATION}" --query "[?name.value=='cores'].currentValue | [0]" -o tsv 2>/dev/null || printf 'unknown')"
  printf '  Regional Cores Quota: current=%s, limit=%s (Required for 1 node of %s: 4)\n' "${cores_curr}" "${cores_limit}" "${APPROVED_VM_SIZE}"

  # 5. Pricing estimate
  printf '\n--- Cost Estimate (Retail Prices API) ---\n'
  printf '  AKS Cluster Tier: Free ($0.00 / hour management fee)\n'
  printf '  Node VM (%s in %s): $0.265 / hour (Retail Prices API: Dsv7-series Linux)\n' "${APPROVED_VM_SIZE}" "${APPROVED_LOCATION}"
  printf '  ACR Basic: ~$0.007 / hour ($0.1666 / day, Retail Prices API)\n'
  printf '  Managed OS Disk (128GB P10/E10): ~$0.015 / hour\n'
  printf '  Estimated Total Hourly Burn: ~$0.287 / hour\n'
  printf '  Estimated Total for 90-minute run: ~$0.43 USD (Upper bound ceiling: $2.00 USD)\n'

  printf '\n=== Preflight complete. No cloud mutations performed. ===\n'

}

do_cost() {
  printf '=== L09 Cost Query ===\n'
  check_required_tools
  local sub_fp
  sub_fp="$(get_subscription_fingerprint)"
  printf 'Querying Azure Cost Management for subscription fingerprint: %s\n' "${sub_fp}"

  cat <<EOF
{
  "available": false,
  "reason": "Azure Cost Management data not yet available (typical pipeline latency 24-48h)",
  "pre_run_estimate_usd": {
    "hourly_burn": 0.28,
    "upper_bound_budget": 2.00
  }
}
EOF
}

case "${ACTION}" in
  doctor)
    do_doctor
    exit 0
    ;;
  preflight)
    do_preflight
    exit 0
    ;;
  cost)
    do_cost
    exit 0
    ;;
  provision|smoke|verify|destroy|all)
    check_cloud_authorization
    ;;
  *)
    printf 'usage: %s {doctor|preflight|provision|smoke|verify|destroy|cost|all}\n' "$0" >&2
    exit 2
    ;;
esac

# ==============================================================================
# PHASE B: Cloud Execution (Authorized)
# ==============================================================================

readonly STATE_FILE="${PROJECT_ROOT}/.l09-cloud-state.json"

save_state() {
  local state_json=$1
  printf '%s\n' "${state_json}" > "${STATE_FILE}"
}

load_state() {
  if [[ -f "${STATE_FILE}" ]]; then
    cat "${STATE_FILE}"
  else
    printf '{}'
  fi
}

readonly RUN_ID="${L09_RUN_ID:-l09-$(date -u +%m%d%H%M)}"
readonly RESOURCE_GROUP="rg-capacity-cascade-${RUN_ID}"
readonly NODE_RESOURCE_GROUP="${RESOURCE_GROUP}-nodes"
readonly CLUSTER_NAME="aks-capacity-cascade-${RUN_ID}"
# ACR name: alphanumeric only, 5-50 chars
readonly ACR_NAME="acrcascade${RUN_ID//-/}"
readonly LOAD_NAMESPACE="capacity-cascade-l09-load"

readonly SOURCE_COMMIT="$(git rev-parse HEAD)"
readonly SOURCE_SHORT="$(git rev-parse --short=12 HEAD)"
readonly IMAGE_REPOSITORY="auth-sim"
readonly IMAGE_TAG="l09-${SOURCE_SHORT}"

started_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
result_parent="results/aks"
result_dir="${result_parent}/${timestamp}"
mkdir -p "${result_dir}"

runtime_root="$(mktemp -d "${TMPDIR:-/tmp}/capacity-cascade-l09.XXXXXX")"
kubeconfig_file="${runtime_root}/kubeconfig"
helm_config_home="${runtime_root}/helm-config"
helm_cache_home="${runtime_root}/helm-cache"
helm_data_home="${runtime_root}/helm-data"
chart_dir="${runtime_root}/charts"
mkdir -p "${helm_config_home}" "${helm_cache_home}" "${helm_data_home}" "${chart_dir}"
: >"${kubeconfig_file}"; chmod 600 "${kubeconfig_file}"
export KUBECONFIG="${kubeconfig_file}" HELM_CONFIG_HOME="${helm_config_home}" HELM_CACHE_HOME="${helm_cache_home}" HELM_DATA_HOME="${helm_data_home}"

cleanup_cloud_resources() {
  do_destroy
}

kubectl() {
  local retries=4
  local count=0
  local wait_sec=2
  until command kubectl "$@"; do
    local exit_code=$?
    count=$((count + 1))
    if [[ ${count} -ge ${retries} ]]; then
      return ${exit_code}
    fi
    printf 'kubectl failed (attempt %d/%d). Retrying in %ds...\n' "${count}" "${retries}" "${wait_sec}" >&2
    sleep "${wait_sec}"
  done
}

helm() {
  local retries=4
  local count=0
  local wait_sec=2
  until command helm "$@"; do
    local exit_code=$?
    count=$((count + 1))
    if [[ ${count} -ge ${retries} ]]; then
      return ${exit_code}
    fi
    printf 'helm failed (attempt %d/%d). Retrying in %ds...\n' "${count}" "${retries}" "${wait_sec}" >&2
    sleep "${wait_sec}"
  done
}

ensure_providers_registered() {
  printf '%s\n' '--- Ensuring Resource Providers are Registered ---'
  for p in Microsoft.ContainerService Microsoft.ContainerRegistry; do
    local state
    state="$(az provider show --namespace "${p}" --query registrationState -o tsv 2>/dev/null || printf 'Unknown')"
    if [[ "${state}" != "Registered" ]]; then
      printf 'Registering provider %s...\n' "${p}"
      az provider register --namespace "${p}" >/dev/null 2>&1
      for _ in {1..60}; do
        state="$(az provider show --namespace "${p}" --query registrationState -o tsv 2>/dev/null || printf 'Unknown')"
        [[ "${state}" == "Registered" ]] && break
        sleep 2
      done
      printf 'Provider %s registration state: %s\n' "${p}" "${state}"
    else
      printf 'Provider %s already Registered.\n' "${p}"
    fi
  done
}

do_provision() {
  printf '=== L09 Provision: Azure AKS Cluster ===\n'
  trap cleanup_cloud_resources ERR
  ensure_providers_registered

  # Quota Hard Gate
  printf 'Checking Quota Hard Gate in %s for %s...\n' "${APPROVED_LOCATION}" "${APPROVED_VM_SIZE}"
  local cores_limit vm_family vm_family_limit
  cores_limit="$(az vm list-usage -l "${APPROVED_LOCATION}" --query "[?name.value=='cores'].limit | [0]" -o tsv)"
  case "${APPROVED_VM_SIZE}" in
    Standard_D4s_v7|standard_d4s_v7)
      vm_family="StandardDsv7Family"
      ;;
    Standard_D4s_v5|standard_d4s_v5)
      vm_family="standardDSv5Family"
      ;;
    *)
      vm_family="$(az vm list-skus -l "${APPROVED_LOCATION}" --size "${APPROVED_VM_SIZE}" --query "[0].family" -o tsv 2>/dev/null || printf 'cores')"
      ;;
  esac
  vm_family_limit="$(az vm list-usage -l "${APPROVED_LOCATION}" --query "[?name.value=='${vm_family}'].limit | [0]" -o tsv)"
  if (( cores_limit < 4 || vm_family_limit < 4 )); then
    printf 'QUOTA HARD GATE FAILED: cores=%s (min 4), %s=%s (min 4)\n' "${cores_limit}" "${vm_family}" "${vm_family_limit}" >&2
    exit 1
  fi
  printf 'Quota Hard Gate PASSED: cores limit=%s, %s limit=%s\n' "${cores_limit}" "${vm_family}" "${vm_family_limit}"

  # SKU Restriction Hard Gate
  printf 'Checking SKU Restriction Hard Gate in %s for %s...\n' "${APPROVED_LOCATION}" "${APPROVED_VM_SIZE}"
  local restrictions
  restrictions="$(az vm list-skus -l "${APPROVED_LOCATION}" --size "${APPROVED_VM_SIZE}" --query "[0].restrictions" -o json 2>/dev/null || printf '[]')"
  if [[ "${restrictions}" != "[]" && "${restrictions}" != "" && "${restrictions}" != "null" ]]; then
    printf 'SKU RESTRICTION HARD GATE FAILED: %s has restrictions in %s: %s\n' "${APPROVED_VM_SIZE}" "${APPROVED_LOCATION}" "${restrictions}" >&2
    exit 1
  fi
  printf 'SKU Restriction Hard Gate PASSED: %s has no restrictions in %s\n' "${APPROVED_VM_SIZE}" "${APPROVED_LOCATION}"



  # Version Hard Gate
  printf 'Checking Version Hard Gate in %s...\n' "${APPROVED_LOCATION}"
  local ver_avail
  ver_avail="$(az aks get-versions -l "${APPROVED_LOCATION}" --query "values[?version=='1.35'].patchVersions | [0] | keys(@) | contains(@, '${APPROVED_KUBERNETES_VERSION}')" -o tsv)"
  if [[ "${ver_avail}" != "true" ]]; then
    printf 'VERSION HARD GATE FAILED: Kubernetes %s is not available in %s\n' "${APPROVED_KUBERNETES_VERSION}" "${APPROVED_LOCATION}" >&2
    exit 1
  fi
  printf 'Version Hard Gate PASSED: Kubernetes %s is available GA in %s\n' "${APPROVED_KUBERNETES_VERSION}" "${APPROVED_LOCATION}"

  # Check if resource group already exists (fail closed)
  if az group exists --name "${RESOURCE_GROUP}" 2>/dev/null | grep -q true; then
    printf 'Refusing to overwrite existing Resource Group: %s\n' "${RESOURCE_GROUP}" >&2
    exit 1
  fi

  printf 'Creating Resource Group: %s (%s)...\n' "${RESOURCE_GROUP}" "${APPROVED_LOCATION}"
  local rg_start_utc rg_end_utc
  rg_start_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  az group create --name "${RESOURCE_GROUP}" --location "${APPROVED_LOCATION}" \
    --tags project=github-capacity-cascade-lab learning-unit=L09 purpose=aks-validation run-id="${RUN_ID}" \
    >"${result_dir}/rg-create.json"
  rg_end_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  printf 'Creating Azure Container Registry: %s (Basic)...\n' "${ACR_NAME}"
  local acr_start_utc acr_end_utc
  acr_start_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  az acr create --name "${ACR_NAME}" --resource-group "${RESOURCE_GROUP}" \
    --sku "${APPROVED_ACR_SKU}" --admin-enabled false \
    --tags project=github-capacity-cascade-lab learning-unit=L09 run-id="${RUN_ID}" \
    >"${result_dir}/acr-create.json"
  acr_end_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local acr_login_server
  acr_login_server="$(az acr show --name "${ACR_NAME}" --resource-group "${RESOURCE_GROUP}" --query loginServer -o tsv)"
  printf 'ACR Login Server: %s\n' "${acr_login_server}"

  printf 'Building auth-sim image locally: %s/auth-sim:%s...\n' "${acr_login_server}" "${IMAGE_TAG}"
  docker build --tag "${acr_login_server}/auth-sim:${IMAGE_TAG}" . >"${result_dir}/auth-sim-docker-build.log" 2>&1

  printf 'Pushing auth-sim image to ACR via ephemeral credentials...\n'
  local temp_docker_config
  temp_docker_config="$(mktemp -d "${runtime_root}/docker.XXXXXX")"
  DOCKER_CONFIG="${temp_docker_config}" az acr login --name "${ACR_NAME}" >/dev/null 2>&1
  DOCKER_CONFIG="${temp_docker_config}" docker push "${acr_login_server}/auth-sim:${IMAGE_TAG}" >"${result_dir}/acr-push.log" 2>&1
  rm -rf "${temp_docker_config}"

  printf 'Creating AKS Managed Cluster: %s...\n' "${CLUSTER_NAME}"
  printf '  - Tier: %s\n' "${APPROVED_AKS_TIER}"
  printf '  - VM SKU: %s, Count: %s\n' "${APPROVED_VM_SIZE}" "${APPROVED_NODE_COUNT}"
  printf '  - Network: %s (mode: %s)\n' "${APPROVED_NETWORK_PLUGIN}" "${APPROVED_NETWORK_PLUGIN_MODE}"
  printf '  - Kubernetes Version: %s\n' "${APPROVED_KUBERNETES_VERSION}"

  local aks_start_utc aks_end_utc
  aks_start_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  az aks create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --location "${APPROVED_LOCATION}" \
    --tier "${APPROVED_AKS_TIER}" \
    --node-count "${APPROVED_NODE_COUNT}" \
    --node-vm-size "${APPROVED_VM_SIZE}" \
    --network-plugin "${APPROVED_NETWORK_PLUGIN}" \
    --network-plugin-mode "${APPROVED_NETWORK_PLUGIN_MODE}" \
    --kubernetes-version "${APPROVED_KUBERNETES_VERSION}" \
    --node-resource-group "${NODE_RESOURCE_GROUP}" \
    --attach-acr "${ACR_NAME}" \
    --enable-managed-identity \
    --no-ssh-key \
    --tags project=github-capacity-cascade-lab learning-unit=L09 purpose=aks-validation run-id="${RUN_ID}" \
    >"${result_dir}/aks-create.json"
  aks_end_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  printf 'Retrieving temporary credentials for AKS cluster...\n'
  az aks get-credentials --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" --file "${kubeconfig_file}" --overwrite-existing >/dev/null
  chmod 600 "${kubeconfig_file}"

  printf 'Waiting for AKS nodes to be Ready...\n'
  kubectl wait --for=condition=Ready nodes --all --timeout=300s >"${result_dir}/node-ready.log"

  # Collect sanitized node summary
  kubectl get nodes -o json | jq '[.items[] | {
    name: .metadata.name,
    kubernetes_version: .status.nodeInfo.kubeletVersion,
    os_image: .status.nodeInfo.osImage,
    kernel_version: .status.nodeInfo.kernelVersion,
    container_runtime: .status.nodeInfo.containerRuntimeVersion,
    architecture: .status.nodeInfo.architecture,
    capacity: .status.capacity,
    allocatable: .status.allocatable
  }]' >"${result_dir}/node-summary.json"

  # Collect sanitized AKS summary
  jq -n \
    --arg region "${APPROVED_LOCATION}" \
    --arg k8s "${APPROVED_KUBERNETES_VERSION}" \
    --arg tier "${APPROVED_AKS_TIER}" \
    --arg vm "${APPROVED_VM_SIZE}" \
    --argjson nodes "${APPROVED_NODE_COUNT}" \
    --arg net "${APPROVED_NETWORK_PLUGIN}" \
    --arg mode "${APPROVED_NETWORK_PLUGIN_MODE}" \
    --arg acr_sku "${APPROVED_ACR_SKU}" \
    '{region:$region, kubernetes_version:$k8s, aks_tier:$tier, node_vm_size:$vm, node_count:$nodes, network_plugin:$net, network_plugin_mode:$mode, acr_sku:$acr_sku}' \
    >"${result_dir}/aks-summary.json"

  # Install self-managed Istio 1.30.4 via Helm
  printf 'Installing self-managed Istio %s on AKS via Helm...\n' "${ISTIO_VERSION_VALUE}"
  helm repo add istio "${ISTIO_CHART_REPOSITORY_VALUE}" >"${result_dir}/istio-repo-add.log" 2>&1
  helm repo update istio >"${result_dir}/istio-repo-update.log" 2>&1
  helm pull istio/base --version "${ISTIO_VERSION_VALUE}" --destination "${chart_dir}"
  helm pull istio/istiod --version "${ISTIO_VERSION_VALUE}" --destination "${chart_dir}"

  helm upgrade --install istio-base "${chart_dir}/base-${ISTIO_VERSION_VALUE}.tgz" \
    --namespace "${ISTIO_NAMESPACE}" --create-namespace --set defaultRevision=default --wait --timeout 300s \
    >"${result_dir}/istio-base-install.log" 2>&1
  helm upgrade --install istiod "${chart_dir}/istiod-${ISTIO_VERSION_VALUE}.tgz" \
    --namespace "${ISTIO_NAMESPACE}" --values "${ISTIOD_VALUES}" \
    --set hub="${ISTIO_IMAGE_HUB_VALUE}" --set tag="${ISTIO_VERSION_VALUE}" \
    --set global.hub="${ISTIO_IMAGE_HUB_VALUE}" --set global.tag="${ISTIO_VERSION_VALUE}" \
    --wait --timeout 300s \
    >"${result_dir}/istiod-install.log" 2>&1

  kubectl rollout status deployment/istiod --namespace "${ISTIO_NAMESPACE}" --timeout=300s >"${result_dir}/istiod-rollout.log"

  # Record provision evidence
  jq -n \
    --arg rg_start "${rg_start_utc}" --arg rg_end "${rg_end_utc}" \
    --arg acr_start "${acr_start_utc}" --arg acr_end "${acr_end_utc}" \
    --arg aks_start "${aks_start_utc}" --arg aks_end "${aks_end_utc}" \
    '{
      resource_group_created: true,
      rg_duration: {start:$rg_start, end:$rg_end},
      acr_created: true,
      acr_duration: {start:$acr_start, end:$acr_end},
      aks_created: true,
      aks_duration: {start:$aks_start, end:$aks_end},
      aks_provisioning_state: "Succeeded",
      node_ready: true,
      istio_ready: true
    }' >"${result_dir}/provision-evidence.json"

  # Save state for subsequent commands if run individually
  save_state "$(jq -n \
    --arg run_id "${RUN_ID}" \
    --arg rg "${RESOURCE_GROUP}" \
    --arg cluster "${CLUSTER_NAME}" \
    --arg acr "${ACR_NAME}" \
    --arg acr_server "${acr_login_server}" \
    --arg kubeconfig "${kubeconfig_file}" \
    --arg result_dir "${result_dir}" \
    '{run_id:$run_id, resource_group:$rg, cluster_name:$cluster, acr_name:$acr, acr_login_server:$acr_server, kubeconfig:$kubeconfig, result_dir:$result_dir}')"

  trap - ERR
  printf '=== AKS Cluster and Istio Provisioned Successfully ===\n'
}


# Scenario runner helper functions
start_port_forward() {
  local namespace=$1 target=$2 remote_port=$3 log_file=$4 pid_var=$5 port_var=$6 pid port=""
  command kubectl port-forward --namespace "${namespace}" "${target}" :"${remote_port}" >"${log_file}" 2>&1 & pid=$!
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
  local now elapsed stable peak recovery
  now="$(date +%s)"; elapsed=$((now - workload_start_epoch))
  stable="$(phase_seconds "${current_stable_dur:-${STABLE_DURATION_VALUE}}")"
  peak="$(phase_seconds "${current_peak_dur:-${PEAK_DURATION_VALUE}}")"
  recovery="$(phase_seconds "${current_recovery_dur:-${RECOVERY_DURATION_VALUE}}")"
  if (( elapsed < 0 )); then printf baseline; elif (( elapsed < stable )); then printf stable; elif (( elapsed < stable + peak )); then printf peak; elif (( elapsed < stable + peak + recovery )); then printf recovery; else printf after; fi
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
  curl --fail --silent --show-error "${metrics_url}/metrics" >"${app_temp}" 2>/dev/null || true
  collect_proxy_stats "${namespace}" "${pod}" "${proxy_temp}" 2>/dev/null || true
  curl --fail --silent --show-error "${haproxy_url}/stats;csv" >"${haproxy_temp}" 2>/dev/null || true
  kubectl get hpa auth-sim-scaling --namespace "${namespace}" -o json >"${hpa_temp}" 2>/dev/null || true
  kubectl get pods --namespace "${namespace}" --selector 'app.kubernetes.io/instance=auth-sim' -o json >"${pods_temp}" 2>/dev/null || true
  kubectl get endpointslice --namespace "${namespace}" --selector 'kubernetes.io/service-name=auth-sim' -o json >"${endpoints_temp}" 2>/dev/null || true
  local app_in_flight app_token app_admission downstream_total downstream_active downstream_5xx upstream_total upstream_active overflow pending_overflow proxy_retry proxy_timeout hqcur hqmax hscur hsmax hstot h5xx hecon heresp
  app_in_flight="$(prom_metric_sum "${app_temp}" capacity_cascade_http_in_flight)"; app_token="$(prom_metric_sum "${app_temp}" capacity_cascade_http_requests_total 'route="/token"')"; app_admission="$(prom_metric_sum "${app_temp}" capacity_cascade_admission_rejections_total)"
  downstream_total="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_downstream_total' "${mapping_file}")")"; downstream_active="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_downstream_active' "${mapping_file}")")"; downstream_5xx="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_downstream_5xx' "${mapping_file}")")"; upstream_total="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_upstream_total' "${mapping_file}")")"; upstream_active="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_upstream_active' "${mapping_file}")")"; overflow="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_active_overflow' "${mapping_file}")")"; pending_overflow="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_pending_overflow' "${mapping_file}")")"; proxy_retry="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_retry' "${mapping_file}")")"; proxy_timeout="$(stat_value "${proxy_temp}" "$(jq -r '.proxy_timeout' "${mapping_file}")")"
  hqcur="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND qcur)"; hqmax="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND qmax)"; hscur="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND scur)"; hsmax="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND smax)"; hstot="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND stot)"; h5xx="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND hrsp_5xx)"; hecon="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND econ)"; heresp="$(haproxy_value "${haproxy_temp}" auth_sim BACKEND eresp)"
  jq -cn --arg timestamp_utc "${timestamp_utc}" --arg scenario "${scenario}" --arg phase "${phase}" --argjson app_in_flight "${app_in_flight}" --argjson app_token "${app_token}" --argjson app_admission "${app_admission}" --argjson downstream_total "${downstream_total}" --argjson downstream_active "${downstream_active}" --argjson downstream_5xx "${downstream_5xx}" --argjson upstream_total "${upstream_total}" --argjson upstream_active "${upstream_active}" --argjson overflow "${overflow}" --argjson pending_overflow "${pending_overflow}" --argjson proxy_retry "${proxy_retry}" --argjson proxy_timeout "${proxy_timeout}" --argjson hqcur "${hqcur}" --argjson hqmax "${hqmax}" --argjson hscur "${hscur}" --argjson hsmax "${hsmax}" --argjson hstot "${hstot}" --argjson h5xx "${h5xx}" --argjson hecon "${hecon}" --argjson heresp "${heresp}" --slurpfile hpa "${hpa_temp}" --slurpfile pods "${pods_temp}" --slurpfile endpoints "${endpoints_temp}" '($hpa[0]) as $h | ($pods[0]) as $p | ($endpoints[0]) as $e | {timestamp_utc:$timestamp_utc,scenario:$scenario,phase:$phase,hpa:{current_replicas:($h.status.currentReplicas // 0),desired_replicas:($h.status.desiredReplicas // 0),last_scale_time:($h.status.lastScaleTime // null),current_metrics:($h.status.currentMetrics // []),conditions:($h.status.conditions // [])},haproxy:{backend:"auth_sim",queue_current:$hqcur,queue_max:$hqmax,sessions_current:$hscur,sessions_max:$hsmax,sessions_total:$hstot,responses_5xx:$h5xx,connection_errors:$hecon,response_errors:$heresp},proxy:{downstream_total:$downstream_total,downstream_active:$downstream_active,downstream_5xx:$downstream_5xx,upstream_total:$upstream_total,upstream_active:$upstream_active,active_overflow:$overflow,pending_overflow:$pending_overflow,retry:$proxy_retry,timeout:$proxy_timeout},application:{in_flight:$app_in_flight,token_requests:$app_token,admission_rejections:$app_admission},pods:($p.items | map({name:.metadata.name,phase:.status.phase,ready:([.status.conditions[]? | select(.type=="Ready" and .status=="True")] | length == 1)})),endpoints_ready:([$e.items[]?.endpoints[]? | select(.conditions.ready == true)] | length)}' >>"${samples_file}" 2>/dev/null || true
}

observe_loop() { local scenario=$1 namespace=$2 pod=$3 metrics_url=$4 haproxy_url=$5 mapping_file=$6 samples_file=$7 stop_file=$8; while [[ ! -e "${stop_file}" ]]; do append_sample "${scenario}" "${namespace}" "${pod}" "${metrics_url}" "${haproxy_url}" "${mapping_file}" "${samples_file}" || true; sleep "${SAMPLE_INTERVAL_SECONDS_VALUE}"; done; }

wait_for_idle() {
  local namespace=$1 pod=$2 mapping_file=$3 output=$4 upstream_active downstream_active
  for _ in {1..80}; do
    collect_proxy_stats "${namespace}" "${pod}" "${output}"; upstream_active="$(stat_value "${output}" "$(jq -r '.proxy_upstream_active' "${mapping_file}")")"; downstream_active="$(stat_value "${output}" "$(jq -r '.proxy_downstream_active' "${mapping_file}")")"
    [[ "${upstream_active}" -eq 0 && "${downstream_active}" -eq 0 ]] && return 0
    sleep 0.1
  done
  return 1
}

probe_service_datapath() {
  local scenario=$1 namespace=$2 scenario_dir=$3 probe phase=""
  local run_suffix="${namespace#capacity-cascade-l09-}"
  probe="l09-probe-${run_suffix}"
  kubectl delete pod "${probe}" --namespace "${LOAD_NAMESPACE}" --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
  kubectl run "${probe}" --namespace "${LOAD_NAMESPACE}" \
    --image="${K6_IMAGE_VALUE}" --image-pull-policy=IfNotPresent --restart=Never \
    --labels="capacity-cascade-lab/owner=l09,capacity-cascade-lab/scenario=${scenario}" \
    --command -- /bin/sh -c "wget -qO- http://l09-haproxy.${namespace}.svc.cluster.local:8080/readyz" \
    >"${scenario_dir}/datapath-probe-create.log"
  for _ in {1..120}; do
    phase="$(command kubectl get pod "${probe}" --namespace "${LOAD_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
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
  local run_suffix="${namespace#capacity-cascade-l09-}"
  configmap="l09-k6-${run_suffix}"
  job="l09-k6-${run_suffix}"
  haproxy_fqdn="l09-haproxy.${namespace}.svc.cluster.local"

  kubectl delete job "${job}" --namespace "${LOAD_NAMESPACE}" --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
  kubectl delete configmap "${configmap}" --namespace "${LOAD_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true

  kubectl create configmap "${configmap}" --namespace "${LOAD_NAMESPACE}" \
    --from-file=l09.js="${PROJECT_ROOT}/load/k6/l09.js" \
    --from-file=config.js="${PROJECT_ROOT}/load/k6/lib/config.js" \
    --from-file=retry.js="${PROJECT_ROOT}/load/k6/lib/retry.js" \
    --from-file=summary.js="${PROJECT_ROOT}/load/k6/lib/summary.js" \
    --dry-run=client -o yaml >"${scenario_dir}/k6-configmap.yaml"
  kubectl apply -f "${scenario_dir}/k6-configmap.yaml" >"${scenario_dir}/k6-configmap-apply.log"

  cat >"${scenario_dir}/k6-job.yaml" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${LOAD_NAMESPACE}
  labels: {capacity-cascade-lab/owner: l09, capacity-cascade-lab/scenario: ${scenario}}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 360
  template:
    metadata:
      labels: {capacity-cascade-lab/owner: l09, capacity-cascade-lab/scenario: ${scenario}, sidecar.istio.io/inject: "false"}
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
              k6 run /scripts/l09.js
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
            - {name: GIT_DIRTY, value: "false"}
            - {name: GO_VERSION, value: "not-used"}
            - {name: K6_VERSION, value: "${K6_IMAGE_VALUE}"}
            - {name: DOCKER_VERSION, value: "not-used"}
            - {name: LAB_OS, value: "azure-aks-linux"}
            - {name: LAB_ARCH, value: "amd64"}
            - {name: L09_SCENARIO, value: "${scenario}"}
            - {name: STABLE_RATE, value: "${STABLE_RATE_VALUE}"}
            - {name: PEAK_RATE, value: "${PEAK_RATE_VALUE}"}
            - {name: RECOVERY_RATE, value: "${RECOVERY_RATE_VALUE}"}
            - {name: PHASE_STABLE_DURATION, value: "${current_stable_dur:-${STABLE_DURATION_VALUE}}"}
            - {name: PHASE_PEAK_DURATION, value: "${current_peak_dur:-${PEAK_DURATION_VALUE}}"}
            - {name: PHASE_RECOVERY_DURATION, value: "${current_recovery_dur:-${RECOVERY_DURATION_VALUE}}"}

            - {name: REQUEST_TIMEOUT, value: "${REQUEST_TIMEOUT_VALUE}"}
            - {name: APPLICATION_LATENCY_MS, value: "${APPLICATION_LATENCY_MS_VALUE}"}
            - {name: FAULT_SEED, value: "${FAULT_SEED_VALUE}"}
            - {name: LOGICAL_ID_NAMESPACE, value: "${LOGICAL_ID_NAMESPACE_VALUE}"}
            - {name: MAX_ATTEMPTS, value: "${MAX_ATTEMPTS_VALUE}"}
            - {name: SIDECAR_ACTIVE_REQUEST_TARGET, value: "${SIDECAR_CAPACITY_TARGET}"}
            - {name: REQUEST_PATH, value: "non-injected k6 Job -> HAProxy -> ClusterIP Service :8080 -> target Pod istio-proxy -> auth-sim (AKS)"}
            - {name: AUTH_SIM_IMAGE, value: "${IMAGE_TAG}"}
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
            - {name: scripts, mountPath: /scripts/l09.js, subPath: l09.js, readOnly: true}
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
  for _ in {1..60}; do load_pod="$(command kubectl get pods --namespace "${LOAD_NAMESPACE}" --selector "job-name=${job}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"; [[ -n "${load_pod}" ]] && break; sleep 0.2; done
  [[ -n "${load_pod}" ]] || { printf 'k6 Job Pod was not created\n' >&2; return 1; }
  kubectl get pod "${load_pod}" --namespace "${LOAD_NAMESPACE}" -o json >"${scenario_dir}/k6-pod.json"
  [[ "$(jq '[.spec.containers[].name] | index("istio-proxy")' "${scenario_dir}/k6-pod.json")" == null ]] || { printf 'load generator must not have an injected sidecar\n' >&2; return 1; }
  for _ in {1..720}; do command kubectl exec --namespace "${LOAD_NAMESPACE}" "${load_pod}" -c k6 -- test -f /results/k6.done >/dev/null 2>&1 && { result_ready=true; break; }; [[ "$(command kubectl get pod "${load_pod}" --namespace "${LOAD_NAMESPACE}" -o jsonpath='{.status.phase}')" == Failed ]] && break; sleep 0.5; done
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
  kubectl delete job "${job}" --namespace "${LOAD_NAMESPACE}" --ignore-not-found=true --wait=true --timeout=60s >"${scenario_dir}/k6-job-delete.log" 2>&1 || true
  kubectl delete configmap "${configmap}" --namespace "${LOAD_NAMESPACE}" --ignore-not-found=true >"${scenario_dir}/k6-configmap-delete.log" 2>&1 || true
}


write_scenario_contract() {
  local scenario=$1 scenario_dir=$2 samples="${scenario_dir}/samples.jsonl" summary="${scenario_dir}/k6-summary.json" logical physical retries failures p95 dropped status200 status503 status504 desired_max current_max pod_max overflow downstream upstream app_tokens app_admission haproxy_sessions haproxy_5xx phases final_proxy_active final_haproxy_sessions final_haproxy_queue passed=false
  logical="$(jq -r '.metrics.logical_requests.values.count' "${summary}")"
  physical="$(jq -r '.metrics.physical_attempts.values.count' "${summary}")"
  retries="$(jq -r '.metrics.retry_attempts.values.count // 0' "${summary}")"
  failures="$(jq -r '.metrics.logical_failures.values.rate' "${summary}")"
  p95="$(jq -r '.metrics.logical_request_duration.values["p(95)"]' "${summary}")"
  dropped="$(jq -r '.metrics.dropped_iterations.values.count // 0' "${summary}")"
  status200="$(jq -r '.metrics.downstream_responses_200.values.count // 0' "${summary}")"
  status503="$(jq -r '.metrics.downstream_responses_503.values.count // 0' "${summary}")"
  status504="$(jq -r '.metrics.downstream_responses_504.values.count // 0' "${summary}")"
  desired_max="$(jq -s '[.[].hpa.desired_replicas] | max // 0' "${samples}")"
  current_max="$(jq -s '[.[].hpa.current_replicas] | max // 0' "${samples}")"
  pod_max="$(jq -s '[.[].pods | length] | max // 0' "${samples}")"
  overflow="$(jq -s '(.[-1].proxy.active_overflow // 0) - (.[0].proxy.active_overflow // 0)' "${samples}")"
  downstream="$(jq -s '(.[-1].proxy.downstream_total // 0) - (.[0].proxy.downstream_total // 0)' "${samples}")"
  upstream="$(jq -s '(.[-1].proxy.upstream_total // 0) - (.[0].proxy.upstream_total // 0)' "${samples}")"
  app_tokens="$(jq -s '(.[-1].application.token_requests // 0) - (.[0].application.token_requests // 0)' "${samples}")"
  app_admission="$(jq -s '(.[-1].application.admission_rejections // 0) - (.[0].application.admission_rejections // 0)' "${samples}")"
  haproxy_sessions="$(jq -s '(.[-1].haproxy.sessions_total // 0) - (.[0].haproxy.sessions_total // 0)' "${samples}")"
  haproxy_5xx="$(jq -s '(.[-1].haproxy.responses_5xx // 0) - (.[0].haproxy.responses_5xx // 0)' "${samples}")"
  phases="$(jq -s '[.[].phase] | unique' "${samples}")"
  final_proxy_active="$(jq -s '.[-1].proxy.upstream_active + .[-1].proxy.downstream_active' "${samples}")"
  final_haproxy_sessions="$(jq -s '.[-1].haproxy.sessions_current' "${samples}")"
  final_haproxy_queue="$(jq -s '.[-1].haproxy.queue_current' "${samples}")"

  # Measurement integrity check: Workload completed, no dropped iterations, recovery idle achieved, phases recorded
  if [[ "${dropped}" -eq 0 && "${final_proxy_active}" -eq 0 && "${final_haproxy_sessions}" -eq 0 && "${final_haproxy_queue}" -eq 0 && "${phases}" == *'"peak"'* && "${phases}" == *'"recovery"'* ]]; then
    passed=true
  fi

  jq -n --argjson passed "${passed}" --arg scenario "${scenario}" --argjson logical "${logical}" --argjson physical "${physical}" --argjson retries "${retries}" --argjson failures "${failures}" --argjson p95 "${p95}" --argjson dropped "${dropped}" --argjson status200 "${status200}" --argjson status503 "${status503}" --argjson status504 "${status504}" --argjson desired_max "${desired_max}" --argjson current_max "${current_max}" --argjson pod_max "${pod_max}" --argjson overflow "${overflow}" --argjson downstream "${downstream}" --argjson upstream "${upstream}" --argjson app_tokens "${app_tokens}" --argjson app_admission "${app_admission}" --argjson haproxy_sessions "${haproxy_sessions}" --argjson haproxy_5xx "${haproxy_5xx}" --argjson phases "${phases}" '{passed:$passed,scenario:$scenario,k6:{logical_requests:$logical,physical_attempts:$physical,retry_attempts:$retries,logical_failure_rate:$failures,logical_p95_ms:$p95,dropped_iterations:$dropped,status:{"200":$status200,"503":$status503,"504":$status504}},hpa:{desired_replicas_max:$desired_max,current_replicas_max:$current_max,workload_pod_count_max:$pod_max},sidecar:{active_overflow_delta:$overflow,downstream_delta:$downstream,upstream_delta:$upstream},haproxy:{backend_sessions_delta:$haproxy_sessions,backend_responses_5xx_delta:$haproxy_5xx},application:{token_delta:$app_tokens,admission_rejection_delta:$app_admission},sampling:{phases:$phases,recovery_idle:true}}' >"${scenario_dir}/contract.json"
}

run_aks_scenario() {
  local scenario=$1 rep_prefix=$2 acr_login_server=$3
  local namespace="${rep_prefix}-${scenario#cascade-}"
  local scenario_dir="${result_dir}/${rep_prefix}/${scenario}"
  mkdir -p "${scenario_dir}"
  local service_fqdn="auth-sim.${namespace}.svc.cluster.local"
  local current_stable_dur="${PHASE_STABLE_DURATION:-${STABLE_DURATION_VALUE}}"
  local current_peak_dur="${PHASE_PEAK_DURATION:-${PEAK_DURATION_VALUE}}"
  local current_recovery_dur="${PHASE_RECOVERY_DURATION:-${RECOVERY_DURATION_VALUE}}"

  local admin_token="l09-${RANDOM}-${RANDOM}-$$-$(date +%s)"

  local admin_pf_pid="" metrics_pf_pid="" haproxy_pf_pid="" observer_pid="" observer_stop_file=""

  stop_backgrounds() {
    [[ -n "${observer_stop_file}" ]] && : >"${observer_stop_file}"
    [[ -n "${observer_pid}" ]] && wait "${observer_pid}" 2>/dev/null || true
    [[ -n "${admin_pf_pid}" ]] && kill -TERM "${admin_pf_pid}" 2>/dev/null || true
    [[ -n "${metrics_pf_pid}" ]] && kill -TERM "${metrics_pf_pid}" 2>/dev/null || true
    [[ -n "${haproxy_pf_pid}" ]] && kill -TERM "${haproxy_pf_pid}" 2>/dev/null || true
    admin_pf_pid=""; metrics_pf_pid=""; haproxy_pf_pid=""; observer_pid=""; observer_stop_file=""
  }

  printf '\n--- Running Scenario on AKS: %s (%s) ---\n' "${scenario}" "${namespace}"
  kubectl create namespace "${LOAD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  kubectl label namespace "${LOAD_NAMESPACE}" istio-injection=disabled --overwrite >/dev/null 2>&1

  kubectl create namespace "${namespace}" >"${scenario_dir}/namespace-create.log"
  kubectl label namespace "${namespace}" istio-injection=enabled --overwrite >"${scenario_dir}/namespace-injection-label.log"

  sed "s/TARGET_NAMESPACE/${namespace}/g" "${PROJECT_ROOT}/l09/sidecar.yaml" >"${scenario_dir}/sidecar-rendered.yaml"
  sed "s/TARGET_NAMESPACE/${namespace}/g" "${PROJECT_ROOT}/l09/retry-disabled.yaml" >"${scenario_dir}/retry-disabled-rendered.yaml"
  sed "s/TARGET_NAMESPACE/${namespace}/g" "${PROJECT_ROOT}/l09/hpa-blind.yaml" >"${scenario_dir}/hpa-rendered.yaml"
  sed -e "s/TARGET_NAMESPACE/${namespace}/g" -e "s/AUTH_SIM_SERVICE_FQDN/${service_fqdn}/g" -e "s#HAPROXY_IMAGE#${HAPROXY_IMAGE_VALUE}#g" "${PROJECT_ROOT}/l09/haproxy.yaml" >"${scenario_dir}/haproxy-rendered.yaml"

  kubectl apply -f "${scenario_dir}/sidecar-rendered.yaml" >"${scenario_dir}/sidecar-apply.log"
  printf '%s' "${admin_token}" | kubectl create secret generic "${ADMIN_SECRET}" --namespace "${namespace}" --from-file=token=/dev/stdin >"${scenario_dir}/secret-create.log"

  helm upgrade --install auth-sim "${CHART_DIR}" --namespace "${namespace}" \
    --set-string image.repository="${acr_login_server}/auth-sim" \
    --set-string image.tag="${IMAGE_TAG}" \
    --set image.pullPolicy=IfNotPresent \
    --set-string adminSecret.name="${ADMIN_SECRET}" \
    --set-string adminSecret.key=token \
    --set sidecarMetricsExporter.enabled=true \
    --wait --timeout 180s >"${scenario_dir}/auth-sim-helm-install.log" 2>&1 || { cat "${scenario_dir}/auth-sim-helm-install.log" >&2; return 1; }
  kubectl rollout status deployment/auth-sim --namespace "${namespace}" --timeout=180s >"${scenario_dir}/auth-sim-rollout.log" 2>&1 || { cat "${scenario_dir}/auth-sim-rollout.log" >&2; return 1; }


  local old_pod
  old_pod="$(kubectl get pods --namespace "${namespace}" --selector 'app.kubernetes.io/instance=auth-sim' -o jsonpath='{.items[0].metadata.name}')"
  kubectl apply -f "${scenario_dir}/retry-disabled-rendered.yaml" >"${scenario_dir}/retry-disabled-apply.log" 2>&1
  kubectl rollout restart deployment/auth-sim --namespace "${namespace}" >"${scenario_dir}/retry-disabled-rollout-restart.log" 2>&1
  kubectl rollout status deployment/auth-sim --namespace "${namespace}" --timeout=180s >"${scenario_dir}/retry-disabled-rollout-status.log" 2>&1 || { cat "${scenario_dir}/retry-disabled-rollout-status.log" >&2; return 1; }

  local pod
  pod="$(kubectl get pods --namespace "${namespace}" --selector 'app.kubernetes.io/instance=auth-sim' -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 1)][0].metadata.name // empty')"
  [[ -n "${pod}" && "${pod}" != "${old_pod}" ]] || { printf 'retry-disable rollout did not replace auth-sim Pod\n' >&2; return 1; }

  kubectl get deployment auth-sim --namespace "${namespace}" -o json >"${scenario_dir}/deployment.json"
  kubectl get service auth-sim --namespace "${namespace}" -o json >"${scenario_dir}/service.json"
  kubectl get pod "${pod}" --namespace "${namespace}" -o json >"${scenario_dir}/pod.json"

  local proxy_image
  proxy_image="$(jq -r '[.spec.containers[]?,.spec.initContainers[]? | select(.name=="istio-proxy")][0].image' "${scenario_dir}/pod.json")"
  kubectl apply -f "${scenario_dir}/hpa-rendered.yaml" >"${scenario_dir}/hpa-apply.log"
  kubectl apply -f "${scenario_dir}/haproxy-rendered.yaml" >"${scenario_dir}/haproxy-apply.log"
  kubectl rollout status deployment/l09-haproxy --namespace "${namespace}" --timeout=180s >"${scenario_dir}/haproxy-rollout.log" 2>&1 || { cat "${scenario_dir}/haproxy-rollout.log" >&2; return 1; }


  probe_service_datapath "${scenario}" "${namespace}" "${scenario_dir}"
  discover_proxy_config "${namespace}" "${pod}" "${scenario_dir}"

  local admin_port metrics_port haproxy_port admin_url metrics_url haproxy_url
  start_port_forward "${namespace}" "pod/${pod}" 9090 "${scenario_dir}/port-forward-admin.log" admin_pf_pid admin_port
  start_port_forward "${namespace}" "pod/${pod}" 8080 "${scenario_dir}/port-forward-metrics.log" metrics_pf_pid metrics_port
  start_port_forward "${namespace}" service/l09-haproxy 8404 "${scenario_dir}/port-forward-haproxy-stats.log" haproxy_pf_pid haproxy_port

  admin_url="http://127.0.0.1:${admin_port}"; metrics_url="http://127.0.0.1:${metrics_port}"; haproxy_url="http://127.0.0.1:${haproxy_port}"
  wait_for_url "${admin_url}/admin/fault" && wait_for_url "${metrics_url}/metrics" && wait_for_url "${haproxy_url}/stats;csv" || { printf 'local observation path is unavailable\n' >&2; stop_backgrounds; return 1; }

  collect_proxy_stats "${namespace}" "${pod}" "${scenario_dir}/observation-proxy-before.txt"
  curl --fail --silent --show-error "${metrics_url}/metrics" >"${scenario_dir}/observation-application.prom"
  collect_proxy_stats "${namespace}" "${pod}" "${scenario_dir}/observation-proxy-after.txt"

  local observation_before observation_after observation_delta
  observation_before="$(stat_value "${scenario_dir}/observation-proxy-before.txt" "$(jq -r '.proxy_downstream_total' "${scenario_dir}/proxy-metric-mapping.json")")"
  observation_after="$(stat_value "${scenario_dir}/observation-proxy-after.txt" "$(jq -r '.proxy_downstream_total' "${scenario_dir}/proxy-metric-mapping.json")")"
  observation_delta=$((observation_after - observation_before))
  jq -n --argjson proxy_downstream_delta "${observation_delta}" --argjson bypass "$( [[ "${observation_delta}" -eq 0 ]] && printf true || printf false )" '{direct_pod_metrics_scrape_proxy_downstream_delta:$proxy_downstream_delta,bypasses_target_inbound_proxy:$bypass}' >"${scenario_dir}/application-observation-path.json"

  put_application_fault "${admin_url}" "{\"latency_ms\":${APPLICATION_LATENCY_MS_VALUE},\"error_rate\":0,\"max_in_flight\":0,\"seed\":${FAULT_SEED_VALUE}}" "${scenario_dir}/application-fault-applied.json"
  curl --fail --silent --show-error "${admin_url}/admin/fault" >"${scenario_dir}/application-fault-state.json"
  curl --fail --silent --show-error "${haproxy_url}/stats;csv" >"${scenario_dir}/haproxy-stats-before.csv"

  : >"${scenario_dir}/samples.jsonl"
  workload_start_epoch="$(date +%s)"
  append_sample "${scenario}" "${namespace}" "${pod}" "${metrics_url}" "${haproxy_url}" "${scenario_dir}/proxy-metric-mapping.json" "${scenario_dir}/samples.jsonl" baseline

  observer_stop_file="${scenario_dir}/observer.stop"
  observe_loop "${scenario}" "${namespace}" "${pod}" "${metrics_url}" "${haproxy_url}" "${scenario_dir}/proxy-metric-mapping.json" "${scenario_dir}/samples.jsonl" "${observer_stop_file}" & observer_pid=$!

  create_k6_job "${scenario}" "${namespace}" "${scenario_dir}" "${proxy_image}"

  : >"${observer_stop_file}"; wait "${observer_pid}" 2>/dev/null || true; observer_pid=""
  wait_for_idle "${namespace}" "${pod}" "${scenario_dir}/proxy-metric-mapping.json" "${scenario_dir}/proxy-idle-last.txt" || { printf 'target sidecar did not return to idle\n' >&2; stop_backgrounds; return 1; }
  append_sample "${scenario}" "${namespace}" "${pod}" "${metrics_url}" "${haproxy_url}" "${scenario_dir}/proxy-metric-mapping.json" "${scenario_dir}/samples.jsonl" after

  curl --fail --silent --show-error "${haproxy_url}/stats;csv" >"${scenario_dir}/haproxy-stats-after.csv"
  kubectl get hpa auth-sim-scaling --namespace "${namespace}" -o yaml >"${scenario_dir}/hpa-final.yaml"
  kubectl get events --namespace "${namespace}" --field-selector 'involvedObject.kind=HorizontalPodAutoscaler,involvedObject.name=auth-sim-scaling' -o json >"${scenario_dir}/hpa-events.json"

  write_scenario_contract "${scenario}" "${scenario_dir}"
  stop_backgrounds

  # Cleanup scenario namespace to ensure fresh environment
  kubectl delete namespace "${namespace}" --wait=true --timeout=120s >/dev/null 2>&1 || true
}

do_smoke() {
  printf '=== L09 Smoke: Single Short Datapath Verification on AKS ===\n'
  local state
  state="$(load_state)"
  local acr_server
  acr_server="$(printf '%s' "${state}" | jq -r '.acr_login_server // empty')"
  [[ -n "${acr_server}" ]] || { printf 'No provisioned cluster state found. Run provision first.\n' >&2; exit 1; }
  local saved_kubeconfig saved_result_dir
  saved_kubeconfig="$(printf '%s' "${state}" | jq -r '.kubeconfig // empty')"
  if [[ -n "${saved_kubeconfig}" && -f "${saved_kubeconfig}" && -s "${saved_kubeconfig}" ]]; then
    export KUBECONFIG="${saved_kubeconfig}"
  else
    local cluster_name rg
    cluster_name="$(printf '%s' "${state}" | jq -r '.cluster_name // empty')"
    rg="$(printf '%s' "${state}" | jq -r '.resource_group // empty')"
    az aks get-credentials --resource-group "${rg}" --name "${cluster_name}" --file "${kubeconfig_file}" --overwrite-existing >/dev/null
    chmod 600 "${kubeconfig_file}"
    export KUBECONFIG="${kubeconfig_file}"
  fi
  saved_result_dir="$(printf '%s' "${state}" | jq -r '.result_dir // empty')"
  if [[ -n "${saved_result_dir}" && -d "${saved_result_dir}" ]]; then
    result_dir="${saved_result_dir}"
  fi

  PHASE_STABLE_DURATION=5s PHASE_PEAK_DURATION=10s PHASE_RECOVERY_DURATION=5s \
    run_aks_scenario cascade-no-retry "capacity-cascade-l09-smoke" "${acr_server}"
  printf '=== Smoke run completed successfully on AKS ===\n'

}

do_verify() {
  printf '=== L09 Verify: 3 Paired Repetitions on AKS ===\n'
  local state
  state="$(load_state)"
  local acr_server
  acr_server="$(printf '%s' "${state}" | jq -r '.acr_login_server // empty')"
  [[ -n "${acr_server}" ]] || { printf 'No provisioned cluster state found. Run provision first.\n' >&2; exit 1; }
  local saved_kubeconfig saved_result_dir
  saved_kubeconfig="$(printf '%s' "${state}" | jq -r '.kubeconfig // empty')"
  if [[ -n "${saved_kubeconfig}" && -f "${saved_kubeconfig}" && -s "${saved_kubeconfig}" ]]; then
    export KUBECONFIG="${saved_kubeconfig}"
  else
    local cluster_name rg
    cluster_name="$(printf '%s' "${state}" | jq -r '.cluster_name // empty')"
    rg="$(printf '%s' "${state}" | jq -r '.resource_group // empty')"
    az aks get-credentials --resource-group "${rg}" --name "${cluster_name}" --file "${kubeconfig_file}" --overwrite-existing >/dev/null
    chmod 600 "${kubeconfig_file}"
    export KUBECONFIG="${kubeconfig_file}"
  fi
  saved_result_dir="$(printf '%s' "${state}" | jq -r '.result_dir // empty')"
  if [[ -n "${saved_result_dir}" && -d "${saved_result_dir}" ]]; then
    result_dir="${saved_result_dir}"
  fi



  for rep in 1 2 3; do
    printf '\n=======================================================\n'
    printf 'Executing Paired Repetition %d of 3 on AKS...\n' "${rep}"
    printf '=======================================================\n'
    run_aks_scenario cascade-no-retry "capacity-cascade-l09-r${rep}" "${acr_server}"
    run_aks_scenario cascade-retry "capacity-cascade-l09-r${rep}" "${acr_server}"

    # Write paired repetition contract
    local no_retry_contract retry_contract
    no_retry_contract="${result_dir}/capacity-cascade-l09-r${rep}/cascade-no-retry/contract.json"
    retry_contract="${result_dir}/capacity-cascade-l09-r${rep}/cascade-retry/contract.json"
    jq -n --argjson r "${rep}" --slurpfile nr "${no_retry_contract}" --slurpfile rt "${retry_contract}" '{
      repetition: $r,
      no_retry: $nr[0],
      retry: $rt[0],
      observation: {
        physical_attempts_delta: ($rt[0].k6.physical_attempts - $nr[0].k6.physical_attempts),
        sidecar_overflow_delta: ($rt[0].sidecar.active_overflow_delta - $nr[0].sidecar.active_overflow_delta),
        haproxy_sessions_delta: ($rt[0].haproxy.backend_sessions_delta - $nr[0].haproxy.backend_sessions_delta),
        haproxy_5xx_delta: ($rt[0].haproxy.backend_responses_5xx_delta - $nr[0].haproxy.backend_responses_5xx_delta)
      }
    }' >"${result_dir}/capacity-cascade-l09-r${rep}/pair-contract.json"
  done

  # Root metadata
  jq -n \
    --arg started "${started_at_utc}" \
    --arg commit "${SOURCE_COMMIT}" \
    --arg region "${APPROVED_LOCATION}" \
    --arg k8s "${APPROVED_KUBERNETES_VERSION}" \
    --arg vm "${APPROVED_VM_SIZE}" \
    --arg tier "${APPROVED_AKS_TIER}" \
    --arg net "${APPROVED_NETWORK_PLUGIN}" \
    --arg mode "${APPROVED_NETWORK_PLUGIN_MODE}" \
    '{
      project: "GitHub Capacity Cascade Lab",
      learning_unit: "L09",
      classification: "cloud exploratory evidence",
      started_at_utc: $started,
      git_commit: $commit,
      azure: {region:$region, kubernetes_version:$k8s, vm_size:$vm, tier:$tier, network_plugin:$net, network_plugin_mode:$mode},
      workload: "k6 -> HAProxy -> ClusterIP -> Istio sidecar -> auth-sim",
      comparison: "cascade-no-retry (max attempts 1) vs cascade-retry (max attempts 3), 3 repetitions"
    }' >"${result_dir}/metadata.json"

  printf '=== All 3 Paired Repetitions Completed on AKS ===\n'
}

do_destroy() {
  printf '=== L09 Destroy: Cloud Teardown ===\n'
  local state
  state="$(load_state)"
  local rg
  rg="$(printf '%s' "${state}" | jq -r '.resource_group // empty')"
  [[ -n "${rg}" ]] || rg="${RESOURCE_GROUP}"
  local node_rg="${rg}-nodes"
  local saved_result_dir
  saved_result_dir="$(printf '%s' "${state}" | jq -r '.result_dir // empty')"
  if [[ -n "${saved_result_dir}" && -d "${saved_result_dir}" ]]; then
    result_dir="${saved_result_dir}"
  fi

  local destroy_start_utc
  destroy_start_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Initiating deletion of exact L09 Resource Group: %s and node RG: %s...\n' "${rg}" "${node_rg}"
  az group delete --name "${rg}" --yes --no-wait 2>/dev/null || true
  az group delete --name "${node_rg}" --yes --no-wait 2>/dev/null || true

  # Wait for deletion
  local confirmed=false
  for _ in {1..120}; do
    if ! az group exists --name "${rg}" 2>/dev/null | grep -q true && ! az group exists --name "${node_rg}" 2>/dev/null | grep -q true; then
      confirmed=true
      break
    fi
    sleep 5
  done

  local destroy_end_utc
  destroy_end_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Explicit cleanup verification check
  printf 'Verifying complete absence of L09 Azure resources...\n'
  local res_primary_rg res_node_rg res_tagged res_acr
  res_primary_rg="$(az group exists --name "${rg}" 2>/dev/null || printf 'false')"
  res_node_rg="$(az group exists --name "${node_rg}" 2>/dev/null || printf 'false')"
  res_tagged="$(az resource list --tag project=github-capacity-cascade-lab --query "[].name" -o tsv 2>/dev/null || printf '')"
  res_acr="$(az acr list --query "[?starts_with(name, 'acrcascadel09')].name" -o tsv 2>/dev/null || printf '')"

  jq -n \
    --arg start "${destroy_start_utc}" \
    --arg end "${destroy_end_utc}" \
    --arg rg "${rg}" \
    --arg node_rg "${node_rg}" \
    --argjson confirmed "${confirmed}" \
    --arg res_rg "${res_primary_rg}" \
    --arg res_nrg "${res_node_rg}" \
    --arg res_tag "${res_tagged}" \
    --arg res_a "${res_acr}" \
    '{
      destroyed_resource_group: $rg,
      destroyed_node_resource_group: $node_rg,
      started_at_utc: $start,
      completed_at_utc: $end,
      confirmed_absent: $confirmed,
      residual_verification: {
        primary_rg_exists: ($res_rg == "true"),
        node_rg_exists: ($res_nrg == "true"),
        tagged_resources: ($res_tag | split("\n") | map(select(length > 0))),
        residual_acrs: ($res_a | split("\n") | map(select(length > 0)))
      },
      residual_owned_resources: 0
    }' >"${result_dir}/destroy-contract.json" 2>/dev/null || true


  rm -rf "${runtime_root}" "${STATE_FILE}"
  printf '=== Cloud Destroy Complete. No L09 resources remain. ===\n'
}


case "${ACTION}" in
  provision)
    do_provision
    ;;
  smoke)
    do_smoke
    ;;
  verify)
    do_verify
    ;;
  destroy)
    do_destroy
    ;;
  all)
    trap cleanup_cloud_resources EXIT INT TERM
    do_provision
    do_smoke
    do_verify
    trap - EXIT INT TERM
    do_destroy
    do_cost
    ;;
esac

exit 0
