#!/usr/bin/env bash
# Shared by tools/vault-init.sh and tools/vault-configure.sh: sourced, not run on its own.
# VAULT_NAMESPACE / VAULT_POD override where the Vault server runs (defaults: vault / vault-0).

NS=${VAULT_NAMESPACE:-vault}
POD=${VAULT_POD:-vault-0}

# v <args>: run the vault CLI in the server container
v(){ kubectl -n "$NS" exec "$POD" -c vault -- vault "$@"; }

# vault_wait <seconds> <regex>: poll 'vault status' every 5 s until a line of its output matches <regex>.
# Leaves the last output in $VAULT_STATUS (empty if Vault did not answer). Returns 1 on timeout.
vault_wait(){
  local end=$((SECONDS + $1))
  while :; do
    VAULT_STATUS=$(v status 2>/dev/null || true)   # exits 2 while sealed; keep the output anyway
    printf '%s\n' "$VAULT_STATUS" | grep -q "$2" && return 0
    [ "$SECONDS" -lt "$end" ] || return 1
    sleep 5
  done
}
