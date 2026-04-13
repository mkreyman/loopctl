---
title: "Dispatch Lineage — Ephemeral Keys and Sub-Agent Identity"
category: reference
scope: system
---

# Dispatch Lineage

Every agent in loopctl operates under a dispatch — a scoped assignment
with an ephemeral API key that carries its full lineage path.

## The dispatch tree

```
root (operator, WebAuthn)
├── orchestrator dispatch (ephemeral key, 4h TTL)
│   ├── implementer dispatch (ephemeral key, 1h TTL, story-scoped)
│   └── reviewer dispatch (ephemeral key, 1h TTL, story-scoped)
└── admin dispatch (ephemeral key, 1h TTL)
```

## Creating a dispatch

```bash
curl -X POST https://loopctl.com/api/v1/dispatches \
  -H "Authorization: Bearer $ORCH_KEY" \
  -d '{"role": "agent", "agent_id": "...", "story_id": "...", "expires_in_seconds": 3600}'
```

Response includes the ephemeral `raw_key` — pass it to the sub-agent.

## Lineage path

Each dispatch records its full ancestry: `[root_id, orch_id, self_id]`.
The self-check compares lineage prefixes: if two dispatches share a
common ancestor (prefix), they are treated as the same actor.

## Why this prevents sock-puppets

An orchestrator cannot dispatch a sub-agent and pre-select it as its
own verifier. The rotating verifier selection (US-26.2.2) picks from
dispatches that do NOT share a prefix with the implementer's lineage.

See [Agent Pattern](/wiki/agent-pattern) for the full lifecycle.
See [Capability Tokens](/wiki/capability-tokens) for how caps bind to lineages.
