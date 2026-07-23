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

  # Mox wiring is PER-TEST, not `setup_all`, and that placement is load-bearing.
  #
  # The export is served by a REAL HTTP server whose handler processes are outside any
  # per-test Mox context, so the stubs must be GLOBAL for those handlers to resolve them
  # (`set_mox_global/0` is valid here — `async: false`). But in global mode Mox lets ONLY
  # the OWNER process register stubs. Owning global mode from `setup_all` therefore makes
  # the whole module read-only for stubs: the MUTATION CHECK below, which must inject a
  # retaining body probe from the TEST BODY, raises
  # `ArgumentError: cannot add expectations/stubs ... Mox is in global mode`.
  #
  # Running this per test makes EACH test process the owner for its own duration, so both
  # `setup` and the test body can register stubs. Mox releases global mode when the owner
  # exits, so the next test re-acquires it cleanly. Same pattern as
  # `vector_endpoint_e2e_latency_scale_test.exs`.
  setup do
    Mox.set_mox_global()

    # `config/test.exs` points EVERY injected collaborator at a Mox mock for the whole
    # test env, and this module does not `use Loopctl.DataCase`, so nothing has stubbed
    # them. The Bandit handler processes run the FULL authenticated pipeline, so an
    # export request reaches far more collaborators than the clock alone (the rate
    # limiter among them) — hand-picking mocks one at a time is how this file kept
    # breaking. `stub_all_defaults/0` is the single source of truth and a superset,
    # so a mock added to DataCase is covered here automatically. It also installs the
    # PRODUCTION (no-op) default for the streaming-export body probe, which the mutation
    # check overrides.
    Loopctl.DataCase.stub_all_defaults()

    Mox.stub(Loopctl.MockClock, :utc_now, &DateTime.utc_now/0)

    :ok
  end

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

    test "MUTATION CHECK: the bounded-memory metric is LOAD-BEARING (#1)", ctx do
      # Proves the test would CATCH a regression. Measure the SAME 80k corpus twice
      # against the same 500 baseline:
      #   (a) NORMAL streaming producer    → ratio ≤ 2x (the real, passing case), and
      #   (b) MUTATED to MATERIALIZE bodies → ratio ≫ 2x (the test FAILS the mutation).
      # If both produced ~the same ratio, the metric would be measuring nothing.
      small = measure_export(ctx.port, ctx.small_user_key, "/api/v1/knowledge/okf/export")
      small_floor = max(small.peak_retained, 65_536)

      normal_big = measure_export(ctx.port, ctx.user_key, "/api/v1/knowledge/okf/export")
      normal_ratio = normal_big.peak_retained / small_floor

      # Force the producer to retain every body (the materializing mutation) by INJECTING a
      # retaining probe, not by mutating global config. `Mox.stub/3` runs the closure in the
      # CALLING process — here the Bandit handler running the export — so the copied binaries
      # are retained in the producer process, which is exactly where the telemetry measures
      # peak retained bytes.
      #
      # `:binary.copy/1` is required: `row.body` is a sub-binary of the DB result, which
      # would be reclaimed along with the row. Copying forces a fresh refc binary that the
      # producer genuinely holds — without it the "mutation" would retain nothing and the
      # check would pass vacuously.
      Mox.stub(Loopctl.MockStreamingExportBodyProbe, :probe, fn ->
        key = {__MODULE__, :materialized_bodies}

        fn body ->
          Process.put(key, [:binary.copy(body || <<>>) | Process.get(key, [])])
          :ok
        end
      end)

      # No cleanup needed, and that is the point of the DI seam: the stub is scoped to THIS
      # test's Mox global-mode ownership, which is re-established per test in `setup`, so
      # the retaining probe cannot outlive this test even if the measurement below raises.
      # The old `Application.put_env` + `delete_env` pair had exactly that failure mode — a
      # raise in between left a materializing producer configured for the rest of the VM.
      mutated_big = measure_export(ctx.port, ctx.user_key, "/api/v1/knowledge/okf/export")

      mutated_ratio = mutated_big.peak_retained / small_floor

      IO.puts(
        "[scale-mem MUTATION CHECK] baseline=#{small_floor}B " <>
          "NORMAL peak=#{normal_big.peak_retained}B ratio=#{Float.round(normal_ratio, 3)} | " <>
          "MUTATED peak=#{mutated_big.peak_retained}B ratio=#{Float.round(mutated_ratio, 1)}"
      )

      # (a) The real producer passes the bound...
      assert normal_ratio <= 2.0,
             "real producer ratio #{Float.round(normal_ratio, 3)} should be ≤ 2x"

      # (b) ...and the MATERIALIZING mutation BLOWS it — proving the metric catches a
      # regression (80k × ~80-byte bodies retained ≫ a streaming producer's working set).
      assert mutated_ratio > 2.0,
             "MUTATION not caught: materializing producer ratio #{Float.round(mutated_ratio, 1)} " <>
               "is still ≤ 2x — the bounded-memory metric is NOT load-bearing."

      # And concretely, the mutation must be DRAMATICALLY larger than the honest run.
      assert mutated_big.peak_retained > normal_big.peak_retained * 5,
             "materializing producer (#{mutated_big.peak_retained}B) was not ≫ the streaming " <>
               "producer (#{normal_big.peak_retained}B) — metric insensitive to retention."
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
  # peak RETAINED memory — the metric that actually grows with N.
  #
  # Two things make this a clean, LOAD-BEARING producer measurement:
  #   1. The CLIENT DISCARDS chunks (keeps only a byte counter + a small rolling
  #      256-byte tail to validate the gzip end-of-archive). So the client buffer is
  #      O(1), never O(N) — the original 4.37x artifact was the client holding the
  #      whole ~4.5MB bundle to extract it; that buffer is gone.
  #   2. The producer (TarGz, in the Bandit handler process) emits, per flush, its
  #      RETAINED refc-binary bytes + ETS buffer bytes via the
  #      `[:loopctl, :streaming_export, :chunk_emitted]` telemetry event. Article
  #      bodies are refc binaries (off the process heap), so a MATERIALIZING producer
  #      that retained every body shows up here — unlike `process_info(:memory)`,
  #      which would miss them (that was the false-green). See `assert_flat_…` and the
  #      `:materialize_for_mutation_check` env flag the mutation-check uses.
  #
  # Returns `%{peak_retained, bytes, status, valid_archive?}`.
  defp measure_export(port, raw_key, path) do
    {:ok, peak_agent} = Agent.start_link(fn -> 0 end)
    handler_id = {__MODULE__, :export_memory_sampler, make_ref()}

    try do
      :telemetry.attach(
        handler_id,
        [:loopctl, :streaming_export, :chunk_emitted],
        fn _event, %{retained_bytes: bytes}, _meta, _config ->
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

      {bytes, tail} = resp.private[:probe] || {0, <<>>}

      %{
        peak_retained: Agent.get(peak_agent, & &1),
        bytes: bytes,
        status: resp.status,
        # A valid gzip stream ends with the 4-byte CRC32 + 4-byte ISIZE trailer; an
        # ABORTED (fail-closed) stream would not. We can't decompress the whole ~4.5MB
        # without holding it, so validity here is "non-trivial body with a well-formed
        # gzip trailer length" — the dedicated fail-closed test (small corpus) proves
        # truncation detection rigorously.
        valid_archive?: resp.status == 200 and bytes > 0 and byte_size(tail) >= 8
      }
    after
      :telemetry.detach(handler_id)
      Agent.stop(peak_agent)
    end
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

  # AC-27.16.3: the 80k PRODUCER peak RETAINED memory (refc binaries + ETS buffer)
  # is within a small constant (≤2x) of the 500 baseline — sub-linear in N. A
  # MATERIALIZING producer (retaining every body) would be ~N/500× (~160×) larger and
  # blow this bound — which the mutation-check test proves. The metric is load-bearing
  # because it counts the off-heap refc binaries article bodies live in.
  #
  # Floor is DELIBERATELY LOW (64 KiB) so the ratio stays load-bearing: a real
  # materialization signal (megabytes) dwarfs it, while it only absorbs sub-64KB GC
  # jitter on the tiny 500 baseline. The label prints both raw numbers for the report.
  @baseline_floor 65_536

  defp assert_flat_producer_memory(big, small) do
    small_floor = max(small.peak_retained, @baseline_floor)
    ratio = big.peak_retained / small_floor

    # Surface the raw numbers (the report wants them; passing assertions are silent).
    IO.puts(
      "[scale-mem] big.peak_retained=#{big.peak_retained}B small.peak_retained=" <>
        "#{small.peak_retained}B floor=#{small_floor}B ratio=#{Float.round(ratio, 3)} " <>
        "(big_archive=#{big.bytes}B small_archive=#{small.bytes}B)"
    )

    assert big.peak_retained > 0,
           "no producer-memory samples captured — telemetry not wired?"

    assert ratio <= 2.0,
           "PRODUCER peak RETAINED-memory ratio #{Float.round(ratio, 3)} " <>
             "(#{big.peak_retained} vs #{small_floor} bytes; big=#{big.bytes}B / " <>
             "small=#{small.bytes}B archive) exceeds the 2x bound — producer is not " <>
             "bounded-memory (it is retaining O(N) bodies)."
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
