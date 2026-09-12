# loopctl-runner

Dev-machine runner for the loopctl agent delivery loop.

A small Phoenix application that runs on each enrolled dev machine. It connects **outbound** to
the loopctl control plane over an authenticated Phoenix Channel, publishes the machine into the
availability pool via `Phoenix.Presence`, and supervises Claude Code sessions in git worktrees
through Ports.

It is deliberately a **client**, not a cluster peer: a dev machine never joins the production
BEAM cluster. See `docs/agent-delivery-loop.md` section 2 for why.

## Status

Design only. No implementation yet. Start at section 12, "Build order", step 1 — one runner,
one machine, one hand-filed story, **merging nothing**.

## Why this repo is private, and what would make it public

It encodes fleet topology (which machines are enrolled, their capabilities, local paths), the
token handling for a channel that can cause code to be written and merged, and it is the
companion to an escalation predicate whose trigger list is a map of which code paths skip human
review.

The mechanism is publishable; the policy and topology are not. If this is built so that
topology and trigger lists live in configuration rather than in source, going public later is
deleting a config directory rather than a refactor. Build it that way.

## Enrolled machines

minis (Linux), mac-mini (macOS), blockit (macOS). Not beelink (dedicated CI host) and not
xps13 (4 threads, 8 GB soldered).

## Packaging

`mix release`, built on each target machine — every enrolled machine already has a full asdf
Elixir toolchain, and BEAM releases are not portable across OS or architecture. Supervised by
`systemd --user` on Linux and a launchd `LaunchAgent` on macOS, user-scoped in both cases.
See `docs/agent-delivery-loop.md` section 14, including three traps that will otherwise cost a
debugging session.
