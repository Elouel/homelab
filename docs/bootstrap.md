# bootstrap.sh — step by step

`bootstrap.sh` turns a fresh Ubuntu 24.04 server into the full cluster, and is safe to re-run on an
existing one (every step is "install if missing, otherwise converge to the pinned version").

## Prerequisites

- Ubuntu 24.04, root shell, outbound internet access
- Ports 80 and 443 reachable from the internet (Let's Encrypt HTTP-01)
- The bootstrap files copied to `/root/homelab` on the server (see below). The repo is **not** cloned on the server:
  Argo CD reads `platform/` and `apps/` straight from GitHub, so the server only needs what `bootstrap.sh` and the
  Vault scripts use.

## Copying the files to the server

From your PC (PowerShell, in the repo folder). Push first, because Argo CD deploys what is on GitHub:

```powershell
git push
$line = Select-String '^SERVER_IP=' .env | Select-Object -First 1
$ip = if ($line) { (($line.Line -split '=',2)[1] -replace '\s+#.*$','').Trim().Trim('"',"'") } else { '' }
if (-not $ip) { $ip = Read-Host 'Server IP' }   # SERVER_IP is empty in .env (auto-detect)
# first time only: ssh root@$ip "mkdir -p /root/homelab"
scp -r bootstrap.sh versions.env .env k3s helm argocd tools "root@${ip}:/root/homelab/"
ssh -t root@$ip "cd /root/homelab && chmod +x bootstrap.sh tools/*.sh && sed -i 's/\r$//' .env && ./bootstrap.sh"
```

SSH asks for the root password once per command (two prompts).

| Copied | Used by |
|---|---|
| `bootstrap.sh`, `versions.env`, `.env` | `bootstrap.sh` |
| `k3s/`, `helm/`, `argocd/` | `bootstrap.sh` (k3s config, Helm values, ApplicationSet) |
| `tools/` | Vault setup: `vault-init.sh`, `vault-configure.sh` and their shared `vault-lib.sh` ([secrets.md](secrets.md)). The other scripts in it are copied along but not needed |

Re-run the same block whenever one of these files changes.

## Flow

```mermaid
sequenceDiagram
  autonumber
  participant B as bootstrap.sh
  participant H as Host (root)
  participant K as k3s API
  participant HR as Helm
  participant A as Argo CD
  B->>B: source versions.env and .env, compute SERVER_IP / BASE_DOMAIN / ARGOCD_HOSTNAME
  B->>H: install k3s/config.yaml to /etc/rancher/k3s/config.yaml
  alt k3s missing or wrong version
    B->>H: curl get.k3s.io with INSTALL_K3S_VERSION
  end
  B->>K: wait for node Ready and deploy/traefik rolled out
  alt helm missing or wrong version
    B->>H: install helm via get-helm-3 with DESIRED_VERSION
  end
  B->>HR: repo add jetstack + argo, repo update
  B->>HR: upgrade --install cert-manager (wait)
  B->>HR: upgrade --install argocd (global.domain = ARGOCD_HOSTNAME, wait)
  B->>K: apply Secret argocd/in-cluster (labels + annotations domain, server-ip)
  alt GIT_REPO_URL set in .env
    B->>K: delete ApplicationSets apps, platform if present (cascade orphan)
    B->>K: apply argocd/*.yaml with URL and branch substituted
    A-->>K: creates Applications, deploys platform/ and apps/
    B->>K: wait for ClusterIssuer letsencrypt-prod, then Certificate argocd-server-tls
  end
  B->>B: print UI URL and the command for the initial admin password
```

## What each step does

| # | Step | Details | Idempotency |
|---|---|---|---|
| 1 | Load settings | `versions.env` (pinned versions, committed) then `.env` (site settings, private). `SERVER_IP` falls back to `api.ipify.org`, then the first local address. `BASE_DOMAIN` defaults to `SERVER_IP.sslip.io`; `ARGOCD_HOSTNAME` to `argocd.BASE_DOMAIN`; `GIT_BRANCH` to `main`. | pure computation |
| 2 | k3s config | Copies `k3s/config.yaml` → `/etc/rancher/k3s/config.yaml` (mode 0600). Enables `secrets-encryption`. | overwritten each run; k3s only re-reads it on restart |
| 3 | k3s install | Runs the official installer pinned to `K3S_VERSION`. Creates the `k3s` systemd unit and `/usr/local/bin/{k3s,kubectl,crictl,ctr}`. | skipped when `k3s --version` already matches |
| 4 | Wait | Until the node is `Ready` and Traefik (auto-deployed by k3s) has rolled out. | — |
| 5 | Helm | Installs Helm `HELM_VERSION`; adds repos `jetstack` and `argo`. | skipped when version matches; repo add uses `--force-update` |
| 6 | cert-manager | Release `cert-manager` in ns `cert-manager`, values `helm/cert-manager/values.yaml` (`crds.enabled: true`). `--wait` so its webhook is ready before anything requests certificates. | `helm upgrade --install` (no-op revision if nothing changed) |
| 7 | Argo CD | Release `argocd` in ns `argocd`, chart `argo/argo-cd` `ARGO_CD_CHART_VERSION`, values `helm/argo-cd/values.yaml` plus `global.domain` (the UI hostname) from `.env`. `--wait`. | `helm upgrade --install` |
| 8 | Cluster values | Secret `argocd/in-cluster`: registers the local cluster with Argo CD, labelled `homelab/cluster-values=true`, annotated with `homelab/domain` and `homelab/server-ip`. The `homelab` ApplicationSet passes them to every chart. See [configuration.md](configuration.md#cluster-values). | `kubectl apply` |
| 9 | GitOps seed | Only if `GIT_REPO_URL` is set and is not the `<user>` placeholder. First deletes the ApplicationSets `apps` and `platform` of the earlier two-file layout, if they exist, with `--cascade=orphan`: their Applications and everything those deployed keep running, and the `homelab` ApplicationSet adopts the Applications by name. Then `sed` fills `${GIT_REPO_URL}` and `${GIT_BRANCH}` in `argocd/*.yaml` and applies them. Argo CD then deploys `platform/` (ClusterIssuers, Vault, External Secrets) and `apps/`. Vault then needs a one-time `tools/vault-init.sh` ([secrets.md](secrets.md#first-time-setup)). | `kubectl delete --ignore-not-found`, `kubectl apply` |
| 10 | TLS check | Waits up to 5 min for `ClusterIssuer letsencrypt-prod` and then for the Argo CD UI certificate. Prints a hint instead of failing if they are slow. | read-only |

## Typical runtimes

| Phase | Fresh server |
|---|---|
| k3s install + Traefik ready | 1–2 min |
| cert-manager | ~1 min |
| Argo CD | 1–3 min |
| First sync of platform/ and apps/ + Argo CD certificate | 1–3 min |

## Re-running

Re-run after changing `.env`, `versions.env`, `argocd/*.yaml` or anything under `k3s/` or `helm/`.
Changes under `platform/` or `apps/` do **not** need it — just `git push` (see [gitops.md](gitops.md)).

## First login

User `admin`. The initial password is generated by Argo CD; on the server:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Change it in the UI (**User Info → Update Password**), then delete the generated one with
`kubectl -n argocd delete secret argocd-initial-admin-secret`. Re-running `bootstrap.sh` does not reset the password.
