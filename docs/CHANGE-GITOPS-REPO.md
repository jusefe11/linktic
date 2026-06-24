# How to change the GitOps repository

Step-by-step guide to repoint the whole platform to a different Git repo. Changing the repo touches
**three** things, not just files:

1. The repo URL inside the manifests (`gitops/apps/*`, `gitops/root-app.yaml`) → handled by `set-repo.sh`.
2. The **code** pushed to the new repo (ArgoCD reads from there).
3. The **repository credentials** in ArgoCD (matched by URL) — only if the new repo is private.

Replace `ORG/NEW-REPO` with your target repo throughout.

---

## 0. AWS pre-checks (only if the cluster is not reachable)

Most of the time you can skip this — you only need it if `kubectl` can't reach the cluster. Quick test:

```bash
cd /Users/caferrerb/aprendiendo/juan
export KUBECONFIG=$PWD/infra/kubeconfig
kubectl get nodes        # if this works, SKIP this whole section and go to Step 1
```

If it fails, run the relevant fix below.

### 0a. Instances were stopped → start them (and fix the new public IPs)
Stopping EC2 releases the public IPs, so `kubeconfig`, `/etc/hosts`, k3s `node-external-ip` and the
registry all reference stale IPs. After starting, the public IPs change.

```bash
source infra/aws-ids.env
# start all lab instances
aws ec2 describe-instances --profile juan-test \
  --filters Name=tag:Project,Values=k8s-lab Name=instance-state-name,Values=stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text \
  | xargs -r aws ec2 start-instances --profile juan-test --instance-ids
aws ec2 wait instance-running --profile juan-test --filters Name=tag:Project,Values=k8s-lab

# capture the NEW public IPs
aws ec2 describe-instances --profile juan-test \
  --filters Name=tag:Project,Values=k8s-lab Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Pub:PublicIpAddress,Priv:PrivateIpAddress}' \
  --output table
# -> update SERVER_PUB / AGENT*_PUB in infra/aws-ids.env, then refresh the local kubeconfig:
source infra/aws-ids.env
ssh -i ~/.ssh/juan-test-key.pem ubuntu@$SERVER_PUB 'sudo cat /etc/rancher/k3s/k3s.yaml' > infra/kubeconfig
chmod 600 infra/kubeconfig
sed -i '' "s#https://127.0.0.1:6443#https://${SERVER_PUB}:6443#" infra/kubeconfig
```
> Tip: to avoid IP churn entirely, attach Elastic IPs to the nodes. For a temporary lab it's usually
> cheaper to just refresh the IPs as above.

### 0b. Your laptop's public IP changed → update the security group
The security group only allows your IP on ports 22/80/443/6443. If your IP changed, `kubectl` (6443)
will time out.

```bash
source infra/aws-ids.env
NEWIP=$(curl -s https://checkip.amazonaws.com)
for p in 22 80 443 6443; do
  aws ec2 authorize-security-group-ingress --profile juan-test --group-id $SG_ID \
    --ip-permissions "IpProtocol=tcp,FromPort=$p,ToPort=$p,IpRanges=[{CidrIp=${NEWIP}/32}]" 2>/dev/null || true
done
# (optionally revoke the old IP rules afterwards)
```

Re-run `kubectl get nodes` to confirm the cluster is reachable before continuing.

---

## 1. Create the new repo
```bash
cd /Users/caferrerb/aprendiendo/juan
gh repo create ORG/NEW-REPO --private --description "Cloud-native k8s platform"
# or create it manually in GitHub/GitLab
```

## 2. Repoint every manifest (one command)
```bash
./gitops/set-repo.sh https://github.com/ORG/NEW-REPO
```
Rewrites the GitHub repo URL across all of `gitops/` and leaves Helm chart repos
(`charts.longhorn.io`, etc.) untouched. It prints `current -> new` for you to confirm.

## 3. Commit and push to the new repo
```bash
git add -A
git commit -m "chore: repoint gitops repo to NEW-REPO"
git remote set-url origin https://github.com/ORG/NEW-REPO.git   # point 'origin' at the new repo
git push -u origin main
```

## 4. Update the ArgoCD credentials (only if the new repo is private)
ArgoCD matches credentials to repos by URL, so register the new repo:
```bash
export KUBECONFIG=$PWD/infra/kubeconfig
GHTOKEN=$(gh auth token)            # use the token/user of the account that owns NEW-REPO
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-cloud-native
  namespace: argocd
  labels: { argocd.argoproj.io/secret-type: repository }
stringData:
  type: git
  url: https://github.com/ORG/NEW-REPO
  username: ORG
  password: ${GHTOKEN}
EOF
```

## 5. Re-apply the root App (the running app still points to the old repo)
Editing files does **not** change what's already running in the cluster. Re-apply the root Application —
it now reads from the new repo and propagates the change to all child Applications:
```bash
kubectl apply -f gitops/root-app.yaml
kubectl -n argocd patch app root --type merge -p '{"operation":{"sync":{}}}'
```

## 6. Verify
```bash
kubectl get applications -n argocd \
  -o custom-columns='APP:.metadata.name,REPO:.spec.source.repoURL,SYNC:.status.sync.status'
```
Expected: the REPO column shows `https://github.com/ORG/NEW-REPO` for every app **except**
`infra-longhorn` (which points to the Helm chart `charts.longhorn.io` — correct, untouched).

If an app stays `OutOfSync`, force it:
```bash
kubectl -n argocd patch app <name> --type merge -p '{"operation":{"sync":{}}}'
```

---

## Notes
- The Longhorn app (`infra-longhorn`) uses the official Helm chart repo, not your Git repo — the script
  intentionally skips it.
- Changing the GitOps repo does **not** require rebuilding images or touching the registry; the app
  images stay in the in-cluster registry.
- AWS steps (section 0) are only needed when the cluster is unreachable — usually because instances were
  stopped (new public IPs) or your laptop's IP changed (security group).
