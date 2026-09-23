defmodule Loopctl.Runners.SelectionTest do
  @moduledoc """
  US-44.6: `Loopctl.Runners.Selection.note_no_runner/3` — the fact a pass logs when a story
  found no runner. `Selection.runners/3` needs a connected runner, so it is exercised through
  both passes in `Loopctl.Delivery.DispatchDriverTest` and `Loopctl.Delivery.TriageDispatcherTest`;
  its exhaustion predicate alone is in `Loopctl.Runners.UsageTest`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Loopctl.Repo
  alias Loopctl.Runners.Runner
  alias Loopctl.Runners.Selection
  alias Loopctl.Runners.Usage

  setup :verify_on_exit!

  # The line is `:info`, below `config/test.exs`'s `:warning` primary level; a module level
  # lets it past for the module that logs it.
  setup do
    Logger.put_module_level(Selection, :info)
    on_exit(fn -> Logger.delete_module_level(Selection) end)
    :ok
  end

  defp runner(tenant_id), do: fixture(:stage_runner, %{tenant_id: tenant_id})

  defp put_row(runner, changes) do
    {:ok, {1, _}} =
      Repo.with_tenant(runner.tenant_id, fn ->
        Repo.update_all(from(r in Runner, where: r.id == ^runner.id), set: changes)
      end)

    :ok
  end

  defp candidate(tenant_id), do: %{tenant_id: tenant_id, story_id: Ecto.UUID.generate()}

  defp noted(fun) do
    log = capture_log([level: :info], fun)
    log |> String.split("\n") |> Enum.filter(&(&1 =~ "earliest_usage_reset="))
  end

  defp logged_reset(line) do
    [_, at] = Regex.run(~r/earliest_usage_reset=(\S+)/, line)
    {:ok, at, 0} = DateTime.from_iso8601(at)
    at
  end

  describe "note_no_runner/3 (AC-44.6.8)" do
    test "names the earliest reset among the tenant's exhausted runners, once per tenant" do
      tenant = fixture(:stage_tenant)
      [r1, r2, _fresh] = for _ <- 1..3, do: runner(tenant.id)
      soon = DateTime.add(DateTime.utc_now(), 600, :second)
      later = DateTime.add(soon, 3_600, :second)

      :ok = Usage.record(tenant.id, r1.id, %{exhausted: true, resets_at: later})
      :ok = Usage.record(tenant.id, r2.id, %{exhausted: true, resets_at: soon})

      lines =
        noted(fn ->
          cache = Selection.note_no_runner(%{}, "Pass", candidate(tenant.id))
          assert Selection.note_no_runner(cache, "Pass", candidate(tenant.id)) == cache
        end)

      assert [line] = lines
      assert line =~ "Pass: "
      assert line =~ "2 exhausted runner(s) in tenant"
      assert DateTime.compare(logged_reset(line), soon) == :eq
    end

    test "a FULL exhausted runner contributes its reset, a REVOKED one does not" do
      tenant = fixture(:stage_tenant)
      [full, revoked] = for _ <- 1..2, do: runner(tenant.id)
      soon = DateTime.add(DateTime.utc_now(), 600, :second)
      later = DateTime.add(soon, 3_600, :second)

      :ok = Usage.record(tenant.id, full.id, %{exhausted: true, resets_at: later})
      :ok = Usage.record(tenant.id, revoked.id, %{exhausted: true, resets_at: soon})
      :ok = put_row(full, in_flight: 1, max_sessions: 1)
      :ok = put_row(revoked, revoked_at: DateTime.utc_now())

      assert [line] = noted(fn -> Selection.note_no_runner(%{}, "Pass", candidate(tenant.id)) end)
      assert line =~ "1 exhausted runner(s) in tenant"
      assert DateTime.compare(logged_reset(line), later) == :eq
    end

    test "logs nothing when the tenant has no exhausted runner, and still notes the tenant" do
      tenant = fixture(:stage_tenant)
      runner(tenant.id)
      key = {:no_runner_noted, tenant.id}

      assert [] =
               noted(fn ->
                 assert %{^key => true} =
                          Selection.note_no_runner(%{}, "Pass", candidate(tenant.id))
               end)
    end

    test "another tenant's exhausted runner is not this tenant's fact (tenant isolation)" do
      tenant_a = fixture(:stage_tenant)
      tenant_b = fixture(:stage_tenant)
      runner(tenant_a.id)
      b = runner(tenant_b.id)
      :ok = Usage.record(tenant_b.id, b.id, %{exhausted: true})

      assert [] = noted(fn -> Selection.note_no_runner(%{}, "Pass", candidate(tenant_a.id)) end)
    end
  end
end
