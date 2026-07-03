defmodule Loopctl.Knowledge.ClaudeContentExtractorTest do
  @moduledoc """
  Exercises the REAL extractor end-to-end via the `:anthropic_req_plug` Req.Test
  seam (no real API call): per-tenant key + model resolution, article parsing, and
  the token-usage recording that the worker relies on.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.Knowledge.ClaudeContentExtractor
  alias Loopctl.Llm

  # Canned Anthropic Messages response: one article + a usage block.
  defp stub_anthropic(articles_json, usage) do
    Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
      # Capture the request for header/model assertions.
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:anthropic_request, conn.req_headers, JSON.decode!(body)})

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
        "api_key" => "test-anthropic-tenant-key-777",
        "extraction_model" => "claude-opus-4-1"
      })

    articles_json =
      JSON.encode!([%{title: "T1", body: "B1", category: "pattern", tags: ["x"]}])

    stub_anthropic(articles_json, %{"input_tokens" => 321, "output_tokens" => 123})

    assert {:ok, [%{title: "T1", category: :pattern}]} =
             ClaudeContentExtractor.extract_from_content(tenant.id, "raw content",
               source_type: "newsletter"
             )

    # The request used THIS tenant's key + resolved model.
    assert_received {:anthropic_request, headers, req_body}
    assert {"x-api-key", "test-anthropic-tenant-key-777"} in headers
    assert req_body["model"] == "claude-opus-4-1"

    # A usage event was recorded with the right tokens/operation/model/source.
    %{data: [row]} = Llm.usage_summary(tenant.id, [])
    assert row.operation == :extraction
    assert row.model == "claude-opus-4-1"
    assert row.input_tokens == 321
    assert row.output_tokens == 123
    assert row.source_type == "newsletter"
  end

  test "returns {:error, :no_api_key} and records nothing when the tenant has no key" do
    tenant = fixture(:tenant)

    assert {:error, :no_api_key} =
             ClaudeContentExtractor.extract_from_content(tenant.id, "raw", source_type: "x")

    assert %{data: []} = Llm.usage_summary(tenant.id, [])
  end

  test "surfaces an API error and records no usage" do
    tenant = fixture(:tenant)
    {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "test-anthropic-1"})

    Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => "rate_limited"})
    end)

    assert {:error, {:api_error, 429, _}} =
             ClaudeContentExtractor.extract_from_content(tenant.id, "raw", source_type: "x")

    assert %{data: []} = Llm.usage_summary(tenant.id, [])
  end
end
