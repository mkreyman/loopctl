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
        chat_api_key: "local-key"
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
          chat_api_key: "local-key"
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
          chat_api_key: "local-key"
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
          chat_api_key: "local-key"
        })
        |> json_response(422)

      assert body["error"]["code"] == "chat_endpoint_not_openai_compatible"
    end
  end

  describe "the credential rule (AC-41.3.3, verbatim from US-41.2 AC-41.2.3)" do
    test "configuring an endpoint with NO key at all is refused", %{conn: conn} do
      {tenant, conn} = user_conn(conn)

      body =
        conn
        |> patch(~p"/api/v1/tenants/me/llm-config", %{
          chat_provider: "openai_compatible",
          chat_base_url: @base_url
        })
        |> json_response(422)

      assert body["error"]["code"] == "chat_key_required"
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
        chat_api_key: "key-for-host-1"
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
        chat_api_key: "key-for-host-1"
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
  end

  describe "tenant isolation" do
    test "tenant A's chat config is invisible to tenant B", %{conn: conn} do
      {a, a_conn} = user_conn(conn)
      stub_probe_ok()

      a_conn
      |> patch(~p"/api/v1/tenants/me/llm-config", %{
        chat_provider: "openai_compatible",
        chat_base_url: @base_url,
        chat_api_key: "a-only-key"
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

  defp user_key(tenant) do
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
    raw_key
  end
end
