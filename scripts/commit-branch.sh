#!/usr/bin/env bash
#
# Commit a working tree to a branch through GitHub's API, so the commit is
# signed.
#
#   commit-branch.sh <workdir> <branch> <message>
#
# A `git commit` in CI is unsigned unless a private key sits on the runner,
# which is not a trade worth making for a state branch. createCommitOnBranch
# builds the commit server-side and GitHub signs it, so the history is
# verifiable without a key ever leaving a person's machine. The author is
# whoever the token is -- github-actions[bot] under ${{ github.token }} --
# rather than an identity invented in a workflow file.
#
# The mutation takes explicit additions and deletions rather than a tree, so
# the diff is computed here. A missed deletion would leave a file on the branch
# forever, which is why the file set comes from git rather than a directory
# walk.
#
# expectedHeadOid makes the write conditional on the branch not having moved.
# The ingest is serialised by its concurrency group, so a mismatch means
# something genuinely unexpected happened and the run should fail.

set -euo pipefail

WORKDIR="${1:?usage: commit-branch.sh <workdir> <branch> <message>}"
BRANCH="${2:?usage: commit-branch.sh <workdir> <branch> <message>}"
MESSAGE="${3:?usage: commit-branch.sh <workdir> <branch> <message>}"

: "${GITHUB_TOKEN:?a token with contents:write}"
: "${GITHUB_REPOSITORY:?owner/repo}"
API="${GITHUB_API_URL:-https://api.github.com}"

log() { printf '%s\n' "$*" >&2; }

cd "$WORKDIR"

# createCommitOnBranch commits onto a branch that already exists; it cannot
# create one, because a branch needs a commit and this is how commits are made.
# The old git-push path bootstrapped a missing branch with `git init`, and that
# is the one thing lost here. Both state branches have existed since the
# archive did, so this fires only if one is deleted -- in which case the fix is
# to recreate it deliberately, not to have a workflow guess at its contents.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log "FATAL: $WORKDIR is not a checkout of $BRANCH."
    log "       The branch has to exist before anything can be committed to it."
    exit 1
fi

# Stage everything so git decides what changed, not a directory walk.
git add -A
if git diff --cached --quiet HEAD 2>/dev/null; then
    log "nothing changed on $BRANCH"
    exit 0
fi

export BRANCH MESSAGE GITHUB_REPOSITORY
HEAD_OID="$(git rev-parse HEAD)"
export HEAD_OID

payload="$(mktemp)"
response="$(mktemp)"
trap 'rm -f "$payload" "$response"' EXIT

# -z output and NUL parsing: a path may contain anything but NUL, and git
# quotes unusual ones in its default format. Reading raw never unquotes.
# --no-renames: the mutation has no concept of a rename, and the add/delete
# pair it wants is exactly what this produces.
# The Python below is quoted so the shell leaves it alone; it reads what it
# needs from the environment.
# shellcheck disable=SC2016
git diff --cached -z --no-renames --name-status HEAD | python3 -c '
import base64, json, os, sys

raw = sys.stdin.buffer.read().split(b"\0")
additions, deletions = [], []
i = 0
while i + 1 < len(raw):
    status = raw[i].decode()
    if not status:
        break
    path = raw[i + 1].decode()
    if status[0] == "D":
        deletions.append({"path": path})
    else:
        with open(path, "rb") as fh:
            additions.append({"path": path,
                              "contents": base64.b64encode(fh.read()).decode()})
    i += 2

json.dump({
    "query": "mutation($input: CreateCommitOnBranchInput!) {"
             "  createCommitOnBranch(input: $input) {"
             "    commit { oid signature { isValid state } } } }",
    "variables": {"input": {
        "branch": {"repositoryNameWithOwner": os.environ["GITHUB_REPOSITORY"],
                   "branchName": os.environ["BRANCH"]},
        "message": {"headline": os.environ["MESSAGE"]},
        "expectedHeadOid": os.environ["HEAD_OID"],
        "fileChanges": {"additions": additions, "deletions": deletions},
    }},
}, sys.stdout)
sys.stderr.write(f"{len(additions)} addition(s), {len(deletions)} deletion(s)\n")
' > "$payload"

log "committing to $BRANCH, $(wc -c < "$payload") byte payload"

curl -sS --fail-with-body -X POST "$API/graphql" \
    -H "Authorization: bearer $GITHUB_TOKEN" \
    -H 'Content-Type: application/json' \
    --data @"$payload" > "$response"

python3 - "$response" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if d.get("errors"):
    print("FATAL: " + "; ".join(e.get("message", "?") for e in d["errors"]), file=sys.stderr)
    raise SystemExit(1)
c = d["data"]["createCommitOnBranch"]["commit"]
sig = c.get("signature") or {}
print(f'committed {c["oid"][:12]} signature={sig.get("state")} valid={sig.get("isValid")}',
      file=sys.stderr)
if not sig.get("isValid"):
    print("FATAL: GitHub did not sign the commit", file=sys.stderr)
    raise SystemExit(1)
PY
