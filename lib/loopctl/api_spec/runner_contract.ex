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
  | runner -> control | `phx_join` on `"runner:<runner_id>"` | `RunnerJoin` | `{contract_version}` | `rate_limited`, `not_authorized`, `invalid_payload`, `unsupported_contract_version`, `machine_mismatch`, `forbidden_topic`, `unknown_topic` |
  | runner -> control | `"status"` | `RunnerStatus` | empty | `rate_limited`, `invalid_payload` |
  | control -> runner | `"dispatch"` | `RunnerDispatch` (pushed only by `Loopctl.Runners.dispatch/3`) | — | — |
  | runner -> control | `"dispatch_reply"` | `RunnerDispatchReply` (since 1.1.0) | empty | `rate_limited`, `invalid_payload`, `unknown_dispatch`, `stale_claim_epoch`, `already_replied` |
  | runner -> control | `"trace"` | `RunnerTraceBatch` of `RunnerTraceEvent` (since 1.1.0) | `RunnerTraceAck` | `rate_limited`, `invalid_payload`, `batch_too_large`, `event_data_too_large`, `unknown_dispatch`, `stale_claim_epoch`, `dispatch_not_accepted`, `run_mismatch` |
  | runner -> control | `"trace_cursor"` | `RunnerTraceCursor` (since 1.1.0) | `RunnerTraceAck` | `rate_limited`, `invalid_payload` |
  | control -> runner | `"disconnecting"` | `RunnerDisconnecting` (since 1.2.0) | — | — |
  | runner -> control | any other event | — | — | `unknown_event` (since 1.2.0; every time, never `rate_limited`) |

  ## Server-initiated disconnects (since 1.2.0)

  Before loopctl closes a runner's connection itself, it pushes `"disconnecting"` on the
  runner's topic with a stable `reason` (`RunnerDisconnecting.reasons/0`), then closes, so
  the runner can tell a revocation from a deploy from a network drop. `runner_revoked` and
  `no_longer_authorized` precede the socket being closed; `server_shutdown` precedes the
  drain of a stopping node, after which the runner should reconnect. A join refused as
  `not_authorized` cannot carry a push — the topic was never joined — so its error reply
  carries `disconnecting: "join_refused_not_authorized"` instead, and the socket is closed
  only after that reply has been sent.

  ## Rate limits

  Published in `x-connection.limits`, and enforced per channel:

  - `min_interval_ms` (`min_interval_ms/1`) — `status` 1000 ms, `trace` 50 ms,
    `trace_cursor` 50 ms. Each event has its OWN floor: a `trace` batch is not held back by a recent
    `status` or `trace_cursor`, so the resume sequence (cursor, then batches) is never
    refused, and a rejoining runner ships up to 20 batches a second.
  - `dispatch_reply_burst` (`dispatch_reply_burst/0`) — a bucket of 8 replies that refills
    one every 250 ms, so several dispatches can be answered back to back.

  Only a message that is ACTED ON counts: one refused before the database (`invalid_payload`,
  `batch_too_large`, `event_data_too_large`) neither starts a floor nor spends a reply, so
  a runner can correct it and resend at once. A message inside its limit is refused with
  `rate_limited` and `min_interval_ms`; send it again after that long.

  ## Values

  Every UUID a runner sends is normalized to lowercase before it is compared or stored, so
  `ABCD...` and `abcd...` are the same id. `seq` must be below 2^63 - 1, and no number in a
  `trace` or `dispatch_reply` may have more digits than the byte rule allows. No string —
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
  event at most `RunnerTraceEvent.max_bytes/0` with at most `RunnerTraceEvent.max_data_bytes/0`
  of `data`. Every byte limit is counted by ONE published rule (`ByteRule`, exported as
  `x-connection.limits.json_byte_rule` with its text, and quoted in each schema's description):
  six bytes per string character, a fixed width per scalar, a fixed cost per container and
  member. It bounds the compact JSON of any conforming encoder, whatever that encoder escapes,
  so a runner that splits by it never sends a frame the socket closes — the transport closes an
  oversize frame before loopctl sees it. Large payloads belong in object storage, referenced
  from `data`; the server stores `(run_id, seq)` once
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

  @version "1.2.0"
  @major 1

  defmodule ByteRule do
    @moduledoc false

    # ONE encoder-independent rule for the size of runner-supplied JSON (issue #803). It does
    # not model any encoder's escaping: it charges every string character the most any
    # conforming encoder can spend on it (a six-byte \\uXXXX; two of them for a character
    # outside the BMP), and every scalar a fixed width. Go's encoding/json escapes < > &, .NET
    # escapes more, a JSON library can escape everything — the bound holds for all of them.
    # The constants are published in the contract export, the text in every schema that
    # carries a byte limit, and a test evaluates the PUBLISHED constants against `bytes/1`.
    @per_char 6
    @per_string 12
    @per_scalar 32
    @per_container 2
    @per_member 2
    @max_number_digits 31

    @doc "The rule's constants, as the export publishes them."
    @spec constants() :: %{String.t() => pos_integer()}
    def constants do
      %{
        "per_string_char" => @per_char,
        "per_string" => @per_string,
        "per_scalar" => @per_scalar,
        "per_container" => @per_container,
        "per_member" => @per_member,
        "max_number_digits" => @max_number_digits
      }
    end

    @doc "The rule as one sentence, published verbatim."
    @spec text() :: String.t()
    def text do
      "Byte rule (compact JSON, any encoder): count #{@per_char} bytes for every character " <>
        "of every string and object key (#{2 * @per_char} for a character outside the Basic " <>
        "Multilingual Plane) plus #{@per_string} per string; #{@per_scalar} per number, true, " <>
        "false or null; #{@per_container} per array or object; #{@per_member} per array " <>
        "element or object member. A number may have at most #{@max_number_digits} digits."
    end

    @doc "The largest integer magnitude the rule's fixed scalar width covers."
    @spec max_number_digits() :: pos_integer()
    def max_number_digits, do: @max_number_digits

    @doc "The size of `term` under the rule."
    @spec bytes(term()) :: non_neg_integer()
    def bytes(term) when is_binary(term), do: @per_char * utf16_units(term) + @per_string
    def bytes(term) when is_number(term) or term in [true, false, nil], do: @per_scalar
    def bytes(term) when is_atom(term), do: bytes(Atom.to_string(term))

    def bytes(term) when is_list(term),
      do: @per_container + Enum.sum_by(term, &(@per_member + bytes(&1)))

    def bytes(term) when is_map(term),
      do: @per_container + Enum.sum_by(term, fn {k, v} -> @per_member + bytes(k) + bytes(v) end)

    # A character outside the BMP is two UTF-16 code units (a surrogate pair when escaped).
    # A byte that is not UTF-8 (the socket's JSON decoder refuses those first) counts as one.
    defp utf16_units(string), do: utf16_units(string, 0)
    defp utf16_units(<<>>, n), do: n
    defp utf16_units(<<c::utf8, rest::binary>>, n) when c > 0xFFFF, do: utf16_units(rest, n + 2)
    defp utf16_units(<<_c::utf8, rest::binary>>, n), do: utf16_units(rest, n + 1)
    defp utf16_units(<<_byte, rest::binary>>, n), do: utf16_units(rest, n + 1)
  end

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

    alias Loopctl.ApiSpec.RunnerContract.ByteRule

    # Both under `ByteRule`. Referenced by the description, the export and
    # `RunnerContract.cast_trace_batch/1`. A schema-valid event with `data` at its cap and
    # every string at its maxLength in astral characters stays under `@max_bytes`, and one
    # such event always fits a batch, so splitting a batch can always make progress.
    @max_data_bytes 6_000
    @max_bytes 12_000

    @doc "The largest `data` object an event may carry, under the byte rule."
    @spec max_data_bytes() :: pos_integer()
    def max_data_bytes, do: @max_data_bytes

    @doc "The largest event, undeclared keys included, under the byte rule."
    @spec max_bytes() :: pos_integer()
    def max_bytes, do: @max_bytes

    OpenApiSpex.schema(
      %{
        title: "RunnerTraceEvent",
        description:
          "One line of a run's NDJSON trace. The on-disk file is the source of truth: " <>
            "the runner ships `(run_id, seq)`, the server ACKs the last contiguous seq and " <>
            "dedups on the pair, and the runner resumes from that offset on rejoin. " <>
            "`parent` is REQUIRED on every event (null only for the root) so the agent " <>
            "tree can be rebuilt by query. `data` is at most #{@max_data_bytes} bytes and the " <>
            "whole event at most #{@max_bytes}, both under the byte rule below; either excess " <>
            "is refused with `event_data_too_large` naming the event's `seq`. Large payloads " <>
            "(tool output, file contents) belong in object storage, referenced from `data`. " <>
            ByteRule.text(),
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

    alias Loopctl.ApiSpec.RunnerContract.ByteRule
    alias Loopctl.ApiSpec.RunnerContract.RunnerTraceEvent

    # Referenced by `maxItems` below and enforced by `RunnerContract.cast_trace_batch/1`.
    @max_events 20

    # The byte budget of a whole batch under `ByteRule`. A string's maxLength counts
    # characters, not bytes, so only a byte budget keeps a frame inside the runner socket's
    # 64 KB cap, which Bandit enforces by closing the socket before any of this code runs.
    # This budget plus `RunnerContract.frame_envelope_bytes/0` stays under that cap; a test
    # holds it against an encoder that escapes every character.
    @max_bytes 60_000

    @doc "The most events one `trace` batch may carry."
    @spec max_events() :: pos_integer()
    def max_events, do: @max_events

    @doc "The byte budget of one `trace` batch, under the byte rule."
    @spec max_bytes() :: pos_integer()
    def max_bytes, do: @max_bytes

    OpenApiSpex.schema(
      %{
        title: "RunnerTraceBatch",
        description:
          "A batch of one run's trace events, pushed as the `trace` event. Every event's " <>
            "`run_id` must equal the batch's. At most #{@max_events} events and at most " <>
            "#{@max_bytes} bytes under the byte rule below; either excess is refused with " <>
            "`batch_too_large`, so split the batch — except that a one-event batch over the " <>
            "budget is refused with `event_data_too_large` naming its `seq`, since splitting " <>
            "cannot help. The run must belong to an ACCEPTED dispatch this runner holds, at " <>
            "the dispatched `claim_epoch`; the first batch binds `run_id` to `dispatch_id`. " <>
            "Replied with `RunnerTraceAck`. " <> ByteRule.text(),
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

  defmodule RunnerDisconnecting do
    @moduledoc false
    require OpenApiSpex

    @reasons ~w(runner_revoked no_longer_authorized join_refused_not_authorized server_shutdown)

    @doc "Every reason loopctl gives for a disconnect it initiates."
    @spec reasons() :: [String.t()]
    def reasons, do: @reasons

    OpenApiSpex.schema(
      %{
        title: "RunnerDisconnecting",
        description:
          "Pushed as `disconnecting` on the runner's topic immediately before loopctl closes " <>
            "the runner's connection itself. `runner_revoked` and `no_longer_authorized` mean " <>
            "the credential no longer works: do not reconnect until re-enrolled. " <>
            "`server_shutdown` means the node is stopping: reconnect. " <>
            "`join_refused_not_authorized` arrives as the `disconnecting` field of a refused " <>
            "join's error reply, because an unjoined topic cannot carry a push.",
        type: :object,
        required: [:reason],
        properties: %{reason: %Schema{type: :string, enum: @reasons}}
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
    RunnerTraceAck,
    RunnerDisconnecting
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
    "trace_cursor" => ~w(rate_limited invalid_payload),
    # Since 1.2.0. `join` is the `phx_join` reply; `unknown_event` answers any event this
    # map does not name, every time.
    "join" => ~w(rate_limited not_authorized invalid_payload unsupported_contract_version
         machine_mismatch forbidden_topic unknown_topic),
    "unknown_event" => ~w(unknown_event)
  }

  # The runner-to-control events `LoopctlWeb.RunnerChannel.handle_in/3` acts on.
  @inbound_events ~w(status dispatch_reply trace trace_cursor)

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

  # What the Phoenix V2 frame around a `trace` payload can cost under `ByteRule`:
  # [join_ref, ref, "runner:<uuid>", "trace", payload] with 20-digit refs is under 600.
  @frame_envelope_bytes 1_000

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

  @doc "The allowance for the V2 frame around a `trace` payload, under the byte rule."
  @spec frame_envelope_bytes() :: pos_integer()
  def frame_envelope_bytes, do: @frame_envelope_bytes

  @doc "The largest `seq` a trace event may carry."
  @spec max_seq() :: pos_integer()
  def max_seq, do: @max_seq

  @doc """
  The stable error `reason` codes, per runner-to-control event, plus `join` (the `phx_join`
  reply) and `unknown_event` (any event not named here).
  """
  @spec error_reasons() :: %{String.t() => [String.t()]}
  def error_reasons, do: @error_reasons

  @doc "The runner-to-control events the channel acts on (`phx_join` aside)."
  @spec inbound_events() :: [String.t()]
  def inbound_events, do: @inbound_events

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
    with :ok <- values_ok(payload),
         {:ok, cast} <- cast(payload, RunnerDispatchReply.schema()) do
      reply = known_fields(cast, RunnerDispatchReply.schema())

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
  `{:event_data_too_large, seq, max_data_bytes, max_event_bytes}` or `{:invalid, messages}`.

  In order: every value is storable (no NUL, no number wider than the byte rule's scalar);
  the event count; the schema; then each event's own limits, which win over the batch
  budget; then the batch budget. A one-event batch over the budget is refused as
  `event_data_too_large` for that event, because splitting it cannot help. Sizes are taken
  under `ByteRule` on the payload AS SENT, undeclared keys included, since those were in
  the frame.
  """
  @spec cast_trace_batch(term()) :: {:ok, map()} | {:error, term()}
  def cast_trace_batch(payload) do
    with :ok <- values_ok(payload),
         :ok <- event_count_ok(payload),
         {:ok, cast} <- cast(payload, RunnerTraceBatch.schema()),
         batch = known_fields(cast, RunnerTraceBatch.schema()),
         :ok <- events_ok(batch, Map.fetch!(payload, "events")),
         :ok <- batch_bytes_ok(batch, payload) do
      {:ok, batch}
    end
  end

  @doc """
  The size of `term` under the published byte rule (`x-connection.limits.json_byte_rule`):
  an upper bound on the compact JSON any conforming encoder writes for it.
  """
  @spec json_bytes_upper_bound(term()) :: non_neg_integer()
  def json_bytes_upper_bound(term), do: ByteRule.bytes(term)

  defp event_count_ok(%{"events" => events}) when is_list(events) do
    if length(events) > RunnerTraceBatch.max_events(),
      do: {:error, batch_too_large()},
      else: :ok
  end

  defp event_count_ok(_payload), do: :ok

  defp batch_too_large,
    do: {:batch_too_large, RunnerTraceBatch.max_events(), RunnerTraceBatch.max_bytes()}

  defp event_too_large(seq),
    do:
      {:event_data_too_large, seq, RunnerTraceEvent.max_data_bytes(),
       RunnerTraceEvent.max_bytes()}

  # `raw_events` are the events as sent, in the order the cast kept them.
  defp events_ok(%{run_id: run_id, events: events}, raw_events) do
    events
    |> Enum.zip(raw_events)
    |> Enum.reduce_while(:ok, fn {event, raw}, :ok ->
      cond do
        event.run_id != run_id ->
          {:halt, {:error, {:invalid, ["event #{event.seq}: run_id differs from the batch"]}}}

        event.seq > @max_seq ->
          {:halt, {:error, {:invalid, ["event seq #{event.seq} exceeds #{@max_seq}"]}}}

        ByteRule.bytes(Map.get(event, :data, %{})) > RunnerTraceEvent.max_data_bytes() ->
          {:halt, {:error, event_too_large(event.seq)}}

        ByteRule.bytes(raw) > RunnerTraceEvent.max_bytes() ->
          {:halt, {:error, event_too_large(event.seq)}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp batch_bytes_ok(%{events: events}, payload) do
    cond do
      ByteRule.bytes(payload) <= RunnerTraceBatch.max_bytes() -> :ok
      match?([_], events) -> {:error, event_too_large(hd(events).seq)}
      true -> {:error, batch_too_large()}
    end
  end

  @doc "Validates a `trace_cursor` payload. Returns `{:ok, %{run_id: run_id}}`."
  @spec cast_trace_cursor(term()) :: {:ok, map()} | {:error, term()}
  def cast_trace_cursor(payload) do
    with {:ok, cast} <- cast(payload, RunnerTraceCursor.schema()) do
      {:ok, known_fields(cast, RunnerTraceCursor.schema())}
    end
  end

  # Every value a runner sends must be storable and sizable, checked on the payload as sent:
  #
  # - no NUL in any string, key or value, at any depth. Postgres refuses one in `text` and in
  #   any jsonb string, and the error would escape the channel's handle_in on every resend.
  # - no integer wider than the byte rule's fixed scalar width, which is what lets a runner
  #   count every number at one published size.
  defp values_ok(value) do
    cond do
      contains_nul?(value) ->
        {:error, {:invalid, ["strings may not contain a NUL character"]}}

      too_wide_number?(value) ->
        {:error, {:invalid, ["numbers may have at most #{ByteRule.max_number_digits()} digits"]}}

      true ->
        :ok
    end
  end

  defp contains_nul?(value) when is_binary(value), do: String.contains?(value, <<0>>)
  defp contains_nul?(value) when is_list(value), do: Enum.any?(value, &contains_nul?/1)

  defp contains_nul?(value) when is_map(value),
    do: Enum.any?(value, fn {k, v} -> contains_nul?(k) or contains_nul?(v) end)

  defp contains_nul?(_value), do: false

  defp too_wide_number?(value) when is_integer(value),
    do: abs(value) >= Integer.pow(10, ByteRule.max_number_digits())

  defp too_wide_number?(value) when is_list(value), do: Enum.any?(value, &too_wide_number?/1)

  defp too_wide_number?(value) when is_map(value),
    do: Enum.any?(value, fn {_k, v} -> too_wide_number?(v) end)

  defp too_wide_number?(_value), do: false

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
          "trace_event" => "RunnerTraceEvent",
          "disconnecting" => "RunnerDisconnecting"
        },
        "replies" => %{
          "trace" => "RunnerTraceAck",
          "trace_cursor" => "RunnerTraceAck"
        },
        "errors" => @error_reasons,
        "limits" => %{
          "trace_max_events" => RunnerTraceBatch.max_events(),
          "trace_max_event_data_bytes" => RunnerTraceEvent.max_data_bytes(),
          "trace_max_event_bytes" => RunnerTraceEvent.max_bytes(),
          "trace_max_batch_bytes" => RunnerTraceBatch.max_bytes(),
          "frame_envelope_bytes" => @frame_envelope_bytes,
          "json_byte_rule" => Map.put(ByteRule.constants(), "text", ByteRule.text()),
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
