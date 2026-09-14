defmodule LoopctlWeb.RunnerUnsupportedKindsTest do
  @moduledoc """
  Contract 1.5.0: a machine that answered `kind_not_supported` is VISIBLE as barred, on both
  runner reads.

  Why it needs its own module: `implement` is the only dispatchable kind, so one such reply
  removes a machine from all work for the life of its `runners` row. With nothing exposing
  that, an operator sees a connected, unrevoked, idle runner and has no way to tell "barred"
  from "nothing to do" — and a runner that maps a transient local condition to that reason
  bricks itself until a human revokes and re-enrols it.

  ## Why `async: false`

  The auth pipeline resolves the API key through `Loopctl.AdminRepo` while the ledger row this
  read derives from is written on the RLS `Loopctl.Repo`. Those are separate sandbox
  connections that cannot see each other's uncommitted rows, so the TENANT, the KEY and the
  RUNNER are committed and swept at the module boundary, while the story and the dispatch row
  stay inside the `Repo` sandbox. A committed row is visible to every concurrently running
  async test, which is what makes this module serial. The derivation itself is tested without
  a key or a socket in `Loopctl.Runners.DispatchLedgerTest`.
  """

  use LoopctlWeb.ConnCase, async: false

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Runners
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.Presence

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp operator_ctx do
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    {_raw, runner} = fixture(:committed_runner, %{name: "minis", tenant_id: tenant.id})
    raw_key = fixture(:committed_operator_key, %{tenant_id: tenant.id})
    %{tenant: tenant, runner: runner, operator_key: raw_key}
  end

  # A real refusal through the ledger, not a hand-written row: the read must derive from the
  # same evidence a runner's reply produces.
  defp refuse_kind(runner, reason) do
    story = fixture(:ledger_story, %{tenant_id: runner.tenant_id, claim_epoch: 0})

    {:ok, dispatch} =
      RunnerContract.cast_dispatch(build(:runner_dispatch, %{"story_id" => story.id}))

    {:ok, record} = DispatchLedger.record_sent(runner.tenant_id, runner.id, dispatch)

    {:ok, reply} =
      RunnerContract.cast_dispatch_reply(%{
        "dispatch_id" => record.dispatch_id,
        "claim_epoch" => record.claim_epoch,
        "decision" => "refused",
        "reason" => reason
      })

    {:ok, _} = DispatchLedger.record_reply(runner.tenant_id, runner.id, reply)
    :ok
  end

  defp track(runner) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)

    meta = %{machine: runner.name, joined_at: DateTime.utc_now(), runner_id: runner.id}
    {:ok, _ref} = Presence.track(pid, Runners.pool_topic(runner.tenant_id), runner.name, meta)
    pid
  end

  test "a barred kind shows on the registry and on the pool", %{conn: conn} do
    ctx = operator_ctx()
    track(ctx.runner)
    :ok = refuse_kind(ctx.runner, "kind_not_supported")

    authed = auth(conn, ctx.operator_key)

    assert [listed] = json_response(get(authed, ~p"/api/v1/runners"), 200)["runners"]
    assert listed["id"] == ctx.runner.id
    assert listed["unsupported_kinds"] == ["implement"]
    # The rest of the runner's own rendering is unchanged by the added field.
    assert listed["name"] == "minis"
    assert listed["max_sessions"] == ctx.runner.max_sessions

    assert [entry] = json_response(get(authed, ~p"/api/v1/runners/pool"), 200)["runners"]
    assert entry["runner_id"] == ctx.runner.id
    assert entry["unsupported_kinds"] == ["implement"]
  end

  test "a runner that has refused nothing shows an empty list, not a missing field",
       %{conn: conn} do
    ctx = operator_ctx()
    track(ctx.runner)

    authed = auth(conn, ctx.operator_key)

    assert [listed] = json_response(get(authed, ~p"/api/v1/runners"), 200)["runners"]
    assert listed["unsupported_kinds"] == []

    assert [entry] = json_response(get(authed, ~p"/api/v1/runners/pool"), 200)["runners"]
    assert entry["unsupported_kinds"] == []
  end

  test "an ordinary refusal bars nothing", %{conn: conn} do
    ctx = operator_ctx()
    :ok = refuse_kind(ctx.runner, "draining")

    authed = auth(conn, ctx.operator_key)

    assert [listed] = json_response(get(authed, ~p"/api/v1/runners"), 200)["runners"]
    assert listed["unsupported_kinds"] == []
  end

  test "one tenant's barred runner is invisible to another", %{conn: conn} do
    ctx = operator_ctx()
    :ok = refuse_kind(ctx.runner, "kind_not_supported")

    other = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    {_raw, theirs} = fixture(:committed_runner, %{name: "blockit", tenant_id: other.id})
    other_key = fixture(:committed_operator_key, %{tenant_id: other.id})

    assert [listed] =
             conn
             |> auth(other_key)
             |> get(~p"/api/v1/runners")
             |> json_response(200)
             |> Map.fetch!("runners")

    assert listed["id"] == theirs.id
    assert listed["unsupported_kinds"] == []
  end
end
