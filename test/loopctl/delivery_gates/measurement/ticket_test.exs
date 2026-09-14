defmodule Loopctl.DeliveryGates.Measurement.TicketTest do
  use ExUnit.Case, async: true

  import Loopctl.Fixtures

  alias Loopctl.DeliveryGates.Measurement.Ticket

  describe "parse/1" do
    test "reads a gh issue record" do
      assert {:ok, ticket} = Ticket.parse(build(:measurement_ticket, labels: ["bug"]))

      assert ticket.number == 1234
      assert ticket.labels == ["bug"]
      assert ticket.state_reason == "COMPLETED"
      assert ticket.intake?
    end

    test "an issue with no intake prefix is not an intake ticket" do
      assert {:ok, %{intake?: false}} =
               Ticket.parse(build(:measurement_ticket, %{"title" => "Refactor the parser"}))
    end

    test "a [Feature] prefix is an intake ticket too" do
      assert {:ok, %{intake?: true}} =
               Ticket.parse(
                 build(:measurement_ticket, %{"title" => "[Feature] Acme Homecare: a column"})
               )
    end

    test "a bracketed title that is not the intake shape is not one" do
      assert {:ok, %{intake?: false}} =
               Ticket.parse(build(:measurement_ticket, %{"title" => "[Bug] the total is wrong"}))
    end

    test "an empty body is nil rather than an empty string" do
      assert {:ok, %{body: nil}} = Ticket.parse(build(:measurement_ticket, %{"body" => ""}))
    end
  end

  describe "parse/1 refuses rather than guesses" do
    test "a record with no title is refused, never defaulted to an empty one" do
      # Defaulting would find no request-shaped signal and quietly LOWER the escalation rate.
      assert {:error, {:missing_title, 1234}} =
               Ticket.parse(build(:measurement_ticket, %{"title" => ""}))
    end

    test "a record with no number is refused" do
      assert {:error, {:missing_number, _keys}} =
               Ticket.parse(Map.delete(build(:measurement_ticket, []), "number"))
    end

    test "something that is not an object at all is refused" do
      assert {:error, :not_an_object} = Ticket.parse("an issue")
    end
  end

  describe "parse_all/1" do
    test "returns the tickets AND the records it refused" do
      records = [build(:measurement_ticket, []), %{"number" => 9}, "junk"]

      assert {:ok, [ticket], [{:missing_title, 9}, :not_an_object]} = Ticket.parse_all(records)
      assert ticket.number == 1234
    end

    test "a corpus that is not a list is refused" do
      assert {:error, :not_a_list} = Ticket.parse_all(%{"issues" => []})
    end
  end
end
