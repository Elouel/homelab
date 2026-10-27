# Architecture

A single Ubuntu 24.04 VPS runs a one-node **k3s** cluster. On top of it run **cert-manager**
and **Argo CD**, and Argo CD deploys everything under `platform/` and `apps/` from this Git repository.

## Layers

```mermaid
flowchart TB
  subgraph L3["Layer 3 - Your apps (Argo CD, from Git)"]
    APPS["apps/* - one Helm chart per folder"]
    PLAT["platform/* - ClusterIssuers, Vault, External Secrets, monitoring, logging"]
  end
  subgraph L2["Layer 2 - Installed by bootstrap.sh with Helm"]
    CM["cert-manager"]
    ARGO["Argo CD + ApplicationSet homelab"]
  end
  subgraph L1["Layer 1 - Bundled with k3s"]
    TRAEFIK["Traefik ingress + ServiceLB"]
    DNS["CoreDNS"]
    LP["local-path provisioner"]
    MS["metrics-server"]
  end
  subgraph L0["Layer 0 - Host"]
    K3S["k3s server: API, SQLite datastore, containerd, flannel"]
    OS["Ubuntu 24.04 VPS"]
  end
  APPS --> ARGO
  PLAT --> ARGO
  ARGO --> CM
  ARGO --> TRAEFIK
  CM --> TRAEFIK
  TRAEFIK --> K3S
  K3S --> OS
```

| Layer | Who installs it | Source of truth in this repo |
|---|---|---|
| 0 Host | You / VPS provider | — |
| 0 k3s | `bootstrap.sh` (`get.k3s.io`) | `versions.env` (`K3S_VERSION`), `k3s/config.yaml` |
| 1 Traefik, CoreDNS, local-path, metrics-server | k3s auto-deploys from `/var/lib/rancher/k3s/server/manifests` | k3s defaults (not overridden) |
| 2 cert-manager | `bootstrap.sh` (`helm upgrade --install`) | `versions.env`, `helm/cert-manager/values.yaml` |
| 2 Argo CD | `bootstrap.sh` (`helm upgrade --install`) | `versions.env`, `helm/argo-cd/values.yaml`, `.env` (hostname) |
| 2 ApplicationSet + cluster values | `bootstrap.sh` (`kubectl apply`) | `argocd/*.yaml`, `.env` |
| 3 platform + apps | Argo CD, from Git | `platform/`, `apps/` |

Argo CD does not manage itself or cert-manager: both are converged by `bootstrap.sh`, so a broken
commit can never take down the tool that would deploy the fix.

## Request flow (HTTPS traffic)

```mermaid
flowchart LR
  U["Browser"] -->|"DNS: name.SERVER_IP.sslip.io resolves to SERVER_IP"| SSLIP["sslip.io DNS"]
  U -->|"TCP 80 / 443"| LB["svclb-traefik DaemonSet - hostPorts 80, 443"]
  LB --> T["Traefik - kube-system"]
  T -->|"Host argocd.BASE_DOMAIN"| A["Service argocd-server - ns argocd"]
  T -->|"Host whoami.BASE_DOMAIN"| W["Service whoami - ns whoami"]
  T -->|"Host vault.BASE_DOMAIN"| V["Service vault - ns vault"]
  T -->|"Host grafana.BASE_DOMAIN"| GR["Service grafana - ns monitoring"]
  T -->|"Host git.BASE_DOMAIN"| G["Service forgejo-http - ns forgejo"]
  T -->|"/.well-known/acme-challenge"| S["cert-manager solver pod"]
  A --> AP["argocd-server pod - plain HTTP"]
  W --> WP["whoami pod"]
```

- **DNS** — `sslip.io` is a public wildcard DNS: any name ending in `<ip>.sslip.io` resolves to `<ip>`.
  No DNS records to manage. Switch to your own domain by setting `BASE_DOMAIN` in `.env`
  and pointing a wildcard `A` record at the server.
- **Load balancer** — k3s ServiceLB (klipper-lb) runs `svclb-traefik-*` pods that bind host ports
  80 and 443 and forward to the Traefik Service of type `LoadBalancer`.
- **Ingress** — Traefik routes by `Host` header using standard Kubernetes `Ingress` objects
  (`ingressClassName: traefik`).
- **TLS** — terminated at Traefik with certificates issued by cert-manager from Let's Encrypt.
  `argocd-server` runs with `server.insecure: true` behind it. See [tls-and-ingress.md](tls-and-ingress.md).

## Network ports on the host

| Port | Protocol | Used by | Needs to be public? |
|---|---|---|---|
| 22 | TCP | SSH | yes (for you) — restrict by source IP if you can |
| 80 | TCP | Traefik HTTP + Let's Encrypt HTTP-01 challenges | **yes** |
| 443 | TCP | Traefik HTTPS (Argo CD UI, apps) | **yes** |
| 6443 | TCP | Kubernetes API (kubectl) | only for remote kubectl — restrict |
| 9100 | TCP | node-exporter (host network), scraped by Prometheus | no |
| 10250 | TCP | kubelet | no |
| 8472 | UDP | flannel VXLAN | only when adding nodes |

Argo CD pulls from GitHub, so no inbound port is needed for GitOps.
Inbound traffic is filtered by source IP in the VPS provider's firewall, in front of the server. It is configured at
the provider, not in this repo. Every HTTPS endpoint (Argo CD, Vault, apps) is reachable only from the IPs it allows.
Let's Encrypt validates HTTP-01 from changing IPs, so port 80 must stay reachable for certificate renewal.
`ufw` on the host is not configured by `bootstrap.sh` — see [operations.md](operations.md#hardening-todo).

## Namespaces

| Namespace | Contents |
|---|---|
| `kube-system` | k3s components, Traefik |
| `cert-manager` | cert-manager controller, webhook, cainjector |
| `argocd` | Argo CD (server, application controller, repo server, ApplicationSet controller, redis), ApplicationSet `homelab`, Applications, **cluster Secret `in-cluster`** with the cluster values |
| `vault` | Vault server `vault-0` (containers `vault` + `unsealer`), its PV, Secret `vault-unseal-keys` (`platform/vault`) |
| `external-secrets` | External Secrets Operator (`platform/external-secrets`); `ClusterSecretStore vault` is cluster-scoped |
| `monitoring` | Prometheus Operator, Prometheus `prometheus-kps-0`, Alertmanager `alertmanager-kps-0`, Grafana, node-exporter, kube-state-metrics (`platform/monitoring`) |
| `logging` | Loki `loki-0`, Alloy DaemonSet (`platform/logging`) |
| `cluster-issuer` | empty (the ClusterIssuers are cluster-scoped; the namespace comes from `CreateNamespace`) |
| `forgejo` | Forgejo (`forgejo` pod: server + `register-runner` sidecar), its PV, Forgejo Runner (`forgejo-runner` pod: runner + privileged `dind`) (`apps/forgejo`) |
| `whoami`, … | one namespace per app (= folder name under `apps/`) |

## Where state lives

| State | Location | Rebuilt from Git? |
|---|---|---|
| Kubernetes objects | k3s SQLite DB `/var/lib/rancher/k3s/server/db/` | config yes, runtime state no |
| Secrets encryption key | `/var/lib/rancher/k3s/server/cred/encryption-config.json` | **no — back it up** |
| Cluster join token | `/var/lib/rancher/k3s/server/token` | no |
| Argo CD admin password, settings | Secrets / ConfigMaps in `argocd` | settings yes (`helm/argo-cd/values.yaml`), password no |
| PersistentVolume data | `/var/lib/rancher/k3s/storage/` (local-path) | no |
| Vault secrets | Raft DB on the PV of `vault-0` | **no — snapshot it**, see [secrets.md](secrets.md#backup-and-restore) |
| Metrics, logs, Grafana database | PVs of Prometheus, Loki, Alertmanager, Grafana (local-path) | dashboards/rules/data sources yes; history (10 days metrics, 7 days logs) no — not backed up |
| Vault unseal key | Secret `vault/vault-unseal-keys` (k3s DB) + your password manager | **no — without it Vault data is unreadable** |
| Vault root token | your password manager | no |
| Forgejo repositories, users, SQLite DB, Actions logs | PV `forgejo-data` (local-path) | **no — back it up**, see [forgejo.md](forgejo.md#backup-and-upgrade) |
| Site-specific settings | `.env` on your PC / server (git-ignored) | no — keep a private copy |
