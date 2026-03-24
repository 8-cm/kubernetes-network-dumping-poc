#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(realpath "$(dirname "$0")")"
CLUSTER_NAME="multi-cp-cluster"
KUBECONFIG_PATH="${SCRIPT_DIR}/../${CLUSTER_NAME}.kubeconfig"
KUBECTL="$(command -v kubectl)"
K="${KUBECTL} --kubeconfig ${KUBECONFIG_PATH}"

# ──────────────────────────────────────────────
# 1. Ensure CiliumEgressGatewayPolicy CRD exists
#    (operator registers it; restart forces it if
#     egressGateway was just enabled)
# ──────────────────────────────────────────────
if ! $K get crd ciliumegressgatewaypolicies.cilium.io &>/dev/null; then
  echo "==> CRD missing — restarting Cilium operator to register it"
  $K rollout restart deployment/cilium-operator -n kube-system
  $K rollout status deployment/cilium-operator -n kube-system --timeout=120s

  echo "==> Waiting for CiliumEgressGatewayPolicy CRD..."
  for i in $(seq 1 30); do
    $K get crd ciliumegressgatewaypolicies.cilium.io &>/dev/null && break
    sleep 2
  done
fi
$K get crd ciliumegressgatewaypolicies.cilium.io

# ──────────────────────────────────────────────
# 2. Resolve network node IPs dynamically
# ──────────────────────────────────────────────
echo "==> Resolving network node IPs"
WORKER5_IP=$($K get node "${CLUSTER_NAME}-worker5" \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
WORKER6_IP=$($K get node "${CLUSTER_NAME}-worker6" \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

echo "    worker5 → team-alpha egress IP: ${WORKER5_IP}"
echo "    worker6 → team-beta  egress IP: ${WORKER6_IP}"

# ──────────────────────────────────────────────
# 3. Create namespaces
# ──────────────────────────────────────────────
echo "==> Applying namespaces"
$K apply -f "${SCRIPT_DIR}/namespaces.yaml"

# ──────────────────────────────────────────────
# 4. Apply CiliumEgressGatewayPolicies
# ──────────────────────────────────────────────
echo "==> Applying CiliumEgressGatewayPolicies"

$K apply -f - <<EOF
---
# team-alpha → egress via worker5 (${WORKER5_IP})
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: egress-team-alpha
spec:
  selectors:
    - podSelector:
        matchLabels: {}
      namespaceSelector:
        matchLabels:
          egress-group: alpha
  destinationCIDRs:
    - 0.0.0.0/0
  egressGateway:
    nodeSelector:
      matchLabels:
        kubernetes.io/hostname: ${CLUSTER_NAME}-worker5
    egressIP: ${WORKER5_IP}
---
# team-beta → egress via worker6 (${WORKER6_IP})
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: egress-team-beta
spec:
  selectors:
    - podSelector:
        matchLabels: {}
      namespaceSelector:
        matchLabels:
          egress-group: beta
  destinationCIDRs:
    - 0.0.0.0/0
  egressGateway:
    nodeSelector:
      matchLabels:
        kubernetes.io/hostname: ${CLUSTER_NAME}-worker6
    egressIP: ${WORKER6_IP}
EOF

# ──────────────────────────────────────────────
# 5. Summary
# ──────────────────────────────────────────────
echo ""
echo "==> Namespaces:"
$K get ns team-alpha team-beta --show-labels

echo ""
echo "==> CiliumEgressGatewayPolicies:"
$K get ciliumegressgatewaypolicies

echo ""
echo "==> To verify egress IPs (requires external connectivity from nodes):"
echo "    # team-alpha pods egress from ${WORKER5_IP}"
echo "    kubectl run test --image=curlimages/curl -n team-alpha --rm -it -- curl ifconfig.me"
echo ""
echo "    # team-beta pods egress from ${WORKER6_IP}"
echo "    kubectl run test --image=curlimages/curl -n team-beta --rm -it -- curl ifconfig.me"
