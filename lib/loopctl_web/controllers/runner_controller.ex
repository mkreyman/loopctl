defmodule LoopctlWeb.RunnerController do
  @moduledoc """
  Enroll, list and revoke the runners of the agent delivery loop (issue #801), and read
  the tenant's connected pool (issue #809).

  All actions require `user` role, and the writes require a human-anchored tenant
  (`RequireHumanAnchor`, surface `:runner_pool`): a runner executes dispatched sessions
  as its machine's user, so an agent-rooted tenant may not admit one for itself.

  Enrollment MINTS a credential — a plain API key that
  belongs to no dispatch lineage — so it carries the same lineage ceiling as
  `POST /api/v1/api_keys`: a caller whose own key a dispatch minted is refused with
  `403 api_key_mint_forbidden` (`LoopctlWeb.Plugs.RequireUnlineagedCaller`).

  A runner's credential counts toward the tenant's `max_api_keys` limit, because it is
  one.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Auth
  alias Loopctl.Dispatches
  alias Loopctl.Runners
  alias Loopctl.Runners.Runner
  alias Loopctl.Tenants
  alias OpenApiSpex.Schema

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :user
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:create, :delete]
  plug LoopctlWeb.Plugs.RequireUnlineagedCaller when action in [:create]

  tags(["Runners"])

  @runner_schema %Schema{
    type: :object,
    required: [:id, :name, :max_sessions, :in_flight, :revoked_at, :inserted_at],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      name: %Schema{type: :string, pattern: Runner.name_format().source},
      max_sessions: %Schema{
        type: :integer,
        minimum: Runner.max_sessions_range().first,
        maximum: Runner.max_sessions_range().last,
        description: "The most capacity slots loopctl reserves on this machine at once."
      },
      in_flight: %Schema{
        type: :integer,
        minimum: 0,
        description: "Slots reserved on this machine now (authoritative; Postgres)."
      },
      revoked_at: %Schema{type: :string, format: :"date-time", nullable: true},
      inserted_at: %Schema{type: :string, format: :"date-time"},
      updated_at: %Schema{type: :string, format: :"date-time"}
    }
  }

  operation(:create,
    summary: "Enroll a runner",
    description:
      "Enrolls a dev machine as a runner and returns its credential ONCE, as `token`. The " <>
        "runner presents it in the `x-loopctl-runner-token` header when it connects to " <>
        "`/runner/socket/websocket`, and joins the topic `runner:<runner.id>` declaring " <>
        "exactly this `name`. The wire contract is `priv/runner_contract/v1.json`. " <>
        "`max_sessions` (default #{Runner.default_max_sessions()}) is how many dispatches " <>
        "loopctl will have in flight on this machine at once. Requires user role; " <>
        "a caller whose key was minted by a dispatch is refused with 403 " <>
        "`api_key_mint_forbidden`. 422 when the name is malformed, already used by an " <>
        "active runner, `max_sessions` is out of range, or the tenant is at its API key limit.",
    request_body:
      {"Runner", "application/json",
       %Schema{
         type: :object,
         required: [:name],
         properties: %{
           name: %Schema{
             type: :string,
             pattern: Runner.name_format().source,
             description: "The machine name, e.g. `minis`."
           },
           max_sessions: %Schema{
             type: :integer,
             minimum: Runner.max_sessions_range().first,
             maximum: Runner.max_sessions_range().last,
             default: Runner.default_max_sessions(),
             description:
               "The most dispatches loopctl keeps in flight on this machine at once. The " <>
                 "tenant's total is capped separately (RUNNER_MAX_IN_FLIGHT_SESSIONS)."
           }
         }
       }},
    responses: %{
      201 =>
        {"Runner enrolled", "application/json",
         %Schema{
           type: :object,
           required: [:runner, :token],
           properties: %{
             runner: @runner_schema,
             token: %Schema{type: :string, description: "The raw credential. Shown once."}
           }
         }},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:index,
    summary: "List runners",
    description:
      "Lists the tenant's enrolled runners. Enrollment only: whether a runner is CONNECTED " <>
        "is Presence, not a row. Pass `include_revoked=true` for revoked ones too.",
    parameters: [
      include_revoked: [in: :query, type: :boolean, description: "Include revoked runners"]
    ],
    responses: %{
      200 =>
        {"Runners", "application/json",
         %Schema{
           type: :object,
           properties: %{runners: %Schema{type: :array, items: @runner_schema}}
         }},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:delete,
    summary: "Revoke a runner",
    description:
      "Revokes the runner and its credential in one transaction and disconnects its live " <>
        "socket, which removes it from the pool. Idempotent. Requires user role.",
    parameters: [id: [in: :path, type: :string, description: "Runner UUID"]],
    responses: %{
      200 =>
        {"Runner revoked", "application/json",
         %Schema{type: :object, properties: %{runner: @runner_schema}}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:pool,
    summary: "The tenant's runner pool",
    description:
      "The runners of the caller's tenant that are CONNECTED right now, read from Presence " <>
        "(`Loopctl.Runners.pool/1`), sorted by machine name. Each entry is the most recently " <>
        "joined socket tracked under that machine name; `live_sockets` counts every socket " <>
        "tracked under it, so a value above 1 means more than one process is holding the " <>
        "runner's credential. `sample` is the latest health sample that socket reported, or " <>
        "null before its first status update. `in_flight` and `max_sessions` are the " <>
        "capacity Postgres holds for the runner — the values dispatch reserves against — and " <>
        "are null only for a runner revoked while its socket is still draining; " <>
        "`reported_in_flight` and `reported_max_sessions` are what the runner itself last " <>
        "reported, a hint. Requires user role. Presence is a liveness " <>
        "hint, not a scheduler, and it converges only within a CLUSTER: on a deployment with " <>
        "more than one unclustered node, a runner connected to another node is absent here.",
    responses: %{
      200 =>
        {"Runner pool", "application/json",
         %Schema{
           type: :object,
           required: [:runners],
           properties: %{
             runners: %Schema{
               type: :array,
               items: %Schema{
                 type: :object,
                 required: [
                   :machine,
                   :runner_id,
                   :joined_at,
                   :in_flight,
                   :draining,
                   :max_sessions,
                   :reported_in_flight,
                   :reported_max_sessions,
                   :sample,
                   :live_sockets,
                   :node,
                   :machine_id
                 ],
                 properties: %{
                   machine: %Schema{type: :string, description: "The enrolled machine name."},
                   runner_id: %Schema{type: :string, format: :uuid},
                   joined_at: %Schema{type: :string, format: :"date-time"},
                   in_flight: %Schema{
                     type: :integer,
                     minimum: 0,
                     nullable: true,
                     description: "Capacity slots reserved on this runner (Postgres)."
                   },
                   draining: %Schema{type: :boolean, nullable: true},
                   max_sessions: %Schema{
                     type: :integer,
                     minimum: 1,
                     nullable: true,
                     description: "The runner's enrolled slot limit (Postgres)."
                   },
                   reported_in_flight: %Schema{
                     type: :integer,
                     minimum: 0,
                     nullable: true,
                     description: "Sessions the runner last reported running. A hint."
                   },
                   reported_max_sessions: %Schema{
                     type: :integer,
                     minimum: 0,
                     nullable: true,
                     description: "The session limit the runner declared on join. A hint."
                   },
                   sample: %Schema{
                     type: :object,
                     nullable: true,
                     description: "The latest self-measured health sample (runner contract)."
                   },
                   live_sockets: %Schema{
                     type: :integer,
                     minimum: 1,
                     description: "Live sockets tracked under this machine name."
                   },
                   node: %Schema{
                     type: :string,
                     nullable: true,
                     description:
                       "The Erlang node holding this socket. Two nodes can share a name, so " <>
                         "`machine_id` is what tells them apart."
                   },
                   machine_id: %Schema{
                     type: :string,
                     nullable: true,
                     description:
                       "The Fly Machine (`FLY_MACHINE_ID`) holding this socket, or null off Fly."
                   }
                 }
               }
             }
           }
         }},
      403 => {"Forbidden", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "POST /api/v1/runners"
  def create(conn, params) do
    tenant = conn.assigns.current_tenant

    with :ok <- validate_key_limit(tenant),
         {:ok, %{runner: runner, raw_key: raw_key}} <-
           Runners.enroll_runner(
             tenant.id,
             %{name: params["name"], max_sessions: params["max_sessions"]},
             actor_lineage: actor_lineage(conn)
           ) do
      conn
      |> put_status(:created)
      |> json(%{runner: runner, token: raw_key})
    end
  end

  @doc "GET /api/v1/runners"
  def index(conn, params) do
    tenant = conn.assigns.current_tenant
    include_revoked = params["include_revoked"] == "true"

    json(conn, %{runners: Runners.list_runners(tenant.id, include_revoked: include_revoked)})
  end

  @doc "DELETE /api/v1/runners/:id"
  def delete(conn, %{"id" => runner_id}) do
    tenant = conn.assigns.current_tenant

    with {:ok, runner} <-
           Runners.revoke_runner(tenant.id, runner_id, actor_lineage: actor_lineage(conn)) do
      json(conn, %{runner: runner})
    end
  end

  @doc "GET /api/v1/runners/pool"
  def pool(conn, _params) do
    tenant = conn.assigns.current_tenant

    # Presence says who is connected; Postgres says what they carry.
    capacity = Runners.capacity(tenant.id)

    runners =
      tenant.id
      |> Runners.pool()
      |> Enum.map(&pool_entry(&1, capacity))
      |> Enum.sort_by(& &1.machine)

    json(conn, %{runners: runners})
  end

  defp pool_entry({machine, %{metas: metas}}, capacity) do
    meta = Enum.max_by(metas, &Map.get(&1, :joined_at), &joined_no_later?/2)
    held = Map.get(capacity, Map.get(meta, :runner_id), %{})

    %{
      machine: machine,
      runner_id: Map.get(meta, :runner_id),
      joined_at: Map.get(meta, :joined_at),
      in_flight: Map.get(held, :in_flight),
      draining: Map.get(meta, :draining),
      max_sessions: Map.get(held, :max_sessions),
      reported_in_flight: Map.get(meta, :in_flight),
      reported_max_sessions: Map.get(meta, :max_sessions),
      sample: Map.get(meta, :sample),
      live_sockets: length(metas),
      node: Map.get(meta, :node),
      machine_id: Map.get(meta, :machine_id)
    }
  end

  defp joined_no_later?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) != :lt
  defp joined_no_later?(_a, nil), do: true
  defp joined_no_later?(nil, _b), do: false

  defp validate_key_limit(tenant) do
    max_keys = Tenants.get_tenant_settings(tenant, "max_api_keys", 100)

    if Auth.count_api_keys(tenant.id) >= max_keys do
      {:error, :unprocessable_entity, "API key limit reached (max: #{max_keys})"}
    else
      :ok
    end
  end

  defp actor_lineage(conn) do
    api_key = conn.assigns.current_api_key
    Dispatches.lineage_for_api_key(api_key.tenant_id, api_key.id)
  end
end
