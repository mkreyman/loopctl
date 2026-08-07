defmodule Mix.Tasks.Loopctl.ReencryptSecrets do
  @moduledoc """
  Re-encrypts every Cloak-encrypted column onto the vault's ACTIVE cipher (#622).

  Step 4 of `docs/runbooks/cloak-key-rotation.md`. Run it after a new `CLOAK_KEY` is live
  and the outgoing key is listed in `CLOAK_RETIRED_KEYS`; when it reports nothing left on
  the retired tag, that key can be dropped from the secret.

  ## Usage

      mix loopctl.reencrypt_secrets              # re-encrypt onto the active cipher
      mix loopctl.reencrypt_secrets --dry-run    # classify and report, write nothing
      mix loopctl.reencrypt_secrets status       # count stored ciphertext by cipher tag
      mix loopctl.reencrypt_secrets --table webhooks --batch-size 200

  ## What it touches

  The columns are DERIVED by reflection over every `Ecto.Schema` in the app
  (`Loopctl.Vault.Rotation.targets/0`), so a newly added `Loopctl.Vault.Binary` field is
  covered without editing this task. `status` prints the list it found.

  Encrypted values inside `oban_jobs.args` are NOT covered — see the runbook's queue-drain
  step and `Loopctl.Vault.Rotation`'s moduledoc.

  ## Reading the output

  Every examined row lands in exactly one bucket, and the buckets sum to `examined`:

    * `reencrypted` — rewritten onto the active cipher (under `--dry-run`, WOULD be)
    * `skipped_active` — already on the active cipher; this is what makes a re-run cheap
    * `skipped_null` — the row's encrypted columns are all empty
    * `skipped_concurrent` — the application rewrote the row mid-pass, so it is already
      on the active cipher; nothing was clobbered
    * `failed` — the plaintext could NOT be recovered, almost always a retired key missing
      from `CLOAK_RETIRED_KEYS`. The task exits non-zero. Fix the secret and re-run; the
      rows it already converted are skipped the second time.

  A run that reports `reencrypted: 0` with a non-zero `skipped_active` is finished work,
  not a silent no-op — confirm it against `status`, which reads tags off the stored bytes.
  """

  use Mix.Task

  alias Loopctl.Vault.Rotation

  @shortdoc "Re-encrypt Cloak-encrypted columns onto the active cipher (key rotation)"

  @switches [dry_run: :boolean, table: :string, batch_size: :integer]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional} = OptionParser.parse!(args, strict: @switches)

    dispatch(positional, opts)
  end

  defp dispatch(["status" | _rest], opts) do
    census = Rotation.census(Keyword.take(opts, [:table, :batch_size]))

    Mix.shell().info("active cipher tag: #{census.active_tag}")

    Enum.each(census.tables, fn {table, columns} ->
      Enum.each(columns, fn {column, tags} ->
        Mix.shell().info("  #{table}.#{column}: #{format_tags(tags)}")
      end)
    end)
  end

  defp dispatch([], opts) do
    case Rotation.reencrypt(opts) do
      {:ok, report} ->
        print_report(report)

      {:error, report} ->
        print_report(report)
        Mix.raise("#{report.totals.failed} row(s) could not be re-encrypted (see above)")
    end
  end

  defp dispatch([unknown | _rest], _opts) do
    Mix.raise("unknown subcommand #{inspect(unknown)}. Try: mix help loopctl.reencrypt_secrets")
  end

  defp print_report(report) do
    if report.dry_run do
      Mix.shell().info("DRY RUN — nothing was written")
    end

    Mix.shell().info("active cipher tag: #{report.active_tag}")

    Enum.each(report.tables, fn {table, counts} ->
      Mix.shell().info("  #{table}: #{format_counts(counts)}")
    end)

    Mix.shell().info("total: #{format_counts(report.totals)}")

    print_failures(report)
  end

  defp print_failures(%{failures: []}), do: :ok

  defp print_failures(report) do
    Mix.shell().error("failures:")

    Enum.each(report.failures, fn failure ->
      Mix.shell().error("  #{failure.table} #{failure.id}: #{failure.reason}")
    end)

    if report.failures_truncated do
      Mix.shell().error("  ... further failures omitted; see the total above for the count")
    end
  end

  defp format_counts(counts) do
    ~w(examined reencrypted skipped_active skipped_null skipped_concurrent failed)a
    |> Enum.map_join(" ", fn key -> "#{key}=#{Map.fetch!(counts, key)}" end)
  end

  defp format_tags(tags) when map_size(tags) == 0, do: "(no rows)"

  defp format_tags(tags) do
    Enum.map_join(tags, " ", fn {tag, count} -> "#{tag}=#{count}" end)
  end
end
