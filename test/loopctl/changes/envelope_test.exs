defmodule Loopctl.Changes.EnvelopeTest do
  @moduledoc "US-47.3: the chg event envelope, v1 (Epic 47 PRD §5)."

  use ExUnit.Case, async: true

  import Loopctl.Fixtures, only: [build: 2]

  alias Loopctl.Changes.Envelope

  test "decodes every field of a v1 envelope" do
    raw =
      Jason.encode!(
        build(:chg_event, %{
          kind: "landed",
          event_seq: 3,
          revision: 2,
          data: %{"merge_sha" => "x"}
        })
      )

    assert {:ok, envelope} = Envelope.decode(raw)
    assert envelope.v == 1
    assert envelope.event_seq == 3
    assert envelope.revision == 2
    assert envelope.kind == "landed"
    assert envelope.data == %{"merge_sha" => "x"}
    assert %DateTime{} = envelope.occurred_at
  end

  test "accepts any lowercase kind, so chg can add kinds without a release" do
    assert {:ok, %{kind: "some_new_kind"}} =
             Envelope.validate(build(:chg_event, %{kind: "some_new_kind"}))
  end

  test "a 64-character sha is a git object id too" do
    assert {:ok, _} = Envelope.validate(build(:chg_event, %{sha: String.duplicate("a", 64)}))
  end

  test "refuses what is not a v1 envelope" do
    base = build(:chg_event, %{})

    for bad <- [
          Map.put(base, "v", 2),
          Map.delete(base, "data"),
          Map.put(base, "data", [1]),
          Map.put(base, "repo", "no-slash"),
          Map.put(base, "change_id", "a b"),
          Map.put(base, "change_id", String.duplicate("a", 256)),
          Map.put(base, "event_seq", 0),
          Map.put(base, "revision", 0),
          Map.put(base, "kind", "Landed"),
          Map.put(base, "sha", String.duplicate("A", 40)),
          Map.put(base, "occurred_at", "yesterday"),
          [base],
          "string"
        ] do
      assert Envelope.validate(bad) == {:error, :invalid_event}, inspect(bad)
    end

    assert Envelope.decode("{") == {:error, :invalid_event}
    assert Envelope.decode("[]") == {:error, :invalid_event}
  end
end
