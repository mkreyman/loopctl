defmodule Loopctl.ApiSpec.RunnerContract do
  @moduledoc """
  The versioned wire contract between loopctl and a runner (issue #801).

  A runner is a dev machine that connects outbound over `LoopctlWeb.RunnerSocket`. This
  module is the ONE declaration of every message on that connection. The same schemas
  VALIDATE inbound messages (`cast_join/1`, `cast_status/1`) and are EXPORTED as JSON
  Schema to `priv/runner_contract/v<major>.json` (`mix loopctl.runner_contract`), which
  `mkreyman/loopctl-runner` vendors. A test fails when the checked-in export drifts from
  these declarations, so the file a runner builds against is always the file loopctl
  enforces.

  ## Connection

  - socket: `wss://<host>/runner/socket/websocket?vsn=2.0.0`
  - credential: header `x-loopctl-runner-token: <raw runner key>`. Never a query
    parameter — a URL is logged by every proxy on the path.
  - topic: `"runner:<runner_id>"` — the id returned by `POST /api/v1/runners` — joined
    with a `RunnerJoin` payload. A runner may join only its own topic.

  ## Messages

  | direction | event | schema |
  |---|---|---|
  | runner -> control | `phx_join` on `"runner:<runner_id>"` | `RunnerJoin` |
  | runner -> control | `"status"` | `RunnerStatus` |
  | control -> runner | `"dispatch"` | `RunnerDispatch` (declared; emitted from #803) |
  | runner -> control | trace upload | `RunnerTraceEvent` (declared; shipped from #803) |

  ## Versioning

  `version/0` is semver. A runner sends its `contract_version` on join; the join is
  refused unless the MAJOR matches. Minor versions only ADD optional fields, so an
  older server ignores fields it does not declare rather than refusing them, and a
  runner must do the same with a newer server's pushes.
  """

  require OpenApiSpex

  alias OpenApiSpex.Schema

  @version "1.0.0"
  @major 1

  defmodule RunnerSample do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "RunnerSample",
        description:
          "A self-measured health sample. Connected is not able-to-build: a wedged " <>
            "machine still answers heartbeats, so the control plane treats a stale " <>
            "sample as a breached threshold.",
        type: :object,
        required: [:sampled_at, :loadavg_1m, :free_ram_mb, :free_disk_mb],
        properties: %{
          sampled_at: %Schema{type: :string, format: :"date-time"},
          loadavg_1m: %Schema{type: :number, minimum: 0},
          free_ram_mb: %Schema{type: :integer, minimum: 0},
          free_disk_mb: %Schema{type: :integer, minimum: 0},
          last_build_at: %Schema{
            type: :string,
            format: :"date-time",
            nullable: true,
            description: "When this machine last completed a build successfully."
          }
        }
      },
      struct?: false
    )
  end

  defmodule RunnerJoin do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.RunnerSample

    OpenApiSpex.schema(
      %{
        title: "RunnerJoin",
        description: "The payload a runner joins its own `runner:<runner_id>` topic with.",
        type: :object,
        required: [
          :contract_version,
          :machine,
          :cores,
          :memory_mb,
          :repos,
          :max_sessions,
          :in_flight,
          :draining
        ],
        properties: %{
          contract_version: %Schema{
            type: :string,
            pattern: "^[0-9]+\\.[0-9]+\\.[0-9]+$",
            description: "The contract version the runner was built against (semver)."
          },
          machine: %Schema{
            type: :string,
            pattern: "^[a-z0-9][a-z0-9._-]{0,62}$",
            description: "The machine name the runner was enrolled under. Must match exactly."
          },
          cores: %Schema{type: :integer, minimum: 1, maximum: 1024},
          memory_mb: %Schema{type: :integer, minimum: 1},
          repos: %Schema{
            type: :array,
            maxItems: 50,
            items: %Schema{
              type: :string,
              pattern: "^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$"
            },
            description: "GitHub `owner/repo` checkouts this runner can work in."
          },
          max_sessions: %Schema{
            type: :integer,
            minimum: 0,
            maximum: 64,
            description: "Concurrent sessions this machine accepts. Advisory; see in_flight."
          },
          in_flight: %Schema{
            type: :integer,
            minimum: 0,
            description:
              "Sessions running now, as the runner counts them. A hint: capacity is " <>
                "reserved in Postgres, never read off Presence."
          },
          draining: %Schema{
            type: :boolean,
            description: "True when the runner accepts no new dispatches."
          },
          sample: RunnerSample.schema()
        }
      },
      struct?: false
    )
  end

  defmodule RunnerStatus do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.RunnerSample

    OpenApiSpex.schema(
      %{
        title: "RunnerStatus",
        description:
          "A runner's periodic update, pushed as the `status` event. Any subset of the " <>
            "fields; at least one.",
        type: :object,
        minProperties: 1,
        properties: %{
          in_flight: %Schema{type: :integer, minimum: 0},
          draining: %Schema{type: :boolean},
          sample: RunnerSample.schema()
        }
      },
      struct?: false
    )
  end

  defmodule RunnerDispatch do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "RunnerDispatch",
        description:
          "Control pushes `dispatch` to start a session. The runner validates it against " <>
            "its LOCAL allow-list (repos, branch prefixes, wall clock, token budget) and " <>
            "refuses by default: a dispatch is a prompt executed as the machine's user. " <>
            "Declared in contract v1; emitted from #803.",
        type: :object,
        required: [
          :dispatch_id,
          :story_id,
          :kind,
          :repo,
          :base_branch,
          :branch,
          :claim_epoch,
          :wall_clock_seconds,
          :max_turns
        ],
        properties: %{
          dispatch_id: %Schema{type: :string, format: :uuid},
          story_id: %Schema{type: :string, format: :uuid},
          kind: %Schema{type: :string, enum: ["triage", "implement"]},
          repo: %Schema{type: :string, pattern: "^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$"},
          base_branch: %Schema{type: :string, minLength: 1, maxLength: 255},
          branch: %Schema{type: :string, minLength: 1, maxLength: 255},
          claim_epoch: %Schema{
            type: :integer,
            minimum: 0,
            description:
              "Echoed on every runner-to-control message about this dispatch. Bumped on " <>
                "reclaim, so a resurrected session's writes are rejected."
          },
          wall_clock_seconds: %Schema{type: :integer, minimum: 1},
          max_turns: %Schema{type: :integer, minimum: 1},
          token_budget: %Schema{type: :integer, minimum: 1, nullable: true}
        }
      },
      struct?: false
    )
  end

  defmodule RunnerTraceEvent do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "RunnerTraceEvent",
        description:
          "One line of a run's NDJSON trace. The on-disk file is the source of truth: " <>
            "the runner ships `(run_id, seq)`, the server ACKs the last contiguous seq and " <>
            "dedups on the pair, and the runner resumes from that offset on rejoin. " <>
            "`parent` is REQUIRED on every event (null only for the root) so the agent " <>
            "tree can be rebuilt by query.",
        type: :object,
        required: [:run_id, :seq, :event_id, :parent, :ts, :type],
        properties: %{
          run_id: %Schema{type: :string, format: :uuid},
          seq: %Schema{type: :integer, minimum: 0},
          event_id: %Schema{type: :string, minLength: 1, maxLength: 128},
          parent: %Schema{type: :string, minLength: 1, maxLength: 128, nullable: true},
          ts: %Schema{type: :string, format: :"date-time"},
          type: %Schema{type: :string, minLength: 1, maxLength: 64},
          data: %Schema{type: :object, additionalProperties: true}
        }
      },
      struct?: false
    )
  end

  @schemas [RunnerJoin, RunnerStatus, RunnerSample, RunnerDispatch, RunnerTraceEvent]

  @doc "The contract version loopctl speaks (semver)."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The schema modules the contract declares."
  @spec schema_modules() :: [module()]
  def schema_modules, do: @schemas

  @doc """
  Validates a join payload. Returns the known fields only, with atom keys, or
  `{:error, reason}` where reason is `{:invalid, messages}` or
  `{:unsupported_contract_version, sent, speaks}`.
  """
  @spec cast_join(term()) :: {:ok, map()} | {:error, term()}
  def cast_join(payload) do
    with {:ok, cast} <- cast(payload, RunnerJoin.schema()),
         :ok <- supported_version(cast.contract_version) do
      {:ok, known_fields(cast, RunnerJoin.schema())}
    end
  end

  @doc "Validates a `status` payload. Returns the known fields only, with atom keys."
  @spec cast_status(term()) :: {:ok, map()} | {:error, term()}
  def cast_status(payload) do
    with {:ok, cast} <- cast(payload, RunnerStatus.schema()) do
      case known_fields(cast, RunnerStatus.schema()) do
        empty when map_size(empty) == 0 -> {:error, {:invalid, ["no known status field"]}}
        known -> {:ok, known}
      end
    end
  end

  # OpenApiSpex keeps undeclared keys on an object, at every depth. Drop them at every
  # depth too, so nothing the contract does not declare reaches Presence.
  defp known_fields(map, %Schema{type: :object, properties: props}) when is_map(map) do
    for {key, sub} <- props, Map.has_key?(map, key), into: %{} do
      {key, known_fields(Map.fetch!(map, key), sub)}
    end
  end

  defp known_fields(value, _schema), do: value

  defp cast(payload, schema) when is_map(payload) do
    case OpenApiSpex.Cast.cast(schema, payload) do
      {:ok, cast} -> {:ok, cast}
      {:error, errors} -> {:error, {:invalid, Enum.map(errors, &to_string/1)}}
    end
  end

  defp cast(_payload, _schema), do: {:error, {:invalid, ["payload must be an object"]}}

  defp supported_version(sent) do
    case String.split(sent, ".") do
      [major | _] when major == unquote(Integer.to_string(@major)) -> :ok
      _ -> {:error, {:unsupported_contract_version, sent, @version}}
    end
  end

  @doc """
  The contract as a JSON Schema document (2020-12), the shape written to
  `priv/runner_contract/v<major>.json`.
  """
  @spec json_schema() :: map()
  def json_schema do
    defs = Map.new(@schemas, fn mod -> {mod.schema().title, schema_to_map(mod.schema())} end)

    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "https://loopctl.com/runner_contract/v#{@major}.json",
      "title" => "loopctl runner contract",
      "x-contract-version" => @version,
      "x-connection" => %{
        "socket_path" => "/runner/socket/websocket",
        "credential_header" => "x-loopctl-runner-token",
        "topic" => "runner:{runner_id}",
        "events" => %{
          "join" => "RunnerJoin",
          "status" => "RunnerStatus",
          "dispatch" => "RunnerDispatch",
          "trace_event" => "RunnerTraceEvent"
        }
      },
      "$defs" => defs
    }
  end

  @doc "The export path for the current major version, relative to the app root."
  @spec export_path() :: String.t()
  def export_path, do: "priv/runner_contract/v#{@major}.json"

  @doc "The export encoded as it is checked in: pretty JSON with sorted keys and a newline."
  @spec encoded_json_schema() :: String.t()
  def encoded_json_schema do
    json_schema()
    |> sort_keys()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp sort_keys(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> {to_string(k), sort_keys(v)} end)
    |> Jason.OrderedObject.new()
  end

  defp sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  defp sort_keys(other), do: other

  # OpenApiSpex nullable -> JSON Schema 2020-12 type union. Nested schemas are inlined
  # (`RunnerSample` inside `RunnerJoin`), because `OpenApiSpex.Cast` cannot resolve a
  # module reference without a full spec, and validation must use these exact structs.
  defp schema_to_map(%Schema{} = schema) do
    base =
      [
        description: schema.description,
        pattern: schema.pattern,
        format: schema.format && to_string(schema.format),
        minimum: schema.minimum,
        maximum: schema.maximum,
        minLength: schema.minLength,
        maxLength: schema.maxLength,
        maxItems: schema.maxItems,
        minProperties: schema.minProperties,
        enum: schema.enum,
        required: schema.required && Enum.map(schema.required, &to_string/1),
        additionalProperties: schema.additionalProperties,
        items: schema.items && schema_to_map(schema.items),
        properties:
          schema.properties &&
            Map.new(schema.properties, fn {k, v} -> {to_string(k), schema_to_map(v)} end)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    type = to_string(schema.type)
    Map.put(base, "type", if(schema.nullable, do: [type, "null"], else: type))
  end
end
