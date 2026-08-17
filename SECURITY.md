# Security policy: guarded-deploy

## Posture

guarded-deploy is provided as-is, with no warranty (see LICENSE). It is a safety
tool for one irreversible command, not a security boundary. Use it as one control
among several, never as a sole guarantee.

The honest ceiling: it reduces, and does not eliminate, the chance of shipping
something other than the commit you checked. It is a door, not a wall. Nothing
stops the deploy command being run directly, and anyone who can run the wrapper
can also set `GD_GATE_CMD` to `true` and neutralize the gate. This is a guard
against mistakes, not against a person or a process that has decided to skip it.

Three properties worth knowing before you rely on this:

The remaining window is small, not zero. The clean tree and the commit id are
re-checked in the instant before the deploy command is called, but a write that
lands inside that instant still ships. What this closes is the minutes-long
window between the first check and the deploy, which is the one long enough to
catch you in practice.

The configured commands are run through `eval`, and they run with your
privileges. Whoever controls `GD_GATE_CMD`, `GD_DEPLOY_CMD`, `GD_PREFLIGHT_CMD`
or `GD_TAG_PUSH_CMD` controls what this executes. Treat those settings as code
and keep them in a reviewed file in your repo rather than in a shell profile or
anywhere an automated process can rewrite them.

The preflight is trusted output. The wrapper never captures or parses it, which
is deliberate, and the cost of that choice is that a preflight reporting
something untrue is believed. It fails closed, so a preflight that exits non-zero
blocks the deploy.

## Validation status

The offline suite in `tests/test_guarded_deploy.sh` has been run: 26 checks, all
passing, on macOS with bash 3.2.57 and git 2.50.1. It covers every guard, both
confirmations, the tag lifecycle, and two checks whose only job is to violate the
headline promise by dirtying the tree and by moving HEAD after the gate has
passed.

The re-check that makes that promise true was then deleted and the suite re-run,
to confirm those two checks can actually fail. They do, and the other 24 are
unaffected.

There is no fuzzing corpus and no adversarial corpus. The threat model is a
person or an agent making a mistake during a slow deploy, not a hostile operator,
and a hostile operator defeats this by running the deploy command directly. That
is a property of the design, not a bug to fix.

## Reporting a problem

Report privately through this repository's Security tab, using GitHub's
"Report a vulnerability" flow, or by opening a minimal issue that describes the
impact without a working exploit. Please give a reasonable window for a fix
before publishing details.

For a correctness bug that is not security sensitive, a normal issue with a
reproduction is the fastest path.
