---
title: "Discovery — The .well-known/loopctl Contract"
category: reference
scope: system
---

# Discovery — The .well-known/loopctl Contract

Following RFC 8615, loopctl publishes a discovery document at a
well-known URL that agents and integrations can fetch without prior
configuration.

## Endpoint

```
GET https://loopctl.com/.well-known/loopctl
```

No authentication required. Returns `application/json`.

## Response schema

```json
{
  "spec_version": "2",
  "mcp_server": {
    "name": "loopctl-mcp-server",
    "npm_version": "2.0.0",
    "repository_url": "https://github.com/mkreyman/loopctl/..."
  },
  "audit_signing_key_url": "https://loopctl.com/api/v1/tenants/{tenant_id}/audit_public_key",
  "capability_scheme_url": "https://loopctl.com/wiki/capability-tokens",
  "chain_of_custody_spec_url": "https://loopctl.com/wiki/chain-of-custody",
  "discovery_bootstrap_url": "https://loopctl.com/wiki/agent-bootstrap",
  "required_agent_pattern_url": "https://loopctl.com/wiki/agent-pattern",
  "system_articles_endpoint": "https://loopctl.com/api/v1/articles/system",
  "contact": "operator@loopctl.com"
}
```

## Caching

The response includes `Cache-Control: public, max-age=3600` and a weak
`ETag`. Agents should cache the document for the duration of their session
(typically 1 hour) and use conditional GET (`If-None-Match`) to refresh.

## URL stability

All URL fields are hardcoded to `https://loopctl.com` — they do NOT
change based on the request's `Host` header. This ensures agents
always reach the canonical deployment.

## URI templates

The `audit_signing_key_url` uses a URI template (`{tenant_id}`). Agents
substitute their tenant ID after authentication to construct the full URL.

## Schema validation

A JSON Schema for the discovery document is available at:

```
GET https://loopctl.com/.well-known/loopctl/schema.json
```

## Related articles

- [Agent Bootstrap](/wiki/agent-bootstrap) — what to do after discovery
- [Chain of Custody](/wiki/chain-of-custody) — the trust model
