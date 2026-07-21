defmodule Loopctl.Workers.PromotionEvalWorkerTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.Llm
  alias Loopctl.Workers.PromotionEvalWorker

  describe "eligible_tenant_ids/0 mirrors Llm.resolve(_, :extraction)" do
    test "includes an openai_compatible tenant that has NO Anthropic api_key" do
      # US-41.3 review: the fan-out gate was a denormalized copy of the mandatory-BYO
      # rule that only knew about `api_key`. `Llm.resolve/2` -> `resolve_chat/2`
      # admits an `openai_compatible` tenant WITHOUT ever reading `api_key` — which is
      # nil for exactly the private-tier tenant this epic exists for — so the copy
      # silently excluded them from promotion eval (no error, no telemetry, no job).
      tenant = fixture(:tenant)

      {:ok, _} =
        Llm.upsert_settings(tenant.id, %{
          "chat_provider" => "openai_compatible",
          "chat_base_url" => "https://llm.example.com/v1",
          "extraction_model" => "meta-llama/Meta-Llama-3-8B-Instruct"
        })

      assert {:ok, %{provider: :openai_compatible}} = Llm.resolve(tenant.id, :extraction)
      assert tenant.id in PromotionEvalWorker.eligible_tenant_ids()
    end

    test "includes an anthropic tenant with a key" do
      tenant = fixture(:tenant)
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "sk-ant-eligible"})

      assert {:ok, %{provider: :anthropic}} = Llm.resolve(tenant.id, :extraction)
      assert tenant.id in PromotionEvalWorker.eligible_tenant_ids()
    end

    test "excludes a tenant with a settings row but no usable extraction target" do
      tenant = fixture(:tenant)
      {:ok, _} = Llm.upsert_settings(tenant.id, %{"embedding_api_key" => "sk-emb-only"})

      assert {:error, :no_api_key} = Llm.resolve(tenant.id, :extraction)
      refute tenant.id in PromotionEvalWorker.eligible_tenant_ids()
    end

    test "excludes a tenant with no settings row at all" do
      tenant = fixture(:tenant)

      assert {:error, :no_api_key} = Llm.resolve(tenant.id, :extraction)
      refute tenant.id in PromotionEvalWorker.eligible_tenant_ids()
    end
  end
end
