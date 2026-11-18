defmodule Loopctl.Changes.PrReviewOutcomesTest do
  @moduledoc """
  US-50.4: a merged pull request's review outcome, from the intake webhook through the job to
  the stored row and its counted rounds.
  """

  use LoopctlWeb.ConnCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Changes.LedgerRow
  alias Loopctl.Changes.PrReviewOutcome
  alias Loopctl.Changes.PrReviewOutcomes
  alias Loopctl.Intake.Signature
  alias Loopctl.Workers.PrReviewOutcomeWorker

  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  @body """
  ## Testing

  Ran the suite.

  ## Review findings

  1. fixed high lib/a.ex:10 — a leak
  2. wrong low lib/b.ex:2 — a race — wrong because the lock at b.ex:1 serialises it
  3. medium, fixed: prose a person wrote
  """

  @merged_at ~U[2026-11-18 12:00:00Z]

  defp merged_pr(number, repo, merged \\ true) do
    %{
      "action" => "closed",
      "number" => number,
      "pull_request" => %{"number" => number, "merged" => merged, "body" => "webhook copy"},
      "repository" => %{"full_name" => repo}
    }
  end

  defp deliver(conn, secret, source, payload, delivery_id \\ Ecto.UUID.generate()) do
    raw = Jason.encode!(payload)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", "pull_request")
    |> put_req_header("x-github-delivery", delivery_id)
    |> put_req_header("x-hub-signature-256", Signature.header(secret, raw))
    |> post("/api/v1/intake/github/#{source.id}", raw)
  end

  defp stub_forge(body, merged \\ true) do
    stub(Loopctl.MockPullRequestSource, :pull_request_body, fn _repo, _number ->
      {:ok,
       %{
         body: body,
         merged?: merged,
         merged_at: if(merged, do: @merged_at),
         merge_sha: if(merged, do: String.duplicate("c", 40))
       }}
    end)
  end

  # `opts`: `:kind` ("review_round" or "review_round_void") and `:round_id` (omitted from
  # `raw` when nil, as a sender predating round ids would).
  defp round_row!(source, repo, pr, opts \\ []) do
    kind = Keyword.get(opts, :kind, "review_round")

    raw =
      case Keyword.get(opts, :round_id) do
        nil -> %{"v" => 1, "kind" => kind, "repo" => repo, "pr" => pr}
        id -> %{"v" => 1, "kind" => kind, "repo" => repo, "pr" => pr, "round_id" => id}
      end

    AdminRepo.insert!(%LedgerRow{
      tenant_id: source.tenant_id,
      source_id: source.id,
      repo: repo,
      host: "minis",
      kind: kind,
      at: DateTime.utc_now(),
      raw: raw,
      row_hash: Ecto.UUID.generate()
    })
  end

  defp void_row!(source, repo, pr, round_id),
    do: round_row!(source, repo, pr, kind: "review_round_void", round_id: round_id)

  defp outcomes(tenant_id),
    do: AdminRepo.all(from o in PrReviewOutcome, where: o.tenant_id == ^tenant_id)

  defp outcome_jobs(source) do
    worker = inspect(Loopctl.Workers.PrReviewOutcomeWorker)

    Loopctl.Repo.all(
      from j in Oban.Job,
        where: j.worker == ^worker and fragment("?->>'source_id' = ?", j.args, ^source.id)
    )
  end

  describe "TC-50.4.2: a merge enqueues once and records one row" do
    test "a redelivery and a second delivery of one merge enqueue one job", %{conn: conn} do
      {secret, source} = fixture(:intake_source, %{})
      payload = merged_pr(7, source.repo_full_name)
      delivery = Ecto.UUID.generate()

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert conn |> deliver(secret, source, payload, delivery) |> json_response(200)
        # The same X-GitHub-Delivery: a redelivery.
        assert build_conn() |> deliver(secret, source, payload, delivery) |> json_response(200)
        # A new delivery id for the same merge, while the first job is still pending.
        assert build_conn() |> deliver(secret, source, payload) |> json_response(200)

        assert [_one] = outcome_jobs(source)
      end)
    end

    test "two deliveries of the merge store one parsed row", %{conn: conn} do
      {secret, source} = fixture(:intake_source, %{})
      stub_forge(@body)
      payload = merged_pr(7, source.repo_full_name)

      assert %{"outcome" => "recorded"} =
               conn |> deliver(secret, source, payload) |> json_response(200)

      assert %{"outcome" => "recorded"} =
               build_conn() |> deliver(secret, source, payload) |> json_response(200)

      assert [row] = outcomes(source.tenant_id)
      assert row.pr_number == 7
      assert row.has_review_section
      assert DateTime.compare(row.merged_at, @merged_at) == :eq
      assert row.merge_sha == String.duplicate("c", 40)

      assert [
               %{
                 "disposition" => "fixed",
                 "severity" => "high",
                 "file" => "lib/a.ex",
                 "line" => 10
               },
               %{
                 "disposition" => "wrong",
                 "reason" => "wrong because the lock at b.ex:1 serialises it"
               }
             ] = row.findings

      assert [unparsed] = row.unparsed
      assert unparsed =~ "medium, fixed"
    end

    test "the job reads the body from the forge, never the webhook copy", %{conn: conn} do
      {secret, source} = fixture(:intake_source, %{})

      expect(Loopctl.MockPullRequestSource, :pull_request_body, fn repo, 9 ->
        assert repo.full_name == source.repo_full_name
        {:ok, %{body: nil, merged?: true, merged_at: @merged_at, merge_sha: nil}}
      end)

      conn |> deliver(secret, source, merged_pr(9, source.repo_full_name)) |> json_response(200)

      assert [%{has_review_section: false, findings: []}] = outcomes(source.tenant_id)
    end

    test "a closed but unmerged PR and other actions queue nothing", %{conn: conn} do
      {secret, source} = fixture(:intake_source, %{})

      expect(Loopctl.MockPullRequestSource, :pull_request_body, 0, fn _repo, _number ->
        flunk("no read")
      end)

      assert %{"outcome" => "ignored"} =
               conn
               |> deliver(secret, source, merged_pr(3, source.repo_full_name, false))
               |> json_response(200)

      opened = %{merged_pr(4, source.repo_full_name) | "action" => "opened"}

      assert %{"outcome" => "ignored"} =
               build_conn() |> deliver(secret, source, opened) |> json_response(200)

      assert outcomes(source.tenant_id) == []
    end
  end

  describe "the job" do
    test "a forge error retries; a re-run replaces the row" do
      {_secret, source} = fixture(:intake_source, %{})
      args = %{"tenant_id" => source.tenant_id, "source_id" => source.id, "pr_number" => 5}

      stub(Loopctl.MockPullRequestSource, :pull_request_body, fn _repo, _n ->
        {:error, {:http, 502}}
      end)

      assert {:error, {:http, 502}} = perform_job(PrReviewOutcomeWorker, args)

      stub_forge("no section here")
      assert :ok = perform_job(PrReviewOutcomeWorker, args)
      stub_forge(@body)
      assert :ok = perform_job(PrReviewOutcomeWorker, args)

      assert [%{has_review_section: true, findings: [_, _]}] = outcomes(source.tenant_id)
    end

    test "an unmerged PR, a revoked source and no credential are cancelled" do
      {_secret, source} = fixture(:intake_source, %{})
      args = %{"tenant_id" => source.tenant_id, "source_id" => source.id, "pr_number" => 5}

      stub_forge(@body, false)
      assert {:cancel, :not_merged} = perform_job(PrReviewOutcomeWorker, args)

      stub(Loopctl.MockVerificationCredential, :for_read, fn _t, _r ->
        {:error, :credential_unavailable}
      end)

      assert {:cancel, :credential_unavailable} = perform_job(PrReviewOutcomeWorker, args)

      AdminRepo.update!(Ecto.Changeset.change(source, revoked_at: DateTime.utc_now()))
      assert {:cancel, :source_unavailable} = perform_job(PrReviewOutcomeWorker, args)

      assert outcomes(source.tenant_id) == []
    end
  end

  describe "TC-50.4.3: rounds" do
    test "no section and no round is merged_without_counted_round", %{conn: conn} do
      {secret, source} = fixture(:intake_source, %{})
      repo = String.downcase(source.repo_full_name)
      stub_forge("## Risk\n\nnone")

      conn |> deliver(secret, source, merged_pr(11, source.repo_full_name)) |> json_response(200)
      stub_forge(@body)

      build_conn()
      |> deliver(secret, source, merged_pr(12, source.repo_full_name))
      |> json_response(200)

      round_row!(source, repo, 12)
      round_row!(source, repo, 12)
      round_row!(source, repo, 11 * 1000)
      round_row!(source, repo, "not-a-number")

      by_pr = source.tenant_id |> PrReviewOutcomes.list() |> Map.new(&{&1.pr_number, &1})

      assert %{has_review_section: false, rounds: 0, merged_without_counted_round: true} =
               by_pr[11]

      assert %{has_review_section: true, rounds: 2, merged_without_counted_round: false} =
               by_pr[12]

      assert [%{pr_number: 12}] =
               PrReviewOutcomes.list(source.tenant_id,
                 repo: source.repo_full_name,
                 since: @merged_at
               )
               |> Enum.filter(&(&1.pr_number == 12))
    end
  end

  describe "voided rounds (#1044)" do
    setup do
      {_secret, source} = fixture(:intake_source, %{})
      repo = String.downcase(source.repo_full_name)
      facts = %{body: @body, merged?: true, merged_at: @merged_at, merge_sha: nil}
      for n <- 1..4, do: {:ok, _} = PrReviewOutcomes.record(source, n, facts)
      %{source: source, repo: repo}
    end

    defp rounds_by_pr(tenant_id),
      do: tenant_id |> PrReviewOutcomes.list() |> Map.new(&{&1.pr_number, &1})

    test "a round and its void count zero; a void for another round_id changes nothing",
         %{source: source, repo: repo} do
      round_row!(source, repo, 1, round_id: "r1")
      void_row!(source, repo, 1, "r1")

      round_row!(source, repo, 2, round_id: "r2a")
      round_row!(source, repo, 2, round_id: "r2b")
      void_row!(source, repo, 2, "r2a")

      round_row!(source, repo, 3, round_id: "r3")
      void_row!(source, repo, 3, "someone-else")

      by_pr = rounds_by_pr(source.tenant_id)
      assert %{rounds: 0, merged_without_counted_round: true} = by_pr[1]
      assert %{rounds: 1, merged_without_counted_round: false} = by_pr[2]
      assert %{rounds: 1} = by_pr[3]

      # PRs 1 and 4 have no counted round.
      assert %{merged: 4, without_round: 2} = PrReviewOutcomes.totals(source.tenant_id)
    end

    test "a void that arrives before its round still cancels it", %{source: source, repo: repo} do
      void_row!(source, repo, 1, "early")
      round_row!(source, repo, 1, round_id: "early")

      assert %{rounds: 0} = rounds_by_pr(source.tenant_id)[1]
      assert %{without_round: 4} = PrReviewOutcomes.totals(source.tenant_id)
    end

    test "a round with no round_id is never cancelled", %{source: source, repo: repo} do
      round_row!(source, repo, 1)
      void_row!(source, repo, 1, nil)

      assert %{rounds: 1} = rounds_by_pr(source.tenant_id)[1]
      assert %{without_round: 3} = PrReviewOutcomes.totals(source.tenant_id)
    end

    test "another tenant's void cancels nothing", %{source: source, repo: repo} do
      {_secret_b, source_b} = fixture(:intake_source, %{})
      round_row!(source, repo, 1, round_id: "shared")
      void_row!(source_b, repo, 1, "shared")

      assert %{rounds: 1} = rounds_by_pr(source.tenant_id)[1]
      assert %{without_round: 3} = PrReviewOutcomes.totals(source.tenant_id)
    end
  end

  describe "totals/2" do
    test "counts every outcome in range, past any list limit, in SQL" do
      {_secret, source} = fixture(:intake_source, %{})
      {_secret_b, source_b} = fixture(:intake_source, %{})
      repo = String.downcase(source.repo_full_name)
      facts = %{body: @body, merged?: true, merged_at: @merged_at, merge_sha: nil}

      for n <- 1..3, do: {:ok, _} = PrReviewOutcomes.record(source, n, facts)

      {:ok, _} =
        PrReviewOutcomes.record(source, 4, %{
          facts
          | body: "none",
            merged_at: ~U[2026-01-01 00:00:00Z]
        })

      {:ok, _} = PrReviewOutcomes.record(source_b, 1, facts)
      round_row!(source, repo, 2)

      assert [_one] = PrReviewOutcomes.list(source.tenant_id, limit: 1)

      assert %{
               merged: 4,
               by_severity: %{"high" => 3, "low" => 3},
               by_disposition: %{"fixed" => 3, "wrong" => 3},
               without_round: 3
             } = PrReviewOutcomes.totals(source.tenant_id)

      assert %{merged: 3, without_round: 2} =
               PrReviewOutcomes.totals(source.tenant_id, since: @merged_at)

      assert %{merged: 1} = PrReviewOutcomes.totals(source_b.tenant_id)
    end
  end

  describe "TC-50.4.4: tenant isolation" do
    test "tenant B reads none of tenant A's outcomes or rounds", %{conn: conn} do
      {secret, source_a} = fixture(:intake_source, %{})
      {_secret_b, source_b} = fixture(:intake_source, %{})
      stub_forge(@body)

      conn
      |> deliver(secret, source_a, merged_pr(21, source_a.repo_full_name))
      |> json_response(200)

      round_row!(source_a, String.downcase(source_a.repo_full_name), 21)

      assert [%{rounds: 1}] = PrReviewOutcomes.list(source_a.tenant_id)
      assert PrReviewOutcomes.list(source_b.tenant_id) == []
    end
  end
end
