#!/usr/bin/env bash
# 명령 실패, 미정의 변수, pipeline 중간 실패를 즉시 반영한다.
set -euo pipefail

# 스크립트 위치를 기준으로 project root를 계산해 어디에서 호출해도 같은 파일을 사용한다.
readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCENARIO="${1:-}"
readonly PUBLIC_ADDR="${LAB_PUBLIC_ADDR:-127.0.0.1:8080}"
readonly ADMIN_ADDR="${LAB_ADMIN_ADDR:-127.0.0.1:9090}"
readonly BASE_URL_VALUE="${BASE_URL:-http://127.0.0.1:8080}"
readonly ADMIN_URL_VALUE="${ADMIN_URL:-http://127.0.0.1:9090}"

# 알 수 없는 파일 경로를 실행하지 않고 L00에서 지원하는 scenario만 허용한다.
case "${SCENARIO}" in
  smoke|baseline|latency|bad-retry|good-retry) ;;
  *)
    printf 'usage: %s {smoke|baseline|latency|bad-retry|good-retry}\n' "$0" >&2
    exit 2
    ;;
esac

# Result directory나 process를 만들기 전에 local dependency를 확인한다.
for required_tool in git go k6; do
  if ! command -v "${required_tool}" >/dev/null 2>&1; then
    printf 'required tool is missing: %s\n' "${required_tool}" >&2
    exit 127
  fi
done

cd "${PROJECT_ROOT}"

# 각 실행은 고유 UTC timestamp directory를 사용하며 기존 evidence를 덮어쓰지 않는다.
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

# 사용자가 token을 주지 않으면 이 실행에서만 쓰는 임시값을 만들고 evidence에는 저장하지 않는다.
admin_token="${LAB_ADMIN_TOKEN:-local-${RANDOM}-${RANDOM}-$$}"
auth_sim_pid=""

cleanup() {
  # 성공, 실패, signal 중단 모두에서 fault를 reset하고 이 스크립트가 시작한 process만 종료한다.
  local exit_code=$?
  trap - EXIT
  set +e
  if [[ -n "${auth_sim_pid}" ]] && kill -0 "${auth_sim_pid}" 2>/dev/null; then
    # Reset 실패가 원래 scenario exit code를 가리지 않도록 cleanup 구간에서는 best-effort로 실행한다.
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

# Makefile이 이미 빌드한 binary를 우선 사용하고, 단독 호출일 때만 local binary를 생성한다.
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

# Public/Admin listener와 admin token을 환경으로만 전달하고 application 로그를 해당 result directory에 저장한다.
LAB_PUBLIC_ADDR="${PUBLIC_ADDR}" \
LAB_ADMIN_ADDR="${ADMIN_ADDR}" \
LAB_ADMIN_TOKEN="${admin_token}" \
  "${binary}" >>"${result_dir}/app.log" 2>&1 &
auth_sim_pid=$!

# Process 생존 여부만이 아니라 health, readiness, token path가 모두 성공할 때까지 bounded probe한다.
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

# 비교 재현에 필요한 commit/dirty 상태와 tool 버전만 metadata용 환경 변수로 전달한다.
# Admin token과 전체 environment는 기록하지 않는다.
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

# k6가 실패해도 EXIT trap이 evidence 경로를 알리고 process를 정리할 수 있도록 exit code를 직접 보존한다.
set +e
k6 run "load/k6/${SCENARIO}.js"
scenario_exit=$?
set -e

exit "${scenario_exit}"
