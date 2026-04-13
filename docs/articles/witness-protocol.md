---
title: "Witness Protocol — Cross-Agent Tamper Detection"
category: reference
scope: system
---

# Witness Protocol

The witness protocol provides cross-agent tamper detection via
PubSub-broadcast Signed Tree Heads (STHs).

## How agents participate

1. Each agent subscribes to the tenant's audit chain PubSub topic
2. STH updates are broadcast every 60 seconds
3. Agents cache the latest STH locally
4. On every API request, agents include the `X-Loopctl-Last-Known-STH`
   header with their cached position and signature prefix

## Divergence detection

If an agent's cached STH doesn't match the server's record for that
position, a divergence is detected. This means someone rewrote the
chain — which requires compromising every connected agent's memory
simultaneously.

## Custody halt

On divergence, the tenant's custody operations are halted until an
operator clears the halt via break-glass with WebAuthn.

See [Chain of Custody](/wiki/chain-of-custody) for the full trust model.
See [Break Glass](/wiki/break-glass) for emergency procedures.
