defmodule Loopctl.Llm.ProviderErrorTest do
  @moduledoc """
  The shared provider-error sanitizer is the single chokepoint that keeps a masked
  API-key fragment (echoed in a provider error body) out of logs and
  `oban_jobs.errors`. It MUST be value-free for EVERY input shape (review #6).
  """
  use ExUnit.Case, async: true

  alias Loopctl.Llm.ProviderError

  describe "sanitize/1" do
    test "drops the api_error body but keeps the status" do
      body = %{"error" => %{"message" => "Incorrect API key provided: test-openai-...ZXY9"}}
      assert ProviderError.sanitize({:api_error, 401, body}) == {:api_error, 401, :provider_error}

      assert ProviderError.sanitize({:api_error, 500, "raw"}) ==
               {:api_error, 500, :provider_error}

      assert ProviderError.sanitize({:api_error, 200, body}) == {:api_error, 200, :provider_error}
      refute inspect(ProviderError.sanitize({:api_error, 401, body})) =~ "ZXY9"
    end

    test "collapses the 2-tuple api_error form" do
      assert ProviderError.sanitize({:api_error, 429}) == {:api_error, 429, :provider_error}
    end

    test "collapses transport + crash payloads to a value-free tag" do
      assert ProviderError.sanitize({:request_failed, %{secret: "x"}}) ==
               {:request_failed, :transport_error}

      assert ProviderError.sanitize({:embedding_crash, "boom sk-leak"}) ==
               {:embedding_crash, :exception}
    end

    test "preserves bare atoms (they cannot carry a secret)" do
      assert ProviderError.sanitize(:timeout) == :timeout
      assert ProviderError.sanitize(:circuit_open) == :circuit_open
      assert ProviderError.sanitize(:no_api_key) == :no_api_key
    end

    test "collapses a BARE provider body (string or map) — the #6 key-bearing shapes" do
      # The only key-bearing shapes besides {:api_error,...}: a raw string body or a
      # decoded JSON map body. Both must collapse — never pass through.
      assert ProviderError.sanitize("Invalid x-api-key: sk-ant-...WXYZ") == :provider_error
      assert ProviderError.sanitize(%{"error" => "sk-ant-...WXYZ"}) == :provider_error

      for term <- ["Invalid x-api-key: sk-ant-...WXYZ", %{"error" => "sk-ant-...WXYZ"}] do
        refute term |> ProviderError.sanitize() |> inspect() =~ "WXYZ"
      end
    end

    test "PRESERVES structured domain-error tuples (they carry no key)" do
      # Must NOT collapse — replacing e.g. an insert-failed reason with a misleading
      # :provider_error would hurt operators, and these carry no secret.
      assert ProviderError.sanitize({:url_blocked, :blocked_ip}) == {:url_blocked, :blocked_ip}

      assert ProviderError.sanitize({:insert_failed, :article, :some_changeset}) ==
               {:insert_failed, :article, :some_changeset}
    end
  end

  describe "log_tag/1" do
    test "never includes a body and unwraps {:error, _}" do
      body = %{"error" => "Incorrect API key: test-openai-...ZXY9"}
      assert ProviderError.log_tag({:api_error, 401, body}) == "api_error status=401"
      assert ProviderError.log_tag({:error, {:api_error, 500, body}}) == "api_error status=500"
      assert ProviderError.log_tag({:request_failed, %{secret: "x"}}) == "request_failed"
      refute ProviderError.log_tag({:api_error, 401, body}) =~ "ZXY9"
    end
  end
end
