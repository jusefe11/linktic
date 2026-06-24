# Cloud-Native Kubernetes Platform on AWS

A production-shaped Kubernetes platform built for the "Ingeniero Cloud Senior" technical test:
**k3s** on EC2, **Gateway API v1.4 + Istio**, **GitOps with ArgoCD**, **CloudNativePG**, **Longhorn**,
full **observability** (Prometheus/Grafana/Jaeger/Kiali/Loki), a 2-microservice **ToDo** app, and public
exposure — all declarative and reproducible.

> Companion docs: [`docs/EVIDENCE.md`](docs/EVIDENCE.md) — the 11 review items mapped to commands + real results ·
> [`docs/RUNBOOK.md`](docs/RUNBOOK.md) — every exact command, step by step ·
> [`docs/STUDY_GUIDE.md`](docs/STUDY_GUIDE.md) — design decisions + why, per block, for the live review ·
> [`task_plan.md`](task_plan.md) — the phased plan with verification gates · [`tasks.json`](tasks.json) —
> machine-readable task list.

## Architecture

```
                Internet
                   │
   ┌───────────────┼──────────────────────────┐
   │ Cloudflare Tunnel (public *.trycloudflare)│   /etc/hosts -> EC2 public IP :443
   │      -> todo-frontend                     │   *.local -> Istio Gateway (TLS, local CA)
   └───────────────┼──────────────────────────┘
                   ▼
        Istio Gateway (Gateway API v1.4, GatewayClass=istio, ServiceLB node IPs)
                   │  HTTPRoutes: todo / todo-api / argocd / grafana / jaeger / kiali / longhorn .local
                   ▼
   ns todo (Istio sidecars, mTLS STRICT):  todo-frontend (React/Nginx) ─/api─> todo-api (Go) ─> CNPG
   ns infra/observability:  ArgoCD · cert-manager · Longhorn · Prometheus/Grafana · Jaeger · Kiali · Loki
   3x EC2 m7i-flex.large (Ubuntu 24.04) · k3s 1.35 (embedded etcd) · Calico VXLAN
```

## Why k3s over kubeadm (the required justification)
- **ServiceLB (klipper)** publishes `LoadBalancer` services on the **real node IP** via hostPort — the
  clean way to get an external IP on AWS EC2. **MetalLB L2 does not work on AWS**: it relies on ARP, but
  the AWS VPC is a software-defined network that ignores gratuitous ARP for unassigned IPs. The spec
  explicitly allows the k3s integrated LB as a justified alternative, so we **skip MetalLB**.
- Lighter control plane for a resource-constrained (24 GB) lab, while `--cluster-init` gives **embedded
  etcd** (not SQLite) to keep production HA semantics.
- Trade-off vs kubeadm: less "vanilla", but every replaced piece (flannel→Calico, traefik→Gateway API)
  is swapped for the component the test actually asks for.

## Prerequisites
- An AWS account with EC2 access (this build used a Free-plan account — see note below), AWS CLI v2.
- Local tools: `kubectl`, `helm` v3+, `istioctl` 1.30, `git`, `gh` (for the private GitOps repo).
- The local CA (`infra/ca/ca.crt`) imported into your OS/browser trust store (see below).

> **AWS Free-plan note:** this account only allows free-tier-eligible instance types. The largest is
> `m7i-flex.large` (2 vCPU / 8 GB), so the cluster is **3× m7i-flex.large = 24 GB total** and the stack
> is resource-tuned accordingly. On a paid account use `t3.large` + 2× `t3.xlarge` for more headroom.

## Bring the environment up from zero
The full, copy-pasteable command sequence is in **[`docs/RUNBOOK.md`](docs/RUNBOOK.md)**. High level:

```bash
# 0. AWS infra: key pair, security group, 3 EC2 + extra EBS   (docs/RUNBOOK.md Phase 0)
# 1. k3s + Calico                                              (infra/k3s, infra/calico)
# 2. cert-manager local CA                                     (infra/cert-manager)
# 3. Gateway API v1.4 + Istio                                  (infra/gateway)
# 4. ArgoCD + App-of-Apps  -> everything else is GitOps:
kubectl apply -f gitops/root-app.yaml
```
After step 4 ArgoCD reconciles `gitops/apps/*` (registry, longhorn, CNPG, app, observability, expose).

A `Makefile` wraps the bootstrap phases:
```bash
make cluster infra gateway argocd observability expose   # targets per block
```

## /etc/hosts entries for the review
Point every hostname at the Istio Gateway (any node's public IP). Replace `<NODE_IP>`:
```
<NODE_IP>  todo.local todo-api.local argocd.local grafana.local jaeger.local kiali.local longhorn.local
```
- `todo.local` — ToDo app (frontend; `/api` is proxied to todo-api through the mesh)
- `todo-api.local` — REST API directly via the Gateway
- `argocd.local` · `grafana.local` · `jaeger.local` (path `/jaeger`) · `kiali.local` (path `/kiali`) ·
  `longhorn.local`

## Import the local CA (no TLS warnings)
All `*.local` certs are signed by a cert-manager root CA. Trust it once:
```bash
# macOS
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain infra/ca/ca.crt
# Linux
sudo cp infra/ca/ca.crt /usr/local/share/ca-certificates/k8s-lab.crt && sudo update-ca-certificates
```

## Repository layout
```
infra/                bootstrap pieces (k3s, calico, cert-manager, gateway, ca, aws-ids)
gitops/
  root-app.yaml       App-of-Apps root (apply once)
  apps/               one ArgoCD Application per component
  manifests/          the actual k8s manifests (cert-manager, gateway, registry, todo, observability, ...)
  set-repo.sh         repoint the whole tree to another Git repo in one command
app/
  todo-api/           Go 1.22 REST API (Dockerfile)
  todo-frontend/      React 18 + Nginx SPA (Dockerfile)
docs/                 RUNBOOK.md (commands) + STUDY_GUIDE.md (decisions & why)
```

## Migrating to a different GitOps repo
Full step-by-step (incl. AWS pre-checks): **[docs/CHANGE-GITOPS-REPO.md](docs/CHANGE-GITOPS-REPO.md)**. Quick version — the repo URL is centralized, so switching is one command:
```bash
./gitops/set-repo.sh https://github.com/ORG/NEW-REPO
git commit -am "repoint gitops" && git push
kubectl -n argocd patch app root --type merge -p '{"operation":{"sync":{}}}'
```

## Key design decisions (full rationale in docs/STUDY_GUIDE.md)
| Area | Decision |
|------|----------|
| Bootstrap | k3s + ServiceLB (skip MetalLB on AWS); embedded etcd |
| CNI | Calico **VXLAN** (always-encapsulate — survives the AWS source/dest check) |
| Networking fix | apiserver `advertise-address` = **private IP** (public IP broke cross-node ClusterIP) |
| Ingress | Gateway API v1.4, one wildcard `*.local` cert, TLS terminated at the Gateway |
| GitOps | ArgoCD App-of-Apps + Sync Waves; HTTPRoutes/Gateways are Git-managed |
| Registry | Docker Registry v2, NodePort, images built in-cluster with kaniko |
| Data | CloudNativePG 3 instances on Longhorn; app uses the `-rw` service + generated Secret |
| Storage | Longhorn 2 replicas on a dedicated EBS; local-path kept as single default SC |
| Mesh/observability | Istio mTLS STRICT; Prometheus/Grafana/Jaeger/Kiali/Loki; 100% trace sampling via Telemetry |
| Public exposure | Cloudflare TryCloudflare tunnel (no account needed; Ngrok needs an authtoken) |

## Bonus implemented
- **mTLS STRICT** in `todo` (+5) — plaintext to the API is rejected; postgres excluded (no sidecar).
- **HPA load test** (+5) — load on todo-api scales the Deployment 2→up to 5 and back.
