# Epic 51 — the chg feedback loop: findings filed, fixed and closed without a human

Mark, 2026-11-18, after Epic 50 shipped the ledger: *"where's the positive feedback loop?"*, and
on chg's own fixes reaching him by design: *"I would argue that should be the first place the
automatic feedback loop should be implemented. Then chg continues improving its practices."*
On the HomeCareBilling intake that triages only support-ticket issues: *"Let's add this source
to allow to enter the loop."*

Epic 50 made loopctl hold chg's ledger. Nothing reads it except a person at a dashboard. This
epic closes the loop: loopctl turns what the ledger shows is wrong into evidence-carrying
GitHub issues, the delivery loop fixes them, and loopctl closes each issue once its signal
stays quiet, or reopens it when the fix did not hold.

## Where this sits against chg#22

mkreyman/chg#22 (S14) designs chg as the improvement loop's sensor and issue writer, with
per-machine `chgd` clustering. Its ledger-shaped sensors (selection misses, flaky tests, review
rounds, stuck changes) now have one central home, loopctl, which sees every machine at once, so
loopctl files those (US-51.1). chg#22 keeps the sensors the ledger does not carry (harness
friction from `chgd`'s spool) and adopts this epic's fingerprint, cap, depth and closure rules
rather than a second copy. The guards below are chg#22's, implemented here in code.

## The loop

```
ledger rows ─▶ nightly sweep ─▶ finding (fingerprint) ─▶ GitHub issue on the owning repo
                                      ▲                         │ intake webhook
                                      │                         ▼
            reopen "fix did not hold" │              triage ─▶ implement ─▶ review ─▶ merge
                                      │                         │
                                      └──── signal recurs ◀─────┴──▶ silent M days ─▶ close
```

## Guards, each in code

- **One open issue per fingerprint.** Occurrences accumulate on the finding row.
- **A cap per repository per day** (default 5). Over the cap a finding waits, ranked by
  occurrences.
- **Two failed fixes, then a person.** A fingerprint that recurs after two merged fixes stops
  auto-filing and escalates.
- **No self-amplification.** A finding whose evidence points at a commit the loop itself merged
  carries `loop_depth + 1`; depth 2 escalates instead of filing.
- **Silence is a finding.** A source that normally sends rows and stops is filed, so an empty
  ledger never reads as "nothing wrong".

## chg's own fixes merge on proof, not on a person (US-51.5)

The KB decision `4a86157b` put chg's selection, gate, verify and revert code behind Gate B's
`human_paths`, because a loop that edits its own gate can weaken it: a "fix" that selects fewer
tests makes a miss disappear by hiding it. Mark overruled the human step for chg's fixes on
2026-11-18. What replaces the person is a measurement the implementer cannot make for itself:

- chg's SELECTION code becomes an `effect_paths` trigger, so a change to it is `:prove_effect`,
  not `:human`.
- The proof is loopctl's own ledger, written by the independent verifier (verify@1, its own
  custody root), never by the implementing session: replayed on the fix's head, the miss commit
  must now select the missed test, and every commit in the replay corpus must select a superset
  of what the base selected. Selection may only WIDEN.
- The merge precondition accepts that proof because loopctl measured it, the case its
  `:effect_proof_caller_asserted` clause was left open for.
- The rest of the floor (verify, revert, landing, CI workflows) stays `human_paths`. No sweep
  finding targets it, so the loop never needs it.

## Stories

| story | what | depends on |
|---|---|---|
| 51.1 | Finding sweep: fingerprint, file one issue per finding, cap, depth | — |
| 51.2 | Closure: close on silence, reopen on recurrence, two failed fixes escalate | 51.1 |
| 51.3 | Loop-filed issues enter intake on a ticket-gated source | 51.1 |
| 51.4 | Silence detector: a quiet source is a finding | 51.1 |
| 51.5 | chg's selection fixes merge on a measured widening proof | 51.1 |
| 51.6 | Read surface: findings in the summary, an MCP tool, the dashboard | 51.1, 51.2 |

The chg side of 51.5 (a replay command that writes verifier-bound ledger rows) and chg#22's
adoption of the finding rules are handed off on the chg channel.

## Decisions Mark may overrule

| default | where | effect of overruling |
|---|---|---|
| loopctl, not chg's `chgd`, files ledger-derived findings | US-51.1 | per-machine filing needs cross-machine dedup loopctl gets for free |
| Cap 5 new loop issues per repository per day | US-51.1 | higher spends more runner sessions on a bad day |
| Close after 7 quiet days | US-51.2 | shorter closes fixes that only looked good |
| Selection code is proof-gated; verify, revert, landing and CI stay human | US-51.5 | widening the proof set needs a proof for each of those paths |
| Proof means selection only widens across the replay corpus | US-51.5 | a fix that legitimately narrows selection still reaches a person |
