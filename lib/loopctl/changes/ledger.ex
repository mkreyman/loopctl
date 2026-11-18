defmodule Loopctl.Changes.Ledger do
  @moduledoc """
  The chg ledger's context (US-50.1): the shadow-ledger rows every fleet machine's chg outbox
  delivers in batches, kept so gate outcomes, selection quality and phase timings are
  answerable from one place instead of by ssh into each machine.

  ## Receipt

  `receive_batch/3` takes one signed `{"rows": [...]}` body for a `chg` intake source. It is
  authenticated by `Loopctl.Changes.Events.signed/4`, the one path every chg sender request
  takes, so it refuses exactly what a change-event push refuses, with the same 401. The body is
  parsed only after the signature checks out.

  Each row is judged on its own. A row that fails is named in `rejected` by its index and
  reason, and never fails the batch:

  - `invalid_row`: not an object, a required field missing or malformed, a U+0000 anywhere
    (`jsonb` refuses it), or larger than
    `@max_row_bytes` encoded. Every row needs `v`, `kind`, `repo`, `host` and `at_ms`; a `chg`
    or `gate` row also needs `sha`, `verdict` (`pass|fail|error|skipped`) and `ms`. Any other
    kind is stored with the common fields, so chg can add kinds without a loopctl release.
  - `repo_mismatch`: the row names a repository other than the source's. A source's secret
    authenticates rows about its own repository and nothing else.

  ## Idempotency

  `row_hash` is the sha256 of the row's canonical JSON (keys sorted at every level), and
  `(tenant_id, source_id, host, row_hash)` is a unique index. The insert is
  `ON CONFLICT DO NOTHING`, so a redelivered row, or a row repeated inside one batch, is
  counted as a duplicate and written once. A sender may resend any batch.

  ## Retention

  `prune/3` deletes one tenant's rows older than a cutoff in bounded batches;
  `Loopctl.Workers.ChgLedgerPruneWorker` runs it nightly at `retention_days/0`. A row older than
  the window that a sender redelivers is stored again; senders do not keep rows that long.

  ## No outbound call

  Nothing here reaches the network.
  """

  import Ecto.Query

  alias Loopctl.Changes.Events
  alias Loopctl.Changes.LedgerRow
  alias Loopctl.Intake.Source
  alias Loopctl.Repo

  # The largest batch and body accepted, held here for the guards
  # (`LoopctlWeb.Plugs.IntakeRawBody`, `receive_batch/3`) and the operation spec
  # (`LoopctlWeb.ChgLedgerController`) alike, so they cannot drift.
  @max_batch 500
  @max_body_bytes 1_048_576
  # One row, canonically encoded. A shadow row is a few hundred bytes.
  @max_row_bytes 16_384

  @retention_days 180
  @prune_batch_size 5_000
  @prune_budget 200_000

  @kind_format ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @host_format ~r/\A[\x21-\x7E]{1,255}\z/
  @sha_format ~r/\A[0-9a-f]{7,64}\z/
  @verdicts ~w(pass fail error skipped)
  @verdict_kinds ~w(chg gate)

  @type rejection :: %{index: non_neg_integer(), reason: String.t()}
  @type result :: %{
          inserted: non_neg_integer(),
          duplicates: non_neg_integer(),
          rejected: [rejection()]
        }

  @doc "The most rows one batch may carry."
  @spec max_batch() :: pos_integer()
  def max_batch, do: @max_batch

  @doc "The largest ledger batch body accepted, in bytes."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc "How many days a ledger row is kept, judged by its `at`."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @doc "The reasons a row can be rejected for."
  @spec rejection_reasons() :: [String.t()]
  def rejection_reasons, do: ["invalid_row", "repo_mismatch"]

  @doc """
  Receives one signed ledger batch for `source_id`: `{:ok, %{inserted:, duplicates:,
  rejected:}}`.

  `input` is `%{raw_body:, timestamp:, signature:}`. A body that is not
  `{"rows": [...]}` with 1..`max_batch/0` entries is `{:error, {:bad_request,
  "invalid_batch"}}`, judged after the signature. Every refusal is `{:error, :unauthorized}`.

  `opts`: `:now` (unix seconds) and `:lock_timeout_ms`, as for
  `Loopctl.Changes.Events.receive_push/3`; inputs for tests only.
  """
  @spec receive_batch(term(), Events.push_input(), keyword()) ::
          {:ok, result()}
          | {:error, :unauthorized | {:bad_request, String.t()} | :busy | :apply_failed}
  def receive_batch(source_id, %{raw_body: raw_body} = input, opts \\ [])
      when is_binary(raw_body) do
    Events.signed(source_id, input, opts, fn held ->
      case decode(raw_body) do
        {:ok, rows} -> store(held, rows, DateTime.utc_now())
        :error -> Repo.rollback({:bad_request, "invalid_batch"})
      end
    end)
  end

  @doc """
  One tenant's ledger rows, newest first. `opts`: `:repo` (a repository name, matched
  case-insensitively), `:kind`, `:limit` (default 100, at most 1000).
  """
  @spec list_rows(Ecto.UUID.t(), keyword()) :: [LedgerRow.t()]
  def list_rows(tenant_id, opts \\ []) when is_binary(tenant_id) do
    limit = opts |> Keyword.get(:limit, 100) |> max(1) |> min(1000)

    query =
      from r in LedgerRow,
        where: r.tenant_id == ^tenant_id,
        order_by: [desc: r.at, desc: r.id],
        limit: ^limit

    query =
      case opts[:repo] do
        repo when is_binary(repo) -> where(query, [r], r.repo == ^Events.repo_key(repo))
        _ -> query
      end

    query =
      case opts[:kind] do
        kind when is_binary(kind) -> where(query, [r], r.kind == ^kind)
        _ -> query
      end

    {:ok, rows} = Repo.with_tenant(tenant_id, fn -> Repo.all(query) end)
    rows
  end

  @doc """
  Deletes `tenant_id`'s rows whose `at` is before `cutoff`, in batches of `:batch_size`
  (default #{@prune_batch_size}) up to `:budget` rows (default #{@prune_budget}), one tenant
  transaction per batch. Returns the count deleted.
  """
  @spec prune(Ecto.UUID.t(), DateTime.t(), keyword()) :: non_neg_integer()
  def prune(tenant_id, %DateTime{} = cutoff, opts \\ []) when is_binary(tenant_id) do
    batch_size = Keyword.get(opts, :batch_size, @prune_batch_size)
    budget = Keyword.get(opts, :budget, @prune_budget)
    prune_loop(tenant_id, cutoff, batch_size, budget, 0)
  end

  defp prune_loop(_tenant_id, _cutoff, _batch_size, budget, deleted) when deleted >= budget,
    do: deleted

  defp prune_loop(tenant_id, cutoff, batch_size, budget, deleted) do
    take = min(batch_size, budget - deleted)

    {:ok, count} =
      Repo.with_tenant(tenant_id, fn ->
        ids =
          from r in LedgerRow,
            where: r.tenant_id == ^tenant_id and r.at < ^cutoff,
            order_by: [asc: r.at],
            select: r.id,
            limit: ^take

        {count, _} = Repo.delete_all(from r in LedgerRow, where: r.id in subquery(ids))
        count
      end)

    if count < take,
      do: deleted + count,
      else: prune_loop(tenant_id, cutoff, batch_size, budget, deleted + count)
  end

  # ── receipt ─────────────────────────────────────────────────────────────────

  defp decode(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{"rows" => rows}} when is_list(rows) and rows != [] and length(rows) <= @max_batch ->
        {:ok, rows}

      _ ->
        :error
    end
  end

  defp store(%Source{} = source, rows, now) do
    repo = Events.repo_key(source.repo_full_name)

    {entries, rejected} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {row, index}, {entries, rejected} ->
        case judge(row, repo) do
          {:ok, fields} -> {[entry(source, fields, now) | entries], rejected}
          {:error, reason} -> {entries, [%{index: index, reason: reason} | rejected]}
        end
      end)

    inserted =
      case entries do
        [] ->
          0

        entries ->
          {count, _} =
            Repo.insert_all(LedgerRow, Enum.reverse(entries),
              on_conflict: :nothing,
              conflict_target: [:tenant_id, :source_id, :host, :row_hash]
            )

          count
      end

    %{
      inserted: inserted,
      duplicates: length(entries) - inserted,
      rejected: Enum.reverse(rejected)
    }
  end

  defp entry(source, fields, now) do
    Map.merge(fields, %{
      id: Ecto.UUID.generate(),
      tenant_id: source.tenant_id,
      source_id: source.id,
      inserted_at: now
    })
  end

  # ── one row ─────────────────────────────────────────────────────────────────

  defp judge(row, repo) when is_map(row) do
    with {:ok, encoded} <- canonical_json(row),
         {:ok, common} <- common_fields(row),
         :ok <- same_repo(common.repo, repo),
         {:ok, verdict_fields} <- verdict_fields(common.kind, row) do
      {:ok,
       common
       |> Map.merge(verdict_fields)
       |> Map.merge(%{raw: row, row_hash: hash(encoded)})}
    end
  end

  defp judge(_row, _repo), do: {:error, "invalid_row"}

  # Postgres `jsonb` refuses U+0000 anywhere in a value or key, and the batch is ONE insert, so a
  # single such row would fail every row with it. It is judged here, alone, as `invalid_row`.
  # The check runs on the encoded form, where Jason writes NUL as the escape `\u0000`; a
  # literal backslash before it is itself escaped (`\\u0000`), so only a real NUL matches the
  # unescaped pattern below.
  @nul_escape ~r/(?<!\\)(?:\\\\)*\\u0000/

  defp canonical_json(row) do
    case Jason.encode(canonical(row)) do
      {:ok, encoded} when byte_size(encoded) <= @max_row_bytes ->
        if Regex.match?(@nul_escape, encoded), do: {:error, "invalid_row"}, else: {:ok, encoded}

      _ ->
        {:error, "invalid_row"}
    end
  end

  defp canonical(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, canonical(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(other), do: other

  defp hash(encoded), do: :sha256 |> :crypto.hash(encoded) |> Base.encode16(case: :lower)

  defp common_fields(%{
         "v" => v,
         "kind" => kind,
         "repo" => repo,
         "host" => host,
         "at_ms" => at_ms
       })
       when is_integer(v) and v >= 1 and is_binary(kind) and is_binary(repo) and is_binary(host) and
              is_integer(at_ms) and at_ms >= 0 do
    with true <- Regex.match?(@kind_format, kind),
         true <- Regex.match?(@host_format, host),
         true <- repo != "" and byte_size(repo) <= 255,
         {:ok, at} <- DateTime.from_unix(at_ms * 1000, :microsecond) do
      {:ok, %{kind: kind, repo: Events.repo_key(repo), host: host, at: at}}
    else
      _ -> {:error, "invalid_row"}
    end
  end

  defp common_fields(_row), do: {:error, "invalid_row"}

  defp same_repo(repo, repo), do: :ok
  defp same_repo(_named, _source_repo), do: {:error, "repo_mismatch"}

  defp verdict_fields(kind, row) when kind in @verdict_kinds do
    case row do
      %{"sha" => sha, "verdict" => verdict, "ms" => ms}
      when is_binary(sha) and verdict in @verdicts and is_integer(ms) and ms >= 0 and
             ms <= 9_223_372_036_854_775_807 ->
        if Regex.match?(@sha_format, sha),
          do: {:ok, %{sha: sha, verdict: verdict, ms: ms}},
          else: {:error, "invalid_row"}

      _ ->
        {:error, "invalid_row"}
    end
  end

  defp verdict_fields(_kind, row) do
    {:ok,
     %{
       sha: optional_sha(row["sha"]),
       verdict: if(row["verdict"] in @verdicts, do: row["verdict"]),
       ms: optional_ms(row["ms"])
     }}
  end

  defp optional_sha(sha) when is_binary(sha),
    do: if(Regex.match?(@sha_format, sha), do: sha)

  defp optional_sha(_sha), do: nil

  defp optional_ms(ms) when is_integer(ms) and ms >= 0 and ms <= 9_223_372_036_854_775_807,
    do: ms

  defp optional_ms(_ms), do: nil
end
