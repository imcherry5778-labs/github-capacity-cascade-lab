#!/usr/bin/env bash
# L12는 실제 GitHub에 mutation하거나 host network를 바꾸지 않는다. 두 Forgejo fixture와
# disposable runner만 Docker internal network 안에서 사용한다.
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly L12_DIR="$ROOT_DIR/l12"
readonly COMPOSE_FILE="$L12_DIR/docker-compose.yml"
readonly RUNNER_IMAGE='capacity-cascade-l12/runner:15.0.9-13.1.0-go1.26.7'
readonly FORGEJO_IMAGE='codeberg.org/forgejo/forgejo:15.0.9'
readonly FORGEJO_RUNNER_IMAGE='code.forgejo.org/forgejo/runner:13.1.0'
readonly GO_IMAGE='golang:1.26.7'
readonly RUNTIME_DIR="${L12_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp}/capacity-cascade-l12-runtime}"
readonly RESULT_ROOT="$ROOT_DIR/results/delivery-continuity"
readonly LAB_USER='l12'
readonly LAB_OWNER='l12'

mode="${1:-}"

die() { printf 'L12: %s\n' "$*" >&2; exit 1; }
note() { printf 'L12: %s\n' "$*" >&2; }

require_tools() {
  local missing=0 tool
  for tool in git go docker curl jq sha256sum tar gzip awk sed grep find mktemp timeout date ruby od; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf '%-18s OK\n' "$tool"
    else
      printf '%-18s MISSING\n' "$tool" >&2
      missing=1
    fi
  done
  if docker info >/dev/null 2>&1; then
    printf '%-18s OK\n' 'docker daemon'
  else
    printf '%-18s UNAVAILABLE\n' 'docker daemon' >&2
    missing=1
  fi
  (( missing == 0 )) || return 1
  go version | grep -q 'go1.26.7' || die 'Go 1.26.7 is required for the selected L12 toolchain.'
}

project_name() { printf 'capacity-cascade-l12-r%s' "$1"; }
run_dir() { printf '%s/run-%s' "$RUNTIME_DIR" "$1"; }
compose() {
  local number="$1"
  shift
  docker compose --project-name "$(project_name "$number")" \
    --env-file "$(run_dir "$number")/compose.env" -f "$COMPOSE_FILE" "$@"
}

primary_port() { printf '%s' "$((15120 + $1 * 10 + 1))"; }
continuity_port() { printf '%s' "$((15120 + $1 * 10 + 2))"; }
witness_port() { printf '%s' "$((15120 + $1 * 10 + 3))"; }
candidate_port() { printf '%s' "$((15120 + $1 * 10 + 4))"; }
network_name() { printf 'capacity-cascade-l12-r%s-internal' "$1"; }
control_network_name() { printf 'capacity-cascade-l12-r%s-control' "$1"; }

ensure_runtime() {
  test -f "$RUNTIME_DIR/prepared-inputs.json" || die 'prepared inputs are absent; run make l12-prepare first.'
  test -f "$RUNTIME_DIR/source.sha" || die 'prepared source identity is absent; run make l12-prepare first.'
  test -f "$RUNTIME_DIR/vendor.tar.gz" || die 'prepared vendor bundle is absent; run make l12-prepare first.'
}

api_url() {
  local number="$1" fixture="$2"
  case "$fixture" in
    primary) printf 'http://127.0.0.1:%s' "$(primary_port "$number")" ;;
    continuity) printf 'http://127.0.0.1:%s' "$(continuity_port "$number")" ;;
    *) die "unknown fixture: $fixture" ;;
  esac
}

curl_auth() {
  local number="$1" fixture="$2"
  shift 2
  curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
    --netrc-file "$(run_dir "$number")/secrets/netrc" "$@" "$(api_url "$number" "$fixture")"
}

curl_to() {
  local number="$1" fixture="$2" path="$3"
  shift 3
  curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
    --netrc-file "$(run_dir "$number")/secrets/netrc" "$@" "$(api_url "$number" "$fixture")$path"
}

write_json() {
  local file="$1"
  shift
  jq -n "$@" >"$file"
}

write_build_block() {
  local file="$1"
  cat >"$file" <<'EOF'
        run: |
          set -eu
          work="$(mktemp -d)"
          trap 'rm -rf "$work"' EXIT
          git clone --no-checkout "$L12_SOURCE_URL" "$work/source"
          cd "$work/source"
          git checkout --detach "$L12_SOURCE_SHA"
          actual_source_sha="$(git rev-parse HEAD)"
          test "$actual_source_sha" = "$L12_SOURCE_SHA"
          printf 'L12_CHECKOUT_OK source_sha=%s source_url=%s\n' "$actual_source_sha" "$L12_SOURCE_URL"
          cd "$work"
          cat > "$work/l12-package.go" <<'GOPROG'
package main

import (
  "fmt"
  "io"
  "net/http"
  "os"
)

func main() {
  if len(os.Args) != 4 { panic("usage: l12-package {get|put} URL PATH") }
  method, url, path := os.Args[1], os.Args[2], os.Args[3]
  var body io.Reader
  if method == "put" {
    file, err := os.Open(path); if err != nil { panic(err) }; defer file.Close(); body = file
  } else if method != "get" { panic("unknown operation") }
  req, err := http.NewRequest(map[string]string{"get":"GET", "put":"PUT"}[method], url, body); if err != nil { panic(err) }
  req.SetBasicAuth(os.Getenv("L12_PACKAGE_USER"), os.Getenv("L12_PACKAGE_PASSWORD"))
  response, err := http.DefaultClient.Do(req); if err != nil { panic(err) }; defer response.Body.Close()
  if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusCreated { panic(fmt.Sprintf("package HTTP %d", response.StatusCode)) }
  if method == "get" { file, err := os.Create(path); if err != nil { panic(err) }; defer file.Close(); if _, err = io.Copy(file, response.Body); err != nil { panic(err) } }
          }
GOPROG
          export GOTOOLCHAIN=local
          go build -trimpath -o "$work/l12-package" "$work/l12-package.go"
          package_transfer() { "$work/l12-package" "$@"; }
          package_transfer get "$L12_PACKAGE_BASE/l12-prepared-inputs/$L12_SOURCE_SHA/prepared-inputs.json" prepared-inputs.json
          grep -Eq '"source_sha"[[:space:]]*:[[:space:]]*"'"$L12_SOURCE_SHA"'"' prepared-inputs.json
          grep -Eq '"vendor_tar_sha256"[[:space:]]*:[[:space:]]*"'"$L12_EXPECTED_VENDOR_SHA256"'"' prepared-inputs.json
          package_transfer get "$L12_PACKAGE_BASE/l12-prepared-inputs/$L12_SOURCE_SHA/vendor.tar.gz" vendor.tar.gz
          actual_vendor_sha256="$(sha256sum vendor.tar.gz | awk '{print $1}')"
          test "$actual_vendor_sha256" = "$L12_EXPECTED_VENDOR_SHA256"
          tar -xzf vendor.tar.gz -C "$work/source"
          test -f "$work/source/vendor/modules.txt"
          cd "$work/source"
          export GOCACHE="$work/go-build-cache"
          export GOMODCACHE="$work/empty-module-cache"
          export GONOSUMDB='*'
          export GOPROXY=off
          export GOSUMDB=off
          go test -mod=vendor ./...
          CGO_ENABLED=0 GOOS=linux go build -mod=vendor -trimpath -ldflags='-s -w' -o "$work/auth-sim" ./cmd/auth-sim
          binary_sha256="$(sha256sum "$work/auth-sim" | awk '{print $1}')"
          test -n "$L12_FORGEJO_RUN_ID"
          printf '{"artifact_version":"%s","binary_sha256":"%s","forgejo_run_id":"%s","scenario":"%s","source_sha":"%s","vendor_tar_sha256":"%s"}\n' "$L12_ARTIFACT_VERSION" "$binary_sha256" "$L12_FORGEJO_RUN_ID" "$L12_SCENARIO" "$actual_source_sha" "$actual_vendor_sha256" > "$work/artifact-manifest.json"
          package_transfer put "$L12_PACKAGE_BASE/l12-build/$L12_ARTIFACT_VERSION/auth-sim" "$work/auth-sim"
          package_transfer put "$L12_PACKAGE_BASE/l12-build/$L12_ARTIFACT_VERSION/artifact-manifest.json" "$work/artifact-manifest.json"
          printf 'L12_BUILD_OK source_sha=%s vendor_sha256=%s binary_sha256=%s artifact_version=%s\n' "$actual_source_sha" "$actual_vendor_sha256" "$binary_sha256" "$L12_ARTIFACT_VERSION"
EOF
}

render_workflow() {
  local template="$1" destination="$2" source_sha="$3" action_sha="$4" vendor_sha="$5" artifact_version="$6" block="$7"
  local intermediate
  intermediate="$(mktemp "$RUNTIME_DIR/workflow.XXXXXX")"
  sed -e "s/__SOURCE_SHA__/$source_sha/g" \
      -e "s/__ACTION_SHA__/$action_sha/g" \
      -e "s/__VENDOR_SHA256__/$vendor_sha/g" \
      -e "s/__ARTIFACT_PREFIX__/$artifact_version/g" \
      "$template" >"$intermediate"
  awk -v block="$block" '
    /run: __BUILD_SCRIPT__/ {
      prefix = $0
      sub(/[^ ].*$/, "", prefix)
      content_prefix = prefix "  "
      getline line < block
      print prefix "run: |"
      while ((getline line < block) > 0) {
        sub(/^          /, "", line)
        print content_prefix line
      }
      close(block)
      next
    }
    { print }
  ' "$intermediate" >"$destination"
  rm -f "$intermediate"
}

create_askpass() {
  local secret_dir="$1"
  cat >"$secret_dir/git-askpass" <<'EOF'
#!/bin/sh
case "$1" in
  *Username*) printf '%s' l12 ;;
  *Password*) cat "$L12_PASSWORD_FILE" ;;
  *) exit 1 ;;
esac
EOF
  chmod 0700 "$secret_dir/git-askpass"
}

git_push() {
  local number="$1" fixture="$2" repository="$3" local_repo="$4"
  local port
  if [[ "$fixture" == primary ]]; then port="$(primary_port "$number")"; else port="$(continuity_port "$number")"; fi
  L12_PASSWORD_FILE="$(run_dir "$number")/secrets/password" \
    GIT_ASKPASS="$(run_dir "$number")/secrets/git-askpass" GIT_TERMINAL_PROMPT=0 \
    git -C "$local_repo" push "http://l12@127.0.0.1:${port}/l12/${repository}.git" HEAD:refs/heads/main
}

create_user() {
  local number="$1" fixture="$2" container password_file
  container="$(compose "$number" ps -q "$fixture")"
  password_file="$(run_dir "$number")/secrets/password"
  docker cp "$password_file" "$container:/tmp/l12-password"
  docker exec "$container" chown 1000:1000 /tmp/l12-password
  compose "$number" exec -T --user 1000:1000 "$fixture" sh -ec '
    password="$(cat /tmp/l12-password)"
    rm -f /tmp/l12-password
    forgejo admin user create --admin --username l12 --password "$password" --email l12@example.invalid --must-change-password=false
  ' >/dev/null
}

create_repository() {
  local number="$1" fixture="$2" repository="$3" response status
  response="$(mktemp "$RUNTIME_DIR/repo-response.XXXXXX")"
  status="$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
    --netrc-file "$(run_dir "$number")/secrets/netrc" -H 'Content-Type: application/json' \
    --data "{\"name\":\"$repository\",\"private\":false,\"auto_init\":false,\"has_actions\":true}" \
    "$(api_url "$number" "$fixture")/api/v1/user/repos")"
  [[ "$status" == 201 ]] || { cat "$response" >&2; rm -f "$response"; die "cannot create $fixture/$repository (HTTP $status)"; }
  rm -f "$response"
}

wait_forgejo() {
  local number="$1" fixture="$2" attempt
  for attempt in $(seq 1 45); do
    if curl --fail --silent --show-error --max-time 2 "$(api_url "$number" "$fixture")/api/healthz" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  die "$fixture did not become healthy"
}

make_compose_env() {
  local number="$1" directory="$2"
  cat >"$directory/compose.env" <<EOF
L12_PRIMARY_PORT=$(primary_port "$number")
L12_CONTINUITY_PORT=$(continuity_port "$number")
L12_NETWORK_NAME=$(network_name "$number")
L12_CONTROL_NETWORK_NAME=$(control_network_name "$number")
EOF
}

start_fixtures() {
  local number="$1"
  compose "$number" up -d --wait
  wait_forgejo "$number" primary
  wait_forgejo "$number" continuity
}

package_put() {
  local number="$1" package="$2" version="$3" name="$4" local_file="$5" status
  status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --netrc-file "$(run_dir "$number")/secrets/netrc" --upload-file "$local_file" \
    "$(api_url "$number" continuity)/api/packages/$LAB_OWNER/generic/$package/$version/$name")"
  [[ "$status" == 201 ]] || die "package upload $package/$version/$name returned HTTP $status"
}

prepare_source_bundle() {
  local source_sha="$1" source_dir="$RUNTIME_DIR/source" empty_cache="$RUNTIME_DIR/prepare-empty-module-cache"
  git clone --no-checkout "$ROOT_DIR" "$source_dir" >/dev/null
  git -C "$source_dir" checkout --detach "$source_sha" >/dev/null
  [[ "$(git -C "$source_dir" rev-parse HEAD)" == "$source_sha" ]] || die 'prepared checkout SHA mismatch'
  (cd "$source_dir" && go mod vendor)
  (cd "$source_dir" && GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off GONOSUMDB='*' \
    GOMODCACHE="$empty_cache" GOCACHE="$RUNTIME_DIR/prepare-go-build-cache" \
    go test -mod=vendor ./... >/dev/null)
  (cd "$source_dir" && GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off GONOSUMDB='*' \
    GOMODCACHE="$empty_cache" GOCACHE="$RUNTIME_DIR/prepare-go-build-cache" \
    CGO_ENABLED=0 GOOS=linux go build -mod=vendor -trimpath -ldflags='-s -w' -o "$RUNTIME_DIR/witness-auth-sim" ./cmd/auth-sim)
  tar -C "$source_dir" -czf "$RUNTIME_DIR/vendor.tar.gz" vendor
  local go_mod_sha go_sum_sha vendor_sha
  go_mod_sha="$(sha256sum "$source_dir/go.mod" | awk '{print $1}')"
  go_sum_sha="$(sha256sum "$source_dir/go.sum" | awk '{print $1}')"
  vendor_sha="$(sha256sum "$RUNTIME_DIR/vendor.tar.gz" | awk '{print $1}')"
  printf '%s\n' "$source_sha" >"$RUNTIME_DIR/source.sha"
  jq -n --arg source_sha "$source_sha" --arg go_mod_sha256 "$go_mod_sha" --arg go_sum_sha256 "$go_sum_sha" \
    --arg vendor_tar_sha256 "$vendor_sha" --arg go_toolchain "$(go version)" \
    '{source_sha:$source_sha,go_mod_sha256:$go_mod_sha256,go_sum_sha256:$go_sum_sha256,vendor_tar_sha256:$vendor_tar_sha256,go_toolchain:$go_toolchain}' \
    >"$RUNTIME_DIR/prepared-inputs.json"
}

build_runner_image() {
  docker build --network none --pull=false -f "$L12_DIR/runner.Dockerfile" -t "$RUNNER_IMAGE" "$L12_DIR" >/dev/null
  docker run --rm --entrypoint sh "$RUNNER_IMAGE" -c 'go version; git --version; forgejo-runner --version' >/dev/null
}

create_action_repo() {
  local action_dir="$RUNTIME_DIR/action-source"
  mkdir -p "$action_dir"
  cp "$L12_DIR/l12-action/action.yml" "$action_dir/action.yml"
  git -C "$action_dir" init -b main >/dev/null
  git -C "$action_dir" config user.name 'L12 Fixture'
  git -C "$action_dir" config user.email 'l12-fixture@example.invalid'
  git -C "$action_dir" add action.yml
  git -C "$action_dir" commit -m 'feat: add l12 action marker' >/dev/null
  git -C "$action_dir" rev-parse HEAD
}

create_control_repo() {
  local number="$1" source_sha="$2" action_sha="$3" vendor_sha="$4" control_dir="$RUNTIME_DIR/control-source" block="$RUNTIME_DIR/build-block.yml"
  local name
  mkdir -p "$control_dir/.forgejo/workflows"
  write_build_block "$block"
  for name in primary-control source-unavailable action-unavailable prepared-continuity unprepared-revision; do
    render_workflow "$L12_DIR/workflows/$name.yml.tmpl" "$control_dir/.forgejo/workflows/$name.yml" \
      "$source_sha" "$action_sha" "$vendor_sha" "prepared-$name" "$block"
  done
  git -C "$control_dir" init -b main >/dev/null
  git -C "$control_dir" config user.name 'L12 Fixture'
  git -C "$control_dir" config user.email 'l12-fixture@example.invalid'
  git -C "$control_dir" add .forgejo
  git -C "$control_dir" commit -m 'feat: add prepared L12 control workflows' >/dev/null
}

prepare_one() {
  local number="$1" directory source_sha vendor_sha action_sha
  directory="$(run_dir "$number")"
  mkdir -p "$directory/secrets"
  chmod 0700 "$directory/secrets"
  make_compose_env "$number" "$directory"
  umask 077
  od -An -N 32 -tx1 /dev/urandom | tr -d ' \n' >"$directory/secrets/password"
  cat >"$directory/secrets/netrc" <<EOF
machine 127.0.0.1 login l12 password $(cat "$directory/secrets/password")
EOF
  chmod 0600 "$directory/secrets/password" "$directory/secrets/netrc"
  create_askpass "$directory/secrets"
  start_fixtures "$number"
  create_user "$number" primary
  create_user "$number" continuity
  for fixture in primary continuity; do
    create_repository "$number" "$fixture" app-source
    create_repository "$number" "$fixture" l12-action
  done
  create_repository "$number" continuity l12-control
  source_sha="$(cat "$RUNTIME_DIR/source.sha")"
  vendor_sha="$(jq -r .vendor_tar_sha256 "$RUNTIME_DIR/prepared-inputs.json")"
  git_push "$number" primary app-source "$RUNTIME_DIR/source"
  git_push "$number" continuity app-source "$RUNTIME_DIR/source"
  action_sha="$(cat "$RUNTIME_DIR/action.sha")"
  git_push "$number" primary l12-action "$RUNTIME_DIR/action-source"
  git_push "$number" continuity l12-action "$RUNTIME_DIR/action-source"
  git_push "$number" continuity l12-control "$RUNTIME_DIR/control-source"
  package_put "$number" l12-prepared-inputs "$source_sha" vendor.tar.gz "$RUNTIME_DIR/vendor.tar.gz"
  package_put "$number" l12-prepared-inputs "$source_sha" prepared-inputs.json "$RUNTIME_DIR/prepared-inputs.json"
  jq -n --arg project "$(project_name "$number")" --arg source_sha "$source_sha" --arg action_sha "$action_sha" \
    --arg vendor_tar_sha256 "$vendor_sha" --arg primary "$(api_url "$number" primary)" --arg continuity "$(api_url "$number" continuity)" \
    '{project:$project,source_sha:$source_sha,action_sha:$action_sha,vendor_tar_sha256:$vendor_tar_sha256,primary_api:$primary,continuity_api:$continuity}' \
    >"$directory/prepared.json"
}

prepare_all() {
  [[ ! -e "$RUNTIME_DIR" ]] || die "runtime state already exists at $RUNTIME_DIR; run make l12-clean before a new prepare."
  mkdir -p "$RUNTIME_DIR"
  chmod 0700 "$RUNTIME_DIR"
  local source_sha
  source_sha="${L12_SOURCE_SHA:-$(git -C "$ROOT_DIR" rev-parse main)}"
  git -C "$ROOT_DIR" cat-file -e "$source_sha^{commit}" || die 'selected source revision is not a commit'
  prepare_source_bundle "$source_sha"
  build_runner_image
  create_action_repo >"$RUNTIME_DIR/action.sha"
  create_control_repo 0 "$source_sha" "$(cat "$RUNTIME_DIR/action.sha")" "$(jq -r .vendor_tar_sha256 "$RUNTIME_DIR/prepared-inputs.json")"
  prepare_one 1
  prepare_one 2
  prepare_one 3
  jq -n --arg source_sha "$source_sha" --arg action_sha "$(cat "$RUNTIME_DIR/action.sha")" \
    --arg forgejo_server "$FORGEJO_IMAGE" --arg forgejo_runner "$FORGEJO_RUNNER_IMAGE" --arg go_image "$GO_IMAGE" \
    --arg server_digest "$(docker image inspect "$FORGEJO_IMAGE" --format '{{index .RepoDigests 0}}')" \
    --arg runner_digest "$(docker image inspect "$FORGEJO_RUNNER_IMAGE" --format '{{index .RepoDigests 0}}')" \
    --arg go_digest "$(docker image inspect "$GO_IMAGE" --format '{{index .RepoDigests 0}}')" \
    --arg vendor_tar_sha256 "$(jq -r .vendor_tar_sha256 "$RUNTIME_DIR/prepared-inputs.json")" \
    '{source_sha:$source_sha,action_sha:$action_sha,forgejo_server:$forgejo_server,forgejo_runner:$forgejo_runner,go_image:$go_image,server_digest:$server_digest,runner_digest:$runner_digest,go_digest:$go_digest,vendor_tar_sha256:$vendor_tar_sha256}' \
    >"$RUNTIME_DIR/metadata.json"
  note 'online preparation completed for three fresh fixture pairs; runtime state remains for smoke or verify.'
}

start_witness() {
  local number="$1" name="capacity-cascade-l12-witness-r$1" context="$RUNTIME_DIR/witness-context-r$1" image="capacity-cascade-l12/auth-sim-witness:r$1"
  mkdir -p "$context"
  cp "$RUNTIME_DIR/witness-auth-sim" "$context/auth-sim"
  cat >"$context/Dockerfile" <<'EOF'
FROM scratch
COPY auth-sim /auth-sim
USER 65532:65532
ENTRYPOINT ["/auth-sim"]
EOF
  docker build --network none -t "$image" "$context" >/dev/null
  docker run --detach --name "$name" --network "$(control_network_name "$number")" \
    --env LAB_PUBLIC_ADDR=0.0.0.0:8080 --env LAB_ADMIN_ADDR=0.0.0.0:9090 \
    --publish "127.0.0.1:$(witness_port "$number"):8080" "$image" >/dev/null
  docker network connect "$(network_name "$number")" "$name"
}

probe_runtime() {
  local port="$1" output="$2" health ready token
  health=false; ready=false; token=false
  curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:$port/healthz" >/dev/null && health=true || true
  curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:$port/readyz" >/dev/null && ready=true || true
  curl --fail --silent --show-error --max-time 5 -X POST "http://127.0.0.1:$port/token" >/dev/null && token=true || true
  jq -n --argjson health "$health" --argjson ready "$ready" --argjson token "$token" '{healthz:$health,readyz:$ready,token:$token,healthy:($health and $ready and $token)}' >"$output"
  [[ "$health" == true && "$ready" == true && "$token" == true ]]
}

runner_name() { printf 'capacity-cascade-l12-runner-r%s-%s' "$1" "$2"; }

start_runner() {
  local number="$1" scenario="$2" runner_token env_file name log_file
  runner_token="$(compose "$number" exec -T --user 1000:1000 continuity forgejo forgejo-cli actions generate-runner-token --scope l12/l12-control)"
  test -n "$runner_token" || die 'Forgejo did not return a repository-scoped runner token'
  env_file="$(run_dir "$number")/secrets/runner-$scenario.env"
  cat >"$env_file" <<EOF
L12_INSTANCE=http://continuity:3000
L12_PACKAGE_BASE=http://continuity:3000/api/packages/l12/generic
L12_PACKAGE_PASSWORD=$(cat "$(run_dir "$number")/secrets/password")
L12_PACKAGE_USER=l12
L12_RUNNER_TOKEN=$runner_token
EOF
  chmod 0600 "$env_file"
  name="$(runner_name "$number" "$scenario")"
  log_file="$3"
  docker run --detach --name "$name" --network "$(network_name "$number")" \
    --env-file "$env_file" "$RUNNER_IMAGE" sh -ec '
      cd /data
      umask 077
      printf "L12_PACKAGE_BASE=%s\nL12_PACKAGE_USER=%s\nL12_PACKAGE_PASSWORD=%s\n" \
        "$L12_PACKAGE_BASE" "$L12_PACKAGE_USER" "$L12_PACKAGE_PASSWORD" > .env
      forgejo-runner register --no-interactive --ephemeral --instance "$L12_INSTANCE" --token "$L12_RUNNER_TOKEN" --name "l12-disposable" --labels "l12-host:host"
      exec forgejo-runner one-job
    ' >/dev/null
  # The token is only required for registration; retain no token in result evidence.
  rm -f "$env_file"
  printf '%s' "$name"
}

runner_exit_code() {
  local name="$1" attempt status
  for attempt in $(seq 1 90); do
    status="$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || true)"
    if [[ "$status" == exited || "$status" == dead ]]; then
      docker inspect --format '{{.State.ExitCode}}' "$name" 2>/dev/null || printf '%s' 'unknown'
      return 0
    fi
    if [[ -z "$status" ]]; then
      # --rm removes a completed runner. The engine log was already streamed below.
      printf '%s' 'removed'
      return 0
    fi
    sleep 1
  done
  die "runner $name did not finish within 90 seconds"
}

runner_log() {
  local name="$1" destination="$2" attempt
  for attempt in $(seq 1 90); do
    docker logs "$name" >"$destination" 2>&1 || true
    if ! docker inspect "$name" >/dev/null 2>&1; then return 0; fi
    if docker inspect --format '{{.State.Running}}' "$name" 2>/dev/null | grep -qx false; then return 0; fi
    sleep 1
  done
  return 1
}

dispatch_workflow() {
  local number="$1" workflow="$2" inputs_json='{}' response request status
  if [[ $# -ge 3 && -n "$3" ]]; then inputs_json="$3"; fi
  response="$(mktemp "$RUNTIME_DIR/dispatch.XXXXXX")"
  request="$(mktemp "$RUNTIME_DIR/dispatch-body.XXXXXX")"
  jq -n --argjson inputs "$inputs_json" '{ref:"main",inputs:$inputs}' >"$request"
  status="$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
    --netrc-file "$(run_dir "$number")/secrets/netrc" -H 'Content-Type: application/json' \
    --data-binary "@$request" \
    "$(api_url "$number" continuity)/api/v1/repos/l12/l12-control/actions/workflows/$workflow/dispatches")"
  [[ "$status" == 204 ]] || { cat "$response" >&2; rm -f "$response" "$request"; die "workflow dispatch $workflow returned HTTP $status"; }
  rm -f "$response" "$request"
}

latest_workflow() {
  local number="$1" workflow_name="$2" destination="$3" all
  all="$(mktemp "$RUNTIME_DIR/runs.XXXXXX")"
  curl --fail --silent --show-error --netrc-file "$(run_dir "$number")/secrets/netrc" \
    "$(api_url "$number" continuity)/api/v1/repos/l12/l12-control/actions/runs?limit=30" >"$all"
  jq --arg name "$workflow_name" '[.workflow_runs[] | select(.title == $name)] | sort_by(.id) | last // empty' "$all" >"$destination"
  rm -f "$all"
  jq -e '.id != null' "$destination" >/dev/null || die "no workflow run found for $workflow_name"
}

workflow_job_log() {
  local number="$1" run_json="$2" destination="$3" run_id
  run_id="$(jq -r '.id' "$run_json")"
  curl --fail --silent --show-error --max-time 30 --netrc-file "$(run_dir "$number")/secrets/netrc" \
    "$(api_url "$number" continuity)/l12/l12-control/actions/runs/$run_id/jobs/0/attempt/1/logs" >"$destination"
}

network_probe() {
  local number="$1" destination="$2" local_ok=false public_blocked=false inspect
  inspect="$(docker network inspect "$(network_name "$number")")"
  jq -e '.[0].Internal == true' <<<"$inspect" >/dev/null
  docker run --rm --network "$(network_name "$number")" --entrypoint sh "$RUNNER_IMAGE" \
    -ec 'wget -q -T 5 -O /dev/null http://continuity:3000/api/healthz' && local_ok=true || true
  if docker run --rm --network "$(network_name "$number")" --entrypoint sh "$RUNNER_IMAGE" \
      -ec 'wget -q -T 5 -O /dev/null https://github.com'; then
    public_blocked=false
  else
    public_blocked=true
  fi
  jq -n --argjson docker_network_internal true --argjson local_forgejo_reachable "$local_ok" --argjson github_https_blocked "$public_blocked" \
    '{docker_network_internal:$docker_network_internal,local_forgejo_reachable:$local_forgejo_reachable,github_https_blocked:$github_https_blocked,passed:($docker_network_internal and $local_forgejo_reachable and $github_https_blocked)}' >"$destination"
  jq -e '.passed == true' "$destination" >/dev/null || die 'network isolation gate failed'
}

primary_stop() {
  local number="$1" destination="$2" source_sha action_sha health=false source_failed=false action_failed=false
  source_sha="$(cat "$RUNTIME_DIR/source.sha")"
  action_sha="$(cat "$RUNTIME_DIR/action.sha")"
  compose "$number" stop primary >/dev/null
  if curl --fail --silent --show-error --max-time 3 "$(api_url "$number" primary)/api/healthz" >/dev/null 2>&1; then health=true; fi
  if ! curl --fail --silent --show-error --max-time 3 "$(api_url "$number" primary)/l12/app-source.git/info/refs?service=git-upload-pack" >/dev/null 2>&1; then source_failed=true; fi
  if ! curl --fail --silent --show-error --max-time 3 "$(api_url "$number" primary)/l12/l12-action/archive/$action_sha.tar.gz" >/dev/null 2>&1; then action_failed=true; fi
  jq -n --arg outage_started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg source_sha "$source_sha" --arg action_sha "$action_sha" \
    --argjson primary_health_available "$health" --argjson primary_source_unavailable "$source_failed" --argjson primary_action_unavailable "$action_failed" \
    '{outage_started_at:$outage_started_at,source_sha:$source_sha,action_sha:$action_sha,primary_health_available:$primary_health_available,primary_source_unavailable:$primary_source_unavailable,primary_action_unavailable:$primary_action_unavailable} | . + {passed:((.primary_health_available|not) and .primary_source_unavailable and .primary_action_unavailable)}' >"$destination"
  jq -e '.passed == true' "$destination" >/dev/null || die 'primary outage was not proven'
}

primary_restore() {
  local number="$1"
  compose "$number" start primary >/dev/null
  wait_forgejo "$number" primary
}

package_download() {
  local number="$1" package="$2" version="$3" name="$4" destination="$5"
  curl --fail --silent --show-error --netrc-file "$(run_dir "$number")/secrets/netrc" \
    "$(api_url "$number" continuity)/api/packages/l12/generic/$package/$version/$name" >"$destination"
}

deploy_artifact() {
  local number="$1" scenario_dir="$2" version="$3" tamper="${4:-false}"
  local artifact_dir="$scenario_dir/cd" manifest binary expected_sha actual_sha source_sha image container context port
  artifact_dir="$scenario_dir/cd"
  mkdir -p "$artifact_dir"
  manifest="$artifact_dir/artifact-manifest.json"
  binary="$artifact_dir/auth-sim"
  package_download "$number" l12-build "$version" artifact-manifest.json "$manifest"
  package_download "$number" l12-build "$version" auth-sim "$binary"
  expected_sha="$(jq -r .binary_sha256 "$manifest")"
  source_sha="$(jq -r .source_sha "$manifest")"
  [[ "$source_sha" == "$(cat "$RUNTIME_DIR/source.sha")" ]] || die 'artifact source SHA differs from prepared source'
  if [[ "$tamper" == true ]]; then printf '\0' >>"$binary"; fi
  actual_sha="$(sha256sum "$binary" | awk '{print $1}')"
  if [[ "$expected_sha" != "$actual_sha" ]]; then
    jq -n --arg expected_sha256 "$expected_sha" --arg actual_sha256 "$actual_sha" --arg source_sha "$source_sha" \
      --argjson tampered "$tamper" '{expected_sha256:$expected_sha256,actual_sha256:$actual_sha256,source_sha:$source_sha,tampered:$tampered,deployment_started:false,passed_rejection:true}' \
    >"$scenario_dir/deployment.json"
    return 0
  fi
  chmod 0755 "$binary"
  context="$artifact_dir/image-context"
  mkdir -p "$context"
  cp "$binary" "$context/auth-sim"
  cat >"$context/Dockerfile" <<'EOF'
FROM scratch
COPY auth-sim /auth-sim
USER 65532:65532
ENTRYPOINT ["/auth-sim"]
EOF
  image="capacity-cascade-l12/auth-sim-candidate:r${number}-${version}"
  docker build --network none --label "org.opencontainers.image.revision=$source_sha" \
    --label "io.capacity-cascade.l12.artifact-sha256=$actual_sha" --label "io.capacity-cascade.l12.scenario=$version" \
    -t "$image" "$context" >/dev/null
  container="capacity-cascade-l12-candidate-r${number}"
  port="$(candidate_port "$number")"
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker run --detach --name "$container" --network "$(control_network_name "$number")" \
    --env LAB_PUBLIC_ADDR=0.0.0.0:8080 --env LAB_ADMIN_ADDR=0.0.0.0:9090 --publish "127.0.0.1:$port:8080" "$image" >/dev/null
  docker network connect "$(network_name "$number")" "$container"
  local attempt
  for attempt in $(seq 1 15); do
    if probe_runtime "$port" "$artifact_dir/runtime-probe.json"; then break; fi
    sleep 1
  done
  jq -e '.healthy == true' "$artifact_dir/runtime-probe.json" >/dev/null || die 'candidate deployment is not healthy'
  jq -n --arg expected_sha256 "$expected_sha" --arg actual_sha256 "$actual_sha" --arg source_sha "$source_sha" --arg image "$image" --arg container "$container" \
    --argjson tampered false --argjson deployment_started true --argjson runtime_healthy true \
    '{expected_sha256:$expected_sha256,actual_sha256:$actual_sha256,source_sha:$source_sha,image:$image,container:$container,tampered:$tampered,deployment_started:$deployment_started,runtime_healthy:$runtime_healthy,passed:true}' \
    >"$scenario_dir/deployment.json"
}

workflow_scenario() {
  local number="$1" scenario="$2" workflow="$3" expected="$4" result_dir="$5" inputs='{}'
  if [[ $# -ge 6 && -n "$6" ]]; then inputs="$6"; fi
  local scenario_dir="$result_dir/$scenario" runner log job_log run_json workflow_name runner_code witness
  scenario_dir="$result_dir/$scenario"
  mkdir -p "$scenario_dir"
  log="$scenario_dir/runner.log"
  job_log="$scenario_dir/workflow.log"
  dispatch_workflow "$number" "$workflow" "$inputs"
  runner="$(start_runner "$number" "$scenario" "$log")"
  runner_log "$runner" "$log" || true
  runner_code="$(runner_exit_code "$runner")"
  docker rm "$runner" >/dev/null 2>&1 || true
  case "$scenario" in
    primary-control|primary-restored) workflow_name='l12-primary-control' ;;
    source-unavailable) workflow_name='l12-source-unavailable' ;;
    action-unavailable) workflow_name='l12-action-unavailable' ;;
    prepared-continuity) workflow_name='l12-prepared-continuity' ;;
    unprepared-revision) workflow_name='l12-unprepared-revision' ;;
    *) die "unknown scenario $scenario" ;;
  esac
  run_json="$scenario_dir/workflow.json"
  latest_workflow "$number" "$workflow_name" "$run_json"
  workflow_job_log "$number" "$run_json" "$job_log"
  witness="$scenario_dir/existing-runtime.json"
  probe_runtime "$(witness_port "$number")" "$witness"
  jq -n --arg scenario "$scenario" --arg expected_outcome "$expected" --arg runner_exit_code "$runner_code" \
    --slurpfile workflow "$run_json" --slurpfile runtime "$witness" \
    '{scenario:$scenario,expected_outcome:$expected_outcome,runner_exit_code:$runner_exit_code,workflow_conclusion:($workflow[0].conclusion // $workflow[0].status // "unknown"),workflow_status:($workflow[0].status // "unknown"),existing_runtime_healthy:$runtime[0].healthy}' \
    >"$scenario_dir/contract.json"
}

assert_success_scenario() {
  local directory="$1"
  jq -e '.workflow_conclusion == "success" and .existing_runtime_healthy == true' "$directory/contract.json" >/dev/null
  rg -q 'L12_ACTION_MARKER' "$directory/workflow.log"
  rg -q 'L12_CHECKOUT_OK' "$directory/workflow.log"
  rg -q 'L12_BUILD_OK' "$directory/workflow.log"
}

assert_source_outage() {
  local directory="$1"
  jq -e '.workflow_conclusion == "failure" and .existing_runtime_healthy == true' "$directory/contract.json" >/dev/null
  rg -q 'L12_ACTION_MARKER origin=continuity' "$directory/workflow.log"
  ! rg -q 'L12_CHECKOUT_OK|L12_BUILD_OK' "$directory/workflow.log"
}

assert_action_outage() {
  local directory="$1"
  jq -e '.workflow_conclusion == "failure" and .existing_runtime_healthy == true' "$directory/contract.json" >/dev/null
  ! rg -q 'L12_CHECKOUT_OK|L12_BUILD_OK' "$directory/workflow.log"
}

create_unprepared_commit() {
  local number="$1" fixture_dir="$RUNTIME_DIR/unprepared-source-r$1" source_sha cnew
  source_sha="$(cat "$RUNTIME_DIR/source.sha")"
  git clone --no-checkout "$ROOT_DIR" "$fixture_dir" >/dev/null
  git -C "$fixture_dir" checkout --detach "$source_sha" >/dev/null
  git -C "$fixture_dir" config user.name 'L12 Fixture'
  git -C "$fixture_dir" config user.email 'l12-fixture@example.invalid'
  printf 'L12 synthetic fixture revision; not part of the repository history.\n' >"$fixture_dir/L12_UNPREPARED_FIXTURE.txt"
  git -C "$fixture_dir" add L12_UNPREPARED_FIXTURE.txt
  git -C "$fixture_dir" commit -m 'test: add unprepared L12 fixture revision' >/dev/null
  cnew="$(git -C "$fixture_dir" rev-parse HEAD)"
  git_push "$number" primary app-source "$fixture_dir" >/dev/null
  printf '%s' "$cnew"
}

mark_contract() {
  local file="$1" deployment="$2" passed="$3"
  local tmp
  tmp="$(mktemp "$RUNTIME_DIR/contract.XXXXXX")"
  jq --argjson new_deployment_started "$deployment" --argjson experiment_contract_passed "$passed" \
    '. + {new_deployment_started:$new_deployment_started,experiment_contract_passed:$experiment_contract_passed}' "$file" >"$tmp"
  mv "$tmp" "$file"
}

artifact_version_from_log() {
  local log="$1"
  rg -o 'artifact_version=[^[:space:]]+' "$log" | tail -n 1 | cut -d= -f2
}

remove_fixture_resources() {
  local number="$1" project containers
  project="$(project_name "$number")"
  if [[ -f "$(run_dir "$number")/compose.env" ]]; then
    compose "$number" down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  # Docker can retain a partially-created Compose container after a daemon restart.
  # These names and labels are owned exclusively by this learning-unit repetition.
  containers="$(docker ps -aq --filter "label=com.docker.compose.project=$project")"
  [[ -z "$containers" ]] || docker rm -f $containers >/dev/null 2>&1 || true
  docker volume rm "${project}_primary_data" "${project}_continuity_data" >/dev/null 2>&1 || true
  docker network rm "$(network_name "$number")" "$(control_network_name "$number")" >/dev/null 2>&1 || true
}

cleanup_one() {
  local number="$1" result_dir="$2" candidate witness containers networks volumes candidate_image witness_image credentials_removed=false
  candidate="capacity-cascade-l12-candidate-r${number}"
  witness="capacity-cascade-l12-witness-r${number}"
  docker rm -f "$candidate" "$witness" >/dev/null 2>&1 || true
  remove_fixture_resources "$number"
  candidate_image="$(jq -r '.prepared_continuity.cd.image // empty' "$result_dir/summary.json" 2>/dev/null || true)"
  witness_image="capacity-cascade-l12/auth-sim-witness:r${number}"
  [[ -z "$candidate_image" ]] || docker image rm "$candidate_image" >/dev/null 2>&1 || true
  docker image rm "$witness_image" >/dev/null 2>&1 || true
  if [[ -d "$(run_dir "$number")/secrets" ]]; then find "$(run_dir "$number")/secrets" -depth -delete; fi
  [[ ! -e "$(run_dir "$number")/secrets" ]] && credentials_removed=true
  containers="$(docker ps -aq --filter "name=^/capacity-cascade-l12-.*-r${number}" | wc -l | tr -d ' ')"
  networks="$(( $(docker network ls -q --filter "name=^$(network_name "$number")$" | wc -l | tr -d ' ') + $(docker network ls -q --filter "name=^$(control_network_name "$number")$" | wc -l | tr -d ' ') ))"
  volumes="$(docker volume ls -q --filter "name=^$(project_name "$number")_(primary|continuity)_data$" | wc -l | tr -d ' ')"
  jq -n --argjson remaining_owned_containers "$containers" --argjson remaining_owned_networks "$networks" --argjson remaining_owned_volumes "$volumes" \
    --argjson temporary_credentials_removed "$credentials_removed" \
    '{remaining_owned_containers:$remaining_owned_containers,remaining_owned_networks:$remaining_owned_networks,remaining_owned_volumes:$remaining_owned_volumes,temporary_credentials_removed:$temporary_credentials_removed} | . + {passed:(.remaining_owned_containers == 0 and .remaining_owned_networks == 0 and .remaining_owned_volumes == 0 and .temporary_credentials_removed)}' \
    >"$result_dir/cleanup.json"
  jq -e '.passed == true' "$result_dir/cleanup.json" >/dev/null || die "cleanup residue remains for repetition $number"
}

run_matrix() {
  local number="$1" result_dir="$2" source_sha action_sha vendor_sha cnew s3_version
  mkdir -p "$result_dir"
  source_sha="$(cat "$RUNTIME_DIR/source.sha")"
  action_sha="$(cat "$RUNTIME_DIR/action.sha")"
  vendor_sha="$(jq -r .vendor_tar_sha256 "$RUNTIME_DIR/prepared-inputs.json")"
  cp "$RUNTIME_DIR/metadata.json" "$result_dir/versions.json"
  cp "$RUNTIME_DIR/prepared-inputs.json" "$result_dir/prepared-inputs.json"
  jq -n --arg requested_source_sha "$source_sha" --arg continuity_source_sha "$source_sha" --arg action_sha "$action_sha" \
    '{requested_source_sha:$requested_source_sha,continuity_source_sha:$continuity_source_sha,action_sha:$action_sha}' >"$result_dir/source-revisions.json"
  network_probe "$number" "$result_dir/network-isolation.json"
  start_witness "$number"
  probe_runtime "$(witness_port "$number")" "$result_dir/witness-start.json"

  workflow_scenario "$number" primary-control primary-control.yml primary_available "$result_dir"
  assert_success_scenario "$result_dir/primary-control"
  mark_contract "$result_dir/primary-control/contract.json" false true

  cnew="$(create_unprepared_commit "$number")"
  [[ "$cnew" =~ ^[0-9a-f]{40}$ ]] || die 'synthetic unprepared revision is not a single commit SHA'
  primary_stop "$number" "$result_dir/outage-window.json"

  workflow_scenario "$number" source-unavailable source-unavailable.yml source_dependency_unavailable "$result_dir"
  assert_source_outage "$result_dir/source-unavailable"
  mark_contract "$result_dir/source-unavailable/contract.json" false true

  workflow_scenario "$number" action-unavailable action-unavailable.yml action_dependency_unavailable "$result_dir"
  assert_action_outage "$result_dir/action-unavailable"
  mark_contract "$result_dir/action-unavailable/contract.json" false true

  workflow_scenario "$number" prepared-continuity prepared-continuity.yml prepared_continuity "$result_dir"
  assert_success_scenario "$result_dir/prepared-continuity"
  s3_version="$(artifact_version_from_log "$result_dir/prepared-continuity/workflow.log")"
  test -n "$s3_version" || die 'prepared continuity workflow did not report an artifact version'
  deploy_artifact "$number" "$result_dir/prepared-continuity" "$s3_version"
  jq -e '.passed == true and .runtime_healthy == true' "$result_dir/prepared-continuity/deployment.json" >/dev/null
  mark_contract "$result_dir/prepared-continuity/contract.json" true true

  workflow_scenario "$number" unprepared-revision unprepared-revision.yml unprepared_revision "$result_dir" "{\"source_sha\":\"$cnew\"}"
  jq -e '.workflow_conclusion == "failure" and .existing_runtime_healthy == true' "$result_dir/unprepared-revision/contract.json" >/dev/null
  rg -q 'L12_ACTION_MARKER origin=continuity' "$result_dir/unprepared-revision/workflow.log"
  ! rg -q 'L12_CHECKOUT_OK|L12_BUILD_OK' "$result_dir/unprepared-revision/workflow.log"
  rg -q "$cnew" "$result_dir/unprepared-revision/workflow.log"
  mark_contract "$result_dir/unprepared-revision/contract.json" false true
  jq -n --arg requested_source_sha "$cnew" --arg prepared_source_sha "$source_sha" --argjson fallback_to_prepared_revision false --argjson deployment_started false --argjson existing_runtime_healthy true --argjson experiment_contract_passed true \
    '{requested_source_sha:$requested_source_sha,prepared_source_sha:$prepared_source_sha,fallback_to_prepared_revision:$fallback_to_prepared_revision,deployment_started:$deployment_started,existing_runtime_healthy:$existing_runtime_healthy,experiment_contract_passed:$experiment_contract_passed}' \
    >"$result_dir/safety-unprepared-revision.json"

  deploy_artifact "$number" "$result_dir/tampered-artifact" "$s3_version" true
  probe_runtime "$(witness_port "$number")" "$result_dir/tampered-artifact/existing-runtime.json"
  jq -e '.passed_rejection == true and .deployment_started == false' "$result_dir/tampered-artifact/deployment.json" >/dev/null
  jq -e '.healthy == true' "$result_dir/tampered-artifact/existing-runtime.json" >/dev/null
  cp "$result_dir/tampered-artifact/deployment.json" "$result_dir/safety-tampered-artifact.json"

  primary_restore "$number"
  workflow_scenario "$number" primary-restored primary-control.yml primary_restored "$result_dir"
  assert_success_scenario "$result_dir/primary-restored"
  mark_contract "$result_dir/primary-restored/contract.json" false true

  jq -n --slurpfile s0 "$result_dir/primary-control/contract.json" --slurpfile s1 "$result_dir/source-unavailable/contract.json" \
    --slurpfile s2 "$result_dir/action-unavailable/contract.json" --slurpfile s3 "$result_dir/prepared-continuity/contract.json" \
    --slurpfile s4 "$result_dir/primary-restored/contract.json" --slurpfile n1 "$result_dir/safety-unprepared-revision.json" --slurpfile n2 "$result_dir/safety-tampered-artifact.json" \
    --slurpfile cd "$result_dir/prepared-continuity/deployment.json" \
    '{primary_control:$s0[0],source_unavailable:$s1[0],action_unavailable:$s2[0],prepared_continuity:($s3[0] + {cd:$cd[0]}),primary_restored:$s4[0],unprepared_revision:$n1[0],tampered_artifact:$n2[0]}' \
    >"$result_dir/summary.json"
  cleanup_one "$number" "$result_dir"
}

result_metadata() {
  local destination="$1"
  jq -n --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg branch "$(git -C "$ROOT_DIR" branch --show-current)" \
    --arg head "$(git -C "$ROOT_DIR" rev-parse HEAD)" --argjson git_dirty "$(if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then printf true; else printf false; fi)" \
    '{generated_at:$generated_at,branch:$branch,head:$head,git_dirty:$git_dirty}' >"$destination"
}

verify_all() {
  ensure_runtime
  local timestamp result_dir number
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
  result_dir="$RESULT_ROOT/$timestamp"
  mkdir -p "$result_dir"
  result_metadata "$result_dir/metadata.json"
  for number in 1 2 3; do
    run_matrix "$number" "$result_dir/repetition-$number"
  done
  jq -n --slurpfile r1 "$result_dir/repetition-1/summary.json" --slurpfile r2 "$result_dir/repetition-2/summary.json" --slurpfile r3 "$result_dir/repetition-3/summary.json" \
    '{repetitions:[$r1[0],$r2[0],$r3[0]],all_contracts_passed:true}' >"$result_dir/comparison.json"
  cat >"$result_dir/summary.md" <<EOF
# L12 raw result

This is generated local evidence. It does not claim a production RTO/RPO or a GitHub production topology.

Source revision: $(cat "$RUNTIME_DIR/source.sha")
Action revision: $(cat "$RUNTIME_DIR/action.sha")
EOF
  # Secrets have no place in raw evidence. The state directory is removed only after all owned services are gone.
  find "$RUNTIME_DIR" -depth -delete
  note "three-repetition L12 matrix completed: $result_dir"
}

smoke() {
  ensure_runtime
  local timestamp result_dir
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)-smoke-$RANDOM"
  result_dir="$RESULT_ROOT/$timestamp"
  mkdir -p "$result_dir"
  result_metadata "$result_dir/metadata.json"
  network_probe 1 "$result_dir/network-isolation.json"
  start_witness 1
  workflow_scenario 1 primary-control primary-control.yml primary_available "$result_dir"
  assert_success_scenario "$result_dir/primary-control"
  mark_contract "$result_dir/primary-control/contract.json" false true
  jq -n --slurpfile control "$result_dir/primary-control/contract.json" '{primary_control:$control[0],smoke:true}' >"$result_dir/summary.json"
  cleanup_one 1 "$result_dir"
  prepare_one 1
  note "smoke completed: $result_dir"
}

clean() {
  local number
  for number in 1 2 3; do
    docker rm -f "capacity-cascade-l12-witness-r$number" "capacity-cascade-l12-candidate-r$number" >/dev/null 2>&1 || true
    remove_fixture_resources "$number"
    docker image rm "capacity-cascade-l12/auth-sim-witness:r$number" >/dev/null 2>&1 || true
  done
  docker image ls --format '{{.Repository}}:{{.Tag}}' | awk '/^capacity-cascade-l12\/auth-sim-candidate:/{print}' | while IFS= read -r image; do docker image rm "$image" >/dev/null 2>&1 || true; done
  docker image rm "$RUNNER_IMAGE" >/dev/null 2>&1 || true
  [[ ! -e "$RUNTIME_DIR" ]] || find "$RUNTIME_DIR" -depth -delete
  note 'owned L12 resources and temporary credentials removed; raw result directories were preserved.'
}

check() {
  require_tools
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/capacity-cascade-l12-check.XXXXXX")"
  trap 'find "$tmp" -depth -delete' RETURN
  L12_PRIMARY_PORT=15121 L12_CONTINUITY_PORT=15122 L12_NETWORK_NAME=capacity-cascade-l12-check-internal L12_CONTROL_NETWORK_NAME=capacity-cascade-l12-check-control \
    docker compose -f "$COMPOSE_FILE" config >"$tmp/compose.yml"
  ruby -e 'require "yaml"; ARGV.each { |file| YAML.load_stream(File.read(file)) }' "$L12_DIR"/workflows/*.yml.tmpl
  bash -n "$0"
  if rg -n ':latest|[[:space:]]latest[[:space:]]' "$L12_DIR"; then die 'latest image reference is forbidden in L12'; fi
  if rg -n '/var/run/docker\.sock|docker\.sock|privileged:[[:space:]]*true' "$L12_DIR"; then die 'runner host Docker socket or privileged execution is forbidden'; fi
  if rg -n '/home/[A-Za-z0-9_.-]+|/Users/[A-Za-z0-9_.-]+|kubeconfig|GITHUB_TOKEN|actions/checkout|setup-go|terraform|ansible|kind:[[:space:]]*(Deployment|Service|Pod|HorizontalPodAutoscaler)' "$L12_DIR"; then die 'private path, forbidden credential/action, or out-of-scope technology found'; fi
  if ! rg -q 'internal: true' "$COMPOSE_FILE"; then die 'L12 network must be Docker-internal'; fi
  if ! rg -q 'uses: http://.*@__ACTION_SHA__' "$L12_DIR"/workflows/*.yml.tmpl; then die 'lab action must use a fully-qualified, SHA-pinned template'; fi
  docker image inspect "$FORGEJO_IMAGE" "$FORGEJO_RUNNER_IMAGE" "$GO_IMAGE" >/dev/null
  docker build --network none --pull=false -f "$L12_DIR/runner.Dockerfile" -t "$RUNNER_IMAGE" "$L12_DIR" >/dev/null
  docker run --rm --entrypoint sh "$RUNNER_IMAGE" -c 'go version | grep -q go1.26.7; git --version; forgejo-runner --version' >/dev/null
  note 'static scope, selected images, Compose declaration, and disposable runner toolchain checks passed.'
}

case "$mode" in
  doctor) require_tools ;;
  check) check ;;
  prepare) require_tools; check; prepare_all ;;
  smoke) check; smoke ;;
  verify) check; verify_all ;;
  clean) clean ;;
  *) die 'usage: run-l12-delivery-continuity.sh {doctor|check|prepare|smoke|verify|clean}' ;;
esac
