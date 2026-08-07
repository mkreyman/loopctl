defmodule Loopctl.Knowledge.ExtractorTitleQualificationTest do
  @moduledoc """
  The ingestion ROOT CAUSE behind the duplicate-capture class (#617).

  The extractor mints every article title, and was shown only a coarse `source_type`
  ("web_article") — so a CHANGELOG file could only be titled "Changelog", which three
  unrelated documents on the hosted corpus duly did, colliding into a false duplicate
  group that 23 articles were retitled by hand to clear. These tests pin the link the
  fix hangs on: the source reaching the OUTGOING PROVIDER REQUEST on BOTH provider
  paths, under the one shared prompt. Asserting on prompt wording instead would pass
  just as happily against a prompt that says the opposite.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.Knowledge.ClaudeContentExtractor
  alias Loopctl.Knowledge.OpenAiContentExtractor
  alias Loopctl.Llm

  @ref "https://github.com/scrogson/oauth2/blob/master/CHANGELOG.md"

  defp articles_json,
    do: JSON.encode!([%{title: "T", body: "B", category: "pattern", tags: []}])

  defp capture(client, response) do
    Req.Test.stub(client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:req_body, JSON.decode!(body)})
      Req.Test.json(conn, response)
    end)
  end

  defp extract(extractor, tenant_id) do
    assert {:ok, _} =
             extractor.extract_from_content(tenant_id, "# Changelog",
               source_type: "web_article",
               source_ref: @ref
             )

    assert_received {:req_body, body}
    body
  end

  test "Anthropic: the user message names the source, under the shared prompt" do
    tenant = fixture(:tenant)
    {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => "k-anthropic"})

    capture(Loopctl.Llm.Anthropic, %{
      "content" => [%{"type" => "text", "text" => articles_json()}],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    })

    body = extract(ClaudeContentExtractor, tenant.id)

    assert body["system"] == ClaudeContentExtractor.system_prompt()
    assert [%{"role" => "user", "content" => user}] = body["messages"]
    assert user =~ "Source: #{@ref}"
  end

  test "OpenAI-compatible: the SAME prompt and the same source line" do
    tenant = fixture(:tenant)

    {:ok, _} =
      Llm.upsert_settings(tenant.id, %{
        "chat_provider" => "openai_compatible",
        "chat_base_url" => "https://local.example.com/v1",
        "chat_api_key" => "k-local",
        "extraction_model" => "llama-3.1-8b-instruct"
      })

    capture(Loopctl.Llm.OpenAiChat, %{
      "choices" => [%{"message" => %{"content" => articles_json()}}],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
    })

    body = extract(OpenAiContentExtractor, tenant.id)

    assert [%{"role" => "system", "content" => system}, %{"role" => "user", "content" => user}] =
             body["messages"]

    assert system == ClaudeContentExtractor.system_prompt()
    assert user =~ "Source: #{@ref}"
  end

  test "user_content/3 omits the source line rather than naming a placeholder" do
    # A model handed `Source: unknown` dutifully qualifies WITH it: "Changelog —
    # unknown" looks specific while distinguishing nothing.
    for missing <- [nil, ""] do
      message = ClaudeContentExtractor.user_content("body", "inline", missing)

      refute message =~ "Source:"
      refute message =~ "unknown"
    end

    assert ClaudeContentExtractor.user_content("body", "newsletter") =~ "Source type: newsletter"
  end

  test "the prompt asks for the qualification the Source line exists to enable" do
    # The wire tests above prove the source ARRIVES; only the prompt turns it into a
    # qualified title, and `body["system"] == system_prompt()` holds for ANY prompt —
    # including one with this paragraph deleted. So the acceptance criterion itself
    # (name the generic-title trap, qualify FROM the source, leave specific titles
    # alone, and define the no-Source branch that has no wire signature) is pinned here.
    prompt = ClaudeContentExtractor.system_prompt()

    for generic <- ["Changelog", "Configuration"], do: assert(prompt =~ generic)

    assert prompt =~ "Source line"
    assert prompt =~ "do not pad it"
    assert prompt =~ "NO Source line"
  end
end
