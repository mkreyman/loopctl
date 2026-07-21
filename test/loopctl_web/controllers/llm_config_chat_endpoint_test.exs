defmodule LoopctlWeb.LlmConfigChatEndpointTest do
  @moduledoc """
  The pluggable chat endpoint's WRITE surface (US-41.3, AC-41.3.3).

  It is the EXISTING `set_llm_config` API (`PATCH /tenants/me/llm-config`), which
  stays ROLE `:user` — the epic's agent-manageability audit is corrected to
  user-write for this row, because the same PATCH stores tenant secrets and
  CLAUDE.md's role checklist forbids downgrading a secret-bearing write to `:agent`.
  """
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Llm

  @base_url "https://local.example.com/v1"
  # US-41.3 review: selecting openai_compatible REQUIRES a model the endpoint can
  # serve — the server default is an Anthropic id no local server will honour.
  @model "llama-3.1-8b-instruct"

  defp auth_conn(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp user_conn(conn) do
    tenant = fixture(:tenant)
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
    {tenant, auth_conn(conn, raw_key)}
  end

  defp stub_probe_ok do
    Req.Test.stub(Loopctl.Llm.OpenAiChat, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(self(), {:probe, conn.request_path, conn.req_headers, JSON.decode!(raw)})
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "pong"}}]})
    end)
  end

  describe "role (AC-41.3.3): the write stays :user" do
    test "an agent key is 403'd", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

      conn
      |> auth_conn(raw_key)
      |> patch(~p"/api/v1/tenants/me/llm-config", %{
        chat_provider: "openai_compatible",
        chat_base_url: @base_url,
        chat_api_key: "local-key",
        extraction_model: @model
      })
      |> json_response(403)

      assert Llm.chat_provider(tenant.id) == :anthropic
    end

    test "an orchestrator key is 403'd", %{conn: conn} do
      tenant = fixture(:tenant)
      {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :orchestrator})

      conn
      |> auth_conn(raw_key)
      |> patch(~p"/api/v1/tenants/me/llm-config", %{chat_base_url: @base_url})
      |> json_response(403)
    end
  end

  describe "the config-time probe (AC-41.3.3)" do
    test "a trivial completion is issued BEFORE persisting, and the config is saved on success",
         %{conn: conn} do
      {tenant, conn} = user_conn(conn)
      stub_probe_ok()

      body =
        conn
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          chat_provider: "openai_compatible",
          chat_base_url: @base_url,
          chat_api_key: "local-secret-key",
          extraction_model: "llama-3.1-8b-instruct"
        })
        |> json_response(200)

      assert_received {:probe, "/v1/chat/completions", headers, probe_body}
      assert {"authorization", "Bearer local-secret-key"} in headers
      assert probe_body["max_tokens"] == 1

      # The endpoint is echoed (it is not a secret); the key never is.
      assert body["chat_provider"] == "openai_compatible"
      assert body["chat_base_url"] == @base_url
      assert body["has_chat_key"] == true
      assert body["chat_api_key_hint"] == "...-key"
      refute Map.has_key?(body, "chat_api_key")
      refute inspect(body) =~ "local-secret-key"

      assert Llm.chat_provider(tenant.id) == :openai_compatible
      assert Llm.chat_base_url(tenant.id) == @base_url
    end

    test "an unreachable endpoint is a 422 and NOTHING is persisted", %{conn: conn} do
      {tenant, conn} = user_conn(conn)

      Req.Test.stub(Loopctl.Llm.OpenAiChat, fn c ->
        Req.Test.transport_error(c, :econnrefused)
      end)

      body =
        conn
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          chat_provider: "openai_compatible",
          chat_base_url: @base_url,
          chat_api_key: "local-key",
          extraction_model: @model
        })
        |> json_response(422)

      assert body["error"]["code"] == "chat_endpoint_unreachable"
      assert body["error"]["message"] =~ @base_url
      assert body["error"]["remediation"]["action"] == "configure_llm"
      assert body["error"]["remediation"]["mcp_tool"] == "set_llm_config"
      refute inspect(body) =~ "local-key"

      assert Llm.chat_provider(tenant.id) == :anthropic
    end

    test "an auth-rejected endpoint is DISTINGUISHED from unreachable", %{conn: conn} do
      {_tenant, conn} = user_conn(conn)

      Req.Test.stub(Loopctl.Llm.OpenAiChat, fn c ->
        c |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "bad key"})
      end)

      body =
        conn
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          chat_provider: "openai_compatible",
          chat_base_url: @base_url,
          chat_api_key: "local-key",
          extraction_model: @model
        })
        |> json_response(422)

      assert body["error"]["code"] == "chat_endpoint_auth_rejected"
    end

    test "a non-OpenAI-compatible 200 is DISTINGUISHED too", %{conn: conn} do
      {_tenant, conn} = user_conn(conn)

      Req.Test.stub(Loopctl.Llm.OpenAiChat, fn c ->
        Req.Test.json(c, %{"hello" => "i am not openai"})
      end)

      body =
        conn
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          chat_provider: "openai_compatible",
          chat_base_url: @base_url,
          chat_api_key: "local-key",
          extraction_model: @model
        })
        |> json_response(422)

      assert body["error"]["code"] == "chat_endpoint_not_openai_compatible"
    end
  end

  describe "the probe exercises the models REAL calls resolve to (AC-41.3.3)" do
    test "every DISTINCT per-operation model is probed, not a hardcoded default",
         %{conn: conn} do
      {tenant, conn} = user_conn(conn)
      stub_probe_ok()

      conn
      |> patch(~p"/api/v1/tenants/me/llm-config", %{
        chat_provider: "openai_compatible",
        chat_base_url: @base_url,
        chat_api_key: "local-key",
        extraction_model: @model,
        merge_model: "qwen2.5-14b-instruct"
      })
      |> json_response(200)

      probed = probed_models()
      assert Enum.sort(probed) == Enum.sort([@model, "qwen2.5-14b-instruct"])

      # And those are exactly the models a real call resolves to — classification
      # was never set, so it follows extraction, NOT the Anthropic server default.
      assert {:ok, %{model: @model}} = Llm.resolve(tenant.id, :classification)
      assert {:ok, %{model: "qwen2.5-14b-instruct"}} = Llm.resolve(tenant.id, :merge)
    end

    test "a model whose probe FAILS blocks the whole write", %{conn: conn} do
      {tenant, conn} = user_conn(conn)

      Req.Test.stub(Loopctl.Llm.OpenAiChat, fn c ->
        {:ok, raw, c} = Plug.Conn.read_body(c)

        case JSON.decode!(raw)["model"] do
          "not-served-here" -> c |> Plug.Conn.put_status(404) |> Req.Test.json(%{"e" => "no"})
          _ -> Req.Test.json(c, %{"choices" => [%{"message" => %{"content" => "pong"}}]})
        end
      end)

      conn
      |> patch(~p"/api/v1/tenants/me/llm-config", %{
        chat_provider: "openai_compatible",
        chat_base_url: @base_url,
        chat_api_key: "local-key",
        extraction_model: @model,
        classification_model: "not-served-here"
      })
      |> json_response(422)

      assert Llm.chat_provider(tenant.id) == :anthropic
    end
  end

  describe "what counts as a change worth probing (AC-41.3.3)" do
    setup %{conn: conn} do
      {tenant, conn} = user_conn(conn)
      stub_probe_ok()

      conn
      |> patch(~p"/api/v1/tenants/me/llm-config", %{
        chat_provider: "openai_compatible",
        chat_base_url: @base_url,
        chat_api_key: "first-key",
        extraction_model: @model
      })
      |> json_response(200)

      flush_probes()
      {:ok, tenant: tenant}
    end

    test "a KEY ROTATION against the same host is probed", %{tenant: tenant} do
      build_conn()
      |> auth_conn(user_key(tenant))
      |> patch(~p"/api/v1/tenants/me/llm-config", %{chat_api_key: "rotated-key"})
      |> json_response(200)

      assert_received {:probe, _path, headers, _body}
      assert {"authorization", "Bearer rotated-key"} in headers
    end

    test "a MODEL change on an already-configured endpoint is probed", %{tenant: tenant} do
      build_conn()
      |> auth_conn(user_key(tenant))
      |> patch(~p"/api/v1/tenants/me/llm-config", %{merge_model: "qwen2.5-14b-instruct"})
      |> json_response(200)

      # EVERY resolved model is re-probed on a chat-surface change, not just the
      # one that moved — the guarantee is about the configuration that will run.
      assert Enum.sort(probed_models()) == Enum.sort([@model, "qwen2.5-14b-instruct"])
    end

    test "a PATCH touching nothing on the chat surface probes NOTHING", %{tenant: tenant} do
      # The Anthropic key is not part of the chat surface for this tenant.
      build_conn()
      |> auth_conn(user_key(tenant))
      |> patch(~p"/api/v1/tenants/me/llm-config", %{embedding_model: "text-embedding-3-large"})
      |> json_response(200)

      refute_received {:probe, _path, _headers, _body}
    end
  end

  describe "SSRF (the chat base url is TENANT-WRITABLE)" do
    test "a private-range host is refused before any request is made", %{conn: conn} do
      {tenant, conn} = user_conn(conn)

      # No Req.Test stub is installed: reaching the transport at all would raise.
      body =
        conn
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          chat_provider: "openai_compatible",
          chat_base_url: "http://169.254.169.254/latest/meta-data",
          chat_api_key: "local-key",
          extraction_model: @model
        })
        |> json_response(422)

      assert body["error"]["code"] == "egress_blocked"
      assert Llm.chat_provider(tenant.id) == :anthropic
    end
  end

  describe "the credential rule (AC-41.3.3, verbatim from US-41.2 AC-41.2.3)" do
    test "a KEYLESS endpoint is configurable and probed with NO authorization header",
         %{conn: conn} do
      # US-41.3 review decision: Ollama / llama.cpp / LM Studio / vLLM commonly serve
      # /chat/completions with no auth at all, so a tenant with no stored key may
      # configure a keyless endpoint rather than inventing a placeholder that would
      # then be shipped as a Bearer token to their host forever.
      {tenant, conn} = user_conn(conn)
      stub_probe_ok()

      body =
        conn
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          chat_provider: "openai_compatible",
          chat_base_url: @base_url,
          extraction_model: @model
        })
        |> json_response(200)

      assert_received {:probe, "/v1/chat/completions", headers, _probe_body}
      refute List.keyfind(headers, "authorization", 0)

      assert body["has_chat_key"] == false
      assert Llm.chat_provider(tenant.id) == :openai_compatible
      assert {:ok, %{api_key: nil}} = Llm.resolve(tenant.id, :extraction)
    end

    test "configuring an endpoint with NO model at all is refused", %{conn: conn} do
      {tenant, conn} = user_conn(conn)

      # No Req.Test stub: the refusal happens BEFORE any request is issued.
      body =
        conn
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          chat_provider: "openai_compatible",
          chat_base_url: @base_url,
          chat_api_key: "local-key"
        })
        |> json_response(422)

      assert body["error"]["code"] == "chat_model_required"
      assert body["error"]["remediation"]["missing"] == ["extraction_model"]
      assert Llm.chat_provider(tenant.id) == :anthropic
    end

    test "CHANGING the endpoint without a matching key needs an explicit acknowledgement",
         %{conn: conn} do
      {tenant, conn} = user_conn(conn)
      stub_probe_ok()

      # First: configure endpoint 1 with its own key.
      conn
      |> patch(~p"/api/v1/tenants/me/llm-config", %{
        chat_provider: "openai_compatible",
        chat_base_url: @base_url,
        chat_api_key: "key-for-host-1",
        extraction_model: @model
      })
      |> json_response(200)

      # Then: move to a DIFFERENT host with no new key and no acknowledgement.
      body =
        build_conn()
        |> auth_conn(user_key(tenant))
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          chat_base_url: "https://other.example.com/v1"
        })
        |> json_response(422)

      assert body["error"]["code"] == "chat_key_acknowledgement_required"
      assert body["error"]["message"] =~ "never ships an existing credential"
      # The stored endpoint is UNCHANGED — the probe never silently shipped the key.
      assert Llm.chat_base_url(tenant.id) == @base_url
    end

    test "the same change SUCCEEDS with acknowledge_key_transmission: true", %{conn: conn} do
      {tenant, conn} = user_conn(conn)
      stub_probe_ok()

      conn
      |> patch(~p"/api/v1/tenants/me/llm-config", %{
        chat_provider: "openai_compatible",
        chat_base_url: @base_url,
        chat_api_key: "key-for-host-1",
        extraction_model: @model
      })
      |> json_response(200)

      build_conn()
      |> auth_conn(user_key(tenant))
      |> patch(~p"/api/v1/tenants/me/llm-config", %{
        chat_base_url: "https://other.example.com/v1",
        acknowledge_key_transmission: true
      })
      |> json_response(200)

      assert Llm.chat_base_url(tenant.id) == "https://other.example.com/v1"

      # The acknowledgement is REQUEST-scoped, never persisted as a field.
      settings = Llm.get_settings(tenant.id)
      refute Map.has_key?(settings, :acknowledge_key_transmission)
    end
  end

  describe "default unchanged (AC-41.3.7)" do
    test "a PATCH that does not touch the chat endpoint probes NOTHING", %{conn: conn} do
      {tenant, conn} = user_conn(conn)

      # No Req.Test stub is installed for the OpenAI plug: any probe would raise.
      body =
        conn
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          api_key: "sk-ant-unchanged-path",
          extraction_model: "claude-opus-4-1"
        })
        |> json_response(200)

      assert body["chat_provider"] == "anthropic"
      assert body["chat_base_url"] == nil
      assert body["has_chat_key"] == false
      assert Llm.chat_provider(tenant.id) == :anthropic
    end

    test "GET returns the chat fields with the unchanged Anthropic defaults", %{conn: conn} do
      {_tenant, conn} = user_conn(conn)

      body = conn |> get(~p"/api/v1/tenants/me/llm-config") |> json_response(200)

      assert body["chat_provider"] == "anthropic"
      assert body["chat_base_url"] == nil
      assert body["has_chat_key"] == false
      assert body["chat_api_key_hint"] == nil
    end
  end

  describe "validation" do
    test "an unknown chat_provider is a 422 changeset error", %{conn: conn} do
      {_tenant, conn} = user_conn(conn)

      conn
      |> patch(~p"/api/v1/tenants/me/llm-config", %{
        chat_provider: "definitely_not_a_provider",
        chat_base_url: @base_url,
        chat_api_key: "k"
      })
      |> json_response(422)
    end

    test "a non-absolute chat_base_url is rejected BEFORE any probe is issued", %{conn: conn} do
      {tenant, conn} = user_conn(conn)

      # No Req.Test stub: the malformed URL must never reach the HTTP client.
      body =
        conn
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          chat_provider: "openai_compatible",
          chat_base_url: "not-a-url",
          chat_api_key: "k"
        })
        |> json_response(422)

      assert body["error"]["code"] == "chat_base_url_invalid"
      assert Llm.chat_provider(tenant.id) == :anthropic
    end

    # US-41.3 review: both validators checked only scheme + non-empty host, so a
    # query string, fragment or userinfo passed. `OpenAiChat.completions_url/1`
    # blindly appends `/chat/completions`, producing e.g.
    # https://host/v1?api-key=SECRET/chat/completions — a request the tenant never
    # intended, surfacing as an opaque transport/4xx instead of a validation message.
    # And unlike `chat_api_key`, `chat_base_url` is NOT encrypted: a key embedded in
    # it is persisted, audited and echoed back in plaintext.
    test "a chat_base_url carrying a query, fragment or userinfo is refused" do
      for url <- [
            "https://host.example.com/v1?api-key=SECRET",
            "https://host.example.com/v1#frag",
            "https://user:pass@host.example.com/v1"
          ] do
        {tenant, tenant_conn} = user_conn(build_conn())

        # No Req.Test stub: the malformed URL must never reach the HTTP client.
        body =
          tenant_conn
          |> patch(~p"/api/v1/tenants/me/llm-config", %{
            chat_provider: "openai_compatible",
            chat_base_url: url,
            chat_api_key: "k",
            extraction_model: @model
          })
          |> json_response(422)

        assert body["error"]["code"] == "chat_base_url_invalid"
        assert body["error"]["message"] =~ "BARE"
        assert Llm.chat_provider(tenant.id) == :anthropic
        assert Llm.chat_base_url(tenant.id) =~ "api.anthropic.com"
      end

      refute_received {:probe, _path, _headers, _body}
    end

    # US-41.3 review: `OpenAiChat.do_post/8` sends `authorization: Bearer <key>` plus
    # the tenant's FULL document text. Plaintext http to an arbitrary PUBLIC host
    # ships both in cleartext across the internet — inside the feature whose stated
    # purpose is that the text never leaves the tenant's chosen boundary. Only a host
    # the ONE egress policy classifies :network_local may use http.
    test "plaintext http to a non-network-local host is refused", %{conn: conn} do
      {tenant, conn} = user_conn(conn)

      body =
        conn
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          chat_provider: "openai_compatible",
          chat_base_url: "http://llm.example.com/v1",
          chat_api_key: "k",
          extraction_model: @model
        })
        |> json_response(422)

      assert body["error"]["code"] == "chat_endpoint_plaintext_refused"
      assert Llm.chat_provider(tenant.id) == :anthropic
      refute_received {:probe, _path, _headers, _body}
    end

    # US-41.3 review: vLLM / TGI / LM Studio / llama.cpp overwhelmingly serve
    # HuggingFace repo ids, and `extraction_model` is sent VERBATIM as the OpenAI
    # `model` field. A model-id class without `/` rejected the epic's headline
    # deployment shape at the changeset.
    test "a HuggingFace-style model id with a slash is accepted", %{conn: conn} do
      {tenant, conn} = user_conn(conn)
      stub_probe_ok()

      body =
        conn
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          chat_provider: "openai_compatible",
          chat_base_url: @base_url,
          chat_api_key: "k",
          extraction_model: "meta-llama/Meta-Llama-3-8B-Instruct"
        })
        |> json_response(200)

      assert body["extraction_model"] == "meta-llama/Meta-Llama-3-8B-Instruct"
      assert_received {:probe, _path, _headers, probe_body}
      assert probe_body["model"] == "meta-llama/Meta-Llama-3-8B-Instruct"

      assert {:ok, %{model: "meta-llama/Meta-Llama-3-8B-Instruct"}} =
               Llm.resolve(tenant.id, :extraction)
    end
  end

  describe "idempotent re-apply of the SAME endpoint (US-41.3 review)" do
    # `host_change?/2` compared the RAW PATCH url against the stored NORMALIZED one
    # (the changeset trims + strips the trailing `/`). Re-sending the identical
    # endpoint with a trailing slash — exactly what an agent replaying set_llm_config
    # does — read as a HOST CHANGE and the credential rule refused the no-op PATCH
    # with 422 chat_key_acknowledgement_required.
    test "re-sending the stored endpoint with a trailing slash is NOT a host change",
         %{conn: conn} do
      {tenant, conn} = user_conn(conn)
      stub_probe_ok()

      conn
      |> patch(~p"/api/v1/tenants/me/llm-config", %{
        chat_provider: "openai_compatible",
        chat_base_url: @base_url,
        chat_api_key: "stored-key",
        extraction_model: @model
      })
      |> json_response(200)

      flush_probes()

      # No chat_api_key, no acknowledgement. Nothing on the chat surface actually
      # changed, so this must be a clean 200 that probes NOTHING — not a 422
      # chat_key_acknowledgement_required.
      body =
        build_conn()
        |> auth_conn(user_key(tenant))
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          chat_provider: "openai_compatible",
          chat_base_url: "  " <> @base_url <> "/  ",
          extraction_model: @model
        })
        |> json_response(200)

      assert body["chat_base_url"] == @base_url
      refute_received {:probe, _path, _headers, _probe_body}
    end

    test "a MODEL change alongside a trailing-slash re-send reuses the stored key",
         %{conn: conn} do
      {tenant, conn} = user_conn(conn)
      stub_probe_ok()

      conn
      |> patch(~p"/api/v1/tenants/me/llm-config", %{
        chat_provider: "openai_compatible",
        chat_base_url: @base_url,
        chat_api_key: "stored-key",
        extraction_model: @model
      })
      |> json_response(200)

      flush_probes()

      # A chat-surface change (the model moved) but NOT a host change — so the
      # credential rule must NOT demand a key or an acknowledgement, and the STORED
      # key is the one probed.
      build_conn()
      |> auth_conn(user_key(tenant))
      |> patch(~p"/api/v1/tenants/me/llm-config", %{
        chat_base_url: @base_url <> "/",
        extraction_model: "Qwen/Qwen2.5-7B-Instruct"
      })
      |> json_response(200)

      assert_received {:probe, _path, headers, probe_body}
      assert {"authorization", "Bearer stored-key"} in headers
      assert probe_body["model"] == "Qwen/Qwen2.5-7B-Instruct"
    end

    # US-41.3 review: `preflight/2` read settings through the node-local ETS cache on
    # a WRITE path, two functions away from `Llm.upsert_settings/2`'s deliberate
    # UNCACHED read. Here the same hazard guards a SECURITY control: with a stale
    # cached `chat_base_url` (a dropped peer invalidation on a multi-node deploy),
    # `host_change?/2` compares the PATCH against the WRONG stored endpoint. This
    # test forces exactly that skew — the DB row moves without a cache invalidation —
    # and asserts the preflight sees the DB, not the cache.
    test "preflight reads the settings row UNCACHED", %{conn: conn} do
      {tenant, conn} = user_conn(conn)
      stub_probe_ok()

      conn
      |> patch(~p"/api/v1/tenants/me/llm-config", %{
        chat_provider: "openai_compatible",
        chat_base_url: @base_url,
        chat_api_key: "stored-key",
        extraction_model: @model
      })
      |> json_response(200)

      # Warm the cache with the CURRENT row, then move the DB row underneath it
      # WITHOUT invalidating — the multi-node dropped-broadcast shape.
      assert %{chat_base_url: @base_url} = Llm.get_settings(tenant.id)
      moved = "https://moved.example.com/v1"

      Loopctl.AdminRepo.get_by!(Loopctl.Llm.TenantLlmSettings, tenant_id: tenant.id)
      |> Ecto.Changeset.change(%{chat_base_url: moved})
      |> Loopctl.AdminRepo.update!()

      assert %{chat_base_url: @base_url} = Llm.get_settings(tenant.id)
      flush_probes()

      # Re-sending the endpoint the DB actually holds is a NO-OP: same host, same
      # models, no key rotation. A CACHED read would see the stale @base_url, call it
      # a host change and refuse with 422 chat_key_acknowledgement_required.
      body =
        build_conn()
        |> auth_conn(user_key(tenant))
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          chat_provider: "openai_compatible",
          chat_base_url: moved,
          extraction_model: @model
        })
        |> json_response(200)

      assert body["chat_base_url"] == moved
      refute_received {:probe, _path, _headers, _body}
    end
  end

  describe "tenant isolation" do
    test "tenant A's chat config is invisible to tenant B", %{conn: conn} do
      {a, a_conn} = user_conn(conn)
      stub_probe_ok()

      a_conn
      |> patch(~p"/api/v1/tenants/me/llm-config", %{
        chat_provider: "openai_compatible",
        chat_base_url: @base_url,
        chat_api_key: "a-only-key",
        extraction_model: @model
      })
      |> json_response(200)

      {b, b_conn} = user_conn(build_conn())
      body = b_conn |> get(~p"/api/v1/tenants/me/llm-config") |> json_response(200)

      assert body["chat_provider"] == "anthropic"
      assert body["chat_base_url"] == nil
      assert body["has_chat_key"] == false

      assert Llm.chat_provider(a.id) == :openai_compatible
      assert Llm.chat_provider(b.id) == :anthropic
      assert {:error, :no_api_key} = Llm.resolve(b.id, :extraction)
    end
  end

  # Every model the probe actually exercised, drained from the mailbox.
  defp probed_models, do: Enum.map(drain_probes(), & &1["model"])

  defp flush_probes, do: drain_probes()

  defp drain_probes do
    receive do
      {:probe, _path, _headers, body} -> [body | drain_probes()]
    after
      0 -> []
    end
  end

  defp user_key(tenant) do
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
    raw_key
  end
end
