# Architecture Decision Records (ADRs)

Why this is shaped the way it is, including the decision that changed after a test disagreed with the design.

## The last check, not the first

The first version checked the work tree at the top of the run, which is the obvious place for it. A dirty tree should cost you a second, not a full test run, so the check belongs before the slow part.

Then I wrote a test for it. The test injected a gate that touched a single file, which is exactly what a build step, a formatter, or an agent tidying up behind you does, and the deploy ran anyway. The clean-tree check had passed, honestly, several minutes earlier. Everything after it was operating on a fact that had expired.

The general name for this is a time-of-check to time-of-use gap, and what makes this one worth closing is the size of it. It is not a microsecond race between two threads. It is the length of your test suite plus however long it took someone to read a prompt and type a word, and the code running inside that window is the very code most likely to write to the tree. The gate is the threat.

So the same two facts are re-established in the instant before the call: the tree is clean, and HEAD is the commit the gate ran against. The commit id matters as much as the tree, because a gate that commits leaves a perfectly clean tree pointing at something that was never gated. Both of those have a test whose only job is to violate the promise, and deleting the re-check turns exactly those two red.

The check at the top stays. It is not the safety property, it is the fast rejection, and keeping both means a dirty tree is refused in a second while a tree that goes dirty later is still caught.

## There is no default gate and no default deploy command

Both are required, and the script refuses to run without them.

A default here would have to be a guess about someone else's repo, and the failure mode of guessing is silent. A gate that defaults to something absent, or to `true`, passes every time and prints the same reassuring line as a gate that ran ten minutes of tests. The tool would then be a machine for producing false confidence, which is worse than no tool, because the whole reason to run this is to be able to trust the output.

Making them required costs two lines in a wrapper script and removes the possibility of a guard that only looks like one.

## The preflight prints to you, and this script never reads it

The fourth guard exists because some of what you are deploying in front of is not in your commit. Feature switches and spend limits live in the running system, and a limit set in the wrong unit is silently ignored by a service that then falls back to its own default. Nothing errors. The number in force is not the number you set, and the only way to know is to look before you ship.

The first version looked by dumping the whole production environment into a shell variable and picking the values it wanted out of it. That works, and it means every secret in that environment is sitting in a variable in a shell script, one `set -x` or one unlucky error message away from a log file. The convenience is real and the exposure is real, and it took me embarrassingly long to notice I had traded one for the other.

So the preflight is your command and its output is not mine. It runs, it writes to your terminal, and this script neither captures nor parses a byte of it. Ask a narrow question, show the answer to the person, let the person decide. If your preflight needs to dump an environment to answer, that decision is yours and it is visible in your script rather than buried in mine.

It runs in the same directory the deploy runs in, because a check that runs somewhere else is checking somewhere else, and tooling that resolves in one directory frequently does not resolve in another. It also fails closed. A preflight that cannot answer blocks the deploy, which is the annoying behavior and the correct one.

## The word you type comes from the preflight, not from the wrapper

A confirmation that is always the same word is a reflex, not a decision. Typing `yes` proves nothing except that a prompt appeared.

The wrapper hands the preflight the path to a file. Whatever single word the preflight writes there becomes the word you have to type. Make it a word that changes with the state you would most regret ignoring, and typing it means you read at least that line. Leave the file empty and no acknowledgement is asked for, so a repo that has nothing outside its commit to worry about does not get a ceremony it did not earn.

This is also the only thing that comes back from the preflight, which keeps the no-capture rule intact. One word, into a file the preflight chose to write.

## The tag is created after the deploy succeeds, and it is pushed

The tag is what makes a rollback possible: an immutable marker on the exact commit that shipped, so getting back is checking it out and running this again.

Creating it before the deploy would mean a failed deploy leaves a `deploy-*` tag on a commit that never shipped, and the next person reading the tag list to work out what is live gets a confident wrong answer. So it is created after the deploy command exits 0.

Pushing it is the part I nearly skipped. A local tag is a rollback plan that lives on one disk, and the day you need it most is a plausible day for that disk to be the problem. It is pushed through a command you can override, so the tool does not assume your remote is called `origin` or that you use git remotes the way I do.

An annotated tag rather than a lightweight one, because an annotated tag carries who made it and when as a real object in the repo, and a test pins that so it cannot quietly drift back.

## A failed push warns, and does not fail

If the tag push fails, the script prints a warning to stderr, tells you the deploy is live and the marker is local only, hands you the command to run by hand, and exits 0.

Exiting non-zero there would be a lie. The deploy already happened. A non-zero exit tells every wrapper, script, and person reading it that the deploy failed, and the reaction to a failed deploy is to try again, which is the last thing anyone should do to a deploy that actually succeeded. The honest report is success with a loud warning about a specific missing piece of durability.

## Reusing a tag that is already on HEAD

If HEAD already carries a `deploy-*` tag, that tag is reused rather than a second one being created next to it.

This is what a rollback looks like from the inside. You check out the tag you want back, you run this again, and the commit you are deploying is a commit that has already shipped once. Stamping a new tag on it would give one commit two names for the same event, and the tag list stops being a history of deploys and becomes a history of times someone ran the script.

## What is deliberately not here

No environment matrix. One gate, one deploy command, one target. Repos that deploy to staging and production from the same script will want two wrapper scripts, and two obvious scripts beat one configurable one.

No check that the remote really has the tag. The push command's exit code is taken at face value. Verifying would mean another network call, on the far side of a deploy that has already happened, to improve a warning message.

No attempt to stop the deploy command being run directly. This is a door, not a wall, and a door that claimed to be a wall would be the more dangerous object.

`--yes` exists and skips both typed confirmations, because an unattended job that cannot skip them will be replaced by someone calling the deploy command directly, and then there are no guards at all. It keeps every git guard, the gate and the preflight, and gives up only the human ones.

Written for bash 3.2, which is what macOS still ships, so no associative arrays and no `mapfile`. The BSD and GNU versions of `sed`, `date` and `mktemp` disagree just enough to matter, so the script sticks to the forms both agree on, and the test suite creates temp directories with an explicit template because a bare `mktemp -d` is not portable. The one git feature that sets a floor is `git tag --points-at`, which the documentation carries back as far as 2.12.
