#!/usr/bin/env bash
# Configure Vault for this cluster (idempotent - safe to re-run).
#   Runs on the server as root. tools/vault-init.sh calls it on first setup; re-run it after changing it:
#     ./tools/vault-configure.sh
# Asks for a Vault token with admin rights (or takes it from $VAULT_TOKEN). The token is sent to the
# Vault pod over stdin only: it is not stored, logged, or put on a command line.
#
# Creates:
#   - KV v2 secrets engine at kv/          (app secrets live under kv/apps/<namespace>/...)
#   - Kubernetes auth method at kubernetes/
#   - policy + role "external-secrets"     (for ServiceAccount "default" in any namespace, token audience "vault";
#                                           read-only on kv/apps/<that namespace>/* - templated policy)
# Must match platform/external-secrets/values.yaml (vaultStore: role, audience, serviceAccount).
set -euo pipefail
. "$(dirname "$0")/vault-lib.sh"

# Wait until Vault is unsealed and active. The pod may still be starting (e.g. right after 'kubectl delete pod'),
# the unsealer sidecar can take up to a minute to see a newly created Secret, and after unsealing the single Raft
# node is a standby for a few seconds until it elects itself leader (API calls fail until "HA Mode active").
echo "Waiting for Vault in $NS/$POD to be unsealed and active (up to 5 min) ..."
if ! vault_wait 300 '^HA Mode *active'; then
  st=$VAULT_STATUS
  if [ -z "$st" ]; then echo "Vault does not answer - check: kubectl -n $NS get pods" >&2
  elif printf '%s\n' "$st" | grep -q '^Initialized *false'; then echo "Vault is not initialised. Run tools/vault-init.sh first (docs/secrets.md)." >&2
  elif printf '%s\n' "$st" | grep -q '^Sealed *true'; then echo "Vault is still sealed - check: kubectl -n $NS logs $POD -c unsealer (Secret $NS/vault-unseal-keys, docs/secrets.md)" >&2
  else echo "Vault is unsealed but not active - check: kubectl -n $NS logs $POD -c vault" >&2; fi
  exit 1
fi

if [ -z "${VAULT_TOKEN:-}" ]; then read -rsp "Vault admin token: " VAULT_TOKEN; echo; fi
# Drop whitespace (e.g. a CR or newline from the clipboard). The token goes into the pod's shell script below,
# so allow only the characters Vault tokens use (hvs.<base62>, ...).
VAULT_TOKEN=$(printf '%s' "$VAULT_TOKEN" | tr -d '[:space:]')
case $VAULT_TOKEN in
  '' | *[!A-Za-z0-9._-]*) echo "The token is empty or has characters a Vault token can't have." >&2; exit 1 ;;
esac

{
  printf "export VAULT_TOKEN='%s'\n" "$VAULT_TOKEN"
  cat <<'INPOD'
set -eu
vault token lookup >/dev/null

if vault secrets list | grep -q '^kv/'; then echo "kv/ already enabled"
else vault secrets enable -path=kv -version=2 kv; fi

if vault auth list | grep -q '^kubernetes/'; then echo "kubernetes/ auth already enabled"
else vault auth enable kubernetes; fi

# Vault runs in the cluster: it uses its own ServiceAccount token and CA to call TokenReview.
vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443

ESO=external-secrets   # name of the policy and of the role

# The ClusterSecretStore logs in as ServiceAccount "default" of the ExternalSecret's namespace. The policy is
# templated on that namespace, so an ExternalSecret in namespace myapp can read kv/apps/myapp/* and nothing else.
ACC=$(vault auth list | awk '$1 == "kubernetes/" {print $3}')   # columns: Path Type Accessor ...
case $ACC in auth_kubernetes_*) ;; *) echo "could not read the accessor of auth/kubernetes (got '$ACC')" >&2; exit 1 ;; esac
NSV="{{identity.entity.aliases.$ACC.metadata.service_account_namespace}}"
vault policy write "$ESO" - <<EOF
# External Secrets Operator: read the secrets of the caller's own namespace only
path "kv/data/apps/$NSV/*"     { capabilities = ["read"] }
path "kv/metadata/apps/$NSV/*" { capabilities = ["read", "list"] }
EOF

vault write "auth/kubernetes/role/$ESO" \
  bound_service_account_names=default \
  bound_service_account_namespaces='*' \
  audience=vault \
  token_policies="$ESO" \
  token_ttl=1h token_max_ttl=4h

echo "Vault configured."
INPOD
} | kubectl -n "$NS" exec -i "$POD" -c vault -- sh -s
