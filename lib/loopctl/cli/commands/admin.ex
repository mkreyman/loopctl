defmodule Loopctl.CLI.Commands.Admin do
  @moduledoc """
  CLI commands for superadmin operations.

  Commands:
  - `loopctl admin tenants` -- list all tenants
  - `loopctl admin tenant <id>` -- tenant detail
  - `loopctl admin suspend <tenant_id>` -- suspend tenant
  - `loopctl admin activate <tenant_id>` -- activate tenant
  - `loopctl admin stats` -- system-wide stats
  """

  alias Loopctl.CLI.Client
  alias Loopctl.CLI.Output

  @doc """
  Dispatches admin subcommands.
  """
  @spec run(String.t(), [String.t()], keyword()) :: :ok
  def run("admin", args, opts) do
    case args do
      ["tenants"] -> list_tenants(opts)
      ["tenant", id] -> show_tenant(id, opts)
      ["suspend", id] -> suspend_tenant(id, opts)
      ["activate", id] -> activate_tenant(id, opts)
      ["stats"] -> stats(opts)
      _ -> Output.error("Usage: loopctl admin tenants|tenant|suspend|activate|stats")
    end
  end

  def run(_command, _args, _opts) do
    Output.error("Usage: loopctl admin tenants|tenant|suspend|activate|stats")
  end

  defp list_tenants(opts) do
    case Client.get("/api/v1/admin/tenants") do
      {:ok, result} ->
        Output.render(result,
          format: Keyword.get(opts, :format),
          headers: ["id", "name", "slug", "status"]
        )

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp show_tenant(id, opts) do
    case Client.get("/api/v1/admin/tenants/#{id}") do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  defp suspend_tenant(id, opts) do
    case Client.post("/api/v1/admin/tenants/#{id}/suspend", %{}) do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  defp activate_tenant(id, opts) do
    case Client.post("/api/v1/admin/tenants/#{id}/activate", %{}) do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  defp stats(opts) do
    case Client.get("/api/v1/admin/stats") do
      {:ok, result} -> Output.render(result, format: Keyword.get(opts, :format))
      {:error, reason} -> handle_error(reason)
    end
  end

  defp handle_error(:no_server_configured) do
    Output.error("No server configured. Run: loopctl auth login --server <url> --key <key>")
  end

  defp handle_error({status, body}) do
    Output.error("Server returned #{status}: #{inspect(body)}")
  end
end
