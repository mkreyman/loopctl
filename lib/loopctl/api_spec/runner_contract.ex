defmodule Loopctl.ApiSpec.RunnerContract do
  @moduledoc """
  The versioned wire contract between loopctl and a runner (issue #801).

  A runner is a dev machine that connects outbound over `LoopctlWeb.RunnerSocket`. This
  module is the ONE declaration of every message on that connection. The same schemas
  VALIDATE messages in both directions (`cast_join/1`, `cast_status/1`,
  `cast_dispatch_reply/1`, `cast_trace_batch/1`, `cast_trace_cursor/1` inbound,
  `cast_dispatch/1` outbound) and are EXPORTED as JSON
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

  | direction | event | schema | ok reply | error `reason`s |
  |---|---|---|---|---|
  | runner -> control | `phx_join` on `"runner:<runner_id>"` | `RunnerJoin` | `{contract_version}` | see `LoopctlWeb.RunnerChannel` |
  | runner -> control | `"status"` | `RunnerStatus` | empty | `rate_limited`, `invalid_payload` |
  | control -> runner | `"dispatch"` | `RunnerDispatch` (pushed only by `Loopctl.Runners.dispatch/3`) | — | — |
  | runner -> control | `"dispatch_reply"` | `RunnerDispatchReply` (since 1.1.0) | empty | `rate_limited`, `invalid_payload`, `unknown_dispatch`, `stale_claim_epoch`, `already_replied` |
  | runner -> control | `"trace"` | `RunnerTraceBatch` of `RunnerTraceEvent` (since 1.1.0) | `RunnerTraceAck` | `rate_limited`, `invalid_payload`, `batch_too_large`, `event_data_too_large`, `unknown_dispatch`, `stale_claim_epoch`, `dispatch_not_accepted`, `run_mismatch` |
  | runner -> control | `"trace_cursor"` | `RunnerTraceCursor` (since 1.1.0) | `RunnerTraceAck` | `rate_limited`, `invalid_payload` |

  ## Rate limits

  Published in `x-connection.limits`, and enforced per channel:

  - `min_interval_ms` (`min_interval_ms/1`) — `status` 1000 ms, `trace` 50 ms,
    `trace_cursor` 50 ms. Each event has its OWN floor: a `trace` batch is not held back
    by a recent `status` or `trace_cursor`, so the resume sequence (cursor, then batches)
    is never refused, and a rejoining runner ships up to 20 batches a second.
  - `dispatch_reply_burst` (`dispatch_reply_burst/0`) — a bucket of 8 replies that refills
    one every 250 ms, so several dispatches can be answered back to back.

  Only a message that is ACTED ON counts: one refused before the database (`invalid_payload`,
  `batch_too_large`, `event_data_too_large`) neither starts a floor nor spends a reply, so
  a runner can correct it and resend at once. A message inside its limit is refused with
  `rate_limited` and `min_interval_ms`; send it again after that long.

  ## Values

  Every UUID a runner sends is normalized to lowercase before it is compared or stored, so
  `ABCD...` and `abcd...` are the same id. `seq` must be below 2^63 - 1. No string —
  including any key or value inside an event's `data` — may contain a NUL character
  (`\\u0000`), which Postgres cannot store; such a message is `invalid_payload`.

  ## Dispatch replies

  A runner answers every `dispatch` it validated with one `dispatch_reply`. The first reply
  moves the ledger row out of `sent`; an IDENTICAL second reply is `ok` (so a reply whose
  acknowledgement was lost can be re-sent), and a DIFFERENT one is `already_replied`. A
  reply for a dispatch this runner was not sent — including another runner's or another
  tenant's — is `unknown_dispatch`, and one whose `claim_epoch` is not the dispatched one is
  `stale_claim_epoch`.

  ## Trace

  The runner's on-disk NDJSON file is the source of truth. It ships events in batches of at
  most `RunnerTraceBatch.max_events/0` events and `RunnerTraceBatch.max_bytes/0` bytes, each
  with at most `RunnerTraceEvent.max_data_bytes/0` of JSON `data`, both byte limits counted by
  `json_bytes_upper_bound/1` (published as `x-connection.limits.trace_max_batch_bytes`). The
  byte budget is what keeps a batch inside the socket's frame cap: a frame over it is closed
  by the transport before loopctl sees it, so a runner must split by the budget, not by the
  per-field character limits; the server stores `(run_id, seq)` once
  and replies `acked_seq`, the highest seq such that EVERY seq from 0 to it is stored. The
  runner resumes from `acked_seq + 1` — on a rejoin it asks `trace_cursor` first, because
  Phoenix replays nothing and a rejoin happens on every rolling deploy. The first batch of a
  run binds its `run_id` to the dispatch; a run belongs to one accepted dispatch.

  ## Versioning

  `version/0` is semver. A runner sends its `contract_version` on join; the join is
  refused unless the MAJOR matches. Minor versions only ADD optional fields, so an
  older server ignores fields it does not declare rather than refusing them, and a
  runner must do the same with a newer server's pushes.
  """

  require OpenApiSpex

  alias OpenApiSpex.Schema

  @version "1.1.0"
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

    # Bytes of the event's `data` as JSON. Referenced by the schema's description and by
    # `RunnerContract.cast_trace_batch/1`, which enforces it.
    @max_data_bytes 2_048

    @doc "The largest `data` object, in bytes of JSON, an event may carry."
    @spec max_data_bytes() :: pos_integer()
    def max_data_bytes, do: @max_data_bytes

    OpenApiSpex.schema(
      %{
        title: "RunnerTraceEvent",
        description:
          "One line of a run's NDJSON trace. The on-disk file is the source of truth: " <>
            "the runner ships `(run_id, seq)`, the server ACKs the last contiguous seq and " <>
            "dedups on the pair, and the runner resumes from that offset on rejoin. " <>
            "`parent` is REQUIRED on every event (null only for the root) so the agent " <>
            "tree can be rebuilt by query. `data` is at most #{@max_data_bytes} bytes of " <>
            "JSON, counted like the batch budget (refused with `event_data_too_large`); " <>
            "larger payloads belong in object storage, referenced from `data`.",
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

  defmodule RunnerDispatchReply do
    @moduledoc false
    require OpenApiSpex

    @refusal_reasons ~w(dispatches_disabled draining at_capacity insufficient_disk
                        repo_not_allowed branch_not_allowed wall_clock_exceeds_limit
                        max_turns_exceeds_limit token_budget_exceeds_limit other)
    @max_detail_length 500

    @doc "Every refusal reason a runner may give."
    @spec refusal_reasons() :: [String.t()]
    def refusal_reasons, do: @refusal_reasons

    @doc "The longest `detail` a refusal may carry."
    @spec max_detail_length() :: pos_integer()
    def max_detail_length, do: @max_detail_length

    OpenApiSpex.schema(
      %{
        title: "RunnerDispatchReply",
        description:
          "The runner's answer to one `dispatch`, pushed as the `dispatch_reply` event. " <>
            "`reason` is REQUIRED when `decision` is `refused` and forbidden when it is " <>
            "`accepted`; `detail` is required when `reason` is `other` and allowed only on a " <>
            "refusal. The server applies the first reply, answers an identical repeat `ok`, " <>
            "and refuses a different one with `already_replied`.",
        type: :object,
        required: [:dispatch_id, :claim_epoch, :decision],
        properties: %{
          dispatch_id: %Schema{type: :string, format: :uuid},
          claim_epoch: %Schema{
            type: :integer,
            minimum: 0,
            description: "The `claim_epoch` of the dispatch being answered, echoed."
          },
          decision: %Schema{type: :string, enum: ["accepted", "refused"]},
          reason: %Schema{type: :string, enum: @refusal_reasons},
          detail: %Schema{type: :string, minLength: 1, maxLength: @max_detail_length}
        }
      },
      struct?: false
    )
  end

  defmodule RunnerTraceBatch do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.RunnerTraceEvent

    # Referenced by `maxItems` below and enforced by `RunnerContract.cast_trace_batch/1`.
    @max_events 20

    # The byte budget of a whole batch, measured by `RunnerContract.json_bytes_upper_bound/1`
    # (every character as the longest escape a JSON encoder may write). A string's maxLength
    # counts CHARACTERS, and a control character escapes to six bytes, an astral one to
    # twelve, so a batch inside every per-field limit could still exceed the runner socket's
    # 64 KB frame, which Bandit closes before any of this code runs. This budget plus the
    # V2 frame envelope stays under that cap; a test holds it for the worst case.
    @max_bytes 60_000

    @doc "The most events one `trace` batch may carry."
    @spec max_events() :: pos_integer()
    def max_events, do: @max_events

    @doc "The byte budget of one `trace` batch, as `RunnerContract.json_bytes_upper_bound/1` counts it."
    @spec max_bytes() :: pos_integer()
    def max_bytes, do: @max_bytes

    OpenApiSpex.schema(
      %{
        title: "RunnerTraceBatch",
        description:
          "A batch of one run's trace events, pushed as the `trace` event. Every event's " <>
            "`run_id` must equal the batch's. At most #{@max_events} events and at most " <>
            "#{@max_bytes} bytes of JSON, counting every character at its longest escape " <>
            "(control characters 6 bytes, other non-ASCII 6, astral 12); either excess is " <>
            "refused with `batch_too_large`. The run must belong to an ACCEPTED dispatch this runner " <>
            "holds, at the dispatched `claim_epoch`; the first batch binds `run_id` to " <>
            "`dispatch_id`. Replied with `RunnerTraceAck`.",
        type: :object,
        required: [:run_id, :dispatch_id, :claim_epoch, :events],
        properties: %{
          run_id: %Schema{type: :string, format: :uuid},
          dispatch_id: %Schema{type: :string, format: :uuid},
          claim_epoch: %Schema{type: :integer, minimum: 0},
          events: %Schema{type: :array, maxItems: @max_events, items: RunnerTraceEvent.schema()}
        }
      },
      struct?: false
    )
  end

  defmodule RunnerTraceCursor do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "RunnerTraceCursor",
        description:
          "Asks where a run's stored trace ends, pushed as the `trace_cursor` event before " <>
            "resuming a shipment. Replied with `RunnerTraceAck`; a run this runner has not " <>
            "shipped (or does not hold) answers -1.",
        type: :object,
        required: [:run_id],
        properties: %{run_id: %Schema{type: :string, format: :uuid}}
      },
      struct?: false
    )
  end

  defmodule RunnerTraceAck do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "RunnerTraceAck",
        description:
          "The reply to `trace` and `trace_cursor`: the highest seq such that every seq " <>
            "from 0 to it is stored, or -1 when seq 0 is not. Resume from `acked_seq + 1`.",
        type: :object,
        required: [:acked_seq],
        properties: %{acked_seq: %Schema{type: :integer, minimum: -1}}
      },
      struct?: false
    )
  end

  @schemas [
    RunnerJoin,
    RunnerStatus,
    RunnerSample,
    RunnerDispatch,
    RunnerDispatchReply,
    RunnerTraceEvent,
    RunnerTraceBatch,
    RunnerTraceCursor,
    RunnerTraceAck
  ]

  # The stable `reason` codes each runner-to-control event can be refused with. Exported, so
  # a runner can switch on them without reading this source.
  @error_reasons %{
    "status" => ~w(rate_limited invalid_payload),
    "dispatch_reply" =>
      ~w(rate_limited invalid_payload unknown_dispatch stale_claim_epoch already_replied),
    "trace" =>
      ~w(rate_limited invalid_payload batch_too_large event_data_too_large unknown_dispatch
         stale_claim_epoch dispatch_not_accepted run_mismatch),
    "trace_cursor" => ~w(rate_limited invalid_payload)
  }

  # The minimum spacing, per channel, between two acted-on messages of one event. A message
  # inside it is refused with `rate_limited` and `min_interval_ms`. Each event has its OWN
  # floor. `LoopctlWeb.RunnerChannel` enforces exactly these values and the export publishes
  # them.
  @min_interval_ms %{
    "status" => 1_000,
    "trace" => 50,
    "trace_cursor" => 50
  }

  # `dispatch_reply` is a bucket rather than a floor: a runner handed several dispatches at
  # once answers them back to back, and a single per-runner gap refused the second answer.
  @dispatch_reply_burst %{"capacity" => 8, "refill_interval_ms" => 250}

  # One below Postgres `bigint`'s maximum: the contiguous-ack query probes `seq + 1`, which
  # must itself fit. The `runner_trace_events_seq` CHECK holds the same bound.
  @max_seq 9_223_372_036_854_775_806

  @doc "The contract version loopctl speaks (semver)."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  The minimum interval, in milliseconds, between two messages of `event` on one channel.
  The channel enforces it and the export publishes it (`x-connection.limits.min_interval_ms`).
  """
  @spec min_interval_ms(String.t()) :: pos_integer()
  def min_interval_ms(event), do: Map.fetch!(@min_interval_ms, event)

  @doc """
  The `dispatch_reply` bucket: `capacity` replies back to back, refilled one per
  `refill_interval_ms`. The channel enforces it and the export publishes it.
  """
  @spec dispatch_reply_burst() :: %{String.t() => pos_integer()}
  def dispatch_reply_burst, do: @dispatch_reply_burst

  @doc "The largest `seq` a trace event may carry."
  @spec max_seq() :: pos_integer()
  def max_seq, do: @max_seq

  @doc "The stable error `reason` codes, per runner-to-control event."
  @spec error_reasons() :: %{String.t() => [String.t()]}
  def error_reasons, do: @error_reasons

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

  @doc """
  Validates an outbound `dispatch` payload before it is pushed to a runner. Returns the
  declared fields only, with atom keys, or `{:error, {:invalid, messages}}`.

  Outbound is validated too, because the runner refuses by default and a push it cannot
  parse is a dispatch silently lost — and because nothing the contract does not declare
  may reach a machine that executes the payload as its user.
  """
  @spec cast_dispatch(term()) :: {:ok, map()} | {:error, term()}
  def cast_dispatch(payload) do
    with {:ok, cast} <- cast(payload, RunnerDispatch.schema()) do
      {:ok, known_fields(cast, RunnerDispatch.schema())}
    end
  end

  @doc """
  Validates a `dispatch_reply` payload. Returns the declared fields only, with atom keys, or
  `{:error, {:invalid, messages}}` — including for the cross-field rules JSON Schema cannot
  state: `reason` iff refused, `detail` only on a refusal and required with `other`.
  """
  @spec cast_dispatch_reply(term()) :: {:ok, map()} | {:error, term()}
  def cast_dispatch_reply(payload) do
    with {:ok, cast} <- cast(payload, RunnerDispatchReply.schema()),
         reply = known_fields(cast, RunnerDispatchReply.schema()),
         :ok <- no_nul(reply) do
      case reply_shape_errors(reply) do
        [] -> {:ok, reply}
        errors -> {:error, {:invalid, errors}}
      end
    end
  end

  defp reply_shape_errors(%{decision: "accepted"} = reply) do
    for key <- [:reason, :detail],
        Map.has_key?(reply, key),
        do: "#{key} is only allowed when decision is refused"
  end

  defp reply_shape_errors(%{decision: "refused", reason: "other"} = reply) do
    if Map.has_key?(reply, :detail), do: [], else: ["detail is required when reason is other"]
  end

  defp reply_shape_errors(%{decision: "refused", reason: _}), do: []
  defp reply_shape_errors(%{decision: "refused"}), do: ["reason is required when refused"]

  @doc """
  Validates a `trace` batch. Returns the declared fields only, with atom keys, or
  `{:error, reason}` where reason is `{:batch_too_large, max_events, max_bytes}`,
  `{:event_data_too_large, seq, max}` or `{:invalid, messages}`.

  The batch size is checked BEFORE the schema cast, so an oversize batch costs no per-event
  casting and gets its own reason a runner can act on by splitting.
  """
  @spec cast_trace_batch(term()) :: {:ok, map()} | {:error, term()}
  def cast_trace_batch(payload) do
    with :ok <- batch_size_ok(payload),
         {:ok, cast} <- cast(payload, RunnerTraceBatch.schema()) do
      batch = known_fields(cast, RunnerTraceBatch.schema())

      with :ok <- no_nul(batch),
           :ok <- events_ok(batch) do
        {:ok, batch}
      end
    end
  end

  # Measured on the payload AS SENT, undeclared keys included, since those were in the frame.
  defp batch_size_ok(payload) do
    max_events = RunnerTraceBatch.max_events()
    max_bytes = RunnerTraceBatch.max_bytes()

    too_many? =
      match?(%{"events" => events} when is_list(events) and length(events) > max_events, payload)

    if too_many? or json_bytes_upper_bound(payload) > max_bytes,
      do: {:error, {:batch_too_large, max_events, max_bytes}},
      else: :ok
  end

  @doc """
  An upper bound on the bytes of `term` encoded as compact JSON by ANY standard encoder.

  Every character is counted at the longest form an encoder may write it in: a control
  character or a non-ASCII BMP character as a six-byte `\\uXXXX`, an astral character as a
  twelve-byte surrogate pair, `"`, `\\` and `/` as two bytes, and printable ASCII as one.
  Floats count as 24 bytes. It is what the `trace` byte budget and the per-event `data` cap
  are measured with, so a runner that splits its batches by the same rule can never send a
  frame the socket closes.
  """
  @spec json_bytes_upper_bound(term()) :: non_neg_integer()
  def json_bytes_upper_bound(term) when is_binary(term), do: 2 + string_bytes(term, 0)
  def json_bytes_upper_bound(term) when is_integer(term), do: byte_size(Integer.to_string(term))
  def json_bytes_upper_bound(term) when is_float(term), do: 24
  def json_bytes_upper_bound(term) when term in [true, false, nil], do: 5

  def json_bytes_upper_bound(term) when is_atom(term),
    do: json_bytes_upper_bound(Atom.to_string(term))

  def json_bytes_upper_bound(term) when is_list(term),
    do: 2 + separators(length(term)) + Enum.sum_by(term, &json_bytes_upper_bound/1)

  def json_bytes_upper_bound(term) when is_map(term) do
    2 + separators(map_size(term)) +
      Enum.sum_by(term, fn {k, v} -> json_bytes_upper_bound(k) + 1 + json_bytes_upper_bound(v) end)
  end

  defp separators(0), do: 0
  defp separators(n), do: n - 1

  defp string_bytes(<<>>, acc), do: acc

  defp string_bytes(<<c::utf8, rest::binary>>, acc) when c in [?", ?\\, ?/],
    do: string_bytes(rest, acc + 2)

  defp string_bytes(<<c::utf8, rest::binary>>, acc) when c < 0x20, do: string_bytes(rest, acc + 6)
  defp string_bytes(<<c::utf8, rest::binary>>, acc) when c < 0x7F, do: string_bytes(rest, acc + 1)

  defp string_bytes(<<c::utf8, rest::binary>>, acc) when c < 0x10000,
    do: string_bytes(rest, acc + 6)

  defp string_bytes(<<_c::utf8, rest::binary>>, acc), do: string_bytes(rest, acc + 12)
  # Not valid UTF-8 (the socket's JSON decoder refuses it first); count a byte at its escape.
  defp string_bytes(<<_byte, rest::binary>>, acc), do: string_bytes(rest, acc + 6)

  defp events_ok(%{run_id: run_id, events: events}) do
    max = RunnerTraceEvent.max_data_bytes()

    Enum.reduce_while(events, :ok, fn event, :ok ->
      cond do
        event.run_id != run_id ->
          {:halt, {:error, {:invalid, ["event #{event.seq}: run_id differs from the batch"]}}}

        event.seq > @max_seq ->
          {:halt, {:error, {:invalid, ["event seq #{event.seq} exceeds #{@max_seq}"]}}}

        json_bytes_upper_bound(Map.get(event, :data, %{})) > max ->
          {:halt, {:error, {:event_data_too_large, event.seq, max}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  @doc "Validates a `trace_cursor` payload. Returns `{:ok, %{run_id: run_id}}`."
  @spec cast_trace_cursor(term()) :: {:ok, map()} | {:error, term()}
  def cast_trace_cursor(payload) do
    with {:ok, cast} <- cast(payload, RunnerTraceCursor.schema()) do
      {:ok, known_fields(cast, RunnerTraceCursor.schema())}
    end
  end

  # Postgres refuses a NUL in `text` and in any jsonb string, and the error would escape the
  # channel's handle_in on every resend of the same message. So a NUL anywhere a runner can
  # put one — every string, and every key and value of a free-form `data` object, at any
  # depth — is refused here, before anything is stored.
  defp no_nul(value) do
    if contains_nul?(value),
      do: {:error, {:invalid, ["strings may not contain a NUL character"]}},
      else: :ok
  end

  defp contains_nul?(value) when is_binary(value), do: String.contains?(value, <<0>>)
  defp contains_nul?(value) when is_list(value), do: Enum.any?(value, &contains_nul?/1)

  defp contains_nul?(%DateTime{}), do: false

  defp contains_nul?(value) when is_map(value),
    do: Enum.any?(value, fn {k, v} -> contains_nul?(k) or contains_nul?(v) end)

  defp contains_nul?(_value), do: false

  # OpenApiSpex keeps undeclared keys on an object, at every depth. Drop them at every
  # depth too, so nothing the contract does not declare reaches Presence.
  # An object that declares no properties (`RunnerTraceEvent.data`) is free-form by design.
  defp known_fields(map, %Schema{type: :object, properties: props})
       when is_map(map) and is_map(props) do
    for {key, sub} <- props, Map.has_key?(map, key), into: %{} do
      {key, known_fields(Map.fetch!(map, key), sub)}
    end
  end

  defp known_fields(list, %Schema{type: :array, items: %Schema{} = items}) when is_list(list),
    do: Enum.map(list, &known_fields(&1, items))

  # A UUID is compared and stored in ONE form. OpenApiSpex accepts either case, but Postgres
  # reads a uuid back lowercase, so an uppercase id would never equal its own stored value.
  defp known_fields(value, %Schema{type: :string, format: :uuid}) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> value
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
          "dispatch_reply" => "RunnerDispatchReply",
          "trace" => "RunnerTraceBatch",
          "trace_cursor" => "RunnerTraceCursor",
          "trace_event" => "RunnerTraceEvent"
        },
        "replies" => %{
          "trace" => "RunnerTraceAck",
          "trace_cursor" => "RunnerTraceAck"
        },
        "errors" => @error_reasons,
        "limits" => %{
          "trace_max_events" => RunnerTraceBatch.max_events(),
          "trace_max_event_data_bytes" => RunnerTraceEvent.max_data_bytes(),
          "trace_max_batch_bytes" => RunnerTraceBatch.max_bytes(),
          "refusal_max_detail_length" => RunnerDispatchReply.max_detail_length(),
          "trace_max_seq" => @max_seq,
          "min_interval_ms" => @min_interval_ms,
          "dispatch_reply_burst" => @dispatch_reply_burst
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
