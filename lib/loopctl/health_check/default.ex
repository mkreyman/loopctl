defmodule Loopctl.HealthCheck.Default do
  @moduledoc """
  Default health check implementation.

  Checks database connectivity (SELECT 1) and Oban process status.
  Returns the application version from the mix project config.
  """

  @behaviour Loopctl.HealthCheck.Behaviour

  alias Ecto.Adapters.SQL

  @impl true
  def check do
    db_check = check_database()
    oban_check = check_oban()
    version = app_version()

    checks = %{
      database: elem(db_check, 0),
      oban: elem(oban_check, 0)
    }

    status =
      if Enum.all?(Map.values(checks), &(&1 == "ok")),
        do: "ok",
        else: "degraded"

    {:ok, %{status: status, version: version, checks: checks}}
  end

  defp check_database do
    case SQL.query(Loopctl.Repo, "SELECT 1", [], timeout: 5_000) do
      {:ok, _} -> {"ok"}
      {:error, _} -> {"error"}
    end
  rescue
    _ -> {"error"}
  end

  defp check_oban do
    case Process.whereis(Oban) do
      pid when is_pid(pid) -> {"ok"}
      nil -> {"error"}
    end
  end

  defp app_version do
    Application.spec(:loopctl, :vsn) |> to_string()
  end
end
