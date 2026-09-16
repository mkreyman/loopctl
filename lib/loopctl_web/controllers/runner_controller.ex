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
    required: [
      :id,
      :name,
      :max_sessions,
      :enrolled_max_sessions,
      :in_flight,
      :revoked_at,
      :inserted_at
    ],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      name: %Schema{type: :string, pattern: Runner.name_format().source},
      max_sessions: %Schema{
        type: :integer,
        minimum: Runner.max_sessions_range().first,
        maximum: Runner.max_sessions_range().last,
        description:
          "The most capacity slots loopctl reserves on this machine at once: the machine's " <>
            "own declared `max_sessions`, capped at `enrolled_max_sessions`. Re-applied on " <>
            "every join (contract 1.13.0)."
      },
      enrolled_max_sessions: %Schema{
        type: :integer,
        minimum: Runner.max_sessions_range().first,
        maximum: Runner.max_sessions_range().last,
        description:
          "The CEILING an operator granted at enrollment. Never written by a join, so a " <>
            "machine can declare itself lower and never higher. Raising it means " <>
            "re-enrolling the machine."
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

  # A runner's dispatch kinds, refused by the runner itself. Declared once and used by both
  # read shapes — the registry and the pool — because it answers the same question in both:
  # why does this machine never get work?
  @unsupported_kinds_schema %Schema{
    type: :array,
    items: %Schema{type: :string},
    description:
      "Dispatch kinds this runner answered `kind_not_supported` for. A CAPABILITY " <>
        "statement, recorded permanently. Since contract 1.6.0 it is the whole decision " <>
        "ONLY for a runner that declares no `kinds` on join: loopctl sends none of these " <>
        "to such a machine again, and `implement` being the only dispatchable kind, one " <>
        "entry means it gets NO work at all while it stays enrolled. For a runner that " <>
        "DOES declare its kinds this list is HISTORY — what the machine refused before — " <>
        "and not a statement about the next dispatch, which the declaration alone decides " <>
        "(see `kinds` on the pool entry). Cleared for a declaring runner by RECONNECTING " <>
        "with the kind declared; for an undeclaring one only by revoking and re-enrolling " <>
        "the machine, which mints a new runner row."
  }

  @listed_runner_schema %Schema{
    @runner_schema
    | required: @runner_schema.required ++ [:unsupported_kinds],
      properties:
        Map.put(@runner_schema.properties, :unsupported_kinds, @unsupported_kinds_schema)
  }

  operation(:create,
    summary: "Enroll a runner",
    description:
      "Enrolls a dev machine as a runner and returns its credential ONCE, as `token`. The " <>
        "runner presents it in the `x-loopctl-runner-token` header when it connects to " <>
        "`/runner/socket/websocket`, and joins the topic `runner:<runner.id>` declaring " <>
        "exactly this `name`. The wire contract is `priv/runner_contract/v1.json`. " <>
        "`max_sessions` (default #{Runner.default_max_sessions()}) is the CEILING on how " <>
        "many dispatches loopctl will have in flight on this machine at once, and the value " <>
        "it starts at: since contract 1.13.0 every join re-applies the machine's own " <>
        "declared `max_sessions`, bounded by this one, so a machine may lower itself below " <>
        "its grant and never raise itself above it. Raising the ceiling later means " <>
        "REVOKING this runner and enrolling the machine again — the active-name index refuses " <>
        "a second active runner with the same name, and the revoke invalidates the credential, " <>
        "so the new token must reach the machine's token file and the runner be restarted. " <>
        "There is no endpoint that widens the ceiling in place. " <>
        "Requires user role; " <>
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
               "The most dispatches loopctl will EVER keep in flight on this machine at " <>
                 "once, and the value the row starts at. From its first join the machine's " <>
                 "own declared `max_sessions` governs (contract 1.13.0), bounded by this: " <>
                 "held capacity is the LESSER of the two, so a runner can take itself down " <>
                 "and cannot raise itself up. The tenant's total is capped separately " <>
                 "(RUNNER_MAX_IN_FLIGHT_SESSIONS)."
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
        "is Presence, not a row. Pass `include_revoked=true` for revoked ones too. " <>
        "`unsupported_kinds` names the dispatch kinds each machine has refused. Since " <>
        "contract 1.6.0 that decides what a machine is sent only while it declares no " <>
        "`kinds` on join; for a declaring runner the declaration decides and this list is " <>
        "history. The declaration is per-connection, so it is on the POOL entry and not " <>
        "here: this endpoint reads enrollment rows and cannot see it. To answer why a " <>
        "connected machine gets no work, read `GET /api/v1/runners/pool`.",
    parameters: [
      include_revoked: [in: :query, type: :boolean, description: "Include revoked runners"]
    ],
    responses: %{
      200 =>
        {"Runners", "application/json",
         %Schema{
           type: :object,
           properties: %{runners: %Schema{type: :array, items: @listed_runner_schema}}
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
        "reported. `reported_in_flight` is a hint — it counts the runner's sessions, not " <>
        "loopctl's reservations. `reported_max_sessions` is NOT: since contract 1.13.0 " <>
        "loopctl copies it into `max_sessions` on every join, capped at the runner's " <>
        "`enrolled_max_sessions`. So `max_sessions` below `reported_max_sessions` means one " <>
        "of three things — the runner has not reconnected since, it is still holding more " <>
        "sessions than it now declares, or it is declaring ABOVE the ceiling it was enrolled " <>
        "with, which `enrolled_max_sessions` here tells apart from the other two. " <>
        "`max_sessions` ABOVE `reported_max_sessions` means exactly one thing and it is not " <>
        "drift: the machine declared `0`, which the 1..64 column holds as `1` while this " <>
        "field shows the raw `0`. No NEW placement is made on it — `0` is refused like " <>
        "`draining`; a retry of a dispatch loopctl already holds is still re-sent. " <>
        "`kinds` is what the runner DECLARED on join (contract 1.6.0), " <>
        "and where it is present it alone decides which dispatches the machine is sent — " <>
        "so a connected machine that never gets work is explained by `kinds` or by " <>
        "`unsupported_kinds`, and both have to be read. Requires user role. Presence is a liveness " <>
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
                   :enrolled_max_sessions,
                   :reported_in_flight,
                   :reported_max_sessions,
                   :sample,
                   :live_sockets,
                   :node,
                   :machine_id,
                   :kinds,
                   :suppressed_kinds,
                   :unsupported_kinds
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
                     description:
                       "The slot limit dispatch reserves against (Postgres): the machine's " <>
                         "declared value capped at `enrolled_max_sessions`."
                   },
                   enrolled_max_sessions: %Schema{
                     type: :integer,
                     minimum: 1,
                     nullable: true,
                     description:
                       "The ceiling granted at enrollment (Postgres). A declaration above " <>
                         "it is held at it."
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
                     description:
                       "The session limit the runner declared on join. NOT a hint since " <>
                         "contract 1.13.0: it is what `max_sessions` is copied from, capped " <>
                         "at `enrolled_max_sessions`. `0` means the machine is taking no " <>
                         "work — held as `1` because the column is 1..64, and refused a " <>
                         "NEW placement like `draining`."
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
                   },
                   kinds: %Schema{
                     type: :array,
                     nullable: true,
                     items: %Schema{type: :string},
                     description:
                       "The dispatch kinds this runner DECLARED on join (contract 1.6.0), " <>
                         "or null from a runner that declared none. Where it is present it " <>
                         "is the whole decision: loopctl sends a kind in this list and " <>
                         "refuses one outside it, whatever `unsupported_kinds` holds. A " <>
                         "connected machine that never gets work is explained by this " <>
                         "field or by that one — read both. Per-CONNECTION, so it can " <>
                         "change when the runner reconnects."
                   },
                   suppressed_kinds: %Schema{
                     type: :array,
                     items: %Schema{type: :string},
                     description:
                       "Kinds this CONNECTION is not being sent because the runner " <>
                         "declared one and then answered `kind_not_supported` for it. " <>
                         "Held apart from `kinds`, which stays exactly what the machine " <>
                         "said: a suppression is loopctl withholding work, not the runner " <>
                         "changing its declaration. Cleared when the runner reconnects. A " <>
                         "non-empty value is a BUG on the runner — it contradicted itself " <>
                         "— and not a state to recover from by reconnecting."
                   },
                   unsupported_kinds: @unsupported_kinds_schema
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
    barred = Runners.unsupported_kinds(tenant.id)

    runners =
      tenant.id
      |> Runners.list_runners(include_revoked: include_revoked)
      |> Enum.map(&listed_runner(&1, barred))

    json(conn, %{runners: runners})
  end

  # The struct's own render plus the one DERIVED field. `Runner.public_fields/0` is the same
  # list its Jason encoder derives from, so this shape cannot drift from the plain one that
  # `create` and `delete` return.
  defp listed_runner(%Runner{} = runner, barred) do
    runner
    |> Map.take(Runner.public_fields())
    |> Map.put(:unsupported_kinds, Map.get(barred, runner.id, []))
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
    barred = Runners.unsupported_kinds(tenant.id)

    runners =
      tenant.id
      |> Runners.pool()
      |> Enum.map(&pool_entry(&1, capacity, barred))
      |> Enum.sort_by(& &1.machine)

    json(conn, %{runners: runners})
  end

  # What the runner DECLARED, or nil when it declared nothing — rendered from the SAME
  # function `Runners.dispatch/3` decides on, so the pool cannot show one thing while
  # dispatch does another. `:implied` renders null rather than `["implement"]`: that value
  # is loopctl's reading of silence, and printing it as the machine's own declaration would
  # tell an operator the runner said something it never said.
  defp declared_kinds(meta) do
    case Runners.declared_kinds(meta) do
      {:declared, kinds} -> kinds
      {:implied, _kinds} -> nil
    end
  end

  defp pool_entry({machine, %{metas: metas}}, capacity, barred) do
    meta = Enum.max_by(metas, &Map.get(&1, :joined_at), &joined_no_later?/2)
    held = Map.get(capacity, Map.get(meta, :runner_id), %{})

    %{
      machine: machine,
      runner_id: Map.get(meta, :runner_id),
      joined_at: Map.get(meta, :joined_at),
      in_flight: Map.get(held, :in_flight),
      draining: Map.get(meta, :draining),
      max_sessions: Map.get(held, :max_sessions),
      enrolled_max_sessions: Map.get(held, :enrolled_max_sessions),
      reported_in_flight: Map.get(meta, :in_flight),
      reported_max_sessions: Map.get(meta, :max_sessions),
      sample: Map.get(meta, :sample),
      live_sockets: length(metas),
      node: Map.get(meta, :node),
      machine_id: Map.get(meta, :machine_id),
      # The pool is where an operator looks at a machine that is connected and doing nothing,
      # so it is where "barred from every kind" has to be readable — and since contract
      # 1.6.0 that takes BOTH fields, because the declaration is what decides for a runner
      # that made one and it writes no ledger row when it refuses. A machine declaring
      # ["triage"] is refused every implement dispatch while `unsupported_kinds` stays
      # empty, which is the same silent-idle blind spot that list was added to close.
      # Null, not [], for a runner that declared nothing: an empty declaration and no
      # declaration are DIFFERENT states here, and only one of them decides anything.
      kinds: declared_kinds(meta),
      suppressed_kinds: Runners.suppressed_kinds(meta),
      unsupported_kinds: Map.get(barred, Map.get(meta, :runner_id), [])
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
