#!/usr/bin/env bash
# Expose a Kind cluster's ingress shards and Hubble UI on the host via loopback.
#
# Human-friendly: Run this after cluster setup to make browser URLs work. For a
# second cluster, override the env vars below so both clusters use different IPs
# and ports without colliding.
#
# Technical: Adds two loopback IP aliases to lo0, rewrites /etc/hosts to map
# cluster-domain hostnames to those aliases, then starts three background
# kubectl port-forward processes (shard-1, shard-2, Hubble UI). PIDs are
# tracked in /tmp/kind-port-forward-<cluster>.pids for clean teardown. When
# ZELLIJ_TABLE_FILE is set the URL table is appended to that file instead of
# printed to stdout — used by setup-dual-cluster.sh to build a combined table.
#
# Usage:
#   ./port-forward.sh            # start (a-cluster defaults)
#   ./port-forward.sh stop       # stop all port-forwards and clean up
#
# Env vars (all optional):
#   CLUSTER_NAME        Kind cluster name                    [default: a-cluster]
#   ALIAS_SHARD1        Loopback IP for HAProxy shard-1      [default: 127.0.0.2]
#   ALIAS_SHARD2        Loopback IP for HAProxy shard-2      [default: 127.0.0.3]
#   HUBBLE_PORT         Host port for Hubble UI              [default: 12000]
#   RADAR_PORT          Host port for radar UI               [default: (unset)]
#   ZELLIJ_TABLE_FILE   If set, append URL table here instead of printing to stdout
#
# Requires: kubectl, sudo (for ifconfig + port 80 bind)
set -euo pipefail

SCRIPT_DIR="$(realpath "$(dirname "$0")")"
CLUSTER_NAME="${CLUSTER_NAME:-a-cluster}"
KUBECONFIG_PATH="${SCRIPT_DIR}/${CLUSTER_NAME}.kubeconfig"
KUBECTL="$(command -v kubectl)"

ALIAS_SHARD1="${ALIAS_SHARD1:-127.0.0.2}"
ALIAS_SHARD2="${ALIAS_SHARD2:-127.0.0.3}"
HUBBLE_PORT="${HUBBLE_PORT:-12000}"
RADAR_PORT="${RADAR_PORT:-}"

PID_FILE="/tmp/kind-port-forward-${CLUSTER_NAME}.pids"
HOSTS_TAG="kind-${CLUSTER_NAME}"

# Domain = cluster name  (e.g. team-alpha.a-cluster, traffic-beta.b-cluster)
HOSTS_BLOCK="# ${HOSTS_TAG}
${ALIAS_SHARD1} team-alpha.${CLUSTER_NAME}
${ALIAS_SHARD2} team-beta.${CLUSTER_NAME}
${ALIAS_SHARD2} team-gamma.${CLUSTER_NAME}
${ALIAS_SHARD1} traffic-alpha.${CLUSTER_NAME}
${ALIAS_SHARD2} traffic-beta.${CLUSTER_NAME}
${ALIAS_SHARD2} traffic-gamma.${CLUSTER_NAME}
# end ${HOSTS_TAG}"

# ──────────────────────────────────────────────
# Stop all port-forwards for this cluster and clean up host state.
#
# Human-friendly: Run with "stop" argument to undo everything port-forward.sh
# set up — kills background processes, removes loopback IPs, cleans /etc/hosts.
#
# Technical: Reads PIDs from PID_FILE and sends SIGTERM via sudo kill. Removes
# loopback aliases with `ifconfig lo0 -alias` (errors suppressed — alias may
# already be gone). Strips the cluster's /etc/hosts block identified by comment
# markers "# kind-CLUSTER_NAME" ... "# end kind-CLUSTER_NAME" using a sed range
# delete, writing to a cluster-specific temp file to avoid parallel-run races.
#
# Args:    none
# Globals: CLUSTER_NAME, ALIAS_SHARD1, ALIAS_SHARD2, PID_FILE, HOSTS_TAG
# Returns: 0 always (individual errors suppressed)
# Sudo:    yes — kill (port 80 forward owned by root), ifconfig, cp to /etc/hosts
# ──────────────────────────────────────────────
stop() {
  echo "==> Stopping port-forwards for ${CLUSTER_NAME}"
  if [[ -f "${PID_FILE}" ]]; then
    while read -r pid; do
      sudo kill "${pid}" 2>/dev/null || true
    done < "${PID_FILE}"
    rm -f "${PID_FILE}"
  fi

  echo "==> Removing loopback aliases (requires sudo)"
  sudo ifconfig lo0 -alias "${ALIAS_SHARD1}" 2>/dev/null || true
  sudo ifconfig lo0 -alias "${ALIAS_SHARD2}" 2>/dev/null || true

  echo "==> Removing /etc/hosts entries (requires sudo)"
  local hosts_tmp="/tmp/hosts-${CLUSTER_NAME}.tmp"
  sed "/# ${HOSTS_TAG}/,/# end ${HOSTS_TAG}/d" /etc/hosts > "${hosts_tmp}" \
    && sudo cp "${hosts_tmp}" /etc/hosts && rm -f "${hosts_tmp}"

  echo "Done."
}

# ──────────────────────────────────────────────
# Render a formatted URL reference table for this cluster.
#
# Human-friendly: Shows every browser URL, which ingress shard and egress-gw
# handles it, and the kubectl context command — useful after setup to know
# where everything is.
#
# Technical: Prints a Unicode box-drawing table using printf %-Ns padding.
# All cell content is deliberately ASCII-only: Unicode arrows/dashes cause
# printf to count bytes instead of display columns, breaking column alignment.
# Column widths: URL=34 chars, Description=46 chars.
# When ZELLIJ_TABLE_FILE is non-empty the output is appended to that file
# (so setup-dual-cluster.sh can combine both clusters into one "urls" tab).
#
# Args:    none
# Globals: CLUSTER_NAME, HUBBLE_PORT, RADAR_PORT, KUBECONFIG_PATH, ZELLIJ_TABLE_FILE
# Returns: 0 always
# Output:  stdout (or appended to ZELLIJ_TABLE_FILE if set)
# ──────────────────────────────────────────────
print_table() {
  local D="${CLUSTER_NAME}"
  # Columns: URL=34, Description=46  (all ASCII content keeps printf padding exact)
  local LT="┌────────────────────────────────────┬────────────────────────────────────────────────┐"
  local LH="├────────────────────────────────────┼────────────────────────────────────────────────┤"
  local LB="└────────────────────────────────────┴────────────────────────────────────────────────┘"

  printf '\n  Cluster: %s\n\n' "${CLUSTER_NAME}"
  printf '  %s\n' "${LT}"
  printf '  │ %-34s │ %-46s │\n' "URL" "Description"
  printf '  %s\n' "${LH}"
  printf '  │ %-34s │ %-46s │\n' \
    "http://team-alpha.${D}"    "hello [shard-1 ingress] [egress: network-00]"
  printf '  │ %-34s │ %-46s │\n' \
    "http://team-beta.${D}"     "hello [shard-2 ingress] [egress: network-01]"
  printf '  │ %-34s │ %-46s │\n' \
    "http://team-gamma.${D}"    "hello [shard-2 ingress] [egress: any node]"
  printf '  %s\n' "${LH}"
  printf '  │ %-34s │ %-46s │\n' \
    "http://traffic-alpha.${D}" "traffic (shard-1): internal/cross/peer/chaos"
  printf '  │ %-34s │ %-46s │\n' \
    "http://traffic-beta.${D}"  "traffic (shard-2): internal/cross/peer/chaos"
  printf '  │ %-34s │ %-46s │\n' \
    "http://traffic-gamma.${D}" "traffic (shard-2): internal/cross/peer/chaos"
  printf '  %s\n' "${LH}"
  printf '  │ %-34s │ %-46s │\n' \
    "http://localhost:${HUBBLE_PORT}" \
    "Hubble UI: L3/L4 flows, DNS, egress-gw SNAT"
  if [[ -n "${RADAR_PORT}" ]]; then
    printf '  │ %-34s │ %-46s │\n' \
      "http://localhost:${RADAR_PORT}" \
      "radar UI (cluster resources / events)"
  fi
  printf '  %s\n' "${LB}"
  printf '\n  kubectl:   export KUBECONFIG=%s\n' "${KUBECONFIG_PATH}"
  printf   '  stop:      ./port-forward.sh stop\n'
  if [[ "${CLUSTER_NAME}" == "a-cluster" ]]; then
    printf '  b-cluster: CLUSTER_NAME=b-cluster ALIAS_SHARD1=127.0.0.4 ALIAS_SHARD2=127.0.0.5 HUBBLE_PORT=12001 ./port-forward.sh\n'
  fi
  printf '\n'
}

# ──────────────────────────────────────────────
# Configure host networking and start port-forward processes for this cluster.
#
# Human-friendly: The main entry point — call with no arguments to bring up
# all URLs for a cluster. Safe to re-run; existing /etc/hosts entries are
# replaced (not duplicated) because the sed range-delete runs first.
#
# Technical:
#   1. Adds ALIAS_SHARD1 and ALIAS_SHARD2 as loopback aliases on lo0 (sudo).
#   2. Removes any existing cluster block from /etc/hosts and appends a fresh
#      one mapping team-*.CLUSTER_NAME and traffic-*.CLUSTER_NAME hostnames to
#      the two loopback aliases. Uses a cluster-specific temp file to avoid
#      data races when both clusters start in parallel.
#   3. Launches three background kubectl port-forward processes (sudo for port 80):
#        - svc/haproxy-shard-1 -> ALIAS_SHARD1:80  (team-alpha ingress)
#        - svc/haproxy-shard-2 -> ALIAS_SHARD2:80  (team-beta/gamma ingress)
#        - svc/hubble-ui       -> 127.0.0.1:HUBBLE_PORT
#      Each PID is appended to PID_FILE for later cleanup.
#   4. Sleeps 2s for port-forwards to establish, then calls print_table().
#
# Args:    none
# Globals: all script-level globals
# Returns: non-zero if sudo or kubectl commands fail (set -euo pipefail)
# Sudo:    yes — ifconfig alias, cp to /etc/hosts, port-forward on port 80
# Background: starts 3 detached kubectl processes (PIDs in PID_FILE)
# ──────────────────────────────────────────────
start() {
  echo "==> Adding loopback aliases (requires sudo)"
  sudo ifconfig lo0 alias "${ALIAS_SHARD1}" 255.255.255.0
  sudo ifconfig lo0 alias "${ALIAS_SHARD2}" 255.255.255.0

  echo "==> Updating /etc/hosts (requires sudo)"
  local hosts_tmp="/tmp/hosts-${CLUSTER_NAME}.tmp"
  sed "/# ${HOSTS_TAG}/,/# end ${HOSTS_TAG}/d" /etc/hosts > "${hosts_tmp}" \
    && sudo cp "${hosts_tmp}" /etc/hosts && rm -f "${hosts_tmp}"
  printf '%s\n' "${HOSTS_BLOCK}" | sudo tee -a /etc/hosts > /dev/null

  echo "==> Starting port-forwards"
  > "${PID_FILE}"

  sudo KUBECONFIG="${KUBECONFIG_PATH}" "${KUBECTL}" port-forward \
    svc/haproxy-shard-1-kubernetes-ingress \
    --address "${ALIAS_SHARD1}" 80:80 \
    -n haproxy-system &>/tmp/pf-${CLUSTER_NAME}-shard1.log &
  echo $! >> "${PID_FILE}"

  sudo KUBECONFIG="${KUBECONFIG_PATH}" "${KUBECTL}" port-forward \
    svc/haproxy-shard-2-kubernetes-ingress \
    --address "${ALIAS_SHARD2}" 80:80 \
    -n haproxy-system &>/tmp/pf-${CLUSTER_NAME}-shard2.log &
  echo $! >> "${PID_FILE}"

  KUBECONFIG="${KUBECONFIG_PATH}" "${KUBECTL}" port-forward \
    svc/hubble-ui \
    --address 127.0.0.1 "${HUBBLE_PORT}":80 \
    -n kube-system &>/tmp/pf-${CLUSTER_NAME}-hubble.log &
  echo $! >> "${PID_FILE}"

  sleep 2

  if [[ -n "${ZELLIJ_TABLE_FILE:-}" ]]; then
    print_table >> "${ZELLIJ_TABLE_FILE}"
  else
    print_table
  fi
}

# ──────────────────────────────────────────────
case "${1:-start}" in
  stop) stop ;;
  *)    start ;;
esac
