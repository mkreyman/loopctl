# chg

The agent fleet's change system: Scion's coordination model (server-side landing with no global
lock, affected-only checks before merge, batched verification after merge, auto-revert, Claude
resolving conflicts, intent review) on git storage. Elixir and TypeScript repos are first-class.

- Design and phases: [docs/design.md](docs/design.md)
- Sources: [docs/sources.md](docs/sources.md)
- Shadow phase and the gate switch (`chg check`, `chg gate`, `chg shadow`): [docs/shadow.md](docs/shadow.md)
- Trunk verification, culprits and auto-revert (`chg verify`, `chg culprit`, `chg revert`, `chg flaky`): [docs/verify.md](docs/verify.md)

Layout as it lands: `cli/` (Rust: `chg` and `chgd`), `adapters/` (Elixir, TypeScript),
`server/` (Elixir/Phoenix control plane, phase 2).
