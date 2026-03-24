#!/usr/bin/env bash
# Exposes HAProxy shards + Hubble UI on loopback aliases.
# All settings are overridable via env vars for dual-cluster use.
#
# Usage:
#   ./port-forward.sh            # start (a-cluster defaults)
#   ./port-forward.sh stop       # stop and clean up
#
# Env vars (all optional):
#   CLUSTER_NAME   cluster name          [default: a-cluster]
#   ALIAS_SHARD1   loopback IP shard-1   [default: 127.0.0.2]
#   ALIAS_SHARD2   loopback IP shard-2   [default: 127.0.0.3]
#   HUBBLE_PORT    local port Hubble UI   [default: 12000]
#   RADAR_PORT     local port radar UI    [default: (none)]
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
  sed "/# ${HOSTS_TAG}/,/# end ${HOSTS_TAG}/d" /etc/hosts > /tmp/hosts.tmp \
    && sudo cp /tmp/hosts.tmp /etc/hosts && rm /tmp/hosts.tmp

  echo "Done."
}

# ──────────────────────────────────────────────
print_table() {
  local D="${CLUSTER_NAME}"
  local LT="┌──────────────────────────────────────────────┬──────────────────────────────────────────────────────┐"
  local LH="├──────────────────────────────────────────────┼──────────────────────────────────────────────────────┤"
  local LB="└──────────────────────────────────────────────┴──────────────────────────────────────────────────────┘"

  printf '\n  Cluster: %s\n\n' "${CLUSTER_NAME}"
  printf '  %s\n' "${LT}"
  printf '  │ %-44s │ %-52s │\n' "URL" "What you will find"
  printf '  %s\n' "${LH}"
  printf '  │ %-44s │ %-52s │\n' \
    "http://team-alpha.${D}"    "team-alpha hello app — ← in / → out / ⇄ combined"
  printf '  │ %-44s │ %-52s │\n' \
    "http://team-beta.${D}"     "team-beta  hello app — ← in / → out / ⇄ combined"
  printf '  │ %-44s │ %-52s │\n' \
    "http://team-gamma.${D}"    "team-gamma hello app — ← in / → out / ⇄ combined"
  printf '  %s\n' "${LH}"
  printf '  │ %-44s │ %-52s │\n' \
    "http://traffic-alpha.${D}" "team-alpha traffic monitor — → out + chaos streams"
  printf '  │ %-44s │ %-52s │\n' \
    "http://traffic-beta.${D}"  "team-beta  traffic monitor — → out + chaos streams"
  printf '  │ %-44s │ %-52s │\n' \
    "http://traffic-gamma.${D}" "team-gamma traffic monitor — → out + chaos streams"
  printf '  %s\n' "${LH}"
  printf '  │ %-44s │ %-52s │\n' \
    "http://localhost:${HUBBLE_PORT}" \
    "Hubble UI — network flows, service map, DNS"
  if [[ -n "${RADAR_PORT}" ]]; then
    printf '  │ %-44s │ %-52s │\n' \
      "http://localhost:${RADAR_PORT}" \
      "Radar — cluster resource overview"
  fi
  printf '  %s\n' "${LB}"
  printf '\n  Stop:  ./port-forward.sh stop'
  if [[ "${CLUSTER_NAME}" == "a-cluster" ]]; then
    printf '\n  Switch to b-cluster:  CLUSTER_NAME=b-cluster ALIAS_SHARD1=127.0.0.4 ALIAS_SHARD2=127.0.0.5 HUBBLE_PORT=12001 ./port-forward.sh'
  fi
  printf '\n\n'
}

# ──────────────────────────────────────────────
start() {
  echo "==> Adding loopback aliases (requires sudo)"
  sudo ifconfig lo0 alias "${ALIAS_SHARD1}" 255.255.255.0
  sudo ifconfig lo0 alias "${ALIAS_SHARD2}" 255.255.255.0

  echo "==> Updating /etc/hosts (requires sudo)"
  sed "/# ${HOSTS_TAG}/,/# end ${HOSTS_TAG}/d" /etc/hosts > /tmp/hosts.tmp \
    && sudo cp /tmp/hosts.tmp /etc/hosts && rm /tmp/hosts.tmp
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

  print_table
}

# ──────────────────────────────────────────────
case "${1:-start}" in
  stop) stop ;;
  *)    start ;;
esac
