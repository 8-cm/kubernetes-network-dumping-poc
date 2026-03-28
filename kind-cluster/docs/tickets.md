# Investigation Tickets

Sample real-world investigations captured at node level using `oc debug node` + `nsenter`. Each ticket shows a different traffic type and a different capture point.

---

## TICKET-4471 · team-gamma · Priority: High

**Title:** Intermittent connection refused to b-cluster after pod restart

**Reported by:** Martin K., backend developer, team-gamma

---

**Problem description**

> Hi, we have an issue with `traffic-external` in `team-gamma`. The app occasionally stops reaching b-cluster and returns connection refused. It happens every time after a deployment or pod restart. Works for a few minutes then stops. Team-alpha and team-beta don't have this problem. I don't understand why — the code is identical.
>
> — Martin, 09:14

---

**Investigation**

First checked where the pod is currently running and what source IP it uses for outbound traffic:

```bash
kubectl get pod -n team-gamma -l app=traffic-external -o wide
# NAME                                READY   NODE
# traffic-external-64d44786db-wdf8x   1/1     a-cluster-worker3  (172.18.0.10)
```

Captured egress traffic directly on worker3:

```bash
oc debug node/a-cluster-worker3 -- \
  chroot /host tcpdump -i eth0 -n \
  'tcp and dst port 80'
# 09:21:03 IP 172.18.0.10.54821 > 172.18.0.15.80: Flags [S]   ← SYN sent
# 09:21:03 IP 172.18.0.15.80 > 172.18.0.10.54821: Flags [R.]  ← RST from b-cluster
```

Source IP is `172.18.0.10` — worker3's IP. Same command on worker5 (team-alpha egress-gw):

```bash
oc debug node/a-cluster-worker5 -- \
  chroot /host tcpdump -i eth0 -n \
  'tcp and dst port 80'
# 09:21:05 IP 172.18.0.8.49302 > 172.18.0.15.80: Flags [S]
# 09:21:05 IP 172.18.0.15.80 > 172.18.0.8.49302: Flags [S.]  ← SYN-ACK, works
```

Team-alpha always uses `172.18.0.8` (worker5). Team-gamma uses the IP of whichever worker the pod is currently on.

Verified in b-cluster HAProxy access log what is happening on the receiving end:

```bash
kubectl --kubeconfig b-cluster.kubeconfig logs -n haproxy-system \
  -l "app.kubernetes.io/instance=haproxy-shard-1" --tail=20
# 172.18.0.8  "GET / HTTP/1.1" 200   ← team-alpha, OK
# 172.18.0.10 "GET / HTTP/1.1" 403   ← team-gamma, blocked IP
```

**Root cause:** B-cluster has an IP whitelist — it allows only `172.18.0.8` (alpha egress-gw) and `172.18.0.4` (beta egress-gw). Team-gamma has no `CiliumEgressGatewayPolicy`, so egress goes directly from whichever worker the pod is on. After each restart or rescheduling the pod lands on a different node → source IP changes → b-cluster whitelist drops the connection.

---

**Why team-alpha and team-beta are not affected**

| namespace | egress gateway | src IP at b-cluster | stable? |
|-----------|---------------|---------------------|---------|
| team-alpha | worker5 (network-00) | `172.18.0.8` always | yes |
| team-beta | worker6 (network-01) | `172.18.0.4` always | yes |
| team-gamma | none | current worker's IP | no |

---

**Fix**

Add a `CiliumEgressGatewayPolicy` for team-gamma (same pattern as alpha/beta) and add the chosen network node IP to the whitelist on the b-cluster side.

Alternative if we don't want to pin to a specific node: deploy Cilium Cluster Mesh with mTLS — then access is based on identity, not IP.

---

**Reply to Martin**

> Found the cause. Team-gamma has no egress gateway policy, so the source IP changes with every pod restart. B-cluster has an IP whitelist that doesn't know the new IP and drops the connection. Team-alpha and beta have the egress gateway fixed to a specific node, so their IP is always the same regardless of which worker the pod is on. Preparing a PR with the egress policy for team-gamma.

---

## TICKET-4489 · team-alpha · Priority: Medium

**Title:** App reporting `connection refused` errors in logs — is this a network issue?

**Reported by:** Jana P., SRE, team-alpha

---

**Problem description**

> In the `traffic-monitor` logs we see entries `chaos → blackhole: connection refused`. We don't know if it's an app bug or if someone is blocking our traffic. Can you take a look?
>
> — Jana, 14:02

---

**Investigation**

Checked the log:

```bash
kubectl logs -n team-alpha deploy/traffic-monitor -c gen-chaos --tail=10
# [14:01:49] chaos → blackhole.team-alpha: connection refused
# [14:01:56] chaos → http://haproxy-shard-1/chaos-not-found: 404
# [14:02:03] chaos → http://haproxy-shard-1/: 200
```

`connection refused` = curl received a TCP RST — connection rejected before HTTP handshake. Captured on the node where `traffic-monitor` is running (worker2):

```bash
oc debug node/a-cluster-worker2 -- \
  chroot /host tcpdump -i any -n \
  'host 10.244.9.43 and tcp[tcpflags] & tcp-rst != 0'
# 14:01:49 IP 10.244.9.43.39812 > 10.96.x.x.80: Flags [S]
# 14:01:49 IP 10.96.x.x.80    > 10.244.9.43.39812: Flags [R.]
```

SYN → RST with no SYN-ACK. No three-way handshake, no timeout — RST arrived immediately.

Verified blackhole service endpoints:

```bash
kubectl get endpoints blackhole -n team-alpha
# NAME        ENDPOINTS   AGE
# blackhole   <none>      2d
```

**Root cause:** Intentional behavior. The `blackhole` service has no endpoints — the selector `app=blackhole-nonexistent` intentionally matches no pod. Cilium responds with an immediate TCP RST without waiting for a timeout. `connection refused` is the correct curl response to a TCP RST. This is not a network issue or a bug.

---

**Reply to Jana**

> This is not a bug or blocking. The blackhole service is intentionally deployed without pods — it demonstrates how Cilium handles traffic to a service with no endpoints. Instead of a timeout it sends an immediate TCP RST, which is why curl reports `connection refused`. Gen-chaos does this every ~42 seconds as part of the chaos traffic pattern. In Hubble UI you can see it as a `DROPPED` flow with reason `no endpoints`.

---

## TICKET-4491 · team-alpha · Priority: Low

**Title:** HTTP 404 errors in traffic-monitor logs — wrong ingress config?

**Reported by:** Jana P., SRE, team-alpha

---

**Problem description**

> Hi, me again. In the `traffic-monitor` logs we see regular HTTP 404 entries — `chaos → /chaos-not-found: 404`. We're worried we have a misconfigured ingress and some traffic is falling through to a non-existent path. Is this our problem or HAProxy?
>
> — Jana, 14:35

---

**Investigation**

Checked the log:

```bash
kubectl logs -n team-alpha deploy/traffic-monitor -c gen-chaos --tail=10
# [14:34:52] chaos → http://haproxy-shard-1/chaos-not-found: 404
# [14:34:59] chaos →  blackhole.team-alpha: connection refused
# [14:35:06] chaos → http://haproxy-shard-1/: 200
```

The 404s arrive regularly, not randomly. Captured traffic on worker2 where `traffic-monitor` runs — the 404 goes through HAProxy (real TCP connection), so it is visible directly on the node without nsenter:

```bash
# Command 1 — capture for 30s and save to node, then keep pod alive
oc debug node/a-cluster-worker2 -n dummy --image=nicolaka/netshoot -- \
  chroot /host bash -c '
    tcpdump -i any -n \
      -w /tmp/chaos-404.pcap \
      "host 10.244.8.140 or host 10.244.4.119" &
    sleep 30 && kill %1 && sleep infinity'
```

```bash
# Command 2 — in a second terminal, download the pcap
kubectl get pod -n dummy   # find debug pod name
oc -n dummy cp <pod-name>:/host/tmp/chaos-404.pcap ~/captures/chaos-404.pcap
```

After downloading the pcap, opened in Wireshark with `http` filter:

```
GET /chaos-not-found HTTP/1.1
Host: haproxy-shard-1-kubernetes-ingress.haproxy-system.svc
→  HTTP/1.1 404 Not Found
   Server: haproxy
```

HAProxy returned 404 because no Ingress rule matches the path `/chaos-not-found`. The connection was established successfully (TCP handshake completed), the response arrived immediately — not a network issue.

Verified Ingress rules:

```bash
kubectl get ingress -n team-alpha
# NAME               HOSTS                      PATHS
# hello-ingress      team-alpha.a-cluster       /
# traffic-ingress    traffic-alpha.a-cluster    /
```

The path `/chaos-not-found` does not exist in any rule — HAProxy correctly returns 404.

**Root cause:** Intentional gen-chaos behavior. Every fourth request deliberately targets the non-existent path `/chaos-not-found` to demonstrate how HAProxy handles an unmatched path. The ingress configuration is correct.

---

**Reply to Jana**

> Ingress is configured correctly. Gen-chaos intentionally sends every fourth request to `/chaos-not-found` — a path that doesn't exist in the Ingress rules. HAProxy responds with a standard 404. This is part of the chaos traffic pattern to demonstrate different error types. If you saw 404s on paths like `/` or other valid endpoints, that would be a problem — this one is not.
