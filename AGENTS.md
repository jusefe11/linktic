# AGENTS.md — Operating guide for AI agents

Read this first. It tells you what this project is, how to reach it, the conventions that avoid breaking
things, and a playbook for the common requests. Keep it updated when the platform changes.

---

## 1. What this is (current status)

A complete cloud-native Kubernetes platform on AWS, built for the "Ingeniero Cloud Senior" technical test.
**All 10 blocks are deployed and verified, plus 2 bonus items.** Nothing major is pending.

- **k3s 1.35** (embedded etcd) on **3× EC2 `m7i-flex.large`** Ubuntu 24.04, **Calico** CNI (VXLAN).
- **Gateway API v1.4 + Istio 1.30** (GatewayClass `istio`), TLS via a local **cert-manager** CA (`*.local`).
- **GitOps with ArgoCD** (App-of-Apps) — repo `github.com/caferrerb/cloud-native-k8s-test`.
- In-cluster **Docker registry** (NodePort 30500), images built with **kaniko**.
- **ToDo app**: `todo-api` (Go) + `todo-frontend` (React/Nginx) in ns `todo`, Istio sidecars, mTLS STRICT.
- **CloudNativePG** (3 instances, failover OK) on **Longhorn** (2 replicas).
- **Observability**: kube-prometheus-stack, Grafana, Jaeger, Kiali, Loki.
- **Public exposure**: Cloudflare TryCloudflare tunnel (ephemeral URL).

Companion docs: `README.md` (overview), `docs/RUNBOOK.md` (every command), `docs/STUDY_GUIDE.md`
(decisions + why, per block), `docs/CHANGE-GITOPS-REPO.md` (repo migration), `task_plan.md` /
`tasks.json` (the plan).

---

## 2. Environment & how to reach the cluster

- Working dir: `/Users/caferrerb/aprendiendo/juan`
- AWS: account `399707825994`, region `us-east-1`, **CLI profile `juan-test`** (always pass `--profile juan-test`).
- IDs/IPs live in **`infra/aws-ids.env`** — `source` it every shell. Key vars: `SERVER_PUB/PRIV`,
  `AGENT1_PUB/PRIV`, `AGENT2_PUB/PRIV`, `SG_ID`, `MYIP`.
- kubeconfig: **`infra/kubeconfig`** → `export KUBECONFIG=$PWD/infra/kubeconfig`.
- SSH: `ssh -i ~/.ssh/juan-test-key.pem ubuntu@<public-ip>`.

**Always start a session by verifying reachability:**
```bash
cd /Users/caferrerb/aprendiendo/juan && source infra/aws-ids.env
export KUBECONFIG=$PWD/infra/kubeconfig
kubectl get nodes        # if this fails, see §6 "cluster unreachable"
```

> ⚠️ **Public IPs are ephemeral.** Stopping/starting EC2 changes every public IP, which breaks
> `infra/kubeconfig`, `/etc/hosts`, k3s `--node-external-ip`, and the registry address baked into image
> names. See §6 to recover.

---

## 3. Golden conventions (learned the hard way — follow them)

1. **zsh does NOT word-split unquoted variables.** Never stuff multiple CLI flags in one var
   (`R="--a --b"; cmd $R` fails). Pass flags inline, or use arrays / `${=R}`.
2. **Shell state does not persist** between separate tool calls. Re-`source infra/aws-ids.env` and
   re-`export KUBECONFIG` in every command block. Persist new IDs to `infra/aws-ids.env`.
3. **Avoid the variable name `status`** in zsh — it's read-only and will error.
4. **The apiserver must advertise the PRIVATE IP** (`infra/k3s/server-config.yaml`). If it ever advertises
   a public IP, cross-node ClusterIP (`10.43.0.1`) breaks and half the cluster fails with `i/o timeout`.
5. **Calico needs the CNI dir symlinks + the `kubernetes-services-endpoint` ConfigMap** on this k3s setup
   (`infra/calico/`). Don't remove them.
6. **CNPG / cloudflared pods must NOT get an Istio sidecar** (`sidecar.istio.io/inject: "false"`). The
   sidecar breaks Postgres replication and the tunnel client.
7. **Confirm before destructive or billable actions** (terminating instances, deleting volumes). The repo
   is the source of truth; prefer GitOps changes over imperative `kubectl edit`.

---

## 4. Repo map

```
infra/                  bootstrap layer (not all GitOps-managed)
  aws-ids.env           IPs/IDs (gitignored)         kubeconfig (gitignored)
  ca/ca.crt             local root CA to trust
  k3s/  calico/         k3s + CNI install + fixes
  cert-manager/ gateway/ observability/ longhorn/   bootstrap manifests/values
gitops/
  root-app.yaml         App-of-Apps root (apply once)
  apps/                 one ArgoCD Application per component
  manifests/            actual k8s manifests (cert-manager, gateway, registry, todo, observability, security, expose)
  set-repo.sh           repoint the whole tree to another Git repo
app/
  todo-api/ (Go)  todo-frontend/ (React+Nginx)   + Dockerfiles
docs/                   RUNBOOK, STUDY_GUIDE, CHANGE-GITOPS-REPO
```

---

## 5. Access (hostnames, creds, URLs)

- Add to `/etc/hosts`: `<NODE_PUBLIC_IP>  todo.local todo-api.local argocd.local grafana.local jaeger.local kiali.local longhorn.local`
- ArgoCD: `https://argocd.local` — user `admin`, password:
  `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`
- Grafana: `https://grafana.local` — `admin/admin`. Jaeger: `https://jaeger.local/jaeger`. Kiali: `https://kiali.local/kiali`.
- Public URL (changes per run): `kubectl logs -n todo deploy/cloudflared | grep trycloudflare`
- All `*.local` use the local CA — trust `infra/ca/ca.crt`, or curl with `--cacert infra/ca/ca.crt`/`-k`.

---

## 6. Playbook — common requests

### Health check / "is everything ok?"
```bash
kubectl get applications -n argocd -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
kubectl get cluster todo-pg -n todo            # "Cluster in healthy state", 3/3
kubectl get pods -A | grep -vE 'Running|Completed'
```
(`app-todo` OutOfSync and `infra-longhorn` Unknown are known cosmetic states — components work.)

### Cluster unreachable (kubectl times out)
- Instances stopped → start them and refresh IPs + kubeconfig: see `docs/CHANGE-GITOPS-REPO.md` §0a.
- Laptop IP changed → reopen the SG: see `docs/CHANGE-GITOPS-REPO.md` §0b.

### Change the GitOps repo
Follow `docs/CHANGE-GITOPS-REPO.md` (script `gitops/set-repo.sh` + push + ArgoCD creds + re-apply root).

### Rebuild & redeploy an app image after code changes
```bash
git add app && git commit -m "..." && git push           # kaniko builds from git
# run the kaniko Job (see docs/RUNBOOK.md Phase 6) -> pushes $SERVER_PRIV:30500/<svc>:v1
kubectl rollout restart deploy/<svc> -n todo
```
Bump the image tag (`:v2`) in `gitops/manifests/todo/*` for a clean rollout, or `rollout restart` to repull.

### Demo CNPG failover
```bash
kubectl delete pod $(kubectl get cluster todo-pg -n todo -o jsonpath='{.status.currentPrimary}') -n todo
kubectl get cluster todo-pg -n todo -w        # a replica is promoted; watch .status.targetPrimary
```

### Re-create the public tunnel / get the URL
```bash
kubectl rollout restart deploy/cloudflared -n todo
kubectl logs -n todo deploy/cloudflared | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com'
```

### Stop / start instances to save cost
```bash
source infra/aws-ids.env
# stop (data on EBS persists; public IPs are released):
aws ec2 stop-instances  --profile juan-test --instance-ids $SERVER_ID $AGENT1_ID $AGENT2_ID
# start, then refresh IPs + kubeconfig (docs/CHANGE-GITOPS-REPO.md §0a):
aws ec2 start-instances --profile juan-test --instance-ids $SERVER_ID $AGENT1_ID $AGENT2_ID
```

### Full teardown
```bash
make clean        # terminates instances by Project=k8s-lab tag; then delete SG + key pair manually
```

---

## 7. Cost & safety
- 3 running instances ≈ **$7/day**. Stop them when idle. EBS still bills a little while stopped.
- This is a **test account** with broad permissions — still, confirm before terminating/deleting.
- After the engagement: `make clean` + delete the IAM access key.

---

## 8. When unsure
- Prefer GitOps (edit `gitops/`, commit, sync) over imperative changes.
- The decision rationale for every component is in `docs/STUDY_GUIDE.md` — read the relevant section
  before changing or removing something, and before answering "why is X like this?".
- The exact commands that built each piece are in `docs/RUNBOOK.md`.
