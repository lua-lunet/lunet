#!/usr/bin/env bash
set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: not inside a git worktree" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if [ ! -f ".githooks/pre-commit" ]; then
  echo "error: missing .githooks/pre-commit" >&2
  exit 1
fi

chmod +x ".githooks/pre-commit"
git config core.hooksPath .githooks

echo "Installed repo-managed hooks."
echo "core.hooksPath=$(git config --get core.hooksPath)"
