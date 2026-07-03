defmodule Loopctl.Knowledge.LlmExtractorTest do
  @moduledoc """
  Exercises the REAL review-finding extractor end-to-end via the
  `:anthropic_req_plug` Req.Test seam (no real API call): per-tenant key + model
  resolution, article parsing, mandatory BYO, and token-usage recording.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.Knowledge.LlmExtractor
  alias Loopctl.Llm

  defp context(tenant_id) do
    %{
      review_record_id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      story_id: Ecto.UUID.generate(),
      review_type: "enhanced",
      findings_count: 2,
      fixes_count: 2,
      summary: "Two findings, both fixed."
    }
  end

  defp stub_anthropic(articles_json, usage) do
    Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => articles_json}],
        "usage" => usage
      })
    end)
  end

  test "resolves the tenant key + extraction model, extracts articles, and records usage" do
    tenant = fixture(:tenant)

    {:ok, _} =
      Llm.upsert_settings(tenant.id, %{
        "api_key" => "sk-ant-review-key-555",
        "extraction_model" => "claude-sonnet-4-5"
      })

    articles_json =
      JSON.encode!([%{title: "Review pattern", body: "Body.", category: "pattern", tags: ["x"]}])

    stub_anthropic(articles_json, %{"input_tokens" => 210, "output_tokens" => 90})

    assert {:ok, [%{title: "Review pattern", category: :pattern}]} =
             LlmExtractor.extract_articles(tenant.id, context(tenant.id))

    %{data: [row]} = Llm.usage_summary(tenant.id, [])
    assert row.operation == :extraction
    assert row.model == "claude-sonnet-4-5"
    assert row.input_tokens == 210
    assert row.output_tokens == 90
    assert row.source_type == "review_finding"
  end

  test "returns {:error, :no_api_key} and records nothing when the tenant has no key" do
    tenant = fixture(:tenant)

    assert {:error, :no_api_key} = LlmExtractor.extract_articles(tenant.id, context(tenant.id))
    assert %{data: []} = Llm.usage_summary(tenant.id, [])
  end
end
