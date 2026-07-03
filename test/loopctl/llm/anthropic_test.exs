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
  @secret "sk-ant-DISTINCTIVE-NEVER-LOG-#{System.unique_integer([:positive])}"

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

  test "never logs the api_key on the 200-unexpected-shape branch" do
    tenant = tenant_with_key()

    Req.Test.stub(Loopctl.Llm.Anthropic, fn conn ->
      Req.Test.json(conn, %{"unexpected" => true})
    end)

    log = capture_log(fn -> assert {:error, {:api_error, 200, _}} = run(tenant) end)
    refute log =~ @secret
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
end
