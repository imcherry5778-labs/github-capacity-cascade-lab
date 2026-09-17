#!/usr/bin/env bash
# L07 uses the L06 data path, changing exactly one mitigation mechanism per pair.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="${1:-matrix}"
CLUSTER="capacity-cascade-l07"
ISTIO_NS="istio-system"
LOAD_NS="capacity-cascade-l07-load"
K3S_IMAGE_VALUE="${K3S_IMAGE:-rancher/k3s:v1.35.5-k3s1}"
ISTIO_VERSION_VALUE="${ISTIO_VERSION:-1.30.4}"
K6_IMAGE_VALUE="${K6_IMAGE:-grafana/k6:2.2.0}"
HAPROXY_IMAGE_VALUE="${HAPROXY_IMAGE:-haproxy:3.2.23-alpine}"
APP_LATENCY="${APPLICATION_LATENCY_MS:-1000}"
REQUEST_TIMEOUT_VALUE="${REQUEST_TIMEOUT:-2s}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL_SECONDS:-1}"
SIDECAR_TARGET=1
cd "$ROOT"

cluster_exists() { k3d cluster list --no-headers 2>/dev/null | awk -v name="$CLUSTER" '$1==name {found=1} END {exit !found}'; }
remaining_containers() { docker ps -a --format '{{.Names}}' | awk -v p="k3d-$CLUSTER-" 'index($0,p)==1 {n++} END {print n+0}'; }
remaining_networks() { docker network ls --format '{{.Name}}' | awk -v n="k3d-$CLUSTER" '$0==n {c++} END {print c+0}'; }
owned_pids() { ps -eo pid=,comm=,args= | awk '$2=="kubectl" && /port-forward/ && /capacity-cascade-l07/ {print $1}'; }
cleanup_exact() {
  local pid
  while read -r pid; do [[ -n "$pid" && "$pid" != "$$" ]] && kill -TERM "$pid" 2>/dev/null || true; done < <(owned_pids)
  cluster_exists && k3d cluster delete "$CLUSTER"
  [[ "$(remaining_containers)" -eq 0 && "$(remaining_networks)" -eq 0 && -z "$(owned_pids)" ]]
}
if [[ "$ACTION" == clean ]]; then
  docker info >/dev/null
  cleanup_exact
  exit 0
fi
case "$ACTION" in m1|m2|m3|m4|matrix|smoke) ;; *) echo "usage: $0 {m1|m2|m3|m4|matrix|smoke|clean}" >&2; exit 2 ;; esac
for tool in git docker k3d kubectl helm k6 curl jq awk sed ruby ps; do command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 127; }; done
for image in "$K3S_IMAGE_VALUE" "$K6_IMAGE_VALUE" "$HAPROXY_IMAGE_VALUE"; do case "$image" in *:latest|latest) echo "latest is forbidden: $image" >&2; exit 2;; *:*) ;; *) echo "image tag required: $image" >&2; exit 2;; esac; done
[[ "$ISTIO_VERSION_VALUE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ISTIO_VERSION patch tag required" >&2; exit 2; }
docker info >/dev/null
if cluster_exists || [[ "$(remaining_containers)" -ne 0 || "$(remaining_networks)" -ne 0 || -n "$(owned_pids)" ]]; then
  echo "L07 resources already exist; inspect them and run make l07-clean" >&2
  exit 1
fi

SOURCE_COMMIT="$(git rev-parse HEAD)"
SOURCE_SHORT="$(git rev-parse --short=12 HEAD)"
GIT_DIRTY=false
[[ -n "$(git status --porcelain --untracked-files=normal)" ]] && GIT_DIRTY=true
[[ "$ACTION" != matrix || "$GIT_DIRTY" == false ]] || { echo "matrix requires clean source; use m1..m4 for exploratory runs" >&2; exit 1; }
AUTH_IMAGE="capacity-cascade/auth-sim:l07-$SOURCE_SHORT"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT="results/rca-mitigations/$STAMP"
i=1; while [[ -e "$RESULT" ]]; do RESULT="results/rca-mitigations/$STAMP-$i"; i=$((i+1)); done
mkdir -p "$RESULT"

ORIGINAL_CONTEXT="$(env -u KUBECONFIG kubectl config current-context 2>/dev/null || true)"
ORIGINAL_HELM_CONFIG="$(helm env HELM_REPOSITORY_CONFIG)"
ORIGINAL_HELM_HASH="$(test -f "$ORIGINAL_HELM_CONFIG" && sha256sum "$ORIGINAL_HELM_CONFIG" | awk '{print $1}' || echo absent)"
RUNTIME="$(mktemp -d "${TMPDIR:-/tmp}/capacity-cascade-l07.XXXXXX")"
KUBECONFIG="$RUNTIME/kubeconfig"
HELM_CONFIG_HOME="$RUNTIME/helm-config"
HELM_CACHE_HOME="$RUNTIME/helm-cache"
HELM_DATA_HOME="$RUNTIME/helm-data"
export KUBECONFIG HELM_CONFIG_HOME HELM_CACHE_HOME HELM_DATA_HOME
mkdir -p "$HELM_CONFIG_HOME" "$HELM_CACHE_HOME" "$HELM_DATA_HOME"
touch "$KUBECONFIG"; chmod 600 "$KUBECONFIG"
ADMIN_TOKEN="l07-$RANDOM-$RANDOM-$$"
ADMIN_PID=""; METRICS_PID=""; HAPROXY_PID=""; OBSERVER_PID=""; STOP_FILE=""
CLUSTER_CREATED=false; BASE_INSTALLED=false; ISTIOD_INSTALLED=false; CLEANING=false

stop_pid() { [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null && { kill -TERM "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }; }
stop_observer() {
  [[ -n "$STOP_FILE" ]] && touch "$STOP_FILE"
  [[ -n "$OBSERVER_PID" ]] && wait "$OBSERVER_PID" 2>/dev/null || true
  stop_pid "$ADMIN_PID"; stop_pid "$METRICS_PID"; stop_pid "$HAPROXY_PID"
  ADMIN_PID=""; METRICS_PID=""; HAPROXY_PID=""; OBSERVER_PID=""; STOP_FILE=""
}
finish() {
  local code="$?"
  [[ "$CLEANING" == true ]] && exit "$code"
  CLEANING=true; set +e; stop_observer
  if [[ "$CLUSTER_CREATED" == true ]]; then
    kubectl delete namespace "$LOAD_NS" --ignore-not-found >"$RESULT/load-namespace-delete.log" 2>&1
    [[ "$ISTIOD_INSTALLED" == true ]] && helm uninstall istiod --namespace "$ISTIO_NS" >"$RESULT/istiod-uninstall.log" 2>&1
    [[ "$BASE_INSTALLED" == true ]] && helm uninstall istio-base --namespace "$ISTIO_NS" >"$RESULT/istio-base-uninstall.log" 2>&1
    k3d cluster delete "$CLUSTER" >"$RESULT/cluster-delete.log" 2>&1
  fi
  rm -rf "$RUNTIME"
  local context_after helm_hash containers networks pids
  context_after="$(env -u KUBECONFIG kubectl config current-context 2>/dev/null || true)"
  helm_hash="$(test -f "$ORIGINAL_HELM_CONFIG" && sha256sum "$ORIGINAL_HELM_CONFIG" | awk '{print $1}' || echo absent)"
  containers="$(remaining_containers)"; networks="$(remaining_networks)"; pids="$(owned_pids | awk 'NF{n++} END{print n+0}')"
  jq -n --argjson runner_exit_code "$code" --argjson cluster_removed "$([[ "$containers" -eq 0 && "$networks" -eq 0 ]] && echo true || echo false)" --argjson remaining_owned_containers "$containers" --argjson remaining_owned_networks "$networks" --argjson remaining_owned_port_forwards "$pids" --argjson temporary_kubeconfig_removed "$([[ ! -e "$RUNTIME" ]] && echo true || echo false)" --argjson original_context_unchanged "$([[ "$context_after" == "$ORIGINAL_CONTEXT" ]] && echo true || echo false)" --argjson original_helm_repository_config_unchanged "$([[ "$helm_hash" == "$ORIGINAL_HELM_HASH" ]] && echo true || echo false)" '{runner_exit_code:$runner_exit_code,cluster_removed:$cluster_removed,remaining_owned_containers:$remaining_owned_containers,remaining_owned_networks:$remaining_owned_networks,remaining_owned_port_forwards:$remaining_owned_port_forwards,temporary_kubeconfig_removed:$temporary_kubeconfig_removed,original_context_unchanged:$original_context_unchanged,original_helm_repository_config_unchanged:$original_helm_repository_config_unchanged}' >"$RESULT/cleanup.json"
  exit "$code"
}
trap finish EXIT INT TERM

start_forward() {
  local namespace="$1" object="$2" remote="$3" log="$4" pid_name="$5" port_name="$6" pid port=""
  kubectl port-forward --namespace "$namespace" "$object" ":$remote" >"$log" 2>&1 & pid=$!
  for n in {1..80}; do port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) ->.*/\1/p' "$log" | head -n1)"; [[ -n "$port" ]] && break; kill -0 "$pid" 2>/dev/null || break; sleep .1; done
  [[ -n "$port" ]] || return 1
  printf -v "$pid_name" '%s' "$pid"; printf -v "$port_name" '%s' "$port"
}
wait_url() { for n in {1..80}; do curl -fsS "$1" >/dev/null 2>&1 && return 0; sleep .25; done; return 1; }
put_fault() { curl -fsS -X PUT -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' --data "$2" "$1/admin/fault" >"$3"; }
stat() { awk -F': ' -v name="$2" '$1==name {print $2+0;ok=1;exit} END{if(!ok)print 0}' "$1"; }
stat_name() {
  local found
  found="$(awk -F': ' -v prefix="$2" -v suffix="$3" 'index($1,prefix)==1 && substr($1,length($1)-length(suffix)+1)==suffix {print $1}' "$1" | sort -u)"
  [[ "$(echo "$found" | awk 'NF{n++} END{print n+0}')" -eq 1 ]] || return 1
  echo "$found"
}
proxy_stats() { kubectl exec --namespace "$1" "$2" -c istio-proxy -- pilot-agent request GET 'stats?filter=8080' >"$3"; }
prom_sum() { awk -v metric="$2" -v filter="${3:-}" 'index($0,metric)==1 && $0 !~ /^#/ && (filter=="" || index($0,filter)>0) {x+=$NF} END{printf "%.0f",x+0}' "$1"; }
haproxy() {
  awk -F, -v px="$2" -v sv="$3" -v field="$4" 'NR==1{sub(/^#[[:space:]]*/,"",$1);for(i=1;i<=NF;i++)c[$i]=i;next} $c["pxname"]==px && $c["svname"]==sv {print $(c[field])+0;ok=1;exit} END{if(!ok)print 0}' "$1"
}
phase() {
  local elapsed=$(( $(date +%s)-WORKLOAD_START ))
  if [[ "$1" == ramp-steep ]]; then
    ((elapsed<30)) && echo stable || { ((elapsed<31)) && echo ramp-up || { ((elapsed<70)) && echo peak || { ((elapsed<71)) && echo ramp-down || { ((elapsed<100)) && echo recovery || echo after; }; }; }; }
  else
    ((elapsed<20)) && echo stable || { ((elapsed<80)) && echo ramp-up || { ((elapsed<100)) && echo ramp-down || echo after; }; }
  fi
}
discover() {
  local ns="$1" pod="$2" dir="$3" dump cluster hcm retry_count retry_budget
  dump="$dir/proxy-config-dump.json"
  kubectl exec --namespace "$ns" "$pod" -c istio-proxy -- pilot-agent request GET config_dump >"$dump"
  kubectl exec --namespace "$ns" "$pod" -c istio-proxy -- pilot-agent request GET server_info >"$dir/proxy-server-info.json"
  kubectl exec --namespace "$ns" "$pod" -c istio-proxy -- pilot-agent request GET stats >"$dir/proxy-stats-inventory.txt"
  cluster="$(jq -r '..|objects|select(has("circuit_breakers"))|(.name? // empty)|select(test("^inbound[|]8080[|]"))' "$dump" | sort -u)"
  [[ "$(echo "$cluster" | awk 'NF{n++}END{print n+0}')" -eq 1 ]] || return 1
  jq --arg n "$cluster" '..|objects|select((.name? // "")==$n and has("circuit_breakers"))' "$dump" >"$dir/target-inbound-cluster.json"
  [[ "$(jq -r '.circuit_breakers.thresholds[]|select((.priority//"DEFAULT")=="DEFAULT")|.max_requests' "$dir/target-inbound-cluster.json" | head -n1)" == "$SIDECAR_TARGET" ]] || return 1
  hcm="$(jq -r '..|objects|select(((.filter_chain_match?.destination_port? // "")|tostring)=="8080")|.filters[]?.typed_config?|select((."@type"? // "")|endswith("HttpConnectionManager"))|.stat_prefix // empty' "$dump" | sort -u)"
  [[ "$(echo "$hcm" | awk 'NF{n++}END{print n+0}')" -eq 1 ]] || return 1
  jq '[..|objects|select(((.filter_chain_match?.destination_port? // "")|tostring)=="8080")|.filters[]?.typed_config?|select((."@type"? // "")|endswith("HttpConnectionManager"))]' "$dump" >"$dir/target-inbound-http-config.json"
  retry_count="$(jq '[..|objects|select(has("retry_policy"))]|length' "$dir/target-inbound-http-config.json")"; retry_budget="$(jq '[..|objects|.retry_policy?.num_retries? // empty]|max // 0' "$dir/target-inbound-http-config.json")"
  [[ "$retry_count" -eq 0 && "$retry_budget" -eq 0 ]] || return 1
  jq -n --arg cluster "$cluster" --arg hcm "$hcm" --arg down_total "$(stat_name "$dir/proxy-stats-inventory.txt" "http.$hcm" '.downstream_rq_total')" --arg down_active "$(stat_name "$dir/proxy-stats-inventory.txt" "http.$hcm" '.downstream_rq_active')" --arg upstream_total "$(stat_name "$dir/proxy-stats-inventory.txt" "cluster.$cluster" '.upstream_rq_total')" --arg upstream_active "$(stat_name "$dir/proxy-stats-inventory.txt" "cluster.$cluster" '.upstream_rq_active')" --arg overflow "$(stat_name "$dir/proxy-stats-inventory.txt" "cluster.$cluster" '.upstream_rq_active_overflow')" --arg pending "$(stat_name "$dir/proxy-stats-inventory.txt" "cluster.$cluster" '.upstream_rq_pending_overflow')" --arg retry "$(stat_name "$dir/proxy-stats-inventory.txt" "cluster.$cluster" '.upstream_rq_retry')" --arg timeout "$(stat_name "$dir/proxy-stats-inventory.txt" "cluster.$cluster" '.upstream_rq_timeout')" '{cluster:$cluster,hcm_stat_prefix:$hcm,proxy_downstream_total:$down_total,proxy_downstream_active:$down_active,proxy_upstream_total:$upstream_total,proxy_upstream_active:$upstream_active,proxy_active_overflow:$overflow,proxy_pending_overflow:$pending,proxy_retry:$retry,proxy_timeout:$timeout}' >"$dir/proxy-metric-mapping.json"
}
sample() {
  local scenario="$1" ns="$2" pod="$3" metrics="$4" stats_url="$5" map="$6" file="$7" step="${8:-}" p a h hp pods ends
  [[ -n "$step" ]] || step="$(phase "$scenario")"
  p="$file.proxy"; a="$file.app"; h="$file.haproxy"; hp="$file.hpa"; pods="$file.pods"; ends="$file.ends"
  curl -fsS "$metrics/metrics" >"$a"; proxy_stats "$ns" "$pod" "$p"; curl -fsS "$stats_url/stats;csv" >"$h"; kubectl get hpa auth-sim-scaling --namespace "$ns" -o json >"$hp"; kubectl get pods --namespace "$ns" --selector app.kubernetes.io/instance=auth-sim -o json >"$pods"; kubectl get endpointslice --namespace "$ns" --selector kubernetes.io/service-name=auth-sim -o json >"$ends"
  local in_flight tokens admission down active upstream upactive overflow pending retry timeout qcur qmax scur smax stot h5 denied
  in_flight="$(prom_sum "$a" capacity_cascade_http_in_flight)"; tokens="$(prom_sum "$a" capacity_cascade_http_requests_total 'route="/token"')"; admission="$(prom_sum "$a" capacity_cascade_admission_rejections_total)"
  down="$(stat "$p" "$(jq -r .proxy_downstream_total "$map")")"; active="$(stat "$p" "$(jq -r .proxy_downstream_active "$map")")"; upstream="$(stat "$p" "$(jq -r .proxy_upstream_total "$map")")"; upactive="$(stat "$p" "$(jq -r .proxy_upstream_active "$map")")"; overflow="$(stat "$p" "$(jq -r .proxy_active_overflow "$map")")"; pending="$(stat "$p" "$(jq -r .proxy_pending_overflow "$map")")"; retry="$(stat "$p" "$(jq -r .proxy_retry "$map")")"; timeout="$(stat "$p" "$(jq -r .proxy_timeout "$map")")"
  qcur="$(haproxy "$h" auth_sim BACKEND qcur)"; qmax="$(haproxy "$h" auth_sim BACKEND qmax)"; scur="$(haproxy "$h" auth_sim BACKEND scur)"; smax="$(haproxy "$h" auth_sim BACKEND smax)"; stot="$(haproxy "$h" auth_sim BACKEND stot)"; h5="$(haproxy "$h" auth_sim BACKEND hrsp_5xx)"; denied="$(haproxy "$h" public FRONTEND dreq)"
  jq -cn --arg timestamp_utc "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" --arg scenario "$scenario" --arg phase "$step" --argjson inf "$in_flight" --argjson tokens "$tokens" --argjson admission "$admission" --argjson down "$down" --argjson active "$active" --argjson upstream "$upstream" --argjson upactive "$upactive" --argjson overflow "$overflow" --argjson pending "$pending" --argjson retry "$retry" --argjson timeout "$timeout" --argjson qcur "$qcur" --argjson qmax "$qmax" --argjson scur "$scur" --argjson smax "$smax" --argjson stot "$stot" --argjson h5 "$h5" --argjson denied "$denied" --slurpfile hpa "$hp" --slurpfile pods "$pods" --slurpfile ends "$ends" '($hpa[0]) as $h|($pods[0]) as $p|($ends[0]) as $e|{timestamp_utc:$timestamp_utc,scenario:$scenario,phase:$phase,hpa:{current_replicas:($h.status.currentReplicas//0),desired_replicas:($h.status.desiredReplicas//0),current_metrics:($h.status.currentMetrics//[]),conditions:($h.status.conditions//[])},haproxy:{queue_current:$qcur,queue_max:$qmax,sessions_current:$scur,sessions_max:$smax,sessions_total:$stot,responses_5xx:$h5,denied_requests:$denied},proxy:{downstream_total:$down,downstream_active:$active,upstream_total:$upstream,upstream_active:$upactive,active_overflow:$overflow,pending_overflow:$pending,retry:$retry,timeout:$timeout},application:{in_flight:$inf,token_requests:$tokens,admission_rejections:$admission},pods:($p.items|map({name:.metadata.name,ready:([.status.conditions[]?|select(.type=="Ready" and .status=="True")]|length==1)})),endpoints_ready:([$e.items[]?.endpoints[]?|select(.conditions.ready==true)]|length)}' >>"$file"
}
observe() { while [[ ! -e "$8" ]]; do sample "$1" "$2" "$3" "$4" "$5" "$6" "$7"; sleep "$SAMPLE_INTERVAL"; done; }
idle() { for n in {1..80}; do proxy_stats "$1" "$2" "$4"; [[ "$(stat "$4" "$(jq -r .proxy_upstream_active "$3")")" -eq 0 && "$(stat "$4" "$(jq -r .proxy_downstream_active "$3")")" -eq 0 ]] && return 0; sleep .1; done; return 1; }

run_k6() {
  local scenario="$1" ns="$2" dir="$3" proxy_image="$4" cm job fqdn pod
  cm="l07-k6-$scenario"; job="l07-k6-$scenario"; fqdn="l07-haproxy.$ns.svc.cluster.local"
  kubectl create configmap "$cm" --namespace "$LOAD_NS" --from-file=l07.js="$ROOT/load/k6/l07.js" --from-file=config.js="$ROOT/load/k6/lib/config.js" --from-file=retry.js="$ROOT/load/k6/lib/retry.js" --from-file=summary.js="$ROOT/load/k6/lib/summary.js" --dry-run=client -o yaml >"$dir/k6-configmap.yaml"; kubectl apply -f "$dir/k6-configmap.yaml" >"$dir/k6-configmap-apply.log"
  cat >"$dir/k6-job.yaml" <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: $job, namespace: $LOAD_NS, labels: {capacity-cascade-lab/owner: l07, capacity-cascade-lab/scenario: $scenario}}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 420
  template:
    metadata: {labels: {capacity-cascade-lab/owner: l07, capacity-cascade-lab/scenario: $scenario, sidecar.istio.io/inject: "false"}}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext: {fsGroup: 12345}
      containers:
        - name: k6
          image: $K6_IMAGE_VALUE
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh", "-c"]
          args: ["set +e; k6 version > /results/k6-version.txt; k6 run /scripts/l07.js; code=\$?; echo \$code > /results/k6.exit; touch /results/k6.done; while [ ! -f /results/collected ]; do sleep 1; done; exit \$code"]
          env:
            - {name: BASE_URL, value: "http://$fqdn:8080"}
            - {name: RESULT_DIR, value: "/results"}
            - {name: STARTED_AT_UTC, value: "$STARTED_AT"}
            - {name: GIT_COMMIT, value: "$SOURCE_COMMIT"}
            - {name: GIT_DIRTY, value: "$GIT_DIRTY"}
            - {name: GO_VERSION, value: "not-used"}
            - {name: K6_VERSION, value: "$K6_IMAGE_VALUE"}
            - {name: DOCKER_VERSION, value: "not-used"}
            - {name: LAB_OS, value: "linux-container"}
            - {name: LAB_ARCH, value: "amd64"}
            - {name: L07_SCENARIO, value: "$scenario"}
            - {name: L07_SMOKE, value: "$([[ "$ACTION" == smoke ]] && echo 1 || echo 0)"}
            - {name: REQUEST_TIMEOUT, value: "$REQUEST_TIMEOUT_VALUE"}
            - {name: APPLICATION_LATENCY_MS, value: "$APP_LATENCY"}
            - {name: FAULT_SEED, value: "17082026"}
            - {name: LOGICAL_ID_NAMESPACE, value: "l07-$scenario"}
            - {name: MAX_ATTEMPTS, value: "3"}
            - {name: BACKOFF_BASE_MS, value: "100"}
            - {name: BACKOFF_MAX_MS, value: "400"}
            - {name: SIDECAR_ACTIVE_REQUEST_TARGET, value: "$SIDECAR_TARGET"}
            - {name: AUTH_SIM_IMAGE, value: "$AUTH_IMAGE"}
            - {name: HAPROXY_IMAGE, value: "$HAPROXY_IMAGE_VALUE"}
            - {name: K6_IMAGE, value: "$K6_IMAGE_VALUE"}
            - {name: ISTIO_PROXY_IMAGE, value: "$proxy_image"}
          securityContext: {runAsNonRoot: true, runAsUser: 12345, runAsGroup: 12345, allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
          volumeMounts:
            - {name: scripts, mountPath: /scripts/l07.js, subPath: l07.js, readOnly: true}
            - {name: scripts, mountPath: /scripts/lib/config.js, subPath: config.js, readOnly: true}
            - {name: scripts, mountPath: /scripts/lib/retry.js, subPath: retry.js, readOnly: true}
            - {name: scripts, mountPath: /scripts/lib/summary.js, subPath: summary.js, readOnly: true}
            - {name: results, mountPath: /results}
      volumes: [{name: scripts, configMap: {name: $cm}}, {name: results, emptyDir: {}}]
EOF
  WORKLOAD_START="$(date +%s)"; kubectl apply -f "$dir/k6-job.yaml" >"$dir/k6-job-apply.log"
  for n in {1..60}; do pod="$(kubectl get pods --namespace "$LOAD_NS" --selector job-name="$job" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"; [[ -n "$pod" ]] && break; sleep .2; done
  [[ -n "$pod" ]] || return 1; kubectl get pod "$pod" --namespace "$LOAD_NS" -o json >"$dir/k6-pod.json"; [[ "$(jq '[.spec.containers[].name]|index("istio-proxy")' "$dir/k6-pod.json")" == null ]] || return 1
  for n in {1..840}; do kubectl exec --namespace "$LOAD_NS" "$pod" -c k6 -- test -f /results/k6.done >/dev/null 2>&1 && break; sleep .5; done
  kubectl logs --namespace "$LOAD_NS" "$pod" -c k6 >"$dir/k6-console.log" 2>&1 || true
  kubectl exec --namespace "$LOAD_NS" "$pod" -c k6 -- cat /results/k6.exit >"$dir/k6.exit"; kubectl exec --namespace "$LOAD_NS" "$pod" -c k6 -- cat /results/metadata.json >"$dir/k6-metadata.json"; kubectl exec --namespace "$LOAD_NS" "$pod" -c k6 -- cat /results/k6-summary.json >"$dir/k6-summary.json"; kubectl exec --namespace "$LOAD_NS" "$pod" -c k6 -- cat /results/summary.md >"$dir/k6-summary.md"
  kubectl exec --namespace "$LOAD_NS" "$pod" -c k6 -- touch /results/collected >"$dir/k6-collected.log"; kubectl wait --for=condition=complete job/"$job" --namespace "$LOAD_NS" --timeout=60s >"$dir/k6-job-wait.log"; [[ "$(tr -d '[:space:]' <"$dir/k6.exit")" == 0 ]]
}
contract() {
  local scenario="$1" dir="$2" s="$dir/k6-summary.json" samples="$dir/samples.jsonl" logical physical retries failure p95 dropped s429 s503 desired current overflow sessions h5 denied final_active final_sessions final_queue validation_mode pass=false
  logical="$(jq -r .metrics.logical_requests.values.count "$s")"; physical="$(jq -r .metrics.physical_attempts.values.count "$s")"; retries="$(jq -r '.metrics.retry_attempts.values.count//0' "$s")"; failure="$(jq -r .metrics.logical_failures.values.rate "$s")"; p95="$(jq -r '.metrics.logical_request_duration.values["p(95)"]' "$s")"; dropped="$(jq -r '.metrics.dropped_iterations.values.count//0' "$s")"; s429="$(jq -r '.metrics.downstream_responses_429.values.count//0' "$s")"; s503="$(jq -r '.metrics.downstream_responses_503.values.count//0' "$s")"
  desired="$(jq -s '[.[].hpa.desired_replicas]|max//0' "$samples")"; current="$(jq -s '[.[].hpa.current_replicas]|max//0' "$samples")"; overflow="$(jq -s '(.[-1].proxy.active_overflow//0)-(.[0].proxy.active_overflow//0)' "$samples")"; sessions="$(jq -s '(.[-1].haproxy.sessions_total//0)-(.[0].haproxy.sessions_total//0)' "$samples")"; h5="$(jq -s '(.[-1].haproxy.responses_5xx//0)-(.[0].haproxy.responses_5xx//0)' "$samples")"; denied="$(jq -s '(.[-1].haproxy.denied_requests//0)-(.[0].haproxy.denied_requests//0)' "$samples")"; final_active="$(jq -s '.[-1].proxy.upstream_active+.[-1].proxy.downstream_active' "$samples")"; final_sessions="$(jq -s '.[-1].haproxy.sessions_current' "$samples")"; final_queue="$(jq -s '.[-1].haproxy.queue_current' "$samples")"
  [[ "$dropped" -eq 0 && "$final_active" -eq 0 && "$final_sessions" -eq 0 && "$final_queue" -eq 0 ]] && pass=true
  if [[ "$ACTION" != smoke ]]; then
    [[ "$scenario" != retry-immediate && "$scenario" != retry-backoff || "$retries" -gt 0 && "$physical" -gt "$logical" ]] || pass=false
    [[ "$scenario" != shedding-429 || "$s429" -gt 0 && "$denied" -gt 0 ]] || pass=false
    [[ "$scenario" != scaling-aware || "$desired" -gt 1 && "$current" -gt 1 ]] || pass=false
  fi
  validation_mode="mechanism-and-recovery"; [[ "$ACTION" == smoke ]] && validation_mode="path-and-recovery"
  jq -n --argjson passed "$pass" --arg scenario "$scenario" --arg validation_mode "$validation_mode" --argjson logical "$logical" --argjson physical "$physical" --argjson retries "$retries" --argjson failure "$failure" --argjson p95 "$p95" --argjson dropped "$dropped" --argjson s429 "$s429" --argjson s503 "$s503" --argjson desired "$desired" --argjson current "$current" --argjson overflow "$overflow" --argjson sessions "$sessions" --argjson h5 "$h5" --argjson denied "$denied" '{passed:$passed,scenario:$scenario,validation_mode:$validation_mode,k6:{logical_requests:$logical,physical_attempts:$physical,retry_attempts:$retries,logical_failure_rate:$failure,logical_p95_ms:$p95,dropped_iterations:$dropped,status:{"429":$s429,"503":$s503}},hpa:{desired_replicas_max:$desired,current_replicas_max:$current},sidecar:{active_overflow_delta:$overflow},haproxy:{backend_sessions_delta:$sessions,backend_responses_5xx_delta:$h5,denied_requests_delta:$denied},sampling:{recovery_idle:true}}' >"$dir/contract.json"
  [[ "$pass" == true || "$ACTION" == smoke ]]
}
run_scenario() {
  local scenario="$1" ns dir hpa haproxy_config app_url metrics_url stats_url pod proxy_image port
  ns="capacity-cascade-l07-$scenario"; dir="$RESULT/$scenario"; hpa="$ROOT/l07/hpa-blind.yaml"; haproxy_config="$ROOT/l07/haproxy-baseline.yaml"
  mkdir -p "$dir"; [[ "$scenario" == scaling-aware ]] && hpa="$ROOT/l07/hpa-aware.yaml"; [[ "$scenario" == shedding-429 ]] && haproxy_config="$ROOT/l07/haproxy-shedding.yaml"
  kubectl create namespace "$ns" >"$dir/namespace-create.log"; kubectl label namespace "$ns" istio-injection=enabled --overwrite >"$dir/namespace-injection-label.log"
  sed "s/capacity-cascade-l07-target/$ns/g" "$ROOT/l07/sidecar.yaml" >"$dir/sidecar.yaml"; sed "s/capacity-cascade-l07-target/$ns/g" "$ROOT/l07/retry-disabled.yaml" >"$dir/retry-disabled.yaml"; sed "s/capacity-cascade-l07-target/$ns/g" "$hpa" >"$dir/hpa.yaml"; sed -e "s/capacity-cascade-l07-target/$ns/g" -e "s/AUTH_SIM_SERVICE_FQDN/auth-sim.$ns.svc.cluster.local/g" -e "s#HAPROXY_IMAGE#$HAPROXY_IMAGE_VALUE#g" "$haproxy_config" >"$dir/haproxy.yaml"
  kubectl apply --server-side --dry-run=server -f "$dir/sidecar.yaml" >"$dir/sidecar-server-dry-run.log"; kubectl apply -f "$dir/sidecar.yaml" >"$dir/sidecar-apply.log"; printf %s "$ADMIN_TOKEN" | kubectl create secret generic auth-sim-admin --namespace "$ns" --from-file=token=/dev/stdin >"$dir/secret-create.log"
  local exporter=false; [[ "$scenario" == scaling-blind || "$scenario" == scaling-aware ]] && exporter=true
  helm upgrade --install auth-sim "$ROOT/charts/auth-sim" --namespace "$ns" --set-string image.repository=capacity-cascade/auth-sim --set-string image.tag="l07-$SOURCE_SHORT" --set-string adminSecret.name=auth-sim-admin --set-string adminSecret.key=token --set sidecarMetricsExporter.enabled="$exporter" --wait --timeout 180s >"$dir/auth-sim-install.log" 2>&1
  kubectl apply -f "$dir/retry-disabled.yaml" >"$dir/retry-disabled-apply.log"; kubectl rollout restart deployment/auth-sim --namespace "$ns" >"$dir/retry-disabled-restart.log"; kubectl rollout status deployment/auth-sim --namespace "$ns" --timeout=180s >"$dir/retry-disabled-rollout.log"
  pod="$(kubectl get pods --namespace "$ns" --selector app.kubernetes.io/instance=auth-sim -o json | jq -r '[.items[]|select(.metadata.deletionTimestamp==null)|select([.status.conditions[]?|select(.type=="Ready" and .status=="True")]|length==1)][0].metadata.name//empty')"; [[ -n "$pod" ]] || return 1
  kubectl get pod "$pod" --namespace "$ns" -o json >"$dir/pod.json"; [[ "$(jq '[.status.containerStatuses[]?,.status.initContainerStatuses[]?|select(.name=="auth-sim" and .ready==true)]|length' "$dir/pod.json")" -eq 1 && "$(jq '[.status.containerStatuses[]?,.status.initContainerStatuses[]?|select(.name=="istio-proxy" and .ready==true)]|length' "$dir/pod.json")" -eq 1 ]] || return 1
  proxy_image="$(jq -r '[.spec.containers[]?,.spec.initContainers[]?|select(.name=="istio-proxy")][0].image' "$dir/pod.json")"
  if [[ "$scenario" == scaling-blind || "$scenario" == scaling-aware ]]; then
    sed -e "s/capacity-cascade-l07-target/$ns/g" -e "s/TARGET_NAMESPACE/$ns/g" -e "s#AUTH_SIM_IMAGE#$AUTH_IMAGE#g" "$ROOT/l07/custom-metrics-adapter.yaml" >"$dir/adapter-all.yaml"
    if [[ "$scenario" == scaling-blind ]]; then awk '/^apiVersion: apiregistration.k8s.io\/v1$/{exit}{print}' "$dir/adapter-all.yaml" >"$dir/adapter.yaml"; else cp "$dir/adapter-all.yaml" "$dir/adapter.yaml"; fi
    kubectl apply -f "$dir/adapter.yaml" >"$dir/adapter-apply.log"; kubectl rollout status deployment/l07-custom-metrics-adapter --namespace "$ns" --timeout=180s >"$dir/adapter-rollout.log"
    [[ "$scenario" != scaling-aware ]] || kubectl wait --for=condition=Available apiservice/v1beta2.custom.metrics.k8s.io --timeout=120s >"$dir/adapter-api.log"
  fi
  kubectl apply -f "$dir/hpa.yaml" >"$dir/hpa-apply.log"; kubectl get hpa auth-sim-scaling --namespace "$ns" -o json >"$dir/hpa-initial.json"; kubectl apply -f "$dir/haproxy.yaml" >"$dir/haproxy-apply.log"; kubectl rollout status deployment/l07-haproxy --namespace "$ns" --timeout=180s >"$dir/haproxy-rollout.log"
  discover "$ns" "$pod" "$dir"
  local admin_port metrics_port haproxy_port
  start_forward "$ns" pod/"$pod" 9090 "$dir/admin-forward.log" ADMIN_PID admin_port; app_url="http://127.0.0.1:$admin_port"
  start_forward "$ns" pod/"$pod" 8080 "$dir/metrics-forward.log" METRICS_PID metrics_port; metrics_url="http://127.0.0.1:$metrics_port"
  start_forward "$ns" service/l07-haproxy 8404 "$dir/haproxy-forward.log" HAPROXY_PID haproxy_port; stats_url="http://127.0.0.1:$haproxy_port"
  wait_url "$app_url/admin/fault" && wait_url "$metrics_url/metrics" && wait_url "$stats_url/stats;csv" || return 1
  proxy_stats "$ns" "$pod" "$dir/observation-before.txt"; curl -fsS "$metrics_url/metrics" >"$dir/application-observation.prom"; proxy_stats "$ns" "$pod" "$dir/observation-after.txt"; local before after; before="$(stat "$dir/observation-before.txt" "$(jq -r .proxy_downstream_total "$dir/proxy-metric-mapping.json")")"; after="$(stat "$dir/observation-after.txt" "$(jq -r .proxy_downstream_total "$dir/proxy-metric-mapping.json")")"; jq -n --argjson proxy_downstream_delta "$((after-before))" '{direct_pod_metrics_scrape_proxy_downstream_delta:$proxy_downstream_delta,bypasses_target_inbound_proxy:($proxy_downstream_delta==0)}' >"$dir/application-observation-path.json"; [[ "$before" -eq "$after" ]] || return 1
  put_fault "$app_url" '{"latency_ms":0,"error_rate":0,"max_in_flight":0,"seed":17082026}' "$dir/fault-reset-before.json"; put_fault "$app_url" "{\"latency_ms\":$APP_LATENCY,\"error_rate\":0,\"max_in_flight\":0,\"seed\":17082026}" "$dir/fault-applied.json"; curl -fsS "$stats_url/stats;csv" >"$dir/haproxy-before.csv"
  : >"$dir/samples.jsonl"; WORKLOAD_START="$(date +%s)"; sample "$scenario" "$ns" "$pod" "$metrics_url" "$stats_url" "$dir/proxy-metric-mapping.json" "$dir/samples.jsonl" baseline; STOP_FILE="$dir/observer.stop"; observe "$scenario" "$ns" "$pod" "$metrics_url" "$stats_url" "$dir/proxy-metric-mapping.json" "$dir/samples.jsonl" "$STOP_FILE" & OBSERVER_PID=$!
  run_k6 "$scenario" "$ns" "$dir" "$proxy_image"; touch "$STOP_FILE"; wait "$OBSERVER_PID"; OBSERVER_PID=""; idle "$ns" "$pod" "$dir/proxy-metric-mapping.json" "$dir/proxy-idle.txt"; sample "$scenario" "$ns" "$pod" "$metrics_url" "$stats_url" "$dir/proxy-metric-mapping.json" "$dir/samples.jsonl" after
  curl -fsS "$stats_url/stats;csv" >"$dir/haproxy-after.csv"; kubectl get hpa auth-sim-scaling --namespace "$ns" -o yaml >"$dir/hpa-final.yaml"; kubectl get events --namespace "$ns" --field-selector involvedObject.kind=HorizontalPodAutoscaler,involvedObject.name=auth-sim-scaling -o json >"$dir/hpa-events.json"; put_fault "$app_url" '{"latency_ms":0,"error_rate":0,"max_in_flight":0,"seed":17082026}' "$dir/fault-reset-after.json"; contract "$scenario" "$dir"; stop_observer
}
pair_contract() {
  local axis="$1" control="$2" mitigation="$3" a b passed=false comparison
  a="$RESULT/$control/contract.json"; b="$RESULT/$mitigation/contract.json"
  case "$axis" in
    m1) comparison="$(jq -n --argjson c "$(cat "$a")" --argjson m "$(cat "$b")" '{measures:["physical_attempts","retry_attempts","logical_failure_rate","logical_p95_ms","active_overflow_delta"],mitigation_minus_control:{physical_attempts:($m.k6.physical_attempts-$c.k6.physical_attempts),retry_attempts:($m.k6.retry_attempts-$c.k6.retry_attempts),logical_failure_rate:($m.k6.logical_failure_rate-$c.k6.logical_failure_rate),logical_p95_ms:($m.k6.logical_p95_ms-$c.k6.logical_p95_ms),active_overflow_delta:($m.sidecar.active_overflow_delta-$c.sidecar.active_overflow_delta)}}')";;
    m2) comparison="$(jq -n --argjson c "$(cat "$a")" --argjson m "$(cat "$b")" '{measures:["downstream_429","denied_requests_delta","active_overflow_delta","logical_failure_rate","logical_p95_ms"],mitigation_minus_control:{downstream_429:($m.k6.status["429"]-$c.k6.status["429"]),denied_requests_delta:($m.haproxy.denied_requests_delta-$c.haproxy.denied_requests_delta),active_overflow_delta:($m.sidecar.active_overflow_delta-$c.sidecar.active_overflow_delta),logical_failure_rate:($m.k6.logical_failure_rate-$c.k6.logical_failure_rate),logical_p95_ms:($m.k6.logical_p95_ms-$c.k6.logical_p95_ms)}}')";;
    m3) comparison="$(jq -n --argjson c "$(cat "$a")" --argjson m "$(cat "$b")" '{measures:["desired_replicas_max","current_replicas_max","active_overflow_delta","logical_failure_rate","logical_p95_ms"],mitigation_minus_control:{desired_replicas_max:($m.hpa.desired_replicas_max-$c.hpa.desired_replicas_max),current_replicas_max:($m.hpa.current_replicas_max-$c.hpa.current_replicas_max),active_overflow_delta:($m.sidecar.active_overflow_delta-$c.sidecar.active_overflow_delta),logical_failure_rate:($m.k6.logical_failure_rate-$c.k6.logical_failure_rate),logical_p95_ms:($m.k6.logical_p95_ms-$c.k6.logical_p95_ms)}}')";;
    m4) comparison="$(jq -n --argjson c "$(cat "$a")" --argjson m "$(cat "$b")" '{measures:["active_overflow_delta","logical_failure_rate","logical_p95_ms","physical_attempts"],mitigation_minus_control:{active_overflow_delta:($m.sidecar.active_overflow_delta-$c.sidecar.active_overflow_delta),logical_failure_rate:($m.k6.logical_failure_rate-$c.k6.logical_failure_rate),logical_p95_ms:($m.k6.logical_p95_ms-$c.k6.logical_p95_ms),physical_attempts:($m.k6.physical_attempts-$c.k6.physical_attempts)}}')";;
  esac
  jq -e '.passed' "$a" >/dev/null && jq -e '.passed' "$b" >/dev/null && passed=true
  jq -n --arg axis "$axis" --argjson passed "$passed" --argjson control "$(cat "$a")" --argjson mitigation "$(cat "$b")" --argjson observed_comparison "$comparison" '{axis:$axis,passed:$passed,control:$control,mitigation:$mitigation,comparison:{one_variable:true,recovery_boundary:"final selected sidecar active and HAProxy queue/sessions equal zero",acceptance:"both paths completed their required validation and recovery checks; metric direction is recorded, not required",observed:$observed_comparison}}' >"$RESULT/$axis-contract.json"
  [[ "$passed" == true || "$ACTION" == smoke ]]
}
echo "L07 result directory: $RESULT"
helm lint "$ROOT/charts/auth-sim" --set-string image.repository=capacity-cascade/auth-sim --set-string image.tag="l07-$SOURCE_SHORT" >"$RESULT/chart-lint.log"
docker build --tag "$AUTH_IMAGE" . >"$RESULT/docker-build.log" 2>&1; docker pull "$K6_IMAGE_VALUE" >"$RESULT/k6-pull.log" 2>&1; docker pull "$HAPROXY_IMAGE_VALUE" >"$RESULT/haproxy-pull.log" 2>&1
k3d cluster create "$CLUSTER" --servers 1 --agents 0 --image "$K3S_IMAGE_VALUE" --api-port 127.0.0.1:0 --kubeconfig-update-default=false --kubeconfig-switch-context=false --k3s-arg '--disable=traefik@server:0' --k3s-arg '--disable=servicelb@server:0' --k3s-arg '--disable=local-storage@server:0' --wait --timeout 180s >"$RESULT/cluster-create.log" 2>&1; CLUSTER_CREATED=true
k3d kubeconfig get "$CLUSTER" >"$KUBECONFIG"; api="$(docker port k3d-$CLUSTER-serverlb 6443/tcp | awk '$1~/^127\.0\.0\.1:[0-9]+$/{print;exit}')"; sed -i "s#server: https://127.0.0.1:0#server: https://$api#" "$KUBECONFIG"; kubectl wait --for=condition=Ready nodes --all --timeout=180s >"$RESULT/node-ready.log"; k3d image import "$AUTH_IMAGE" --cluster "$CLUSTER" >"$RESULT/image-import.log" 2>&1
helm repo add istio https://blob.istio.io/istio-release/charts >"$RESULT/istio-repo-add.log"; helm repo update istio >"$RESULT/istio-repo-update.log"; helm pull istio/base --version "$ISTIO_VERSION_VALUE" --destination "$RUNTIME"; helm pull istio/istiod --version "$ISTIO_VERSION_VALUE" --destination "$RUNTIME"; helm upgrade --install istio-base "$RUNTIME/base-$ISTIO_VERSION_VALUE.tgz" --namespace "$ISTIO_NS" --create-namespace --set defaultRevision=default --wait --timeout 180s >"$RESULT/istio-base.log" 2>&1; BASE_INSTALLED=true; helm upgrade --install istiod "$RUNTIME/istiod-$ISTIO_VERSION_VALUE.tgz" --namespace "$ISTIO_NS" --values "$ROOT/l04/istiod-values.yaml" --set hub=docker.io/istio --set tag="$ISTIO_VERSION_VALUE" --set global.hub=docker.io/istio --set global.tag="$ISTIO_VERSION_VALUE" --wait --timeout 180s >"$RESULT/istiod.log" 2>&1; ISTIOD_INSTALLED=true
kubectl create namespace "$LOAD_NS" >"$RESULT/load-namespace.log"; kubectl label namespace "$LOAD_NS" istio-injection=disabled --overwrite >>"$RESULT/load-namespace.log"
jq -n --arg started_at_utc "$STARTED_AT" --arg git_commit "$SOURCE_COMMIT" --argjson git_dirty "$GIT_DIRTY" --arg action "$ACTION" --arg auth_image "$AUTH_IMAGE" --arg haproxy_image "$HAPROXY_IMAGE_VALUE" --arg k6_image "$K6_IMAGE_VALUE" --arg istio "$ISTIO_VERSION_VALUE" '{project:"GitHub Capacity Cascade Lab",learning_unit:"L07",classification:"local exploratory evidence",scenario_mode:$action,started_at_utc:$started_at_utc,git_commit:$git_commit,git_dirty:$git_dirty,images:{auth_sim:$auth_image,haproxy:$haproxy_image,k6:$k6_image},istio:{version:$istio},topology:"non-injected k6 Job -> HAProxy -> ClusterIP Service -> inbound istio-proxy -> auth-sim",fixed_local_conditions:{sidecar_http2MaxRequests:1,application_latency_ms:1000,request_timeout:"2s",haproxy_retry:"off",proxy_retry:"off"},matrix:{m1:"retry timing only",m2:"HAProxy local shedding policy only",m3:"HPA observed signal only",m4:"arrival schedule only"}}' >"$RESULT/metadata.json"
case "$ACTION" in
  m1) run_scenario retry-immediate; run_scenario retry-backoff; pair_contract m1 retry-immediate retry-backoff;;
  m2) run_scenario shedding-control; run_scenario shedding-429; pair_contract m2 shedding-control shedding-429;;
  m3) run_scenario scaling-blind; run_scenario scaling-aware; pair_contract m3 scaling-blind scaling-aware;;
  m4) run_scenario ramp-steep; run_scenario ramp-gradual; pair_contract m4 ramp-steep ramp-gradual;;
  matrix|smoke) run_scenario retry-immediate; run_scenario retry-backoff; pair_contract m1 retry-immediate retry-backoff; run_scenario shedding-control; run_scenario shedding-429; pair_contract m2 shedding-control shedding-429; run_scenario scaling-blind; run_scenario scaling-aware; pair_contract m3 scaling-blind scaling-aware; run_scenario ramp-steep; run_scenario ramp-gradual; pair_contract m4 ramp-steep ramp-gradual;;
esac
