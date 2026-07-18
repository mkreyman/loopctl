defmodule Loopctl.Coordination.ChannelPostTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.Coordination.ChannelPost

  # A minimally-valid programmatic struct; create_changeset casts only the
  # caller fields on top of it.
  defp base_struct do
    %ChannelPost{
      tenant_id: Ecto.UUID.generate(),
      project_id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      expires_at: DateTime.utc_now()
    }
  end

  describe "create_changeset/2 validations" do
    test "valid with just a body" do
      cs = ChannelPost.create_changeset(base_struct(), %{"body" => "hello"})
      assert cs.valid?
    end

    test "requires body" do
      cs = ChannelPost.create_changeset(base_struct(), %{})
      refute cs.valid?
      assert %{body: _} = errors_on(cs)
    end

    test "rejects body over 16KB" do
      big = String.duplicate("x", 16_385)
      cs = ChannelPost.create_changeset(base_struct(), %{"body" => big})
      refute cs.valid?
      assert %{body: _} = errors_on(cs)
    end

    test "rejects key over 200 chars" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "key" => String.duplicate("k", 201)
        })

      refute cs.valid?
      assert %{key: _} = errors_on(cs)
    end

    test "rejects a keyed post without a session_id (per-session slot needs a session)" do
      cs = ChannelPost.create_changeset(base_struct(), %{"body" => "ok", "key" => "session_goal"})
      refute cs.valid?
      assert %{session_id: _} = errors_on(cs)
    end

    test "accepts a keyed post that carries a session_id" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "key" => "session_goal",
          "session_id" => "S1"
        })

      assert cs.valid?
    end

    test "body cap is byte-based, not grapheme-based" do
      # 8_193 multibyte (2-byte) chars = 16_386 bytes > 16_384, but only 8_193
      # graphemes — a grapheme-based cap would wrongly accept it.
      big = String.duplicate("é", 8_193)
      assert byte_size(big) > 16_384
      assert String.length(big) < 16_384
      cs = ChannelPost.create_changeset(base_struct(), %{"body" => big})
      refute cs.valid?
      assert %{body: _} = errors_on(cs)
    end

    test "rejects refs with a key outside the allowlist" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "refs" => %{"evil" => "value"}
        })

      refute cs.valid?
      assert %{refs: _} = errors_on(cs)
    end

    test "rejects an over-large refs value" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "refs" => %{"branch" => String.duplicate("x", 9_000)}
        })

      refute cs.valid?
      assert %{refs: _} = errors_on(cs)
    end

    test "no kind/category/type field exists on the schema" do
      fields = ChannelPost.__schema__(:fields)
      refute :kind in fields
      refute :category in fields
      refute :type in fields
    end

    test "rejects an over-long session_id (bounds the keyed-slot btree index row)" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "session_id" => String.duplicate("s", 201)
        })

      refute cs.valid?
      assert %{session_id: _} = errors_on(cs)
    end

    test "rejects an over-long host" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "host" => String.duplicate("h", 256)
        })

      refute cs.valid?
      assert %{host: _} = errors_on(cs)
    end

    test "a blank key is normalised to nil (no keyed slot, no forced session_id)" do
      cs = ChannelPost.create_changeset(base_struct(), %{"body" => "ok", "key" => ""})
      assert cs.valid?
      assert is_nil(Ecto.Changeset.get_field(cs, :key))
      # blank key must NOT force session_id to be required
      refute Map.has_key?(errors_on(cs), :session_id)
    end

    test "a whitespace-only key is normalised to nil" do
      cs = ChannelPost.create_changeset(base_struct(), %{"body" => "ok", "key" => "   "})
      assert cs.valid?
      assert is_nil(Ecto.Changeset.get_field(cs, :key))
    end

    test "rejects a whitespace-only body (must not land as an empty post)" do
      for blank <- ["   ", "\n\t", " \n "] do
        cs = ChannelPost.create_changeset(base_struct(), %{"body" => blank})
        refute cs.valid?, "expected #{inspect(blank)} body to be rejected"
        assert %{body: _} = errors_on(cs)
      end
    end

    test "refs value cap is byte-based, not grapheme-based" do
      # 200 four-byte chars = 800 bytes > 512, but only 200 graphemes — a
      # grapheme-based cap would wrongly accept it.
      val = String.duplicate("😀", 200)
      assert byte_size(val) > 512
      assert String.length(val) <= 512

      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "refs" => %{"branch" => val}
        })

      refute cs.valid?
      assert %{refs: _} = errors_on(cs)
    end

    test "an oversized, secret-shaped body is rejected on BOTH length and the secret scan" do
      # body is both oversized AND secret-shaped. The scan is bounded (only the
      # first @scan_byte_cap bytes are handed to the denylist — CPU-safe) but NOT
      # suppressed by the length error: a credential in the leading bytes still
      # records the secret error (and fires the secret_blocked signal).
      big_secret = "sk-" <> String.duplicate("a", 20_000)
      cs = ChannelPost.create_changeset(base_struct(), %{"body" => big_secret})
      refute cs.valid?
      assert Enum.any?(errors_on(cs).body, &(&1 =~ "secret"))
      assert Enum.any?(errors_on(cs).body, &(&1 =~ "byte"))
    end

    test "a length error on one field does not suppress another field's secret scan" do
      # Regression: an unrelated oversized field must NOT gate the secret scan of a
      # different field. A credential in body is still detected even when host blows
      # its byte cap — the write is rejected on both, and the secret error is present.
      oversized_host = String.duplicate("h", 300)

      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "here is my key sk-" <> String.duplicate("a", 30),
          "host" => oversized_host
        })

      refute cs.valid?
      assert Enum.any?(errors_on(cs).body, &(&1 =~ "secret"))
      assert Enum.any?(errors_on(cs).host, &(&1 =~ "byte"))
    end

    test "an oversized refs value cannot bypass the secret scan cap" do
      # refs values are also scanned over a bounded slice — an oversized refs value
      # (rejected by validate_refs) does not amplify the denylist scan, and a
      # credential in its leading bytes is still detected.
      big_ref = "sk-" <> String.duplicate("a", 2_000)

      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "refs" => %{"file" => big_ref}
        })

      refute cs.valid?
      assert %{refs: _} = errors_on(cs)
    end

    test "building the changeset has no side effects (no telemetry on the pure path)" do
      # Scope the handler to THIS test's tenant so a concurrent async test emitting
      # the same event can never trip our refute_receive.
      struct = base_struct()
      tenant_id = struct.tenant_id
      handler_id = "chanpost-pure-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:loopctl, :coordination, :secret_blocked],
        fn _event, _measurements, meta, _cfg ->
          if meta[:tenant_id] == tenant_id, do: send(test_pid, :secret_blocked_fired)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      ChannelPost.create_changeset(struct, %{"body" => "sk-" <> String.duplicate("a", 30)})

      refute_receive :secret_blocked_fired, 50
    end

    test "rejects a NUL byte in the body (would 500 at insert otherwise)" do
      cs = ChannelPost.create_changeset(base_struct(), %{"body" => "before" <> <<0>> <> "after"})
      refute cs.valid?
      assert %{body: _} = errors_on(cs)
    end

    test "rejects a NUL byte in a refs value (jsonb would 500 otherwise)" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "refs" => %{"branch" => "main" <> <<0>> <> "x"}
        })

      refute cs.valid?
      assert %{refs: _} = errors_on(cs)
    end

    test "rejects a NUL byte in session_id" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "session_id" => "S" <> <<0>> <> "1"
        })

      refute cs.valid?
      assert %{session_id: _} = errors_on(cs)
    end
  end

  describe "secret denylist" do
    test "rejects a secret in the body (422 path)" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "here is my key sk-" <> String.duplicate("a", 30)
        })

      refute cs.valid?
      assert %{body: _} = errors_on(cs)
    end

    test "rejects a secret in a refs value" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "refs" => %{"branch" => "lc_" <> String.duplicate("a", 30)}
        })

      refute cs.valid?
      assert %{refs: _} = errors_on(cs)
    end

    test "rejects a secret in the key" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "key" => "ghp_" <> String.duplicate("a", 30)
        })

      refute cs.valid?
      assert %{key: _} = errors_on(cs)
    end

    test "rejects a secret in session_id (persisted + echoed to peer sessions)" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "session_id" => "sk-" <> String.duplicate("a", 30)
        })

      refute cs.valid?
      assert %{session_id: _} = errors_on(cs)
    end

    test "rejects a secret in host" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "ok",
          "host" => "Bearer " <> String.duplicate("a", 30)
        })

      refute cs.valid?
      assert %{host: _} = errors_on(cs)
    end

    test "accumulates errors across every offending field in one pass" do
      cs =
        ChannelPost.create_changeset(base_struct(), %{
          "body" => "sk-" <> String.duplicate("a", 30),
          "session_id" => "S1",
          "key" => "lc_" <> String.duplicate("a", 30)
        })

      refute cs.valid?
      errors = errors_on(cs)
      assert %{body: _} = errors
      assert %{key: _} = errors
    end
  end
end
