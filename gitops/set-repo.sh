#!/bin/bash
# Repoint the whole GitOps tree to a different Git repo in one command.
# Only touches the GitHub repo URL — Helm chart repos (charts.longhorn.io, etc.) are left alone.
# Usage: ./gitops/set-repo.sh https://github.com/ORG/NEW-REPO
set -e
NEW="$1"
[ -z "$NEW" ] && { echo "usage: set-repo.sh <new-repo-url>"; exit 1; }

# Detect the current GitOps repo: the github.com repoURL in the tree (strip any trailing punctuation).
OLD=$(grep -rhoE 'repoURL: https://github\.com/[^ ,}]+' gitops | head -1 | awk '{print $2}')
[ -z "$OLD" ] && { echo "ERROR: could not detect a github.com repoURL under gitops/"; exit 1; }

echo "current GitOps repo: $OLD"
echo "new GitOps repo:     $NEW"

# Replace the URL substring everywhere it appears under gitops/ (works in both block and flow YAML).
grep -rl "$OLD" gitops | xargs sed -i '' "s#${OLD}#${NEW}#g"

echo
echo "Done editing files. Next: commit+push to the NEW repo, update ArgoCD repo creds, re-apply root-app."
