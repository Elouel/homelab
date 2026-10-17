#!/usr/bin/env bash
# One-time Vault setup on a new cluster (safe to re-run: does nothing if Vault is already initialised).
#   Runs on the server as root, after Argo CD has synced platform-vault:
#     ./tools/vault-init.sh
# 1. vault operator init with ONE unseal key (all keys would sit in the same Secret anyway)
# 2. stores the key in Secret vault/vault-unseal-keys -> the unsealer sidecar unseals Vault on every start
# 3. runs tools/vault-configure.sh with the root token (it waits until the sidecar has unsealed Vault)
# Prints the unseal key and root token ONCE: put both in your password manager. The unseal key is also kept in
# that Secret (k3s datastore on the server's disk, encrypted at rest); the root token is not stored anywhere.
# During init both sit in a file inside the pod until they have been printed (see INIT_FILE below).
set -euo pipefail
. "$(dirname "$0")/vault-lib.sh"

NAME=vault-unseal-keys
# 'operator init' writes its output here (emptyDir "home" of the pod, mode 0600) before it is read back, so a dropped
# kubectl connection can't lose the key and token. Deleted once printed; gone anyway when the pod is deleted.
INIT_FILE=/home/vault/vault-init.json
in_pod(){ kubectl -n "$NS" exec "$POD" -c vault -- "$@"; }
recover_hint(){
  echo "The init output is in the pod. Save the unseal key and root token from it, then delete it:" >&2
  echo "  kubectl -n $NS exec $POD -c vault -- cat $INIT_FILE" >&2
  echo "  kubectl -n $NS exec $POD -c vault -- rm -f $INIT_FILE" >&2
  echo "Then create Secret $NS/$NAME from the key (docs/secrets.md, 'Restarts: auto-unseal'), run" >&2
  echo "  kubectl -n $NS delete pod $POD && ./tools/vault-configure.sh" >&2
}

echo "Waiting for the Vault server in $NS/$POD to answer (up to 10 min) ..."
vault_wait 600 '^Sealed ' || { echo "Vault does not answer - check: kubectl -n $NS get pods" >&2; exit 1; }

if printf '%s\n' "$VAULT_STATUS" | grep -q '^Initialized *true'; then
  echo "Vault is already initialised - nothing to do."
  echo "(Sealed? Check that Secret $NS/$NAME exists: kubectl -n $NS logs $POD -c unsealer)"
  if in_pod test -s "$INIT_FILE" 2>/dev/null; then echo "An earlier run was interrupted." >&2; recover_hint; fi
  exit 0
fi

# Nothing that can fail may run between 'operator init' and printing the key and token: check the tools first,
# keep the output in the pod until it is printed, fall back to the raw output if parsing fails, create the Secret last.
command -v python3 >/dev/null || { echo "python3 is needed to read the init output - install it first" >&2; exit 1; }

rc=0
INIT_JSON=$(in_pod sh -c 'umask 077 && vault operator init -key-shares=1 -key-threshold=1 -format=json >"$1" && cat "$1"' \
  sh "$INIT_FILE") || rc=$?
if [ "$rc" != 0 ]; then
  echo "vault operator init failed, or the connection to the pod dropped (exit code $rc)." >&2
  echo "If 'kubectl -n $NS exec $POD -c vault -- vault status' now shows 'Initialized true':" >&2
  recover_hint
  exit 1
fi
if ! UNSEAL_KEY=$(printf '%s' "$INIT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["unseal_keys_b64"][0])') \
   || ! ROOT_TOKEN=$(printf '%s' "$INIT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["root_token"])'); then
  echo "Could not parse the init output. Save unseal_keys_b64[0] and root_token from it NOW:" >&2
  printf '%s\n' "$INIT_JSON" >&2
  recover_hint
  exit 1
fi
unset INIT_JSON

cat <<EOF

==================================================================
 Vault initialised. Save BOTH values in your password manager NOW.
 They are shown only this once.

   Unseal key : $UNSEAL_KEY
   Root token : $ROOT_TOKEN
==================================================================

EOF

in_pod rm -f "$INIT_FILE" \
  || echo "Could not delete $INIT_FILE in the pod - delete it: kubectl -n $NS exec $POD -c vault -- rm -f $INIT_FILE" >&2

# Vault was uninitialised, so a Secret left over from an earlier Vault (wiped PV) holds a useless key: replace it.
if ! { kubectl -n "$NS" delete secret "$NAME" --ignore-not-found >/dev/null \
       && printf '%s' "$UNSEAL_KEY" | kubectl -n "$NS" create secret generic "$NAME" --from-file=key1=/dev/stdin \
       && kubectl -n "$NS" label secret "$NAME" app.kubernetes.io/part-of=vault homelab/created-by=vault-init.sh >/dev/null; }; then
  echo "Could not create Secret $NS/$NAME. Create it from the key above (docs/secrets.md, 'Restarts: auto-unseal')," >&2
  echo "then run: kubectl -n $NS delete pod $POD && ./tools/vault-configure.sh" >&2
  exit 1
fi
unset UNSEAL_KEY

# vault-configure.sh waits for the unsealer sidecar to unseal Vault, then configures it.
VAULT_TOKEN="$ROOT_TOKEN" "$(dirname "$0")/vault-configure.sh"
