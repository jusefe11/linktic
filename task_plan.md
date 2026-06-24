# Cloud-Native Kubernetes Platform on AWS — Step-by-Step Execution Plan

> Source: "Prueba Técnica – Ingeniero Cloud Senior" (v2.0, May 2026).
> AWS test account `399707825994`, region `us-east-1`, CLI profile `juan-test`.
> Written for step-by-step execution by an AI coding agent.
>
> **GOLDEN RULE: never advance to the next step until its `✅ GATE` command returns the expected
> result. Each gate is a hard stop. If a gate fails, resolve it (see `↩ IF FAILS`) before continuing.**

---

## Legend
- `▶ DO` — actions/commands to run.
- `✅ GATE` — verification that MUST pass before the next step. Includes the exact command and expected output.
- `↩ IF FAILS` — recovery hint.
- `🛑 STOP-GATE` — end-of-phase checkpoint; the whole block is considered done only when this passes.

## Shell-state warning
The execution shell does **not** persist variables between separate command invocations, and zsh does
**not** word-split unquoted vars. Therefore: **persist every generated ID to `infra/aws-ids.env`** and
re-source it, and always pass `--profile juan-test` inline.

---

## 0. Architecture Decisions (AWS-specific) — unchanged, see rationale in README

| Decision | Choice | One-line justification |
|----------|--------|------------------------|
| Nodes | 3x EC2 Ubuntu 24.04 | Spec forbids kind/minikube/k3d; EC2 = real VMs; 3 nodes for Longhorn replication + CNPG failover. |
| Bootstrap | k3s, embedded etcd | ServiceLB publishes LB svc on real node IP → avoids MetalLB-L2-on-AWS (VPC is SDN, ARP VIP won't route). Spec allows k3s LB as justified alt. |
| CNI | Calico | Istio-compatible + full NetworkPolicy (block 6). |
| LoadBalancer | k3s ServiceLB (skip MetalLB) | Works natively on EC2. `/etc/hosts` → node public IP. |
| Storage | Longhorn on extra gp3 EBS | open-iscsi at OS level, 2 replicas. |
| Sizing | 1x t3.large + 2x t3.xlarge | Heavy stack (Istio+Prometheus+Loki+Longhorn+3 PG+ArgoCD). |

### Fixed AWS facts (discovered, re-verify at run)
- VPC `vpc-023b0ff014485f3c0` (172.31.0.0/16) · Subnet us-east-1a `subnet-02602a20f305b7594`
- AMI Ubuntu 24.04 `ami-0f8a61b66d1accaee` · Admin IP `181.53.99.60/32` (changes — re-check)

### Execution order (per user)
Block 1 fully green → Block 3 → rest. Dependency-correct sequence below.

---

# PHASE 0 — AWS Infrastructure  `[BILLABLE]`

### Step 0.0 — Preconditions
- `▶ DO`: confirm CLI identity and create the IDs file directory.
- `✅ GATE`:
  ```bash
  aws sts get-caller-identity --profile juan-test --query Account --output text
  # expect: 399707825994
  mkdir -p infra && echo "AWS_REGION=us-east-1" > infra/aws-ids.env && cat infra/aws-ids.env
  ```

### Step 0.1 — SSH key pair
- `▶ DO`:
  ```bash
  aws ec2 create-key-pair --profile juan-test --key-name juan-test-key \
    --query KeyMaterial --output text > ~/.ssh/juan-test-key.pem
  chmod 600 ~/.ssh/juan-test-key.pem
  ```
- `✅ GATE`:
  ```bash
  aws ec2 describe-key-pairs --profile juan-test --key-names juan-test-key \
    --query 'KeyPairs[0].KeyName' --output text   # expect: juan-test-key
  test -f ~/.ssh/juan-test-key.pem && echo "PEM OK"   # expect: PEM OK
  ```
- `↩ IF FAILS` (key exists): delete with `aws ec2 delete-key-pair --profile juan-test --key-name juan-test-key` then redo.

### Step 0.2 — Security group + rules
- `▶ DO`:
  ```bash
  SG_ID=$(aws ec2 create-security-group --profile juan-test --group-name k8s-lab-sg \
    --description "k8s lab" --vpc-id vpc-023b0ff014485f3c0 \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Project,Value=k8s-lab}]' \
    --query GroupId --output text)
  echo "SG_ID=$SG_ID" >> infra/aws-ids.env
  # admin access (SSH/HTTP/HTTPS) from my IP only
  aws ec2 authorize-security-group-ingress --profile juan-test --group-id $SG_ID --ip-permissions \
    IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp=181.53.99.60/32}]' \
    IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges='[{CidrIp=181.53.99.60/32}]' \
    IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges='[{CidrIp=181.53.99.60/32}]'
  # node-to-node: all traffic within the SG (k3s API 6443, etcd, calico, kubelet...)
  aws ec2 authorize-security-group-ingress --profile juan-test --group-id $SG_ID \
    --protocol -1 --source-group $SG_ID
  ```
- `✅ GATE`:
  ```bash
  source infra/aws-ids.env
  aws ec2 describe-security-groups --profile juan-test --group-ids $SG_ID \
    --query 'SecurityGroups[0].IpPermissions[].FromPort' --output text
  # expect to see: 22  80  443  and a -1 (all) rule -> 4 permission entries total
  ```

### Step 0.3 — Launch instances (server + 2 agents) with extra EBS
- `▶ DO`:
  ```bash
  source infra/aws-ids.env
  BDM='[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}},{"DeviceName":"/dev/sdf","Ebs":{"VolumeSize":80,"VolumeType":"gp3"}}]'
  # server
  aws ec2 run-instances --profile juan-test --image-id ami-0f8a61b66d1accaee \
    --instance-type t3.large --key-name juan-test-key --security-group-ids $SG_ID \
    --subnet-id subnet-02602a20f305b7594 --associate-public-ip-address \
    --block-device-mappings "$BDM" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Project,Value=k8s-lab},{Key=Name,Value=k3s-server}]'
  # 2 agents
  aws ec2 run-instances --profile juan-test --image-id ami-0f8a61b66d1accaee \
    --instance-type t3.xlarge --key-name juan-test-key --security-group-ids $SG_ID \
    --subnet-id subnet-02602a20f305b7594 --associate-public-ip-address \
    --block-device-mappings "$BDM" --count 2 \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Project,Value=k8s-lab},{Key=Name,Value=k3s-agent}]'
  ```
- `✅ GATE` (wait until all 3 are `running`):
  ```bash
  aws ec2 describe-instances --profile juan-test \
    --filters Name=tag:Project,Values=k8s-lab Name=instance-state-name,Values=running \
    --query 'length(Reservations[].Instances[])' --output text   # expect: 3
  ```

### Step 0.4 — Record IPs
- `▶ DO`:
  ```bash
  aws ec2 describe-instances --profile juan-test \
    --filters Name=tag:Project,Values=k8s-lab Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Priv:PrivateIpAddress,Pub:PublicIpAddress,Id:InstanceId}' \
    --output table
  # then write into infra/aws-ids.env: SERVER_PUB, SERVER_PRIV, AGENT1_PUB, AGENT1_PRIV, AGENT2_PUB, AGENT2_PRIV
  ```
- `✅ GATE`: `infra/aws-ids.env` contains 6 IP vars, all non-empty.

### Step 0.5 — SSH reachability to all 3 nodes
- `✅ GATE` (run for each public IP):
  ```bash
  source infra/aws-ids.env
  for ip in $SERVER_PUB $AGENT1_PUB $AGENT2_PUB; do
    ssh -i ~/.ssh/juan-test-key.pem -o StrictHostKeyChecking=accept-new ubuntu@$ip \
      'echo reachable: $(hostname)'
  done
  # expect: 3 "reachable: ..." lines
  ```
- `↩ IF FAILS`: instance still booting (wait 60s), or SG rule / wrong key.

### 🛑 STOP-GATE PHASE 0
3 instances running, each with a 30GB root + 80GB data EBS, SSH works to all. Only then → Phase 1.

---

# PHASE 1 — Block 1: k3s Bootstrap  `[12% · Senior · DO FIRST]`

### Step 1.1 — OS prep on ALL nodes
- `▶ DO` (run on server + both agents via SSH):
  ```bash
  sudo apt-get update -y && sudo apt-get install -y open-iscsi nfs-common
  sudo systemctl enable --now iscsid
  sudo modprobe iscsi_tcp && echo iscsi_tcp | sudo tee /etc/modules-load.d/iscsi.conf
  echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-k8s.conf && sudo sysctl --system
  ```
- `✅ GATE` (per node):
  ```bash
  ssh ... 'systemctl is-active iscsid; sysctl -n net.ipv4.ip_forward; lsblk | grep -c nvme1n1'
  # expect: active / 1 / 1   (iscsid up, ip_forward on, extra 80GB disk present)
  ```

### Step 1.2 — Install k3s SERVER (no flannel, no traefik, embedded etcd)
- `▶ DO` (on server):
  ```bash
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
    --cluster-init \
    --flannel-backend=none --disable-network-policy \
    --disable=traefik \
    --node-external-ip=$SERVER_PUB \
    --tls-san=$SERVER_PUB" sh -
  ```
- `✅ GATE` (on server):
  ```bash
  sudo systemctl is-active k3s            # expect: active
  sudo k3s kubectl get nodes              # server present (will be NotReady until Calico — expected)
  ```
- `↩ IF FAILS`: `sudo journalctl -u k3s -n 50`. Node NotReady here is EXPECTED (no CNI yet).

### Step 1.3 — Join the 2 agents
- `▶ DO`:
  ```bash
  # on server: get token
  sudo cat /var/lib/rancher/k3s/server/node-token   # -> save as K3S_TOKEN
  # on each agent:
  curl -sfL https://get.k3s.io | K3S_URL=https://$SERVER_PRIV:6443 K3S_TOKEN=<token> \
    INSTALL_K3S_EXEC="agent --node-external-ip=<AGENT_PUB>" sh -
  ```
- `✅ GATE` (on server):
  ```bash
  sudo k3s kubectl get nodes   # expect: 3 nodes listed (NotReady until 1.4 — expected)
  ```

### Step 1.4 — Install Calico CNI
- `▶ DO` (from server, pod CIDR = k3s default 10.42.0.0/16):
  ```bash
  sudo k3s kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/tigera-operator.yaml
  # Installation CR with cidr: 10.42.0.0/16, encapsulation VXLAN (works on AWS without BGP)
  sudo k3s kubectl apply -f - <<'EOF'
  apiVersion: operator.tigera.io/v1
  kind: Installation
  metadata: { name: default }
  spec:
    calicoNetwork:
      ipPools:
      - cidr: 10.42.0.0/16
        encapsulation: VXLAN
  EOF
  ```
- `✅ GATE`:
  ```bash
  sudo k3s kubectl wait --for=condition=Ready node --all --timeout=180s   # expect: all nodes Ready
  sudo k3s kubectl get pods -n calico-system   # expect: all Running
  sudo k3s kubectl get nodes -o wide           # expect: 3x Ready
  ```
- `↩ IF FAILS`: check `tigera-operator` pod logs; ensure VXLAN (not IPIP/BGP) — AWS blocks BGP.

### Step 1.5 — Local kubeconfig
- `▶ DO`:
  ```bash
  scp -i ~/.ssh/juan-test-key.pem ubuntu@$SERVER_PUB:/etc/rancher/k3s/k3s.yaml ./infra/kubeconfig
  sed -i '' "s/127.0.0.1/$SERVER_PUB/" ./infra/kubeconfig   # macOS sed
  export KUBECONFIG=$PWD/infra/kubeconfig
  ```
- `✅ GATE`:
  ```bash
  kubectl get nodes -o wide   # expect: 3x Ready, from the local machine
  ```

### Step 1.6 — LoadBalancer smoke test (ServiceLB)
- `▶ DO`:
  ```bash
  kubectl create deploy whoami --image=traefik/whoami
  kubectl expose deploy whoami --port=80 --type=LoadBalancer
  ```
- `✅ GATE`:
  ```bash
  kubectl get svc whoami -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
  # expect: a node IP (private). Then test from a node or via public IP:
  curl -s http://$SERVER_PUB/ | head -1   # expect: HTTP response from whoami (needs SG :80 open)
  kubectl delete deploy/whoami svc/whoami
  ```

### 🛑 STOP-GATE PHASE 1 (Block 1 complete)
- `kubectl get nodes` → 3x Ready · Calico Running · a LoadBalancer svc gets an external IP and answers.
- README documents: k3s-over-kubeadm + ServiceLB-over-MetalLB rationale.
- **Do not start Phase 2 until every check above is green.**

---

# PHASE 2 — Block 2: cert-manager + local CA  `[8% · Base]`

### Step 2.1 — Install cert-manager
- `▶ DO`: `helm repo add jetstack https://charts.jetstack.io && helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set crds.enabled=true`
- `✅ GATE`: `kubectl wait --for=condition=Available deploy -n cert-manager --all --timeout=120s` → all Available.

### Step 2.2 — ClusterIssuer chain (selfsigned → CA)
- `▶ DO`: apply `selfsigned-issuer` (kind selfsigned) → Certificate `root-ca` (isCA:true) in cert-manager ns → `ca-issuer` (kind CA, references the root-ca Secret).
- `✅ GATE`:
  ```bash
  kubectl get clusterissuer   # expect: selfsigned-issuer Ready=True, ca-issuer Ready=True
  kubectl get secret root-ca-secret -n cert-manager   # expect: exists (tls.crt/tls.key/ca.crt)
  ```

### Step 2.3 — Test certificate + export root CA
- `▶ DO`: create a throwaway Certificate signed by `ca-issuer`; export `ca.crt`.
- `✅ GATE`: `kubectl get certificate <test>` → Ready=True; `openssl x509 -in ca.crt -noout -subject` shows the local CA. Delete the test cert.
- README: document importing `ca.crt` into OS/browser trust store.

### 🛑 STOP-GATE PHASE 2
Both ClusterIssuers Ready=True, root CA Secret present, test cert issued OK.

---

# PHASE 3 — Block 3: Gateway API v1.4 + Istio  `[12% · Senior · DO SECOND]`

### Step 3.1 — Install Gateway API Standard Channel CRDs v1.4
- `▶ DO`: `kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml`
- `✅ GATE`:
  ```bash
  kubectl get crd gateways.gateway.networking.k8s.io \
    -o jsonpath='{.spec.versions[?(@.storage)].name}{"\n"}'   # expect: v1
  kubectl get crd | grep gateway.networking.k8s.io | wc -l    # expect: >=5 (GatewayClass,Gateway,HTTPRoute,GRPCRoute,ReferenceGrant)
  ```

### Step 3.2 — Install Istio (demo profile)
- `▶ DO`: `istioctl install --set profile=demo -y`
- `✅ GATE`:
  ```bash
  kubectl get gatewayclass istio -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}{"\n"}'  # expect: True
  kubectl get pods -n istio-system   # expect: istiod + ingressgateway Running
  ```

### Step 3.3 — Main Gateway (HTTP→HTTPS redirect, TLS from local CA)
- `▶ DO`: Certificate for `todo.local`/`todo-api.local` (issuer ca-issuer) → Secret; Gateway with
  listener :80 (HTTP, redirect) + listener :443 (HTTPS, certificateRefs → that Secret), `gatewayClassName: istio`.
- `✅ GATE`:
  ```bash
  kubectl get gateway <name> -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}'  # expect: True
  kubectl get svc -n istio-system istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'  # expect: node IP
  ```

### Step 3.4 — Platform listeners + certs (argocd/grafana/kiali/jaeger/longhorn .local)
- `▶ DO`: add hostnames/listeners (or extra Gateways) each with a CA-signed cert Secret.
- `✅ GATE`: each listener `Programmed=True`; each cert Secret exists and Ready.

### Step 3.5 — ReferenceGrants for cross-namespace cert/route refs
- `✅ GATE`: `kubectl get referencegrant -A` present where needed; HTTPRoutes resolve with `ResolvedRefs=True`.

### 🛑 STOP-GATE PHASE 3
GatewayClass `istio` Accepted=True · Gateways Programmed=True · ingressgateway has external IP ·
HTTP→HTTPS redirect works with a CA-signed cert (no browser warning after importing CA).

---

# PHASE 4 — Block 4: GitOps (ArgoCD, App-of-Apps, Sync Waves)  `[13% · Senior]`
> From here on, everything declared in phases 2-3 is migrated into Git and managed by ArgoCD.

- Step 4.1 Repo layout: `apps/ infra/ observability/ bootstrap/`. `✅ GATE`: repo pushed, evaluator access granted.
- Step 4.2 Install ArgoCD in `argocd` ns; HTTPRoute → `argocd.local`. `✅ GATE`: argocd-server pods Healthy; `https://argocd.local` loads with CA cert.
- Step 4.3 Root Application + child Apps with Sync Waves: wave0 GW-API CRDs+cert-manager · wave1 Istio · wave2 Longhorn · wave3 CNPG · wave4 platform Gateways/HTTPRoutes+observability · wave5 ToDo. `✅ GATE`: `argocd app list` all `Synced + Healthy`.
- Step 4.4 GitOps loop demo: change replicas in Git → `✅ GATE`: ArgoCD auto-syncs, `kubectl get deploy` reflects new count without manual apply.

### 🛑 STOP-GATE PHASE 4: all Applications Synced+Healthy; no imperative leftovers.

---

# PHASE 5 — Block 5: Local Registry (ECR simulated)  `[7% · Base]`
- Step 5.1 Deploy Docker Registry v2 (or Zot) in-cluster. `✅ GATE`: registry pod Running; `curl <registry>/v2/_catalog` returns 200.
- Step 5.2 Push/pull test: build a tiny image, push, pull from a node. `✅ GATE`: `kubectl run test --image=<registry>/<img>` pulls successfully.

### 🛑 STOP-GATE PHASE 5: image pushed to cluster registry and pulled by a pod.

---

# PHASE 6 — Block 6: ToDo App (2 microservices)  `[13% · Senior]`
`todo-api` (Go1.22/Node20 :8080) + `todo-frontend` (React18+Nginx :3000), ns `todo`, Istio sidecar.
- Step 6.1 todo-api endpoints `/healthz /readyz /metrics` + CRUD `/tasks`; propagate tracing headers (x-request-id, x-b3-*). `✅ GATE`: local `curl /readyz` 200 only when DB reachable; `/metrics` returns Prometheus text.
- Step 6.2 todo-frontend calls api through the Gateway (HTTPRoute). `✅ GATE`: build succeeds, image pushed to registry.
- Step 6.3 K8s resources: Deployment(2 replicas, RollingUpdate), HTTPRoute→main Gateway, HPA(CPU60%,min2,max5), liveness/readiness probes, resources req/limits, NetworkPolicy(frontend→api, api→PG only), ConfigMap+Secret, 1 ServiceAccount/svc. `✅ GATE`: `kubectl get hpa,networkpolicy,sa -n todo` all present; pods 2/2 Ready (app+sidecar).
- Step 6.4 `✅ GATE`: rolling update with zero downtime (`kubectl rollout` while curling endpoint → no 5xx).
- Step 6.5 `✅ GATE`: create task from frontend → appears in UI and in PostgreSQL row.

### 🛑 STOP-GATE PHASE 6: end-to-end task create/list/edit/delete works; all `todo` pods 2/2.

---

# PHASE 7 — Block 7: CloudNativePG  `[10% · Senior]`
- Step 7.1 Install CNPG operator in `cnpg-system`. `✅ GATE`: operator deploy Available.
- Step 7.2 Cluster: 3 instances, DB `tododb`, creds Secret, storageClass Longhorn ≥5Gi, PodMonitor on. `✅ GATE`: `kubectl get cluster -n <ns>` → `Cluster in healthy state`, 3 pods Running.
- Step 7.3 Wire todo-api to CNPG **RW Service**, creds from CNPG Secret. `✅ GATE`: todo-api `/readyz` 200.
- Step 7.4 Failover demo. `✅ GATE`: `kubectl delete pod <primary>` → a replica promotes in <30s (`kubectl get cluster` shows new primary); tasks persist across todo-api restarts.

### 🛑 STOP-GATE PHASE 7: 3 instances Healthy, failover <30s, data persists, PG metrics in Prometheus.

---

# PHASE 8 — Block 8: Longhorn  `[8% · Base+]`
- Step 8.1 Prepare extra EBS as Longhorn disk on each node (open-iscsi from 1.1). `✅ GATE`: `/dev/nvme1n1` mounted on all nodes.
- Step 8.2 Install Longhorn (Helm), default 2 replicas; UI via HTTPRoute → longhorn.local. `✅ GATE`: longhorn-manager pods Running; `https://longhorn.local` loads.
- Step 8.3 `✅ GATE`: CNPG PVCs `Bound`; volumes show `Healthy` + replicated in Longhorn UI; data survives delete+recreate of PG pods.

### 🛑 STOP-GATE PHASE 8: PVCs Bound, volumes Healthy/replicated, persistence proven.

---

# PHASE 9 — Block 9: Observability  `[12% · Senior]`
- Step 9.1 Enable sidecar injection in `todo`, restart pods. `✅ GATE`: all `todo` pods 2/2.
- Step 9.2 Install kube-prometheus-stack + Loki/Promtail; Grafana via HTTPRoute → grafana.local. `✅ GATE`: Prometheus targets Up; `https://grafana.local` loads.
- Step 9.3 Expose Jaeger/Kiali via HTTPRoutes. `✅ GATE`: both UIs load over HTTPS (no port-forward).
- Step 9.4 Import dashboards 7639 (Istio Mesh), 315 (K8s), CNPG. `✅ GATE`: dashboards show real data.
- Step 9.5 Kiali graph + p50/p95 + ≥1 VirtualService (timeout/retry on todo-api). `✅ GATE`: live traffic graph for `todo`.
- Step 9.6 `✅ GATE`: Jaeger shows full span chain Gateway → todo-api → PostgreSQL per endpoint.

### 🛑 STOP-GATE PHASE 9: traces correlated, Kiali graph live, Grafana dashboards with real data.

---

# PHASE 10 — Block 10: Public Exposure (Ngrok)  `[5% · Base]`
- Step 10.1 Install Ngrok K8s Operator (GitOps), tunnel → todo-frontend. `✅ GATE`: operator pods Running; a public URL is issued.
- Step 10.2 `✅ GATE`: open public URL from a browser, create a task → row persists in PostgreSQL.

### 🛑 STOP-GATE PHASE 10: app reachable from public URL, write persists.

---

# PHASE 11 — Deliverables & Review Prep
- 11.1 README (prereqs, from-zero steps, per-block decisions, `/etc/hosts` list, k3s-vs-kubeadm). `✅ GATE`: a fresh reader can follow it.
- 11.2 `bootstrap.sh`/`Makefile` targets: `cluster infra gateway argocd observability expose`. `✅ GATE`: each target runs idempotently.
- 11.3 Clean commit history; evaluator has repo access.
- 11.4 Dry-run the 11-point live review checklist. `✅ GATE`: all 11 demonstrations pass.

---

# PHASE 12 — Bonus (selected +10)
- 12.1 mTLS STRICT PeerAuthentication in `todo` (+5). `✅ GATE`: `istioctl authn tls-check` shows STRICT; plaintext call blocked.
- 12.2 HPA load test (k6/hey) (+5). `✅ GATE`: under load `kubectl get hpa` scales replicas up, then back down.

---

# CLEANUP (end of engagement)
- `✅ GATE` after teardown (expect 0 running):
  ```bash
  aws ec2 describe-instances --profile juan-test \
    --filters Name=tag:Project,Values=k8s-lab Name=instance-state-name,Values=running \
    --query 'length(Reservations[].Instances[])' --output text   # expect: 0
  ```
- Terminate instances, delete EBS, SG, key pair by `Project=k8s-lab`; delete IAM access key.

---

## Status tracker — ALL 10 BLOCKS COMPLETE (100%) + bonus (+10)
- ✅ P0 infra · P1 k3s/Calico · P2 cert-manager · P3 Gateway API/Istio · P4 ArgoCD GitOps
- ✅ P5 registry · P6 ToDo app (e2e ok, zero-downtime) · P7 CNPG (failover ok) · P8 Longhorn
- ✅ P9 observability (Prometheus/Grafana/Jaeger/Kiali/Loki, dashboards w/ real data)
- ✅ P10 public exposure (Cloudflare tunnel) · P11 README+Makefile · P12 bonus mTLS STRICT + HPA load test
- Repo: github.com/caferrerb/cloud-native-k8s-test
- Remember: stop EC2 when idle; the cloudflared URL changes per run.
