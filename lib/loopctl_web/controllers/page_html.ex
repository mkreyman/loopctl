defmodule LoopctlWeb.PageHTML do
  @moduledoc """
  HTML templates for the landing page.
  """

  use LoopctlWeb, :html

  embed_templates "page_html/*"

  # Code block content stored as module attributes to avoid HEEx/sigil parsing issues.
  # HEEx interprets `{` as Elixir expressions and `|` as pipe operators,
  # making inline JSON/shell impossible in templates or sigils.

  @hero_code ~S"""
  <pre><code>$ curl -s -H "Authorization: Bearer $KEY" \
    https://loopctl.com/api/v1/stories | jq

  {
    "data": [
      {
        "id": "a3f1...",
        "title": "Landing page",
        "agent_status": "implementing",
        "verified_status": "unverified"
      }
    ]
  }</code></pre>
  """

  @api_stories_code ~S"""
  <pre><code># List stories for your project
  $ curl -H "Authorization: Bearer $KEY" \
    https://loopctl.com/api/v1/stories

  # Contract a story (commit to AC count)
  $ curl -X POST \
    -H "Authorization: Bearer $KEY" \
    -d '{"story_title": "...", "ac_count": 12}' \
    https://loopctl.com/api/v1/stories/$ID/contract

  # Claim and start work
  $ curl -X POST \
    -H "Authorization: Bearer $KEY" \
    https://loopctl.com/api/v1/stories/$ID/claim</code></pre>
  """

  @api_verify_code ~S"""
  <pre><code># Report story done (reviewer, not implementer)
  $ curl -X POST \
    -H "Authorization: Bearer $REVIEWER_KEY" \
    https://loopctl.com/api/v1/stories/$ID/report

  # Record review completion (with findings math)
  $ curl -X POST \
    -H "Authorization: Bearer $REVIEWER_KEY" \
    -d '{"findings_count": 5, "fixes_count": 5}' \
    https://loopctl.com/api/v1/stories/$ID/review-complete

  # Verify (orchestrator confirms)
  $ curl -X POST \
    -H "Authorization: Bearer $ORCH_KEY" \
    https://loopctl.com/api/v1/stories/$ID/verify</code></pre>
  """

  @step1_code ~S"""
  <pre>curl -X POST https://loopctl.com/api/v1/tenants/register \
  -H "Content-Type: application/json" \
  -d '{"name": "My Company", "slug": "my-company", "email": "dev@example.com"}'</pre>
  """

  @step2_code ~S"""
  <pre>curl -X POST https://loopctl.com/api/v1/api_keys \
  -H "Authorization: Bearer $YOUR_KEY" \
  -d '{"name": "orchestrator", "role": "orchestrator"}'

  curl -X POST https://loopctl.com/api/v1/api_keys \
  -H "Authorization: Bearer $YOUR_KEY" \
  -d '{"name": "agent", "role": "agent"}'</pre>
  """

  @step3_code ~S"""
  <pre>curl -X POST https://loopctl.com/api/v1/projects \
  -H "Authorization: Bearer $YOUR_KEY" \
  -d '{"name": "My App", "slug": "my-app"}'</pre>
  """

  @step4_code ~S"""
  <pre>// Add to .mcp.json
  {
  "mcpServers": {
    "loopctl": {
      "command": "node",
      "args": ["node_modules/@loopctl/mcp-server/index.js"],
      "env": {
        "LOOPCTL_SERVER": "https://loopctl.com",
        "LOOPCTL_AGENT_KEY": "lc_your_agent_key"
      }
    }
  }
  }</pre>
  """

  def step1_code_block(assigns),
    do:
      (
        _ = assigns
        Phoenix.HTML.raw(@step1_code)
      )

  def step2_code_block(assigns),
    do:
      (
        _ = assigns
        Phoenix.HTML.raw(@step2_code)
      )

  def step3_code_block(assigns),
    do:
      (
        _ = assigns
        Phoenix.HTML.raw(@step3_code)
      )

  def step4_code_block(assigns),
    do:
      (
        _ = assigns
        Phoenix.HTML.raw(@step4_code)
      )

  @doc """
  Returns the hero code example (curl + JSON response) as safe HTML.
  """
  def hero_code_block(assigns) do
    _ = assigns
    Phoenix.HTML.raw(@hero_code)
  end

  @doc """
  Returns the stories tab code example as safe HTML.
  """
  def api_stories_code_block(assigns) do
    _ = assigns
    Phoenix.HTML.raw(@api_stories_code)
  end

  @doc """
  Returns the verify tab code example as safe HTML.
  """
  def api_verify_code_block(assigns) do
    _ = assigns
    Phoenix.HTML.raw(@api_verify_code)
  end

  # ---------------------------------------------------------------------------
  # Docs page code blocks
  # ---------------------------------------------------------------------------

  @docs_orchestrator_code ~S"""
  <pre><code># Genericized orchestrator command (key excerpts)
  # Full command is ~300 lines; this shows the essential structure.

  # === IDENTITY ===
  # Create sentinel file so hooks know this is an orchestrator session
  touch "$HOME/.claude/.orchestrator-active-$SESSION_ID"

  # === PRE-FLIGHT ===
  # 1. Read CLAUDE.md and AGENTS.md for project conventions
  # 2. Identify architecture docs relevant to current epic
  # 3. Load orchestration state from loopctl
  mcp__loopctl__get_progress({project_id: "&lt;uuid&gt;"})

  # === AUTONOMOUS LOOP ===
  # Repeat until no stories remain in ready state:

  # 1. Find next ready story
  STORY=$(mcp__loopctl__list_stories({status: "ready", limit: 1}))

  # 2. Contract the story (commit to acceptance criteria count)
  mcp__loopctl__contract_story({
  story_id: "$STORY_ID",
  story_title: "...",
  ac_count: 12
  })

  # 3. Build implementation context
  #    - Read the story JSON for full requirements
  #    - Identify which architecture docs apply
  #    - Check for dependency stories that inform this one

  # 4. Dispatch implementation agent (NEVER write code directly)
  #    The orchestrator coordinates. Agents write code.
  claude --agent implementation-agent \
  --message "Implement US-X.Y: $STORY_TITLE ..."

  # 5. Implementation agent finishes — request review
  mcp__loopctl__request_review({story_id: "$STORY_ID"})

  # 6. Dispatch review agents (different identity than implementer)
  #    Team review: 3 agents in parallel
  #    Then: VCA (Verify, Classify, Aggregate)
  #    Then: Adversarial review: 4 agents in parallel
  #    Then: VCA again

  # 7. Review agent reports completion
  mcp__loopctl__report_story({story_id: "$STORY_ID"})
  mcp__loopctl__review_complete({
  story_id: "$STORY_ID",
  findings_count: 14,
  fixes_count: 12,
  disproved_count: 2
  })

  # 8. Orchestrator verifies (third identity)
  mcp__loopctl__verify_story({story_id: "$STORY_ID"})

  # === RULES ===
  # - MCP tools over curl (typed, validated, discoverable)
  # - One story at a time — never parallelize stories
  # - Chain of custody: implementer != reviewer != verifier
  # - Never write code directly — dispatch sub-agents
  # - Fix ALL review findings — no deferrals</code></pre>
  """

  @docs_impl_agent_code ~S"""
  <pre><code>---
  name: implementation-agent
  description: Primary development agent for feature implementation
  permissionMode: bypassPermissions
  model: sonnet
  effort: high
  skills:
  - patterns-elixir
  - patterns-ecto
  - patterns-phoenix-web
  ---</code></pre>
  """

  @docs_security_agent_code ~S"""
  <pre><code>---
  name: security-adversary
  description: Adversarial security and resilience reviewer (READ-ONLY)
  permissionMode: bypassPermissions
  model: opus
  effort: high
  skills:
  - owasp-security
  - patterns-elixir
  ---</code></pre>
  """

  @docs_review_pipeline_code ~S"""
  <pre><code>Team Review (3 agents)  ──&gt;  VCA  ──&gt;  Fix
        │                                  │
        ▼                                  ▼
  Adversarial Review (4 agents)  ──&gt;  VCA  ──&gt;  Fix  ──&gt;  Summary</code></pre>
  """

  @docs_review_math_code ~S"""
  <pre><code># Findings math is API-enforced:
  fixes_count + disproved_count == findings_count

  # Example: 14 findings found
  {
  "findings_count": 14,
  "fixes_count": 12,      # Bugs actually fixed
  "disproved_count": 2     # False positives with justification
  }
  # 12 + 2 == 14  ✓  (accepted by API)
  # 12 + 1 == 13  ✗  (rejected — math doesn't add up)</code></pre>
  """

  @docs_guardrail_hook_code ~S"""
  <pre><code>#!/bin/bash
  # .claude/hooks/PreToolUse/orchestrator-guardrail.sh
  # Blocks Edit/Write/MultiEdit when orchestrator sentinel is active.
  # Orchestrator coordinates — agents write code.

  input=$(cat)
  tool_name=$(echo "$input" | jq -r '.tool_name // ""')
  session_id=$(echo "$input" | jq -r '.session_id // ""')

  if [ -f "$HOME/.claude/.orchestrator-active-$session_id" ]; then
  case "$tool_name" in
    Edit|Write|MultiEdit|NotebookEdit)
      echo "BLOCKED: Orchestrator cannot write code. Dispatch a sub-agent." &gt;&amp;2
      exit 2 ;;
  esac
  fi
  exit 0</code></pre>
  """

  @docs_keepworking_hook_code ~S"""
  <pre><code>#!/bin/bash
  # .claude/hooks/Stop/keep-working.sh
  # Prevents orchestrator from stopping when stories remain.
  # Queries loopctl API for pending work.

  INPUT=$(cat)
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')

  if [ ! -f "$HOME/.claude/.orchestrator-active-$SESSION_ID" ]; then
  exit 0  # Not an orchestrator session
  fi

  # Check for remaining work
  PENDING=$(curl -s -H "Authorization: Bearer $LOOPCTL_ORCH_KEY" \
  "$LOOPCTL_SERVER/api/v1/stories/ready?limit=1" | jq '.data | length')

  if [ "$PENDING" -gt 0 ]; then
  exit 2  # Force continuation — stories remain
  fi
  exit 0</code></pre>
  """

  @docs_claude_md_code ~S"""
  <pre><code># My Project

  Stack: Elixir 1.18 / Phoenix 1.8, PostgreSQL, Oban

  ## CRITICAL: Load Orchestration State
  mcp__loopctl__get_progress({project_id: "&lt;uuid&gt;"})

  ## Chain-of-Custody Enforcement
  - POST /stories/:id/report — 409 if caller == assigned_agent
  - POST /stories/:id/review-complete — 409 if caller == assigned_agent
  - POST /stories/:id/verify — 409 if caller == assigned_agent</code></pre>
  """

  @docs_mcp_json_code ~S"""
  <pre><code>{
  "mcpServers": {
    "loopctl": {
      "command": "node",
      "args": ["node_modules/@loopctl/mcp-server/index.js"],
      "env": {
        "LOOPCTL_SERVER": "https://loopctl.com",
        "LOOPCTL_ORCH_KEY": "lc_your_orchestrator_key",
        "LOOPCTL_AGENT_KEY": "lc_your_agent_key"
      }
    }
  }
  }</code></pre>
  """

  # Docs page code block helper functions

  def docs_orchestrator_code_block(assigns) do
    _ = assigns
    Phoenix.HTML.raw(@docs_orchestrator_code)
  end

  def docs_impl_agent_code_block(assigns) do
    _ = assigns
    Phoenix.HTML.raw(@docs_impl_agent_code)
  end

  def docs_security_agent_code_block(assigns) do
    _ = assigns
    Phoenix.HTML.raw(@docs_security_agent_code)
  end

  def docs_review_pipeline_code_block(assigns) do
    _ = assigns
    Phoenix.HTML.raw(@docs_review_pipeline_code)
  end

  def docs_review_math_code_block(assigns) do
    _ = assigns
    Phoenix.HTML.raw(@docs_review_math_code)
  end

  def docs_guardrail_hook_code_block(assigns) do
    _ = assigns
    Phoenix.HTML.raw(@docs_guardrail_hook_code)
  end

  def docs_keepworking_hook_code_block(assigns) do
    _ = assigns
    Phoenix.HTML.raw(@docs_keepworking_hook_code)
  end

  def docs_claude_md_code_block(assigns) do
    _ = assigns
    Phoenix.HTML.raw(@docs_claude_md_code)
  end

  def docs_mcp_json_code_block(assigns) do
    _ = assigns
    Phoenix.HTML.raw(@docs_mcp_json_code)
  end
end
