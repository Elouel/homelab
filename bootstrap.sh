#!/usr/bin/env bash
# Rebuilds the HomeLab single-node k3s + Argo CD cluster.
# Run as root on a fresh Ubuntu 24.04 host, from the repo root:  sudo ./bootstrap.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./versions.env
[ -f .env ] || { echo "Missing .env (copy .env.example and fill it in)"; exit 1; }
source ./.env
[ "$(id -u)" = 0 ] || { echo "Run as root"; exit 1; }

SERVER_IP=${SERVER_IP:-$(curl -fsS https://api.ipify.org || hostname -I | awk '{print $1}')}
BASE_DOMAIN=${BASE_DOMAIN:-${SERVER_IP}.sslip.io}
ARGOCD_HOSTNAME=${ARGOCD_HOSTNAME:-argocd.${BASE_DOMAIN}}
GIT_BRANCH=${GIT_BRANCH:-main}
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

step "helm ${HELM_VERSION}"
if ! command -v helm >/dev/null || ! helm version --short | grep -q "${HELM_VERSION}"; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | DESIRED_VERSION="${HELM_VERSION}" bash
fi
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update

step "cert-manager ${CERT_MANAGER_VERSION}"
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace --version "${CERT_MANAGER_VERSION}" \
  -f helm/cert-manager/values.yaml --wait --timeout 10m

step "Argo CD (chart ${ARGO_CD_CHART_VERSION}) at https://${ARGOCD_HOSTNAME}"
helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace --version "${ARGO_CD_CHART_VERSION}" \
  -f helm/argo-cd/values.yaml \
  --set global.domain="${ARGOCD_HOSTNAME}" \
  --wait --timeout 10m

step "cluster values (Secret argocd/in-cluster) - read by the homelab ApplicationSet"
# Registers the local cluster with Argo CD explicitly, so the cluster generator can select it by
# label and pass its annotations (domain, serverIP) to every platform component and app as Helm values.
kubectl -n argocd create secret generic in-cluster \
  --from-literal=name=in-cluster \
  --from-literal=server=https://kubernetes.default.svc \
  --from-literal=config='{"tlsClientConfig":{"insecure":false}}' \
  --dry-run=client -o yaml \
| kubectl label --local -f - -o yaml \
    argocd.argoproj.io/secret-type=cluster homelab/cluster-values=true \
| kubectl annotate --local -f - -o yaml \
    homelab/domain="${BASE_DOMAIN}" homelab/server-ip="${SERVER_IP}" \
| kubectl apply -f -

if [ -n "${GIT_REPO_URL:-}" ] && [[ "${GIT_REPO_URL}" != *"<user>"* ]]; then
  step "GitOps: ApplicationSet homelab -> ${GIT_REPO_URL} (${GIT_BRANCH})"
  # ApplicationSets apps and platform of the earlier two-file layout: remove them without their Applications
  # (--cascade=orphan), so the homelab ApplicationSet adopts those by name. A normal delete would cascade to the
  # Applications and, through the apps' finalizer, to everything the apps deploy.
  kubectl -n argocd delete applicationset apps platform --cascade=orphan --ignore-not-found
  for f in argocd/*.yaml; do
    sed -e "s|\${GIT_REPO_URL}|${GIT_REPO_URL}|g" -e "s|\${GIT_BRANCH}|${GIT_BRANCH}|g" "$f"
    echo "---"
  done | kubectl apply -f -
  echo "Waiting for ClusterIssuer letsencrypt-prod (deployed by Argo CD from platform/)..."
  if kubectl wait clusterissuer/letsencrypt-prod --for=condition=Ready --timeout=5m 2>/dev/null; then
    kubectl -n argocd wait certificate/argocd-server-tls --for=condition=Ready --timeout=5m \
      || echo "Argo CD certificate not ready yet - see docs/tls-and-ingress.md#debugging-a-certificate"
  else
    echo "ClusterIssuer not ready yet - check the platform-cluster-issuer app in Argo CD"
  fi
else
  echo "GIT_REPO_URL not set in .env - skipping the ApplicationSet"
fi

echo -e "\nDone. Open https://${ARGOCD_HOSTNAME}  (user: admin)"
echo "Initial admin password:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
