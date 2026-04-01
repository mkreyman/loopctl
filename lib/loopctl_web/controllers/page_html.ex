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
end
