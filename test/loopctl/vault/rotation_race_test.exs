defmodule Loopctl.Vault.RotationRaceTest do
  @moduledoc """
  What the re-encryption pass does when the row moves under it (#622 review round 1).

  A 0-row compare-and-set used to be tallied `skipped_concurrent`, which the report
  DESCRIBES as "already on the active cipher". That claim is false in two ways, and both
  are reproduced here with an injected concurrent writer — the pass SELECTs a batch and then
  compare-and-sets each row in turn, so a write landing right after the first row's
  compare-and-set is exactly the application write that races the second.

  The writer is `Loopctl.Vault.Rotation.reencrypt/1`'s `:around_write`, wrapped around each
  compare-and-set exactly where the AFTER UPDATE trigger these tests used to install fired:
  after a write that changed a row, on every write the pass makes (its retry included), or in
  place of the write when it raises. The module runs async: a `CREATE TRIGGER` took SHARE
  ROW EXCLUSIVE on `tenant_llm_settings` until the test ended, and every concurrent test
  inserting there waited out the statement timeout (57014, KB 493d2020).
  """
  use Loopctl.DataCase, async: true

  alias Cloak.Ciphers.AES.GCM
  alias Loopctl.AdminRepo
  alias Loopctl.Vault
  alias Loopctl.Vault.Rotation

  setup :verify_on_exit!

  @table "tenant_llm_settings"

  test "a row raced on ONE column is re-decided, not counted as already-converted" do
    rows = two_rows_on_retired_key()
    raced = Vault.encrypt!("raced-by-the-application")

    # The guard spans every rewritten column, so touching just chat_api_key voids it —
    # while api_key is still on the key the operator is about to delete.
    # Only this test's other row: the module runs async, and an unscoped write would race
    # every concurrent test's rows in the table.
    racer =
      after_each_write(fn pk ->
        AdminRepo.query!(
          ~s|UPDATE "#{@table}" SET chat_api_key = $1 WHERE id = ANY($2) AND id <> $3|,
          [raced, ids(rows), pk]
        )
      end)

    assert {:ok, report} = Rotation.reencrypt(table: @table, batch_size: 2, around_write: racer)

    assert report.totals.reencrypted == 2
    assert report.totals.skipped_concurrent == 0

    for row <- rows do
      assert Rotation.tag_of(raw("api_key", row.id)) == {:ok, Rotation.active_tag()}
    end

    # The race really landed: the last write raced the other row's chat_api_key.
    assert Enum.any?(rows, &(raw("chat_api_key", &1.id) == raced))
  end

  test "a row deleted mid-pass counts as skipped_gone, not as already-converted" do
    rows = two_rows_on_retired_key()

    racer =
      after_each_write(fn pk ->
        AdminRepo.query!(~s|DELETE FROM "#{@table}" WHERE id = ANY($1) AND id <> $2|, [
          ids(rows),
          pk
        ])
      end)

    assert {:ok, report} = Rotation.reencrypt(table: @table, batch_size: 2, around_write: racer)

    assert report.totals.skipped_gone == 1
    assert report.totals.skipped_concurrent == 0
    assert report.totals.reencrypted == 1
  end

  # A DB error mid-pass used to propagate out as a raise, discarding the counts and
  # failures the runbook tells the operator to read.
  test "a DB error mid-pass returns the partial report instead of throwing it away" do
    _rows = two_rows_on_retired_key()

    assert {:error, report} =
             Rotation.reencrypt(
               table: @table,
               batch_size: 2,
               around_write: fn _pk, _write -> raise_db_error() end
             )

    assert report.aborted
    assert [failure] = report.failures
    assert failure.reason =~ "aborted before completing"
    # The abort invents no row: the buckets still describe only rows actually examined.
    assert report.totals.failed == 0
  end

  # The rescue used to sit on the BATCH frame, closing over the report bound at entry — so
  # the rows already converted in the failing batch were dropped from the printed counts.
  test "an abort keeps the counts the failing batch had already accrued" do
    last =
      two_rows_on_retired_key()
      |> Enum.sort_by(&Ecto.UUID.dump!(&1.id))
      |> List.last()

    last_pk = Ecto.UUID.dump!(last.id)

    fail_last = fn
      ^last_pk, _write -> raise_db_error()
      _pk, write -> write.()
    end

    assert {:error, report} =
             Rotation.reencrypt(table: @table, batch_size: 2, around_write: fail_last)

    assert report.aborted
    assert report.totals.reencrypted == 1
    assert report.totals.examined == 1
  end

  # What the AFTER UPDATE trigger did: `race` runs after a write that changed a row, given
  # that row's key, and never for a write that changed nothing.
  defp after_each_write(race) do
    fn pk, write ->
      case write.() do
        0 ->
          0

        rows ->
          race.(pk)
          rows
      end
    end
  end

  # The error the trigger's RAISE produced: the compare-and-set itself fails.
  defp raise_db_error do
    raise Postgrex.Error, message: "connection went away"
  end

  defp retired_opts do
    {GCM, opts} = Keyword.fetch!(Application.get_env(:loopctl, Vault)[:ciphers], :retired_v0)
    opts
  end

  defp two_rows_on_retired_key do
    rows = for _n <- 1..2, do: fixture(:tenant_llm_settings, %{})

    for row <- rows, column <- ["api_key", "chat_api_key"] do
      {:ok, ciphertext} = GCM.encrypt(column, retired_opts())

      AdminRepo.query!(~s(UPDATE "#{@table}" SET "#{column}" = $1 WHERE id = $2), [
        ciphertext,
        Ecto.UUID.dump!(row.id)
      ])
    end

    rows
  end

  defp ids(rows), do: Enum.map(rows, &Ecto.UUID.dump!(&1.id))

  defp raw(column, id) do
    %{rows: [[value]]} =
      AdminRepo.query!(~s(SELECT "#{column}" FROM "#{@table}" WHERE id = $1), [
        Ecto.UUID.dump!(id)
      ])

    value
  end
end
