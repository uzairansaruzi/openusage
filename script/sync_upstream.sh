#!/bin/sh
# Keeps this fork current: replays the fork's own commits on top of the latest upstream `main`
# (robinebers/openusage), runs the tests, pushes the result to the fork, and rebuilds and restarts
# the dev app. The dev app has its own bundle id and no update feed, so the installed OpenUsage is
# never touched and Sparkle never swaps this build for an upstream release.
#
# Usage: script/sync_upstream.sh [--no-test]
#
# On a rebase conflict it stops with the rebase in progress: fix the files, `git add` them,
# `git rebase --continue`, then run this again. `git rebase --abort` puts everything back.
set -eu
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain)" ]; then
  echo "sync_upstream: commit or stash your changes first." >&2
  exit 1
fi
if [ "$(git branch --show-current)" != "main" ]; then
  echo "sync_upstream: run this on main, which carries the fork's commits." >&2
  exit 1
fi

before=$(git rev-parse HEAD)
git fetch upstream
if git merge-base --is-ancestor upstream/main HEAD; then
  echo "sync_upstream: already on the latest upstream main."
else
  echo "==> fork commits being replayed onto upstream/main:"
  git log --oneline upstream/main..HEAD
  git rebase upstream/main || {
    echo "sync_upstream: rebase stopped on a conflict; see the header of this script." >&2
    exit 1
  }
fi

if [ "${1:-}" != "--no-test" ]; then
  script/test_quiet.sh || {
    echo "sync_upstream: tests failed after the sync. Nothing was pushed." >&2
    echo "  Undo the sync with: git reset --hard $before" >&2
    exit 1
  }
fi

git push --force-with-lease origin main
./script/build_and_run.sh verify
