defmodule LoopctlWeb.Plugs.ResolveProjectRef do
  @moduledoc """
  Resolves a `project_id` param that carries a project REFERENCE — a slug, or the repo
  directory name an agent actually types — into that project's UUID, scoped to the
  caller's tenant (#652).

  ## Why this exists

  Mining ~2,100 real agent searches off two machines turned up 27 failures with an
  unambiguous shape: where a UUID is demanded, agents pass the repo's DIRECTORY name
  exactly as the checkout spells it — `home_care_billing` (x24), `loopctl` (x3). Never a
  name, never a path, never a malformed UUID.

  Note that `home_care_billing` is NOT that tenant's slug (`home-care-billing` is) and is
  not a resolvable `repo_url` either, so the pre-existing `resolve_project/2` would have
  answered only one of the two observed spellings. `Projects.resolve_project_ref/2` is
  the resolver that covers what agents actually type; see its docs for the three passes.

  The recovery behaviour is what makes this worth fixing at the boundary rather than in
  an error message. 26 of the 27 recovered by DROPPING `project_id` and retrying
  unscoped. Nobody ever fixed the value. The search then succeeds and the scope intent is
  silently abandoned — a confidently wrong answer, which is strictly worse than the 422
  that preceded it. A better error message would at best teach agents to do faster what
  they already do.

  ## Contract

  Runs in the `:authenticated` pipeline, so it only ever touches an authenticated
  request. It rewrites `conn.params["project_id"]` (and `conn.path_params`, so a
  `/projects/:project_id/...` route resolves too) IN PLACE when ALL of:

    * the value is a non-empty binary that is not already a canonical 36-char UUID,
    * the key's tenant is known (superadmin keys, `tenant_id: nil`, are skipped), and
    * `Projects.resolve_project_ref/2` finds exactly one project in THAT tenant.

  Anything else — including an AMBIGUOUS reference — is left untouched, so
  `LoopctlWeb.Helpers.ProjectId.validate/1` still returns its 422 for a genuinely
  unresolvable value. Resolution is tenant-scoped by an explicit predicate on every
  pass, so a reference belonging to another tenant does not resolve and cannot be used
  as a cross-tenant existence oracle: it produces the same 422 as a typo.

  Deliberately narrow: only the `project_id` key. `id` is the resource key on every
  route and rewriting it would silently change the meaning of unrelated requests.
  """

  @behaviour Plug

  require Logger

  alias Loopctl.Projects
  alias Loopctl.TelemetryEvents

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{params: %{"project_id" => value}} = conn, _opts) when is_binary(value) do
    with {:ok, tenant_id} <- tenant_id(conn),
         :ref <- classify(value),
         {:ok, project, matched_by} <- lookup(tenant_id, value) do
      emit_resolved(conn, value, project, matched_by)

      conn
      |> put_param("project_id", project.id)
      |> put_path_param("project_id", value, project.id)
    else
      _ -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp tenant_id(conn) do
    case conn.assigns[:current_api_key] do
      %{tenant_id: tenant_id} when is_binary(tenant_id) -> {:ok, tenant_id}
      _ -> :error
    end
  end

  # A canonical 36-char UUID is already the thing the query wants — never touch it.
  # An empty value means "no filter" and is handled downstream.
  defp classify(""), do: :skip

  defp classify(value) when byte_size(value) == 36 do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :skip
      :error -> :ref
    end
  end

  defp classify(_value), do: :ref

  defp lookup(tenant_id, ref) do
    Projects.resolve_project_ref(tenant_id, ref)
  rescue
    # A reference lookup must never be able to fail a request that would otherwise have
    # produced a clean 422.
    _ -> :error
  end

  defp put_param(conn, key, value), do: %{conn | params: Map.put(conn.params, key, value)}

  # Only rewrite the path param when the SAME slug is what the router matched. A route
  # can carry `project_id` in the query string while `path_params` holds something else.
  defp put_path_param(%Plug.Conn{path_params: %{"project_id" => raw}} = conn, key, raw, value),
    do: %{conn | path_params: Map.put(conn.path_params, key, value)}

  defp put_path_param(conn, _key, _raw, _value), do: conn

  defp emit_resolved(conn, ref, project, matched_by) do
    :telemetry.execute(
      TelemetryEvents.project_ref_resolved(),
      %{count: 1},
      %{
        tenant_id: project.tenant_id,
        project_id: project.id,
        ref: ref,
        matched_by: matched_by,
        path: conn.request_path
      }
    )

    # Values are inlined in the message rather than passed as Logger metadata: these
    # keys are not in the prod metadata allowlist (config/config.exs), so as metadata
    # they would be silently dropped exactly where this line is meant to be read.
    Logger.info(
      "project_id reference resolved: #{inspect(ref)} -> #{project.id} " <>
        "(matched_by=#{matched_by}, path=#{conn.request_path})"
    )
  end
end
