defmodule Loopctl.ConfigCloakCiphersTest do
  use ExUnit.Case, async: true

  alias Loopctl.Config
  alias Mix.Tasks.Loopctl.CheckEnvDocs

  # A distinct valid key per role, so a test that asserts on ORDER cannot pass by accident.
  @active Base.encode64(:binary.copy(<<1>>, 32))
  @retired Base.encode64(:binary.copy(<<2>>, 32))
  @second_retired Base.encode64(:binary.copy(<<3>>, 32))

  describe "cloak_ciphers!/3 — the active cipher" do
    test "an install that sets only CLOAK_KEY is unchanged: one cipher on the legacy tag" do
      assert [default: {Cloak.Ciphers.AES.GCM, opts}] = Config.cloak_ciphers!(@active)
      assert opts[:tag] == Config.cloak_default_tag()
      assert opts[:key] == :binary.copy(<<1>>, 32)
      assert opts[:iv_length] == 12
    end

    test "CLOAK_KEY_TAG overrides the tag; a blank value falls back to the default" do
      assert [default: {_module, opts}] = Config.cloak_ciphers!(@active, "AES.GCM.V2")
      assert opts[:tag] == "AES.GCM.V2"

      for blank <- [nil, "", "   "] do
        assert [default: {_module, fallback}] = Config.cloak_ciphers!(@active, blank)
        assert fallback[:tag] == Config.cloak_default_tag()
      end
    end

    # Cloak's framing encodes a tag of up to 127 bytes, so an over-long or non-printable one
    # boots and is stamped into every header — and then Rotation.active_tag/0, which reads
    # the tag back off a probe, raises "the vault is misconfigured" and the whole rotation
    # tooling is unusable during a rotation. The bound belongs where the value is admitted.
    test "a tag over the bound, or holding a non-printable byte, raises at boot" do
      long = String.duplicate("A", Config.cloak_max_tag_bytes() + 1)

      assert_raise ArgumentError, ~r/CLOAK_KEY_TAG is #{byte_size(long)} bytes/, fn ->
        Config.cloak_ciphers!(@active, long)
      end

      assert_raise ArgumentError, ~r/CLOAK_KEY_TAG holds a byte outside printable ASCII/, fn ->
        Config.cloak_ciphers!(@active, "AES.GCM.\x01")
      end

      assert [default: {_module, opts}] =
               Config.cloak_ciphers!(@active, String.duplicate("A", Config.cloak_max_tag_bytes()))

      assert byte_size(opts[:tag]) == Config.cloak_max_tag_bytes()
    end

    # A retired tag is matched against the tag READ OFF stored bytes, so the same bound
    # applies: one Rotation cannot decode buckets those rows as :untagged and fails them.
    test "a retired entry's tag is bounded the same way, named by position" do
      long = String.duplicate("B", Config.cloak_max_tag_bytes() + 1)

      assert_raise ArgumentError, ~r/CLOAK_RETIRED_KEYS entry 1's tag is/, fn ->
        Config.cloak_ciphers!(@active, "AES.GCM.V2", "#{long}:#{@retired}")
      end
    end

    # Cloak.Vault.encrypt/2 takes hd(ciphers) — NOT the entry labelled :default. If a
    # retired key ever sorted first, every new write would go out under a dead key.
    test "the active cipher is FIRST, ahead of every retired key" do
      ciphers = Config.cloak_ciphers!(@active, "AES.GCM.V2", "AES.GCM.V1:#{@retired}")

      assert [{_first_label, {_module, opts}} | _rest] = ciphers
      assert opts[:key] == :binary.copy(<<1>>, 32)
    end
  end

  describe "cloak_ciphers!/3 — retired keys" do
    test "parses a comma-separated TAG:BASE64 list, tolerating whitespace" do
      ciphers =
        Config.cloak_ciphers!(
          @active,
          "AES.GCM.V3",
          " AES.GCM.V2:#{@retired} , AES.GCM.V1:#{@second_retired} ,"
        )

      assert [_active, {_l1, {_m1, first}}, {_l2, {_m2, second}}] = ciphers
      assert first[:tag] == "AES.GCM.V2"
      assert first[:key] == :binary.copy(<<2>>, 32)
      assert second[:tag] == "AES.GCM.V1"
      assert second[:key] == :binary.copy(<<3>>, 32)
    end

    test "an UNSET CLOAK_RETIRED_KEYS adds nothing" do
      assert [{:default, _cipher}] = Config.cloak_ciphers!(@active, nil, nil)
    end

    # A deploy script that builds the value from an empty list produces "" (the likeliest
    # shape by far), "," or " " — none of them the same statement as "unset". Accepting one
    # yields zero retired ciphers on a boot the operator believes carries them, which is the
    # silent drop this guard exists to stop.
    test "a value the operator SET that names no entries raises rather than meaning none" do
      for value <- ["", "  ", ",", ",,", " , "] do
        assert_raise ArgumentError, ~r/is set but names no entries/, fn ->
          Config.cloak_ciphers!(@active, nil, value)
        end
      end
    end

    # The position has to be the operator's field number in the raw string, or the message
    # points at an entry they cannot find. Blanks are still tolerated; they still count.
    test "the position names the raw comma-separated field, blanks included" do
      assert_raise ArgumentError, ~r/entry 3 is not TAG:BASE64_KEY/, fn ->
        Config.cloak_ciphers!(@active, "AES.GCM.V2", ",,#{@retired}")
      end
    end

    # The whole reason the tag is part of the entry. Cloak picks a decrypt cipher by tag
    # and takes the FIRST hit, so an operator who swaps CLOAK_KEY but forgets to bump
    # CLOAK_KEY_TAG would hand every pre-rotation row to the new key and get GCM auth
    # failures. Boot has to stop there, not at the first read.
    test "a retired key reusing the ACTIVE tag raises, naming CLOAK_KEY_TAG" do
      error =
        assert_raise ArgumentError, fn ->
          Config.cloak_ciphers!(@active, nil, "#{Config.cloak_default_tag()}:#{@retired}")
        end

      assert error.message =~ "CLOAK_KEY_TAG"
    end

    test "two retired entries sharing a tag raise — only the first would ever be tried" do
      assert_raise ArgumentError, ~r/repeats the tag/, fn ->
        Config.cloak_ciphers!(
          @active,
          "AES.GCM.V3",
          "AES.GCM.V1:#{@retired},AES.GCM.V1:#{@second_retired}"
        )
      end
    end

    test "an entry with no ':' raises rather than being dropped" do
      assert_raise ArgumentError, ~r/entry 1 is not TAG:BASE64_KEY/, fn ->
        Config.cloak_ciphers!(@active, "AES.GCM.V2", @retired)
      end
    end

    test "a blank tag raises" do
      assert_raise ArgumentError, ~r/entry 1 has a blank tag/, fn ->
        Config.cloak_ciphers!(@active, "AES.GCM.V2", ":#{@retired}")
      end
    end

    test "the failing entry is identified by position, not by echoing key material" do
      error =
        assert_raise ArgumentError, fn ->
          Config.cloak_ciphers!(@active, "AES.GCM.V3", "AES.GCM.V2:#{@retired},AES.GCM.V1:!!!!")
        end

      assert error.message =~ "CLOAK_RETIRED_KEYS entry 2"
      refute error.message =~ @retired
    end

    test "more retired keys than the cap raises, pointing at the re-encryption pass" do
      many = Enum.map_join(1..17, ",", fn i -> "AES.GCM.R#{i}:#{@retired}" end)

      assert_raise ArgumentError, ~r/mix loopctl.reencrypt_secrets/, fn ->
        Config.cloak_ciphers!(@active, "AES.GCM.V99", many)
      end
    end
  end

  describe "cloak_ciphers!/3 — key material validation" do
    # Cloak.Ciphers.AES.GCM hardcodes :aes_256_gcm. A short key is accepted by config and
    # then blows up on the first encrypt — which, for a RETIRED key, means rows nobody can
    # read. Both roles go through the same check.
    test "a key that is not 32 bytes raises, for the active key and for a retired one" do
      short = Base.encode64(:binary.copy(<<9>>, 16))

      assert_raise ArgumentError, ~r/CLOAK_KEY decodes to 16 bytes/, fn ->
        Config.cloak_ciphers!(short)
      end

      assert_raise ArgumentError, ~r/entry 1 decodes to 16 bytes/, fn ->
        Config.cloak_ciphers!(@active, "AES.GCM.V2", "AES.GCM.V1:#{short}")
      end
    end

    test "a non-base64 key raises without echoing the value" do
      error = assert_raise ArgumentError, fn -> Config.cloak_ciphers!("not base64 at all!") end

      assert error.message =~ "CLOAK_KEY is not valid base64"
      refute error.message =~ "not base64 at all!"
    end
  end

  # The reads must stay LITERAL in runtime.exs: that is the shape `mix loopctl.check_env_docs`
  # scans, and it is what forces the deploy/FLY_SECRETS.md row for each of them.
  test "the CLOAK_* vars are read literally in runtime.exs, under the env-docs guard" do
    scanned = "config/runtime.exs" |> File.read!() |> CheckEnvDocs.scan_env_vars()

    for var <- ~w(CLOAK_KEY CLOAK_KEY_TAG CLOAK_RETIRED_KEYS) do
      assert Enum.member?(scanned, var), "expected #{var} to be a literal System.get_env/1 read"
    end
  end
end
