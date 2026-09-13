defmodule Loopctl.Intake.TicketFacts do
  @moduledoc """
  Extracts structured, non-prose facts from a HomeCareBilling-filed GitHub issue by strict
  pattern only (issue #803). No model ever reads the text to do it.

  The format is the one `HomeCareBilling.Workers.GitHubIssueWorker` writes today:

      [Bug] <tenant name>: <subject>

      ## Description
      <reporter description>

      ## Context
      - **Ticket**: #HCB-a1b2c3d4
      - **Priority**: normal
      - **Page**: <page url>
      - **Tenant**: <tenant name>
      - **Browser**: <user agent>

      ---
      *Filed automatically by HomeCareBilling. View ticket in admin: https://<host>/admin/support-tickets/<uuid>*

  ## What is extracted

  - `ticket_ref` — `HCB-` plus eight lowercase hex digits, from exactly one Ticket line.
  - `ticket_id` — the support ticket UUID, from exactly one footer line, and only when it
    begins with the ref's eight digits.
  - `ticket_priority` — `urgent`, `high`, `normal` or `low`, from exactly one Priority line.
  - `ticket_kind` — `bug` or `feature`, from the title's `[Bug] ` / `[Feature] ` prefix.

  `page_url` and `user_agent` are returned for the injection detector and never stored:
  both are client-supplied, so they are exactly where a payload hides. Each is trimmed and
  loses ONE pair of delimiters wrapping the whole value — an inline code span (one or two
  backticks) or matching double or single quotes — because a producer formatting the issue
  may wrap them, and a wrapper is formatting, not content. Only the outermost pair goes: a
  backtick left inside a user agent still reaches the detector, which flags it.

  The `Tenant` line is not a fact and is not read here at all (HomeCareBilling writes the
  tenant name in a code span). It is still part of the body the detector scans.

  ## The reporter can type the format

  The description sits ABOVE the context block, so a reporter can write a Ticket, Priority,
  Page, Browser or footer line of their own. Every structured line must therefore appear
  exactly once; a second copy yields no fact and a `structured_field_spoof` reason, as
  does a footer UUID that disagrees with the ref. A single forged line on an issue that is
  NOT in this format cannot be told apart, which is why every fact here is a claim.
  """

  @ticket_line ~r/^- \*\*Ticket\*\*: #(HCB-[0-9a-f]{8})[ \t]*$/m
  @priority_line ~r/^- \*\*Priority\*\*: ([a-z]+)[ \t]*$/m
  @page_line ~r/^- \*\*Page\*\*: ?(.*)$/m
  @browser_line ~r/^- \*\*Browser\*\*: ?(.*)$/m
  @footer_line ~r/^\*Filed automatically by HomeCareBilling\. View ticket in admin: https?:\/\/[A-Za-z0-9.-]+(?::\d{1,5})?\/admin\/support-tickets\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\*[ \t]*$/m
  @kind_prefix ~r/\A\[(Bug|Feature)\] /

  @priorities ~w(urgent high normal low)

  @type extraction :: %{
          facts: %{
            ticket_ref: String.t() | nil,
            ticket_id: String.t() | nil,
            ticket_priority: String.t() | nil,
            ticket_kind: String.t() | nil
          },
          page_url: String.t() | nil,
          user_agent: String.t() | nil,
          reasons: [String.t()]
        }

  @doc "Extracts the facts from an issue's title and body. See the moduledoc."
  @spec extract(String.t() | nil, String.t() | nil) :: extraction()
  def extract(title, body) do
    body =
      (body || "") |> String.replace_invalid(<<0xFFFD::utf8>>) |> String.replace("\r\n", "\n")

    title = title || ""

    {ref, ref_spoof} = single(@ticket_line, body, "ticket")
    {priority, priority_spoof} = single(@priority_line, body, "priority")
    {footer_id, footer_spoof} = single(@footer_line, body, "footer")
    {page_url, page_spoof} = single(@page_line, body, "page")
    {user_agent, browser_spoof} = single(@browser_line, body, "browser")
    page_url = unwrap(page_url)
    user_agent = unwrap(user_agent)

    {ref, ticket_id, mismatch} = reconcile(ref, footer_id)

    reasons =
      [ref_spoof, priority_spoof, footer_spoof, page_spoof, browser_spoof, mismatch]
      |> Enum.reject(&is_nil/1)

    %{
      facts: %{
        ticket_ref: ref,
        ticket_id: ticket_id,
        ticket_priority: if(priority in @priorities, do: priority),
        ticket_kind: kind(title)
      },
      page_url: page_url,
      user_agent: user_agent,
      reasons: reasons
    }
  end

  # Exactly one match yields its capture; more than one yields nothing and a spoof reason.
  defp single(pattern, body, line) do
    case Regex.scan(pattern, body, capture: :all_but_first) do
      [[value]] -> {value, nil}
      [] -> {nil, nil}
      [_, _ | _] -> {nil, "structured_field_spoof:#{line}_line"}
    end
  end

  # Outermost first, so a double-backtick span is not mistaken for a single one.
  @wrappers [{"``", "``"}, {"`", "`"}, {"\"", "\""}, {"'", "'"}]

  defp unwrap(nil), do: nil

  defp unwrap(value) do
    trimmed = String.trim(value)

    Enum.find_value(@wrappers, trimmed, fn {open, close} ->
      if byte_size(trimmed) > byte_size(open) + byte_size(close) and
           String.starts_with?(trimmed, open) and String.ends_with?(trimmed, close) do
        trimmed
        |> binary_part(byte_size(open), byte_size(trimmed) - byte_size(open) - byte_size(close))
        |> String.trim()
      end
    end)
  end

  # The footer id is only ever kept as confirmation of a ref. With no ref there is nothing
  # to check it against, so a footer line alone, typed or duplicated, is not a fact.
  defp reconcile(nil, _footer_id), do: {nil, nil, nil}
  defp reconcile(ref, nil), do: {ref, nil, nil}

  defp reconcile("HCB-" <> short = ref, footer_id) do
    if String.starts_with?(footer_id, short),
      do: {ref, footer_id, nil},
      else: {nil, nil, "structured_field_spoof:ticket_ref_mismatch"}
  end

  defp kind(title) do
    case Regex.run(@kind_prefix, title, capture: :all_but_first) do
      ["Bug"] -> "bug"
      ["Feature"] -> "feature"
      _ -> nil
    end
  end
end
