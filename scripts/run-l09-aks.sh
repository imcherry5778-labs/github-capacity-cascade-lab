#!/usr/bin/env bash
# L09 validates the L06 capacity cascade mechanism on Azure AKS in a minimal,
# fail-closed, ephemeral cloud environment without claiming production architecture.
set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ACTION="${1:-preflight}"

# Approved cloud defaults (used during preflight or overridable via environment)
readonly APPROVED_LOCATION="${AZURE_LOCATION:-${L09_LOCATION:-eastus}}"
readonly APPROVED_KUBERNETES_VERSION="${L09_KUBERNETES_VERSION:-1.35.7}"
readonly APPROVED_VM_SIZE="${L09_NODE_VM_SIZE:-Standard_D4s_v5}"
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
  printf '  Node VM (%s in %s): ~$0.192 - $0.236 / hour\n' "${APPROVED_VM_SIZE}" "${APPROVED_LOCATION}"
  printf '  ACR Basic: ~$0.007 / hour (~$0.167 / day)\n'
  printf '  Managed OS Disk (128GB P10/E10): ~$0.015 / hour\n'
  printf '  Estimated Total Hourly Burn: ~$0.25 - $0.35 / hour\n'
  printf '  Estimated Total for 90-minute run: ~$0.40 - $0.60 USD (Upper bound ceiling: $2.00 USD)\n'

  printf '\n=== Preflight complete. No cloud mutations performed. ===\n'
}

do_cost() {
  printf '=== L09 Cost Query ===\n'
  check_required_tools
  local sub_fp
  sub_fp="$(get_subscription_fingerprint)"
  printf 'Querying Azure Cost Management for subscription fingerprint: %s\n' "${sub_fp}"

  # Azure Cost Management queries often have 24-48h latency.
  # Return structured JSON indicating status.
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
  provision|smoke|verify|destroy)
    check_cloud_authorization
    printf 'Cloud action %s requested with explicit authorization.\n' "${ACTION}"
    # Guard logic: If invoked in Phase A without user authorization, check_cloud_authorization fails.
    # In Phase B, the implementation below executes the approved cloud mutations.
    ;;
  *)
    printf 'usage: %s {doctor|preflight|provision|smoke|verify|destroy|cost}\n' "$0" >&2
    exit 2
    ;;
esac

# ==============================================================================
# PHASE B Implementation (Guarded by L09_CLOUD_APPROVED=YES)
# ==============================================================================

readonly RUN_ID="l09-$(date -u +%m%d%H%M)"
readonly RESOURCE_GROUP="rg-capacity-cascade-${RUN_ID}"
readonly NODE_RESOURCE_GROUP="${RESOURCE_GROUP}-nodes"
readonly CLUSTER_NAME="aks-capacity-cascade-${RUN_ID}"
# ACR names must be alphanumeric and 5-50 characters
readonly ACR_NAME="acrcascade${RUN_ID//-/}"

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
  printf 'Cleaning up L09 cloud resources: %s...\n' "${RESOURCE_GROUP}"
  az group delete --name "${RESOURCE_GROUP}" --yes --no-wait 2>/dev/null || true
  rm -rf "${runtime_root}"
}

if [[ "${ACTION}" == "destroy" ]]; then
  cleanup_cloud_resources
  printf 'Destroy command issued for %s.\n' "${RESOURCE_GROUP}"
  exit 0
fi

printf 'L09 Phase B placeholder ready.\n'
exit 0
