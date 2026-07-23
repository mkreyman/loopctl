defmodule Loopctl.Knowledge.VectorEndpointE2eLatencyScaleTest do
  @moduledoc """
  US-27.8 AC-27.8.4 / TC-27.8.2: END-TO-END wall-clock latency at prod scale, measured
  through the REAL HTTP endpoint (a timed `Phoenix.ConnTest` request: auth + RLS context +
  query + serialize + render), NOT only via `EXPLAIN`.

  The PRIMARY signal stays the deterministic plan assertion (index-backed, no full-corpus
  Sort) — already enforced by `topk_endpoints_scale_test.exs` /
  `distant_pairs_novelty_scale_test.exs`. This test adds the SECONDARY, ADVISORY wall-clock
  budget the AC calls for, measured the way prod actually experiences it — the full conn
  call — so a regression that keeps the plan index-backed but blows the budget (serialization
  bloat, an extra round-trip) is still surfaced.

  ## Why advisory/secondary (and how it avoids flaking)

  Wall-clock on shared CI hardware is noisy. So the budget is DELIBERATELY GENEROUS
  (`:scale_latency_budget_ms`, default 2000ms — the Theme-2 acceptance target) and the
  deterministic plan gate is the real arbiter. The budget is configurable per AC-27.8.6 so
  it can be tuned as prod grows. A breach here is a signal to investigate, not a hair-trigger
  red — but it is a REAL timed conn, so a true blow-up (e.g. a reintroduced full-corpus Sort
  that the plan gate somehow missed) trips it.

  ## What this does NOT exercise (review note)

  In `:test` the heavy-read DI routes through `AdminRepo`, not the dedicated `HeavyReadRepo`
  pool — so this conn timing does NOT cover the heavy-pool checkout / `statement_timeout`
  dimension; that is covered by the worker-latency + heavy-read-timeout assertions in
  `topk_endpoints_scale_test.exs`. This test's distinct value is the full HTTP path
  (auth / RLS / serialize / render) wall-clock.

  ## How the conn sees the committed 80k corpus

  The scale corpus, tenant, and an agent API key are seeded COMMITTED via
  `Sandbox.unboxed_run(AdminRepo, …)`. The request path's DB reads are on `AdminRepo`
  (auth `verify_api_key`, the vector heavy-reads via `HeavyRead`→AdminRepo in test) and
  `Loopctl.Repo` (analytics). We take SHARED sandbox ownership of all three repos for the
  test process; a shared-sandbox checkout SEES committed rows (verified), so the real conn —
  running in the test process — reads the committed 80k corpus.

  `:scale_nightly`, wired into the CI `scale_file` matrix (enforced by
  `scale_verification_runbook_test.exs`).
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Auth
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ScaleSeed
  alias Loopctl.PlanAssertions
  alias Loopctl.Tenants.Tenant

  import Ecto.Query

  @endpoint LoopctlWeb.Endpoint

  @moduletag :scale_nightly
  @moduletag timeout: :timer.minutes(30)

  # Advisory wall-clock budget (AC-27.8.4/.6), configurable so the gate is tuned as prod
  # grows. Default 2000ms = the Theme-2 "<2s" acceptance target.
  defp latency_budget_ms,
    do: Application.get_env(:loopctl, :scale_latency_budget_ms, 2000)

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

    # 1. Seed the corpus + tenant + an agent API key — all COMMITTED (unboxed) so the real
    #    conn (which reads on AdminRepo) finds them.
    {tenant, raw_key} =
      unboxed(fn ->
        slug = "e2e-lat-#{:erlang.phash2(Ecto.UUID.generate())}"

        {:ok, t} =
          %Tenant{}
          |> Tenant.create_changeset(%{
            name: "E2E Latency #{slug}",
            slug: slug,
            email: "#{slug}@example.com",
            settings: %{},
            status: :active
          })
          |> AdminRepo.insert()

        ScaleSeed.seed(t.id, count: ScaleSeed.prod_article_floor(), link_density: 5)

        {:ok, {raw, _api_key}} =
          Auth.generate_api_key(%{
            tenant_id: t.id,
            name: "e2e-latency-agent",
            role: :agent
          })

        {t, raw}
      end)

    unboxed(fn -> PlanAssertions.assert_scale_floor!(tenant.id) end)

    # A real, embedded, published, SHARED target article for the suggested_links request.
    # The endpoint applies the agent key's visibility scope (shared + own); pick a `shared`
    # row so the agent can see it (ScaleSeed makes ~10% `private` — those would 404 for this
    # agent, which is correct behavior, just not what we're timing).
    target_id =
      unboxed(fn ->
        AdminRepo.one(
          from(a in Article,
            where:
              a.tenant_id == ^tenant.id and a.status == :published and not is_nil(a.embedding) and
                fragment("COALESCE(?->>'visibility', 'shared') = 'shared'", a.metadata),
            order_by: [asc: a.inserted_at, asc: a.id],
            offset: 100,
            limit: 1,
            select: a.id
          )
        )
      end)

    # 2. Take SHARED sandbox ownership for the test process on all three repos so the conn
    #    request (running in this process) has connections; committed rows are visible to a
    #    shared checkout. Drop ownership + clean up committed rows on exit.
    repo_pid = Sandbox.start_owner!(Loopctl.Repo, shared: true)
    admin_pid = Sandbox.start_owner!(AdminRepo, shared: true)
    heavy_pid = Sandbox.start_owner!(Loopctl.HeavyReadRepo, shared: true)

    # 3. The real request pipeline calls config-DI mock dependencies (clock, rate limiter,
    #    health, embedding, …) that need their permissive default stubs. This is a plain
    #    `ExUnit.Case` (not ConnCase), so install them explicitly. `set_mox_global` makes the
    #    stubs visible from the request process (= the test process for ConnTest, and any
    #    plug it calls). Then override the embedding stub with a real seeded vector so the
    #    semantic ANN scores against the committed corpus.
    Mox.set_mox_global()
    Loopctl.DataCase.stub_all_defaults()

    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _tenant_id, _text ->
      {:ok, ScaleSeed.embedding_for(0)}
    end)

    on_exit(fn ->
      Sandbox.stop_owner(repo_pid)
      Sandbox.stop_owner(admin_pid)
      Sandbox.stop_owner(heavy_pid)

      try do
        unboxed(fn ->
          AdminRepo.delete_all(from(k in Loopctl.Auth.ApiKey, where: k.tenant_id == ^tenant.id))

          AdminRepo.delete_all(from(a in Article, where: a.tenant_id == ^tenant.id))
          AdminRepo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
        end)
      rescue
        _ -> :ok
      end
    end)

    {:ok, tenant: tenant, raw_key: raw_key, target_id: target_id}
  end

  defp auth_conn(raw_key) do
    build_conn()
    # The witness STH header the ValidateWitnessHeader plug expects (mirrors ConnCase).
    |> put_req_header("x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")
    |> put_req_header("authorization", "Bearer #{raw_key}")
  end

  test "GET suggested_links completes end-to-end under the advisory latency budget at 80k",
       %{raw_key: raw_key, target_id: target_id} do
    {elapsed_us, conn} =
      :timer.tc(fn ->
        raw_key
        |> auth_conn()
        |> get("/api/v1/knowledge/articles/#{target_id}/suggested_links", %{
          "limit" => "5",
          "threshold" => "0.5"
        })
      end)

    # Correctness first: a real 200 on the committed corpus (proves the conn truly exercised
    # the request path against the 80k rows, not a 401/404/500 short-circuit).
    body = json_response(conn, 200)
    assert is_list(body["data"])
    assert is_map(body["meta"])

    elapsed_ms = div(elapsed_us, 1000)
    budget = latency_budget_ms()

    # ADVISORY/SECONDARY (AC-27.8.4): generous budget, the deterministic plan gate is the
    # real arbiter. A breach is a signal to investigate a serialization/round-trip
    # regression, surfaced as a legible failure (not a silent skip).
    assert elapsed_ms <= budget,
           "suggested_links end-to-end took #{elapsed_ms}ms, advisory budget #{budget}ms " <>
             "(:scale_latency_budget_ms). The deterministic plan gate is primary; investigate " <>
             "a serialize/render/round-trip regression."
  end

  test "GET semantic search completes end-to-end under the advisory latency budget at 80k",
       %{raw_key: raw_key} do
    {elapsed_us, conn} =
      :timer.tc(fn ->
        raw_key
        |> auth_conn()
        |> get("/api/v1/knowledge/search", %{
          "q" => "scale idea",
          "mode" => "semantic",
          "limit" => "10"
        })
      end)

    body = json_response(conn, 200)
    assert is_list(body["data"])
    assert is_map(body["meta"])

    elapsed_ms = div(elapsed_us, 1000)
    budget = latency_budget_ms()

    assert elapsed_ms <= budget,
           "semantic search end-to-end took #{elapsed_ms}ms, advisory budget #{budget}ms " <>
             "(:scale_latency_budget_ms). The deterministic plan gate is primary; investigate " <>
             "a serialize/render/round-trip regression."
  end
end
