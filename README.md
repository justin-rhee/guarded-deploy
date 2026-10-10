# guarded-deploy

One bash wrapper for deploy scripts: **re-check the tree is clean and HEAD is the exact gated commit immediately before anything ships**, **refuse loudly and say which one moved when either changed**, and **create and push a `deploy-<utc>` tag only once the deploy has succeeded**. About 200 lines of POSIX bash, and everything it calls is already on your machine.

It exists because my deploy script shipped a file the tests had never run against, and I only caught it because I happened to be testing the deploy script itself that day. The clean-tree check had passed a few minutes earlier, and somewhere in between the gate touched a file; a build step, a formatter, an agent working in another session, and the thing ships what's on disk rather than what it checked. If your deploy script checks the tree before it runs your tests, it's telling you about a tree that's already gone.

## Use it if

- your checks take minutes, and minutes is long enough for the tree to change under them
- a build step, an editor, or an agent shares the machine your deploys run from
- you'd rather a deploy refuse loudly than ship something nothing ever gated

## How it works

Right before your deploy command runs, it looks one more time: is the tree still clean, and is HEAD still the exact commit the gate passed? That second question is about the commit the gate actually ran against, not the one you asked for, because those can quietly stop being the same thing. Three guards wrap around that, in this order:

- the work tree is clean, checked first so a dirty tree costs you a second instead of a full test run
- your gate command exits 0, whatever your gate is
- HEAD gets an annotated `deploy-<utc>` tag, created only once the deploy succeeds, then pushed; the tag waits for exit 0 so a failed deploy never leaves a marker claiming it shipped, and it gets pushed because a tag that only exists on your laptop isn't a rollback plan the day the laptop is the problem

The fourth guard is for state that isn't in your commit: feature switches, spend limits, whatever the service reads at runtime. A limit set in the wrong unit is silently ignored and the service falls back to its own default, so nothing errors and the number in force isn't the number you set. A preflight command of your choosing runs before anything ships, and if it can't answer, nothing ships. The preflight is your command and this wrapper never reads its output; whatever it prints goes to your terminal and nowhere else. The first version dumped the whole production environment into a shell variable to read settings, which left every secret in it one `set -x` from a log file. If the preflight wants something acknowledged, it writes one word into a file it's handed, and that word is what you type.

What a refusal looks like, from a gate that leaves a build stamp behind:

```
$ ./guarded-deploy.sh --yes
guarded-deploy: running the gate: ./check2.sh
  lint ok, types ok, 214 tests ok
guarded-deploy: preflight: ./preflight.sh
  autoplay      ON    customers see the new player the moment this lands
  daily limit   500   dollars, read live by the service, not from this commit

guarded-deploy: commit  7b20d14 (7b20d14b2cdef9fbd1e23ee0b621668be0741821)
guarded-deploy: tag     deploy-20260813T032735Z (new, created and pushed once the deploy succeeds)
guarded-deploy: deploy  ./ship.sh  (in the repo root)

guarded-deploy: BLOCKED: the working tree went dirty after the gate ran. Nothing shipped. Commit or stash, then run this again so the gate covers what you are deploying.
```

## Install

Copy `src/guarded-deploy.sh` into your repo, make it executable, and configure it through the environment.

| Setting | What it is |
| --- | --- |
| `GD_GATE_CMD` | required. The checks that must pass. Runs at the repo root. |
| `GD_DEPLOY_CMD` | required. The irreversible command. |
| `GD_DEPLOY_DIR` | where to run the deploy. Defaults to the repo root. |
| `GD_PREFLIGHT_CMD` | runs before anything ships, in `GD_DEPLOY_DIR`. Optional. |
| `GD_TAG_PUSH_CMD` | defaults to `git push origin`, and receives the tag as an argument. |

There's no default gate and no default deploy command, and it refuses to run without both; a gate you didn't choose isn't a gate. Keep the settings in a small script in the repo, so they get reviewed like anything else instead of living in one person's shell history.

Point it at your own repo without letting it near anything real: `--dry-run` runs every guard and then stops, so the deploy command is never used.

```sh
GD_GATE_CMD="make check" GD_DEPLOY_CMD="echo would deploy" bash ~/guarded-deploy/src/guarded-deploy.sh --dry-run
```

You know it's in place when `--dry-run` ends with "every guard passed" and a dirty tree stops in about a second with `BLOCKED`. `--yes` skips both typed confirmations and keeps every other guard, which is what a scheduled job should use.

## What it won't do

It doesn't make your deploy command safe. It decides whether to run it, and after that whatever happens is between you and your deploy command.

The window is smaller, not gone. A write landing in the fraction of a second between the final check and the deploy still ships; what closes is the minutes-long window, the one with a realistic chance of catching you.

It can't tell whether your gate is any good. A gate of `true` passes every time and the wrapper will happily report every guard passed. Same for the preflight: it's your script, and if it reports something untrue, this believes it. If it can't answer at all the deploy blocks, which will annoy you the first time your network is down.

It's a door, not a wall. Nothing stops anyone running the deploy command directly, it doesn't cover that command reachable from a CI job or a browser tab, and anyone who can run the wrapper can set `GD_GATE_CMD` to `true`. It guards against mistakes, not against someone who has decided to skip it. `--yes` gives up the human half the same way: a job running with it keeps the git guards, the gate and the preflight, and asks nobody for confirmation.

It assumes one deploy command going to one place, so there's no environment matrix and no staging-and-production pair, and nothing that varies by branch. It also calls the tag pushed when the push command exits 0, without checking the remote afterwards.

It needs `git tag --points-at`, which the documentation carries back to 2.12; I've run it on 2.50. POSIX shell only, never run on Windows.

## How I tested it

26 offline checks: `bash tests/test_guarded_deploy.sh`. Each builds its own throwaway git repo, and the gate, preflight, deploy and tag push are fakes that write marker files, so no irreversible command ever runs.

Two of them exist only to break the headline promise. Both pass the first clean-tree check honestly and then change what was checked, so only the re-check can catch them: one injects a gate that touches a file, the way a build step or a formatter does, and the other injects a gate that commits, leaving a clean tree pointing at a commit nothing gated.

Then I deleted the nine lines that do the re-check and ran it again.

```
  FAIL  a tree that goes dirty after the gate stops the deploy: expected a blocked, non-zero exit, got 0
  FAIL  a HEAD that moves after the gate stops the deploy: expected a blocked, non-zero exit, got 0
24 passed, 2 failed
```

Exactly those two, the other 24 unaffected. A test that passes with the protection removed was never testing the protection. Lines back, suite back to 26.

Run on macOS with bash 3.2.57 and git 2.50.1, so the suite avoids associative arrays and `mapfile` and gives `mktemp -d` an explicit template. Ubuntu comes from the CI matrix.

## License

MIT, see [LICENSE](LICENSE). No warranty. Security posture and how to report a problem: [SECURITY.md](SECURITY.md). Design decisions and what changed while building it: [docs/ADR.md](docs/ADR.md).

This little tool is one of a handful I pulled out of my own day-to-day agent setup. I use them all myself, so when something breaks I usually notice fast. If you spot anything off, open an issue. I read every one. More tools on my [GitHub profile](https://github.com/justin-rhee).
