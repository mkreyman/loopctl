defmodule Loopctl.Llm.AnthropicTest do
  @moduledoc """
  The tenant's API key is a secret — it must NEVER appear in any log line, across
  ALL response branches of the client (review #16).
  """
  use Loopctl.DataCase, async: true

  import ExUnit.CaptureLog

  alias Loopctl.Llm
  alias Loopctl.Llm.Anthropic

  # A distinctive, per-test key so a hit in captured output is unambiguous and can
  # never be another test's key (avoids cross-test capture_log leakage concerns).
  @secret "test-anthropic-DISTINCTIVE-NEVER-LOG-#{System.unique_integer([:positive])}"

  defp tenant_with_key do
    tenant = fixture(:tenant)
    {:ok, _} = Llm.upsert_settings(tenant.id, %{"api_key" => @secret})
    tenant
  end

  defp body_fun, do: fn _model -> %{max_tokens: 10, system: "s", messages: []} end

  defp run(tenant), do: Anthropic.message(tenant.id, :extraction, body_fun())

  test "never logs the api_key on the 200-success branch" do
    tenant = tenant_with_key()

    Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => "ok"}],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      })
    end)

    log = capture_log(fn -> assert {:ok, "ok"} = run(tenant) end)
    refute log =~ @secret
  end

  test "sanitizes the 200-unexpected-shape body (never leaks a key fragment) (review CRIT #1)" do
    tenant = tenant_with_key()

    # A misconfigured/compromised endpoint can return HTTP 200 with an error-shaped
    # body echoing a masked key fragment. The 200-shape branch must sanitize it just
    # like a non-200 — the returned term is value-free and the fragment never leaks
    # (into the error term that becomes an Oban reason, nor the log).
    masked = "sk-ant-...LEAK200"

    Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
      Req.Test.json(conn, %{"error" => %{"message" => "Invalid x-api-key header: #{masked}"}})
    end)

    log =
      capture_log(fn ->
        assert {:error, {:api_error, 200, :provider_error}} = run(tenant)
      end)

    refute log =~ @secret
    refute log =~ masked
  end

  test "sanitizes the non-200 body to the exact value-free term (review #11)" do
    tenant = tenant_with_key()
    masked = "sk-ant-...LEAK401"

    Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => %{"message" => "Invalid x-api-key header: #{masked}"}})
    end)

    log =
      capture_log(fn ->
        assert {:error, {:api_error, 401, :provider_error}} = run(tenant)
      end)

    refute log =~ @secret
    refute log =~ masked
  end

  test "never logs the api_key on the non-200 branch" do
    tenant = tenant_with_key()

    Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
    end)

    log = capture_log(fn -> assert {:error, {:api_error, 500, _}} = run(tenant) end)
    refute log =~ @secret
  end

  test "never logs the api_key on the transport-error branch" do
    tenant = tenant_with_key()

    Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    log = capture_log(fn -> assert {:error, {:request_failed, _}} = run(tenant) end)
    refute log =~ @secret
  end

  describe "US-34.3 review fix (AC-34.3.3): wires [:loopctl, :llm, :provider_error]" do
    # Prior to this fix, a real 429/5xx/transport storm on the primary Anthropic
    # surface (content extraction/classification/merge/memory-promotion — every one
    # funnels through this shared client) was invisible to the provider-error-rate
    # ScaleAlerts signal: only the embedding worker path recorded it. Attaching a
    # listener here proves the client itself is now the single choke point for
    # every Anthropic call site.
    defp attach_provider_error_listener(test_pid) do
      handler_id = {:anthropic_provider_error_test, System.unique_integer([:positive])}

      :telemetry.attach(
        handler_id,
        [:loopctl, :llm, :provider_error],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:provider_error_emitted, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "a permanent 4xx API error (e.g. revoked key) is recorded provider=anthropic class=:permanent" do
      tenant = tenant_with_key()
      attach_provider_error_listener(self())

      Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "bad key"})
      end)

      assert {:error, {:api_error, 401, :provider_error}} = run(tenant)

      assert_received {:provider_error_emitted, %{count: 1}, metadata}
      assert metadata == %{provider: "anthropic", class: :permanent}
    end

    test "a 5xx API error is recorded provider=anthropic class=:transient" do
      tenant = tenant_with_key()
      attach_provider_error_listener(self())

      Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      assert {:error, {:api_error, 500, :provider_error}} = run(tenant)

      assert_received {:provider_error_emitted, %{count: 1}, metadata}
      assert metadata == %{provider: "anthropic", class: :transient}
    end

    test "a 429 rate-limit is classified :transient (not permanent — it can succeed on retry)" do
      tenant = tenant_with_key()
      attach_provider_error_listener(self())

      Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
        conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "rate limited"})
      end)

      assert {:error, {:api_error, 429, :provider_error}} = run(tenant)

      assert_received {:provider_error_emitted, %{count: 1}, metadata}
      assert metadata == %{provider: "anthropic", class: :transient}
    end

    test "a transport error is recorded provider=anthropic class=:transient" do
      tenant = tenant_with_key()
      attach_provider_error_listener(self())

      Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:request_failed, _}} = run(tenant)

      assert_received {:provider_error_emitted, %{count: 1}, metadata}
      assert metadata == %{provider: "anthropic", class: :transient}
    end

    test "a 200-with-unexpected-shape response is NEVER recorded (review fix LOW: a 200 is a provider SUCCESS, not an outage)" do
      tenant = tenant_with_key()
      attach_provider_error_listener(self())

      Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
        Req.Test.json(conn, %{"error" => %{"message" => "unexpected"}})
      end)

      assert {:error, {:api_error, 200, :provider_error}} = run(tenant)

      refute_received {:provider_error_emitted, _measurements, _metadata}
    end

    test "a successful 200 call never emits provider_error" do
      tenant = tenant_with_key()
      test_pid = self()
      handler_id = {:anthropic_provider_error_success_test, System.unique_integer([:positive])}

      :telemetry.attach(
        handler_id,
        [:loopctl, :llm, :provider_error],
        fn _event, _measurements, _metadata, _config ->
          send(test_pid, :unexpected_provider_error)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        })
      end)

      assert {:ok, "ok"} = run(tenant)
      refute_received :unexpected_provider_error
    end
  end

  describe "US-37.1: per-(tenant, provider) admission gate (#352)" do
    test "empty bucket → {:error, :rate_limited_local}, NO provider call, NO record_provider_error" do
      tenant = tenant_with_key()
      test_pid = self()

      # Empty node-local bucket for the anthropic provider.
      stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit -> {:deny, 0} end)

      # A provider_error emission or an HTTP call would signal the short-circuit ran
      # too late (after building/sending the request or after the error branches).
      handler_id = {:anthropic_admission_test, System.unique_integer([:positive])}

      :telemetry.attach(
        handler_id,
        [:loopctl, :llm, :provider_error],
        fn _event, _measurements, _metadata, _config ->
          send(test_pid, :unexpected_provider_error)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
        send(test_pid, :unexpected_http_call)
        Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "ok"}]})
      end)

      assert {:error, :rate_limited_local} = run(tenant)
      refute_received :unexpected_http_call
      refute_received :unexpected_provider_error
    end

    test "token available → the request is issued and the success path is unchanged" do
      tenant = tenant_with_key()

      # Default permissive stub already allows, but assert explicitly for clarity.
      stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit -> {:allow, 1} end)

      Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        })
      end)

      assert {:ok, "ok"} = run(tenant)
    end
  end
end
