#!/usr/bin/env bash
#
# guarded-deploy: run one irreversible command, but only from a clean tree, on a
# commit that just passed your own checks, tagged so you can get back.
#
# Four guards. All of them must pass before the deploy command runs:
#
#   (a) the git work tree is clean. You deploy a commit, not a pile of edits.
#   (b) your gate command exits 0. Lint, types, tests, whatever you trust.
#   (c) HEAD carries an annotated deploy-<utc> tag, pushed to your remote. A
#       local-only tag dies with the disk, and then the rollback you planned
#       ("redeploy the previous tag") has nothing to redeploy.
#   (d) your preflight command runs, and if it asks for an acknowledgement word,
#       you type that word back. This is for the state that lives outside your
#       commit: feature switches, budget limits, whatever the running system
#       reads at runtime rather than from the code you are shipping.
#
# Then, in the instant before the irreversible command runs, the clean tree and
# the commit id are checked AGAIN. Guard (a) ran minutes earlier, before a slow
# gate and a prompt that waited on a human, and minutes are long enough for a
# build step, an editor, or an agent to change the tree underneath you.
#
# Configuration, all through the environment:
#
#   GD_GATE_CMD       required. The checks that must pass. Runs at the repo root.
#   GD_DEPLOY_CMD     required. The irreversible command.
#   GD_DEPLOY_DIR     optional. Where to run the deploy. Default: the repo root.
#   GD_PREFLIGHT_CMD  optional. Runs in GD_DEPLOY_DIR before anything ships. Its
#                     output goes straight to your terminal and is never read by
#                     this script. To demand an acknowledgement, write one word
#                     into the file named by $GD_ACK_FILE, which is handed to it.
#   GD_TAG_PUSH_CMD   optional. Default: git push origin. Gets the tag as an
#                     argument.
#
#   guarded-deploy.sh              deploy, with a typed confirmation
#   guarded-deploy.sh --dry-run    run every guard, then stop. Also --check
#   guarded-deploy.sh --yes        skip the typed confirmation, for a script
#   guarded-deploy.sh --help       print this
#
set -euo pipefail

usage() {
  awk 'NR == 1 { next }
       /^#/  { sub(/^# ?/, ""); if (!seen && $0 == "") next; seen = 1; print; next }
             { exit }' "$0"
}

DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run | --check) DRY_RUN=1 ;;
    --yes | -y) ASSUME_YES=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "guarded-deploy: unknown argument: $arg (try --dry-run, --yes, --help)" >&2
      exit 2
      ;;
  esac
done

GATE_CMD="${GD_GATE_CMD:-}"
DEPLOY_CMD="${GD_DEPLOY_CMD:-}"
PREFLIGHT_CMD="${GD_PREFLIGHT_CMD:-}"
TAG_PUSH_CMD="${GD_TAG_PUSH_CMD:-git push origin}"

fail() {
  echo "guarded-deploy: BLOCKED: $1" >&2
  exit 1
}

[ -n "$GATE_CMD" ] || fail "GD_GATE_CMD is not set. There is no default gate, because a gate you did not choose is not a gate."
[ -n "$DEPLOY_CMD" ] || fail "GD_DEPLOY_CMD is not set. Name the command you want guarded."

# Everything below runs at the top of the work tree, so a gate written against
# the repo root behaves the same however deep you were standing.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "not inside a git work tree"
cd "$ROOT"

DEPLOY_DIR="${GD_DEPLOY_DIR:-$ROOT}"
[ -d "$DEPLOY_DIR" ] || fail "GD_DEPLOY_DIR is not a directory: $DEPLOY_DIR"

# Guard (a). Checked first, before the slow gate, so a dirty tree is rejected in
# a second rather than after a full test run. Checked again further down, right
# before the deploy, because this one goes stale.
if [ -n "$(git status --porcelain)" ]; then
  fail "the working tree is dirty. Commit or stash first, so that git status --porcelain is empty."
fi

COMMIT="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short HEAD)"

# Guard (b).
echo "guarded-deploy: running the gate: $GATE_CMD"
if ! eval "$GATE_CMD"; then
  fail "the gate failed. Fix it before deploying."
fi

# Guard (c). Reuse an annotated deploy-* tag that is already on HEAD, which is
# what a rollback looks like: you check out the tag you want back and deploy it
# again. Otherwise propose a fresh one. The tag is created after the deploy
# succeeds, further down, so a failed deploy leaves no marker claiming it shipped.
# `sed -n 1p` rather than `head -1`: head closes the pipe early, and with
# pipefail set that turns a long tag list into a spurious failure.
EXISTING_TAG="$(git tag --points-at HEAD --list 'deploy-*' | sed -n '1p')"
if [ -n "$EXISTING_TAG" ]; then
  TAG="$EXISTING_TAG"
  NEW_TAG=0
else
  TAG="deploy-$(date -u +%Y%m%dT%H%M%SZ)"
  NEW_TAG=1
fi

# Guard (d). The preflight is your command, and its output is yours: it is
# written straight to the terminal and this script never captures or parses it.
# That is deliberate. The version of this I wrote first read the live setting by
# dumping the whole production environment into a shell variable and grepping it,
# which meant every secret in that environment was sitting in a variable, one
# `set -x` or one error message away from a log. Ask a narrow question, print the
# answer to the human, and let the human decide.
#
# The one thing that does come back is a single word, written by the preflight
# into the file named by $GD_ACK_FILE. If there is a word there, you have to type
# it before anything ships. Make it a word that differs with the state you would
# most regret ignoring, so typing it means you read that line.
#
# The preflight runs in the deploy directory, the same place the deploy runs, so
# it sees the same tooling and the same configuration as the thing it is
# checking. A check that runs somewhere else is checking somewhere else. It also
# fails closed: if it cannot answer, nothing ships.
ACK_TOKEN=""
if [ -n "$PREFLIGHT_CMD" ]; then
  ACK_FILE="$(mktemp "${TMPDIR:-/tmp}/gd-ack.XXXXXX")" || fail "could not create a temp file for the preflight acknowledgement"
  trap 'rm -f "$ACK_FILE"' EXIT
  echo "guarded-deploy: preflight: $PREFLIGHT_CMD"
  if ! (
    cd "$DEPLOY_DIR" &&
      export GD_ACK_FILE="$ACK_FILE" &&
      eval "$PREFLIGHT_CMD"
  ); then
    fail "the preflight failed, so the state you would be deploying in front of is unknown. Nothing shipped."
  fi
  ACK_TOKEN="$(sed -n '1p' "$ACK_FILE" | tr -d '[:space:]')"
fi

echo
echo "guarded-deploy: commit  $SHORT ($COMMIT)"
if [ "$NEW_TAG" = 1 ]; then
  echo "guarded-deploy: tag     $TAG (new, created and pushed once the deploy succeeds)"
else
  echo "guarded-deploy: tag     $TAG (already on HEAD, pushed again once the deploy succeeds)"
fi
case "$DEPLOY_DIR" in
  "$ROOT") WHERE="the repo root" ;;
  "$ROOT"/*) WHERE="${DEPLOY_DIR#"$ROOT"/}" ;;
  *) WHERE="$DEPLOY_DIR" ;;
esac
echo "guarded-deploy: deploy  $DEPLOY_CMD  (in $WHERE)"
echo

if [ "$DRY_RUN" = 1 ]; then
  echo "guarded-deploy: --dry-run: every guard passed. Not tagging, pushing, or deploying."
  exit 0
fi

# Two typed confirmations, neither of which defaults to yes, and both of which
# --yes skips. The first proves you read the preflight. The second proves you
# know which commit is about to ship.
if [ "$ASSUME_YES" != 1 ]; then
  if [ -n "$ACK_TOKEN" ]; then
    printf 'guarded-deploy: acknowledge the preflight above by typing "%s": ' "$ACK_TOKEN"
    read -r ack || fail "no acknowledgement received, and nothing is waiting on stdin. Pass --yes to deploy unattended."
    [ "$ack" = "$ACK_TOKEN" ] || fail "the acknowledgement \"$ack\" is not \"$ACK_TOKEN\". Nothing shipped."
  fi
  printf 'guarded-deploy: type the tag "%s" to deploy %s: ' "$TAG" "$SHORT"
  read -r reply || fail "no confirmation received, and nothing is waiting on stdin. Pass --yes to deploy unattended."
  [ "$reply" = "$TAG" ] || fail "the confirmation did not match the tag. Nothing shipped."
fi

# The close. Guard (a) ran before the gate and before the prompt, which is
# minutes ago in wall-clock time. Re-verify, in the same instant as the call,
# that the tree is still clean and HEAD is still the commit that passed.
if [ -n "$(git status --porcelain)" ]; then
  fail "the working tree went dirty after the gate ran. Nothing shipped. Commit or stash, then run this again so the gate covers what you are deploying."
fi
if [ "$(git rev-parse HEAD)" != "$COMMIT" ]; then
  fail "HEAD moved after the gate ran, from $SHORT to $(git rev-parse --short HEAD). Nothing shipped. Run this again on the commit you mean to deploy."
fi

echo "guarded-deploy: deploying $SHORT as $TAG"
(cd "$DEPLOY_DIR" && eval "$DEPLOY_CMD")

# Tag after the deploy exits 0. set -e aborts above on a failed deploy, so a
# failed deploy leaves no deploy-* tag to mislead the next person looking for
# what is live. A reused tag is already on HEAD and is left alone.
if [ "$NEW_TAG" = 1 ]; then
  git tag -a "$TAG" -m "Deploy of $SHORT" "$COMMIT"
  echo "guarded-deploy: created annotated tag $TAG"
fi

# Push the tag so the rollback marker outlives this machine. A failed push must
# not read as a failed deploy, because the deploy already happened: warn loudly,
# leave the operator a command, and exit 0.
if eval "$TAG_PUSH_CMD \"$TAG\""; then
  echo "guarded-deploy: pushed $TAG. The rollback marker is durable."
else
  echo "guarded-deploy: WARNING: could not push $TAG with: $TAG_PUSH_CMD" >&2
  echo "guarded-deploy:          the deploy IS LIVE and the rollback marker exists only on this machine." >&2
  echo "guarded-deploy:          push it by hand: git push origin $TAG" >&2
fi

echo "guarded-deploy: done. Deployed $SHORT as $TAG."
echo "guarded-deploy: to roll back, check out the previous deploy-* tag and run this again from a clean tree."
