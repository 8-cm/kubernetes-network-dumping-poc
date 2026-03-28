# Observability Guide

How to observe every layer of communication in the environment using Hubble, tcpdump, tshark, and kubectl logs.

## Tools

| Tool | Purpose | Access |
|------|---------|--------|
| **Hubble UI** | L3/L4 flow graph, service map, drop reasons, egress-gw verdicts, DNS | `http://localhost:12000` (a-cluster), `http://localhost:12001` (b-cluster) |
| **k9s** | Real-time pod/event/log view, exec into pods | `KUBECONFIG=a-cluster.kubeconfig k9s --context kind-a-cluster` |
| **radar** | Web-based cluster resource browser | `radar -kubeconfig a-cluster.kubeconfig -port 9280` |
| **tcpdump** | Raw packet capture at any vantage point | `oc debug node/<node> -- chroot /host tcpdump ...` |
| **tshark** | Wireshark CLI — decode HTTP, DNS, follow streams | `oc debug node/<node> -- chroot /host tshark ...` |
| **kube-dump** | Bulk capture across pods and nodes | `KUBECONFIG=a-cluster.kubeconfig ./tools/kube-dump.sh -l app=... -e 'tcpdump ...'` |

---

## E2E Packet Walk

Full packet path diagrams with a capture command at every hop. `oc debug node` gives a privileged shell on the node; `nsenter -t <PID> -n` enters the pod's network namespace without requiring a privileged pod.

### Ingress: browser → hello pod

```
 [ Browser — macOS ]
     │  GET http://team-alpha.a-cluster/
     │  /etc/hosts: team-alpha.a-cluster → 127.0.0.2
     │
     ▼
 [ lo0 — loopback alias 127.0.0.2:80 ]
     │
     │  sudo tcpdump -i lo0 -n 'host 127.0.0.2 and port 80'
     │  you see: SYN, SYN-ACK, GET / HTTP/1.1, 200 OK
     │
     ▼
 [ kubectl port-forward (sudo) ]
     │  listener: 127.0.0.2:80
     │  tunnel: kube-apiserver → kubelet on worker5 → haproxy pod :80
     │
     ▼
 [ a-cluster-worker5 eth0 ]  172.18.0.5
     │
     │  oc debug node/a-cluster-worker5 -- \
     │    chroot /host tcpdump -i eth0 -n port 80
     │  you see: src=172.18.0.1, dst=172.18.0.5:80
     │           incoming HTTP from port-forward tunnel
     │
     ▼
 [ HAProxy pod — haproxy-system ]
     │  hostPort: worker5:80 → haproxy :80
     │  reads Ingress: host=team-alpha.a-cluster
     │  → backend: hello.team-alpha.svc.cluster.local:80
     │
     │  oc debug node/a-cluster-worker5 -- chroot /host bash -c '
     │    PID=$(crictl inspect \
     │      $(crictl ps -q --name haproxy) | jq .info.pid)
     │    nsenter -t $PID -n -- tcpdump -i eth0 -n port 80'
     │  you see: incoming GET /, outgoing to ClusterIP hello svc
     │
     ▼
 [ Cilium eBPF — DNAT ]
     │  ClusterIP (10.96.x.x:80) → pod IP 10.244.3.7:8080
     │
     ▼
 [ vethXXXXXX on worker5 ]  ← node-side of veth pair
     │
     │  # find veth via nsenter (no exec into pod):
     │  oc debug node/a-cluster-worker5 -- chroot /host bash -c '
     │    PID=$(crictl inspect \
     │      $(crictl ps -q --name hello) | jq .info.pid)
     │    IFIDX=$(nsenter -t $PID -n -- \
     │      cat /sys/class/net/eth0/iflink)
     │    VETH=$(ip link | awk -F": " "/^${IFIDX}:/{print \$2}")
     │    tcpdump -i $VETH -n'
     │  you see: DNAT done, dst=10.244.3.7:8080
     │
     ▼
 [ hello pod eth0 ]  10.244.3.7:8080
     │
     │  oc debug node/a-cluster-worker5 -- chroot /host bash -c '
     │    PID=$(crictl inspect \
     │      $(crictl ps -q --name hello) | jq .info.pid)
     │    nsenter -t $PID -n -- tcpdump -i eth0 -n'
     │  you see: src=HAProxy pod IP, dst=10.244.3.7:8080
     │           plain HTTP, no NAT
     │
     ▼
 [ nginx — HTTP 200 OK ]
```

---

### Egress: team-alpha pod → egress gateway (SNAT)

```
 [ team-alpha pod eth0 ]  10.244.3.7
     │  curl http://172.18.0.15:80
     │
     │  oc debug node/a-cluster-worker1 -- chroot /host bash -c '
     │    PID=$(crictl inspect \
     │      $(crictl ps -q --name hello) | jq .info.pid)
     │    nsenter -t $PID -n -- tcpdump -i eth0 -n'
     │  you see: SYN dst=172.18.0.15:80, src=10.244.3.7
     │           before SNAT — still pod IP
     │
     ▼
 [ Cilium eBPF — EgressGatewayPolicy ]
     │  selector: namespace=team-alpha
     │  egressGateway: a-cluster-worker5 (network-00)
     │  if pod is NOT on worker5 → VXLAN redirect
     │
     ▼
 (cross-node case — pod running on worker1)

 [ a-cluster-worker1 eth0 ]
     │
     │  oc debug node/a-cluster-worker1 -- \
     │    chroot /host tcpdump -i eth0 -n 'udp port 8472'
     │  you see: VXLAN encapsulation
     │           outer: 172.18.0.11 → 172.18.0.5
     │           inner: 10.244.3.7 → 172.18.0.15
     │
     ▼
 [ a-cluster-worker5 eth0 ]  172.18.0.5   ← egress gateway / network-00
     │  Cilium SNAT: src 10.244.3.7 → 172.18.0.5
     │
     │  oc debug node/a-cluster-worker5 -- \
     │    chroot /host tcpdump -i eth0 -n 'dst 172.18.0.15'
     │  you see: SYN src=172.18.0.5 dst=172.18.0.15:80
     │           source IP is always worker5 (deterministic SNAT)
```

---

### E2E Cross-cluster: a-cluster team-alpha → b-cluster hello pod

Full path from the source pod in a-cluster to the destination pod in b-cluster, including all NAT operations.

```
 A-CLUSTER
 ══════════════════════════════════════════════════════

 [ team-alpha pod eth0 ]  10.244.3.7   (running on a-cluster-worker1)
     │  gen-external: curl http://172.18.0.15:80
     │
     │  oc debug node/a-cluster-worker1 -- chroot /host bash -c '
     │    PID=$(crictl inspect \
     │      $(crictl ps -q --name gen-external) | jq .info.pid)
     │    nsenter -t $PID -n -- tcpdump -i eth0 -n'
     │  you see: SYN src=10.244.3.7 dst=172.18.0.15:80
     │           app sends to b-cluster directly, unaware of SNAT
     │
     ▼
 [ Cilium eBPF — EgressGatewayPolicy (team-alpha → network-00) ]
     │  packet intercepted in TC egress hook on pod's veth
     │  → redirected to a-cluster-worker5 via VXLAN
     │
     ▼
 [ a-cluster-worker1 eth0 ]  VXLAN encapsulation
     │
     │  oc debug node/a-cluster-worker1 -- \
     │    chroot /host tcpdump -i eth0 -n 'udp port 8472'
     │  you see: UDP/VXLAN outer: 172.18.0.11 → 172.18.0.5
     │           inner (decode with -X): 10.244.3.7 → 172.18.0.15
     │
     ▼
 [ a-cluster-worker5 eth0 ]  172.18.0.5   ← egress gateway
     │  Cilium SNAT: src 10.244.3.7 → 172.18.0.5
     │  packet leaves a-cluster via Docker bridge
     │
     │  oc debug node/a-cluster-worker5 -- \
     │    chroot /host tcpdump -i eth0 -n \
     │    'tcp and dst 172.18.0.15 and dst port 80'
     │  you see: SYN src=172.18.0.5 dst=172.18.0.15:80
     │           SNAT complete — source IP is network-00

 DOCKER BRIDGE  (platform / host)
 ══════════════════════════════════════════════════════

 [ br-kind ]  172.18.0.0/16
     │  L2 bridge connecting both clusters
     │  !! accessible on Linux host only
     │
     │  sudo tcpdump -i br-kind -n \
     │    'tcp and host 172.18.0.5 and host 172.18.0.15'
     │  you see: all communication between both clusters at L2
     │           src MAC = worker5 NIC, dst MAC = b-cluster-worker5 NIC

 B-CLUSTER
 ══════════════════════════════════════════════════════

 [ b-cluster-worker5 eth0 ]  172.18.0.15
     │  receives packet on hostPort:80 = HAProxy shard-1
     │
     │  oc debug node/b-cluster-worker5 -- \
     │    chroot /host tcpdump -i eth0 -n port 80
     │  you see: SYN src=172.18.0.5, dst=172.18.0.15:80
     │           b-cluster always sees same src IP (team-alpha)
     │           if you see varying src IPs → team-gamma (no policy)
     │
     ▼
 [ HAProxy shard-1 — b-cluster ]
     │  Ingress route: Host header → hello.team-alpha.svc
     │
     │  oc debug node/b-cluster-worker5 -- chroot /host bash -c '
     │    PID=$(crictl inspect \
     │      $(crictl ps -q --name haproxy) | jq .info.pid)
     │    nsenter -t $PID -n -- tcpdump -i eth0 -n port 80'
     │  you see: incoming from 172.18.0.5, outgoing to ClusterIP hello svc
     │
     ▼
 [ Cilium eBPF — DNAT (b-cluster) ]
     │  ClusterIP hello svc → b-cluster hello pod IP
     │
     ▼
 [ vethXXXXXX on b-cluster-worker5 ]
     │
     │  oc debug node/b-cluster-worker5 -- chroot /host bash -c '
     │    PID=$(crictl inspect \
     │      $(crictl ps -q --name hello) | jq .info.pid)
     │    IFIDX=$(nsenter -t $PID -n -- \
     │      cat /sys/class/net/eth0/iflink)
     │    VETH=$(ip link | awk -F": " "/^${IFIDX}:/{print \$2}")
     │    tcpdump -i $VETH -n'
     │  you see: DNAT done, dst=b-cluster hello pod IP
     │
     ▼
 [ b-cluster hello pod eth0 ]
     │
     │  oc debug node/b-cluster-worker5 -- chroot /host bash -c '
     │    PID=$(crictl inspect \
     │      $(crictl ps -q --name hello) | jq .info.pid)
     │    nsenter -t $PID -n -- tcpdump -i eth0 -n'
     │  you see: src=172.18.0.5 (a-cluster network-00)
     │           HTTP GET /, response 200 OK
     │
     ▼
 [ nginx — HTTP 200 OK → back along the same path ]
```

---

### Capture Point Overview

```
 INTERFACE          WHERE              DIR      YOU SEE
 ─────────────────────────────────────────────────────────────────────────────
 eth0 (pod)         pod netns          ↕ both   outbound: what app sends, dst=ClusterIP/peer IP
                                                inbound:  after DNAT, dst=pod IP

 lo (pod)           pod netns          ↕ both   localhost only: sidecar↔container 127.0.0.1
                                                !! veth cannot see this at all

 vethXXXXXX         node netns         ↕ both   identical to pod eth0 (other end of same cable)
 (node-side)                                    accessible without nsenter — one veth = one pod

 eth0 (node)        node netns         ↕ both   outbound: SNAT traffic (egress-gw), VXLAN outer
                                                inbound:  from LB/port-forward, VXLAN from other nodes
                                                hostPort traffic in both directions

 lo (node)          node netns         ↕ both   localhost only: kubelet↔apiserver, healthchecks
                                                pod-to-node via 127.0.0.1

 cilium_host        node netns         ↕ both   outbound: node stack → pod CIDR
                                                inbound:  pod CIDR → node stack

 cilium_vxlan       node netns         ↕ both   outbound: inner packets before VXLAN encapsulation
 or geneve0                                     inbound:  decapsulated inner packets from other nodes
                                                no outer VXLAN headers — clean pod IPs

 any (node netns)   node netns         ↕ both   eth0 + all veth* + lo + cilium_*
                                                = all node traffic including all pods
                                                note: packets are duplicated (eth0 + veth + vxlan)

 any (pod netns)    pod netns          ↕ both   eth0 + lo of this pod only
                                                = traffic of this specific pod only
 ─────────────────────────────────────────────────────────────────────────────
 KIND SPECIFIC

 lo0 (macOS host)   host               ↕ both   port-forward traffic (127.0.0.2/3 → kubectl tunnel)

 br-kind            host (Linux only)  ↕ both   L2 between all Kind nodes, cross-cluster traffic
 ─────────────────────────────────────────────────────────────────────────────
```

**`any` depends on the network namespace:**

```
 node netns (oc debug node)     →  any = eth0 + veth* (all pods) + cilium_* + lo
 pod netns  (nsenter -t PID -n) →  any = eth0 + lo of this pod only
```

**NAT and direction — what you see where:**

```
 OUTBOUND (app → out):
   pod eth0 / veth  →  src=pod IP,  dst=ClusterIP        before DNAT
   node eth0        →  src=pod IP,  dst=pod IP            after DNAT
                       src=node IP, dst=peer              after SNAT (egress-gw)

 INBOUND (reply → app):
   node eth0        →  src=pod IP,  dst=pod IP            before reverse DNAT
   veth / pod eth0  →  src=pod IP,  dst=pod IP            after reverse DNAT
```

### Quick reference — commands

```
 LEVEL              COMMAND
 ──────────────────────────────────────────────────────────────────────────────
 macOS lo0          sudo tcpdump -i lo0 -n 'host 127.0.0.2 or host 127.0.0.3'

 node eth0          oc debug node/<node> -- \
                      chroot /host tcpdump -i eth0 -n [filter]

 node any           oc debug node/<node> -- \
                      chroot /host tcpdump -i any -n [filter]

 node veth          oc debug node/<node> -- chroot /host bash -c '
 (pod uplink)         PID=$(crictl inspect \
                        $(crictl ps -q --name <app>) | jq .info.pid)
                      IFIDX=$(nsenter -t $PID -n -- \
                        cat /sys/class/net/eth0/iflink)
                      VETH=$(ip link | awk -F": " "/^${IFIDX}:/{print \$2}")
                      tcpdump -i $VETH -n'

 pod eth0           oc debug node/<node> -- chroot /host bash -c '
 (no exec into pod)   PID=$(crictl inspect \
                        $(crictl ps -q --name <app>) | jq .info.pid)
                      nsenter -t $PID -n -- tcpdump -i eth0 -n'

 pod lo             oc debug node/<node> -- chroot /host bash -c '
 (sidecar traffic)    PID=$(crictl inspect \
                        $(crictl ps -q --name <app>) | jq .info.pid)
                      nsenter -t $PID -n -- tcpdump -i lo -n'

 pod any            oc debug node/<node> -- chroot /host bash -c '
 (pod eth0 + lo)      PID=$(crictl inspect \
                        $(crictl ps -q --name <app>) | jq .info.pid)
                      nsenter -t $PID -n -- tcpdump -i any -n'

 VXLAN tunnel       oc debug node/<node> -- \
 (cross-node)         chroot /host tcpdump -i eth0 -n 'udp port 8472'

 cilium_vxlan       oc debug node/<node> -- \
 (inner packets)      chroot /host tcpdump -i cilium_vxlan -n

 Docker bridge      sudo tcpdump -i br-kind -n            # Linux host only
```

**Why `lo` cannot be captured via veth:**

```
┌─ pod netns ──────────────────────────────────────────────┐
│                                                          │
│  gen-cross ──lo:127.0.0.1──> nginx                      │  ← veth CANNOT SEE
│                                                          │
│  gen-cross ──eth0────────────────────────────────────────┼──> vethXXX
│                                                          │  ← veth CAN SEE
└──────────────────────────────────────────────────────────┘
```

Example: in the `hello` pod, the `gen-cross` sidecar communicates with nginx via `127.0.0.1:8080` — this is visible **only** via `nsenter ... tcpdump -i lo`.

---

## Vantage Points

### 1. Pod network namespace

Captures traffic as seen by the application — before any eBPF NAT. Shows the real destination IP the app used (ClusterIP, peer IP), not what the packet carries after DNAT.

```bash
NODE=$(kubectl --kubeconfig a-cluster.kubeconfig \
  get pod -n team-alpha -l app=traffic-monitor \
  -o jsonpath='{.items[0].spec.nodeName}')

oc debug node/$NODE -- chroot /host bash -c '
  PID=$(crictl inspect \
    $(crictl ps -q --name gen-external) | jq .info.pid)
  nsenter -t $PID -n -- tcpdump -i eth0 -n tcp'
```

**What you see**: DNS queries to kube-dns, TCP SYN to ClusterIP (before DNAT), RST from blackhole service (ClusterIP with no endpoints).

---

### 2. Worker node — after eBPF DNAT

After Cilium DNAT, ClusterIP addresses are replaced with real pod IPs. This is the first point where you see actual pod-to-pod flows.

```bash
# All TCP port 80 on the node
oc debug node/a-cluster-worker1 -- \
  chroot /host tcpdump -i any -n tcp port 80

# Filter on a specific pod (find IP first)
POD_IP=$(kubectl --kubeconfig a-cluster.kubeconfig -n team-alpha \
  get pod -l app=traffic-monitor -o jsonpath='{.items[0].status.podIP}')
oc debug node/a-cluster-worker1 -- \
  chroot /host tcpdump -i any -n host $POD_IP

# DNS from all pods on the node
oc debug node/a-cluster-worker1 -- \
  chroot /host tcpdump -i any -n udp port 53
```

**What you see**: pod-to-pod TCP after DNAT, DNS queries and responses. No ClusterIPs here — only pod IPs.

---

### 3. Network node — ingress (shard-1 on worker5)

All inbound traffic for `team-alpha` and `traffic-alpha` enters through worker5's eth0.

```bash
# All port 80 on the ingress node
oc debug node/a-cluster-worker5 -- \
  chroot /host tcpdump -i eth0 -n tcp port 80

# HTTP decode via tshark
oc debug node/a-cluster-worker5 -- chroot /host bash -c '
  tshark -i eth0 -f "tcp port 80" -Y "http.request" \
    -T fields \
    -e frame.time_relative \
    -e ip.src \
    -e ip.dst \
    -e http.host \
    -e http.request.uri \
    -e http.request.method 2>/dev/null'

# HAProxy access log
kubectl --kubeconfig a-cluster.kubeconfig logs -n haproxy-system \
  -l "app.kubernetes.io/name=kubernetes-ingress,app.kubernetes.io/instance=haproxy-shard-1" -f
```

**What you see**: incoming port-forward connections, HAProxy proxying to pod IPs, outbound egress traffic from team-alpha pods SNATed to worker5's IP.

---

### 4. Network node — egress gateway (SNAT point)

The most informative capture point for demonstrating CiliumEgressGateway. All external traffic from `team-alpha` leaves the cluster via worker5, regardless of which worker the pod is running on.

```bash
# Egress traffic on network-00 (team-alpha gateway)
oc debug node/a-cluster-worker5 -- \
  chroot /host tcpdump -i eth0 -n \
  'tcp and not dst net 10.0.0.0/8 and not dst net 192.168.0.0/16'

# On network-01 (team-beta gateway)
oc debug node/a-cluster-worker6 -- \
  chroot /host tcpdump -i eth0 -n \
  'tcp and not dst net 10.0.0.0/8 and not dst net 192.168.0.0/16'

# On a regular worker (team-gamma — non-deterministic source IP)
oc debug node/a-cluster-worker2 -- \
  chroot /host tcpdump -i eth0 -n \
  'tcp and not dst net 10.0.0.0/8'
```

**alpha/beta**: all cross-cluster TCP always appears here with src=network node IP.
**gamma**: cross-cluster TCP appears on whichever worker the pod is currently running on — src IP changes with every rescheduling.

---

### 5. Docker bridge — cross-cluster traffic

The Docker bridge `br-kind` carries all communication between both clusters.

```bash
# Find bridge interface name
BRIDGE=$(docker network ls --filter name=kind --format '{{.ID}}' | head -1 | cut -c1-12)
echo "Bridge: br-$BRIDGE"

# All cross-cluster HTTP (Linux host only)
sudo tcpdump -i br-$BRIDGE -n tcp port 80

# Decode via tshark — show Host header
sudo tshark -i br-$BRIDGE -f 'tcp port 80' \
  -Y 'http.request' \
  -T fields \
  -e frame.time_relative \
  -e ip.src \
  -e ip.dst \
  -e http.host \
  -e http.request.method

# SYN packets only — watch connection establishment
sudo tcpdump -i br-$BRIDGE -n -tttt \
  'tcp port 80 and (tcp[tcpflags] & tcp-syn != 0)'
```

**What you see**: TCP connections between cluster Docker IPs. The source IP reveals which network node is acting as egress gateway — `172.18.A.5` for alpha, `172.18.A.6` for beta, variable for gamma.

---

## Side-by-side: alpha vs gamma egress

Run in three terminals simultaneously — observe the SNAT difference live.

**Terminal 1** — worker5: only team-alpha egress appears here
```bash
oc debug node/a-cluster-worker5 -- \
  chroot /host tcpdump -i eth0 -n \
  'tcp dst port 80 and not src net 10.0.0.0/8'
```

**Terminal 2** — find and watch the gamma worker
```bash
GAMMA_NODE=$(kubectl --kubeconfig a-cluster.kubeconfig \
  get pod -n team-gamma -l app=traffic-external \
  -o jsonpath='{.items[0].spec.nodeName}')
oc debug node/$GAMMA_NODE -- \
  chroot /host tcpdump -i eth0 -n \
  'tcp dst port 80 and not src net 10.0.0.0/8'
```

**Terminal 3** — Hubble UI: `http://localhost:12000`, Service Map tab.

In Hubble: team-alpha flows show `worker5` as an intermediate hop (egress gateway verdict). team-gamma flows have no egress gateway — the packet exits directly from the pod's worker.

---

## Hubble UI filters

| What to watch | Filter |
|---------------|--------|
| All team-alpha traffic | Namespace: `team-alpha` |
| Egress-gateway verdicts | Verdict: `FORWARDED`, destination outside pod CIDR |
| TCP RST from blackhole | Verdict: `DROPPED`, destination service: `blackhole` |
| Cross-cluster flows | Destination IP: b-cluster Docker subnet (`172.18.x.x`) |
| DNS queries | Destination port: `53` |
| Ingress from HAProxy | Source: HAProxy pod IP, Destination namespace: `team-alpha` |
| 404 chaos requests | HTTP response code (if L7 policy is enabled) |

---

## kubectl log streams

```bash
# team-alpha generators — raw output
kubectl --kubeconfig a-cluster.kubeconfig logs -n team-alpha \
  deploy/traffic-monitor -c gen-internal -f

kubectl --kubeconfig a-cluster.kubeconfig logs -n team-alpha \
  deploy/traffic-monitor -c gen-external -f

kubectl --kubeconfig a-cluster.kubeconfig logs -n team-alpha \
  deploy/traffic-monitor -c gen-chaos -f

# hello gen-cross sidecar
kubectl --kubeconfig a-cluster.kubeconfig logs -n team-alpha \
  deploy/hello -c gen-cross -f

# HAProxy access log (shard-1)
kubectl --kubeconfig a-cluster.kubeconfig logs -n haproxy-system \
  -l "app.kubernetes.io/instance=haproxy-shard-1" -f

# Cilium agent logs (egress-gw decisions)
kubectl --kubeconfig a-cluster.kubeconfig logs -n kube-system \
  -l k8s-app=cilium -c cilium-agent -f | grep -i egress
```

---

## Saving pcap for Wireshark

```bash
# Capture on the node and save to file
oc debug node/a-cluster-worker5 -- chroot /host bash -c '
  tcpdump -i eth0 -n -w /tmp/cap.pcap tcp port 80 &
  sleep 30
  kill %1'

# Copy from node debug pod to host
# (oc debug pod stays alive — open a second terminal)
kubectl cp <debug-pod>:/host/tmp/cap.pcap ./capture.pcap
# Open in Wireshark on host
open ./capture.pcap
```

---

## What changes after a team-gamma pod restart

```bash
# Before restart: record current worker and src IP seen at b-cluster
kubectl --kubeconfig a-cluster.kubeconfig get pod -n team-gamma \
  -l app=traffic-external -o wide

# Watch SYN packets on b-cluster-worker5
oc debug node/b-cluster-worker5 -- \
  chroot /host tcpdump -i eth0 -n \
  'tcp port 80 and tcp[tcpflags] & tcp-syn != 0' &

# Restart the pod
kubectl --kubeconfig a-cluster.kubeconfig rollout restart \
  -n team-gamma deploy/traffic-external

# Watch: src IP in b-cluster capture changes if pod lands on a different worker
kubectl --kubeconfig a-cluster.kubeconfig get pod -n team-gamma \
  -l app=traffic-external -o wide -w
```

Repeat the same test for team-alpha — the src IP at b-cluster will NOT change regardless of which worker the pod lands on. That is the egress gateway guarantee.

---

## kube-dump.sh — bulk capture

`tools/kube-dump.sh` launches a debug pod next to each selected pod and executes a command inside its network namespace via nsenter — no `kubectl exec` or privileged container required.

Default image is `nicolaka/netshoot` (includes tcpdump, tshark, strace, ss, ip, curl, …).

Placeholders in commands:
- `%t` — name of the target pod or node
- `%n` — name of the node where the pod runs
- `%f` — path to the imported file (after `--import-file`)

Always set kubeconfig before running:
```bash
export KUBECONFIG=$(pwd)/a-cluster.kubeconfig
```

---

### Example 1 — single label, all namespaces

Captures traffic from all `traffic-external` pods at once (team-alpha, team-beta, team-gamma):

```bash
export KUBECONFIG=$(pwd)/a-cluster.kubeconfig

./tools/kube-dump.sh \
  -l app=traffic-external \
  -e 'tcpdump -i any -nn -s 0 -w /tmp/%t.pcap' \
  -s 'ls /tmp/%t.pcap' \
  -o ./captures/external-all \
  --kill-switch-abs 50MB \
  --install-deps
```

Output in `captures/external-all/`:
```
traffic-external-xxx-team-alpha-command-0.log
traffic-external-xxx-team-beta-command-0.log
traffic-external-xxx-team-gamma-command-0.log
traffic-external-xxx-team-alpha.pcap
...
```

---

### Example 1b — write to node filesystem, debug pods in dummy NS

The pcap is written directly to the node's disk (`/host/var/tmp/`) — survives a debug pod restart and does not consume pod ephemeral storage. Kill switch monitors node disk, not pod disk. Debug pods are created in the `dummy` namespace (pre-created by setup.sh).

```bash
export KUBECONFIG=$(pwd)/a-cluster.kubeconfig

./kube-dump.sh \
  -l app=traffic-monitor \
  -e 'tcpdump -i any -nn -s 0 -w /host/var/tmp/POD_%t.pcap' \
  -s 'ls /host/var/tmp/*.pcap' \
  -o ./captures/external-all \
  -n dummy \
  --kill-switch-abs 50MB \
  --install-deps \
  --pod-volume /host/var/tmp
```

Captures all three `traffic-monitor` pods (team-alpha, team-beta, team-gamma). Files `POD_<pod-name>.pcap` on each node — downloaded to `captures/external-all/`.

---

### Example 2 — multiple labels from different namespaces (OR logic)

Captures traffic from both `traffic-external` and `hello` pods simultaneously — different apps, different namespaces:

```bash
export KUBECONFIG=$(pwd)/a-cluster.kubeconfig

./tools/kube-dump.sh \
  -l app=traffic-external \
  -l app=hello \
  -e 'tcpdump -i any -nn -s 0 -c 200 -w /tmp/%t.pcap' \
  -s 'ls /tmp/%t.pcap' \
  -o ./captures/multi-label \
  --kill-switch-abs 100MB \
  --install-deps
```

Each `-l` is OR — the script finds pods matching ANY selector. In this case 6 pods (3× traffic-external + 3× hello).

---

### Example 3 — network nodes + tshark (HTTP decode)

Worker5 and worker6 have the `node-role=network` label and host HAProxy. tshark on their `eth0` sees all ingress/egress:

```bash
export KUBECONFIG=$(pwd)/a-cluster.kubeconfig

./tools/kube-dump.sh \
  -L node-role=network \
  -E 'tshark -i eth0 -f "tcp port 80" -T fields \
    -e frame.time_relative \
    -e ip.src \
    -e ip.dst \
    -e http.request.method \
    -e http.request.uri \
    -e http.response.code \
    2>/dev/null | tee /tmp/%t-http.log' \
  -S 'ls /tmp/%t-http.log' \
  -o ./captures/network-nodes \
  --install-deps
```

For pcap instead of live output:
```bash
./tools/kube-dump.sh \
  -L node-role=network \
  -E 'tshark -i eth0 -f "tcp port 80" -w /tmp/%t.pcap' \
  -S 'ls /tmp/%t.pcap' \
  -o ./captures/network-nodes \
  --kill-switch-abs 200MB \
  --install-deps
```

---

### Example 4 — include-nodes, multiple -e and -E, import script

Captures network traffic inside the pod (nsenter → pod netns) and simultaneously on the node hosting the pod — two vantage points at once.

First create a local script for node-side diagnostics:

```bash
cat > /tmp/node-egress-check.sh << 'EOF'
#!/bin/sh
echo "=== $(hostname) ==="
echo "--- routing ---"
ip route show
echo "--- active TCP (dst :80) ---"
ss -tun dst :80
echo "--- last 30 SYN on eth0 ---"
tcpdump -i eth0 -nn -c 30 'tcp[tcpflags] & tcp-syn != 0 and dst port 80' 2>/dev/null
EOF
```

Run:
```bash
export KUBECONFIG=$(pwd)/a-cluster.kubeconfig

./tools/kube-dump.sh \
  -l app=traffic-external \
  -e 'tcpdump -i eth0 -nn -s 0 -w /tmp/%t-pod.pcap' \
  -e 'ss -tunap > /tmp/%t-sockets.txt' \
  --include-nodes \
  --import-file /tmp/node-egress-check.sh \
  -E 'bash %f | tee /tmp/%t-node-diag.log' \
  -E 'tcpdump -i eth0 -nn -s 0 -w /tmp/%t-node.pcap tcp port 80' \
  -s 'ls /tmp/%t-pod.pcap /tmp/%t-sockets.txt' \
  -S 'ls /tmp/%t-node-diag.log /tmp/%t-node.pcap' \
  -o ./captures/egress-debug \
  --kill-switch-abs 200MB \
  --install-deps
```

What it runs:
- `-e` command 0 — tcpdump inside pod netns (nsenter → pod `eth0`)
- `-e` command 1 — `ss` inside pod netns (active TCP connections)
- `--include-nodes` — automatically includes the worker nodes where the pods run
- `-E` command 0 — imported script on the node (routing + ss + SYN capture)
- `-E` command 1 — tcpdump on node `eth0` (sees SNAT/masquerade output)

---

### Example 5 — strace network syscalls (with import-file)

Enters the PID and network namespace of the target pod and traces `connect`, `sendto`, `recvfrom` for every process in the container.

```bash
cat > /tmp/strace-net.sh << 'EOF'
#!/bin/sh
# Mount /proc so strace can see PIDs in the target PID namespace
mount -t proc none /proc 2>/dev/null
OUTDIR=/tmp/strace
mkdir -p $OUTDIR
# Spusť strace pro každý proces v kontejneru
for pid in $(ls /proc | grep -E '^[0-9]+$'); do
  [ -d /proc/$pid/fd ] || continue
  strace -f -p $pid \
    -e trace=network \
    -e signal=none \
    -o $OUTDIR/$pid.strace \
    2>/dev/null &
done
sleep 30
kill $(jobs -p) 2>/dev/null
wait
EOF
```

```bash
export KUBECONFIG=$(pwd)/a-cluster.kubeconfig

./tools/kube-dump.sh \
  -l app=traffic-external \
  -n team-gamma \
  --import-file /tmp/strace-net.sh \
  -e 'bash %f' \
  --nsenter-params n,p \
  -s 'ls /tmp/strace/*.strace' \
  -o ./captures/strace-gamma \
  --install-deps \
  --no-cleanup
```

`--nsenter-params n,p` — enters both the **network** and **PID** namespace of the pod. `--no-cleanup` leaves the debug pod running for log inspection.

Output: `NNN.strace` files for each PID in the container, containing calls like:
```
connect(5, {sa_family=AF_INET, sin_port=htons(80), sin_addr=inet_addr("172.18.0.15")}, 16) = 0
sendto(5, "GET / HTTP/1.1\r\nHost: ...", ...)
recvfrom(5, "HTTP/1.1 200 OK\r\n...", ...)
```
