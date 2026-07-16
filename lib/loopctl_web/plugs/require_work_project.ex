defmodule LoopctlWeb.Plugs.RequireWorkProject do
  @moduledoc """
  Rejects attaching work-breakdown entities (epics, stories, ui-tests, imported work
  breakdowns) to a knowledge-only (`kind: :kb`) project.

  A `:kb` scope exists ONLY to partition knowledge articles by repo; it is structurally
  barred from the chain-of-custody surface. This plug makes that a POSITIVE invariant at
  the web boundary, independent of `RequireHumanAnchor`: a KB project can never host work
  even if a nested `/projects/:id/*` route forgets its own tier gate. That closes the trap
  where "a project exists" was previously equated with "custody is unlocked" (the
  default-deny test's old unreachability premise).

  Reads the project id from a path param — default `"project_id"`; pass `param: "id"` for
  routes that use `:id` (e.g. import). A missing or not-found project is left untouched so
  the controller can 404 as usual; a `:work` project passes through; a `:kb` project halts
  with `422 kb_project_no_work`. Order it AFTER `RequireHumanAnchor` so agent-rooted callers
  still hit the tier gate first.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: Keyword.get(opts, :param, "project_id")

  @impl true
  def call(conn, param) do
    with %{tenant_id: tenant_id} <- conn.assigns[:current_api_key],
         project_id when is_binary(project_id) <- conn.params[param],
         {:ok, %{kind: :kb}} <- Loopctl.Projects.get_project(tenant_id, project_id) do
      conn
      |> put_status(:unprocessable_entity)
      |> Phoenix.Controller.json(%{
        error: %{
          status: 422,
          code: "kb_project_no_work",
          message:
            "This is a knowledge-only project scope (kind: kb) and cannot host " <>
              "work-breakdown items (epics, stories, dispatch, ui-tests, imports). " <>
              "Use a work project (kind: work) for chain-of-custody work."
        }
      })
      |> halt()
    else
      _ -> conn
    end
  end
end
