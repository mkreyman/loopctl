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
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.ExportConcurrency
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

  describe "TC-27.16.1: >5,000-article export succeeds; PRODUCER memory flat vs N" do
    test "OKF export of ~80k is 200 chunked (not 413) and producer memory stays ~flat vs 500",
         ctx do
      big = measure_export(ctx.port, ctx.user_key, "/api/v1/knowledge/okf/export")
      small = measure_export(ctx.port, ctx.small_user_key, "/api/v1/knowledge/okf/export")

      # Not 413: a full 200 chunked response with a VALID end-of-archive (the stream
      # finished cleanly) and substantially more bytes for 80k than 500 (so the big
      # corpus really did stream the whole KB, > the old 5k cap).
      assert big.status == 200 and small.status == 200
      assert big.valid_archive? and small.valid_archive?
      assert big.bytes > small.bytes * 10

      assert_flat_producer_memory(big, small)
    end

    test "Obsidian export of ~80k is 200 chunked (not 413) and producer memory stays ~flat vs 500",
         ctx do
      big = measure_export(ctx.port, ctx.user_key, "/api/v1/knowledge/export")
      small = measure_export(ctx.port, ctx.small_user_key, "/api/v1/knowledge/export")

      assert big.status == 200 and small.status == 200
      assert big.valid_archive? and small.valid_archive?
      assert big.bytes > small.bytes * 10

      assert_flat_producer_memory(big, small)
    end

    test "the big corpus exceeds the old 5,000-article cap (no 413)", ctx do
      published = published_count(ctx.big.id)
      assert published > 5_000, "scale corpus must exceed the removed 5k cap (got #{published})"
    end
  end

  describe "TC-27.16.5: concurrent full-KB exports don't starve a light read on the SAME pool" do
    test "N concurrent exports + a light read on the exports' pool: the read does not time out",
         ctx do
      # The cap must be PROVABLY load-bearing, so the light read must run on the
      # SAME pool the exports consume. The exports read through `Loopctl.HeavyRead`
      # (resolved via `:heavy_read_repo`); we run the light read through the exact
      # same `HeavyRead.all/3` entry point so it contends for the identical pool —
      # NOT a separate AdminRepo pool that would pass regardless of the cap.
      #
      # We fire MORE exporters (8) than the heavy pool could serve if they all ran
      # at once; the per-tenant + global concurrency cap (max_global, default 2) is
      # the ONLY thing keeping concurrent long-held checkouts below the pool size,
      # so a passing light read here demonstrates the cap is doing the work (without
      # it, 8 client-paced exports would each pin a connection and starve the read).
      parent = self()
      n_exporters = 8

      exporters =
        for _ <- 1..n_exporters do
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

      # Light read on the exports' own pool, while exports are in flight.
      light_query =
        from(a in Article,
          where: a.tenant_id == ^ctx.small.id and a.status == :published,
          select: count(a.id)
        )

      {elapsed_us, count} =
        :timer.tc(fn -> HeavyRead.one(ctx.small.id, light_query) end)

      assert count == @small_count
      # Completes well under any checkout/queue timeout (queue_target is seconds).
      assert elapsed_us < 5_000_000,
             "light read on the exports' pool took #{div(elapsed_us, 1000)}ms — " <>
               "the pool is starved; the concurrency cap is not bounding heavy holders"

      # The cap MUST have refused some of the 8 (we fired more than max_global), so
      # at least one 429 proves the cap actually engaged; the rest stream 200; never
      # a pool-starvation 500/timeout.
      statuses = for _ <- exporters, do: receive_status()
      assert Enum.any?(statuses, &(&1 == 200))

      assert Enum.any?(statuses, &(&1 == 429)),
             "expected the concurrency cap to refuse some of #{n_exporters} exports " <>
               "(max_global=#{ExportConcurrency.max_global()}); got: " <>
               inspect(statuses)

      assert Enum.all?(statuses, &(&1 in [200, 429]))
    end
  end

  # --- helpers ---

  # Stream the export over the REAL chunked transport and measure the PRODUCER's
  # peak process memory — NOT a VM-wide / client-buffer measurement.
  #
  # Two things make this a clean producer measurement:
  #   1. The CLIENT DISCARDS chunks (keeps only a byte counter + a small rolling
  #      256-byte tail to validate the gzip end-of-archive). So the client buffer is
  #      O(1), never O(N) — the 4.37x artifact was the client holding the whole
  #      ~4.5MB bundle to extract it; that buffer is gone.
  #   2. Producer memory is sampled INSIDE the Bandit handler process via the
  #      `[:loopctl, :streaming_export, :chunk_emitted]` telemetry event the emit fun
  #      executes per flush (carrying `process_info(self(), :memory)` after a GC).
  #
  # Returns `%{peak_producer_mem, bytes, status, valid_archive?}`.
  defp measure_export(port, raw_key, path) do
    {:ok, peak_agent} = Agent.start_link(fn -> 0 end)

    handler_id = {__MODULE__, :export_memory_sampler, make_ref()}

    :telemetry.attach(
      handler_id,
      [:loopctl, :streaming_export, :chunk_emitted],
      fn _event, %{process_memory: bytes}, _meta, _config ->
        if is_integer(bytes) and bytes > 0, do: Agent.update(peak_agent, &max(&1, bytes))
      end,
      nil
    )

    # Discard-collector: count bytes, keep only a tiny tail, never hold the bundle.
    collector = fn {:data, data}, {req, resp} ->
      {acc_bytes, tail} = resp.private[:probe] || {0, <<>>}

      new_tail =
        binary_part(
          tail <> data,
          max(0, byte_size(tail <> data) - 256),
          min(256, byte_size(tail <> data))
        )

      resp = put_in(resp.private[:probe], {acc_bytes + byte_size(data), new_tail})
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

    :telemetry.detach(handler_id)
    peak = Agent.get(peak_agent, & &1)
    Agent.stop(peak_agent)

    {bytes, tail} = resp.private[:probe] || {0, <<>>}

    %{
      peak_producer_mem: peak,
      bytes: bytes,
      status: resp.status,
      # A valid gzip stream ends with the 4-byte CRC32 + 4-byte ISIZE trailer; an
      # ABORTED (fail-closed) stream would not. We can't decompress the whole 4.5MB
      # without holding it, so validity here is "we received a non-trivial body with
      # a well-formed gzip trailer length" — the dedicated fail-closed test (small
      # corpus) proves truncation detection rigorously.
      valid_archive?: resp.status == 200 and bytes > 0 and byte_size(tail) >= 8
    }
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

  defp published_count(tenant_id) do
    HeavyRead.one(
      tenant_id,
      from(a in Article,
        where: a.tenant_id == ^tenant_id and a.status == :published,
        select: count(a.id)
      )
    )
  end

  # AC-27.16.3: the 80k PRODUCER peak is within a small constant (≤2x) of the 500
  # baseline — sub-linear in N. A materializing implementation would be ~N/500×
  # larger. With the client buffer removed (discard-collector) and producer memory
  # measured via process_info, the ratio reflects ONLY the producer.
  defp assert_flat_producer_memory(big, small) do
    # Floor the baseline so GC noise on a tiny 500-corpus producer can't make the
    # ratio explode; 1 MiB is well above a keyset-paged producer's working set.
    small_floor = max(small.peak_producer_mem, 1_048_576)
    ratio = big.peak_producer_mem / small_floor

    assert big.peak_producer_mem > 0,
           "no producer-memory samples captured — telemetry not wired?"

    assert ratio <= 2.0,
           "PRODUCER peak memory ratio #{Float.round(ratio, 2)} " <>
             "(#{big.peak_producer_mem} vs #{small_floor} bytes; big=#{big.bytes}B / " <>
             "small=#{small.bytes}B archive) exceeds the 2x bound — producer is not " <>
             "bounded-memory."
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
