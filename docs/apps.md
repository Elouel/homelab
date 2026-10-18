# App catalogue

Everything Argo CD deploys from this repo. **Keep this table current** whenever you add, rename or remove a folder
under `platform/` or `apps/`.

| Folder | Argo CD Application | Namespace | Kind | URL | Secrets needed (Vault paths under `kv/`) | Persistent data |
|---|---|---|---|---|---|---|
| `platform/cluster-issuer` | `platform-cluster-issuer` | `cluster-issuer` (empty; the ClusterIssuers are cluster-scoped) | local chart | — | none | none |
| `platform/vault` | `platform-vault` | `vault` | wrapper of `hashicorp/vault` 0.34.1 (Vault 2.0.4) | `https://vault.<BASE_DOMAIN>` | none in Vault. Secret `vault-unseal-keys` (made by `tools/vault-init.sh`); unseal key + root token also in your password manager (see [secrets.md](secrets.md#first-time-setup)) | 2 Gi PV `data-vault-0` (Raft) |
| `platform/external-secrets` | `platform-external-secrets` | `external-secrets` | wrapper of `external-secrets` 2.13.0 (image v2.13.0) | — | none in Vault (logs in with its ServiceAccount) | none |
| `platform/monitoring` | `platform-monitoring` | `monitoring` | wrapper of `kube-prometheus-stack` 92.10.1 (Prometheus Operator v0.94.1) + `prometheus-operator-crds` 32.0.1 | `https://grafana.<BASE_DOMAIN>` | `kv/apps/monitoring/grafana` (`admin-user`, `admin-password`), `kv/apps/monitoring/alertmanager-telegram` (`bot-token`, `chat-id`) | 10 Gi PV Prometheus, 1 Gi Alertmanager, 1 Gi Grafana |
| `platform/logging` | `platform-logging` | `logging` | wrapper of `grafana-community/loki` 18.17.1 (Loki 3.7.8) + `grafana/alloy` 1.13.1 (Alloy v1.20.1) | — (read in Grafana) | none | 10 Gi PV `storage-loki-0` |
| `apps/whoami` | `whoami` | `whoami` | local chart | `https://whoami.<BASE_DOMAIN>` | none | none |

Installed by `bootstrap.sh` rather than from these folders: cert-manager, and Argo CD itself at
`https://argocd.<BASE_DOMAIN>` (see [bootstrap.md](bootstrap.md)).

## Platform components

| Component | Purpose |
|---|---|
| `ClusterIssuer letsencrypt-prod` | Trusted Let's Encrypt certificates for app Ingresses and the Argo CD UI |
| `ClusterIssuer letsencrypt-staging` | Untrusted test certificates with high rate limits, for trying out new apps |
| Vault | Secret store for apps and builds. Auto-unsealed by a sidecar after every restart |
| External Secrets Operator + `ClusterSecretStore vault` | Copies Vault secrets (`kv/apps/<namespace>/*`, each namespace only its own) into Kubernetes Secrets via `ExternalSecret` objects |
| Prometheus + Alertmanager + Grafana | Metrics of the server, Kubernetes, platform and apps; alerts to Telegram; dashboards at `grafana.<BASE_DOMAIN>` |
| Loki + Alloy | Pod logs and Kubernetes events, 7 days, searchable in Grafana |

### vault

HashiCorp Vault, one replica with integrated (Raft) storage, UI enabled, agent injector disabled. Traefik terminates
TLS and forwards to Service `vault` (also while sealed, so the UI shows the status); inside the cluster the
External Secrets store uses plain HTTP at `vault-active.vault.svc:8200`. A sidecar `unsealer` unseals it
on every start from Secret `vault-unseal-keys`. Needs a one-time `tools/vault-init.sh`. See [secrets.md](secrets.md).

### external-secrets

External Secrets Operator (controller, webhook, cert controller) and the `ClusterSecretStore vault`. The store
logs in with Vault's Kubernetes auth (role `external-secrets`, audience `vault`) as ServiceAccount `default` of each
ExternalSecret's namespace, so every namespace reads only `kv/apps/<namespace>/*`. Apps use it as described in
[secrets.md](secrets.md#giving-an-app-a-secret).

### monitoring

kube-prometheus-stack: Prometheus Operator, Prometheus (10 days, 8 GB max), Alertmanager (routes to Telegram, token and
chat ID from Vault), Grafana (admin login from Vault, ~25 dashboards plus Traefik's), node-exporter and
kube-state-metrics. Scrapes every `ServiceMonitor`/`PodMonitor`/`PrometheusRule` in the cluster, and also Traefik,
cert-manager, Argo CD, Loki and Alloy (`templates/scrape-platform.yaml`). Extra alerts in `templates/rules-platform.yaml`.
The CRDs come from `prometheus-operator-crds` (server-side apply). See [monitoring.md](monitoring.md).

### logging

Loki in Monolithic mode (one pod, filesystem storage on its PV, 7 days retention, no gateway or caches) and Grafana Alloy
as a DaemonSet that reads every pod's logs and the Kubernetes events through the API and pushes them to
`http://loki.logging.svc:3100`. Grafana (`platform/monitoring`) has Loki as a data source. See [monitoring.md](monitoring.md).

## Apps

### whoami

Tiny HTTP server that echoes request details. It shows that DNS, Traefik, TLS and Argo CD all work end to end.
Image `traefik/whoami`. Uses the reference layout described in [adding-an-app.md](adding-an-app.md).
