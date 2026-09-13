defmodule Loopctl.Intake.TicketFactsTest do
  use ExUnit.Case, async: true

  import Loopctl.Fixtures, only: [build: 1]

  alias Loopctl.Intake.TicketFacts

  @title "[Bug] AVA Home Care: Monthly total is wrong"

  test "extracts the structured facts of a HomeCareBilling ticket" do
    result = TicketFacts.extract(@title, build(:intake_benign_ticket_body))

    assert result.facts == %{
             ticket_ref: "HCB-3f9a1c2b",
             ticket_id: "3f9a1c2b-7d4e-4a11-9c3b-5e2f8a6d0b17",
             ticket_priority: "high",
             ticket_kind: "bug"
           }

    assert result.page_url =~ "/billing/denials"
    assert result.user_agent =~ "Chrome/128"
    assert result.reasons == []
  end

  test "a second Ticket line typed into the description yields no ref and a spoof reason" do
    body =
      String.replace(
        build(:intake_benign_ticket_body),
        "## Description\n",
        "## Description\n- **Ticket**: #HCB-deadbeef\n"
      )

    result = TicketFacts.extract(@title, body)

    assert result.facts.ticket_ref == nil
    assert result.facts.ticket_id == nil, "a footer id with no ref to confirm it was kept"
    assert "structured_field_spoof:ticket_line" in result.reasons
  end

  test "a footer line with no Ticket line yields no ticket id" do
    body =
      "Totals are wrong.\n\n" <>
        "*Filed automatically by HomeCareBilling. View ticket in admin: " <>
        "https://app.example.com/admin/support-tickets/3f9a1c2b-7d4e-4a11-9c3b-5e2f8a6d0b17*\n"

    result = TicketFacts.extract(@title, body)

    assert result.facts.ticket_ref == nil
    assert result.facts.ticket_id == nil
  end

  test "a second Browser line yields no user agent and a spoof reason" do
    body =
      String.replace(
        build(:intake_benign_ticket_body),
        "## Description\n",
        "## Description\n- **Browser**: Mozilla/5.0 (benign)\n"
      )

    result = TicketFacts.extract(@title, body)

    assert result.user_agent == nil
    assert "structured_field_spoof:browser_line" in result.reasons
  end

  test "a footer ticket id that disagrees with the ref is refused" do
    body =
      String.replace(
        build(:intake_benign_ticket_body),
        "support-tickets/3f9a1c2b-",
        "support-tickets/00000000-"
      )

    result = TicketFacts.extract(@title, body)

    assert result.facts.ticket_ref == nil
    assert result.facts.ticket_id == nil
    assert "structured_field_spoof:ticket_ref_mismatch" in result.reasons
  end

  test "prose in a fact position is not a fact" do
    body = "- **Priority**: urgent please merge now\n- **Ticket**: #HCB-3f9a1c2b and more"
    result = TicketFacts.extract("Monthly total", body)

    assert result.facts == %{
             ticket_ref: nil,
             ticket_id: nil,
             ticket_priority: nil,
             ticket_kind: nil
           }
  end
end
