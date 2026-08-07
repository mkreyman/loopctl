defmodule Loopctl.Vault.Rotation do
  @moduledoc """
  Re-encrypts Cloak-encrypted columns onto the vault's ACTIVE cipher (#622).

  The operator surface is `mix loopctl.reencrypt_secrets`; the procedure that wraps it is
  `docs/runbooks/cloak-key-rotation.md`. This module is the engine.

  ## Which columns

  `targets/0` DERIVES the column list by reflection — every `Ecto.Schema` in the `:loopctl`
  application is scanned for fields whose type declares `__cloak__/0` (the callback
  `Cloak.Ecto.Type` injects) and names `Loopctl.Vault`. A future `field :x,
  Loopctl.Vault.Binary` is therefore picked up with no change here.

  Two things reflection cannot reach, both deliberate:

    * **Encrypted values inside `oban_jobs.args`** — `Loopctl.Ingestion.ContentEnvelope`
      and `Loopctl.Workers.OrphanedSecretCleanupWorker` call `Vault.encrypt!/1` and
      base64 the result into job args. Those are transient rows an executing job may be
      holding, so rewriting them races the worker. The runbook's queue-drain step covers
      them instead.
    * **An encrypted value inside an array or map column** — no such column exists, and
      rewriting one needs per-element handling this module does not do. `targets/0`
      RAISES on one rather than skipping it silently.

  ## Why not `Cloak.Ecto.Migrator`

  Cloak ships `Cloak.Ecto.migrate/2`, which force-updates every row through a changeset.
  It has no dry run, reports no counts, cannot skip rows already on the active cipher (so
  it is not cheaply resumable), and opens one transaction per ROW. A rotation is exactly
  the moment those matter.

  ## Idempotent, resumable, and honest about skips

  Each row's raw ciphertext header carries the tag of the cipher that wrote it, and
  `active_tag/0` derives the active tag by ENCRYPTING A PROBE with the live vault rather
  than re-reading config — so "already re-encrypted" is decided against what the vault
  actually stamps, not against what config claims it stamps. A row already on the active
  tag is skipped, which makes a second run a no-op and an interrupted run cheap to resume.

  Every row is accounted for in the report under exactly one of `reencrypted`,
  `skipped_active`, `skipped_null`, `skipped_concurrent` or `failed` — the counts sum to
  `examined`. A row whose plaintext cannot be recovered (its cipher is not configured, or
  the GCM auth check fails) is a FAILURE, never a skip: that is the one outcome a
  half-configured `CLOAK_RETIRED_KEYS` produces, and reporting it as success would hide
  the data loss this task exists to prevent.

  The write is a compare-and-set on the exact ciphertext bytes
  (`UPDATE ... WHERE pk = $n AND col = <old bytes>`), so a row the application rewrote
  between our read and our write is left alone and counted `skipped_concurrent` — the
  application's own write is already on the active cipher.

  ## Repo choice

  Reads and writes both go through `Loopctl.AdminRepo` (BYPASSRLS). `Loopctl.Repo` would
  need a per-tenant `SET LOCAL` this pass has no way to enumerate, and `Loopctl.HeavyRead`
  is wrong despite this being an enumeration: it may be pointed at a read replica
  (`REPLICA_DATABASE_URL`), which cannot take the writes, and splitting the read from the
  compare-and-set write across a replica and the primary would make every CAS race a stale
  read. So the usual "route enumerations through HeavyRead" rule does not apply here.

  That does mean the pass occupies one of AdminRepo's 3 connections
  (`ADMIN_POOL_SIZE`, `config/runtime.exs`) for its duration, which is why it is batched
  into bounded round trips rather than held open on one streaming cursor, and why the
  runbook puts it in a quiet window.
  """

  alias Cloak.Tags.Decoder
  alias Loopctl.AdminRepo
  alias Loopctl.Vault

  @default_batch_size 500

  # Cap on the failure detail carried back for printing. `failed` still counts them all.
  @max_reported_failures 50

  @type column :: %{field: atom(), column: String.t()}
  @type target :: %{
          schema: module(),
          table: String.t(),
          primary_key: String.t(),
          columns: [column()]
        }
  @type counts :: %{
          examined: non_neg_integer(),
          reencrypted: non_neg_integer(),
          skipped_active: non_neg_integer(),
          skipped_null: non_neg_integer(),
          skipped_concurrent: non_neg_integer(),
          failed: non_neg_integer()
        }
  @type report :: %{
          dry_run: boolean(),
          active_tag: String.t(),
          totals: counts(),
          tables: %{String.t() => counts()},
          failures: [%{table: String.t(), id: String.t(), reason: String.t()}],
          failures_truncated: boolean()
        }

  @empty_counts %{
    examined: 0,
    reencrypted: 0,
    skipped_active: 0,
    skipped_null: 0,
    skipped_concurrent: 0,
    failed: 0
  }

  @doc """
  Every Cloak-encrypted column in the schema, derived by reflection over `:loopctl`.

  Sorted by table so a run's output is stable between invocations.
  """
  @spec targets() :: [target()]
  def targets do
    (Application.spec(:loopctl, :modules) || [])
    |> Enum.filter(&ecto_schema?/1)
    |> Enum.flat_map(&target_for/1)
    |> Enum.sort_by(& &1.table)
  end

  @doc """
  The cipher tag the vault stamps on new writes, read back off a probe encryption.

  Derived from the LIVE vault rather than from `Application.get_env/3`: the tag this
  returns is what decides which rows count as already-done, and a tag read from config
  while the vault ran on something else would skip rows that still need rewriting.
  """
  @spec active_tag() :: String.t()
  def active_tag do
    case tag_of(Vault.encrypt!("")) do
      {:ok, tag} ->
        tag

      :error ->
        raise "could not read a cipher tag back from Loopctl.Vault. The vault is " <>
                "misconfigured, or Cloak's ciphertext framing changed."
    end
  end

  @doc "The Cloak cipher tag in a raw ciphertext header, or `:error` if it carries none."
  @spec tag_of(binary() | nil) :: {:ok, String.t()} | :error
  def tag_of(ciphertext) when is_binary(ciphertext) and byte_size(ciphertext) >= 2 do
    case Decoder.decode(ciphertext) do
      %{tag: tag} when is_binary(tag) -> {:ok, tag}
      _other -> :error
    end
  rescue
    _error -> :error
  end

  def tag_of(_ciphertext), do: :error

  @doc """
  Counts ciphertext by cipher tag, per table and column, changing nothing.

  The pre- and post-rotation check an operator can trust: it reads the tag off the stored
  bytes, so it reports what is IN the database rather than what a run claimed to do.
  Keys are the tag string, plus `:null` for an empty column and `:untagged` for bytes with
  no readable Cloak header.

  Options: `:batch_size`, `:table`.
  """
  @spec census(keyword()) :: %{active_tag: String.t(), tables: map()}
  def census(opts \\ []) do
    tag = active_tag()

    tables =
      opts
      |> selected_targets()
      |> Map.new(fn target -> {target.table, census_table(target, batch_size(opts))} end)

    %{active_tag: tag, tables: tables}
  end

  @doc """
  Re-encrypts every column not already on the active cipher.

  Options:

    * `:batch_size` — rows fetched per round trip (default #{@default_batch_size})
    * `:table` — restrict to one table, by its DB name
    * `:dry_run` — read, decrypt and classify, but write nothing. `reencrypted` then
      counts the rows a real run WOULD rewrite.

  Returns `{:ok, report}`, or `{:error, report}` when any row failed to decrypt.
  """
  @spec reencrypt(keyword()) :: {:ok, report()} | {:error, report()}
  def reencrypt(opts \\ []) do
    context = %{
      active_tag: active_tag(),
      dry_run: Keyword.get(opts, :dry_run, false),
      batch_size: batch_size(opts)
    }

    report =
      opts
      |> selected_targets()
      |> Enum.reduce(empty_report(context), &reencrypt_table(&1, context, &2))

    if report.totals.failed == 0, do: {:ok, report}, else: {:error, report}
  end

  ## Target enumeration

  defp ecto_schema?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) and
      module.__schema__(:source) != nil
  end

  defp target_for(schema) do
    columns =
      for field <- schema.__schema__(:fields),
          cloak_column?(schema, field),
          do: %{field: field, column: to_string(schema.__schema__(:field_source, field))}

    if columns == [] do
      []
    else
      [
        %{
          schema: schema,
          table: schema.__schema__(:source),
          primary_key: primary_key!(schema),
          columns: columns
        }
      ]
    end
  end

  defp cloak_column?(schema, field) do
    type = schema.__schema__(:type, field)

    if container_of_cloak?(type) do
      raise ArgumentError,
            "#{inspect(schema)}.#{field} holds Cloak-encrypted values inside a container " <>
              "column. Loopctl.Vault.Rotation rewrites scalar columns only, so this one " <>
              "would need a hand-written pass — see docs/runbooks/cloak-key-rotation.md."
    end

    cloak_type?(type)
  end

  defp cloak_type?(type) when is_atom(type) do
    Code.ensure_loaded?(type) and function_exported?(type, :__cloak__, 0) and
      type.__cloak__()[:vault] == Vault
  end

  defp cloak_type?(_type), do: false

  defp container_of_cloak?({kind, inner}) when kind in [:array, :map], do: cloak_type?(inner)
  defp container_of_cloak?(_type), do: false

  defp primary_key!(schema) do
    case schema.__schema__(:primary_key) do
      [field] ->
        quote_ident(to_string(schema.__schema__(:field_source, field)))

      other ->
        raise ArgumentError,
              "#{inspect(schema)} has a #{length(other)}-column primary key; " <>
                "Loopctl.Vault.Rotation keyset-paginates on a single column."
    end
  end

  defp selected_targets(opts) do
    all = targets()

    case Keyword.get(opts, :table) do
      nil ->
        all

      table ->
        Enum.filter(all, &(&1.table == table)) |> ensure_known_table!(table, all)
    end
  end

  defp ensure_known_table!([], table, all) do
    raise ArgumentError,
          "#{table} holds no Cloak-encrypted columns. Encrypted tables: " <>
            Enum.map_join(all, ", ", & &1.table)
  end

  defp ensure_known_table!(selected, _table, _all), do: selected

  ## Re-encryption

  defp empty_report(context) do
    %{
      dry_run: context.dry_run,
      active_tag: context.active_tag,
      totals: @empty_counts,
      tables: %{},
      failures: [],
      failures_truncated: false
    }
  end

  defp reencrypt_table(target, context, report) do
    report
    |> Map.put(:tables, Map.put(report.tables, target.table, @empty_counts))
    |> walk(target, context, nil)
  end

  defp walk(report, target, context, after_pk) do
    case fetch_batch(target, after_pk, context.batch_size) do
      [] ->
        report

      rows ->
        report = Enum.reduce(rows, report, &apply_row(&1, target, context, &2))
        walk(report, target, context, rows |> List.last() |> hd())
    end
  end

  defp apply_row([pk | values], target, context, report) do
    case classify(values, target, context.active_tag) do
      :null -> tally(report, target.table, :skipped_null)
      :active -> tally(report, target.table, :skipped_active)
      {:error, reason} -> record_failure(report, target, pk, reason)
      {:rewrite, rewrites} -> write_row(report, target, context, pk, rewrites)
    end
  end

  # Splits a row's columns into "already on the active cipher" (left alone) and "must be
  # rewritten", decrypting the latter. A single unreadable column fails the whole row —
  # a partial rewrite would leave the row half on each key.
  defp classify(values, target, active_tag) do
    target.columns
    |> Enum.zip(values)
    |> Enum.reduce_while({:null, []}, fn {column, value}, {state, rewrites} ->
      case column_action(value, active_tag) do
        :null -> {:cont, {state, rewrites}}
        :active -> {:cont, {:active, rewrites}}
        {:error, reason} -> {:halt, {:error, "#{column.column}: #{reason}"}}
        {:rewrite, new_value} -> {:cont, {:active, [{column, value, new_value} | rewrites]}}
      end
    end)
    |> resolve_classification()
  end

  defp resolve_classification({:error, reason}), do: {:error, reason}
  defp resolve_classification({state, []}), do: state
  defp resolve_classification({_state, rewrites}), do: {:rewrite, Enum.reverse(rewrites)}

  defp column_action(nil, _active_tag), do: :null

  defp column_action(value, active_tag) do
    case tag_of(value) do
      {:ok, ^active_tag} -> :active
      {:ok, tag} -> rewrite_action(value, tag)
      :error -> {:error, "no readable Cloak tag in the stored bytes"}
    end
  end

  defp rewrite_action(value, tag) do
    case decrypt(value) do
      {:ok, plaintext} -> {:rewrite, Vault.encrypt!(plaintext)}
      :error -> {:error, "cannot decrypt ciphertext tagged #{tag} — is it in CLOAK_RETIRED_KEYS?"}
    end
  end

  # Vault.decrypt/1 does NOT uniformly return an error tuple: a GCM auth failure comes back
  # as {:ok, :error} (same trap `Loopctl.Ingestion.ContentEnvelope.safe_decrypt/1` documents),
  # and a missing cipher raises inside encrypt/decrypt paths. Only a binary is success.
  defp decrypt(ciphertext) do
    case Vault.decrypt(ciphertext) do
      {:ok, plaintext} when is_binary(plaintext) -> {:ok, plaintext}
      _other -> :error
    end
  rescue
    _error -> :error
  end

  defp write_row(report, target, %{dry_run: true}, _pk, _rewrites) do
    tally(report, target.table, :reencrypted)
  end

  defp write_row(report, target, _context, pk, rewrites) do
    case AdminRepo.query!(update_sql(target, rewrites), update_params(pk, rewrites)) do
      %{num_rows: 0} -> tally(report, target.table, :skipped_concurrent)
      _updated -> tally(report, target.table, :reencrypted)
    end
  end

  defp update_sql(target, rewrites) do
    count = length(rewrites)

    assignments =
      rewrites
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {{column, _old, _new}, i} ->
        "#{quote_ident(column.column)} = $#{i}"
      end)

    # The compare-and-set on the OLD bytes is what makes a concurrent application write win
    # instead of being clobbered with the plaintext we read a moment ago.
    guards =
      rewrites
      |> Enum.with_index(count + 2)
      |> Enum.map_join(" AND ", fn {{column, _old, _new}, i} ->
        "#{quote_ident(column.column)} = $#{i}"
      end)

    "UPDATE #{quote_ident(target.table)} SET #{assignments} " <>
      "WHERE #{target.primary_key} = $#{count + 1} AND #{guards}"
  end

  defp update_params(pk, rewrites) do
    Enum.map(rewrites, fn {_column, _old, new} -> new end) ++
      [pk] ++ Enum.map(rewrites, fn {_column, old, _new} -> old end)
  end

  ## Census

  defp census_table(target, batch_size) do
    empty = Map.new(target.columns, fn column -> {column.column, %{}} end)

    census_walk(target, batch_size, nil, empty)
  end

  defp census_walk(target, batch_size, after_pk, acc) do
    case fetch_batch(target, after_pk, batch_size) do
      [] ->
        acc

      rows ->
        acc = Enum.reduce(rows, acc, &census_row(&1, target, &2))
        census_walk(target, batch_size, rows |> List.last() |> hd(), acc)
    end
  end

  defp census_row([_pk | values], target, acc) do
    target.columns
    |> Enum.zip(values)
    |> Enum.reduce(acc, fn {column, value}, inner ->
      Map.update!(inner, column.column, fn tally ->
        Map.update(tally, census_key(value), 1, &(&1 + 1))
      end)
    end)
  end

  defp census_key(nil), do: :null

  defp census_key(value) do
    case tag_of(value) do
      {:ok, tag} -> tag
      :error -> :untagged
    end
  end

  ## Shared SQL

  defp fetch_batch(target, after_pk, limit) do
    columns = Enum.map_join(target.columns, ", ", &quote_ident(&1.column))
    pk = target.primary_key
    select = "SELECT #{pk}, #{columns} FROM #{quote_ident(target.table)}"

    {sql, params} =
      case after_pk do
        nil -> {"#{select} ORDER BY #{pk} LIMIT #{limit}", []}
        value -> {"#{select} WHERE #{pk} > $1 ORDER BY #{pk} LIMIT #{limit}", [value]}
      end

    AdminRepo.query!(sql, params).rows
  end

  # Identifiers come from Ecto schema reflection, never from operator input, but they are
  # interpolated into SQL — so the shape is asserted rather than assumed.
  defp quote_ident(name) do
    if Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, name) do
      ~s("#{name}")
    else
      raise ArgumentError, "refusing to interpolate #{inspect(name)} as a SQL identifier"
    end
  end

  ## Report bookkeeping

  defp batch_size(opts) do
    case Keyword.get(opts, :batch_size, @default_batch_size) do
      size when is_integer(size) and size > 0 ->
        size

      other ->
        raise ArgumentError, "batch_size must be a positive integer, got #{inspect(other)}"
    end
  end

  defp tally(report, table, key) do
    report
    |> Map.put(:totals, bump(report.totals, key))
    |> Map.put(:tables, Map.update!(report.tables, table, &bump(&1, key)))
  end

  defp bump(counts, key) do
    counts
    |> Map.update!(:examined, &(&1 + 1))
    |> Map.update!(key, &(&1 + 1))
  end

  defp record_failure(report, target, pk, reason) do
    failure = %{table: target.table, id: format_pk(pk), reason: reason}
    truncated? = length(report.failures) >= @max_reported_failures

    report
    |> tally(target.table, :failed)
    |> Map.put(:failures, if(truncated?, do: report.failures, else: report.failures ++ [failure]))
    |> Map.put(:failures_truncated, report.failures_truncated or truncated?)
  end

  defp format_pk(pk) when is_binary(pk) and byte_size(pk) == 16 do
    case Ecto.UUID.load(pk) do
      {:ok, uuid} -> uuid
      :error -> inspect(pk)
    end
  end

  defp format_pk(pk), do: inspect(pk)
end
