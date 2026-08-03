defmodule Loopctl.Embeddings.LegacyRetirementTest do
  @moduledoc """
  GH #551 — the US-41.1 legacy-column retirement TRIGGER.

  The thing under test is a gate, so most of these are negative: each asserts that one
  specific way of NOT knowing keeps the verdict at `:not_due`. That is the property the
  issue actually asked for — "an expired token or an API error must not read as already
  cleaned up" — and every one of them would pass vacuously against a gate that simply
  never fires, so the positive cases (`due_via_evidence`, `due_via_deadline`) are what
  keep the negatives honest.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings.LegacyRetirement
  alias Loopctl.Embeddings.RetirementObservation

  setup :verify_on_exit!

  @today ~D[2026-08-02]
  @required 3

  # A window that WOULD pass: `@required` contiguous days, flag on, counters frozen.
  defp clear_window(opts \\ []) do
    scans = Keyword.get(opts, :scans, %{"articles_embedding_hnsw_idx" => 674})
    reset = Keyword.get(opts, :stats_reset_at, ~U[2026-01-01 00:00:00.000000Z])

    for offset <- (@required - 1)..0//-1 do
      insert_observation(
        observed_on: Date.add(@today, -offset),
        side_table_reads: 1,
        legacy_index_scans: scans,
        stats_reset_at: reset
      )
    end
  end

  defp insert_observation(attrs) do
    attrs = Map.new(attrs)

    %RetirementObservation{}
    |> RetirementObservation.changeset(
      Map.merge(
        %{
          observed_at: DateTime.utc_now(),
          side_table_reads: 1,
          legacy_columns_present: ["articles", "memories"],
          legacy_index_scans: %{},
          stats_reset_at: nil
        },
        attrs
      )
    )
    |> AdminRepo.insert!()
  end

  defp probe(overrides \\ %{}) do
    Map.merge(
      %{
        side_table_reads: 1,
        legacy_columns: ["articles", "memories"],
        legacy_index_scans: %{"articles_embedding_hnsw_idx" => 674},
        stats_reset_at: ~U[2026-01-01 00:00:00.000000Z]
      },
      overrides
    )
  end

  defp evaluate(probe, opts \\ []) do
    LegacyRetirement.evaluate(
      probe,
      Keyword.merge(
        [today: @today, required_clear_days: @required, review_by: ~D[2027-01-22]],
        opts
      )
    )
  end

  describe "probe/0 against the live schema" do
    test "reports the legacy columns that actually exist" do
      assert {:ok, result} = LegacyRetirement.probe()

      assert "articles" in result.legacy_columns
      assert "memories" in result.legacy_columns
    end

    test "discovers legacy indexes BY COLUMN, and finds a non-empty set" do
      assert {:ok, result} = LegacyRetirement.probe()

      # The non-emptiness assertion is the load-bearing one. A `pg_index`/`pg_attribute`
      # join that silently matches NOTHING would make every "zero scans" window pass
      # vacuously forever, and the resulting `:due` would look identical to a real one.
      refute result.legacy_index_scans == %{},
             "expected at least one index over a legacy `embedding` column; an empty " <>
               "set makes the scan check vacuous"

      assert Enum.all?(result.legacy_index_scans, fn {name, scans} ->
               is_binary(name) and is_integer(scans)
             end)

      # Discovery is by column, so it must catch the canonical articles index WITHOUT
      # that name appearing anywhere in the query.
      assert Map.has_key?(result.legacy_index_scans, "articles_embedding_hnsw_idx")
    end

    test "reports the read flag the request path is actually using" do
      stub(Loopctl.MockEmbeddingReadPath, :side_table_reads_enabled?, fn -> true end)
      assert {:ok, %{side_table_reads: 1}} = LegacyRetirement.probe()

      stub(Loopctl.MockEmbeddingReadPath, :side_table_reads_enabled?, fn -> false end)
      assert {:ok, %{side_table_reads: 0}} = LegacyRetirement.probe()
    end
  end

  describe "record/2" do
    test "writes one row per UTC day" do
      assert {:ok, first} = LegacyRetirement.record(probe(), today: @today)
      assert first.observed_on == @today
      assert first.side_table_reads == 1
      assert first.legacy_columns_present == ["articles", "memories"]
    end

    test "a same-day re-run UPDATES rather than adding a second row for the day" do
      {:ok, first} = LegacyRetirement.record(probe(), today: @today)

      {:ok, second} =
        LegacyRetirement.record(
          probe(%{legacy_index_scans: %{"articles_embedding_hnsw_idx" => 700}}),
          today: @today
        )

      assert second.id == first.id
      assert second.legacy_index_scans == %{"articles_embedding_hnsw_idx" => 700}

      # A duplicate row for one day would let a single day stand in for a whole streak.
      assert AdminRepo.aggregate(
               from(o in RetirementObservation, where: o.observed_on == ^@today),
               :count
             ) == 1
    end
  end

  describe "evaluate/2 — the retired terminus" do
    test "no surviving legacy column is :retired, not :due" do
      verdict = evaluate(probe(%{legacy_columns: []}))

      assert verdict.verdict == :retired
      assert verdict.trigger == nil
    end
  end

  describe "evaluate/2 — the evidence trigger" do
    test "a full clear window is :due via evidence" do
      clear_window()

      verdict = evaluate(probe())

      assert verdict.verdict == :due
      assert verdict.trigger == :evidence
      assert verdict.clear_days == @required
    end

    test "no observations at all is :not_due, and says which days are missing" do
      verdict = evaluate(probe())

      assert verdict.verdict == :not_due
      assert verdict.clear_days == 0
      assert Enum.any?(verdict.reasons, &(&1 =~ "only 0 of #{@required} day(s) observed"))
    end

    test "a GAP in the window is :not_due — a day we cannot speak for is not a quiet one" do
      # Two of three days, the missing one strictly inside the window.
      insert_observation(observed_on: Date.add(@today, -2), side_table_reads: 1)
      insert_observation(observed_on: @today, side_table_reads: 1)

      verdict = evaluate(probe())

      assert verdict.verdict == :not_due
      assert Enum.any?(verdict.reasons, &(&1 =~ "only 2 of #{@required} day(s) observed"))
    end

    test "the read flag being OFF on any day in the window is :not_due" do
      clear_window()

      AdminRepo.update_all(
        from(o in RetirementObservation, where: o.observed_on == ^Date.add(@today, -1)),
        set: [side_table_reads: 0]
      )

      verdict = evaluate(probe())

      assert verdict.verdict == :not_due
      assert Enum.any?(verdict.reasons, &(&1 =~ "side_table_reads was not 1 on 1 day(s)"))
    end

    test "a legacy index scan inside the window is :not_due, and names the index" do
      clear_window()

      AdminRepo.update_all(
        from(o in RetirementObservation, where: o.observed_on == ^@today),
        set: [legacy_index_scans: %{"articles_embedding_hnsw_idx" => 700}]
      )

      verdict = evaluate(probe())

      assert verdict.verdict == :not_due

      assert Enum.any?(
               verdict.reasons,
               &(&1 =~ "legacy index scans inside the window: articles_embedding_hnsw_idx (+26)")
             )
    end

    test "a pg_stat reset inside the window invalidates it" do
      clear_window()

      # A reset zeroes idx_scan. Without this check the frozen-looking counters that
      # follow would read as proof of quiet — the precise inversion of the truth.
      AdminRepo.update_all(
        from(o in RetirementObservation, where: o.observed_on == ^@today),
        set: [
          stats_reset_at: ~U[2026-08-02 03:00:00.000000Z],
          legacy_index_scans: %{"articles_embedding_hnsw_idx" => 0}
        ]
      )

      verdict = evaluate(probe())

      assert verdict.verdict == :not_due
      assert Enum.any?(verdict.reasons, &(&1 =~ "statistics were reset inside the window"))
    end

    test "an index absent at the START of the window is :not_due" do
      clear_window()

      # An index created two days ago cannot testify about three.
      AdminRepo.update_all(
        from(o in RetirementObservation, where: o.observed_on == ^Date.add(@today, -2)),
        set: [legacy_index_scans: %{}]
      )

      verdict = evaluate(probe())

      assert verdict.verdict == :not_due

      assert Enum.any?(
               verdict.reasons,
               &(&1 =~ "absent at the start of the window: articles_embedding_hnsw_idx")
             )
    end

    test "a surviving column with NO index over it still clears — deliberately" do
      # Documented as a correct vacuous pass, not a hole: an unindexed legacy column is
      # already past the expensive half of retirement. The flag and the full window
      # still have to hold, which is what makes it a decision rather than a default.
      clear_window(scans: %{})

      verdict = evaluate(probe(%{legacy_index_scans: %{}}))

      assert verdict.verdict == :due
      assert verdict.trigger == :evidence
    end
  end

  describe "evaluate/2 — the deadline trigger" do
    test "a passed review_by is :due even with no evidence whatsoever" do
      # This is the case that makes the whole check fail closed. With no observations,
      # an evidence-only trigger is silent forever and indistinguishable from healthy.
      verdict = evaluate(probe(), review_by: Date.add(@today, -1))

      assert verdict.verdict == :due
      assert verdict.trigger == :deadline
      assert verdict.deadline_passed?
      assert Enum.any?(verdict.reasons, &(&1 =~ "has passed"))
    end

    test "review_by exactly today has passed" do
      verdict = evaluate(probe(), review_by: @today)

      assert verdict.verdict == :due
      assert verdict.trigger == :deadline
    end

    test "a future review_by does not fire on its own" do
      verdict = evaluate(probe(), review_by: Date.add(@today, 1))

      assert verdict.verdict == :not_due
      refute verdict.deadline_passed?
    end

    test "the deadline NEVER fires once the columns are gone" do
      verdict = evaluate(probe(%{legacy_columns: []}), review_by: Date.add(@today, -1))

      assert verdict.verdict == :retired
    end
  end

  describe "the shipped defaults" do
    test "review_by is a real future-dated deadline, not an unset placeholder" do
      # A deadline defaulted to nil or to the epoch is the same as having none: the
      # first quietly never fires, the second fires on day one and gets muted.
      assert %Date{} = LegacyRetirement.review_by()
      assert Date.compare(LegacyRetirement.review_by(), ~D[2026-08-02]) == :gt
      assert LegacyRetirement.required_clear_days() > 0
    end
  end
end
