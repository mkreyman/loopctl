defmodule Loopctl.Vault.RotationTest do
  use Loopctl.DataCase, async: true

  alias Cloak.Ciphers.AES.GCM
  alias Loopctl.AdminRepo
  alias Loopctl.Llm.TenantLlmSettings
  alias Loopctl.Vault
  alias Loopctl.Vault.Rotation
  alias Loopctl.Webhooks.Webhook

  setup :verify_on_exit!

  @table "webhooks"
  @column "signing_secret_encrypted"
  @settings_table "tenant_llm_settings"

  # config/test.exs configures the vault in its post-rotation shape: an ACTIVE cipher plus
  # the decrypt-only `retired_v0` on a distinct tag. Reading the opts back from there
  # (rather than re-declaring a key here) is what lets these tests write genuine
  # retired-key ciphertext without Application.put_env.
  defp retired_opts do
    ciphers = Application.get_env(:loopctl, Vault)[:ciphers]
    {GCM, opts} = Keyword.fetch!(ciphers, :retired_v0)
    opts
  end

  defp retired_tag, do: retired_opts()[:tag]

  # A key the vault does NOT know: the shape a half-configured CLOAK_RETIRED_KEYS produces.
  defp unconfigured_opts do
    [tag: "AES.GCM.VNEVER", key: :crypto.strong_rand_bytes(32), iv_length: 12]
  end

  defp encrypt_with(opts, plaintext) do
    {:ok, ciphertext} = GCM.encrypt(plaintext, opts)
    ciphertext
  end

  defp put_raw(table, column, id, value) do
    AdminRepo.query!(~s(UPDATE "#{table}" SET "#{column}" = $1 WHERE id = $2), [
      value,
      Ecto.UUID.dump!(id)
    ])

    :ok
  end

  defp raw(table, column, id) do
    %{rows: [[value]]} =
      AdminRepo.query!(~s(SELECT "#{column}" FROM "#{table}" WHERE id = $1), [
        Ecto.UUID.dump!(id)
      ])

    value
  end

  defp webhook_raw(id), do: raw(@table, @column, id)

  # A webhook whose signing secret is stored under the RETIRED key — i.e. a row written
  # before the rotation. Returns `{webhook, plaintext}`.
  defp webhook_on_retired_key(attrs \\ %{}) do
    webhook = fixture(:webhook, attrs)
    secret = "secret-#{System.unique_integer([:positive])}"
    :ok = put_raw(@table, @column, webhook.id, encrypt_with(retired_opts(), secret))

    {webhook, secret}
  end

  describe "targets/0" do
    # The guard against this pass quietly going out of date. Reflection over every Ecto
    # schema is what makes a NEW `Loopctl.Vault.Binary` field covered with no edit to the
    # task; this pins the reflected set against the sources, in BOTH directions. Heredocs
    # are stripped first so a doc example cannot pose as a schema declaration.
    test "finds exactly the fields the sources declare as Loopctl.Vault.Binary" do
      declared =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.flat_map(&declared_cloak_fields/1)
        |> MapSet.new()

      refute Enum.empty?(declared), "the source scan found nothing — the regex has rotted"

      reflected =
        Rotation.targets()
        |> Enum.flat_map(fn target -> Enum.map(target.columns, &to_string(&1.field)) end)
        |> MapSet.new()

      assert reflected == declared
      assert Enum.any?(Rotation.targets(), &(&1.table == @table))
    end

    test "each target carries its table, a single-column primary key and its columns" do
      target = Enum.find(Rotation.targets(), &(&1.table == @table))

      assert target.schema == Webhook
      assert target.primary_key == ~s("id")
      assert Enum.any?(target.columns, &(&1.column == @column))
    end

    test "a table with no encrypted columns raises rather than reporting a clean no-op" do
      assert_raise ArgumentError, ~r/holds no Cloak-encrypted columns/, fn ->
        Rotation.reencrypt(table: "tenants")
      end
    end
  end

  describe "active_tag/0 and tag_of/1" do
    # active_tag/0 is derived by encrypting a probe, so it is by construction the tag the
    # vault stamps rather than what config claims. Everything downstream SKIPS on this
    # value, so a wrong answer here would silently pass over the whole corpus.
    test "the active tag is the tag the vault actually stamps" do
      assert {:ok, tag} = Rotation.tag_of(Vault.encrypt!("anything"))
      assert tag == Rotation.active_tag()
      refute tag == retired_tag()
    end

    test "retired-key ciphertext reports the retired tag" do
      assert Rotation.tag_of(encrypt_with(retired_opts(), "x")) == {:ok, retired_tag()}
    end

    test "bytes with no Cloak header report :error instead of guessing" do
      assert Rotation.tag_of("") == :error
      assert Rotation.tag_of(nil) == :error
    end
  end

  describe "reencrypt/1" do
    # AC #622: a row written under a retired key is readable BEFORE the pass (the retired
    # cipher decrypts it) and is moved onto the active key BY the pass.
    test "a retired-key row stays readable, then lands on the active cipher" do
      {webhook, secret} = webhook_on_retired_key()

      assert AdminRepo.get(Webhook, webhook.id).signing_secret_encrypted == secret
      assert Rotation.tag_of(webhook_raw(webhook.id)) == {:ok, retired_tag()}

      assert {:ok, report} = Rotation.reencrypt(table: @table)

      assert report.totals.reencrypted == 1
      assert report.totals.failed == 0
      assert Rotation.tag_of(webhook_raw(webhook.id)) == {:ok, Rotation.active_tag()}
      assert AdminRepo.get(Webhook, webhook.id).signing_secret_encrypted == secret
    end

    # The counts have to be load-bearing: a pass that silently skipped everything would
    # still return {:ok, _}, so they are asserted against a corpus of known composition.
    test "counts every row into exactly one bucket, and the buckets sum to examined" do
      {retired_row, _secret} = webhook_on_retired_key()
      already_active = fixture(:webhook)

      assert {:ok, report} = Rotation.reencrypt(table: @table)

      counts = report.totals
      assert counts.reencrypted == 1
      assert counts.skipped_active == 1
      assert counts.failed == 0
      assert counts.examined == 2

      assert counts.examined ==
               counts.reencrypted + counts.skipped_active + counts.skipped_null +
                 counts.skipped_concurrent + counts.failed

      assert Rotation.tag_of(webhook_raw(retired_row.id)) == {:ok, Rotation.active_tag()}
      assert Rotation.tag_of(webhook_raw(already_active.id)) == {:ok, Rotation.active_tag()}
    end

    test "a second run is a no-op: nothing is rewritten and the bytes are untouched" do
      {webhook, _secret} = webhook_on_retired_key()

      assert {:ok, _first} = Rotation.reencrypt(table: @table)
      after_first = webhook_raw(webhook.id)

      assert {:ok, second} = Rotation.reencrypt(table: @table)

      assert second.totals.reencrypted == 0
      assert second.totals.skipped_active == 1
      assert webhook_raw(webhook.id) == after_first
    end

    test "dry_run reports the work without performing it" do
      {webhook, _secret} = webhook_on_retired_key()
      before = webhook_raw(webhook.id)

      assert {:ok, report} = Rotation.reencrypt(table: @table, dry_run: true)

      assert report.dry_run
      assert report.totals.reencrypted == 1
      assert webhook_raw(webhook.id) == before
      assert Rotation.tag_of(webhook_raw(webhook.id)) == {:ok, retired_tag()}
    end

    # Keyset pagination is where a batched pass silently drops rows, so the batch size is
    # driven below the row count to force several round trips over one corpus.
    test "batching smaller than the corpus still converts every row" do
      rows = for _n <- 1..3, do: elem(webhook_on_retired_key(), 0)

      assert {:ok, report} = Rotation.reencrypt(table: @table, batch_size: 1)

      assert report.totals.reencrypted == 3

      for row <- rows do
        assert Rotation.tag_of(webhook_raw(row.id)) == {:ok, Rotation.active_tag()}
      end
    end

    # This pass is deliberately CROSS-tenant (AdminRepo, BYPASSRLS). A rotation that
    # converted only one tenant would leave every other tenant's rows pinned to a key the
    # operator is about to delete, so tenant scoping here would BE the bug.
    test "converts rows across every tenant, not just one" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      {row_a, secret_a} = webhook_on_retired_key(%{tenant_id: tenant_a.id})
      {row_b, secret_b} = webhook_on_retired_key(%{tenant_id: tenant_b.id})

      assert {:ok, report} = Rotation.reencrypt(table: @table)

      assert report.totals.reencrypted == 2
      assert AdminRepo.get(Webhook, row_a.id).signing_secret_encrypted == secret_a
      assert AdminRepo.get(Webhook, row_b.id).signing_secret_encrypted == secret_b
    end
  end

  describe "reencrypt/1 across a multi-column row" do
    test "rewrites only the stale columns, leaving active bytes and NULLs alone" do
      settings = fixture(:tenant_llm_settings, %{})
      stale = "byo-key-#{System.unique_integer([:positive])}"
      :ok = put_raw(@settings_table, "api_key", settings.id, encrypt_with(retired_opts(), stale))
      :ok = put_raw(@settings_table, "chat_api_key", settings.id, Vault.encrypt!("chat-key"))
      chat_before = raw(@settings_table, "chat_api_key", settings.id)

      assert {:ok, report} = Rotation.reencrypt(table: @settings_table)

      assert report.totals.reencrypted == 1

      assert Rotation.tag_of(raw(@settings_table, "api_key", settings.id)) ==
               {:ok, Rotation.active_tag()}

      assert raw(@settings_table, "chat_api_key", settings.id) == chat_before
      assert is_nil(raw(@settings_table, "embedding_api_key", settings.id))
      assert AdminRepo.get(TenantLlmSettings, settings.id).api_key == stale
    end

    test "a row whose encrypted columns are all empty counts as skipped_null" do
      _settings = fixture(:tenant_llm_settings, %{api_key: nil, chat_api_key: nil})

      assert {:ok, report} = Rotation.reencrypt(table: @settings_table)

      assert report.totals.skipped_null == 1
      assert report.totals.reencrypted == 0
    end
  end

  describe "reencrypt/1 failure handling" do
    # The dangerous failure mode this task exists to rule out: reporting success while
    # leaving rows behind. An undecryptable row is a FAILURE and a non-ok return, never a
    # skip — and the row is left byte-for-byte alone so a corrected secret can retry it.
    test "a row whose cipher is not configured fails loudly and is left untouched" do
      webhook = fixture(:webhook)
      ciphertext = encrypt_with(unconfigured_opts(), "unreadable")
      :ok = put_raw(@table, @column, webhook.id, ciphertext)

      assert {:error, report} = Rotation.reencrypt(table: @table)

      assert report.totals.failed == 1
      assert report.totals.reencrypted == 0
      assert webhook_raw(webhook.id) == ciphertext

      assert [failure] = report.failures
      assert failure.table == @table
      assert failure.id == webhook.id
      assert failure.reason =~ "CLOAK_RETIRED_KEYS"
    end

    test "bytes carrying no Cloak header fail rather than counting as already-done" do
      webhook = fixture(:webhook)
      :ok = put_raw(@table, @column, webhook.id, "")

      assert {:error, report} = Rotation.reencrypt(table: @table)

      assert report.totals.failed == 1
      assert report.totals.skipped_active == 0
      assert hd(report.failures).reason =~ "no readable Cloak tag"
    end

    test "one unreadable row does not stop the rest of the corpus converting" do
      {good, _secret} = webhook_on_retired_key()
      bad = fixture(:webhook)
      :ok = put_raw(@table, @column, bad.id, encrypt_with(unconfigured_opts(), "unreadable"))

      assert {:error, report} = Rotation.reencrypt(table: @table)

      assert report.totals.failed == 1
      assert report.totals.reencrypted == 1
      assert Rotation.tag_of(webhook_raw(good.id)) == {:ok, Rotation.active_tag()}
    end
  end

  describe "census/1" do
    # The pre/post check an operator can trust, because it reads tags off the STORED bytes
    # rather than believing a run's own summary.
    test "counts stored ciphertext by cipher tag" do
      {_retired_row, _secret} = webhook_on_retired_key()
      _active_row = fixture(:webhook)

      census = Rotation.census(table: @table)
      tally = census.tables[@table][@column]

      assert census.active_tag == Rotation.active_tag()
      assert tally[Rotation.active_tag()] == 1
      assert tally[retired_tag()] == 1
    end

    test "labels bytes with no readable header as :untagged, and empty columns as :null" do
      webhook = fixture(:webhook)
      :ok = put_raw(@table, @column, webhook.id, "")
      _settings = fixture(:tenant_llm_settings, %{api_key: nil, chat_api_key: nil})

      assert Rotation.census(table: @table).tables[@table][@column][:untagged] == 1

      settings_tally = Rotation.census(table: @settings_table).tables[@settings_table]
      assert settings_tally["api_key"][:null] == 1
    end

    test "the census agrees with the pass: nothing on a retired tag once it has run" do
      {_webhook, _secret} = webhook_on_retired_key()

      assert {:ok, _report} = Rotation.reencrypt(table: @table)

      tally = Rotation.census(table: @table).tables[@table][@column]

      refute Map.has_key?(tally, retired_tag())
      assert tally[Rotation.active_tag()] == 1
    end
  end

  defp declared_cloak_fields(path) do
    path
    |> File.read!()
    |> String.replace(~r/"""(?:.|\n)*?"""/, "")
    |> then(
      &Regex.scan(~r/field\s+:(\w+),\s*Loopctl\.Vault\.Binary/, &1, capture: :all_but_first)
    )
    |> List.flatten()
  end
end
