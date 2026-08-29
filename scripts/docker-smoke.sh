#!/usr/bin/env bash
set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly IMAGE="${IMAGE:-capacity-cascade/auth-sim:dev}"
readonly CONTAINER="capacity-cascade-auth-sim-smoke-$$"

for required_tool in docker k6; do
  if ! command -v "${required_tool}" >/dev/null 2>&1; then
    printf 'required tool is missing: %s\n' "${required_tool}" >&2
    exit 127
  fi
done

cd "${PROJECT_ROOT}"

cleanup() {
  local exit_code=$?
  trap - EXIT
  set +e
  docker stop --time 5 "${CONTAINER}" >/dev/null 2>&1
  exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker run --detach --rm \
  --name "${CONTAINER}" \
  --env LAB_PUBLIC_ADDR=0.0.0.0:8080 \
  --publish 127.0.0.1::8080 \
  "${IMAGE}" >/dev/null

public_binding="$(docker port "${CONTAINER}" 8080/tcp)"
public_port="${public_binding##*:}"
base_url="http://127.0.0.1:${public_port}"

ready=0
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
  docker logs "${CONTAINER}" >&2 || true
  printf 'container smoke failed\n' >&2
  exit 1
fi

printf 'container smoke passed: %s\n' "${base_url}"
