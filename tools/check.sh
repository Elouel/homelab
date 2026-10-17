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
FILES=$(git ls-files -co --exclude-standard 2>/dev/null)
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
if command -v helm >/dev/null 2>&1; then
  for c in $(echo "$FILES" | grep -E '(^|/)Chart\.yaml$' | xargs -n1 dirname); do
    helm template check "$c" --set domain=example.org --set serverIP=192.0.2.10 >/dev/null 2>&1 && ok "$c" || bad "$c (run: helm template x $c)"
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

echo "7. every apps/ and platform/ folder is documented in docs/apps.md (apps/ folders must be Helm charts)"
for dir in $(echo "$FILES" | grep -E '^(apps|platform)/[^/]+/' | cut -d/ -f1-2 | sort -u); do
  grep -qF "\`$dir\`" docs/apps.md && ok "$dir" || bad "$dir missing from docs/apps.md"
  case "$dir" in apps/*) [ -f "$dir/Chart.yaml" ] || bad "$dir has no Chart.yaml (the apps ApplicationSet deploys Helm charts)";; esac
done

echo "8. Mermaid blocks start with a known diagram type"
for f in $(echo "$FILES" | grep -E '\.md$'); do
  awk -v F="$f" 'p==1{ if ($0 !~ /^(flowchart|graph|sequenceDiagram|classDiagram|stateDiagram|erDiagram|gantt|pie|journey|gitGraph|mindmap|timeline)/) {print "  FAIL " F ": mermaid block starts with: " $0; e=1}; p=0 }
                 /^```mermaid/{p=1} END{exit e}' "$f" || FAIL=1
done
[ $FAIL = 0 ] && ok "mermaid"

echo
[ $FAIL = 0 ] && echo "All checks passed." || { echo "Checks FAILED."; exit 1; }
