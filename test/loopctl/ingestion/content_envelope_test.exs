defmodule Loopctl.Ingestion.ContentEnvelopeTest do
  @moduledoc """
  #493 — `Loopctl.Ingestion.ContentEnvelope` encrypts ingestion document content at rest
  inside Oban job args. The contract: `wrap/1` output is Cloak ciphertext (NOT the
  plaintext, so `oban_jobs.args` never holds the document in the clear), round-trips
  through `unwrap/1`, and `unwrap/1` fails CLOSED on any tampered/malformed input so the
  worker can discard a poison pill instead of yielding garbage.
  """
  use ExUnit.Case, async: true

  alias Loopctl.Ingestion.ContentEnvelope

  describe "wrap/1 + unwrap/1 round-trip" do
    test "round-trips ASCII, Cyrillic, and multi-line content" do
      for content <- [
            "Some raw content about Elixir patterns",
            "Некоторый секретный документ по проектам",
            "line one\n\n# heading\n\nline two with émojis 🔐 and quotes \"x\"",
            String.duplicate("large payload ", 5000)
          ] do
        envelope = ContentEnvelope.wrap(content)
        assert {:ok, ^content} = ContentEnvelope.unwrap(envelope)
      end
    end

    test "the envelope is ciphertext — never the plaintext, and is Base64" do
      content = "sensitive document body that must not sit in oban_jobs plaintext"
      envelope = ContentEnvelope.wrap(content)

      refute envelope == content
      refute String.contains?(envelope, "sensitive document body")
      # Valid Base64 (JSON-safe transport).
      assert {:ok, _ciphertext} = Base.decode64(envelope)
    end

    test "encryption is non-deterministic (random IV) but both envelopes decrypt" do
      content = "same input, different ciphertext each time"
      e1 = ContentEnvelope.wrap(content)
      e2 = ContentEnvelope.wrap(content)

      refute e1 == e2
      assert {:ok, ^content} = ContentEnvelope.unwrap(e1)
      assert {:ok, ^content} = ContentEnvelope.unwrap(e2)
    end

    test "round-trips the empty string" do
      assert {:ok, ""} = ContentEnvelope.unwrap(ContentEnvelope.wrap(""))
    end
  end

  describe "unwrap/1 fails closed on malformed input" do
    test "non-Base64 input" do
      assert {:error, :corrupt_content_envelope} = ContentEnvelope.unwrap("not-base64!!!")
    end

    test "valid Base64 that is not valid ciphertext" do
      not_ciphertext = Base.encode64("just some plaintext bytes, no Cloak header")
      assert {:error, :corrupt_content_envelope} = ContentEnvelope.unwrap(not_ciphertext)
    end

    test "a truncated (tampered) envelope" do
      envelope = ContentEnvelope.wrap("authenticated content")
      truncated = String.slice(envelope, 0, div(String.length(envelope), 2))
      assert {:error, :corrupt_content_envelope} = ContentEnvelope.unwrap(truncated)
    end

    test "a bit-flipped (tampered) ciphertext fails the GCM auth tag" do
      envelope = ContentEnvelope.wrap("authenticated content")
      {:ok, ciphertext} = Base.decode64(envelope)
      # Flip a byte in the middle of the ciphertext, re-wrap as Base64.
      mid = div(byte_size(ciphertext), 2)
      <<head::binary-size(mid), byte, tail::binary>> = ciphertext
      tampered = Base.encode64(<<head::binary, Bitwise.bxor(byte, 0xFF), tail::binary>>)

      assert {:error, :corrupt_content_envelope} = ContentEnvelope.unwrap(tampered)
    end

    test "the empty string is not a valid envelope" do
      assert {:error, :corrupt_content_envelope} = ContentEnvelope.unwrap("")
    end
  end
end
