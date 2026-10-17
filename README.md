# HomeLab — k3s + Rancher

Infrastructure-as-code to rebuild the single-node k3s cluster running Rancher
(Ubuntu 24.04, 8 GB RAM). Server IP, domain and passwords live only in `.env`.

## What gets installed

| Layer | Version | How |
|---|---|---|
| k3s (with `secrets-encryption`) | v1.36.5+k3s1 | `get.k3s.io` + `k3s/config.yaml` |
| Traefik, CoreDNS, local-path, metrics-server | bundled | k3s defaults |
| Helm | v3.22.1 | `get-helm-3` |
| cert-manager | v1.21.2 | Helm, `helm/cert-manager/values.yaml` |
| Rancher | 2.15.2 | Helm, `helm/rancher/values.yaml` + `.env` |

Rancher then installs on its own: fleet, rancher-webhook, rancher-turtles (CAPI),
system-upgrade-controller. Those are **not** in this repo on purpose.

## Rebuild

On a fresh Ubuntu 24.04 server (ports 80, 443 and 6443 reachable):

```bash
git clone <this repo> homelab && cd homelab
cp .env.example .env && nano .env      # SERVER_IP, email, bootstrap password, repo URL
sudo ./bootstrap.sh
```

`BASE_DOMAIN` defaults to `<SERVER_IP>.sslip.io` and Rancher is served at `rancher.<BASE_DOMAIN>`. TLS comes from Let's Encrypt via
Rancher's own Issuer, so port 80 must be open to the internet.

The script is idempotent: re-running it upgrades or reapplies to the pinned versions in `versions.env`.

## GitOps (Fleet)

Fleet ships with Rancher. `bootstrap.sh` registers this repo with it (`fleet/gitrepo.yaml`,
URL from `GIT_REPO_URL` in `.env`). After that, **`git push` is the deploy**: Fleet polls every 30s.

- `platform/` holds cluster-wide pieces: a `letsencrypt-prod` ClusterIssuer.
- `apps/<name>/` is one app per folder: a `fleet.yaml` (target namespace, Helm chart or kustomize options) plus manifests.
  `apps/whoami` is a working example (a tiny Helm chart) at `https://whoami.<BASE_DOMAIN>`. Copy it to start a new app.
- **Cluster-specific values stay out of git.** `bootstrap.sh` writes `.env` values into ConfigMap
  `kube-system/homelab-values` (`serverIP`, `domain`), and each app's `fleet.yaml` pulls them in with
  `helm.valuesFrom`, so templates use `{{ .Values.domain }}`. After changing `.env`, re-run `./bootstrap.sh`.
- Check status in Rancher → **Continuous Delivery → Git Repos**, or with `kubectl -n fleet-local get gitrepo,bundles`.
- Removing an app folder removes the app from the cluster.

**This repo is public, so never commit plain Secrets.** Use Sealed Secrets or SOPS for those (not set up yet).

## Layout

```
bootstrap.sh              one-shot installer
versions.env              pinned versions
.env.example              site-specific settings (copy to .env, git-ignored)
k3s/config.yaml           -> /etc/rancher/k3s/config.yaml
helm/cert-manager/        cert-manager values
helm/rancher/             Rancher values
fleet/gitrepo.yaml        Fleet seed (points Fleet at this repo)
platform/                 cluster-wide config deployed by Fleet
apps/                     your apps, deployed by Fleet
tools/export-cluster.sh   snapshot a running cluster (run on the node as root)
docs/current-cluster.md   what the original cluster looked like
.secrets/                 git-ignored: SSH keys, raw exports
```

## Not covered (state, not config)

- Rancher users, passwords, projects and settings you've changed in the UI. They live in Rancher's CRDs,
  so back them up with the **rancher-backup** operator if you need them.
- Persistent volume data. The original cluster had none.
