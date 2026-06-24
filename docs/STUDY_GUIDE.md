# Study Guide & Defense Notes

Didactic notes to defend the technical test in the live review. **Built progressively**: each section
is filled ONLY when its task is executed, as the closing step of that task. A task is not `done` until
its section here is written.

Every section must answer, at minimum:
- **Decision taken & why** (chosen option, rejected alternatives, reasoning) — required; the review asks
  the candidate to justify every decision.
- What I built / what it does.
- Concepts to study.
- What to pay attention to.
- What happens if the component is removed.
- Likely review questions + answers.
- Evidence (commands / screenshots).

Status legend: ⬜ pending · 🟡 in progress · ✅ documented

---

## Global Architecture Decisions (recorded as decided — the big WHYs)

> These cross-cutting decisions are fixed up front; detailed per-task rationale lives in each section below.

| Decision | Choice | Why (short) | Rejected alternative |
|----------|--------|-------------|----------------------|
| Bootstrap tool | **k3s** (embedded etcd) | ServiceLB publishes LB on real node IP → solves AWS LB cleanly; lighter; spec allows it | kubeadm — MetalLB L2 is painful on AWS |
| LoadBalancer | **k3s ServiceLB** | Works on EC2 out of the box | MetalLB L2 — AWS VPC is SDN, ARP VIPs don't route |
| CNI | **Calico** (VXLAN) | Istio-compatible + full NetworkPolicy; VXLAN because AWS blocks BGP | Flannel (limited NetworkPolicy) |
| Nodes | **3x EC2 Ubuntu 24.04** | Real VMs (spec bans kind/k3d); Longhorn replication + CNPG anti-affinity | single node (no replication/failover) |
| Sizing | **3x m7i-flex.large (24GB total)** | AWS Free plan only allows free-tier-eligible types; m7i-flex.large (8GB) is the biggest | t3.large/xlarge — rejected by Free plan |
| GitOps | **ArgoCD App-of-Apps + Sync Waves** | Single source of truth, ordered reconciliation | manual/imperative apply |

_(Expand the reasoning behind each as the relevant task is executed.)_

---

## Section template (copy for each task)

```
### <Px> - <Title>            [status: ⬜]
**Decision taken & why:** _TODO — chosen option, rejected alternatives, reasoning._
**What I built / what it does:** _TODO_
**Concepts to study:** _TODO_
**Pay attention to:** _TODO_
**What if removed:** _TODO_
**Likely review questions + answers:** _TODO_
**Evidence (commands/screens):** _TODO_
```

---

## P0 - AWS Infrastructure            [status: ✅]
**Decision taken & why:** Run the cluster on **3x EC2 m7i-flex.large (2 vCPU / 8 GB) Ubuntu 24.04**, one
server + two agents, in the default VPC (us-east-1a), each with a **30 GB root + 80 GB data EBS**, behind
one security group. Real VMs because the spec bans kind/minikube/k3d. 3 nodes so Longhorn can replicate
across workers and CNPG can spread replicas for failover.
- **Why m7i-flex.large and not t3.large/xlarge (the original "comfortable" pick):** the account is on the
  **AWS Free plan**, which rejects non-free-tier-eligible instance types (`InvalidParameterCombination:
  not eligible for Free Tier`). The largest free-tier-eligible type is `m7i-flex.large` (8 GB). So the
  real ceiling is 24 GB total, not the 40 GB we wanted. The stack must be resource-tuned to fit.
- **Why the data EBS is separate:** Longhorn needs a dedicated block device; mixing with the OS root is
  fragile.
**What I built / what it does:** key pair `juan-test-key`; SG `k8s-lab-sg` (22/80/443/6443 from my IP,
all traffic intra-SG); 3 instances tagged `Project=k8s-lab`; IDs persisted in `infra/aws-ids.env`.
**Concepts to study:** EC2 vs containers-as-nodes; VPC/subnet/SG basics; EBS gp3 + Nitro device naming
(`/dev/sdf` -> `nvme1n1`); AWS source/dest check; AWS Free plan vs paid plan limits.
**Pay attention to:** the admin IP in the SG changes (re-check); new accounts hit a temporary
`PendingVerification` hold on launching extra instances (cleared in minutes here); **stop instances when
idle** to control cost/credits.
**What if removed:** no extra EBS -> Longhorn/CNPG PVCs cannot bind; no intra-SG rule -> k3s API/etcd/
Calico VXLAN between nodes is blocked and the cluster never forms.
**Likely review questions + answers:** *Why EC2 not minikube?* spec requires real VMs. *Why 3 nodes?*
storage replication + DB failover need >1 worker.
**Evidence:** `aws ec2 describe-instances ... Project=k8s-lab` -> 3 running; SSH to all 3 works.

## P1 - k3s Bootstrap            [status: ✅]
**Decision taken & why:**
- **k3s (embedded etcd) over kubeadm:** lighter for a 24 GB budget, and its built-in **ServiceLB**
  cleanly publishes LoadBalancer services on real node IPs — the justified AWS alternative to MetalLB.
  Used `--cluster-init` for **embedded etcd** (not SQLite) to mirror production HA semantics.
- **Calico CNI (VXLAN) over Flannel:** Istio-compatible and full NetworkPolicy (block 6 needs it).
  **encapsulation: VXLAN (always)** — on AWS, un-encapsulated pod traffic carries pod IPs the VPC drops
  (source/dest check); BGP/IPIP are also blocked. VXLAN wraps packets in node IPs, which the VPC allows.
- **Disabled flannel, default network-policy and traefik** in k3s because Calico + Istio Gateway API
  replace them.
- **Skipped MetalLB:** proven unnecessary — ServiceLB gave the LoadBalancer an external IP and answered
  HTTP. MetalLB L2 relies on ARP, which AWS's SDN does not honor.
**What I built / what it does:** 1 server + 2 agents joined via node-token; Calico via tigera-operator
v3.29.1 + an `Installation` CR; kubeconfig pulled locally (server URL rewritten to its public IP).
Manifests saved in `infra/calico/`.
**Problems solved (great defense material):**
1. **CNI path mismatch:** the Calico operator writes to `/etc/cni/net.d` + `/opt/cni/bin`, but k3s reads
   its own dirs. Fixed with symlinks (`infra/calico/00-cni-symlinks.sh`) on every node.
2. **Operator bootstrap deadlock (workaround):** the operator could not reach the API via ClusterIP
   `10.43.0.1` (`i/o timeout`). Initial workaround: the **`kubernetes-services-endpoint` ConfigMap**
   pointing Calico directly at the server node IP:6443.
3. **THE REAL ROOT CAUSE (platform-wide):** the `kubernetes` Service endpoint was the server's **PUBLIC
   IP** (`100.x:6443`), because `--node-external-ip` made k3s advertise it. So **every** pod on an agent
   node DNAT'd `10.43.0.1:443` -> server public IP, which is not reachable node-to-node inside the VPC ->
   timeout. This broke Calico bootstrap, cert-manager (cainjector exit 124), and the API->kubelet log/exec
   proxy (502). **Fix:** set `advertise-address` and `node-ip` to the server **private IP** in
   `/etc/rancher/k3s/config.yaml` (saved in `infra/k3s/server-config.yaml`) and restart k3s. After this,
   agent pods reach `10.43.0.1` (401, i.e. reachable) and the whole cross-node service mesh works.
   Lesson: on cloud VMs, `--node-external-ip` is for display/LoadBalancer only — the apiserver must
   advertise the routable PRIVATE IP.
**Concepts to study:** k3s vs kubeadm architecture; embedded etcd vs SQLite; CNI role; Calico
VXLAN/BGP/IPIP; pod CIDR (10.42.0.0/16) vs service CIDR (10.43.0.0/16); ServiceLB/klipper vs MetalLB L2
(ARP) and why ARP fails on AWS; node-external-ip.
**Pay attention to:** a node is **NotReady until the CNI is installed** — this is expected, say it
confidently; calico-node goes 0/1 -> 1/1 after Felix/BIRD start; opening 6443 to the admin IP is what
lets local kubectl work.
**What if removed:** delete Calico -> nodes NotReady, no pod networking, no NetworkPolicy. Remove
ServiceLB -> Istio Gateway never gets an external IP. Remove the services-endpoint ConfigMap -> operator
deadlocks again.
**Likely review questions + answers:** *Why k3s over kubeadm?* lighter + ServiceLB solves AWS LB.
*What happens if you delete the CNI?* nodes NotReady, pods can't network. *Why doesn't MetalLB L2 work on
AWS and what did you use?* AWS SDN ignores ARP VIPs; used k3s ServiceLB (node-IP based).
**Evidence:** `kubectl get nodes -o wide` -> 3x Ready; `kubectl get pods -n calico-system` -> all
Running; whoami LoadBalancer got EXTERNAL-IP = node IPs and `curl http://<server-public-ip>` returned the
whoami pod.

## P2 - cert-manager            [status: ✅]
**Decision taken & why:** Local self-signed CA via a **two-step ClusterIssuer chain**:
`selfsigned-issuer` (bootstrap) -> issues a 10-year root CA cert (`root-ca`, ECDSA P-256) -> `ca-issuer`
(type CA) signs all leaf certs. Chosen because the cluster has no public DNS/ACME; a local CA lets every
internal hostname (`*.local`) get a valid HTTPS cert that the reviewer trusts after importing one root.
- **Why two issuers, not one:** an `Issuer` of type CA needs an existing CA key/cert in a Secret. The
  `selfsigned` issuer bootstraps that root; then `ca-issuer` consumes it. One issuer can't self-bootstrap.
- **ClusterIssuer (not Issuer):** certs are needed cluster-wide (todo, argocd, monitoring namespaces).
**What I built / what it does:** cert-manager v1.20.2 (Helm, CRDs enabled) in `cert-manager`;
`infra/cert-manager/clusterissuers.yaml` (selfsigned -> root-ca -> ca-issuer); exported root CA to
`infra/ca/ca.crt` for the OS/browser trust store.
**Concepts to study:** cert-manager objects (Issuer/ClusterIssuer, Certificate, CertificateRequest,
Secret); selfsigned vs CA issuer; X.509 chain of trust (isCA, root vs leaf, subject==issuer for a root);
how a Gateway HTTPS listener consumes a cert Secret; ACME vs local CA.
**Pay attention to:** import `infra/ca/ca.crt` into the OS/browser to avoid TLS warnings; the cert Secret
must be readable by the Gateway (same ns or a ReferenceGrant); cainjector/webhook need the cluster
network healthy — they crashed until the P1 advertise-address fix landed (good cross-link to tell in
review).
**What if removed:** no cert-manager -> Gateways have no valid certs; all HTTPS endpoints break or warn.
Remove ca-issuer -> cannot sign leaf certs from the local root.
**Likely review questions + answers:** *Why two ClusterIssuers?* selfsigned bootstraps the root that the
CA issuer then signs with. *TLS termination at Gateway vs HTTPRoute?* we terminate at the Gateway (central
cert management, simpler); HTTPRoute-level would push TLS to the app.
**Evidence:** `kubectl get clusterissuer` -> selfsigned-issuer & ca-issuer Ready=True; a test Certificate
issued Ready=True with `issuer=CN=k8s-lab-local-ca`; `openssl x509` on the root shows subject==issuer.

## P3 - Gateway API + Istio            [status: ✅]
**Decision taken & why:**
- **Gateway API v1.4 (Standard channel) over Ingress:** role separation (GatewayClass=infra,
  Gateway=platform, HTTPRoute=app), portable, the modern north-south standard. Installed CRDs BEFORE
  Istio so the `istio` GatewayClass registers.
- **Istio 1.30.1 (demo profile):** newest istioctl, supports Gateway API v1.4; demo profile preconfigures
  100% trace sampling + the Jaeger/Kiali/Prometheus/Grafana addons reused in block 9.
- **One Gateway with a wildcard `*.local` cert** (not one listener per host): a single cert-manager
  Certificate from `ca-issuer` covers todo/argocd/grafana/kiali/jaeger/longhorn `.local`. Less to manage,
  fewer Secrets, lighter on a 24GB cluster. `allowedRoutes.namespaces.from: All` lets HTTPRoutes in any
  app namespace attach — so no per-namespace ReferenceGrant just for route attachment.
- **TLS terminated at the Gateway** (not the HTTPRoute): central cert management; the mesh handles
  pod-to-pod encryption separately (mTLS, block 12).
- **HTTP->HTTPS redirect via an HTTPRoute `RequestRedirect` filter** (Gateway API has no listener-level
  redirect): a catch-all 301 on the :80 listener.
**What I built / what it does:** Gateway API v1.4 CRDs; Istio demo; `main-gateway` (HTTP:80 redirect +
HTTPS:443 wildcard) in ns `istio-ingress`; Istio auto-provisioned `main-gateway-istio` Deployment+Service
(LoadBalancer -> node IPs via ServiceLB). Manifests in `infra/gateway/main-gateway.yaml`.
**Problem solved:** the demo profile's **classic `istio-ingressgateway`** grabbed node hostPorts 80/443,
so the Gateway-API service's ServiceLB pods stayed Pending ("no free ports"). Fix: patch the classic
gateway Service to ClusterIP + scale its Deployment to 0 (we route exclusively through Gateway API).
Also scaled `istio-egressgateway` to 0 (unused) to save RAM.
**Concepts to study:** Gateway API resource/role model; Gateway API vs Ingress; Standard vs Experimental
channel; how Istio provisions a data-plane gateway per Gateway resource; TLS terminate vs passthrough vs
HTTPRoute-level; parentRefs/sectionName; allowedRoutes vs ReferenceGrant; RequestRedirect filter.
**Pay attention to:** install CRDs before Istio; only one LoadBalancer can own node ports 80/443 (hence
killing the classic gateway); wildcard cert subject is empty but SAN=`*.local` (verify with SAN, not CN);
ReferenceGrant is still needed later only if an HTTPRoute's backendRef crosses namespaces.
**What if removed:** no Gateway API CRDs -> Istio can't build gateways, no north-south routing. Remove the
Gateway -> every UI/app unreachable. Re-enable the classic ingressgateway -> port 80/443 conflict returns.
**Likely review questions + answers:** *Why Gateway API over Ingress?* role separation + portability.
*TLS at Gateway vs HTTPRoute?* central management at the edge. *Why did the gateway stay Pending?* the
classic ingressgateway held the node ports.
**Evidence:** `kubectl get gatewayclass istio` Accepted=True; `kubectl get gateway main-gateway`
Programmed=True, ADDRESS=node IP; `curl http://<node> -H Host:argocd.local` -> 301 to https;
`openssl s_client` on :443 -> issuer CN=k8s-lab-local-ca, verify code 0 (ok).

## P4 - GitOps with ArgoCD            [status: ✅]
**Decision taken & why:**
- **App-of-Apps with a single root Application** watching `gitops/apps/` (directory recurse): one
  `kubectl apply` bootstraps everything; adding a component = drop an Application YAML in `gitops/apps/`.
- **Centralized repo URL + `gitops/set-repo.sh`:** the repo URL is the only environment coupling; the
  script rewrites it across the tree in one command, so migrating to another Git repo is trivial (the
  user explicitly asked if that's possible — yes).
- **Sync Waves** (annotations `argocd.argoproj.io/sync-wave`): issuers wave 1, platform Gateway wave 4,
  argocd route wave 5 — guarantees CRDs/cert-manager exist before the Gateway, etc.
- **`server.insecure=true` + TLS terminated at the Gateway:** ArgoCD serves plain HTTP; the Istio Gateway
  does HTTPS for `argocd.local`. Avoids double TLS. Scaled `dex` + `notifications` to 0 to save RAM (24GB).
- **Private repo creds via an ArgoCD `repository` Secret** (GitHub token), so the controller can pull.
**What I built / what it does:** ArgoCD v2.13.2 in `argocd`; root App-of-Apps; child Applications adopt
the already-applied cert-manager issuers and the platform Gateway, and create the argocd HTTPRoute.
Repo: `github.com/caferrerb/cloud-native-k8s-test`. Layout: `gitops/{root-app.yaml,apps/,manifests/}`.
**Problem solved / great demo:** the **GitOps loop** — changed the redirect statusCode in Git, ArgoCD
auto-applied it to the live cluster (301->302->back to 301). Bonus learning: a `308` attempt was
**rejected by ArgoCD** because Gateway API's RequestRedirect only allows 301/302 — proof that GitOps
validates manifests before they hit the cluster. Also learned ArgoCD pins an in-flight sync to a commit
SHA; an invalid commit must be terminated before a fresh sync picks up the fix.
**Concepts to study:** GitOps (declarative, single source of truth, drift+self-heal); ArgoCD objects
(Application, Project, sync policy, automated/selfHeal/prune); App-of-Apps; Sync Waves & hooks;
adopting existing resources; repository credentials.
**Pay attention to:** HTTPRoutes/Gateways must be Git-managed (they are, under `gitops/manifests`); the
argocd route attaches only to the `https` listener (sectionName) so HTTP still redirects; a specific-host
HTTPRoute overrides the `*.local` catch-all redirect.
**What if removed:** no ArgoCD -> no continuous reconciliation, config drift, lose single source of truth.
No Sync Waves -> app deploys before its CRDs/DB and fails.
**Likely review questions + answers:** *Explain App-of-Apps.* one root app manages child apps declared in
git. *How do Sync Waves order things?* lower wave applies and goes Healthy first. *What if someone
kubectl-edits a managed resource?* selfHeal reverts it to git.
**Evidence:** `kubectl get applications -n argocd` -> all Synced+Healthy; `https://argocd.local` returns
200 with the local-CA cert; git redirect change auto-applied to the cluster.

## P5 - Local Registry            [status: ✅]
**Decision taken & why:** **Docker Registry v2** in-cluster (Deployment+PVC on k3s `local-path`),
exposed via **NodePort 30500**. Images are referenced as `<server-private-ip>:30500/<name>:<tag>` — the
same address resolves both for **push** (in-cluster builders reach the node IP:NodePort) and **pull**
(containerd on the host reaches the NodePort), all over plain HTTP. Chose Registry v2 (not Zot/Harbor)
for the lowest footprint on a 24 GB cluster; the spec marks it "recommended for this level".
- **Why NodePort + node-IP naming, not a DNS/ClusterIP name:** a ClusterIP name (`registry.registry.svc`)
  isn't resolvable by the host containerd; embedding the node IP:NodePort gives one consistent, resolvable
  address for both sides with no /etc/hosts, no extra DNS, no TLS/CA juggling on the laptop.
- **Pull config:** `/etc/rancher/k3s/registries.yaml` on every node maps that address to
  `http://<ip>:30500` (insecure HTTP), then restart k3s.
**What I built / what it does:** registry in ns `registry` (GitOps Application, sync-wave 2);
`infra/k3s/registries.yaml` on all nodes. Image build/push for the app (P6) uses in-cluster builders
(crane/kaniko) so no laptop Docker daemon changes are needed (unsupervised-friendly).
**Concepts to study:** OCI Distribution Spec / registry v2 API; insecure registries; how containerd
selects a registry endpoint (k3s `registries.yaml` mirrors); NodePort vs ClusterIP reachability from the
host vs pods; real-ECR 12h token expiry (the optional bonus).
**Pay attention to:** containerd needs the registry endpoint as HTTP or a trusted cert — we used HTTP +
`registries.yaml`; restart k3s after editing it; the registry data lives on one node (local-path) — fine
for a single replica.
**What if removed:** no registry -> Deployments can't pull app images -> `ImagePullBackOff`.
**Likely review questions + answers:** *Why this registry?* lightest OCI-compliant option for the budget.
*How does the node pull over HTTP?* `registries.yaml` mirror marks it insecure. *How would you solve
ECR's 12h token?* a CronJob refreshing the `imagePullSecret`.
**Evidence:** `crane copy busybox <ip>:30500/busybox:test --insecure` pushed; `/v2/_catalog` lists
`busybox`; a pod with image `<ip>:30500/busybox:test` reached Running (pulled by containerd).

## P6 - ToDo App            [status: ✅]
**Decision taken & why:**
- **todo-api in Go 1.22** (distroless image): single static binary, tiny attack surface, fast. Endpoints
  `/healthz`, `/readyz` (actually pings the DB), `/metrics` (Prometheus), CRUD `/tasks`. Propagates B3
  trace headers on outbound calls.
- **todo-frontend = static React 18 (UMD/CDN) + Nginx**: no node build step → trivial, reproducible image.
  Nginx serves the SPA and **reverse-proxies `/api/` to the todo-api service** (same-origin) — so it works
  identically behind the Gateway and behind the public tunnel, and the call is mesh-traced by the sidecars.
- **Images built in-cluster with kaniko** from the Git context → no laptop Docker daemon changes,
  fully reproducible/unsupervised-friendly. Pushed to the in-cluster registry over HTTP.
- Full K8s hygiene: 2 replicas + RollingUpdate (maxUnavailable:0 = zero-downtime), HTTPRoute per service,
  HPA (cpu60/min2/max5), liveness+readiness probes, requests/limits, NetworkPolicies, ConfigMap+Secret
  (DB creds from the CNPG Secret), one ServiceAccount per service.
**Pay attention to:** `2/2` = app + Envoy sidecar; readiness genuinely gates on DB connectivity; the
NetworkPolicy default-denies then allows only frontend→api, api→pg (and monitoring→metrics) — this is
exactly what bit Prometheus scraping until a metrics-allow rule was added.
**What if removed:** no readiness DB check → traffic to not-ready pods during rollout; no NetworkPolicy →
any pod can reach Postgres; no B3 propagation → fragmented Jaeger traces.
**Likely review questions:** liveness vs readiness; why maxUnavailable:0; what the NetworkPolicy blocks;
why build in-cluster.
**Evidence:** pods 2/2; create task via `todo.local/api` AND `todo-api.local` → both persist in Postgres;
rolling restart with **0/60 non-200 responses** (zero-downtime); HPA scaled 2→5 under load.

> Limitation to disclose: Jaeger shows Gateway→frontend→todo-api spans (Envoy L7), but **not a PostgreSQL
> span** — that needs app-level OpenTelemetry DB instrumentation, which is out of scope here.

## P7 - CloudNativePG            [status: ✅ (failover demo pending in review)]
**Decision taken & why:**
- **CNPG operator + a 3-instance Cluster** (1 primary + 2 replicas), `primaryUpdateStrategy:
  unsupervised` for automatic failover. Storage on **Longhorn** (5Gi/instance) so data survives pod/node
  loss. DB `tododb`, owner `todo`.
- **App connects to the `todo-pg-rw` Service** (always the current primary) using the **CNPG-generated
  Secret `todo-pg-app`** (username/password injected as env). Never hardcode creds or a pod IP — the RW
  service follows failover automatically.
- **Postgres pods excluded from the Istio sidecar** (`inheritedMetadata` annotation
  `sidecar.istio.io/inject: "false"`): the Envoy sidecar interferes with CNPG replication and the
  instance-manager's liveness/readiness, so the DB tier stays out of the mesh while the app tier stays in.
**What I built:** `gitops/manifests/todo/10-postgres.yaml`; CNPG operator via Helm in `cnpg-system`.
**Concepts to study:** operator pattern + CRDs; Postgres streaming replication; CNPG roles & services
(`-rw` primary, `-ro` replicas, `-r` any); automatic failover/switchover; PodMonitor; how a StorageClass
binds the per-instance PVCs.
**Pay attention to:** the app must use `-rw` (not a pod IP); creds come from the generated Secret; failover
should promote a replica in <30s; PodMonitor is enabled in P9 (needs the Prometheus CRDs first).
**What if removed:** no CNPG -> no managed HA/failover, manual Postgres ops; wrong service -> app can't
find the primary after failover.
**Likely review questions + answers:** *How does failover work?* the operator detects primary loss and
promotes the most-advanced replica, repoints `-rw`. *Why -rw service?* it always targets the live primary.
*What happens to in-flight writes during failover?* they fail and must retry; the app reconnects.
**Evidence:** `kubectl get cluster todo-pg -n todo` -> "Cluster in healthy state", 3/3 ready, primary
todo-pg-1; 3 Longhorn PVCs Bound. (Failover: delete the primary pod, watch a replica promote <30s.)

## P8 - Longhorn            [status: ✅]
**Decision taken & why:**
- **Longhorn** distributed block storage, **2 replicas/volume**, data on a **dedicated 80GB EBS** mounted
  at `/var/lib/longhorn` on every node (keeps Longhorn off the OS root). Requires `open-iscsi` (installed
  in P1). Chosen over OpenEBS as the spec's primary recommendation; replicated volumes let CNPG data
  survive a node loss.
- **Kept `local-path` as the single default StorageClass; Longhorn is non-default** — the registry uses
  local-path explicitly, CNPG names `longhorn` explicitly, avoiding the two-defaults ambiguity Longhorn
  creates on install.
- `replicaSoftAntiAffinity: false` so the 2 replicas land on **different nodes** (real redundancy).
**What I built:** Longhorn 1.12.0 via Helm in `longhorn-system`; UI HTTPRoute `longhorn.local`; GitOps
apps `infra-longhorn` (Helm) + `infra-longhorn-route`.
**Concepts to study:** CSI & dynamic provisioning; Longhorn architecture (manager, engine, replicas,
instance-manager); why open-iscsi; PV/PVC/StorageClass binding; replica count vs node-failure tolerance.
**Pay attention to:** install Longhorn BEFORE CNPG; 2 replicas needs ≥2 schedulable workers; the extra
EBS must be mounted before install; two default StorageClasses is a bug — fix it.
**What if removed:** no replicated storage -> CNPG PVCs can't bind, data not durable; remove open-iscsi ->
volumes fail to attach.
**Likely review questions + answers:** *How does Longhorn replicate?* synchronous replicas across nodes
via the engine. *Node holding a replica dies?* the volume stays Healthy from the other replica and rebuilds.
*Why open-iscsi?* Longhorn attaches volumes as iSCSI block devices.
**Evidence:** `kubectl get storageclass` -> longhorn present, single default; a test PVC Bound, volume
`robustness=healthy`, 2 replicas; `https://longhorn.local` -> 200.

## P8 - Longhorn            [status: ⬜]
_TODO: fill when P8 completes._

## P9 - Observability            [status: ✅]
**Decision taken & why:**
- **Istio sidecars** in `todo` give L7 metrics, traces and mTLS for free. **kube-prometheus-stack**
  (Helm) for Prometheus+Grafana (trimmed: no alertmanager, 2d retention, `*SelectorNilUsesHelmValues:
  false` so it scrapes all PodMonitors). **Jaeger + Kiali** from the Istio addons; **Loki** for logs.
- **Tracing enabled via a `Telemetry` resource at 100% sampling** pointing to the Jaeger provider — in
  Istio 1.30 the old meshConfig zipkin sampling alone produced no app traces; the Telemetry API is the
  current way.
- **Kiali pointed at the kube-prom Prometheus** (not the sample one) and at Jaeger; web_root `/kiali`.
- **VirtualService on todo-api** (timeout 5s, 3 retries) — the required app-level traffic policy; also
  makes the API resilient to failover blips.
- Dashboards imported via the Grafana API: **7639** (Istio Mesh), **315** (K8s), **20417** (CloudNativePG).
**Problem solved:** the `todo` NetworkPolicies default-denied ingress, so **Prometheus couldn't scrape**
the sidecars (15090) or CNPG (9187) — both targets timed out. Fix: an `allow-metrics-scrape` policy
permitting the `monitoring` namespace on the metrics ports. Great cross-link: segmentation vs scraping.
**Pay attention to:** all UIs via HTTPRoute (no port-forward at review); sidecar metrics are on the named
port `http-envoy-prom` (15090); 100% sampling is Telemetry, not meshConfig.
**What if removed:** no sidecar → no L7 telemetry; no Telemetry resource → no traces; no scrape policy →
empty dashboards.
**Likely review questions:** the three pillars; how Prometheus discovers targets (PodMonitor/ServiceMonitor);
what the VirtualService does; walk a Jaeger trace.
**Evidence:** `istio_requests_total = 312` and `cnpg_collector_up` = 3 in Prometheus; Jaeger services list
`main-gateway-istio`, `todo-frontend`, `todo-api`; Grafana/Jaeger/Kiali all 200 via HTTPS.

## P10 - Public Exposure            [status: ✅]
**Decision taken & why:** **Cloudflare TryCloudflare** (cloudflared `tunnel --url`) instead of the Ngrok
operator, because **Ngrok requires an account authtoken** (unavailable in an unsupervised run) while
TryCloudflare issues an ephemeral `*.trycloudflare.com` URL with real Cloudflare TLS and **no account**.
The spec lists cloudflared as an accepted alternative. Runs as an in-cluster Deployment (sidecar disabled)
tunnelling to `todo-frontend`; a NetworkPolicy allows cloudflared→frontend.
**Pay attention to:** the URL changes each run (document it); the tunnel client must be allowed past the
default-deny NetworkPolicy; keep it out of the mesh (it dials Cloudflare's edge).
**What if removed:** the app is only reachable inside the VPC / via the Gateway hostnames.
**Likely review questions:** how a reverse tunnel exposes a private service with no inbound firewall change;
operator vs quick-tunnel trade-offs.
**Evidence:** `https://<random>.trycloudflare.com` → 200; POST a task via the public URL → persisted in
PostgreSQL (id observed).

## P11 - Review Prep            [status: ✅]
**What I built:** `README.md` (architecture, from-zero steps, /etc/hosts, k3s-vs-kubeadm, CA import),
`Makefile` (targets: cluster/infra/gateway/argocd/observability/expose/status/clean), `docs/RUNBOOK.md`
(every command), this `STUDY_GUIDE.md`. Descriptive commit history; private repo on GitHub.
**Pay attention to:** be ready to explain each component's purpose AND what breaks if removed (the review
asks this explicitly); rehearse the failover and GitOps-loop demos live.

## P12 - Bonus (mTLS + HPA)            [status: ✅ +10]
**Decision taken & why:** **PeerAuthentication STRICT** in `todo` forces mTLS for all sidecar'd workloads;
Postgres is unaffected (no sidecar) and todo-api→postgres falls back to plaintext via Istio auto-mTLS.
**HPA load test** with 40 concurrent workers through the Gateway.
**Evidence:** a plaintext call from a no-sidecar pod to `todo-api:8080` → **Connection reset** (rejected);
PeerAuthentication STRICT active; app + public URL still 200. HPA: CPU spiked to **145%** → Deployment
scaled **2 → 4 → 5**, then back down after the stabilization window.

## P10 - Ngrok            [status: ⬜]
_TODO: fill when P10 completes._

## P11 - Review Prep            [status: ⬜]
_TODO: fill when P11 completes._

## P12 - Bonus (mTLS + HPA)            [status: ⬜]
_TODO: fill when P12 completes._
