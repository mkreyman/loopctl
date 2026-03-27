defmodule Loopctl.Webhooks.SigningTest do
  use ExUnit.Case, async: true

  alias Loopctl.Webhooks.Signing

  describe "sign_payload/2" do
    test "returns sha256= prefixed hex HMAC" do
      payload = Jason.encode!(%{"event" => "test"})
      signature = Signing.sign_payload(payload, "test_secret_1234")

      assert String.starts_with?(signature, "sha256=")
      hex_part = String.replace_prefix(signature, "sha256=", "")
      assert String.length(hex_part) == 64
      assert Regex.match?(~r/^[0-9a-f]+$/, hex_part)
    end

    test "different secrets produce different signatures" do
      payload = Jason.encode!(%{"event" => "test"})
      sig_a = Signing.sign_payload(payload, "secret_a")
      sig_b = Signing.sign_payload(payload, "secret_b")

      assert sig_a != sig_b
      assert String.starts_with?(sig_a, "sha256=")
      assert String.starts_with?(sig_b, "sha256=")
    end

    test "signature is computed over raw bytes" do
      payload = Jason.encode!(%{"event" => "test"})
      secret = "my_secret"

      signature = Signing.sign_payload(payload, secret)

      # Manually compute expected HMAC
      expected_hmac =
        :crypto.mac(:hmac, :sha256, secret, payload)
        |> Base.encode16(case: :lower)

      assert signature == "sha256=#{expected_hmac}"
    end

    test "same payload and secret produce same signature" do
      payload = Jason.encode!(%{"event" => "test", "id" => "abc"})
      secret = "deterministic_secret"

      sig1 = Signing.sign_payload(payload, secret)
      sig2 = Signing.sign_payload(payload, secret)

      assert sig1 == sig2
    end

    test "different payloads produce different signatures" do
      secret = "same_secret"
      sig1 = Signing.sign_payload(Jason.encode!(%{"a" => 1}), secret)
      sig2 = Signing.sign_payload(Jason.encode!(%{"a" => 2}), secret)

      assert sig1 != sig2
    end
  end

  describe "prepare_payload/1" do
    test "returns JSON for small payloads" do
      payload = %{"event" => "test", "data" => %{"id" => "abc"}}
      json = Signing.prepare_payload(payload)

      assert is_binary(json)
      assert byte_size(json) < 65_536
      decoded = Jason.decode!(json)
      assert decoded["event"] == "test"
    end

    test "truncates oversized payloads" do
      # Create a payload larger than 64KB
      large_data = String.duplicate("x", 70_000)

      payload = %{
        "event" => "story.status_changed",
        "id" => "abc",
        "timestamp" => "2026-01-01T00:00:00Z",
        "data" => %{
          "story_id" => "123",
          "old_state" => large_data,
          "new_state" => large_data,
          "findings" => large_data
        }
      }

      json = Signing.prepare_payload(payload)
      decoded = Jason.decode!(json)

      assert decoded["truncated"] == true
      refute Map.has_key?(decoded["data"], "old_state")
      refute Map.has_key?(decoded["data"], "new_state")
      refute Map.has_key?(decoded["data"], "findings")
      assert decoded["data"]["story_id"] == "123"
      assert decoded["data"]["_truncated_fields"] == ["old_state", "new_state", "findings"]
    end

    test "preserves core fields when truncating" do
      large_data = String.duplicate("x", 70_000)

      payload = %{
        "id" => "event-123",
        "event" => "story.verified",
        "timestamp" => "2026-01-01T00:00:00Z",
        "data" => %{
          "story_id" => "story-456",
          "old_state" => large_data
        }
      }

      json = Signing.prepare_payload(payload)
      decoded = Jason.decode!(json)

      assert decoded["id"] == "event-123"
      assert decoded["event"] == "story.verified"
      assert decoded["timestamp"] == "2026-01-01T00:00:00Z"
      assert decoded["data"]["story_id"] == "story-456"
    end
  end
end
