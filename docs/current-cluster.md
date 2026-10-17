# Snapshot of the original cluster (2026-10-17)

> **Outdated:** this is the Rancher + Fleet cluster the repo started from. The repo now builds a
> k3s + Argo CD cluster (no Rancher). After rebuilding the server, re-export it
> ([operations.md](operations.md#re-exporting-the-cluster)) and replace this page.

From `tools/export-cluster.sh`. The raw archive is in `.secrets/k3s-export.tar.gz` (not committed).

- Node: single VPS (IP in `.env`), Ubuntu 24.04.5, kernel 6.8.0-139, 8 GB RAM, no swap, ufw inactive
- k3s v1.36.5+k3s1, containerd 2.3.4, single server, flag `--secrets-encryption`, no `config.yaml`
- No custom registries, no extra files in `server/manifests`, no local-path PVs
- StorageClass: `local-path` (default). IngressClass: `traefik`

## Helm releases

| Namespace | Release | Chart | Installed by |
|---|---|---|---|
| kube-system | traefik / traefik-crd | 40.1.5+up40.1.0 | k3s |
| cert-manager | cert-manager | v1.21.2 | you (jetstack) |
| cattle-system | rancher | 2.15.2 | you (rancher-stable) |
| cattle-system | rancher-webhook | 110.0.3+up0.11.3 | Rancher |
| cattle-system | system-upgrade-controller | 110.0.0 | Rancher |
| cattle-fleet-system | fleet / fleet-crd | 110.0.2+up0.16.2 | Rancher |
| cattle-fleet-local-system | fleet-agent-local | — | Rancher |
| cattle-turtles-system | rancher-turtles | 110.0.2+up0.27.2 | Rancher |

Rancher values in use: `hostname=rancher.<SERVER_IP>.sslip.io`, `ingress.tls.source=letsEncrypt`,
`letsEncrypt.ingress.class=traefik`, `replicas=1`, plus email and bootstrap password.

## User workloads

None. Every Deployment, Service and Ingress belongs to k3s, cert-manager or Rancher.
