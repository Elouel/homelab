# App catalogue

Everything Argo CD deploys from this repo. **Keep this table current** whenever you add, rename or remove a folder
under `platform/` or `apps/`.

| Folder | Argo CD Application | Namespace | Kind | URL | Secrets needed (create by hand) | Persistent data |
|---|---|---|---|---|---|---|
| `platform/cluster-issuer` | `platform-cluster-issuer` | (cluster-scoped) | manifests | — | none | none |
| `apps/whoami` | `whoami` | `whoami` | local chart | `https://whoami.<BASE_DOMAIN>` | none | none |

Installed by `bootstrap.sh` rather than from these folders: cert-manager, and Argo CD itself at
`https://argocd.<BASE_DOMAIN>` (see [bootstrap.md](bootstrap.md)).

## Platform components

| Component | Purpose |
|---|---|
| `ClusterIssuer letsencrypt-prod` | Trusted Let's Encrypt certificates for app Ingresses and the Argo CD UI |
| `ClusterIssuer letsencrypt-staging` | Untrusted test certificates with high rate limits, for trying out new apps |

## Apps

### whoami

Tiny HTTP server that echoes request details. It shows that DNS, Traefik, TLS and Argo CD all work end to end.
Image `traefik/whoami`. Uses the reference layout described in [adding-an-app.md](adding-an-app.md).
