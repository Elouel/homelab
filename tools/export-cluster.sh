#!/usr/bin/env bash
# Collects everything needed to rebuild this k3s (+ Rancher/Helm) cluster.
# Run as root on the k3s server node:  bash export-cluster.sh
# Output: /root/k3s-export.tar.gz
# Secrets are exported WITHOUT values unless you run: INCLUDE_SECRETS=1 bash export-cluster.sh
set -u
OUT=/root/k3s-export
rm -rf "$OUT" && mkdir -p "$OUT"/{host,k3s,helm,cluster,namespaced}
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
K="kubectl"; command -v kubectl >/dev/null || K="k3s kubectl"
log(){ echo "[export] $*"; }

log "host info"
{ hostname; uname -a; cat /etc/os-release; } > "$OUT/host/os.txt" 2>&1
ip -br addr > "$OUT/host/ip.txt" 2>&1
df -h > "$OUT/host/df.txt" 2>&1
free -h > "$OUT/host/mem.txt" 2>&1
(ufw status verbose || iptables -S) > "$OUT/host/firewall.txt" 2>&1
crontab -l > "$OUT/host/crontab.txt" 2>&1

log "k3s config"
k3s --version > "$OUT/k3s/version.txt" 2>&1
for f in /etc/rancher/k3s/config.yaml /etc/rancher/k3s/registries.yaml \
         /etc/systemd/system/k3s.service /etc/systemd/system/k3s-agent.service; do
  [ -f "$f" ] && cp "$f" "$OUT/k3s/"
done
ls /etc/rancher/k3s/config.yaml.d/ >/dev/null 2>&1 && cp -r /etc/rancher/k3s/config.yaml.d "$OUT/k3s/"
# env files hold the join token -> redact values
for f in /etc/systemd/system/k3s.service.env /etc/systemd/system/k3s-agent.service.env; do
  [ -f "$f" ] && sed -E 's/^([A-Z_]+)=.*/\1=<REDACTED>/' "$f" > "$OUT/k3s/$(basename "$f")"
done
sed -i -E 's/(password|token|secret)(["]?\s*[:=]\s*).*/\1\2<REDACTED>/I' "$OUT"/k3s/*.yaml 2>/dev/null
[ -d /var/lib/rancher/k3s/server/manifests ] && cp -r /var/lib/rancher/k3s/server/manifests "$OUT/k3s/server-manifests"
ls -la /var/lib/rancher/k3s/storage > "$OUT/k3s/local-path-storage.txt" 2>&1
du -sh /var/lib/rancher/k3s/storage/* >> "$OUT/k3s/local-path-storage.txt" 2>&1

log "helm"
if command -v helm >/dev/null; then
  helm version > "$OUT/helm/version.txt" 2>&1
  helm repo list -o yaml > "$OUT/helm/repos.yaml" 2>&1
  helm list -A -o json > "$OUT/helm/releases.json" 2>&1
  helm list -A --no-headers | while read -r name ns _; do
    helm get values "$name" -n "$ns" -o yaml > "$OUT/helm/values__${ns}__${name}.yaml" 2>&1
    helm get metadata "$name" -n "$ns" -o yaml > "$OUT/helm/meta__${ns}__${name}.yaml" 2>&1
  done
else
  echo "helm not installed" > "$OUT/helm/NOTE.txt"
fi

log "cluster-scoped resources"
$K version -o yaml > "$OUT/cluster/version.yaml" 2>&1
$K get nodes -o wide > "$OUT/cluster/nodes.txt" 2>&1
$K get nodes -o json > "$OUT/cluster/nodes.json" 2>&1
$K get crd -o custom-columns=NAME:.metadata.name,HELM:.metadata.labels.app\\.kubernetes\\.io/managed-by --no-headers > "$OUT/cluster/crd-list.txt" 2>&1
$K api-resources --verbs=list -o wide > "$OUT/cluster/api-resources.txt" 2>&1

SKIP='^(events|events\.events\.k8s\.io|nodes|componentstatuses|.*\.metrics\.k8s\.io|leases\..*|endpoints|endpointslices\..*|pods|replicasets\.apps|controllerrevisions\.apps|jobs\.batch|tokenreviews.*|selfsubjectaccessreviews.*|.*reviews\..*|certificatesigningrequests\..*|.*\.cattle\.io|.*\.fleet\.cattle\.io|.*\.cluster\.x-k8s\.io|apiservices\..*|customresourcedefinitions\..*)$'

for r in $($K api-resources --verbs=list --namespaced=false -o name); do
  echo "$r" | grep -Eq "$SKIP" && continue
  $K get "$r" -o json > "$OUT/cluster/$r.json" 2>/dev/null
done

log "namespaced resources"
$K get ns -o json > "$OUT/cluster/namespaces.json"
for r in $($K api-resources --verbs=list --namespaced=true -o name); do
  echo "$r" | grep -Eq "$SKIP" && continue
  if [ "$r" = "secrets" ]; then
    if [ "${INCLUDE_SECRETS:-0}" = "1" ]; then
      $K get secrets -A -o json > "$OUT/namespaced/secrets.FULL.json"
    fi
    # names, types and keys only (helm release secrets skipped)
    $K get secrets -A -o go-template='{{range .items}}{{if ne .type "helm.sh/release.v1"}}{{.metadata.namespace}}	{{.metadata.name}}	{{.type}}	{{range $k,$v := .data}}{{$k}},{{end}}{{"\n"}}{{end}}{{end}}' \
      > "$OUT/namespaced/secrets.redacted.tsv" 2>&1
    continue
  fi
  $K get "$r" -A -o json > "$OUT/namespaced/$r.json" 2>/dev/null
done
# Rancher CRs are skipped above (Rancher recreates them); keep a list for reference
$K api-resources --verbs=list -o name | grep -E 'cattle\.io' | while read -r r; do
  echo "== $r"; $K get "$r" -A --no-headers 2>/dev/null | head -50
done > "$OUT/cluster/rancher-objects-list.txt"

# drop empty lists
find "$OUT" -name '*.json' -size -200c -exec grep -l '"items": \[\]' {} + 2>/dev/null | xargs -r rm -f

tar -czf /root/k3s-export.tar.gz -C /root k3s-export
log "done -> /root/k3s-export.tar.gz ($(du -h /root/k3s-export.tar.gz | cut -f1))"
