#!/usr/bin/env bash
#
# Offline test suite for guarded-deploy.
#
#     bash tests/test_guarded_deploy.sh
#
# Nothing to install, no network, no credentials. Every check builds its own
# throwaway git repo under a temp directory and deletes it afterwards. The gate,
# the preflight, the deploy and the tag push are all fakes that write marker
# files, so no irreversible command ever runs and no remote is ever contacted.
#
# Exit 0 only if every check passes.
#
# Written for bash 3.2, which is what macOS ships: no associative arrays, no
# mapfile, no ${var^^}. `pipefail` is deliberately off, because several checks
# feed input to a script that exits before reading it, and that would otherwise
# be reported as the pipeline failing.

set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
SCRIPT="$(cd "$HERE/.." && pwd -P)/src/guarded-deploy.sh"

PASS=0
FAIL=0
ERR=""
STATUS=0

WORK=""
REPO=""
RUN_DIR=""
OUTF=""
ERRF=""
INF=""
GATE=""
DEPLOY=""
PREFLIGHT=""
PUSH=""
DIR=""
STDIN_DATA=""

# --- the fixture repo ------------------------------------------------------

setup() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/gd.XXXXXX") || return 1
  # macOS hands back /var/..., while git reports the same place as /private/var/...
  # Resolve it once here so no check ever compares the two spellings.
  WORK=$(cd "$WORK" && pwd -P) || return 1

  REPO="$WORK/repo"
  OUTF="$WORK/stdout"
  ERRF="$WORK/stderr"
  INF="$WORK/stdin"
  mkdir -p "$REPO" "$WORK/nohooks" "$WORK/deploydir" "$WORK/elsewhere" || return 1

  git init -q "$REPO" >/dev/null 2>&1 || return 1
  git -C "$REPO" config user.email "tests@guarded-deploy.invalid"
  git -C "$REPO" config user.name "guarded-deploy tests"
  git -C "$REPO" config commit.gpgsign false
  # A core.hooksPath configured globally on the machine running this suite must
  # not reach into the fixture repos.
  git -C "$REPO" config core.hooksPath "$WORK/nohooks"
  printf 'hello\n' >"$REPO/a.txt"
  git -C "$REPO" add a.txt || return 1
  git -C "$REPO" commit -q -m "first" || return 1

  # Markers live outside the repo. A marker written inside it would dirty the
  # tree and quietly change what the guards are looking at.
  RUN_DIR="$REPO"
  GATE="true"
  DEPLOY='touch "$TEST_WORK/DEPLOYED"'
  PREFLIGHT=""
  PUSH="true"
  DIR="$REPO"
  STDIN_DATA=""

  fixtures
}

fixtures() {
  cat >"$WORK/gate-dirty.sh" <<'EOS'
#!/bin/sh
# A gate that dirties the tree it just checked: a build step, a formatter, an
# agent tidying up behind you. The clean-tree guard has already passed.
touch sneaky.txt
EOS
  cat >"$WORK/gate-commit.sh" <<'EOS'
#!/bin/sh
# A gate that commits. The tree stays clean, so only a check on the commit id
# can notice that HEAD is no longer what was gated.
git commit -q --allow-empty -m "landed while you were reading the prompt"
EOS
  cat >"$WORK/gate-marker.sh" <<'EOS'
#!/bin/sh
touch "$TEST_WORK/GATE_RAN"
EOS
  cat >"$WORK/preflight-live.sh" <<'EOS'
#!/bin/sh
echo "preflight: the switch is LIVE and the daily limit is 500"
printf 'live' > "$GD_ACK_FILE"
EOS
  cat >"$WORK/preflight-quiet.sh" <<'EOS'
#!/bin/sh
echo "preflight: nothing here needs acknowledging"
EOS
  cat >"$WORK/preflight-pwd.sh" <<'EOS'
#!/bin/sh
pwd -P > "$TEST_WORK/PREFLIGHT_PWD"
EOS
  cat >"$WORK/deploy-pwd.sh" <<'EOS'
#!/bin/sh
pwd -P > "$TEST_WORK/DEPLOY_PWD"
touch "$TEST_WORK/DEPLOYED"
EOS
  cat >"$WORK/push-record.sh" <<'EOS'
#!/bin/sh
printf '%s' "$1" > "$TEST_WORK/PUSHED"
EOS
  chmod +x "$WORK"/gate-*.sh "$WORK"/preflight-*.sh "$WORK"/deploy-pwd.sh "$WORK"/push-record.sh
}

run_tool() {
  printf '%s' "$STDIN_DATA" >"$INF"
  (
    cd "$RUN_DIR" &&
      TEST_WORK="$WORK" \
        GD_GATE_CMD="$GATE" \
        GD_DEPLOY_CMD="$DEPLOY" \
        GD_DEPLOY_DIR="$DIR" \
        GD_PREFLIGHT_CMD="$PREFLIGHT" \
        GD_TAG_PUSH_CMD="$PUSH" \
        "$SCRIPT" "$@"
  ) >"$OUTF" 2>"$ERRF" <"$INF"
  STATUS=$?
}

seed_tag() { git -C "$REPO" tag -a "$1" -m "seed" >/dev/null 2>&1; }
tags() { git -C "$REPO" tag --list 'deploy-*'; }
tail_err() { tail -n 1 "$ERRF" 2>/dev/null; }

# Each of these sets ERR and returns 1 on failure, so a check reads as a list of
# `assertion || return 1` lines.
blocked() { [ "$STATUS" -ne 0 ] || { ERR="expected a blocked, non-zero exit, got 0"; return 1; }; }
succeeded() { [ "$STATUS" -eq 0 ] || { ERR="expected exit 0, got $STATUS: $(tail_err)"; return 1; }; }
exited() { [ "$STATUS" -eq "$1" ] || { ERR="expected exit $1, got $STATUS: $(tail_err)"; return 1; }; }
says() { grep -qE "$1" "$OUTF" || { ERR="stdout never said /$1/"; return 1; }; }
warns() { grep -qE "$1" "$ERRF" || { ERR="stderr never said /$1/, last line was: $(tail_err)"; return 1; }; }
marked() { [ -e "$WORK/$1" ] || { ERR="the $1 marker is missing, so that step never ran"; return 1; }; }
unmarked() { [ ! -e "$WORK/$1" ] || { ERR="the $1 marker exists, so that step ran when it must not have"; return 1; }; }
no_tags() { [ -z "$(tags)" ] || { ERR="expected no deploy tag, found: $(tags)"; return 1; }; }

# --- the guards ------------------------------------------------------------

t_script_is_executable() {
  [ -f "$SCRIPT" ] || { ERR="no script at $SCRIPT"; return 1; }
  [ -x "$SCRIPT" ] || { ERR="the script is not executable"; return 1; }
}

t_dry_run_deploys_nothing() {
  run_tool --dry-run
  succeeded || return 1
  says 'every guard passed. Not tagging' || return 1
  unmarked DEPLOYED || return 1
  no_tags || return 1
}

t_dirty_tree_rejected_before_the_gate() {
  printf 'uncommitted\n' >"$REPO/b.txt"
  GATE="$WORK/gate-marker.sh"
  run_tool --dry-run
  blocked || return 1
  warns 'dirty' || return 1
  unmarked GATE_RAN || return 1
  unmarked DEPLOYED || return 1
}

t_red_gate_blocks() {
  GATE="false"
  run_tool --dry-run
  blocked || return 1
  warns 'gate failed' || return 1
  unmarked DEPLOYED || return 1
}

t_missing_deploy_command_blocks() {
  DEPLOY=""
  GATE="$WORK/gate-marker.sh"
  run_tool --dry-run
  blocked || return 1
  warns 'GD_DEPLOY_CMD is not set' || return 1
  unmarked GATE_RAN || return 1
}

t_missing_gate_command_blocks() {
  GATE=""
  run_tool --dry-run
  blocked || return 1
  warns 'GD_GATE_CMD is not set' || return 1
  unmarked DEPLOYED || return 1
}

t_outside_a_git_tree_refuses() {
  RUN_DIR="$WORK/elsewhere"
  run_tool --dry-run
  blocked || return 1
  warns 'not inside a git work tree' || return 1
  unmarked DEPLOYED || return 1
}

# --- confirmation ----------------------------------------------------------

t_nothing_on_stdin_means_no_deploy() {
  run_tool
  blocked || return 1
  warns 'no confirmation received' || return 1
  unmarked DEPLOYED || return 1
  no_tags || return 1
}

t_yes_deploys_and_leaves_an_annotated_tag() {
  run_tool --yes
  succeeded || return 1
  marked DEPLOYED || return 1
  tag=$(tags)
  echo "$tag" | grep -qE '^deploy-[0-9]{8}T[0-9]{6}Z$' ||
    { ERR="the tag is not a deploy-<utc> stamp: $tag"; return 1; }
  kind=$(git -C "$REPO" cat-file -t "$tag" 2>/dev/null)
  [ "$kind" = "tag" ] || { ERR="the tag is a $kind, not an annotated tag"; return 1; }
}

t_typing_the_tag_confirms_the_deploy() {
  seed_tag deploy-20200101T000000Z
  STDIN_DATA='deploy-20200101T000000Z
'
  run_tool
  succeeded || return 1
  marked DEPLOYED || return 1
}

t_a_wrong_tag_confirmation_blocks() {
  seed_tag deploy-20200101T000000Z
  STDIN_DATA='yes
'
  run_tool
  blocked || return 1
  warns 'did not match the tag' || return 1
  unmarked DEPLOYED || return 1
}

t_a_tag_already_on_head_is_reused() {
  seed_tag deploy-20200101T000000Z
  PUSH="$WORK/push-record.sh"
  run_tool --yes
  succeeded || return 1
  [ "$(tags)" = "deploy-20200101T000000Z" ] ||
    { ERR="expected the one existing tag, found: $(tags)"; return 1; }
  [ "$(cat "$WORK/PUSHED" 2>/dev/null)" = "deploy-20200101T000000Z" ] ||
    { ERR="the reused tag was not the one pushed"; return 1; }
}

# --- the preflight ---------------------------------------------------------

t_a_failing_preflight_blocks_even_a_check_run() {
  PREFLIGHT="false"
  run_tool --check
  blocked || return 1
  warns 'preflight failed' || return 1
  unmarked DEPLOYED || return 1
  no_tags || return 1
}

t_preflight_output_reaches_the_operator() {
  PREFLIGHT="$WORK/preflight-live.sh"
  run_tool --dry-run
  succeeded || return 1
  says 'the switch is LIVE and the daily limit is 500' || return 1
}

t_preflight_runs_in_the_deploy_directory() {
  DIR="$WORK/deploydir"
  PREFLIGHT="$WORK/preflight-pwd.sh"
  run_tool --dry-run
  succeeded || return 1
  got=$(cat "$WORK/PREFLIGHT_PWD" 2>/dev/null)
  [ "$got" = "$WORK/deploydir" ] ||
    { ERR="the preflight ran in $got, not in the deploy directory"; return 1; }
}

t_the_acknowledgement_word_must_be_typed_back() {
  seed_tag deploy-20200101T000000Z
  PREFLIGHT="$WORK/preflight-live.sh"
  STDIN_DATA='live
deploy-20200101T000000Z
'
  run_tool
  succeeded || return 1
  says 'acknowledge the preflight above by typing "live"' || return 1
  marked DEPLOYED || return 1
}

t_a_wrong_acknowledgement_word_blocks() {
  seed_tag deploy-20200101T000000Z
  PREFLIGHT="$WORK/preflight-live.sh"
  STDIN_DATA='paused
deploy-20200101T000000Z
'
  run_tool
  blocked || return 1
  warns 'acknowledgement .paused. is not .live.' || return 1
  unmarked DEPLOYED || return 1
}

t_no_word_is_demanded_when_the_preflight_asks_for_none() {
  seed_tag deploy-20200101T000000Z
  PREFLIGHT="$WORK/preflight-quiet.sh"
  STDIN_DATA='deploy-20200101T000000Z
'
  run_tool
  succeeded || return 1
  marked DEPLOYED || return 1
}

# --- the deploy and the tag ------------------------------------------------

t_the_deploy_runs_in_the_deploy_directory() {
  DIR="$WORK/deploydir"
  DEPLOY="$WORK/deploy-pwd.sh"
  run_tool --yes
  succeeded || return 1
  got=$(cat "$WORK/DEPLOY_PWD" 2>/dev/null)
  [ "$got" = "$WORK/deploydir" ] ||
    { ERR="the deploy ran in $got, not in the deploy directory"; return 1; }
}

t_the_tag_is_handed_to_the_push_command() {
  PUSH="$WORK/push-record.sh"
  run_tool --yes
  succeeded || return 1
  marked DEPLOYED || return 1
  tag=$(tags)
  got=$(cat "$WORK/PUSHED" 2>/dev/null)
  [ "$got" = "$tag" ] || { ERR="the push command got '$got', not '$tag'"; return 1; }
  says 'pushed deploy-' || return 1
}

t_a_failed_push_is_not_a_failed_deploy() {
  PUSH="false"
  run_tool --yes
  succeeded || return 1
  marked DEPLOYED || return 1
  [ -n "$(tags)" ] || { ERR="the tag should still exist on this machine"; return 1; }
  warns 'could not push|only on this machine' || return 1
}

t_a_failed_deploy_leaves_no_tag() {
  DEPLOY="false"
  run_tool --yes
  blocked || return 1
  no_tags || return 1
}

# --- the close: the tree and HEAD are re-checked in the same instant -------

t_a_tree_that_goes_dirty_after_the_gate_stops_the_deploy() {
  GATE="$WORK/gate-dirty.sh"
  run_tool --yes
  blocked || return 1
  warns 'went dirty' || return 1
  unmarked DEPLOYED || return 1
  no_tags || return 1
}

t_a_head_that_moves_after_the_gate_stops_the_deploy() {
  GATE="$WORK/gate-commit.sh"
  run_tool --yes
  blocked || return 1
  warns 'HEAD moved' || return 1
  unmarked DEPLOYED || return 1
  no_tags || return 1
}

# --- arguments -------------------------------------------------------------

t_an_unknown_argument_exits_2() {
  run_tool --deploy-now
  exited 2 || return 1
  warns 'unknown argument' || return 1
  unmarked DEPLOYED || return 1
}

t_help_runs_nothing() {
  GATE="$WORK/gate-marker.sh"
  run_tool --help
  succeeded || return 1
  says 'Four guards' || return 1
  unmarked GATE_RAN || return 1
  unmarked DEPLOYED || return 1
}

CHECKS=(
  "t_script_is_executable|the script exists and is executable"
  "t_dry_run_deploys_nothing|--dry-run passes every guard and deploys nothing"
  "t_dirty_tree_rejected_before_the_gate|a dirty tree is rejected before the gate runs"
  "t_red_gate_blocks|a red gate blocks the deploy"
  "t_missing_deploy_command_blocks|no deploy command configured blocks before the gate"
  "t_missing_gate_command_blocks|no gate command configured blocks"
  "t_outside_a_git_tree_refuses|outside a git work tree it refuses to run"
  "t_nothing_on_stdin_means_no_deploy|nothing on stdin means no deploy"
  "t_yes_deploys_and_leaves_an_annotated_tag|--yes deploys and leaves an annotated deploy tag"
  "t_typing_the_tag_confirms_the_deploy|typing the tag confirms the deploy"
  "t_a_wrong_tag_confirmation_blocks|a wrong confirmation blocks the deploy"
  "t_a_tag_already_on_head_is_reused|a deploy tag already on HEAD is reused, not duplicated"
  "t_a_failing_preflight_blocks_even_a_check_run|a failing preflight blocks, even on a --check run"
  "t_preflight_output_reaches_the_operator|the preflight's own output reaches the operator"
  "t_preflight_runs_in_the_deploy_directory|the preflight runs in the deploy directory"
  "t_the_acknowledgement_word_must_be_typed_back|the preflight's acknowledgement word must be typed back"
  "t_a_wrong_acknowledgement_word_blocks|a wrong acknowledgement word blocks the deploy"
  "t_no_word_is_demanded_when_the_preflight_asks_for_none|no word is demanded when the preflight asks for none"
  "t_the_deploy_runs_in_the_deploy_directory|the deploy runs in the deploy directory"
  "t_the_tag_is_handed_to_the_push_command|the deploy tag is handed to the push command"
  "t_a_failed_push_is_not_a_failed_deploy|a failed tag push is not a failed deploy"
  "t_a_failed_deploy_leaves_no_tag|a failed deploy leaves no tag behind"
  "t_a_tree_that_goes_dirty_after_the_gate_stops_the_deploy|a tree that goes dirty after the gate stops the deploy"
  "t_a_head_that_moves_after_the_gate_stops_the_deploy|a HEAD that moves after the gate stops the deploy"
  "t_an_unknown_argument_exits_2|an unknown argument exits 2 and runs nothing"
  "t_help_runs_nothing|--help prints the guards and runs nothing"
)

printf 'guarded-deploy: %d offline checks\n' "${#CHECKS[@]}"

for entry in "${CHECKS[@]}"; do
  fn=${entry%%|*}
  name=${entry#*|}
  ERR=""
  STATUS=0
  if setup; then
    "$fn"
    st=$?
  else
    st=1
    ERR="could not build a throwaway git repo under ${TMPDIR:-/tmp}"
  fi
  if [ "$st" -eq 0 ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s: %s\n' "$name" "$ERR"
  fi
  case "$WORK" in
    */gd.*) rm -rf "$WORK" ;;
  esac
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
