#!/usr/bin/env bash
# Sets up two Kind clusters (a-cluster + b-cluster), wires them together for
# cross-cluster traffic, and optionally opens k9s panes and launches radar.
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
  --zellij            Open k9s in Zellij pane(s) after setup
                      With ab: right pane for a-cluster, then split-down for b-cluster
  --tmux              Open k9s in tmux pane(s) after setup
                      With ab: split-h for a-cluster, then split-v for b-cluster
  --radar             Launch 'radar' TUI in the background for each created cluster
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
node_docker_ip() {
  docker inspect "$1" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null
}

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

open_k9s() {
  local kc="$1" name="$2" direction="${3:-right}"
  if ! command -v k9s &>/dev/null; then
    echo "  [skip] k9s not found in PATH"
    return
  fi
  echo "==> Opening k9s for ${name} (${direction})"
  if $USE_ZELLIJ; then
    zellij action new-pane --direction "${direction}" -- \
      bash -c "KUBECONFIG=${kc} k9s --context kind-${name}"
  elif $USE_TMUX; then
    if [[ "${direction}" == "right" ]]; then
      tmux split-window -h "KUBECONFIG=${kc} k9s --context kind-${name}"
    else
      tmux split-window -v "KUBECONFIG=${kc} k9s --context kind-${name}"
    fi
  fi
}

wire_peers() {
  echo "==> Resolving peer ingress endpoints (Docker bridge IPs — hostPort 80)"
  local A_N0 A_N1 B_N0 B_N1
  A_N0=$(node_docker_ip "${CLUSTER_A}-network-00")
  A_N1=$(node_docker_ip "${CLUSTER_A}-network-01")
  B_N0=$(node_docker_ip "${CLUSTER_B}-network-00")
  B_N1=$(node_docker_ip "${CLUSTER_B}-network-01")

  printf '  %-40s  %s\n' "a-cluster shard-1 (network-00)" "${A_N0}:80"
  printf '  %-40s  %s\n' "a-cluster shard-2 (network-01)" "${A_N1}:80"
  printf '  %-40s  %s\n' "b-cluster shard-1 (network-00)" "${B_N0}:80"
  printf '  %-40s  %s\n' "b-cluster shard-2 (network-01)" "${B_N1}:80"

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
# 3. Radar
# ──────────────────────────────────────────────────────
if $USE_RADAR; then
  if ! command -v radar &>/dev/null; then
    echo "==> [--radar] 'radar' not found in PATH — skipping"
  else
    if $CREATE_A; then
      KUBECONFIG="${KC_A}" radar &
      echo "==> radar launched for ${CLUSTER_A} (PID $!)"
    fi
    if $CREATE_B; then
      KUBECONFIG="${KC_B}" radar &
      echo "==> radar launched for ${CLUSTER_B} (PID $!)"
    fi
  fi
fi

# ──────────────────────────────────────────────────────
# 4. k9s panes
# ──────────────────────────────────────────────────────
if $USE_ZELLIJ || $USE_TMUX; then
  if $CREATE_A && $CREATE_B; then
    open_k9s "${KC_A}" "${CLUSTER_A}" right
    sleep 1   # give zellij/tmux time to focus new pane
    open_k9s "${KC_B}" "${CLUSTER_B}" down
  elif $CREATE_A; then
    open_k9s "${KC_A}" "${CLUSTER_A}" right
  elif $CREATE_B; then
    open_k9s "${KC_B}" "${CLUSTER_B}" right
  fi
fi

# ──────────────────────────────────────────────────────
# 5. Port-forwards
# ──────────────────────────────────────────────────────
echo ""
echo "==> Starting port-forwards"

if $CREATE_A; then
  CLUSTER_NAME="${CLUSTER_A}" "${SCRIPT_DIR}/port-forward.sh"
fi

if $CREATE_B; then
  # b-cluster uses different loopback IPs to avoid conflict with a-cluster
  CLUSTER_NAME="${CLUSTER_B}" \
  ALIAS_SHARD1="127.0.0.4" \
  ALIAS_SHARD2="127.0.0.5" \
  HUBBLE_PORT="12001" \
    "${SCRIPT_DIR}/port-forward.sh"
fi
