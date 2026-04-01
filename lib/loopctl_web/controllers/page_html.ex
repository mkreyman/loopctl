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
        "verified_status": "pending"
      }
    ]
  }</code></pre>
  """

  @api_code ~S"""
  <pre><code># List stories for your project
  $ curl -H "Authorization: Bearer $KEY" \
    https://loopctl.com/api/v1/stories

  # Contract a story (commit to AC count)
  $ curl -X POST \
    -H "Authorization: Bearer $KEY" \
    -d '{"ac_count": 12}' \
    https://loopctl.com/api/v1/stories/$ID/contract

  # Claim and start work
  $ curl -X POST \
    -H "Authorization: Bearer $KEY" \
    https://loopctl.com/api/v1/stories/$ID/claim</code></pre>
  """

  @doc """
  Returns the hero code example (curl + JSON response) as safe HTML.
  """
  def hero_code_block(assigns) do
    _ = assigns
    Phoenix.HTML.raw(@hero_code)
  end

  @doc """
  Returns the API code example (multiple curl commands) as safe HTML.
  """
  def api_code_block(assigns) do
    _ = assigns
    Phoenix.HTML.raw(@api_code)
  end
end
