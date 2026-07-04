defmodule Loopctl.Llm.RemediationTest do
  use ExUnit.Case, async: true

  alias Loopctl.Llm.Remediation

  describe "for_credential/1" do
    test ":anthropic names the api_key + the set_llm_config MCP tool" do
      r = Remediation.for_credential(:anthropic)

      assert r.action == "configure_llm"
      assert r.missing == ["api_key"]
      assert r.mcp_tool == "set_llm_config"
      assert r.api == "PATCH /api/v1/tenants/me/llm-config"
      assert r.example =~ "set_llm_config"
      assert r.example =~ "api_key"
      assert is_binary(r.docs) and r.docs =~ "onboarding"
      assert r.message =~ "Anthropic"
    end

    test ":embedding names the embedding_api_key + the set_llm_config MCP tool" do
      r = Remediation.for_credential(:embedding)

      assert r.action == "configure_llm"
      assert r.missing == ["embedding_api_key"]
      assert r.mcp_tool == "set_llm_config"
      assert r.api == "PATCH /api/v1/tenants/me/llm-config"
      assert r.example =~ "embedding_api_key"
      assert r.message =~ "semantic" or r.message =~ "embedding"
    end

    test "carries no secret-looking value (it only names fields)" do
      for cred <- [:anthropic, :embedding] do
        r = Remediation.for_credential(cred)
        blob = inspect(r)
        # The placeholder is angle-bracketed, never a real sk-... token.
        refute blob =~ ~r/sk-[A-Za-z0-9]{8}/
        assert r.example =~ "<your"
      end
    end
  end

  describe "for_fallback_reason/1" do
    test "maps the missing-embedding-key tag to the embedding remediation" do
      assert Remediation.for_fallback_reason("no_embedding_key") ==
               Remediation.for_credential(:embedding)
    end

    test "returns nil for transient/provider fallbacks (a key IS configured there)" do
      for tag <- [
            "embedding_circuit_open",
            "embedding_timeout",
            "embedding_provider_error_401",
            "embedding_request_failed",
            "embedding_crash",
            "embedding_error",
            nil
          ] do
        assert Remediation.for_fallback_reason(tag) == nil
      end
    end
  end
end
