#!/usr/bin/env bash
set -euo pipefail
[[ -z $(git status --porcelain) ]] || { echo 'Working tree must be clean' >&2; exit 1; }
[[ $(git remote get-url upstream) == https://github.com/anymouschina/TapCanvas.git ]] || { echo 'Unexpected upstream' >&2; exit 1; }
git fetch upstream main
git fetch origin develop
branch="sync/upstream-$(date -u +%Y%m%dT%H%M%SZ)"
git switch -c "$branch" origin/develop
git merge --no-edit upstream/main
echo "Prepared $branch. Resolve failures, run checks, then push and open a PR to develop. Production was not changed."
