# AGENTS.md

Instructions for AI coding agents (Claude, Codex, Copilot, Cursor, …) and humans working on this repo.
Read this file completely before changing anything.

## What this repo is

Infrastructure-as-code for a single-node k3s cluster with cert-manager and Argo CD. One Argo CD
ApplicationSet (`argocd/homelab.yaml`) deploys every folder under `platform/` and `apps/` from this **public** GitHub repo. Start with
[README.md](README.md) and [docs/architecture.md](docs/architecture.md).

## Hard rules (never break these)

1. **No private data in committed files.** No server IP, no real domain or `*.sslip.io` hostname, no email,
   no passwords, tokens, keys, kubeconfigs or Secret values. Private values belong in `.env` (git-ignored).
   In docs and examples write `<SERVER_IP>`, `<BASE_DOMAIN>`, `<server>`. If an example needs an IP,
   use the documentation range `192.0.2.0/24`.
2. **Never commit `kind: Secret` with data.** Secret values live in Vault; charts get them through an
   `ExternalSecret` (see [docs/secrets.md](docs/secrets.md)). Document which Vault paths/keys must exist.
3. **Never read, print or copy the contents of `.env` or `.secrets/`** into files, commits, logs or chat.
   Use them only through `bootstrap.sh` / `tools/check.sh`.
4. **Cluster-specific values reach charts only via the cluster Secret `argocd/in-cluster`** (annotations
   `homelab/domain`, `homelab/server-ip`, written by `bootstrap.sh`, passed in by the `homelab` ApplicationSet).
   Templates use `{{ .Values.domain }}` / `{{ .Values.serverIP }}`. Never hard-code them.
5. **Pin every version**: component and chart versions in `versions.env`, chart dependency versions in
   `Chart.yaml`, image tags in values (no `latest`).
6. **Don't bypass the hooks** (`--no-verify`) and don't weaken `.gitleaks.toml` to get a commit through.
   Fix the content, or add a narrowly scoped `# gitleaks:allow` for a true false positive and say why.
7. **Argo CD is installed by `bootstrap.sh`, not by itself.** Don't put Argo CD (or cert-manager) under
   `platform/` or `apps/`; change `helm/argo-cd/values.yaml` / `versions.env` instead.
8. **No direct changes to the live cluster** as a substitute for Git. If something is applied by hand
   (e.g. a Secret), document it.

## How to make a change

1. Find where the change belongs (see the decision chart in [docs/operations.md](docs/operations.md#where-to-change-what)):
   - app / platform component → `apps/<name>/` or `platform/<name>/` (Argo CD, deploys on push)
   - versions → `versions.env` (needs `./bootstrap.sh` on the server)
   - k3s flags → `k3s/config.yaml` (needs `./bootstrap.sh` + `systemctl restart k3s`)
   - Argo CD / cert-manager values → `helm/*/values.yaml` (needs `./bootstrap.sh`)
   - how folders become Argo CD Applications → `argocd/*.yaml` (needs `./bootstrap.sh`)
   - new private setting → `.env.example` + `bootstrap.sh` (+ cluster Secret annotation and
     a `valuesObject` line in `argocd/homelab.yaml` if charts need it)
   - Vault configuration (auth methods, policies, roles) → `tools/vault-configure.sh` (user runs it on the server;
     first setup is `tools/vault-init.sh`)
2. Follow the existing patterns. New apps copy `apps/whoami` (a Helm chart; folder name = namespace = release).
   `platform/` folders are Helm charts too; upstream charts are wrapped as a dependency (see `platform/vault`).
3. **Update the docs in the same change** (see the matrix below). A change without matching docs is incomplete.
4. Run `sh tools/check.sh` and fix every `FAIL`.
5. Tell the user which steps they still have to run on the server, if any (e.g. copy the files and run `./bootstrap.sh`, see `docs/bootstrap.md`). The repo is not cloned on the server.

## Documentation update matrix

| If you change… | Update… |
|---|---|
| add / rename / remove `apps/<name>` or `platform/<name>` | `docs/apps.md` (table row + short section). `tools/check.sh` enforces the row |
| app hostname, namespace, required secrets or storage | that app's row and section in `docs/apps.md` |
| `bootstrap.sh` (any step) | `docs/bootstrap.md` (sequence diagram + step table). Also `docs/configuration.md` if inputs changed |
| `.env.example` (new/renamed/removed variable) | `docs/configuration.md` `.env` table. Also `docs/bootstrap.md` if bootstrap uses it |
| cluster values (annotations on `argocd/in-cluster`, `valuesObject` in `argocd/homelab.yaml`) | `docs/configuration.md` (cluster values section) and `docs/adding-an-app.md` |
| `versions.env` | `README.md` "What gets installed" table. Also `docs/operations.md` if the upgrade needs special steps |
| `k3s/config.yaml` | `docs/configuration.md` k3s table. Also `docs/architecture.md` if ports or state paths change |
| `helm/*/values.yaml` | `docs/configuration.md` Helm values table |
| `argocd/*.yaml` or Argo CD conventions | `docs/gitops.md` |
| ClusterIssuers, Traefik, ingress or TLS behaviour | `docs/tls-and-ingress.md`, `docs/apps.md` platform table |
| `platform/vault`, `platform/external-secrets`, `tools/vault-*.sh`, Vault paths/policies, unseal | `docs/secrets.md` |
| `.gitleaks.toml`, `.githooks/`, CI workflow | `docs/secret-scanning.md` rules table |
| `tools/*.sh` | the doc that describes the tool (`docs/operations.md`, `docs/secret-scanning.md`) and the layout in `README.md` |
| new top-level folder or file | `README.md` repository layout |
| new doc file | `README.md` documentation table and `docs/README.md` index |
| a fresh export from `tools/export-cluster.sh` | `docs/current-cluster.md` |
| any component, flow or namespace added/removed | the Mermaid diagrams in `docs/architecture.md` (and `README.md` overview) |

## Documentation style

- Markdown. Diagrams in fenced ```` ```mermaid ```` blocks (`flowchart`, `sequenceDiagram`) so GitHub renders them.
- Mermaid labels: wrap them in double quotes. Don't use `<`/`>` inside labels (write `BASE_DOMAIN`, not `<BASE_DOMAIN>`).
  Keep diagrams small: one idea per diagram.
- Prefer tables for reference data (variables, ports, namespaces, states) and short numbered steps for procedures.
- Every command must be copy-pasteable and say where it runs (PC/PowerShell vs server/root).
- Link between docs with relative links. `tools/check.sh` verifies they resolve.
- Describe what *is*, not history. Put snapshots of the live cluster only in `docs/current-cluster.md`.
- If you are unsure whether something is true (tool behaviour, version compatibility), say so in the doc
  or verify it. Don't invent flags or fields.

## Verification

```bash
sh tools/check.sh
```

It checks shell syntax, YAML, Helm rendering (if `helm` is installed), that no `.env` value leaks
into committable files, gitleaks (if installed), Markdown links, that every `apps/`/`platform/` folder is
listed in `docs/apps.md` (and is a Helm chart), that Mermaid blocks are well-formed,
that the rendered Vault server and unsealer images have the same tag, that the External Secrets image tags match its chart
version, that the Prometheus Operator CRDs chart and kube-prometheus-stack ship the same operator version, and that no
rendered image is untagged or `latest`. All checks must pass before you commit. Wrapper chart dependencies are downloaded
only when missing. If the download fails, the render check shows `skip` when the chart repository is unreachable
(offline) and `FAIL` when it is reachable (wrong name or version in `Chart.yaml`).

## Environment notes for agents

- The user's PC is Windows (`D:\Projects\HomeLab`). Give PowerShell commands for the PC side and bash for the server.
- Agents may not have SSH access to the server. Prepare the change and hand the user the exact commands to run.
- The cluster has a single node with 8 GB RAM. Always set resource requests (and memory limits).

## Commits

- Small, focused commits with a descriptive subject, e.g. `apps: add uptime-kuma`, `docs: explain cluster values`.
- Code and docs go in the same commit.
