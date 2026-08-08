defmodule Loopctl.Webhooks.SigningTest do
  use ExUnit.Case, async: true

  alias Loopctl.Webhooks.Signing

  # The v1 scheme (issue #623). The property that matters is that the TIMESTAMP is
  # inside the MAC: without it a captured (body, signature) pair is a token that
  # never expires, and the timestamp header a receiver would date it by is
  # rewritable by whoever presents the pair.
  describe "sign/3 binds the timestamp into the signature" do
    test "emits t=<unix>,v1=<hex>" do
      signature = Signing.sign(~s({"event":"test"}), "secret", 1_700_000_000)

      assert "t=1700000000,v1=" <> hex = signature
      assert String.length(hex) == 64
      assert Regex.match?(~r/^[0-9a-f]+$/, hex)
    end

    test "the MAC covers <timestamp>.<body>, not the body alone" do
      body = ~s({"event":"test"})
      secret = "my_secret"

      "t=1700000000,v1=" <> hex = Signing.sign(body, secret, 1_700_000_000)

      expected =
        :crypto.mac(:hmac, :sha256, secret, "1700000000." <> body)
        |> Base.encode16(case: :lower)

      assert hex == expected
      # The legacy body-only MAC is a DIFFERENT value — a v1 signature is not a
      # renamed legacy one.
      refute hex == String.replace_prefix(Signing.sign_payload(body, secret), "sha256=", "")
    end

    test "the SAME body under a different timestamp yields a different signature" do
      body = ~s({"event":"test"})

      assert Signing.sign(body, "secret", 1_700_000_000) !=
               Signing.sign(body, "secret", 1_700_000_001)
    end
  end

  describe "verify/4 distinguishes a stale signature from a forged one" do
    setup do
      body = ~s({"event":"story.status_changed"})
      secret = "receiver_secret"
      now = 1_700_000_000

      {:ok, body: body, secret: secret, now: now, signature: Signing.sign(body, secret, now)}
    end

    test "a fresh, genuine signature verifies", ctx do
      assert :ok = Signing.verify(ctx.signature, ctx.body, ctx.secret, now: ctx.now)
    end

    test "a signature inside the tolerance window still verifies", ctx do
      inside = ctx.now + Signing.tolerance_seconds()
      assert :ok = Signing.verify(ctx.signature, ctx.body, ctx.secret, now: inside)
    end

    # THE replay case: the signature is genuine, the body is untouched, and it is
    # still refused — and refused for the RIGHT reason, so a receiver can log
    # "this is a replay" rather than "someone is forging".
    test "a genuine signature replayed past the window is out-of-tolerance", ctx do
      replayed_at = ctx.now + Signing.tolerance_seconds() + 1

      assert {:error, :timestamp_out_of_tolerance} =
               Signing.verify(ctx.signature, ctx.body, ctx.secret, now: replayed_at)
    end

    test "a signature from the future is out-of-tolerance too", ctx do
      assert {:error, :timestamp_out_of_tolerance} =
               Signing.verify(ctx.signature, ctx.body, ctx.secret,
                 now: ctx.now - Signing.tolerance_seconds() - 1
               )
    end

    # Moving the timestamp forward to escape the window invalidates the MAC,
    # because the MAC covers it. This is the property the whole scheme rests on.
    test "re-dating a captured signature breaks it", ctx do
      "t=" <> rest = ctx.signature
      [_ts, mac_part] = String.split(rest, ",", parts: 2)
      forged = "t=#{ctx.now + 10_000},#{mac_part}"

      assert {:error, :signature_mismatch} =
               Signing.verify(forged, ctx.body, ctx.secret, now: ctx.now + 10_000)
    end

    test "a modified body is a mismatch, not a tolerance failure", ctx do
      assert {:error, :signature_mismatch} =
               Signing.verify(ctx.signature, ctx.body <> " ", ctx.secret, now: ctx.now)
    end

    test "a wrong secret is a mismatch", ctx do
      assert {:error, :signature_mismatch} =
               Signing.verify(ctx.signature, ctx.body, "other_secret", now: ctx.now)
    end

    test "a legacy sha256= header is reported as malformed, never accepted", ctx do
      legacy = Signing.sign_payload(ctx.body, ctx.secret)

      assert {:error, :malformed_signature} =
               Signing.verify(legacy, ctx.body, ctx.secret, now: ctx.now)
    end

    test "a well-formed value naming another scheme is distinguishable", ctx do
      assert {:error, :unsupported_scheme} =
               Signing.verify("t=#{ctx.now},v2=deadbeef", ctx.body, ctx.secret, now: ctx.now)
    end

    test "garbage does not crash verification", ctx do
      for junk <- ["", "nonsense", "t=,v1=", "t=abc,v1=deadbeef", "v1=deadbeef"] do
        assert {:error, _} = Signing.verify(junk, ctx.body, ctx.secret, now: ctx.now)
      end
    end

    test "a non-hex MAC is a mismatch, not a crash", ctx do
      assert {:error, :signature_mismatch} =
               Signing.verify("t=#{ctx.now},v1=zzzz", ctx.body, ctx.secret, now: ctx.now)
    end
  end

  describe "sign_payload/2 (legacy, still emitted during the deprecation window)" do
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
