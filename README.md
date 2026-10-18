# HomeLab — k3s + Argo CD

Infrastructure-as-code for a single-node **k3s** cluster. **Argo CD** deploys everything under
`platform/` and `apps/` from this repository. Server IP, domain and other site-specific settings
live only in a private `.env`; nothing site-specific is committed.

```mermaid
flowchart LR
  DEV["You: edit + git push"] --> GH["GitHub (this repo)"]
  ENV[".env - private"] --> BS["bootstrap.sh - run once on the server"]
  GH --> BS
  BS --> K3S["k3s + Traefik"]
  BS --> CM["cert-manager"]
  BS --> AR["Argo CD + ApplicationSet"]
  GH -->|"poll about every 3 min"| AR
  AR --> P["platform/ - ClusterIssuers, Vault, External Secrets"]
  AR --> A["apps/ - Forgejo + runner, your apps"]
  U["Internet"] -->|"80 / 443"| K3S
```

## Quick start

```bash
# on your PC (once per clone)
sh tools/setup-git-hooks.sh          # secret scanning before every commit (needs gitleaks)
cp .env.example .env                 # fill in SERVER_IP (or leave empty), repo URL

# then copy the bootstrap files to a fresh Ubuntu 24.04 server and run bootstrap.sh:
# see docs/bootstrap.md "Copying the files to the server" (no git clone on the server)
```

Then open `https://argocd.<BASE_DOMAIN>` and log in as `admin` (bootstrap prints how to get the
initial password). To deploy apps, add a folder under `apps/` and `git push`.

## What gets installed

| Component | Version | Installed by |
|---|---|---|
| k3s (secrets encryption on) + Traefik, CoreDNS, local-path, metrics-server | v1.36.5+k3s1 | `bootstrap.sh` |
| Helm | v3.22.1 | `bootstrap.sh` |
| cert-manager | v1.21.2 | `bootstrap.sh` (Helm) |
| Argo CD | v3.5.5 (chart `argo/argo-cd` 10.10.5) | `bootstrap.sh` (Helm) |
| ApplicationSet `homelab` | — | `bootstrap.sh` (from `argocd/homelab.yaml`) |
| Vault | v2.0.4 (chart `hashicorp/vault` 0.34.1) | Argo CD, `platform/vault` |
| External Secrets Operator | v2.13.0 (chart `external-secrets` 2.13.0) | Argo CD, `platform/external-secrets` |
| Forgejo (Git server, Forgejo Actions) + Forgejo Runner | Forgejo 15.0.10 (chart `forgejo-helm/forgejo` 17.3.1), runner 13.2.0 | Argo CD, `apps/forgejo` |
| `platform/*`, `apps/*` | — | Argo CD, from Git |

Versions are pinned in [`versions.env`](versions.env), and for platform components in their `Chart.yaml` / `values.yaml`.

## Documentation

| Doc | Read it when you want to… |
|---|---|
| [docs/architecture.md](docs/architecture.md) | understand the components, traffic flow, ports, namespaces and where state lives |
| [docs/bootstrap.md](docs/bootstrap.md) | know exactly what `bootstrap.sh` does, step by step |
| [docs/configuration.md](docs/configuration.md) | change settings: `.env`, `versions.env`, k3s config, Helm values, cluster values |
| [docs/gitops.md](docs/gitops.md) | understand the Argo CD setup, check deploy status, force or pause deploys |
| [docs/adding-an-app.md](docs/adding-an-app.md) | deploy something new |
| [docs/apps.md](docs/apps.md) | see what's deployed |
| [docs/secrets.md](docs/secrets.md) | set up Vault (auto-unseal), give an app or a build a secret |
| [docs/forgejo.md](docs/forgejo.md) | set up Forgejo and its runner, write GitHub-style workflows for Forgejo Actions |
| [docs/tls-and-ingress.md](docs/tls-and-ingress.md) | debug certificates or hostnames |
| [docs/secret-scanning.md](docs/secret-scanning.md) | understand the gitleaks hook and what's not allowed in this public repo |
| [docs/operations.md](docs/operations.md) | upgrade, back up, restore, change IP, troubleshoot, harden |
| [docs/current-cluster.md](docs/current-cluster.md) | see the latest snapshot of the live cluster |
| [AGENTS.md](AGENTS.md) | read the rules for AI agents (and humans) changing this repo |

## Repository layout

```
bootstrap.sh              installs/converges the whole cluster (run as root on the server)
versions.env              pinned versions
.env.example              template for the private .env (git-ignored)
k3s/config.yaml           -> /etc/rancher/k3s/config.yaml
helm/cert-manager/        cert-manager values
helm/argo-cd/             Argo CD values (UI hostname comes from .env)
argocd/                   ApplicationSet homelab: one Argo CD Application per platform/ and apps/ folder
platform/                 shared components deployed by Argo CD (ClusterIssuers, Vault, External Secrets)
apps/                     one Helm chart per app, deployed by Argo CD
tools/check.sh            repo self-check (run before every commit)
tools/export-cluster.sh   snapshot a live cluster
tools/vault-init.sh       one-time Vault init + auto-unseal key Secret - run on the server
tools/vault-configure.sh  configure Vault (KV, Kubernetes auth, External Secrets role) - run on the server
tools/vault-lib.sh        helpers shared by the two Vault scripts (sourced)
tools/setup-git-hooks.sh  enable the gitleaks pre-commit hook
.githooks/ .gitleaks.toml .github/workflows/   secret scanning
.gitattributes            LF line endings on every OS (files are copied to the server as they are)
docs/                     documentation
.secrets/                 git-ignored: keys, exports
```
