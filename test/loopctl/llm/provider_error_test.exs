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

      assert ProviderError.log_tag({:api_error, 401, body}) ==
               "api_error status=401 provider_error"

      assert ProviderError.log_tag({:error, {:api_error, 500, body}}) ==
               "api_error status=500 provider_error"

      assert ProviderError.log_tag({:request_failed, %{secret: "x"}}) == "request_failed"
      refute ProviderError.log_tag({:api_error, 401, body}) =~ "ZXY9"
    end

    test "names the classification, so an operator can see WHY a 400 happened" do
      # The defect this closes: 80 articles failed identically for 16 hours and every
      # record of it — logs AND oban_jobs.errors — said only "status=400". The reason
      # had to be recovered by bisecting against the live provider.
      body = %{
        "error" => %{"message" => "Invalid 'input': maximum context length is 8192 tokens."}
      }

      assert ProviderError.log_tag({:api_error, 400, body}) ==
               "api_error status=400 context_length_exceeded"
    end
  end

  describe "classify/1" do
    test "recognises input-too-long across vendor spellings" do
      for message <- [
            "Invalid 'input': maximum context length is 8192 tokens.",
            "This model's maximum context length is 8192 tokens, however you requested 9001.",
            "Please reduce the length of the messages.",
            "input is too long for the model",
            "string too long"
          ] do
        body = %{"error" => %{"message" => message}}

        assert ProviderError.classify(body) == :context_length_exceeded,
               "failed to classify: #{message}"
      end
    end

    test "reads the error code as well as the message" do
      body = %{"error" => %{"code" => "context_length_exceeded", "message" => nil}}
      assert ProviderError.classify(body) == :context_length_exceeded
    end

    test "is case-insensitive" do
      body = %{"error" => %{"message" => "MAXIMUM CONTEXT LENGTH IS 8192 TOKENS"}}
      assert ProviderError.classify(body) == :context_length_exceeded
    end

    test "does NOT claim context-length for unrelated failures" do
      # A false :context_length_exceeded is worse than none: it would send the worker
      # down the shrink ladder, re-billing the provider two extra times for an error
      # that shrinking cannot fix.
      for body <- [
            %{"error" => %{"message" => "Incorrect API key provided: sk-...ZXY9"}},
            %{"error" => %{"message" => "Rate limit reached for requests"}},
            %{"error" => %{"code" => "invalid_api_key"}},
            %{"error" => "some string body"},
            "a bare string body",
            %{"unexpected" => "shape"},
            nil
          ] do
        assert ProviderError.classify(body) == :provider_error,
               "wrongly classified as context-length: #{inspect(body)}"
      end
    end

    test "is idempotent on an already-classified tag" do
      # sanitize/1 runs again at every worker boundary. If classify/1 flattened a tag
      # back to :provider_error the workers' retry ladder would never fire — the exact
      # half-fix that would leave the 80 articles un-embedded while looking fixed.
      assert ProviderError.classify(:context_length_exceeded) == :context_length_exceeded
      assert ProviderError.classify(:provider_error) == :provider_error
    end

    test "keeps no byte of the body — the return is always a fixed atom" do
      body = %{"error" => %{"message" => "maximum context length exceeded for sk-...ZXY9"}}
      result = ProviderError.classify(body)

      assert result in [:provider_error, :context_length_exceeded]
      refute inspect(result) =~ "ZXY9"
    end
  end

  describe "sanitize/1 classification round-trip" do
    test "carries the classification into the Oban error term" do
      body = %{"error" => %{"message" => "maximum context length is 8192 tokens"}}

      assert ProviderError.sanitize({:api_error, 400, body}) ==
               {:api_error, 400, :context_length_exceeded}
    end

    test "a second sanitize pass preserves it (worker boundaries re-sanitize)" do
      once =
        ProviderError.sanitize(
          {:api_error, 400, %{"error" => %{"code" => "context_length_exceeded"}}}
        )

      assert ProviderError.sanitize(once) == once
      assert once == {:api_error, 400, :context_length_exceeded}
    end

    test "preserves the throttle 4-tuple for a classified tag too" do
      term = {:api_error, 429, :provider_error, 30}
      assert ProviderError.sanitize(term) == term
    end
  end
end
