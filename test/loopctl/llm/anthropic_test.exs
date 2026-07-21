defmodule Loopctl.Llm.AnthropicTest do
  @moduledoc """
  The tenant's API key is a secret — it must NEVER appear in any log line, across
  ALL response branches of the client (review #16).

  ## Why `async: false` (deliberate, not an oversight)

  Most tests here attach a GLOBAL `:telemetry` handler on the VM-global event
  `[:loopctl, :llm, :provider_error]` and assert on what lands in the test
  process mailbox (`assert_received` / `refute_received`). The emitter in
  `Loopctl.LLM.record_provider_error/2` DELIBERATELY puts NO `tenant_id` (nor any
  high-cardinality id) in the event metadata — see the "NEVER `tenant_id`" note
  in `lib/loopctl/llm.ex`. Because the metadata carries no tenant, the handlers
  CANNOT be tenant-scoped: the best they can do is filter on `provider:
  "anthropic"` (which they do). Under `async: true` that filter is not enough —
  ANY concurrently-running test whose Anthropic path emits a `provider_error`
  with `provider: "anthropic"` (content extraction/classification/merge/
  memory-promotion all funnel through this shared client) would leak a
  `{:provider_error_emitted, ...}` / `:unexpected_provider_error` message into a
  listener's mailbox and trip the `refute_received` / metadata assertions
  non-deterministically. The admission-gate listener does not even filter by
  provider, so an embedding-path emission would leak into it too. This file is
  ALSO an emitter: its 401/429/500/transport capture_log tests each record a
  `provider_error`, so under async it would leak INTO other files' listeners.
  A non-async module never runs concurrently with any other module
  (`ExUnit.Case` `:async` docs), so no cross-file emitter is running while these
  listeners are attached and no other file's listener is attached while these
  emitters run. This mirrors `test/loopctl/knowledge_semantic_search_provider_error_test.exs`,
  which documents `async: false` for exactly this VM-global-telemetry reason.
  """
  use Loopctl.DataCase, async: false

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
        fn
          # Forward ONLY this provider's events. `[:loopctl, :llm, :provider_error]`
          # is a VM-GLOBAL telemetry event: a concurrent embedding-path test
          # (Knowledge.generate_embedding / the US-37.1 embedding worker tests)
          # emitting it with provider="embedding" must NOT be mistaken for this
          # test's Anthropic call. Filtering at the handler keeps the
          # `assert_received {:provider_error_emitted, ...}` assertion targeting
          # only anthropic events. (This module is `async: false` — so no
          # cross-file emitter runs concurrently at all — for exactly this
          # VM-global-telemetry reason; see @moduledoc.)
          _event, measurements, %{provider: "anthropic"} = metadata, _config ->
            send(test_pid, {:provider_error_emitted, measurements, metadata})

          _event, _measurements, _metadata, _config ->
            :ok
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
        fn
          # Filter to this provider — the event is VM-global, so an unrelated
          # embedding-path emission must NOT be mistaken for this test's call
          # emitting a provider_error on a successful 200. (Module is
          # `async: false` so no concurrent emitter runs; see @moduledoc.)
          _event, _measurements, %{provider: "anthropic"}, _config ->
            send(test_pid, :unexpected_provider_error)

          _event, _measurements, _metadata, _config ->
            :ok
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

  describe "provider guard (US-41.3 review, AC-41.3.3)" do
    # `Llm.resolve/2` returns the tenant's LOCAL `chat_api_key` for an
    # `openai_compatible` tenant. A provider-BLIND match would POST it to the
    # hardcoded https://api.anthropic.com/v1 as `x-api-key` — a cross-provider
    # credential leak the egress guard cannot catch, because the vendor host is the
    # DEFAULT. The mirror direction (`OpenAiChat.resolve_target/2`) was already
    # guarded; the defence must be symmetric.
    test "refuses :provider_mismatch for an openai_compatible tenant and sends NOTHING" do
      tenant = fixture(:tenant)
      test_pid = self()

      {:ok, _} =
        Llm.upsert_settings(tenant.id, %{
          "chat_provider" => "openai_compatible",
          "chat_base_url" => "https://llm.example.com/v1",
          "extraction_model" => "Qwen/Qwen2.5-7B-Instruct",
          "chat_api_key" => "tenant-local-chat-key"
        })

      Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
        send(test_pid, {:leaked, conn.req_headers})
        Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "ok"}]})
      end)

      assert {:error, :provider_mismatch} = run(tenant)
      refute_received {:leaked, _headers}
    end

    # A KEYLESS local endpoint resolves `api_key: nil`; the old provider-blind clause
    # matched it too and threaded a nil key into the Anthropic request.
    test "refuses a KEYLESS openai_compatible tenant rather than sending a nil key" do
      tenant = fixture(:tenant)
      test_pid = self()

      {:ok, _} =
        Llm.upsert_settings(tenant.id, %{
          "chat_provider" => "openai_compatible",
          "chat_base_url" => "https://llm.example.com/v1",
          "extraction_model" => "Qwen/Qwen2.5-7B-Instruct"
        })

      Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
        send(test_pid, :unexpected_http_call)
        Req.Test.json(conn, %{"content" => [%{"type" => "text", "text" => "ok"}]})
      end)

      assert {:error, :provider_mismatch} = run(tenant)
      refute_received :unexpected_http_call
    end
  end
end
