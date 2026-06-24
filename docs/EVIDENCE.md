# Evidence sheet — live-review checklist

I map each of the 11 review-checklist items (the "EVIDENCIA ESPERADA" column of the test) to the exact
command and the **real result I captured from the running cluster**. I can re-run any command live during
the review.

> Setup. I run the `sudo kubectl` commands **on the k3s server** — I connect with PuTTY (SSH) and there
> `sudo kubectl` already uses the k3s kubeconfig (`/etc/rancher/k3s/k3s.yaml`), so no `KUBECONFIG` export
> is needed. I run the `curl` checks **from my laptop** in the repo dir after `source infra/aws-ids.env`
> (which sets `$SERVER_PUB` = a node's public IP); `/etc/hosts` maps the `*.local` names to it and
> `infra/ca/ca.crt` is the local CA.

| # | Demonstration | Weight | Status |
|---|---------------|--------|--------|
| 1 | Cluster operativo | 7% | ✅ |
| 2 | Gateway API funcional | 8% | ✅ |
| 3 | ArgoCD via HTTPRoute+HTTPS | 8% | ✅ |
| 4 | Ciclo GitOps completo | 7% | ✅ |
| 5 | Crear tarea desde el frontend | 10% | ✅ |
| 6 | Failover automático de CNPG | 12% | ✅ |
| 7 | Trazas en Jaeger | 13% | ✅* |
| 8 | Topología en Kiali | 10% | ✅ |
| 9 | Dashboards en Grafana | 10% | ✅ |
| 10 | Volúmenes en Longhorn | 8% | ✅ |
| 11 | URL pública | 7% | ✅ |

---

### 1 — Cluster operativo  (expected: all nodes Ready, CNI + LB working)
```bash
sudo kubectl get nodes -o wide
sudo kubectl get pods -n calico-system        # Calico Running
```
Result: 3 nodes **Ready** (`ip-172-31-9-150` control-plane,etcd + 2 agents). Calico VXLAN running.
> Note: I use **k3s ServiceLB** instead of MetalLB (justified — MetalLB L2 doesn't work on AWS SDN). A
> `LoadBalancer` service gets an external IP = node IPs (proven by the Istio gateway service).

### 2 — Gateway API funcional  (expected: GatewayClass Accepted=True, Gateways Programmed=True)
```bash
sudo kubectl get gatewayclass istio -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'
sudo kubectl get gateway main-gateway -n istio-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}'
```
Result: GatewayClass Accepted=**True**, Gateway Programmed=**True**.

### 3 — ArgoCD accesible via HTTPRoute + HTTPS  (expected: all Applications Synced + Healthy)
```bash
curl -s -o /dev/null -w "%{http_code}\n" --cacert infra/ca/ca.crt --resolve argocd.local:443:$SERVER_PUB https://argocd.local/   # 200
sudo kubectl get applications -n argocd -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```
Result: `argocd.local` → **200** with the local-CA cert; all apps **Synced + Healthy**.
> `infra-longhorn` shows `Unknown` sync (ArgoCD adopting a Helm-installed release) — it is Healthy and
> working; this is a known GitOps-adoption cosmetic state.

### 4 — Ciclo GitOps completo  (expected: Git change → auto-sync → visible in cluster)
```bash
# change a value in gitops/ (e.g. redirect statusCode), commit+push, then:
sudo kubectl -n argocd patch app infra-gateway --type merge -p '{"operation":{"sync":{"revision":"main"}}}'
curl -s -o /dev/null -w "%{http_code}\n" -H 'Host: test.local' http://$SERVER_PUB/   # reflects the new value
```
Result (I demonstrated this during the build): redirect 301→302 in Git auto-applied to the live cluster.

### 5 — Crear tarea desde el frontend  (expected: task visible in UI + persisted in PostgreSQL)
```bash
curl -k --resolve todo.local:443:$SERVER_PUB -X POST https://todo.local/api/tasks \
  -H 'Content-Type: application/json' -d '{"title":"demo","done":false}'
sudo kubectl exec -n todo $(sudo kubectl get cluster todo-pg -n todo -o jsonpath='{.status.currentPrimary}') \
  -c postgres -- psql -U postgres -d tododb -c 'SELECT id,title,done FROM tasks;'
```
Result: app pods **2/2** (app + sidecar); tasks persisted in PostgreSQL (count=3 at capture). Also works
via the public URL.

### 6 — Failover automático de CNPG  (expected: delete primary → new primary < 30s)
```bash
sudo kubectl delete pod $(sudo kubectl get cluster todo-pg -n todo -o jsonpath='{.status.currentPrimary}') -n todo
sudo kubectl get cluster todo-pg -n todo -w     # watch .status.targetPrimary flip, then healthy
```
Result: operator promoted a replica (`targetPrimary` → `todo-pg-2`) in seconds; cluster returned to
**"Cluster in healthy state" 3/3**, data intact. (Watch `targetPrimary`, not the lagging `currentPrimary`.)

### 7 — Trazas en Jaeger via HTTPRoute  (expected: full span for GET/POST /tasks)
```bash
# generate traffic, then:
curl -s -k --resolve jaeger.local:443:$SERVER_PUB https://jaeger.local/jaeger/api/services
# open https://jaeger.local/jaeger and inspect a /tasks trace
```
Result: Jaeger services = `main-gateway-istio`, `todo-frontend.todo`, `todo-api.todo` — the chain
**Gateway → frontend → todo-api** is captured per request.
> *Caveat: there is **no PostgreSQL span** — the Envoy sidecar sees HTTP (L7), not the SQL call.
> A Postgres span would need app-level OpenTelemetry DB instrumentation, which I left out of scope.

### 8 — Topología en Kiali via HTTPRoute  (expected: animated graph + latency for ns todo)
```bash
curl -s -o /dev/null -w "%{http_code}\n" -k --resolve kiali.local:443:$SERVER_PUB https://kiali.local/kiali/   # 200
# open https://kiali.local/kiali -> Graph -> namespace todo (live traffic, p50/p95)
```
Result: `kiali.local/kiali` → **200**; Kiali points at the kube-prom Prometheus, shows the live `todo`
graph. A VirtualService (timeout/retry) on todo-api is configured.

### 9 — Dashboards en Grafana via HTTPRoute  (expected: Istio Mesh + CNPG with real data)
```bash
curl -s -o /dev/null -w "%{http_code}\n" -k --resolve grafana.local:443:$SERVER_PUB https://grafana.local/   # 302 -> login
# Prometheus actually has the data:
curl -s -k --resolve grafana.local:443:$SERVER_PUB -u admin:admin \
  "https://grafana.local/api/datasources/proxy/uid/prometheus/api/v1/query?query=sum(istio_requests_total)"
```
Result: `istio_requests_total` = **7329**, `cnpg_collector_up` = **3 instances**. Dashboards imported:
**7639** (Istio Mesh), **315** (K8s), **20417** (CloudNativePG).

### 10 — Volúmenes en Longhorn via HTTPRoute  (expected: PVCs Bound + replicated)
```bash
curl -s -o /dev/null -w "%{http_code}\n" -k --resolve longhorn.local:443:$SERVER_PUB https://longhorn.local/   # 200
sudo kubectl get pvc -n todo                                   # CNPG PVCs Bound
sudo kubectl get volumes.longhorn.io -n longhorn-system        # robustness=healthy
```
Result: `longhorn.local` → **200**; the 3 CNPG volumes are **attached / healthy** (2 replicas each).

### 11 — URL pública  (expected: app reachable from internet, task created from public URL)
```bash
sudo kubectl logs -n todo deploy/cloudflared | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com'
curl -X POST <public-url>/api/tasks -H 'Content-Type: application/json' -d '{"title":"public","done":false}'
```
Result: public URL (e.g. `https://def-hope-varieties-opponents.trycloudflare.com`) → **200**; a task
created from it persists in PostgreSQL.
> Decision: **Cloudflare TryCloudflare** instead of Ngrok (Ngrok needs an account authtoken; the spec
> accepts cloudflared). The URL changes each run.

---

## Bonus evidence
- **mTLS STRICT (+5):** `sudo kubectl get peerauthentication -n todo` → `default STRICT`. A plaintext call from a
  no-sidecar pod to `todo-api:8080` is **rejected** ("Connection reset by peer"); the app still works.
- **HPA load test (+5):** generate load through the Gateway and `sudo kubectl get hpa todo-api -n todo -w` →
  CPU spiked to **145%**, Deployment scaled **2 → 4 → 5**, then back down after the stabilization window.

## What the reviewer will also ask (per the test)
For every component: its **purpose** and **what would break if removed** — see `docs/STUDY_GUIDE.md`,
which has both for each block, plus the k3s-vs-kubeadm and Gateway-API-vs-Ingress rationale.
