#!/usr/bin/env bash
# Releases the committed tree to the Fly app siwa-server, and nothing else.
#
#   scripts/deploy.sh
#
# It refuses a working tree with any change, a commit that is not on
# origin/main, and a commit that does not contain the one already live, so what
# runs is always what the repository holds and never takes live work out. The
# build context is `git archive` of the commit in a fresh release folder, so no
# local file outside git reaches the image. The image is labelled with the full
# commit (revision) and the elixir-utils commit mix.exs pins (elixir-utils).
#
# Fly's logs stream into the release folder from before the deploy until the
# checks after it are done. The checks: the live image names this commit,
# /readyz answers ready with every check true, and the served agent helpers and
# guide are byte for byte the files in git.
#
# The release folder, tmp/releases/<time>-<commit>/, is kept as the record:
# context/ (what was built), fly-deploy.txt, fly-logs.txt, readyz.json and
# checks.txt. Record the release in RELEASES.md afterwards.
set -euo pipefail

app="siwa-server"
host="siwa.regents.sh"
served_files=(agent/siwa_agent.py agent/siwa-agent.mjs agent/siwa-contract.json skill.md)

if [[ $# -ne 0 ]]; then
  echo "Usage: scripts/deploy.sh" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to deploy: commit or remove every change first." >&2
  exit 1
fi

git fetch --quiet origin main
commit="$(git rev-parse HEAD)"
if ! git merge-base --is-ancestor "$commit" origin/main; then
  echo "Refusing to deploy: ${commit:0:7} is not on origin/main. Push it to main first." >&2
  exit 1
fi

# The running image carries the commit it was built from in its revision label.
# A commit that does not contain it would take live work back out, which
# happens when two releases cross: bring this checkout up to origin/main and
# deploy again.
live="$(fly image show --app "$app" --json | jq -r '.[0].Labels | fromjson | .revision // empty')"
if [[ -z $live ]]; then
  echo "Refusing to deploy: the live image has no revision label to compare with." >&2
  exit 1
fi
if ! git merge-base --is-ancestor "$live" "$commit" 2>/dev/null; then
  echo "Refusing to deploy: ${commit:0:7} does not contain the live commit ${live:0:7}. Update to origin/main first." >&2
  exit 1
fi

elixir_utils="$(sed -n 's/^  @elixir_utils_ref "\([0-9a-f]\{40\}\)"$/\1/p' mix.exs)"
if [[ ${#elixir_utils} -ne 40 ]]; then
  echo "Refusing to deploy: mix.exs names no full elixir-utils commit in @elixir_utils_ref." >&2
  exit 1
fi

mkdir -p tmp/releases
release="$root/tmp/releases/$(date -u +%Y%m%dT%H%M%SZ)-${commit:0:7}"
mkdir "$release" "$release/context"
git archive "$commit" | tar -x -C "$release/context"

fly logs --app "$app" >"$release/fly-logs.txt" 2>&1 &
logs_pid=$!
trap 'kill "$logs_pid" 2>/dev/null || true' EXIT
sleep 3

echo "==> Deploying ${commit:0:7} (elixir-utils ${elixir_utils:0:7}) to $app; live is ${live:0:7}"
echo "==> Release folder: $release"
fly deploy "$release/context" \
  --config "$release/context/fly.toml" \
  --app "$app" \
  --remote-only \
  --label revision="$commit" \
  --label elixir-utils="$elixir_utils" 2>&1 | tee "$release/fly-deploy.txt"

failed=0
check() {
  echo "$1" | tee -a "$release/checks.txt"
}

served="$(fly image show --app "$app" --json | jq -r '.[0].Labels | fromjson | .revision // empty')"
if [[ $served == "$commit" ]]; then
  check "ok   live image revision $commit"
else
  check "FAIL live image revision is \"$served\", not $commit"
  failed=1
fi

ready=0
for _attempt in {1..12}; do
  if curl -fsS "https://$host/readyz" >"$release/readyz.json" 2>&1 &&
    jq -e '.ready == true and ([.checks[]] | all)' "$release/readyz.json" >/dev/null; then
    ready=1
    break
  fi
  sleep 5
done
if [[ $ready == 1 ]]; then
  check "ok   /readyz ready, every check true"
else
  check "FAIL /readyz not ready after a minute: $(cat "$release/readyz.json")"
  failed=1
fi

for file in "${served_files[@]}"; do
  expected="$(git show "$commit:priv/static/$file" | shasum -a 256 | cut -d' ' -f1)"
  actual="$(curl -fsS "https://$host/$file" | shasum -a 256 | cut -d' ' -f1)" || actual="unreachable"
  if [[ $expected == "$actual" ]]; then
    check "ok   /$file sha256 $expected"
  else
    check "FAIL /$file sha256 $actual, git has $expected"
    failed=1
  fi
done

sleep 5
if [[ $failed == 1 ]]; then
  echo "==> ${commit:0:7} is deployed but a check failed; read $release before anything else." >&2
  exit 1
fi
echo "==> ${commit:0:7} is live on $app and every check passed. Record it in RELEASES.md."
