# Forgejo and Forgejo Actions

`apps/forgejo` runs **Forgejo** (Git server) at `https://git.<BASE_DOMAIN>` with **Forgejo Actions** enabled, and one
**Forgejo Runner** that runs the jobs in containers through Docker-in-Docker. Workflows are written like GitHub Actions
workflows, and `uses: actions/checkout@v4` is fetched from GitHub, so most GitHub workflows run with small changes
(see [Differences from GitHub Actions](#differences-from-github-actions)).

```mermaid
flowchart LR
  YOU["You: git push"] --> F["Forgejo - deploy forgejo, ns forgejo"]
  R["runner container - deploy forgejo-runner"] -->|"poll for jobs - in-cluster HTTP"| F
  R -->|"docker API - localhost:2376"| D["dind container - same pod"]
  D --> J["job container - image from the runs-on label"]
  J -->|"clone repo - https://git.BASE_DOMAIN"| F
  R -->|"fetch actions - uses: owner/repo@ref"| GH["github.com"]
```

| Part | Where | What it does |
|---|---|---|
| Forgejo | `apps/forgejo` (wrapper of chart `forgejo-helm/forgejo`), Deployment `forgejo` | Web UI, API, Git over HTTPS, Actions. SQLite DB and repositories on PVC `forgejo-data` (10 Gi) |
| `register-runner` sidecar | container in the `forgejo` pod | Registers runner `homelab` with the shared secret on every start (`forgejo forgejo-cli actions register`, idempotent) |
| Forgejo Runner | Deployment `forgejo-runner`: containers `runner` + `dind` (`templates/runner.yaml`) | Polls Forgejo, starts each job in a container on the Docker-in-Docker daemon |
| Secrets | Vault `kv/apps/forgejo/admin`, `kv/apps/forgejo/runner` → Secrets `forgejo-admin`, `forgejo-runner-token` | First admin account, shared runner secret ([secrets.md](secrets.md)) |
| Settings | `apps/forgejo/values.yaml` | Forgejo `app.ini` values (`forgejo.gitea.config`), runner labels and images (`runner`) |

## First-time setup

1. **Write the two secrets to Vault.** On the server (root), in the Vault pod (`=-` reads the value from stdin, so it
   stays out of history; the runner secret is generated in the pod and never shown):
   ```bash
   kubectl -n vault exec -it vault-0 -c vault -- sh
   vault login                                    # paste your token
   vault kv put kv/apps/forgejo/admin username=forgejo-admin password=-   # paste a password, then Ctrl-D
   head -c 20 /dev/urandom | od -An -tx1 | tr -d ' \n' | vault kv put kv/apps/forgejo/runner token=-
   rm ~/.vault-token && exit
   ```
   | Vault path | Keys | Notes |
   |---|---|---|
   | `kv/apps/forgejo/admin` | `username`, `password` | First admin account. Not `admin` (a reserved name in Forgejo). Every Forgejo start sets the password to this value (chart setting `passwordMode` is `keepUpdated`); put the password in your password manager |
   | `kv/apps/forgejo/runner` | `token` | Exactly 40 lowercase hex characters. Forgejo and the runner both read it ([offline registration](https://forgejo.org/docs/latest/admin/actions/registration/#offline-registration)) |
2. **Let Argo CD deploy it** (the folder is in Git). Until both secrets exist, the pods wait in
   `CreateContainerConfigError` / `ContainerCreating` and start on their own afterwards. Check (server, root):
   ```bash
   kubectl -n forgejo get externalsecret                        # both SecretSynced, READY True
   kubectl -n forgejo get pods                                  # forgejo 2/2, forgejo-runner 2/2
   kubectl -n forgejo logs deploy/forgejo -c register-runner    # "runner homelab registered"
   kubectl -n forgejo logs deploy/forgejo-runner -c runner      # "... declared successfully"
   ```
3. **Sign in** at `https://git.<BASE_DOMAIN>` with the admin account. Change its e-mail address under
   **Settings → Account** (the chart sets the placeholder `gitea@local.domain`). **Site administration → Actions →
   Runners** shows `homelab` as online with the labels below. Self-registration is off: create accounts under
   **Site administration → User accounts**.

Clone and push over HTTPS (`https://git.<BASE_DOMAIN>/<owner>/<repo>.git`, password or an access token). SSH is
disabled: port 22 on the host is the server's own SSH.

## Writing workflows

Forgejo reads workflows (`*.yaml`, `*.yml`) from `.forgejo/workflows/`. If a repository has no `.forgejo/workflows` folder,
it reads `.github/workflows` instead, so a repository moved from GitHub (**+ → New migration → GitHub**) keeps its
workflows.

`runs-on` picks the image the job runs in (set in `runner.labels` in `apps/forgejo/values.yaml`):

| `runs-on` | Job image | Use for |
|---|---|---|
| `docker` | `node:24.22.0-bookworm` (Debian, Node.js, git) | small jobs; the Forgejo default environment |
| `ubuntu-latest`, `ubuntu-24.04` | `ghcr.io/catthehacker/ubuntu:act-24.04-20260815` | workflows written for GitHub: Ubuntu with many of the tools GitHub's runners have, including the `docker` CLI. Large image: the first job after a runner restart spends a minute or more pulling it |

`uses: owner/repo@ref` without a host is fetched from `https://github.com` (`DEFAULT_ACTIONS_URL`), as on GitHub.
A full URL picks another host, e.g. `uses: https://code.forgejo.org/actions/checkout@v4`.

```yaml
# .forgejo/workflows/build.yaml (or .github/workflows/build.yaml)
on:
  push:
    branches: [main]
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 24
      - run: npm ci && npm test
      - run: docker build -t myapp:${{ github.sha }} .   # the Docker-in-Docker daemon of the runner pod
```

Every job can use Docker: `DOCKER_HOST`, `DOCKER_TLS_VERIFY` and `DOCKER_CERT_PATH` point at the `dind` container,
so `docker build`, `docker run` and Docker-based actions work. Images pulled or built there are cached until the
runner pod restarts.

Secrets for workflows: **Repository → Settings → Actions → Secrets**, used as `${{ secrets.NAME }}`. Reading build
secrets from Vault with an OIDC token is planned, see [secrets.md](secrets.md#builds-forgejo-actions).

### Differences from GitHub Actions

Forgejo Actions aims to be *familiar*, not *compatible*
([Forgejo docs](https://forgejo.org/docs/latest/user/actions/github-actions/)). Known differences:

- The default environment is different. `runs-on: docker` is a Debian image with Node.js; `ubuntu-*` here is a
  community image (`catthehacker/ubuntu`) that is close to, but not the same as, GitHub's runner image.
- Some keys of the `github` context are missing.
- Some job keys are ignored, e.g. `permissions` and `continue-on-error`.
- OIDC ID tokens are enabled with `enable-openid-connect: true` in the workflow, not `permissions: id-token: write`.
- Actions that call the GitHub REST or GraphQL API (create a release, comment on a pull request, the `gh` CLI)
  generally don't work: Forgejo's API is different. Look for a Forgejo equivalent under `https://code.forgejo.org/actions`.

## How the runner is wired

```mermaid
sequenceDiagram
  participant S as register-runner sidecar
  participant F as Forgejo
  participant R as runner container
  participant D as dind container
  S->>F: forgejo-cli actions register --secret-file (name homelab)
  R->>R: UUID from the first 16 characters of the secret
  R->>D: wait until localhost:2376 answers
  R->>F: connect with UUID + secret, declare labels
  loop every 2 s
    R->>F: fetch a job
  end
  F-->>R: job for runs-on ubuntu-latest
  R->>D: pull image, start job container (network host)
  D-->>F: job clones https://git.BASE_DOMAIN/owner/repo
```

- **Registration** needs no clicks in the UI. Both sides read the same 40-character secret from Secret
  `forgejo-runner-token`: Forgejo stores it for runner `homelab` (the UUID is the first 16 characters as bytes,
  the whole secret is the token), and the runner computes the same UUID at start and reads the token from the
  mounted file `/run/runner/token` (`token_url` in its config). Nothing secret is in the runner's ConfigMap.
- **The runner reaches Forgejo inside the cluster** (`http://forgejo-http.forgejo.svc:3000/`). **Jobs** get
  `https://git.<BASE_DOMAIN>` (Forgejo's `ROOT_URL`) and clone from there, so the server must reach its own public
  hostname (see [troubleshooting](#troubleshooting)).
- **Jobs share the pod's network** (`container.network: host`): they reach the Docker daemon on `localhost:2376`, the
  runner's cache server (`actions/cache`), and cluster DNS names like any pod.
- **One job at a time** (`runner.capacity: 1`). `dind` has a 3 Gi memory limit that covers all job containers, and
  its image cache is an `emptyDir` of at most `runner.dockerStorage` (20 Gi). Past that the pod is evicted and starts
  again with an empty cache.
- Runner pods are replaced on every change to the runner config (checksum annotation). Running jobs are cancelled.

To add a label (another job image), add a `name:docker://image:tag` line to `runner.labels` and push.

## Security

- **`dind` is a privileged container.** A privileged container can take over the node. Anyone who can push a
  workflow to any repository on this Forgejo, or open a pull request whose workflow runs, can run code with that
  power. Keep registration closed, give write access only to people you would give root on the server, and don't
  mirror untrusted repositories with Actions enabled.
- Jobs can reach every Service in the cluster (Vault included), like any pod. Vault still needs a token.
- Forgejo is on the internet at `https://git.<BASE_DOMAIN>`, reachable from the IPs the provider firewall allows
  (see [architecture.md](architecture.md#network-ports-on-the-host)).

**Rotating the runner secret:** write a new value to `kv/apps/forgejo/runner` that keeps the **first 16 characters**
and changes the last 24 (the first 16 identify the runner). Then, on the server (root):

```bash
kubectl -n forgejo annotate externalsecret forgejo-runner-token force-sync=$(date +%s) --overwrite   # re-read Vault now
kubectl -n forgejo rollout restart deploy/forgejo deploy/forgejo-runner
```

A value with new first 16 characters registers a second runner; delete the old, offline one in **Site
administration → Actions → Runners**.

## Backup and upgrade

All Forgejo data (repositories, SQLite DB, attachments, Actions logs) is on PVC `forgejo-data`. It has
`argocd.argoproj.io/sync-options: Delete=false`, so deleting the Application keeps it. Back it up like other app data
([operations.md](operations.md#backups)), with Forgejo scaled to 0 (server, root):

```bash
kubectl -n forgejo scale deploy/forgejo --replicas=0
tar -czf /root/forgejo-$(date +%F).tgz -C /var/lib/rancher/k3s/storage "$(kubectl -n forgejo get pvc forgejo-data -o jsonpath='{.spec.volumeName}')_forgejo_forgejo-data"
kubectl -n forgejo scale deploy/forgejo --replicas=1
```

Upgrades: bump the dependency `version` in `apps/forgejo/Chart.yaml`, `forgejo.image.tag` **and** the
`register-runner` image in `apps/forgejo/values.yaml` (`tools/check.sh` compares them), push. Read the Forgejo
release notes and the chart's changelog first and take a backup: Forgejo migrates the DB on start and can't be
downgraded. The runner and `dind` images are in `runner.image` / `runner.dindImage`.

## Troubleshooting

| Symptom | Check |
|---|---|
| Pods stay in `CreateContainerConfigError` / `ContainerCreating` | the Secrets don't exist yet: `kubectl -n forgejo get externalsecret`, then [first-time setup](#first-time-setup) step 1 |
| `runner: Secret forgejo-runner-token ... must be 40 lowercase hex characters` | fix the value in Vault (`kv/apps/forgejo/runner`, key `token`), then rotate as [above](#security) |
| Runner logs `unauthenticated` / runner offline in the UI | `kubectl -n forgejo logs deploy/forgejo -c register-runner`. After changing the secret, restart both Deployments (see [rotating](#security)) |
| Job waits for a runner forever | its `runs-on` matches no label in `runner.labels`, or the runner is busy (`capacity: 1`) |
| `actions/checkout` can't connect to `git.BASE_DOMAIN` | jobs clone through the public hostname. If the server's public IP is not on its network interface (NAT), traffic goes out to the provider firewall; allow the server's own IP there |
| `uses:` fails to clone `https://github.com/...` | wrong action name or tag, or no outbound internet from the pod |
| `forgejo-runner` pod `Evicted` | the `dind` cache grew past `runner.dockerStorage`; raise it or use smaller job images |
| `docker: Cannot connect to the Docker daemon` in a job | `kubectl -n forgejo logs deploy/forgejo-runner -c dind` |
| UI shows `http://git.example.com` links or a wrong domain | ConfigMap `forgejo-server` is read at pod start: `kubectl -n forgejo rollout restart deploy/forgejo` |
| No certificate / 404 | see [tls-and-ingress.md](tls-and-ingress.md#debugging-a-certificate) (Ingress `forgejo`, Secret `forgejo-tls`) |
