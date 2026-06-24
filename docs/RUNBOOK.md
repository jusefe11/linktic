# RUNBOOK — Exact commands, step by step

Reproducible command log of the whole build. Every step lists **the exact command**, **what it does**,
and **the expected result / gate**. Conceptual reasoning lives in `STUDY_GUIDE.md`; this file is the
"what I actually ran". Commands assume macOS + zsh on the operator laptop, AWS CLI profile `juan-test`.

## Conventions
- IDs/IPs are stored in `infra/aws-ids.env` and re-sourced each shell (`source infra/aws-ids.env`).
  zsh does NOT word-split unquoted vars and shell state does NOT persist between tool calls — hence the file.
- kubectl uses the local kubeconfig: `export KUBECONFIG=$PWD/infra/kubeconfig`.
- SSH to nodes: `ssh -i ~/.ssh/juan-test-key.pem ubuntu@<public-ip>`.

## Tools installed on the laptop
```bash
aws --version            # aws-cli/2.x (already present)
brew install helm        # helm v4.2.2
curl -sL https://istio.io/downloadIstio | ISTIO_VERSION=1.30.1 sh -   # istioctl 1.30.1 -> ~/.local/bin
kubectl version --client # from gcloud sdk (already present)
```

---

# PHASE 0 — AWS Infrastructure

### 0.0 Identity + workspace
```bash
aws sts get-caller-identity --profile juan-test --query Account --output text   # -> 399707825994
mkdir -p infra docs
echo "AWS_REGION=us-east-1" > infra/aws-ids.env
echo "MYIP=$(curl -s https://checkip.amazonaws.com)" >> infra/aws-ids.env
```

### 0.1 SSH key pair
```bash
aws ec2 create-key-pair --profile juan-test --key-name juan-test-key \
  --query KeyMaterial --output text > ~/.ssh/juan-test-key.pem
chmod 600 ~/.ssh/juan-test-key.pem
# gate:
aws ec2 describe-key-pairs --profile juan-test --key-names juan-test-key --query 'KeyPairs[0].KeyName' --output text
```

### 0.2 Security group (22/80/443/6443 from my IP, all traffic intra-SG)
```bash
source infra/aws-ids.env
SG_ID=$(aws ec2 create-security-group --profile juan-test --group-name k8s-lab-sg \
  --description "k8s lab" --vpc-id vpc-023b0ff014485f3c0 \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Project,Value=k8s-lab}]' \
  --query GroupId --output text)
echo "SG_ID=$SG_ID" >> infra/aws-ids.env
aws ec2 authorize-security-group-ingress --profile juan-test --group-id $SG_ID --ip-permissions \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MYIP}/32}]" \
  "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=${MYIP}/32}]" \
  "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=${MYIP}/32}]"
aws ec2 authorize-security-group-ingress --profile juan-test --group-id $SG_ID --protocol -1 --source-group $SG_ID
# 6443 (kube API) added later so local kubectl works:
aws ec2 authorize-security-group-ingress --profile juan-test --group-id $SG_ID \
  --ip-permissions "IpProtocol=tcp,FromPort=6443,ToPort=6443,IpRanges=[{CidrIp=${MYIP}/32}]"
```

### 0.3 Launch instances — NOTE the AWS Free-plan constraint
`t3.large`/`t3.xlarge` are REJECTED (`InvalidParameterCombination: not eligible for Free Tier`). The
biggest free-tier-eligible type is `m7i-flex.large` (2 vCPU / 8 GB). List eligible types with:
```bash
aws ec2 describe-instance-types --profile juan-test --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].InstanceType' --output text
```
Launch (server + 2 agents), each 30 GB root + 80 GB data EBS:
```bash
source infra/aws-ids.env
BDM='[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}},{"DeviceName":"/dev/sdf","Ebs":{"VolumeSize":80,"VolumeType":"gp3","DeleteOnTermination":true}}]'
aws ec2 run-instances --profile juan-test --image-id ami-0f8a61b66d1accaee \
  --instance-type m7i-flex.large --key-name juan-test-key --security-group-ids $SG_ID \
  --subnet-id subnet-02602a20f305b7594 --associate-public-ip-address --block-device-mappings "$BDM" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Project,Value=k8s-lab},{Key=Name,Value=k3s-server},{Key=Role,Value=server}]'
aws ec2 run-instances --profile juan-test --image-id ami-0f8a61b66d1accaee \
  --instance-type m7i-flex.large --key-name juan-test-key --security-group-ids $SG_ID \
  --subnet-id subnet-02602a20f305b7594 --associate-public-ip-address --block-device-mappings "$BDM" --count 2 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Project,Value=k8s-lab},{Key=Name,Value=k3s-agent},{Key=Role,Value=agent}]'
```
> New accounts may hit `PendingVerification` on extra instances (clears in minutes). Retry the agents
> until they launch (see `infra/launch-agents.sh`).

### 0.4 Record IPs
```bash
aws ec2 describe-instances --profile juan-test \
  --filters Name=tag:Project,Values=k8s-lab Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Pub:PublicIpAddress,Priv:PrivateIpAddress}' --output table
# write SERVER_PUB/SERVER_PRIV/AGENT1_PUB/AGENT1_PRIV/AGENT2_PUB/AGENT2_PRIV into infra/aws-ids.env
```

### 0.5 SSH gate
```bash
source infra/aws-ids.env
for ip in $SERVER_PUB $AGENT1_PUB $AGENT2_PUB; do
  ssh -i ~/.ssh/juan-test-key.pem -o StrictHostKeyChecking=accept-new ubuntu@$ip 'hostname'
done   # -> 3 hostnames
```

---

# PHASE 1 — k3s Bootstrap

### 1.1 OS prep on ALL 3 nodes
```bash
ssh -i ~/.ssh/juan-test-key.pem ubuntu@<node> 'bash -s' <<'EOS'
sudo apt-get update -y -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq open-iscsi nfs-common
sudo systemctl enable --now iscsid
sudo modprobe iscsi_tcp && echo iscsi_tcp | sudo tee /etc/modules-load.d/iscsi.conf
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-k8s.conf && sudo sysctl --system
EOS
# gate per node: systemctl is-active iscsid -> active ; sysctl -n net.ipv4.ip_forward -> 1 ; lsblk | grep nvme1n1
```

### 1.2 Pre-create CNI dir symlinks on ALL nodes (so Calico operator paths match k3s)
```bash
ssh ... 'bash -s' <<'EOS'
sudo mkdir -p /etc/cni/net.d /opt/cni /var/lib/rancher/k3s/agent/etc/cni
[ -L /var/lib/rancher/k3s/agent/etc/cni/net.d ] || { sudo rm -rf /var/lib/rancher/k3s/agent/etc/cni/net.d; sudo ln -sfn /etc/cni/net.d /var/lib/rancher/k3s/agent/etc/cni/net.d; }
[ -e /opt/cni/bin ] || sudo ln -sfn /var/lib/rancher/k3s/data/current/bin /opt/cni/bin
EOS
```
(Saved as `infra/calico/00-cni-symlinks.sh`.)

### 1.3 Install k3s SERVER  (flannel/traefik off, embedded etcd, advertise PRIVATE IP)
```bash
source infra/aws-ids.env
ssh -i ~/.ssh/juan-test-key.pem ubuntu@$SERVER_PUB "bash -s" <<EOS
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --cluster-init \
  --flannel-backend=none --disable-network-policy --disable=traefik \
  --node-external-ip=${SERVER_PUB} --tls-san=${SERVER_PUB}" sh -
EOS
```
**CRITICAL follow-up (root-cause fix):** k3s advertised the PUBLIC IP as the `kubernetes` Service
endpoint, breaking cross-node ClusterIP. Pin the private IP and restart:
```bash
ssh ... ubuntu@$SERVER_PUB "bash -s" <<EOS
sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<YAML
node-ip: ${SERVER_PRIV}
advertise-address: ${SERVER_PRIV}
YAML
sudo systemctl restart k3s
EOS
# gate: kubectl get endpoints kubernetes -> 172.31.9.150:6443 (PRIVATE)
```

### 1.4 Join the 2 agents
```bash
TOKEN=$(ssh ... ubuntu@$SERVER_PUB 'sudo cat /var/lib/rancher/k3s/server/node-token')
ssh ... ubuntu@<AGENT_PUB> "bash -s" <<EOS
curl -sfL https://get.k3s.io | K3S_URL=https://${SERVER_PRIV}:6443 K3S_TOKEN=${TOKEN} \
  INSTALL_K3S_EXEC="agent --node-external-ip=<AGENT_PUB>" sh -
EOS
# gate: sudo k3s kubectl get nodes -> 3 nodes (NotReady until CNI)
```

### 1.5 Install Calico (tigera-operator) + break the bootstrap deadlock
```bash
ssh ... ubuntu@$SERVER_PUB 'sudo k3s kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/tigera-operator.yaml'
# Installation CR (VXLAN always, AWS-safe) + APIServer CR -> infra/calico/installation.yaml
ssh ... 'sudo k3s kubectl apply -f -' < infra/calico/installation.yaml
# The operator can't reach API ClusterIP before CNI exists -> point it at the node IP directly:
ssh ... 'sudo k3s kubectl apply -f -' < infra/calico/kubernetes-services-endpoint.yaml
ssh ... 'sudo k3s kubectl rollout restart deploy/tigera-operator -n tigera-operator'
# gate: kubectl wait --for=condition=Ready node --all --timeout=180s -> all Ready
#       kubectl get pods -n calico-system -> Running
```

### 1.6 Local kubeconfig + LoadBalancer smoke test
```bash
ssh ... ubuntu@$SERVER_PUB 'sudo cat /etc/rancher/k3s/k3s.yaml' > infra/kubeconfig
chmod 600 infra/kubeconfig
sed -i '' "s#https://127.0.0.1:6443#https://${SERVER_PUB}:6443#" infra/kubeconfig
export KUBECONFIG=$PWD/infra/kubeconfig
kubectl get nodes -o wide                       # 3x Ready
kubectl create deploy whoami --image=traefik/whoami
kubectl expose deploy whoami --port=80 --type=LoadBalancer
kubectl get svc whoami -o wide                  # EXTERNAL-IP = node IPs (ServiceLB)
curl -s http://$SERVER_PUB/ | head -1           # whoami responds
kubectl delete deploy/whoami svc/whoami
```

---

# PHASE 2 — cert-manager + local CA

```bash
export KUBECONFIG=$PWD/infra/kubeconfig
helm repo add jetstack https://charts.jetstack.io && helm repo update jetstack
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --set crds.enabled=true --wait --timeout 5m
kubectl wait --for=condition=Available deploy -n cert-manager --all --timeout=120s   # gate v2.1
# If cainjector/webhook crash with i/o timeout to 10.43.0.1 -> that's the advertise-address bug (fix in 1.3),
# then: kubectl delete pod -n cert-manager --all

# ClusterIssuer chain (infra/cert-manager/clusterissuers.yaml): selfsigned -> root-ca (isCA) -> ca-issuer
kubectl apply -f infra/cert-manager/clusterissuers.yaml
kubectl wait --for=condition=Ready clusterissuer/ca-issuer --timeout=60s                # gate v2.2
# export root CA for OS/browser trust:
kubectl get secret root-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > infra/ca/ca.crt
```

---

# PHASE 3 — Gateway API v1.4 + Istio

```bash
export KUBECONFIG=$PWD/infra/kubeconfig
# 3.1 Gateway API Standard CRDs v1.4.0
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.spec.versions[?(@.storage)].name}'  # v1

# 3.2 Istio demo profile (registers GatewayClass 'istio')
istioctl install --set profile=demo -y
kubectl get gatewayclass istio -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'        # True

# free node ports 80/443: the demo's classic ingressgateway holds them -> we use Gateway API instead
kubectl scale deploy/istio-egressgateway -n istio-system --replicas=0
kubectl patch svc istio-ingressgateway -n istio-system -p '{"spec":{"type":"ClusterIP"}}'
kubectl scale deploy/istio-ingressgateway -n istio-system --replicas=0

# 3.3 main Gateway + wildcard *.local cert + HTTP->HTTPS redirect (infra/gateway/main-gateway.yaml)
kubectl apply -f infra/gateway/main-gateway.yaml
kubectl wait --for=condition=Ready certificate/wildcard-local -n istio-ingress --timeout=60s
kubectl wait --for=condition=Programmed gateway/main-gateway -n istio-ingress --timeout=120s
kubectl get gateway main-gateway -n istio-ingress      # PROGRAMMED True, ADDRESS = node IP

# gates: HTTP redirect + TLS from local CA
curl -s -o /dev/null -w "%{http_code} %{redirect_url}\n" -H "Host: argocd.local" http://$SERVER_PUB/   # 301 https://argocd.local/
echo | openssl s_client -connect $SERVER_PUB:443 -servername argocd.local -CAfile infra/ca/ca.crt 2>/dev/null | grep "Verify return"  # 0 (ok)
```

---

# PHASE 4+ — (appended as executed)

# PHASE 4 — GitOps with ArgoCD

```bash
export KUBECONFIG=$PWD/infra/kubeconfig
# 4.2 install ArgoCD + make it work behind the Gateway
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl scale deploy/argocd-dex-server deploy/argocd-notifications-controller -n argocd --replicas=0   # trim RAM
kubectl rollout restart deploy/argocd-server -n argocd
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d    # admin pwd

# 4.1 repo + 4.3 App-of-Apps (gitops/ tree); private-repo creds for ArgoCD:
GHTOKEN=$(gh auth token)
kubectl apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata: { name: repo-cloud-native, namespace: argocd, labels: { argocd.argoproj.io/secret-type: repository } }
stringData: { type: git, url: https://github.com/caferrerb/cloud-native-k8s-test, username: caferrerb, password: ${GHTOKEN} }
YAML
git add gitops && git commit -m "gitops: app-of-apps" && git push    # push the gitops/ tree first
kubectl apply -f gitops/root-app.yaml
kubectl get applications -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'   # all Synced+Healthy

# 4.2 verify UI via Gateway (TLS from local CA), no port-forward:
curl -s -o /dev/null -w "%{http_code}\n" --cacert infra/ca/ca.crt --resolve argocd.local:443:$SERVER_PUB https://argocd.local/   # 200

# 4.4 GitOps loop demo: change a value in git -> ArgoCD applies it
sed -i '' 's/statusCode: 301/statusCode: 302/' gitops/manifests/gateway/main-gateway.yaml
git commit -am "demo" && git push
kubectl patch app infra-gateway -n argocd --type merge -p '{"operation":{"sync":{"revision":"main"}}}'   # force (or wait 3min poll)
curl -s -o /dev/null -w "%{http_code}\n" -H 'Host: test.local' http://$SERVER_PUB/   # 302  (then revert to 301)
# NOTE: Gateway API RequestRedirect only allows 301/302. If a sync sticks on a bad commit:
#   kubectl patch app <name> -n argocd --subresource status --type merge -p '{"status":{"operationState":{"phase":"Terminating"}}}'
# then re-trigger the sync against the fixed commit.
```

### Repo migration (answer to "can we change repos later?") — YES, one command
```bash
./gitops/set-repo.sh https://github.com/ORG/NEW-REPO
git commit -am "chore: repoint gitops repo" && git push
kubectl -n argocd patch app root --type merge -p '{"operation":{"sync":{}}}'
```

# PHASE 5 — Local Registry (ECR simulated)

```bash
export KUBECONFIG=$PWD/infra/kubeconfig
# deploy registry (Deployment + local-path PVC + NodePort 30500) — gitops/manifests/registry/registry.yaml
kubectl apply -f gitops/manifests/registry/registry.yaml
ssh ... ubuntu@$SERVER_PUB "curl -s http://${SERVER_PRIV}:30500/v2/_catalog"   # {"repositories":[]}

# configure containerd to pull from it over HTTP, on EVERY node, then restart k3s/k3s-agent:
ssh ... "bash -s" <<EOS
sudo tee /etc/rancher/k3s/registries.yaml >/dev/null <<YAML
mirrors:
  "${SERVER_PRIV}:30500":
    endpoint: [ "http://${SERVER_PRIV}:30500" ]
YAML
systemctl list-units | grep -q k3s-agent && sudo systemctl restart k3s-agent || sudo systemctl restart k3s
EOS

# verify push (in-cluster crane Job) + pull (test pod):
kubectl apply -f - <<YAML   # Job: crane copy busybox:1.36 ${SERVER_PRIV}:30500/busybox:test --insecure
... (gcr.io/go-containerregistry/crane:latest)
YAML
kubectl run regpull -n registry --image=${SERVER_PRIV}:30500/busybox:test --restart=Never --command -- sleep 20
kubectl get pod regpull -n registry -o jsonpath='{.status.phase}'   # Running == pulled OK
```

# PHASE 6-12 — App, Data, Observability, Expose, Bonus (condensed)

```bash
export KUBECONFIG=$PWD/infra/kubeconfig
# P7 CNPG operator + P8 Longhorn (Helm)
helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace --wait
helm upgrade --install longhorn longhorn/longhorn -n longhorn-system --create-namespace --version 1.12.0 -f infra/longhorn/values.yaml --wait
kubectl patch storageclass longhorn -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
# (prep: format+mount the extra EBS at /var/lib/longhorn on every node first)

# P6 build images in-cluster (kaniko, git context) -> push to the registry
#   Job: gcr.io/kaniko-project/executor --context=git://<repo>#refs/heads/main \
#        --context-sub-path=app/todo-api --destination=$SERVER_PRIV:30500/todo-api:v1 --insecure
kubectl apply -f gitops/manifests/todo/        # ns, CNPG cluster, app, networkpolicies
kubectl get cluster todo-pg -n todo            # "Cluster in healthy state", 3/3

# E2E + failover
curl -k --resolve todo.local:443:$SERVER_PUB -X POST https://todo.local/api/tasks -d '{"title":"x","done":false}'
kubectl delete pod $(kubectl get cluster todo-pg -n todo -o jsonpath='{.status.currentPrimary}') -n todo  # watch a replica promote

# P9 observability
helm upgrade --install kube-prom prometheus-community/kube-prometheus-stack -n monitoring --create-namespace -f infra/observability/kube-prom-values.yaml --wait
kubectl apply -f /tmp/istio-1.30.1/samples/addons/{jaeger,kiali,loki}.yaml
kubectl apply -f gitops/manifests/observability/    # httproutes, virtualservice, telemetry (100% sampling), istio podmonitor
# import Grafana dashboards 7639 / 315 / 20417 via the API (admin:admin)

# P10 public tunnel (no account)
kubectl apply -f gitops/manifests/expose/cloudflared.yaml
kubectl logs -n todo deploy/cloudflared | grep trycloudflare   # public URL

# P12 bonus
kubectl apply -f gitops/manifests/security/peerauth.yaml       # mTLS STRICT
# HPA: 40 concurrent workers vs https://todo-api.local/tasks -> kubectl get hpa todo-api -n todo -w
```
