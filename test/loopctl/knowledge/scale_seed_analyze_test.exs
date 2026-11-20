defmodule Loopctl.Knowledge.ScaleSeedAnalyzeTest do
  @moduledoc """
  Story 100.38 AC-3: the plan-gate seeds confirm that `ANALYZE` reached
  `pg_stat_user_tables.last_analyze` for every table they analyze. The statistics reader,
  the `ANALYZE` call and the sleep are injected, so no database is touched.
  """
  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.ScaleSeed

  @t0 ~U[2026-11-20 10:00:00Z]
  @t1 ~U[2026-11-20 10:00:05Z]

  # A reader that answers from an Agent, so a test can move a table's timestamp when the
  # fake ANALYZE runs (or later, after some reads).
  defp stats(initial) do
    {:ok, pid} = Agent.start_link(fn -> %{ts: initial, reads: %{}} end)

    read = fn table ->
      Agent.get_and_update(pid, fn s ->
        n = Map.get(s.reads, table, 0) + 1
        {{table, n, s.ts[table]}, %{s | reads: Map.put(s.reads, table, n)}}
      end)
    end

    {pid, read}
  end

  defp opts(read_fun, analyze, sleeps) do
    [
      analyze: analyze,
      last_analyze: read_fun,
      sleep: fn ms -> send(sleeps, {:slept, ms}) end,
      attempts: 4
    ]
  end

  test "passes when every table's last_analyze advanced" do
    {pid, read} = stats(%{"articles" => @t0, "article_embeddings" => nil})

    analyze = fn table -> Agent.update(pid, &put_in(&1, [:ts, table], @t1)) end
    read_ts = fn table -> elem(read.(table), 2) end

    assert :ok ==
             ScaleSeed.analyze_and_confirm!(
               ["articles", "article_embeddings"],
               opts(read_ts, analyze, self())
             )

    refute_received {:slept, _}
  end

  test "waits for a lagging statistics view, then passes" do
    {_pid, read} = stats(%{"articles" => @t0})

    # The view shows the new timestamp only from the third read on (one before, two after).
    read_ts = fn table ->
      case read.(table) do
        {_, n, _} when n >= 3 -> @t1
        {_, _, ts} -> ts
      end
    end

    assert :ok ==
             ScaleSeed.analyze_and_confirm!(["articles"], opts(read_ts, fn _ -> :ok end, self()))

    assert_received {:slept, 100}
  end

  test "raises naming the table whose last_analyze never moved" do
    {_pid, read} = stats(%{"articles" => @t1, "memories" => @t0})

    # articles moves; memories stays at its pre-ANALYZE value for every read.
    read_ts = fn
      "articles" = t -> if elem(read.(t), 1) > 1, do: ~U[2026-11-20 10:01:00Z], else: @t1
      t -> elem(read.(t), 2)
    end

    error =
      assert_raise RuntimeError, fn ->
        ScaleSeed.analyze_and_confirm!(
          ["articles", "memories"],
          opts(read_ts, fn _ -> :ok end, self())
        )
      end

    assert error.message =~ "memories (still ~U[2026-11-20 10:00:00Z])"
    refute error.message =~ "articles"
    assert_received {:slept, 100}
    assert_received {:slept, 200}
    assert_received {:slept, 400}
  end

  test "a table whose last_analyze stays nil fails" do
    {_pid, read} = stats(%{"memories" => nil})
    read_ts = fn t -> elem(read.(t), 2) end

    assert_raise RuntimeError, ~r/memories \(still nil\)/, fn ->
      ScaleSeed.analyze_and_confirm!(["memories"], opts(read_ts, fn _ -> :ok end, self()))
    end
  end

  test "every table is analyzed, each once" do
    read_ts = fn _t -> @t1 end
    analyze = fn table -> send(self(), {:analyzed, table}) end

    # The before-read sees @t1 too, so nothing "advanced": the call raises, but only after
    # analyzing both tables exactly once.
    assert_raise RuntimeError, fn ->
      ScaleSeed.analyze_and_confirm!(
        ["memories", "memory_embeddings"],
        opts(read_ts, analyze, self())
      )
    end

    assert_received {:analyzed, "memories"}
    assert_received {:analyzed, "memory_embeddings"}
    refute_received {:analyzed, _}
  end
end
