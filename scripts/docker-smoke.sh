#!/usr/bin/env bash
# 명령 실패, 미정의 변수, pipeline 중간 실패를 즉시 반영한다.
set -euo pipefail

# 스크립트 위치를 기준으로 project root를 계산해 호출 디렉터리에 의존하지 않는다.
readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly IMAGE="${IMAGE:-capacity-cascade/auth-sim:dev}"
# PID를 포함한 소유 container 이름으로 다른 local 실행과 충돌하지 않게 한다.
readonly CONTAINER="capacity-cascade-auth-sim-smoke-$$"

# 필요한 도구가 없으면 image/container 상태를 바꾸기 전에 중단한다.
for required_tool in docker k6; do
  if ! command -v "${required_tool}" >/dev/null 2>&1; then
    printf 'required tool is missing: %s\n' "${required_tool}" >&2
    exit 127
  fi
done

cd "${PROJECT_ROOT}"

cleanup() {
  # Smoke 성공 여부와 관계없이 이 스크립트가 만든 container만 정리하고 원래 exit code를 보존한다.
  local exit_code=$?
  trap - EXIT
  set +e
  docker stop --time 5 "${CONTAINER}" >/dev/null 2>&1
  exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Host에서는 loopback의 무작위 port로만 공개해 충돌과 외부 노출을 피한다.
docker run --detach --rm \
  --name "${CONTAINER}" \
  --env LAB_PUBLIC_ADDR=0.0.0.0:8080 \
  --publish 127.0.0.1::8080 \
  "${IMAGE}" >/dev/null

public_binding="$(docker port "${CONTAINER}" 8080/tcp)"
public_port="${public_binding##*:}"
base_url="http://127.0.0.1:${public_port}"

ready=0
# Container 생성과 HTTP 준비 사이의 짧은 경쟁 구간을 bounded retry로 확인한다.
for _ in {1..20}; do
  if BASE_URL="${base_url}" k6 run --quiet load/k6/probe.js >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! docker inspect "${CONTAINER}" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

if [[ "${ready}" -ne 1 ]]; then
  # 실패한 경우에만 container 로그를 표시해 원인 분석 정보를 남긴다.
  docker logs "${CONTAINER}" >&2 || true
  printf 'container smoke failed\n' >&2
  exit 1
fi

printf 'container smoke passed: %s\n' "${base_url}"
