defmodule Loopctl.LlmTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Llm
  alias Loopctl.Llm.TenantLlmSettings

  import Ecto.Query

  describe "upsert_settings/2 + resolve/2" do
    test "stores models + key and resolves the per-operation model + decrypted key" do
      tenant = fixture(:tenant)

      {:ok, _settings} =
        Llm.upsert_settings(tenant.id, %{
          "api_key" => "sk-ant-secret-key-1234",
          "extraction_model" => "claude-opus-4-1",
          "classification_model" => "claude-sonnet-4-5"
        })

      assert {:ok, %{api_key: "sk-ant-secret-key-1234", model: "claude-opus-4-1"}} =
               Llm.resolve(tenant.id, :extraction)

      assert {:ok, %{model: "claude-sonnet-4-5"}} = Llm.resolve(tenant.id, :classification)

      # merge_model was left nil -> falls back to the server default (Haiku).
      assert {:ok, %{model: "claude-haiku-4-5-20251001"}} = Llm.resolve(tenant.id, :merge)
    end

    test "upsert is idempotent per tenant (one row, updates in place)" do
      tenant = fixture(:tenant)
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "sk-ant-a"})
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"extraction_model" => "m-x"})

      # Both persisted on the single row.
      assert {:ok, %{api_key: "sk-ant-a", model: "m-x"}} = Llm.resolve(tenant.id, :extraction)

      count =
        from(s in TenantLlmSettings, where: s.tenant_id == ^tenant.id, select: count(s.id))
        |> AdminRepo.one()

      assert count == 1
    end

    test "resolve/2 is tenant-scoped — A and B each get their own key + model (review #17)" do
      a = fixture(:tenant)
      b = fixture(:tenant)

      {:ok, _} =
        Llm.upsert_settings(a.id, %{"api_key" => "sk-ant-AAAA", "extraction_model" => "model-a"})

      {:ok, _} =
        Llm.upsert_settings(b.id, %{"api_key" => "sk-ant-BBBB", "extraction_model" => "model-b"})

      assert {:ok, %{api_key: "sk-ant-AAAA", model: "model-a"}} = Llm.resolve(a.id, :extraction)
      assert {:ok, %{api_key: "sk-ant-BBBB", model: "model-b"}} = Llm.resolve(b.id, :extraction)

      # No cross-tenant leakage in either direction.
      refute match?({:ok, %{api_key: "sk-ant-BBBB"}}, Llm.resolve(a.id, :extraction))
      refute match?({:ok, %{api_key: "sk-ant-AAAA"}}, Llm.resolve(b.id, :extraction))
    end

    test "resolve/2 returns {:error, :no_api_key} when no key is configured" do
      tenant = fixture(:tenant)
      assert {:error, :no_api_key} = Llm.resolve(tenant.id, :extraction)

      # A settings row with only models but no key is still "no key".
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"extraction_model" => "m-x"})
      assert {:error, :no_api_key} = Llm.resolve(tenant.id, :extraction)
      refute Llm.has_api_key?(tenant.id)
    end

    test "rejects an invalid (blank) api_key and an implausible model id" do
      tenant = fixture(:tenant)
      assert {:error, changeset} = Llm.upsert_settings(tenant.id, %{"api_key" => "   "})
      assert %{api_key: _} = errors_on(changeset)

      assert {:error, cs2} =
               Llm.upsert_settings(tenant.id, %{"extraction_model" => "has spaces!"})

      assert %{extraction_model: _} = errors_on(cs2)
    end
  end

  describe "encryption at rest + redaction" do
    test "the api_key column is ciphertext, not the plaintext key" do
      tenant = fixture(:tenant)
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "sk-ant-plaintext-xyz"})

      %{rows: [[raw]]} =
        AdminRepo.query!(
          "SELECT api_key FROM tenant_llm_settings WHERE tenant_id = $1",
          [Ecto.UUID.dump!(tenant.id)]
        )

      assert is_binary(raw)
      refute raw == "sk-ant-plaintext-xyz"
      refute String.contains?(raw, "sk-ant-plaintext-xyz")

      # ... but it decrypts back on load.
      assert {:ok, %{api_key: "sk-ant-plaintext-xyz"}} = Llm.resolve(tenant.id, :extraction)
    end

    test "inspect/settings_view never expose the raw key" do
      tenant = fixture(:tenant)
      {:ok, settings} = Llm.upsert_settings(tenant.id, %{"api_key" => "sk-ant-hidden-9999"})

      # redact: true omits the value from inspect entirely.
      refute inspect(settings) =~ "sk-ant-hidden-9999"

      view = Llm.settings_view(settings)
      assert view.has_api_key == true
      assert view.api_key_hint == "...9999"
      refute Map.has_key?(view, :api_key)
      refute view |> inspect() =~ "sk-ant-hidden-9999"
    end
  end

  describe "audit" do
    test "setting a key writes an llm_config.key_set audit event WITHOUT the value" do
      tenant = fixture(:tenant)
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "sk-ant-audit-4242"})

      events =
        from(a in AuditLog,
          where: a.tenant_id == ^tenant.id and a.entity_type == "llm_config",
          select: a
        )
        |> AdminRepo.all()

      actions = Enum.map(events, & &1.action)
      assert "llm_config.updated" in actions
      assert "llm_config.key_set" in actions

      # No event's serialized state contains the raw key.
      refute events |> inspect() =~ "sk-ant-audit-4242"
    end

    test "a models-only update does not write a key_set event" do
      tenant = fixture(:tenant)
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "sk-ant-1"})
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"extraction_model" => "m-y"})

      key_set_count =
        from(a in AuditLog,
          where: a.tenant_id == ^tenant.id and a.action == "llm_config.key_set",
          select: count(a.id)
        )
        |> AdminRepo.one()

      # Only the first upsert (which set the key) emitted key_set.
      assert key_set_count == 1
    end
  end

  describe "record_usage/2 + usage_summary/2" do
    test "records events and aggregates by operation/model/source over a range" do
      tenant = fixture(:tenant)

      {:ok, _} =
        Llm.record_usage(tenant.id, %{
          operation: :extraction,
          model: "haiku",
          input_tokens: 100,
          output_tokens: 40,
          source_type: "newsletter"
        })

      {:ok, _} =
        Llm.record_usage(tenant.id, %{
          operation: :extraction,
          model: "haiku",
          input_tokens: 50,
          output_tokens: 10,
          source_type: "newsletter"
        })

      {:ok, _} =
        Llm.record_usage(tenant.id, %{
          operation: :classification,
          model: "sonnet",
          input_tokens: 5,
          output_tokens: 2,
          source_type: nil
        })

      %{data: rows, meta: meta} = Llm.usage_summary(tenant.id, [])

      extraction =
        Enum.find(rows, &(&1.operation == :extraction and &1.model == "haiku"))

      assert extraction.input_tokens == 150
      assert extraction.output_tokens == 50
      assert extraction.event_count == 2

      classification = Enum.find(rows, &(&1.operation == :classification))
      assert classification.input_tokens == 5
      assert classification.event_count == 1

      assert meta.total_count == length(rows)
    end

    test "usage_summary is tenant-isolated (A cannot see B's usage)" do
      a = fixture(:tenant)
      b = fixture(:tenant)

      {:ok, _} =
        Llm.record_usage(b.id, %{
          operation: :extraction,
          model: "haiku",
          input_tokens: 999,
          output_tokens: 999,
          source_type: "leak"
        })

      %{data: rows_a} = Llm.usage_summary(a.id, [])
      assert rows_a == []

      %{data: rows_b} = Llm.usage_summary(b.id, [])
      assert length(rows_b) == 1
    end

    test "paginates with a stable order across pages" do
      tenant = fixture(:tenant)

      # Three distinct groups on the same day (different models) → 3 summary rows.
      for model <- ["m-a", "m-b", "m-c"] do
        {:ok, _} =
          Llm.record_usage(tenant.id, %{
            operation: :extraction,
            model: model,
            input_tokens: 1,
            output_tokens: 1,
            source_type: "s"
          })
      end

      %{data: page1, meta: m1} = Llm.usage_summary(tenant.id, limit: 2, offset: 0)
      %{data: page2} = Llm.usage_summary(tenant.id, limit: 2, offset: 2)

      assert m1.total_count == 3
      assert length(page1) == 2
      assert length(page2) == 1

      # No overlap between pages (stable tiebreaker).
      keys1 = Enum.map(page1, & &1.model)
      keys2 = Enum.map(page2, & &1.model)
      assert keys1 -- keys2 == keys1
      assert Enum.sort(keys1 ++ keys2) == ["m-a", "m-b", "m-c"]
    end

    test "date-range filters narrow the window" do
      tenant = fixture(:tenant)
      now = DateTime.utc_now()
      old = DateTime.add(now, -10 * 86_400, :second)

      {:ok, _} =
        Llm.record_usage(tenant.id, %{
          operation: :extraction,
          model: "recent",
          input_tokens: 1,
          output_tokens: 1,
          occurred_at: now
        })

      {:ok, _} =
        Llm.record_usage(tenant.id, %{
          operation: :extraction,
          model: "ancient",
          input_tokens: 1,
          output_tokens: 1,
          occurred_at: old
        })

      from = DateTime.add(now, -2 * 86_400, :second)
      %{data: rows} = Llm.usage_summary(tenant.id, from: from)

      models = Enum.map(rows, & &1.model)
      assert "recent" in models
      refute "ancient" in models
    end
  end
end
