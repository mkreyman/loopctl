defmodule Loopctl.Vault.RotationRaceTest do
  @moduledoc """
  What the re-encryption pass does when the row moves under it (#622 review round 1).

  A 0-row compare-and-set used to be tallied `skipped_concurrent`, which the report
  DESCRIBES as "already on the active cipher". That claim is false in two ways, and both
  are reproduced here with a Postgres trigger as the concurrent writer — the pass SELECTs a
  batch and then compare-and-sets each row in turn, so an AFTER UPDATE trigger firing on
  the first row is exactly the application write that races the second.
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
    raced = Base.encode16(Vault.encrypt!("raced-by-the-application"), case: :lower)

    # The guard spans every rewritten column, so touching just chat_api_key voids it —
    # while api_key is still on the key the operator is about to delete.
    race_trigger(~s|UPDATE #{@table} SET chat_api_key = '\\x#{raced}'::bytea WHERE id <> NEW.id;|)

    assert {:ok, report} = Rotation.reencrypt(table: @table, batch_size: 2)

    assert report.totals.reencrypted == 2
    assert report.totals.skipped_concurrent == 0

    for row <- rows do
      assert Rotation.tag_of(raw("api_key", row.id)) == {:ok, Rotation.active_tag()}
    end
  end

  test "a row deleted mid-pass counts as skipped_gone, not as already-converted" do
    _rows = two_rows_on_retired_key()

    race_trigger(~s|DELETE FROM #{@table} WHERE id <> NEW.id;|)

    assert {:ok, report} = Rotation.reencrypt(table: @table, batch_size: 2)

    assert report.totals.skipped_gone == 1
    assert report.totals.skipped_concurrent == 0
    assert report.totals.reencrypted == 1
  end

  # A DB error mid-pass used to propagate out as a raise, discarding the counts and
  # failures the runbook tells the operator to read.
  test "a DB error mid-pass returns the partial report instead of throwing it away" do
    _rows = two_rows_on_retired_key()

    race_trigger(~s|RAISE EXCEPTION 'connection went away';|)

    assert {:error, report} = Rotation.reencrypt(table: @table, batch_size: 2)

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

    race_trigger(
      ~s|IF NEW.id = '#{last.id}' THEN RAISE EXCEPTION 'connection went away'; | <>
        "END IF;"
    )

    assert {:error, report} = Rotation.reencrypt(table: @table, batch_size: 2)

    assert report.aborted
    assert report.totals.reencrypted == 1
    assert report.totals.examined == 1
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

  defp raw(column, id) do
    %{rows: [[value]]} =
      AdminRepo.query!(~s(SELECT "#{column}" FROM "#{@table}" WHERE id = $1), [
        Ecto.UUID.dump!(id)
      ])

    value
  end

  # The WHEN clause is evaluated BEFORE the trigger function runs, so `= 0` (not 1) is what
  # keeps the trigger's own write from re-entering it — at 1 the trigger never fires at all
  # and every test above goes vacuous. The sandbox rolls the DDL back.
  defp race_trigger(body) do
    name = "rotation_race_#{System.unique_integer([:positive])}"

    AdminRepo.query!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $fn$ BEGIN #{body} RETURN NEW; END; " <>
        "$fn$ LANGUAGE plpgsql"
    )

    AdminRepo.query!(
      ~s|CREATE TRIGGER #{name}_t AFTER UPDATE ON "#{@table}" FOR EACH ROW | <>
        "WHEN (pg_trigger_depth() = 0) EXECUTE FUNCTION #{name}()"
    )

    :ok
  end
end
