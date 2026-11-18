defmodule Loopctl.Changes.PrReviewOutcomes do
  @moduledoc """
  Review outcomes of merged pull requests (US-50.4): what each merged PR's `## Review findings`
  section said, and how many review rounds the fleet counted for it.

  ## Where the facts come from

  - A merged `pull_request` webhook on a repository with an intake source enqueues
    `Loopctl.Workers.PrReviewOutcomeWorker` (`Loopctl.Intake`), which reads the PR's CURRENT
    body through the tenant's forge credential and parses it with
    `Loopctl.Changes.ReviewFindings`. `record/3` stores the result; a re-run replaces the row.
  - Rounds are chg ledger rows (US-50.1) of kind `review_round` for the same repository whose
    `raw` carries `"pr"`, the PR number (posted as an overrulable default on the chg channel).
    A merged PR with no such row is `merged_without_counted_round`.

  The body is UNTRUSTED forge text. The parser never fails on it, and nothing reads a stored
  finding as an instruction.
  """

  import Ecto.Query

  alias Loopctl.Changes.Events
  alias Loopctl.Changes.LedgerRow
  alias Loopctl.Changes.PrReviewOutcome
  alias Loopctl.Changes.ReviewFindings
  alias Loopctl.Delivery.PullRequestSource
  alias Loopctl.HeavyRead
  alias Loopctl.Intake.Source
  alias Loopctl.Repo

  @round_kind "review_round"

  @type outcome :: %{
          repo: String.t(),
          pr_number: pos_integer(),
          merged_at: DateTime.t() | nil,
          merge_sha: String.t() | nil,
          has_review_section: boolean(),
          findings: [map()],
          unparsed: [String.t()],
          rounds: non_neg_integer(),
          merged_without_counted_round: boolean()
        }

  @doc """
  Stores the outcome of `pr_number` on `source`'s repository from the forge's
  `t:Loopctl.Delivery.PullRequestSource.pull_request_body/0`, replacing any earlier row.
  """
  @spec record(Source.t(), pos_integer(), PullRequestSource.pull_request_body()) ::
          {:ok, PrReviewOutcome.t()} | {:error, term()}
  def record(%Source{} = source, pr_number, %{} = facts)
      when is_integer(pr_number) and pr_number > 0 do
    parsed = ReviewFindings.parse(facts.body)
    now = DateTime.utc_now()

    row = %{
      id: Ecto.UUID.generate(),
      tenant_id: source.tenant_id,
      source_id: source.id,
      repo: Events.repo_key(source.repo_full_name),
      pr_number: pr_number,
      merged_at: usec(facts.merged_at),
      merge_sha: facts.merge_sha,
      has_review_section: parsed.section?,
      findings: Enum.map(parsed.findings, &stringify/1),
      unparsed: parsed.unparsed,
      inserted_at: now,
      updated_at: now
    }

    replace =
      [:source_id, :merged_at, :merge_sha, :has_review_section, :findings, :unparsed, :updated_at]

    Repo.with_tenant(source.tenant_id, fn ->
      {1, [stored]} =
        Repo.insert_all(PrReviewOutcome, [row],
          on_conflict: {:replace, replace},
          conflict_target: [:tenant_id, :repo, :pr_number],
          returning: true
        )

      stored
    end)
  end

  # GitHub's timestamps carry whole seconds; the column is microsecond.
  defp usec(%DateTime{} = at), do: %{at | microsecond: {elem(at.microsecond, 0), 6}}
  defp usec(nil), do: nil

  defp stringify(finding), do: Map.new(finding, fn {k, v} -> {Atom.to_string(k), v} end)

  @doc """
  `tenant_id`'s outcomes, newest merge first, each with its counted `rounds` and
  `merged_without_counted_round`. `opts`: `:repo` (an `owner/name`, any case), `:since` (a
  `DateTime`, on `merged_at`), `:limit` (1..500, default 100).
  """
  @spec list(Ecto.UUID.t(), keyword()) :: [outcome()] | {:error, :heavy_read_overloaded}
  def list(tenant_id, opts \\ []) when is_binary(tenant_id) do
    limit = opts |> Keyword.get(:limit, 100) |> max(1) |> min(500)

    query =
      from o in PrReviewOutcome,
        where: o.tenant_id == ^tenant_id,
        order_by: [desc_nulls_last: o.merged_at, desc: o.pr_number],
        limit: ^limit

    query =
      case Keyword.get(opts, :repo) do
        repo when is_binary(repo) -> where(query, [o], o.repo == ^Events.repo_key(repo))
        _ -> query
      end

    query =
      case Keyword.get(opts, :since) do
        %DateTime{} = since -> where(query, [o], o.merged_at >= ^since)
        _ -> query
      end

    with rows when is_list(rows) <- heavy_all(tenant_id, query),
         counts when is_map(counts) <- rounds(tenant_id, rows) do
      Enum.map(rows, &with_rounds(&1, counts))
    end
  end

  # An analytical read an operator page re-runs at will, so it runs on `HeavyReadRepo`
  # (`Loopctl.HeavyRead`, whose guard pins every base table to `tenant_id`). Shed load comes
  # back as `{:error, :heavy_read_overloaded}` rather than raising, for the caller to show.
  defp heavy_all(tenant_id, query) do
    HeavyRead.all(tenant_id, query, Keyword.put(HeavyRead.opts(:enumeration), :on_overload, :tag))
  end

  # One grouped read of every listed PR's review_round rows, keyed {repo, pr_number}. A `pr`
  # that is not a canonical decimal is not counted: the cast is guarded so a malformed row from
  # a fleet machine can never fail the read.
  defp rounds(_tenant_id, []), do: %{}

  defp rounds(tenant_id, outcomes) do
    repos = outcomes |> Enum.map(& &1.repo) |> Enum.uniq()
    numbers = outcomes |> Enum.map(&Integer.to_string(&1.pr_number)) |> Enum.uniq()

    from(r in LedgerRow,
      where:
        r.tenant_id == ^tenant_id and r.kind == @round_kind and r.repo in ^repos and
          fragment("(?->>'pr')", r.raw) in ^numbers,
      group_by: [r.repo, fragment("(?->>'pr')", r.raw)],
      select: {r.repo, fragment("(?->>'pr')", r.raw), count(r.id)}
    )
    |> then(&heavy_all(tenant_id, &1))
    |> case do
      rows when is_list(rows) -> Map.new(rows, fn {repo, pr, count} -> {{repo, pr}, count} end)
      {:error, _reason} = error -> error
    end
  end

  defp with_rounds(%PrReviewOutcome{} = o, counts) do
    rounds = Map.get(counts, {o.repo, Integer.to_string(o.pr_number)}, 0)

    %{
      repo: o.repo,
      pr_number: o.pr_number,
      merged_at: o.merged_at,
      merge_sha: o.merge_sha,
      has_review_section: o.has_review_section,
      findings: o.findings,
      unparsed: o.unparsed,
      rounds: rounds,
      merged_without_counted_round: rounds == 0
    }
  end
end
