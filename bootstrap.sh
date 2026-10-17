#!/usr/bin/env bash
# Rebuilds the HomeLab single-node k3s + Rancher cluster.
# Run as root on a fresh Ubuntu 24.04 host, from the repo root:  sudo ./bootstrap.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./versions.env
[ -f .env ] || { echo "Missing .env (copy .env.example and fill it in)"; exit 1; }
source ./.env
[ "$(id -u)" = 0 ] || { echo "Run as root"; exit 1; }

SERVER_IP=${SERVER_IP:-$(curl -fsS https://api.ipify.org || hostname -I | awk '{print $1}')}
BASE_DOMAIN=${BASE_DOMAIN:-${SERVER_IP}.sslip.io}
RANCHER_HOSTNAME=${RANCHER_HOSTNAME:-rancher.${BASE_DOMAIN}}
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
step(){ echo -e "\n==> $*"; }

step "k3s ${K3S_VERSION}"
install -D -m 0600 k3s/config.yaml /etc/rancher/k3s/config.yaml
if ! command -v k3s >/dev/null || ! k3s --version | grep -q "${K3S_VERSION}"; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - server
fi
until kubectl get nodes 2>/dev/null | grep -q ' Ready'; do sleep 3; done
kubectl -n kube-system rollout status deploy/traefik --timeout=5m 2>/dev/null || \
  { until kubectl -n kube-system get deploy traefik >/dev/null 2>&1; do sleep 5; done; \
    kubectl -n kube-system rollout status deploy/traefik --timeout=5m; }

step "cluster values (kube-system/homelab-values) - read by Fleet apps via helm.valuesFrom"
kubectl -n kube-system create configmap homelab-values \
  --from-literal=values.yaml="$(printf 'serverIP: %s\ndomain: %s\n' "${SERVER_IP}" "${BASE_DOMAIN}")" \
  --dry-run=client -o yaml | kubectl apply -f -

step "helm ${HELM_VERSION}"
if ! command -v helm >/dev/null || ! helm version --short | grep -q "${HELM_VERSION}"; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | DESIRED_VERSION="${HELM_VERSION}" bash
fi
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update
helm repo update

step "cert-manager ${CERT_MANAGER_VERSION}"
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace --version "${CERT_MANAGER_VERSION}" \
  -f helm/cert-manager/values.yaml --wait --timeout 10m

step "Rancher ${RANCHER_VERSION} at https://${RANCHER_HOSTNAME}"
helm upgrade --install rancher rancher-stable/rancher \
  -n cattle-system --create-namespace --version "${RANCHER_VERSION}" \
  -f helm/rancher/values.yaml \
  --set hostname="${RANCHER_HOSTNAME}" \
  --set letsEncrypt.email="${LETSENCRYPT_EMAIL}" \
  --set bootstrapPassword="${RANCHER_BOOTSTRAP_PASSWORD}"
kubectl -n cattle-system rollout status deploy/rancher --timeout=15m

if [ -n "${GIT_REPO_URL:-}" ] && [[ "${GIT_REPO_URL}" != *"<user>"* ]]; then
  step "GitOps: Fleet -> ${GIT_REPO_URL} (${GIT_BRANCH:-main})"
  until kubectl get crd gitrepos.fleet.cattle.io >/dev/null 2>&1; do sleep 5; done
  sed -e "s|\${GIT_REPO_URL}|${GIT_REPO_URL}|" -e "s|\${GIT_BRANCH}|${GIT_BRANCH:-main}|" \
    fleet/gitrepo.yaml | kubectl apply -f -
else
  echo "GIT_REPO_URL not set in .env - skipping Fleet GitRepo"
fi

echo -e "\nDone. Open https://${RANCHER_HOSTNAME}  (Let's Encrypt cert may take a minute or two)"
echo "Rancher will now install fleet, rancher-webhook, turtles/CAPI and system-upgrade-controller by itself."
