defmodule Loopctl.Knowledge.ClaudeMergeSynthesizerTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.Knowledge.ClaudeMergeSynthesizer, as: Synth
  alias Loopctl.Llm

  describe "synthesize/3 end-to-end (Req.Test seam, review #11)" do
    test "uses the tenant's key + merge model and records usage" do
      tenant = fixture(:tenant)

      {:ok, _} =
        Llm.upsert_settings(tenant.id, %{
          "api_key" => "sk-ant-merge-999",
          "merge_model" => "claude-opus-4-1"
        })

      Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(self(), {:req, conn.req_headers, JSON.decode!(body)})

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => ~s({"title":"Merged","body":"Both."})}],
          "usage" => %{"input_tokens" => 30, "output_tokens" => 15}
        })
      end)

      assert {:ok, %{title: "Merged", body: "Both."}} =
               Synth.synthesize(tenant.id, %{title: "A", body: "a"}, %{title: "B", body: "b"})

      assert_received {:req, headers, req_body}
      assert {"x-api-key", "sk-ant-merge-999"} in headers
      assert req_body["model"] == "claude-opus-4-1"

      %{data: [row]} = Llm.usage_summary(tenant.id, [])
      assert row.operation == :merge
      assert row.model == "claude-opus-4-1"
      assert row.input_tokens == 30
      assert row.output_tokens == 15
    end
  end

  describe "parse_text/1" do
    test "parses a clean JSON object" do
      assert {:ok, %{title: "T", body: "B"}} =
               Synth.parse_text(~s({"title": "T", "body": "B"}))
    end

    test "tolerates markdown fences and surrounding prose" do
      text = "Here you go:\n```json\n{\"title\": \"Merged\", \"body\": \"Body text\"}\n```\n"
      assert {:ok, %{title: "Merged", body: "Body text"}} = Synth.parse_text(text)
    end

    test "rejects empty title or body" do
      assert {:error, :unparseable_merge} = Synth.parse_text(~s({"title": "", "body": "B"}))
      assert {:error, :unparseable_merge} = Synth.parse_text(~s({"title": "T", "body": "   "}))
    end

    test "rejects non-JSON / missing keys / nil" do
      assert {:error, :unparseable_merge} = Synth.parse_text("not json")
      assert {:error, :unparseable_merge} = Synth.parse_text(~s({"title": "T"}))
      assert {:error, :unparseable_merge} = Synth.parse_text(nil)
    end
  end

  describe "synthesize/3 without a configured backend" do
    test "returns :no_api_key rather than a placeholder (mandatory BYO)" do
      # The tenant has no configured key → graceful degrade, no live HTTP call.
      tenant = fixture(:tenant)

      assert {:error, :no_api_key} =
               Synth.synthesize(tenant.id, %{title: "A", body: "a"}, %{title: "B", body: "b"})
    end
  end
end
