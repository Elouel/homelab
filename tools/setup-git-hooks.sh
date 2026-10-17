#!/bin/sh
# One-time setup per clone: turn on the repo's tracked git hooks (secret scanning).
# Run from Git Bash / any shell inside the repo:  sh tools/setup-git-hooks.sh
set -e
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
git update-index --chmod=+x .githooks/pre-commit 2>/dev/null || true
if command -v gitleaks >/dev/null 2>&1 || command -v gitleaks.exe >/dev/null 2>&1; then
  echo "Hooks enabled. gitleaks $(gitleaks version) will scan every commit."
else
  echo "Hooks enabled, but gitleaks is missing - commits will be blocked until you install it:"
  echo "  Windows: winget install Gitleaks.Gitleaks    macOS: brew install gitleaks"
fi
