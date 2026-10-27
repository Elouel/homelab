# Documentation index

Suggested reading order:

1. [architecture.md](architecture.md): the big picture, request flow, ports, namespaces, state
2. [bootstrap.md](bootstrap.md): how the cluster is built
3. [configuration.md](configuration.md): every setting and where it lives
4. [gitops.md](gitops.md): how Git changes reach the cluster
5. [adding-an-app.md](adding-an-app.md): recipes for new apps
6. [apps.md](apps.md): what's currently deployed
7. [secrets.md](secrets.md): Vault + External Secrets for apps and builds
8. [monitoring.md](monitoring.md): Grafana, Prometheus, Loki, alerts to Telegram
9. [forgejo.md](forgejo.md): Forgejo, its runner, and GitHub-style workflows with Forgejo Actions
10. [tls-and-ingress.md](tls-and-ingress.md): certificates and routing
11. [secret-scanning.md](secret-scanning.md): keeping the public repo clean
12. [operations.md](operations.md): upgrades, backups, restore, troubleshooting, hardening
13. [current-cluster.md](current-cluster.md): latest snapshot of the live cluster

Diagrams are [Mermaid](https://mermaid.js.org/) and render on GitHub. Maintainers: see [../AGENTS.md](../AGENTS.md).
