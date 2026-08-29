#!/usr/bin/env bash
set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCENARIO="${1:-}"
readonly PUBLIC_ADDR="${LAB_PUBLIC_ADDR:-127.0.0.1:8080}"
readonly ADMIN_ADDR="${LAB_ADMIN_ADDR:-127.0.0.1:9090}"
readonly BASE_URL_VALUE="${BASE_URL:-http://127.0.0.1:8080}"
readonly ADMIN_URL_VALUE="${ADMIN_URL:-http://127.0.0.1:9090}"

case "${SCENARIO}" in
  smoke|baseline|latency|bad-retry|good-retry) ;;
  *)
    printf 'usage: %s {smoke|baseline|latency|bad-retry|good-retry}\n' "$0" >&2
    exit 2
    ;;
esac

for required_tool in git go k6; do
  if ! command -v "${required_tool}" >/dev/null 2>&1; then
    printf 'required tool is missing: %s\n' "${required_tool}" >&2
    exit 127
  fi
done

cd "${PROJECT_ROOT}"

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
touch "${result_dir}/app.log"

admin_token="${LAB_ADMIN_TOKEN:-local-${RANDOM}-${RANDOM}-$$}"
auth_sim_pid=""

cleanup() {
  local exit_code=$?
  trap - EXIT
  set +e
  if [[ -n "${auth_sim_pid}" ]] && kill -0 "${auth_sim_pid}" 2>/dev/null; then
    ADMIN_URL="${ADMIN_URL_VALUE}" LAB_ADMIN_TOKEN="${admin_token}" \
      ALLOW_REMOTE_FAULTS="${ALLOW_REMOTE_FAULTS:-}" \
      k6 run --quiet load/k6/reset.js >/dev/null 2>&1
    kill -TERM "${auth_sim_pid}" 2>/dev/null
    wait "${auth_sim_pid}" 2>/dev/null
  fi
  printf 'Result: %s\n' "${result_dir}"
  exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -n "${AUTH_SIM_BIN:-}" ]]; then
  binary="${AUTH_SIM_BIN}"
  if [[ ! -x "${binary}" ]]; then
    printf 'AUTH_SIM_BIN is not executable: %s\n' "${binary}" >&2
    exit 1
  fi
else
  binary="bin/auth-sim"
  mkdir -p bin
  go build -trimpath -o "${binary}" ./cmd/auth-sim
fi

LAB_PUBLIC_ADDR="${PUBLIC_ADDR}" \
LAB_ADMIN_ADDR="${ADMIN_ADDR}" \
LAB_ADMIN_TOKEN="${admin_token}" \
  "${binary}" >>"${result_dir}/app.log" 2>&1 &
auth_sim_pid=$!

ready=0
for _ in {1..20}; do
  if BASE_URL="${BASE_URL_VALUE}" k6 run --quiet load/k6/probe.js >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "${auth_sim_pid}" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

if [[ "${ready}" -ne 1 ]]; then
  printf 'auth-sim did not become ready; inspect %s/app.log\n' "${result_dir}" >&2
  exit 1
fi

git_commit="$(git rev-parse HEAD 2>/dev/null || printf 'unborn')"
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  git_dirty=true
else
  git_dirty=false
fi

export BASE_URL="${BASE_URL_VALUE}"
export ADMIN_URL="${ADMIN_URL_VALUE}"
export LAB_ADMIN_TOKEN="${admin_token}"
export RESULT_DIR="${result_dir}"
export STARTED_AT_UTC="${started_at_utc}"
export GIT_COMMIT="${git_commit}"
export GIT_DIRTY="${git_dirty}"
export GO_VERSION="$(go version)"
export K6_VERSION="$(k6 version | head -n 1)"
export LAB_OS="$(uname -s)"
export LAB_ARCH="$(uname -m)"

set +e
k6 run "load/k6/${SCENARIO}.js"
scenario_exit=$?
set -e

exit "${scenario_exit}"
