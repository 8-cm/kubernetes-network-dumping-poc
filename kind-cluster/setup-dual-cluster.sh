#!/usr/bin/env bash
# Orchestrate a dual Kind cluster environment for network observability demos.
#
# Human-friendly: One command to get both clusters running, wired together,
# with port-forwards active and browser tabs open. Re-run safely at any time —
# existing clusters are detected and skipped. Use the "wire" subcommand alone
# to refresh cross-cluster routing after a Docker/host restart.
#
# Technical: Delegates single-cluster setup to setup.sh. After both clusters
# exist, resolves each cluster's network node Docker bridge IPs and injects
# them into peer-ingress ConfigMaps so pods can send cross-cluster HTTP traffic.
# Tool tabs (radar, k9s) are opened in Zellij before port-forwards start so
# sudo prompts are visible in the setup tab. Both clusters' port-forwards run
# in parallel (background &) after sudo -v pre-caches credentials.
#
# Subcommands:
#   wire   Re-inject peer Docker IPs without recreating clusters (use after restart)
#
# Options:
#   --create=<a|b|ab>   Which cluster(s) to create       [default: ab]
#   --delete=<a|b|ab>   Delete cluster(s) and exit
#   --zellij            Open k9s + radar in named Zellij tabs
#   --tmux              Open k9s + radar in tmux split panes
#   --radar             Also launch the radar TUI for each cluster
#   -h, --help          Show usage and exit
#
# Requires: kind, helm, kubectl, docker; optionally: zellij, tmux, k9s, radar
set -euo pipefail

SCRIPT_DIR="$(realpath "$(dirname "$0")")"
CLUSTER_A="a-cluster"
CLUSTER_B="b-cluster"
KC_A="${SCRIPT_DIR}/${CLUSTER_A}.kubeconfig"
KC_B="${SCRIPT_DIR}/${CLUSTER_B}.kubeconfig"
KUBECTL="$(command -v kubectl)"

# ──────────────────────────────────────────────────────
# Usage / help
# ──────────────────────────────────────────────────────
usage() {
  cat <<EOF

Usage: $(basename "$0") [OPTIONS] [wire]

Sets up Kind clusters with Cilium, HAProxy shards, demo apps, and cross-cluster
peer traffic (pods in each cluster target the other cluster's ingress via the
Docker bridge — visible as egress-gateway SNAT in Hubble/Wireshark).

Subcommand:
  wire           Re-wire peer IPs only (both clusters must already be running).
                 Run this after a node restart to refresh Docker bridge IPs.

Options (all optional):
  --create=<a|b|ab>   Cluster(s) to create             [default: ab]
  --delete=<a|b|ab>   Delete cluster(s) and exit
  --zellij            Open k9s (and radar if --radar) in dedicated Zellij tabs
                      Each tool gets its own tab; clusters split right within the tab
  --tmux              Open k9s (and radar if --radar) in tmux split panes
  --radar             Launch radar TUI for each created cluster
                      With --zellij: dedicated "radar" tab; --tmux: split; else background
  -h, --help          Show this help and exit

Examples:
  $(basename "$0")                            # create both clusters (default)
  $(basename "$0") --create=a                 # create only a-cluster
  $(basename "$0") --create=ab --zellij       # both clusters + k9s in Zellij
  $(basename "$0") --create=b --tmux --radar  # b-cluster + k9s in tmux + radar
  $(basename "$0") --delete=ab               # delete both clusters
  $(basename "$0") wire                       # re-wire peer IPs (no cluster creation)

After setup, port-forwards are started automatically. Use port-forward.sh to manage:
  $(basename "$(dirname "$0")")/port-forward.sh stop
  CLUSTER_NAME=b-cluster $(basename "$(dirname "$0")")/port-forward.sh

EOF
}

# ──────────────────────────────────────────────────────
# Arg parsing
# ──────────────────────────────────────────────────────
CREATE=""
DELETE=""
USE_ZELLIJ=false
USE_TMUX=false
USE_RADAR=false
WIRE_ONLY=false

for arg in "$@"; do
  case "$arg" in
    -h|--help)   usage; exit 0 ;;
    --create=*)  CREATE="${arg#--create=}" ;;
    --delete=*)  DELETE="${arg#--delete=}" ;;
    --zellij)    USE_ZELLIJ=true ;;
    --tmux)      USE_TMUX=true ;;
    --radar)     USE_RADAR=true ;;
    wire)        WIRE_ONLY=true ;;
    *)           echo "Unknown argument: $arg" >&2; usage; exit 1 ;;
  esac
done

# Default to ab if no create/delete/wire specified
[[ -z "$CREATE" && -z "$DELETE" && "$WIRE_ONLY" == false ]] && CREATE="ab"

# Name the current tab so we can return to it after opening tool tabs.
$USE_ZELLIJ && zellij action rename-tab "setup" 2>/dev/null || true

CREATE_A=false; CREATE_B=false
[[ "$CREATE" == *a* ]] && CREATE_A=true
[[ "$CREATE" == *b* ]] && CREATE_B=true

# ──────────────────────────────────────────────────────
# Delete
# ──────────────────────────────────────────────────────
if [[ -n "$DELETE" ]]; then
  echo "==> Deleting clusters: ${DELETE}"
  if [[ "$DELETE" == *a* ]]; then
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_A}$"; then
      kind delete cluster --name "${CLUSTER_A}"
      echo "    deleted ${CLUSTER_A}"
    else
      echo "    ${CLUSTER_A} not found, skipping"
    fi
  fi
  if [[ "$DELETE" == *b* ]]; then
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_B}$"; then
      kind delete cluster --name "${CLUSTER_B}"
      echo "    deleted ${CLUSTER_B}"
    else
      echo "    ${CLUSTER_B} not found, skipping"
    fi
  fi
  exit 0
fi

# ──────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────
# ──────────────────────────────────────────────
# Look up the Docker bridge IP of a Kind cluster node container.
#
# Human-friendly: Given a node name like "a-cluster-worker5", returns the IP
# that other Docker containers can use to reach it on the Docker bridge network.
#
# Technical: Runs `docker inspect` with a Go template that iterates all attached
# networks and prints the first IP address found. Kind nodes each run as a Docker
# container named exactly as the Kind node name. Returns empty string if the
# container is not found or has no IP.
#
# Args:
#   $1  container_name  Docker container name of the Kind node (e.g. a-cluster-worker5)
# Returns: Docker bridge IP on stdout (e.g. 172.18.0.5); empty string on failure
# ──────────────────────────────────────────────
node_docker_ip() {
  docker inspect "$1" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null
}

# ──────────────────────────────────────────────
# Run setup.sh for one cluster, skipping creation if the cluster already exists.
#
# Human-friendly: Idempotent cluster launcher — calling this twice is safe.
# The second call detects the existing cluster and prints a skip message.
#
# Technical: Uses `kind get clusters` to check for cluster existence before
# delegating to setup.sh. Passes cluster identity and HAProxy shard Helm values
# via environment variables rather than positional arguments so setup.sh can be
# called standalone with the same interface.
#
# Args:
#   $1  name    Kind cluster name (e.g. a-cluster)
#   $2  config  Path to Kind cluster YAML config file
#   $3  s1val   Path to Helm values YAML for HAProxy shard-1
#   $4  s2val   Path to Helm values YAML for HAProxy shard-2
# Returns: exit code from setup.sh, or 0 if cluster already exists
# ──────────────────────────────────────────────
run_setup() {
  local name="$1" config="$2" s1val="$3" s2val="$4"
  if kind get clusters 2>/dev/null | grep -q "^${name}$"; then
    echo "==> ${name} already running — skipping cluster creation"
  else
    echo "==> Setting up ${name}"
    CLUSTER_NAME="${name}" \
    CLUSTER_CONFIG="${config}" \
    SHARD1_VALUES="${s1val}" \
    SHARD2_VALUES="${s2val}" \
      "${SCRIPT_DIR}/setup.sh"
  fi
}

# ──────────────────────────────────────────────
# Inject peer cluster ingress endpoints into every team namespace as a ConfigMap.
#
# Human-friendly: Tells pods in one cluster where to find the other cluster's
# ingress nodes. Without this, cross-cluster traffic falls back to example.com.
#
# Technical: Applies (creates or replaces) the "peer-ingress" ConfigMap in
# team-alpha, team-beta, and team-gamma. Pods reference it via envFrom, making
# PEER_SHARD1, PEER_SHARD2, and PEER_DOMAIN available as environment variables.
# The ConfigMap is applied with `kubectl apply -f -` via a heredoc so it is
# idempotent (subsequent calls update in place rather than failing on conflict).
#
# Args:
#   $1  KC           Path to kubeconfig for the target cluster
#   $2  SHARD1       Docker bridge IP of the peer cluster's network-00 node (worker5)
#   $3  SHARD2       Docker bridge IP of the peer cluster's network-01 node (worker6)
#   $4  PEER_DOMAIN  Peer cluster name used as ingress Host header domain (e.g. b-cluster)
# Returns: last exit code from kubectl apply (non-zero on API server error)
# ──────────────────────────────────────────────
apply_peer_cm() {
  local KC="$1" SHARD1="$2" SHARD2="$3" PEER_DOMAIN="$4"
  for ns in team-alpha team-beta team-gamma; do
    "${KUBECTL}" --kubeconfig "${KC}" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: peer-ingress
  namespace: ${ns}
data:
  PEER_SHARD1: "${SHARD1}"
  PEER_SHARD2: "${SHARD2}"
  PEER_DOMAIN: "${PEER_DOMAIN}"
EOF
  done
}

# ──────────────────────────────────────────────
# Open a named Zellij tab and run one shell command per pane.
#
# Human-friendly: Creates a new Zellij tab with a descriptive name and
# launches each passed command in its own pane, split to the right.
#
# Technical: Creates the tab with `zellij action new-tab --name`. The first
# command is typed into the tab's default shell pane using write-chars + \n
# (simulating keyboard input rather than --command, which Zellij does not
# support in this version). Each subsequent command gets a new right-split pane
# via `new-pane --direction right` followed by write-chars. A 0.5s sleep after
# each pane creation prevents write-chars from firing before the pane shell is ready.
#
# Args:
#   $1      tab_name  Name to assign to the new Zellij tab
#   $2..N   cmd       Shell commands to run — one per pane (left to right)
# Returns: 0 always (Zellij action errors are not propagated)
# Side effects: leaves a persistent Zellij tab open after the script exits
# ──────────────────────────────────────────────
# Opens a named zellij tab and runs each command in a pane.
# The first command runs in the tab's default shell pane; subsequent ones split right.
open_zellij_tab() {
  local tab_name="$1"; shift
  local first=true
  zellij action new-tab --name "${tab_name}"
  sleep 0.5
  for cmd in "$@"; do
    if $first; then
      zellij action write-chars "${cmd}"$'\n'
      first=false
    else
      zellij action new-pane --direction right
      sleep 0.5
      zellij action write-chars "${cmd}"$'\n'
    fi
  done
}

# ──────────────────────────────────────────────
# Split the current tmux pane and launch k9s for a cluster. (tmux only)
#
# Human-friendly: Opens a side-by-side k9s view in tmux for a cluster.
# For Zellij, k9s is launched via open_zellij_tab (dedicated "k9s" tab) instead.
#
# Technical: Guards against missing k9s binary and duplicate instances (pgrep
# on the --context flag string). Splits the current tmux window horizontally
# or vertically depending on the direction argument. KUBECONFIG is passed as
# an env var prefix on the tmux command so k9s sees the correct cluster.
#
# Args:
#   $1  kc         Path to kubeconfig file
#   $2  name       Cluster name — used in pgrep match (k9s.*--context kind-NAME)
#   $3  direction  tmux split direction: "right" (split -h) or "down" (split -v) [default: right]
# Returns: 0 if skipped; tmux exit code otherwise
# ──────────────────────────────────────────────
open_k9s() {
  local kc="$1" name="$2" direction="${3:-right}"
  if ! command -v k9s &>/dev/null; then
    echo "  [skip] k9s not found in PATH"
    return
  fi
  if pgrep -qf "k9s.*--context kind-${name}" 2>/dev/null; then
    echo "  [skip] k9s for ${name} already running"
    return
  fi
  echo "==> Opening k9s for ${name}"
  if [[ "${direction}" == "right" ]]; then
    tmux split-window -h "KUBECONFIG=${kc} k9s --context kind-${name}"
  else
    tmux split-window -v "KUBECONFIG=${kc} k9s --context kind-${name}"
  fi
}

# ──────────────────────────────────────────────
# Launch the radar Kubernetes TUI for a cluster.
#
# Human-friendly: Starts radar (a web-based cluster resource browser) and lets
# it open a browser tab automatically. For Zellij it gets a dedicated "radar"
# tab; for tmux a horizontal split; otherwise a detached background process.
#
# Technical: Skips if radar is not in PATH or if a radar process already exists
# for this cluster (pgrep matches on the -kubeconfig path which embeds the
# cluster name). In background mode writes the PID to /tmp/kind-radar-NAME.pid
# and checks it on subsequent calls to avoid duplicate launches. Radar is started
# without -no-browser so it automatically opens its UI in the default browser.
#
# Args:
#   $1  kc    Path to kubeconfig file (used as -kubeconfig flag and for pgrep match)
#   $2  name  Cluster name — used in pgrep pattern and PID file name
#   $3  port  Local port for the radar HTTP server [default: 9280]
# Returns: 0 always; radar error output is not captured
# Side effects: may open a browser tab; writes PID file in /tmp
# ──────────────────────────────────────────────
open_radar() {
  local kc="$1" name="$2" port="${3:-9280}"
  if ! command -v radar &>/dev/null; then
    echo "  [skip] radar not found in PATH"
    return
  fi
  if pgrep -qf "radar.*${name}" 2>/dev/null; then
    echo "  [skip] radar for ${name} already running"
    return
  fi
  echo "==> Opening radar for ${name} (port ${port})"
  local radar_cmd="radar -kubeconfig ${kc} -port ${port}"
  if $USE_TMUX; then
    tmux split-window -h "${radar_cmd}"
  else
    local pid_file="/tmp/kind-radar-${name}.pid"
    if [[ -f "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
      echo "  [skip] radar for ${name} already running (PID $(cat "${pid_file}"))"
      return
    fi
    ${radar_cmd} &
    echo $! > "${pid_file}"
    echo "    radar launched in background (PID $!)"
  fi
}

# ──────────────────────────────────────────────
# Resolve Docker bridge IPs and wire cross-cluster peer ingress routing.
#
# Human-friendly: Run this after both clusters exist (or after a Docker restart
# that changes node IPs) to enable cross-cluster traffic. Without it, pods fall
# back to example.com for external requests.
#
# Technical:
#   1. Calls node_docker_ip() for all four network nodes (a-cluster worker5/6,
#      b-cluster worker5/6) to get their current Docker bridge IPs.
#   2. Calls apply_peer_cm() twice: once to inject b-cluster IPs into a-cluster's
#      namespaces, and once to inject a-cluster IPs into b-cluster's namespaces.
#   3. Restarts hello and traffic-external deployments in all three namespaces
#      of both clusters so they pick up the updated peer-ingress ConfigMap values.
#      Errors from rollout restart are suppressed (pods may not exist yet).
#   4. Waits for all hello deployments to reach ready state (120s timeout each).
#
# Args:    none
# Globals: CLUSTER_A, CLUSTER_B, KC_A, KC_B, KUBECTL
# Returns: non-zero if any `rollout status` times out
# ──────────────────────────────────────────────
wire_peers() {
  echo "==> Resolving peer ingress endpoints (Docker bridge IPs — hostPort 80)"
  local A_N0 A_N1 B_N0 B_N1
  # Kind auto-names network nodes as worker5 (shard-1) and worker6 (shard-2)
  A_N0=$(node_docker_ip "${CLUSTER_A}-worker5")
  A_N1=$(node_docker_ip "${CLUSTER_A}-worker6")
  B_N0=$(node_docker_ip "${CLUSTER_B}-worker5")
  B_N1=$(node_docker_ip "${CLUSTER_B}-worker6")

  printf '  %-40s  %s\n' "a-cluster shard-1 (worker5/network-00)" "${A_N0}:80"
  printf '  %-40s  %s\n' "a-cluster shard-2 (worker6/network-01)" "${A_N1}:80"
  printf '  %-40s  %s\n' "b-cluster shard-1 (worker5/network-00)" "${B_N0}:80"
  printf '  %-40s  %s\n' "b-cluster shard-2 (worker6/network-01)" "${B_N1}:80"

  echo "==> Creating peer-ingress ConfigMaps"
  # a-cluster pods → b-cluster IPs + domain; b-cluster pods → a-cluster IPs + domain
  apply_peer_cm "${KC_A}" "${B_N0}" "${B_N1}" "${CLUSTER_B}"
  apply_peer_cm "${KC_B}" "${A_N0}" "${A_N1}" "${CLUSTER_A}"

  echo "==> Restarting hello + traffic deployments to pick up peer-ingress"
  for ns in team-alpha team-beta team-gamma; do
    "${KUBECTL}" --kubeconfig "${KC_A}" rollout restart \
      deployment/hello deployment/traffic-external -n "${ns}" 2>/dev/null || true
    "${KUBECTL}" --kubeconfig "${KC_B}" rollout restart \
      deployment/hello deployment/traffic-external -n "${ns}" 2>/dev/null || true
  done

  echo "==> Waiting for rollouts"
  for ns in team-alpha team-beta team-gamma; do
    "${KUBECTL}" --kubeconfig "${KC_A}" rollout status deployment/hello -n "${ns}" --timeout=120s
    "${KUBECTL}" --kubeconfig "${KC_B}" rollout status deployment/hello -n "${ns}" --timeout=120s
  done
}

# ──────────────────────────────────────────────────────
# Wire-only mode
# ──────────────────────────────────────────────────────
if $WIRE_ONLY; then
  wire_peers
  echo "==> Done."
  exit 0
fi

# ──────────────────────────────────────────────────────
# 1. Cluster setup
# ──────────────────────────────────────────────────────
$CREATE_A && run_setup "${CLUSTER_A}" \
  "${SCRIPT_DIR}/cluster.yaml" \
  "${SCRIPT_DIR}/haproxy/shard1-values.yaml" \
  "${SCRIPT_DIR}/haproxy/shard2-values.yaml"

$CREATE_B && run_setup "${CLUSTER_B}" \
  "${SCRIPT_DIR}/cluster-b.yaml" \
  "${SCRIPT_DIR}/haproxy/shard1-values-b.yaml" \
  "${SCRIPT_DIR}/haproxy/shard2-values-b.yaml"

# ──────────────────────────────────────────────────────
# 2. Peer wiring (only when both clusters exist)
# ──────────────────────────────────────────────────────
if $CREATE_A && $CREATE_B; then
  wire_peers
fi

# ──────────────────────────────────────────────────────
# 3. Radar  (zellij: dedicated tab with one pane per cluster)
# ──────────────────────────────────────────────────────
if $USE_RADAR; then
  if $USE_ZELLIJ && command -v radar &>/dev/null; then
    RADAR_CMDS=()
    if $CREATE_A && ! pgrep -qf "radar.*a-cluster" 2>/dev/null; then
      RADAR_CMDS+=("radar -kubeconfig ${KC_A} -port 9280")
    elif $CREATE_A; then echo "  [skip] radar for ${CLUSTER_A} already running"; fi
    if $CREATE_B && ! pgrep -qf "radar.*b-cluster" 2>/dev/null; then
      RADAR_CMDS+=("radar -kubeconfig ${KC_B} -port 9281")
    elif $CREATE_B; then echo "  [skip] radar for ${CLUSTER_B} already running"; fi
    [[ ${#RADAR_CMDS[@]} -gt 0 ]] && open_zellij_tab "radar" "${RADAR_CMDS[@]}"
  else
    $CREATE_A && open_radar "${KC_A}" "${CLUSTER_A}" 9280
    $CREATE_B && open_radar "${KC_B}" "${CLUSTER_B}" 9281
  fi
fi

# ──────────────────────────────────────────────────────
# 4. k9s  (zellij: dedicated tab with one pane per cluster)
# ──────────────────────────────────────────────────────
if $USE_ZELLIJ || $USE_TMUX; then
  if $USE_ZELLIJ && command -v k9s &>/dev/null; then
    K9S_CMDS=()
    if $CREATE_A && ! pgrep -qf "k9s.*--context kind-${CLUSTER_A}" 2>/dev/null; then
      K9S_CMDS+=("KUBECONFIG=${KC_A} k9s --context kind-${CLUSTER_A}")
    elif $CREATE_A; then echo "  [skip] k9s for ${CLUSTER_A} already running"; fi
    if $CREATE_B && ! pgrep -qf "k9s.*--context kind-${CLUSTER_B}" 2>/dev/null; then
      K9S_CMDS+=("KUBECONFIG=${KC_B} k9s --context kind-${CLUSTER_B}")
    elif $CREATE_B; then echo "  [skip] k9s for ${CLUSTER_B} already running"; fi
    [[ ${#K9S_CMDS[@]} -gt 0 ]] && open_zellij_tab "k9s" "${K9S_CMDS[@]}"
  elif $USE_TMUX; then
    if $CREATE_A && $CREATE_B; then
      open_k9s "${KC_A}" "${CLUSTER_A}" right
      sleep 1
      open_k9s "${KC_B}" "${CLUSTER_B}" right
    elif $CREATE_A; then
      open_k9s "${KC_A}" "${CLUSTER_A}" right
    elif $CREATE_B; then
      open_k9s "${KC_B}" "${CLUSTER_B}" right
    fi
  fi
fi

# ──────────────────────────────────────────────────────
# 5. Port-forwards  (both clusters in parallel)
# ──────────────────────────────────────────────────────
# Return to the setup tab so sudo prompts are visible.
$USE_ZELLIJ && zellij action go-to-tab-name "setup" 2>/dev/null || true

# Collect table output to a file; displayed in a "urls" tab after port-forwards start.
TABLE_FILE=""
if $USE_ZELLIJ; then
  TABLE_FILE="/tmp/kind-tables-$$.txt"
  rm -f "${TABLE_FILE}"
fi
export ZELLIJ_TABLE_FILE="${TABLE_FILE}"

echo ""
echo "==> Starting port-forwards (sudo required for port 80)"
# Pre-cache sudo so both clusters can start in parallel without double-prompting.
sudo -v

if $CREATE_A; then
  CLUSTER_NAME="${CLUSTER_A}" "${SCRIPT_DIR}/port-forward.sh" &
fi
if $CREATE_B; then
  CLUSTER_NAME="${CLUSTER_B}" \
  ALIAS_SHARD1="127.0.0.4" \
  ALIAS_SHARD2="127.0.0.5" \
  HUBBLE_PORT="12001" \
    "${SCRIPT_DIR}/port-forward.sh" &
fi
wait

# Open all cluster ingress URLs in a single browser window.
if [[ "$(uname)" == "Darwin" ]]; then
  echo ""
  echo "==> Opening browser"
  ALL_URLS=()
  if $CREATE_A; then
    ALL_URLS+=(
      "http://team-alpha.${CLUSTER_A}"
      "http://team-beta.${CLUSTER_A}"
      "http://team-gamma.${CLUSTER_A}"
      "http://traffic-alpha.${CLUSTER_A}"
      "http://traffic-beta.${CLUSTER_A}"
      "http://traffic-gamma.${CLUSTER_A}"
      "http://localhost:12000"
    )
  fi
  if $CREATE_B; then
    ALL_URLS+=(
      "http://team-alpha.${CLUSTER_B}"
      "http://team-beta.${CLUSTER_B}"
      "http://team-gamma.${CLUSTER_B}"
      "http://traffic-alpha.${CLUSTER_B}"
      "http://traffic-beta.${CLUSTER_B}"
      "http://traffic-gamma.${CLUSTER_B}"
      "http://localhost:12001"
    )
  fi
  [[ ${#ALL_URLS[@]} -gt 0 ]] && open "${ALL_URLS[@]}"
fi

# Open combined URL table as a read-only "urls" tab (last tab opened).
if $USE_ZELLIJ && [[ -s "${TABLE_FILE}" ]]; then
  open_zellij_tab "urls" "less -S '${TABLE_FILE}'"
fi
