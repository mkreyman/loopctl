defmodule Loopctl.Knowledge.VectorSearchUnderFillScaleTest do
  @moduledoc """
  US-27.6b scale gate (TC-27.6b.2 at scale + AC-27.6b.2 / AC-27.6b.4):

    * **Dense-hub under-fill at prod scale** — on a real ~80k-row, densely-linked
      corpus (the conditions that produce the silent fast-green-but-wrong empty
      result the epic exists to fix), a hub whose nearest pool is filled but mostly
      already-linked must (a) return fewer than the requested limit AND (b) fire the
      `[:loopctl, :knowledge, :vector_search, :under_fill]` telemetry signal with a
      full pool — proving the detection works against the real planner + HNSW recall,
      not only the small async-suite pool.

    * **ef_search parity (AC-27.6b.4)** — whatever `hnsw.ef_search` is EFFECTIVE must
      be identical on the scale-gate connection and a prod-shaped connection, asserted
      by `SHOW hnsw.ef_search` on each (NOT by comparing `:parameters` config blobs).
      ef_search is never SET today (pgvector default 40); this pins it so a future
      `ALTER ROLE … SET hnsw.ef_search` on prod (US-27.11) can't silently diverge from
      the gate (ties to US-27.8).

  Seeds ~80k committed rows via `Loopctl.Knowledge.ScaleSeed`, so it is
  `:scale_nightly` and wired into `.github/workflows/ci.yml`'s `scale_file` matrix
  (enforced by `scale_verification_runbook_test.exs`).
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.HeavyReadRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.ScaleSeed
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.PlanAssertions
  alias Loopctl.TelemetryEvents
  alias Loopctl.Tenants.Tenant

  import Ecto.Query

  @moduletag :scale_nightly
  @moduletag timeout: :timer.minutes(30)

  defp unboxed(fun), do: Sandbox.unboxed_run(AdminRepo, fun)

  setup do
    # `config/test.exs` points EVERY injected collaborator at a Mox mock for the whole
    # test env, and this module does not `use Loopctl.DataCase`, so nothing has stubbed
    # them. Any call reaching an unstubbed mock raises `Mox.UnexpectedCallError` in the
    # nightly scale job. Install the SAME permissive default set DataCase gives every
    # other test, rather than hand-picking one mock at a time: the narrow
    # `stub_embedding_read_path/0` left `MockEmbeddingConcurrency` unstubbed, which is
    # exactly how the nightly broke. `stub_all_defaults/0` is a superset of it and the
    # single source of truth, so a mock added to DataCase is covered here automatically.
    # The stub bodies are closures — an unused stub never executes, so this is inert for
    # collaborators a given scale file never touches.
    Loopctl.DataCase.stub_all_defaults()

    tenant =
      unboxed(fn ->
        slug = "vuf-scale-#{:erlang.phash2(Ecto.UUID.generate())}"

        {:ok, t} =
          %Tenant{}
          |> Tenant.create_changeset(%{
            name: "VUF Scale #{slug}",
            slug: slug,
            email: "#{slug}@example.com",
            settings: %{},
            status: :active
          })
          |> AdminRepo.insert()

        # link_density: 10 → a dense, linked corpus so a hub's nearest pool is heavily
        # pre-linked (the adversarial anti-join that produces under-fill).
        ScaleSeed.seed(t.id, count: ScaleSeed.prod_article_floor(), link_density: 10)
        t
      end)

    on_exit(fn ->
      try do
        unboxed(fn ->
          # Links MUST go first: `article_links` FKs articles with `on_delete: :restrict`,
          # so deleting articles while their links exist raises
          # `article_links_source_article_id_fkey` — which the `rescue` below then swallows,
          # silently leaving the whole ~80k corpus committed. CI hides that (each matrix job
          # gets a fresh Postgres), but locally it poisons the test partition for every
          # later run.
          AdminRepo.delete_all(from(l in ArticleLink, where: l.tenant_id == ^tenant.id))
          AdminRepo.delete_all(from(a in Article, where: a.tenant_id == ^tenant.id))
          AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
        end)
      rescue
        _ -> :ok
      end
    end)

    {:ok, tenant: tenant}
  end

  test "dense hub under-fills AND fires the under_fill signal at prod scale (TC-27.6b.2, AC-27.6b.2)",
       %{tenant: tenant} do
    unboxed(fn ->
      # A dense-hub target deep in the seeded corpus. The ambient seed links each article
      # to only ~link_density neighbors, which can't exhaust a 500-row pool — so to model a
      # GENUINE dense hub (the real fast-green-but-wrong failure: a hub whose whole nearest
      # pool is already linked), we explicitly link the target to EVERY one of its top-pool
      # nearest neighbors. The anti-join then removes the entire pool, while the eligible
      # candidate count (ignoring links) still >= pool → under-fill must fire.
      target =
        AdminRepo.one(
          from(a in Article,
            where: a.tenant_id == ^tenant.id and not is_nil(a.embedding),
            order_by: [asc: a.inserted_at, asc: a.id],
            offset: 100,
            limit: 1,
            select: %{id: a.id, embedding: a.embedding}
          )
        )

      pool = VectorSearch.pool_size(5)
      target_vec = VectorSearch.to_embedding_list(target.embedding)

      # EVERY eligible article in the tenant, not just the top-`pool` nearest.
      #
      # Linking only the `pool`-nearest was sufficient while the ANN's reachable candidate
      # set was bounded by one `ef_search` batch. Since #535 pinned
      # `:hnsw_iterative_scan_default` ON in `config/test.exs` — matching prod — that is no
      # longer true: iterative scan is PRECISELY the feature that keeps scanning past the
      # first batch until the limit is filled, so the ANN simply reached past the 500
      # linked neighbours, found unlinked ones, and returned 5 of 5. The test did not
      # become flaky; its premise was repealed by the configuration, and it failed on the
      # nightly for exactly that reason.
      #
      # Exhausting the WHOLE eligible set restores the acceptance criterion under the
      # configuration production actually runs: no unlinked candidate exists at any scan
      # depth, so the anti-join must under-fill whether iterative scan is on or off. It is
      # also the stronger statement of AC-27.6b.2 — "filters exhausted the pool" — rather
      # than a statement about how far one ef_search batch happens to reach.
      #
      # `target_vec` still orders the insert so the nearest are linked first; the ordering
      # is now cosmetic for the assertion but keeps the rows deterministic.
      nearest_ids =
        AdminRepo.all(
          from(a in Article,
            where: a.tenant_id == ^tenant.id and a.status == :published,
            where: not is_nil(a.embedding) and a.id != ^target.id,
            order_by: [asc: fragment("? <=> ?", a.embedding, ^target_vec)],
            select: a.id
          )
        )

      now = DateTime.utc_now()

      link_rows =
        Enum.map(nearest_ids, fn nid ->
          %{
            id: Ecto.UUID.generate(),
            tenant_id: tenant.id,
            source_article_id: target.id,
            target_article_id: nid,
            relationship_type: :relates_to,
            metadata: %{},
            inserted_at: now
          }
        end)

      # `on_conflict: :nothing` is REQUIRED, not defensive. `ScaleSeed` already links every
      # article to its `link_density` index-adjacent neighbours, so a plain insert_all
      # always trips `article_links_tenant_src_tgt_rel_index`. Skipping the already-present
      # rows preserves the intent exactly: what matters is that the target ends up linked
      # to every eligible article (so the anti-join has nothing left to return at ANY scan
      # depth), not which of those links this insert happened to author.
      #
      # CHUNKED because the eligible set is the whole prod-floor corpus (~80k): `insert_all`
      # binds one parameter per field per row, so a single call would blow past Postgres's
      # 65535-parameter limit. 5_000 rows x 7 fields = 35_000 bindings, comfortably under.
      link_rows
      |> Enum.chunk_every(5_000)
      |> Enum.each(fn chunk ->
        {_n, _} =
          AdminRepo.insert_all(ArticleLink, chunk,
            on_conflict: :nothing,
            conflict_target: [
              :tenant_id,
              :source_article_id,
              :target_article_id,
              :relationship_type
            ]
          )
      end)

      test_pid = self()
      handler_id = "under-fill-scale-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        TelemetryEvents.vector_search_under_fill(),
        fn _e, measurements, metadata, _ ->
          send(test_pid, {:under_fill, measurements, metadata})
        end,
        nil
      )

      try do
        # threshold: 0.0 so the under-fill is driven purely by the anti-join (the dense
        # hub's whole nearest pool is already-linked), not the similarity floor — the
        # cleanest demonstration that filters exhausting a FULL pool fire the signal.
        {:ok, suggestions, meta} =
          Knowledge.suggest_links_with_meta(tenant.id, target.id,
            limit: 5,
            threshold: 0.0
          )

        assert length(suggestions) < 5,
               "expected a dense hub to under-fill (returned #{length(suggestions)} of 5)"

        assert meta.recall_truncated == true
        assert meta.pool_exhausted == true

        assert_received {:under_fill, measurements, metadata}
        assert measurements.requested == 5
        assert measurements.returned < 5
        assert measurements.pool == VectorSearch.pool_size(5)
        # The ANN delivered candidates (bounded by ef_search ~40, so typically < pool —
        # which is exactly why the old `>= pool` pool-full gate was degenerate and is gone).
        assert measurements.ann_candidates > 0
        # Near neighbors genuinely EXIST among what the ANN surfaced (threshold 0.0 → the
        # nearest are all above the bar) but the anti-join hid them — this is what separates
        # a real recall incident from a sparse region whose pool is below threshold, and it
        # holds REGARDLESS of ef_search (the bug prod-scale verification caught).
        assert measurements.above_threshold > measurements.returned

        assert measurements.excluded_by_link ==
                 measurements.above_threshold - measurements.returned

        assert measurements.excluded_by_link >= 1
        assert metadata.tenant_id == tenant.id
        assert metadata.endpoint == :suggested_links

        # No content leak in the payload (AC-27.6b.5).
        flat = inspect({measurements, metadata})
        refute flat =~ "::vector"
        refute flat =~ "embedding"
      after
        :telemetry.detach(handler_id)
      end
    end)
  end

  test "ef_search is identical on the scale-gate connection and a prod-shaped connection (AC-27.6b.4)" do
    # Read the EFFECTIVE value via `SHOW` on each connection (NOT a :parameters config
    # compare). Touch a vector op first so pgvector's custom GUC is registered for the
    # session, then read it. ef_search is never SET today, so both must report the
    # pgvector default — pinned so a future prod ALTER ROLE can't diverge from the gate.
    #
    # SHARED-ROLE ASSUMPTION (the one scenario this guard could go silently green while
    # prod diverges — document it so a future reader knows when to revisit):
    #   (a) The `gate == prod` parity check assumes AdminRepo and HeavyReadRepo connect
    #       as ONE Postgres role (true in prod today — both use admin_database_url's
    #       BYPASSRLS role). `hnsw.ef_search` is set per-ROLE via `ALTER ROLE … SET`
    #       (US-27.11), so a single ALTER ROLE moves BOTH pools together → parity holds
    #       by construction even after an override.
    #   (b) IF those repos are ever split onto DIFFERENT Postgres roles, an ALTER ROLE on
    #       one role would NOT move the other, and THIS test is the only thing that would
    #       catch the silent gate-vs-prod divergence — so it MUST be revisited then
    #       (read ef_search on each role explicitly, not assume one ALTER ROLE covers both).
    #   (c) The `== "40"` pin below is a deliberate tripwire for "still pgvector default".
    #       When US-27.11 lands a non-default `ALTER ROLE … SET hnsw.ef_search = N`, this
    #       pin MUST be updated to the new value (and (a)'s shared-role reasoning re-checked).
    gate_ef =
      unboxed(fn ->
        AdminRepo.query!("SELECT '[1,2,3]'::vector")
        %{rows: [[v]]} = AdminRepo.query!("SHOW hnsw.ef_search")
        v
      end)

    prod_ef =
      Sandbox.unboxed_run(HeavyReadRepo, fn ->
        HeavyReadRepo.query!("SELECT '[1,2,3]'::vector")
        %{rows: [[v]]} = HeavyReadRepo.query!("SHOW hnsw.ef_search")
        v
      end)

    # The SHARED parity assertion (US-27.8) — the calibration-mismatch test drives the SAME
    # function in the failure direction, so the gate and its failure-test can't drift.
    assert :ok = PlanAssertions.assert_ef_search_parity!(gate_ef, prod_ef)

    # And it is the pgvector default (40) until US-27.11's ALTER ROLE lever is applied.
    assert gate_ef == "40"
  end
end
