#!/usr/bin/env bash
# Repo self-check: run before every commit (humans and AI agents).
#   sh tools/check.sh        (Git Bash on Windows, Linux, macOS)
# Exits non-zero on any failure. Optional tools (python3+PyYAML, helm, gitleaks) are used when present.
set -u
cd "$(git rev-parse --show-toplevel 2>/dev/null || dirname "$0"/..)"
FAIL=0
ok(){ printf '  ok   %s\n' "$*"; }
bad(){ printf '  FAIL %s\n' "$*"; FAIL=1; }
skip(){ printf '  skip %s\n' "$*"; }

# Files that would be committed: tracked + untracked-but-not-ignored
FILES=$(git ls-files -co --exclude-standard 2>/dev/null | while read -r f; do [ -e "$f" ] && echo "$f"; done)   # skip deleted files
PY=$(command -v python3 || command -v python || true)

echo "1. shell syntax"
for f in $(echo "$FILES" | grep -E '\.sh$|^\.githooks/'); do
  bash -n "$f" 2>/dev/null && ok "$f" || bad "$f"
done

echo "2. YAML syntax (Helm templates excluded)"
if [ -n "$PY" ] && "$PY" -c 'import yaml' 2>/dev/null; then
  for f in $(echo "$FILES" | grep -E '\.ya?ml$' | grep -v '/templates/'); do
    "$PY" -c 'import sys,yaml; list(yaml.safe_load_all(open(sys.argv[1])))' "$f" 2>/dev/null && ok "$f" || bad "$f"
  done
else skip "python3 with PyYAML not found"; fi

echo "3. Helm charts render"
# true if every dependency repository of chart $1 answers (http(s) only; no curl = unknown = false)
repos_reachable(){
  r=$(sed -n "s/^ *repository: *[\"']\{0,1\}\([^\"' #]*\).*/\1/p" "$1/Chart.yaml")
  [ -n "$r" ] && command -v curl >/dev/null 2>&1 || return 1
  for u in $r; do
    case $u in http*) curl -fsS -o /dev/null -r 0-0 --max-time 15 "${u%/}/index.yaml" 2>/dev/null || return 1;; *) return 1;; esac
  done
}
# Each render is kept in $RENDER for checks 9 to 11. --skip-tests: the charts' test pods are never deployed by
# Argo CD, and the Vault chart's test pod would add a third hashicorp/vault image to check 9.
RENDER=$(mktemp -d); trap 'rm -rf "$RENDER"' EXIT
# render_file <chart>: the file in $RENDER that holds the rendered manifests of <chart>
render_file(){ echo "$RENDER/$(echo "$1" | tr / _).yaml"; }
if command -v helm >/dev/null 2>&1; then
  for c in $(echo "$FILES" | grep -E '(^|/)Chart\.yaml$' | xargs -n1 dirname); do
    # wrapper charts (platform/vault, ...) need their dependencies in charts/ (git-ignored, like Chart.lock).
    # Download only if 'helm dependency list' reports one as missing or at the wrong version.
    if grep -q '^dependencies:' "$c/Chart.yaml" \
       && helm dependency list "$c" 2>/dev/null | awk 'NR>1 && NF && $NF!="ok"{m=1} END{exit !m}' \
       && ! helm dependency build "$c" >/dev/null 2>&1; then
      # offline is fine; a reachable repository that can't deliver the chart means a wrong name/version in Chart.yaml
      if repos_reachable "$c"; then bad "$c (dependency build failed although the repository is reachable - run: helm dependency build $c)"
      else skip "$c (dependency repository not reachable - offline? run: helm dependency build $c)"; fi
      continue
    fi
    out=$(render_file "$c")
    helm template check "$c" --skip-tests --set domain=example.org --set serverIP=192.0.2.10 >"$out" 2>/dev/null && ok "$c" \
      || { rm -f "$out"; bad "$c (run: helm template x $c)"; }
  done
else skip "helm not installed"; fi

echo "4. private values from .env do not appear in committable files"
if [ -f .env ]; then
  # every non-empty .env value except GIT_* (the repo URL/branch are public anyway)
  for var in $(grep -oE '^[A-Z_][A-Z0-9_]*=' .env | tr -d '=' | grep -v '^GIT_'); do
    val=$(grep -E "^${var}=" .env | head -1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]$//")
    [ -z "$val" ] && continue
    hits=$(echo "$FILES" | grep -v -E '^\.env$' | xargs grep -lF -- "$val" 2>/dev/null)
    [ -n "$hits" ] && bad "$var value found in: $(echo $hits)" || ok "$var"
  done
else skip ".env not present"; fi

echo "5. gitleaks on committable files"
GL=$(command -v gitleaks || command -v gitleaks.exe || true)
if [ -n "$GL" ]; then
  TMP=$(mktemp -d)
  echo "$FILES" | while read -r f; do [ -f "$f" ] && mkdir -p "$TMP/$(dirname "$f")" && cp "$f" "$TMP/$f"; done
  "$GL" dir --config .gitleaks.toml --redact --no-banner "$TMP" >/dev/null 2>&1 && ok "no findings" \
    || bad "gitleaks findings - run: gitleaks dir --config .gitleaks.toml --verbose <file>"
  rm -rf "$TMP"
else skip "gitleaks not installed"; fi

echo "6. relative links in Markdown resolve"
for f in $(echo "$FILES" | grep -E '\.md$'); do
  d=$(dirname "$f")
  for l in $(grep -oE '\]\([^)#: ]+(#[^)]*)?\)' "$f" | sed -E 's/^\]\(//; s/\)$//; s/#.*$//'); do
    [ -z "$l" ] && continue
    [ -e "$d/$l" ] || bad "$f -> $l"
  done
done
[ $FAIL = 0 ] && ok "links"

echo "7. every apps/ and platform/ folder is documented in docs/apps.md and is a Helm chart"
for dir in $(echo "$FILES" | grep -E '^(apps|platform)/[^/]+/' | cut -d/ -f1-2 | sort -u); do
  grep -qF "\`$dir\`" docs/apps.md && ok "$dir" || bad "$dir missing from docs/apps.md"
  [ -f "$dir/Chart.yaml" ] || bad "$dir has no Chart.yaml (the ApplicationSet deploys Helm charts)"
done

echo "8. Mermaid blocks start with a known diagram type"
for f in $(echo "$FILES" | grep -E '\.md$'); do
  awk -v F="$f" 'p==1{ if ($0 !~ /^(flowchart|graph|sequenceDiagram|classDiagram|stateDiagram|erDiagram|gantt|pie|journey|gitGraph|mindmap|timeline)/) {print "  FAIL " F ": mermaid block starts with: " $0; e=1}; p=0 }
                 /^```mermaid/{p=1} END{exit e}' "$f" || FAIL=1
done
[ $FAIL = 0 ] && ok "mermaid"

# Checks 9 to 11 compare the images in the charts rendered by check 3, so other tags in values.yaml don't matter.
# img_tags <chart> <repository>: the tag of every container image <any registry/>repository, one per line.
# Returns 1 if check 3 has no render of the chart (no helm, dependencies missing, or a render error).
img_tags(){ f=$(render_file "$1"); [ -s "$f" ] || return 1
  sed -n "s|^ *image: *[\"']\{0,1\}\([^ \"']*/\)\{0,1\}$2:\([^\"' ]*\).*|\2|p" "$f"; }
lines(){ printf '%s' "$1" | grep -c .; }

echo "9. Vault server image and unsealer sidecar image have the same tag"
# Exactly the server and the unsealer (tests are not rendered): one image means the unsealer is missing
# or not written as hashicorp/vault:<tag>.
if vt=$(img_tags platform/vault hashicorp/vault); then
  vu=$(printf '%s\n' "$vt" | sort -u)
  [ "$(lines "$vt")" -eq 2 ] && [ "$(lines "$vu")" -eq 1 ] && ok "hashicorp/vault $vu" \
    || bad "platform/vault/values.yaml: server.image.tag and the unsealer image must both be hashicorp/vault:<same tag> (rendered: $(echo $vt))"
else skip "platform/vault was not rendered (see check 3)"; fi

echo "10. External Secrets image tags match the chart version"
# The external-secrets chart version equals its appVersion, so the controller, webhook and cert-controller
# images must all be v<chart version>.
ec=$(awk '/^ *- name: external-secrets *$/{d=1; next} d && /^ *version:/{sub(/^ *version: *"?/, ""); sub(/["# ].*/, ""); print; exit}' \
       platform/external-secrets/Chart.yaml)
if et=$(img_tags platform/external-secrets external-secrets/external-secrets); then
  eu=$(printf '%s\n' "$et" | sort -u)
  [ -n "$ec" ] && [ "$(lines "$et")" -ge 3 ] && [ "$eu" = "v$ec" ] && ok "external-secrets $ec, images $eu" \
    || bad "platform/external-secrets/values.yaml: controller, webhook and certController image tags must all be v$ec (rendered: $(echo $eu))"
else skip "platform/external-secrets was not rendered (see check 3)"; fi

echo "11. Forgejo server image and register-runner sidecar image have the same tag"
# The chart's server and init containers use forgejo.image.tag; the sidecar names its image itself. All rendered
# forgejo/forgejo images must have one tag, and the register-runner container must exist and be one of them.
# container_image <file> <name>: the image of every rendered container (list item) called <name>, one per line.
container_image(){ awk -v N="$2" '
  function pop(){ if (nm[sp] == N) print im[sp]; sp-- }
  { match($0, /^ */); i = RLENGTH }
  $0 ~ /^ *- [A-Za-z_]+:/ { c = i + 2; while (sp > 0 && col[sp] >= c) pop(); sp++; col[sp] = c; nm[sp] = im[sp] = "" }
  $0 ~ /^ *[A-Za-z_]+:/   { c = i; while (sp > 0 && col[sp] > c) pop() }
  $0 !~ /^ *(- )?[A-Za-z_]+:/ { next }
  sp > 0 && col[sp] == c { k = substr($0, c + 1); v = k; sub(/^[A-Za-z_]+: */, "", v); gsub(/["'\'' ]/, "", v)
                           if (k ~ /^name:/) nm[sp] = v; if (k ~ /^image:/) im[sp] = v }
  END { while (sp > 0) pop() }' "$1"; }
if ft=$(img_tags apps/forgejo forgejo/forgejo); then
  fu=$(printf '%s\n' "$ft" | sort -u)
  ri=$(container_image "$(render_file apps/forgejo)" register-runner)
  [ "$(lines "$fu")" -eq 1 ] && [ "$(lines "$ri")" -eq 1 ] && [ "${ri##*forgejo/forgejo:}" = "$fu" ] \
    && ok "forgejo/forgejo $fu (server and register-runner)" \
    || bad "apps/forgejo/values.yaml: forgejo.image.tag and the register-runner image must be the same Forgejo version (rendered: $(echo $fu), register-runner: ${ri:-missing})"
else skip "apps/forgejo was not rendered (see check 3)"; fi

echo
[ $FAIL = 0 ] && echo "All checks passed." || { echo "Checks FAILED."; exit 1; }
