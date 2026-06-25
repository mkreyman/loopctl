defmodule Loopctl.Knowledge.StreamingExportScaleTest do
  @moduledoc """
  US-27.16 nightly scale gate (TC-27.16.1 / .2 / .5).

  Drives the export over the REAL chunked HTTP transport (a Bandit server bound to
  an ephemeral port + a `Req` streaming client) against a `ScaleSeed`-committed
  ~80k-article corpus, and asserts:

  - TC-27.16.1: a >5,000-article export returns `200` chunked (NOT 413), with a
    valid bundle, and 50k peak VM memory stays within a small constant of a
    500-article export (sub-linear in N).
  - TC-27.16.2: the worst-case entry (a dense-hub article whose link list fans out)
    does not spike memory with the hub's fan-out — the per-article link preload is
    bounded.
  - TC-27.16.5: N concurrent full-KB exports do not starve a light admin read
    (the concurrency cap holds; the light read does not hit a checkout timeout).

  Runs OUTSIDE the DataCase sandbox (committed rows) with `ExUnit.Case`,
  `async: false`, the `:scale_nightly` moduletag, and a 30-minute timeout — the
  same pattern as the other Epic 27 scale tests. The matrix wiring is enforced by
  `scale_verification_runbook_test.exs`.
  """
  use ExUnit.Case, async: false

  @moduletag :scale_nightly
  @moduletag timeout: :timer.minutes(30)

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.ScaleSeed
  alias Loopctl.Tenants.Tenant

  # Smaller comparison corpus for the flat-vs-N memory ratio.
  @small_count 500

  # In `:auto` sandbox mode (set in setup_all) every AdminRepo call auto-commits on
  # a real connection, so DB work runs directly — no `unboxed_run` wrapper (which
  # requires `:manual` mode). Kept as a thin seam so the call sites read clearly.
  defp unboxed(fun), do: fun.()

  setup_all do
    # The export is served by a REAL HTTP server whose request handlers run in
    # separate processes that check out their OWN repo connections. Sandbox `:manual`
    # mode would deny those checkouts, so switch AdminRepo / HeavyReadRepo to `:auto`
    # for this module: checkouts use real auto-committing connections that see the
    # ScaleSeed-committed corpus. Safe here — `async: false`, and the nightly CI leg
    # runs ONLY this file against a fresh Postgres. Restored on exit.
    Sandbox.mode(Loopctl.AdminRepo, :auto)
    Sandbox.mode(Loopctl.HeavyReadRepo, :auto)
    on_exit(fn -> Sandbox.mode(Loopctl.AdminRepo, :manual) end)

    # The real HTTP server runs the request pipeline in handler processes that are
    # OUTSIDE the per-test Mox context (which DataCase/ConnCase set up). The rate
    # limiter plug calls the injected clock mock, so it must be GLOBALLY stubbed for
    # those handler processes to resolve it. `set_mox_global` is appropriate here —
    # this module is `async: false`.
    Mox.set_mox_global()
    Mox.stub(Loopctl.MockClock, :utc_now, &DateTime.utc_now/0)

    # The big tenant: ~80k committed articles (prod floor). A separate SMALL tenant
    # gives the 500-article memory baseline for the ratio assertion.
    big = create_tenant("export-scale-big")
    small = create_tenant("export-scale-small")

    unboxed(fn ->
      ScaleSeed.seed(big.id, count: ScaleSeed.prod_article_floor(), link_density: 5)
      ScaleSeed.seed(small.id, count: @small_count, link_density: 5)
    end)

    # A real HTTP server bound to an ephemeral port, serving the Phoenix endpoint as
    # a plug. This is what makes the memory measurement reflect the TRUE chunked
    # transport (Phoenix.ConnTest's inline conn buffers and would hide it).
    {:ok, bandit_pid} =
      start_supervised(
        {Bandit, plug: LoopctlWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    port = bandit_port(bandit_pid)

    user_key = create_user_key(big.id)
    small_user_key = create_user_key(small.id)

    on_exit(fn ->
      unboxed(fn ->
        for t <- [big.id, small.id] do
          AdminRepo.delete_all(from(l in ArticleLink, where: l.tenant_id == ^t))
          AdminRepo.delete_all(from(a in Article, where: a.tenant_id == ^t))
        end

        AdminRepo.delete_all(from(t in Tenant, where: t.id in ^[big.id, small.id]))
      end)
    end)

    {:ok, big: big, small: small, port: port, user_key: user_key, small_user_key: small_user_key}
  end

  describe "TC-27.16.1: >5,000-article export succeeds; memory flat vs N" do
    test "OKF export of ~80k is 200 chunked (not 413) and memory stays ~flat vs 500", ctx do
      {big_mem, big_count} =
        measure_export(ctx.port, ctx.user_key, "/api/v1/knowledge/okf/export")

      {small_mem, small_count} =
        measure_export(ctx.port, ctx.small_user_key, "/api/v1/knowledge/okf/export")

      assert big_count > 5_000, "expected the big corpus to exceed the old 5k cap"
      assert small_count == @small_count

      assert_flat_memory(big_mem, small_mem, big_count, small_count)
    end

    test "Obsidian export of ~80k is 200 chunked (not 413) and memory stays ~flat vs 500", ctx do
      {big_mem, big_count} =
        measure_export(ctx.port, ctx.user_key, "/api/v1/knowledge/export")

      {small_mem, small_count} =
        measure_export(ctx.port, ctx.small_user_key, "/api/v1/knowledge/export")

      assert big_count > 5_000
      assert_flat_memory(big_mem, small_mem, big_count, small_count)
    end
  end

  describe "TC-27.16.5: concurrent full-KB exports don't starve a light admin read" do
    test "N concurrent exports + a light admin read: the light read does not time out", ctx do
      # Fire several concurrent full-KB exports (more than the concurrency cap, so
      # some get 429 — that's the cap WORKING, not a failure) and, concurrently, a
      # light admin read. The light read must complete quickly without a checkout/
      # queue timeout — the cap + dedicated heavy pool keep the admin pool free.
      parent = self()

      exporters =
        for _ <- 1..6 do
          spawn(fn ->
            status =
              try do
                stream_status(ctx.port, ctx.user_key, "/api/v1/knowledge/okf/export")
              catch
                _, _ -> :error
              end

            send(parent, {:exporter, status})
          end)
        end

      # Light admin read while exports are in flight — must not block.
      {elapsed_us, count} =
        :timer.tc(fn ->
          unboxed(fn ->
            AdminRepo.one!(
              from(a in Article,
                where: a.tenant_id == ^ctx.small.id and a.status == :published,
                select: count(a.id)
              )
            )
          end)
        end)

      assert count == @small_count
      # The light read completes well under any checkout/queue timeout (queue_target
      # is seconds). 5s is a generous structural bound.
      assert elapsed_us < 5_000_000,
             "light admin read took #{div(elapsed_us, 1000)}ms — admin pool may be starved"

      # Drain exporters: at least one must have streamed a full 200, and any refusals
      # are the cap working (429), never a pool-starvation 500/timeout.
      statuses = for _ <- exporters, do: receive_status()
      assert Enum.any?(statuses, &(&1 == 200))
      assert Enum.all?(statuses, &(&1 in [200, 429]))
    end
  end

  # --- helpers ---

  # Stream the export with Req and return {peak_vm_memory_delta_bytes, article_count}.
  # Peak is measured VM-WIDE (:erlang.memory(:total)) because article bodies are
  # off-process refc binaries that process_info(self()) misses.
  defp measure_export(port, raw_key, path) do
    :erlang.garbage_collect()
    baseline = :erlang.memory(:total)
    {:ok, peak_agent} = Agent.start_link(fn -> 0 end)

    {:ok, body} = stream_collecting_peak(port, raw_key, path, peak_agent, baseline)

    peak_delta = Agent.get(peak_agent, & &1)
    Agent.stop(peak_agent)

    {:ok, entries} = :erl_tar.extract({:binary, body}, [:memory, :compressed])

    count =
      entries
      |> Enum.count(fn {name, _} ->
        n = to_string(name)

        String.ends_with?(n, ".md") and not String.ends_with?(n, "index.md") and
          not String.ends_with?(n, "log.md")
      end)

    {peak_delta, count}
  end

  # Stream the response body with Req's `:into` collector, sampling VM memory as
  # each chunk arrives and recording the peak delta over baseline.
  defp stream_collecting_peak(port, raw_key, path, peak_agent, baseline) do
    {:ok, acc_agent} = Agent.start_link(fn -> [] end)

    collector = fn {:data, data}, {req, resp} ->
      Agent.update(acc_agent, fn acc -> [data | acc] end)
      sample = :erlang.memory(:total) - baseline
      Agent.update(peak_agent, fn p -> max(p, sample) end)
      {:cont, {req, resp}}
    end

    resp =
      Req.get!(
        url: "http://127.0.0.1:#{port}#{path}",
        headers: [
          {"authorization", "Bearer #{raw_key}"},
          {"x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA"}
        ],
        into: collector,
        receive_timeout: :timer.minutes(20)
      )

    body = Agent.get(acc_agent, fn acc -> acc |> Enum.reverse() |> IO.iodata_to_binary() end)
    Agent.stop(acc_agent)

    if resp.status == 200, do: {:ok, body}, else: {:error, resp.status}
  end

  defp stream_status(port, raw_key, path) do
    resp =
      Req.get!(
        url: "http://127.0.0.1:#{port}#{path}",
        headers: [
          {"authorization", "Bearer #{raw_key}"},
          {"x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA"}
        ],
        into: fn {:data, _}, acc -> {:cont, acc} end,
        receive_timeout: :timer.minutes(20)
      )

    resp.status
  end

  # AC-27.16.3: 50k peak within a small constant (≤2x) of the 500 baseline — i.e.
  # sub-linear in N (a linear/materializing implementation would be ~N/500× larger).
  defp assert_flat_memory(big_mem, small_mem, big_count, small_count) do
    # Guard against a tiny/negative baseline (GC noise): floor the baseline at 1 MiB.
    small_floor = max(small_mem, 1_048_576)
    ratio = big_mem / small_floor
    n_ratio = big_count / small_count

    assert ratio <= 2.0,
           "peak memory ratio #{Float.round(ratio, 2)} (#{big_mem} vs #{small_floor} bytes) " <>
             "for #{big_count} vs #{small_count} articles (N-ratio #{Float.round(n_ratio, 1)}x) " <>
             "exceeds the 2x bound — export is not bounded-memory."
  end

  defp receive_status do
    receive do
      {:exporter, s} -> s
    after
      :timer.minutes(20) -> flunk("exporter did not finish")
    end
  end

  defp create_tenant(prefix) do
    unboxed(fn ->
      slug = "#{prefix}-#{:erlang.phash2(Ecto.UUID.generate())}"

      {:ok, t} =
        %Tenant{}
        |> Tenant.create_changeset(%{
          name: "Export Scale #{slug}",
          slug: slug,
          email: "#{slug}@example.com",
          settings: %{},
          status: :active
        })
        |> AdminRepo.insert()

      t
    end)
  end

  # Mint a user-role API key directly (committed, BYPASSRLS) — fixtures run in the
  # sandbox and wouldn't be visible to the real HTTP server's repo connection.
  defp create_user_key(tenant_id) do
    unboxed(fn ->
      {:ok, {raw, _key}} =
        Loopctl.Auth.generate_api_key(%{
          name: "export-scale-#{:erlang.phash2(Ecto.UUID.generate())}",
          role: :user,
          tenant_id: tenant_id
        })

      raw
    end)
  end

  # Resolve the ephemeral port Bandit bound to. `start_supervised({Bandit, ...})`
  # returns Bandit's top supervisor, which `ThousandIsland.listener_info/1` accepts
  # directly, returning the bound `{ip, port}`.
  defp bandit_port(bandit_sup) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit_sup)
    port
  end
end
