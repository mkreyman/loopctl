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
  | runner -> control | `"stage"` | `RunnerStageReport` (since 1.4.0) | `{stage, claim_epoch, lock_version, attempts, effects}` | `rate_limited`, `invalid_payload`, `unknown_dispatch`, `dispatch_not_accepted`, `stale_claim_epoch`, `stale_stage`, `unknown_story_stage`, `effect_conflict` |
  | runner -> control | any other event | — | — | `unknown_event` (since 1.2.0; every time, never `rate_limited`) |
  | control -> runner | `"disconnecting"` | `RunnerDisconnecting` (since 1.2.0) | — | — |
  | (1.3.0) a dispatch's `wall_clock_seconds` is bounded: `RunnerDispatch.max_wall_clock_seconds/0` | | | | |
  | (1.5.0) an implement dispatch carries a `RunnerStory`, and a runner may refuse a kind with `kind_not_supported` | | | | |

  ## The story object (since 1.5.0)

  An `implement` dispatch carries the story as TYPED FIELDS — `RunnerStory` — and loopctl
  never sends a prompt. The runner composes its own prompt from those fields with its own
  template.

  That is a security property and not a convenience. A dispatch is executed as the machine's
  user with that machine's credentials, so a control plane able to hand a runner PROSE TO
  EXECUTE is a control plane able to run anything on every enrolled laptop. Typed fields
  bound what a dispatch can say: a field the schema does not declare cannot be sent, and
  every field it does declare is data the runner places inside a template it wrote.

  The object is OPTIONAL on the wire, so a 1.4.0 runner ignores it, and it is allowed only on
  an `implement` dispatch. Its `id` must be the dispatch's own `story_id`: a dispatch naming
  one story and carrying another's text is the confusion the check exists to prevent.

  Every cap is declared once in `RunnerStory` and published at
  `x-connection.limits.story`. The per-field caps are `maxLength`/`maxItems` — characters and
  items, the units JSON Schema counts in — and the WHOLE OBJECT is bounded in bytes by the
  same `ByteRule` every other payload here is measured with (`RunnerStory.max_bytes/0`). The
  object cap is the one that usually binds, and loopctl REFUSES an oversize story rather than
  truncating it: a silently dropped acceptance criterion is a story built to the wrong spec.
  See `Loopctl.Delivery.StoryPayload`, which escalates the story to a human instead of
  dispatching a partial one.

  `domain_reference` looks like another repository's concern and is on this wire deliberately.
  `mkreyman/home_care_billing` runs a domain gate that refuses any pull request touching
  `lib/home_care_billing*` without a reference to the domain document the change belongs to
  (loopctl #805). The implementing session has to name it in the pull request it opens, and
  the session's only input is this dispatch — so a field loopctl does not carry is a field the
  session cannot produce, and every such pull request fails that repository's gate. It is one
  bounded string, chosen by triage, and no other repository is obliged to set it.

  ## Dispatchable kinds

  `kind` declares the vocabulary (`triage`, `implement`); `RunnerDispatch.dispatchable_kinds/0`
  is what loopctl will actually send, and `cast_dispatch/1` refuses anything else BEFORE a
  payload is recorded or broadcast. Today that is `implement` alone.

  Triage is excluded structurally rather than by convention. Its input is the reporter's own
  words, which the implementer must never see (design §10), so it needs its own payload with
  its own fencing (`Loopctl.Delivery.Untrusted`) — and the implement payload has no field that
  could carry it. A triage dispatch on this shape would reach a machine with no input and a
  template for the wrong job. The `kind` enum keeps `triage` because narrowing an enum is a
  BREAKING change and a minor version may only add; the refusal lives in the cast instead.

  A runner may also answer a dispatch with `kind_not_supported`, a CAPABILITY statement rather
  than a fault: this machine does not do this kind of work. loopctl records it and does not
  send that kind to that runner again (`Loopctl.Runners.DispatchLedger.kind_unsupported?/3`).

  ## Stage reporting (since 1.4.0)

  A runner reports each delivery-stage transition its session made with `stage`. **Postgres
  owns the stage; the message is a request.** The server compare-and-sets `from` -> `to` on
  the story's `story_stages` row in one transaction, fenced on `claim_epoch` exactly as
  `dispatch_reply` and `trace` are, and answers with the row's new stage, epoch,
  `lock_version` and `attempts`. The transition table is published at
  `x-connection.stage_transitions`, derived from the server's own machine.

  **A runner may report what its own session DID AND CONTROL CAN INDEPENDENTLY CHECK, plus
  its own escalation — never the outcome of a check it does not perform.** The published
  table is that rule applied to the server's machine, by two allowlists.

  The EDGES exclude the verdicts some other principal reaches about the session:
  `merge_gate` (the merge-precondition gate is control's), `verification_failed` (post-deploy
  verification compares the deployed sha against the merge commit, which the session cannot
  see) and `budget_exceeded` (`failed` is terminal with no way out at all, so a runner able
  to report it could park a story for good — a session out of budget escalates instead and
  control decides). Also held back: anything into `claimed`, and `runner_lost`,
  `claim_released` and `human_resolution`.

  The SOURCES stop at `merged`, which is where the loop stops producing things control can
  check and starts producing verdicts. `merged` carries a `merge_sha` and `deployed` a
  `release_id`, both of which GitHub can confirm; `verified` and `done` carry nothing and are
  pure verdicts. **A story therefore WAITS at `deployed` for control to decide
  verified-or-escalated, and a runner has no path to `verified` or `done` at all.** Reporting
  the deploy is the last thing a session does.

  Arriving at a terminal stage ends the session and the runner's slot goes back in the same
  transaction — the server decides that from the destination stage, so no message can free a
  slot while its session runs. The only terminal a runner can reach is `escalated`, which
  STOPS the loop rather than completing it; `done` and `failed` are not reportable at all.

  Every `stage` message is safe to REPLAY, and the ack tells you what the server holds. One
  whose first copy committed finds the row already at `to` under the same epoch and is
  answered `ok` with that row, so a re-send after a lost acknowledgement — which happens on
  every rolling deploy — never transitions twice. A message for a row that has moved somewhere
  ELSE is `stale_stage`: re-read the story and send the transition that applies.

  **A replay must carry the SAME identities its first copy did.** One that names a DIFFERENT
  value for an identity already recorded is `effect_conflict`, never `ok`: the case that
  forces it is `ci -> merged`, where a lost ack and a retry that produced a second merge
  commit would otherwise leave the row and the `story_stage_merged` chain entry naming a
  merge that is not the branch's. The ack's `effects` is what the row actually holds, so a
  runner can see which value survived and reconcile against it. Do not re-send after an
  `effect_conflict`.

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

  One case that rule does not cover: a message the server ACCEPTED but could not write,
  because a database lock it needed was not free (loopctl #803). It comes back as
  `rate_limited` with a `min_interval_ms` LONGER than that wait, and it has already spent its
  trace floor or a `dispatch_reply` bucket token — it reached the database, which is what the
  floors meter. A runner that keeps re-sending inside the interval it was given can therefore
  run its reply bucket down while none of the replies is recorded; wait the interval out.

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

  alias Loopctl.Delivery.StageMachine
  alias OpenApiSpex.Schema

  @version "1.5.0"
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
            description:
              "Concurrent sessions this machine accepts; it refuses past them with " <>
                "`at_capacity`. Advisory to loopctl, which reserves against the max_sessions " <>
                "the runner was ENROLLED with, never this value."
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

  defmodule RunnerStory do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.ByteRule

    # EVERY cap of the story object, declared once here (since 1.5.0). The schema below reads
    # them, `RunnerContract.cast_dispatch/1` enforces the byte cap from `max_bytes/0`,
    # `Loopctl.Delivery.ImplementerInput.story_object/2` builds against them, and
    # `limits/0` publishes them. Nothing restates a number.
    #
    # The per-field caps are `maxLength`/`maxItems` — the units JSON Schema counts in, and
    # the ones the runner's vendored validator implements. OpenApiSpex counts a `maxLength`
    # in GRAPHEMES, which is looser than codepoints; that is harmless here because nothing
    # downstream is a Postgres CHECK, and the object cap below is counted with `ByteRule`,
    # which charges six bytes per UTF-16 unit and therefore bounds anything a loose grapheme
    # count let through.
    @max_title_length 200
    @max_description_length 8_000
    @max_criteria 20
    @max_criterion_length 500
    @max_test_cases 20
    @max_test_case_length 500
    @max_touches 100
    @max_touch_length 200
    @max_domain_reference_length 500

    # The WHOLE object, under `ByteRule` — the one byte counter this contract has.
    #
    # It is derived from the frame, not chosen: the contract's demonstrated-safe payload
    # budget is `RunnerTraceBatch.max_bytes/0` (60_000) plus
    # `RunnerContract.frame_envelope_bytes/0`, held against a 64 KB socket frame by a test
    # that assumes an encoder escaping every character. A dispatch's non-story fields, every
    # one of them at its own maximum, cost about 6_000 under the same rule, so 48_000 leaves
    # the story the budget the frame can carry with headroom to spare —
    # `runner_contract_test.exs` asserts that sum rather than trusting this arithmetic.
    #
    # It is also the cap that BINDS. The per-field caps above sum to far more than this, so
    # in practice a story is refused for its total size and not for one long field. Measured
    # on the committed `docs/user_stories` corpus on 2026-09-13: a story's title, description,
    # acceptance criteria and test cases run 14_000-38_500 bytes under this rule, so 48_000
    # admits the corpus and an oversize story is a genuinely oversize story rather than an
    # ordinary one meeting a cap set too low.
    @max_bytes 48_000

    @doc "The largest story object, under the byte rule."
    @spec max_bytes() :: pos_integer()
    def max_bytes, do: @max_bytes

    @doc "The longest title."
    @spec max_title_length() :: pos_integer()
    def max_title_length, do: @max_title_length

    @doc "The longest description."
    @spec max_description_length() :: pos_integer()
    def max_description_length, do: @max_description_length

    @doc "The most acceptance criteria, and the longest one."
    @spec max_criteria() :: pos_integer()
    def max_criteria, do: @max_criteria

    @doc "The longest acceptance criterion."
    @spec max_criterion_length() :: pos_integer()
    def max_criterion_length, do: @max_criterion_length

    @doc "The most test cases."
    @spec max_test_cases() :: pos_integer()
    def max_test_cases, do: @max_test_cases

    @doc "The longest test case."
    @spec max_test_case_length() :: pos_integer()
    def max_test_case_length, do: @max_test_case_length

    @doc "The most paths a story may predict it touches."
    @spec max_touches() :: pos_integer()
    def max_touches, do: @max_touches

    @doc "The longest touched path."
    @spec max_touch_length() :: pos_integer()
    def max_touch_length, do: @max_touch_length

    @doc "The longest domain reference."
    @spec max_domain_reference_length() :: pos_integer()
    def max_domain_reference_length, do: @max_domain_reference_length

    @doc "Every cap of the story object, as the export publishes them."
    @spec limits() :: %{String.t() => pos_integer()}
    def limits do
      %{
        "max_bytes" => @max_bytes,
        "max_title_length" => @max_title_length,
        "max_description_length" => @max_description_length,
        "max_criteria" => @max_criteria,
        "max_criterion_length" => @max_criterion_length,
        "max_test_cases" => @max_test_cases,
        "max_test_case_length" => @max_test_case_length,
        "max_touches" => @max_touches,
        "max_touch_length" => @max_touch_length,
        "max_domain_reference_length" => @max_domain_reference_length
      }
    end

    OpenApiSpex.schema(
      %{
        title: "RunnerStory",
        description:
          "The story an `implement` dispatch is for, as TYPED FIELDS (since 1.5.0). loopctl " <>
            "never sends a prompt: the runner composes one from these fields with its own " <>
            "template, because a dispatch runs as the machine's user and a control plane " <>
            "able to hand a runner prose to execute is able to run anything on it. `id` " <>
            "must be the dispatch's own `story_id`. The whole object is at most " <>
            "#{@max_bytes} bytes under the byte rule below, which is the cap that usually " <>
            "binds; loopctl REFUSES an oversize story and escalates it to a human rather " <>
            "than truncating one, since a dropped acceptance criterion is a story built to " <>
            "the wrong spec. `domain_reference` is the domain document the change belongs " <>
            "to, required by some repositories' own pull-request gates. " <> ByteRule.text(),
        type: :object,
        required: [:id, :title],
        properties: %{
          id: %Schema{
            type: :string,
            format: :uuid,
            description: "The story's id. Must equal the dispatch's `story_id`."
          },
          title: %Schema{type: :string, minLength: 1, maxLength: @max_title_length},
          description: %Schema{type: :string, maxLength: @max_description_length},
          acceptance_criteria: %Schema{
            type: :array,
            maxItems: @max_criteria,
            items: %Schema{type: :string, minLength: 1, maxLength: @max_criterion_length},
            description:
              "What the work is judged against, one string per criterion, in the story's " <>
                "own order. Never truncated: a story with more than #{@max_criteria} is " <>
                "refused."
          },
          test_cases: %Schema{
            type: :array,
            maxItems: @max_test_cases,
            items: %Schema{type: :string, minLength: 1, maxLength: @max_test_case_length}
          },
          touches: %Schema{
            type: :array,
            maxItems: @max_touches,
            items: %Schema{type: :string, minLength: 1, maxLength: @max_touch_length},
            description:
              "The paths triage predicted the change touches. Advisory to the session and " <>
                "never a permission: what a runner may write is its own local allow-list."
          },
          domain_reference: %Schema{
            type: :string,
            minLength: 1,
            maxLength: @max_domain_reference_length
          }
        }
      },
      struct?: false
    )
  end

  defmodule RunnerDispatch do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.RunnerStory

    # A session's wall clock, bounded (since 1.3.0). The runner stops a session there, and
    # loopctl stores the value and presumes a slot free past it plus a grace
    # (`Loopctl.Runners.Capacity`), so an unbounded one both outlives any real session and
    # overflows the `runner_dispatches.wall_clock_seconds` integer column — a raise out of
    # `Loopctl.Runners.dispatch/3` rather than the `invalid_payload` an out-of-range value
    # deserves. A day is the story claim lease's own default (`STORY_CLAIM_LEASE_SECONDS`):
    # past it the claim would be reclaimed under the session anyway.
    @max_wall_clock_seconds 86_400

    @doc "The longest wall clock a dispatch may give a session."
    @spec max_wall_clock_seconds() :: pos_integer()
    def max_wall_clock_seconds, do: @max_wall_clock_seconds

    # The `kind` VOCABULARY, and the subset loopctl will actually send (since 1.5.0). Both are
    # declared here; `RunnerContract.cast_dispatch/1` refuses a kind outside
    # `dispatchable_kinds/0` before anything is recorded or broadcast, and the export
    # publishes both lists.
    #
    # `triage` stays in the enum and out of the dispatchable set. Narrowing an enum would be a
    # BREAKING change and a minor version may only add — and the vocabulary is what a runner
    # answers `kind_not_supported` about. What keeps triage off the wire is the cast: its
    # input is the reporter's own words, which the implementer must never see (design §10), so
    # it needs its own payload with its own fencing, and this shape has no field that could
    # carry it.
    @kinds ["triage", "implement"]
    @dispatchable_kinds ["implement"]

    @doc "Every dispatch kind the contract names."
    @spec kinds() :: [String.t()]
    def kinds, do: @kinds

    @doc "The kinds loopctl will send. Every other declared kind is refused by the cast."
    @spec dispatchable_kinds() :: [String.t()]
    def dispatchable_kinds, do: @dispatchable_kinds

    OpenApiSpex.schema(
      %{
        title: "RunnerDispatch",
        description:
          "Control pushes `dispatch` to start a session. The runner validates it against " <>
            "its LOCAL allow-list (repos, branch prefixes, wall clock, token budget) and " <>
            "refuses by default: a dispatch runs as the machine's user. Since 1.5.0 an " <>
            "`implement` dispatch carries the story as TYPED FIELDS (`story`) and never a " <>
            "prompt — the runner composes its own from them. `story` is allowed only on an " <>
            "`implement` dispatch and its `id` must equal `story_id`. Only the kinds in " <>
            "`x-connection.dispatchable_kinds` are sent; a runner that does not do a kind " <>
            "answers `kind_not_supported` and is not sent that kind again. " <>
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
          kind: %Schema{type: :string, enum: @kinds},
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
          wall_clock_seconds: %Schema{
            type: :integer,
            minimum: 1,
            maximum: @max_wall_clock_seconds,
            description:
              "How long the runner lets the session run before stopping it. At most " <>
                "#{@max_wall_clock_seconds} (a day) since contract 1.3.0."
          },
          max_turns: %Schema{type: :integer, minimum: 1},
          token_budget: %Schema{type: :integer, minimum: 1, nullable: true},
          story: RunnerStory.schema()
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

    # `kind_not_supported` (since 1.5.0) is the one refusal that is a CAPABILITY STATEMENT
    # rather than a fault: this machine does not do this kind of work, and it will not do it
    # after a retry either. loopctl treats it as PERMANENT for that runner and that kind and
    # sends no more of them (`Loopctl.Runners.DispatchLedger.kind_unsupported?/3`), which is
    # what makes it different from `draining` or `at_capacity` — those are about right now.
    # Like every refusal it gives the slot straight back, so it costs the runner no capacity,
    # and nothing reads a refusal as a health signal.
    @refusal_reasons ~w(dispatches_disabled draining at_capacity insufficient_disk
                        repo_not_allowed branch_not_allowed wall_clock_exceeds_limit
                        max_turns_exceeds_limit token_budget_exceeds_limit
                        kind_not_supported other)
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

  defmodule RunnerStage do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.Delivery.StageMachine

    # The wire enums are DERIVED from the stage machine (`StageMachine.runner_transitions/0`),
    # so the contract cannot declare a stage or an edge the machine does not have, and an edge
    # added to the machine is on the wire the moment it is reportable. The individual enums
    # bound each field; `RunnerContract.cast_stage/1` checks the TRIPLE, which is the real
    # rule — `{ci, escalated, ci_red}` passes three separate enums and is not a transition.
    @from_stages Enum.map(StageMachine.runner_from_stages(), &Atom.to_string/1)
    @to_stages Enum.map(StageMachine.runner_to_stages(), &Atom.to_string/1)
    @edges Enum.map(StageMachine.runner_edges(), &Atom.to_string/1)

    # The `story_stages_text_bounds` CHECK's bound, read from `StageMachine` — the ONE place
    # it is declared (#824 round 2), rather than a fourth copy of the number.
    #
    # CODEPOINTS, matching Postgres `char_length`. The schema's `maxLength` below cannot
    # enforce that: OpenApiSpex counts it with `String.length/1`, which counts GRAPHEMES, and
    # an emoji family or a combining mark is one grapheme and several characters to Postgres
    # — so a 4000-grapheme reason cast clean here and was refused by the CHECK afterwards,
    # which is not a retryable class. `RunnerContract.reason_length_errors/1` applies the
    # codepoint bound, and the `maxLength` stays as the published number a runner splits by.
    @max_reason_length StageMachine.max_reason_length()

    @doc "The bound counted the way Postgres counts it."
    @spec codepoints(String.t()) :: non_neg_integer()
    def codepoints(value), do: value |> String.to_charlist() |> length()

    @doc """
    The effect identities a `stage` message may carry, read off the schema's OWN properties.

    `StageMachine.reportable_effects/0` is the DECLARATION; this is what the schema actually
    says, and `runner_contract_test.exs` asserts the two are equal — so a property added here
    without the machine's blessing, or an effect the machine allows and the schema forgot,
    both go red. The ack and the `effect_conflict` refusal read the machine's list.

    At runtime, not compile time: `schema/0` is defined by the `OpenApiSpex.schema` macro
    below and a module attribute cannot call it.
    """
    @spec effect_names() :: [atom()]
    def effect_names, do: schema().properties |> Map.keys() |> Enum.sort()

    @doc "The stages a runner may report a transition OUT of."
    @spec from_stages() :: [String.t()]
    def from_stages, do: @from_stages

    @doc "The stages a runner may report a transition INTO."
    @spec to_stages() :: [String.t()]
    def to_stages, do: @to_stages

    @doc "The edges a runner may report."
    @spec edges() :: [String.t()]
    def edges, do: @edges

    @doc "The longest escalation reason or note a stage message may carry."
    @spec max_reason_length() :: pos_integer()
    def max_reason_length, do: @max_reason_length

    OpenApiSpex.schema(
      %{
        title: "RunnerStageEffects",
        description:
          "The identities a transition produced, recorded on the story's stage row before " <>
            "the effect is repeated. Each is writable only by the stage that produces it, " <>
            "and only once: the same value again is accepted (a replay finds what its " <>
            "first run recorded), a different one is refused. `merge_sha` is the one that " <>
            "cannot be written before its effect, because the merge commit does not exist " <>
            "until GitHub makes it, so it is REQUIRED on the transition into `merged` and " <>
            "accepted nowhere else. `runner_id` is deliberately absent: which machine holds " <>
            "a story is control's to record, not a runner's to assert.",
        type: :object,
        properties: %{
          worktree_path: %Schema{type: :string, minLength: 1, maxLength: 4096},
          branch: %Schema{type: :string, minLength: 1, maxLength: 255},
          head_sha: %Schema{type: :string, pattern: "^[0-9a-f]{40}([0-9a-f]{24})?$"},
          merge_sha: %Schema{type: :string, pattern: "^[0-9a-f]{40}([0-9a-f]{24})?$"},
          pr_number: %Schema{type: :integer, minimum: 1},
          release_id: %Schema{type: :string, minLength: 1, maxLength: 255}
        }
      },
      struct?: false
    )
  end

  defmodule RunnerStageReport do
    @moduledoc false
    require OpenApiSpex

    alias Loopctl.ApiSpec.RunnerContract.RunnerStage

    OpenApiSpex.schema(
      %{
        title: "RunnerStageReport",
        description:
          "One delivery-stage transition a runner's session made, pushed as the `stage` " <>
            "event (since 1.4.0). It is a REQUEST, never authority: Postgres owns the " <>
            "stage, and the server compare-and-sets `from` -> `to` on the story's row " <>
            "inside one transaction. `from` is on the wire for that reason — a row that " <>
            "has moved refuses the message with `stale_stage` rather than taking a " <>
            "transition from wherever it happens to be. `claim_epoch` is the fence: it " <>
            "must be the dispatch's AND the story's current epoch, so a session whose " <>
            "claim was reclaimed writes nothing. A REPLAY is safe — a message whose first " <>
            "copy committed finds the row already at `to` and is answered `ok` with the " <>
            "row, so a re-send after a lost acknowledgement never transitions twice. " <>
            "Arriving at a terminal stage also gives the runner slot back, in the same " <>
            "transaction; the server decides that from the stage, so nothing here can free " <>
            "a slot whose session is still running. `escalated` is the only terminal a " <>
            "runner can reach: `verified` and `done` are control's verdicts, not a " <>
            "session's, so a story waits at `deployed`.",
        type: :object,
        required: [:dispatch_id, :claim_epoch, :from, :to],
        properties: %{
          dispatch_id: %Schema{
            type: :string,
            format: :uuid,
            description:
              "The ACCEPTED dispatch whose session made this transition. It names the " <>
                "story; a story id is never taken from the wire."
          },
          claim_epoch: %Schema{
            type: :integer,
            minimum: 0,
            description: "The `claim_epoch` of the dispatch, echoed."
          },
          from: %Schema{
            type: :string,
            enum: RunnerStage.from_stages(),
            description: "The stage the runner believed the story was at."
          },
          to: %Schema{type: :string, enum: RunnerStage.to_stages()},
          edge: %Schema{
            type: :string,
            enum: RunnerStage.edges(),
            description:
              "Which transition, when `from` -> `to` has more than one. Defaults to " <>
                "`forward`. Every edge but `forward` counts in the story's `attempts`."
          },
          reason: %Schema{
            type: :string,
            minLength: 1,
            maxLength: RunnerStage.max_reason_length(),
            description:
              "REQUIRED entering `escalated` and on `merge_refused`, a free note " <>
                "otherwise. Session-authored and therefore untrusted: it is recorded and " <>
                "capped, never executed, and fenced as untrusted data wherever it reaches " <>
                "a prompt. At most #{RunnerStage.max_reason_length()} CODEPOINTS — the " <>
                "`maxLength` beside this is the same number counted as graphemes, which " <>
                "is looser, so split by codepoints. A reason over the bound is " <>
                "`invalid_payload`."
          },
          effects: RunnerStage.schema()
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
    RunnerStory,
    RunnerDispatch,
    RunnerDispatchReply,
    RunnerTraceEvent,
    RunnerTraceBatch,
    RunnerTraceCursor,
    RunnerTraceAck,
    RunnerDisconnecting,
    RunnerStage,
    RunnerStageReport
  ]

  # The stable `reason` codes each runner-to-control event can be refused with. Exported, so
  # a runner can switch on them without reading this source.
  #
  # `internal_error` is on EVERY inbound event and is the server admitting a gap: a refusal
  # reason no clause of `LoopctlWeb.RunnerChannel.message_error/1` names. It used to RAISE,
  # which took the channel down and every in-flight session on that socket with it (#824
  # round 2). It is not actionable — retrying is reasonable, the same message may well work
  # once the gap is closed — and the underlying reason is logged server-side, never sent.
  @error_reasons %{
    "status" => ~w(rate_limited invalid_payload internal_error),
    "dispatch_reply" =>
      ~w(rate_limited invalid_payload unknown_dispatch stale_claim_epoch already_replied
         internal_error),
    "trace" =>
      ~w(rate_limited invalid_payload batch_too_large event_data_too_large unknown_dispatch
         stale_claim_epoch dispatch_not_accepted run_mismatch internal_error),
    "trace_cursor" => ~w(rate_limited invalid_payload internal_error),
    # Since 1.4.0. Two codes are NEW because nothing already published carries their remedy,
    # and a runner that cannot tell them apart does the wrong thing:
    #
    # - `stale_stage` — the row is not at `from`. The message is well formed and the claim is
    #   fine, so `invalid_payload` (stop sending this) and `stale_claim_epoch` (stop working
    #   the story) are both actively wrong. Re-read the story's stage and send the transition
    #   that actually applies.
    # - `unknown_story_stage` — the dispatch's story has no stage row at all, which is a
    #   control-plane state the runner cannot fix by resending or by giving up the claim.
    #   `unknown_dispatch` would name the wrong object: the dispatch is known.
    #
    # Everything the stage machine refuses on the MESSAGE's own content — a transition that
    # is not in the table, a missing escalation reason, a malformed or wrong-stage effect —
    # is `invalid_payload` with details, because resending it unchanged cannot help.
    # - `effect_conflict` — the server already recorded a DIFFERENT identity for this
    #   transition. Read the recorded values off the ack (`effects`) and reconcile; do NOT
    #   re-send. `invalid_payload` would tell a runner whose merge sha was dropped that its
    #   message was malformed, which is both wrong and the wrong remedy. The refusal CARRIES
    #   the recorded identities in `effects`, because the case it exists for is a LOST ack —
    #   the runner never saw the one that named the surviving value.
    # - `audit_chain_append_failed` — the tenant's hash chain refused this transition's entry
    #   and nothing was written. PERMANENT: the next attempt fails the same way and every
    #   custody transition in the tenant is failing until an operator acts. Do NOT retry; it is
    #   deliberately not `rate_limited`, and it is the same code the HTTP surface answers.
    "stage" =>
      ~w(rate_limited invalid_payload unknown_dispatch dispatch_not_accepted stale_claim_epoch
         stale_stage unknown_story_stage effect_conflict audit_chain_append_failed
         internal_error),
    # Since 1.2.0. `join` is the `phx_join` reply; `unknown_event` answers any event this
    # map does not name, every time.
    "join" => ~w(rate_limited not_authorized invalid_payload unsupported_contract_version
         machine_mismatch forbidden_topic unknown_topic),
    "unknown_event" => ~w(unknown_event)
  }

  # The runner-to-control events `LoopctlWeb.RunnerChannel.handle_in/3` acts on.
  @inbound_events ~w(status dispatch_reply trace trace_cursor stage)

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

  # `stage` is a bucket for the same reason, and a bigger one. A machine at `max_sessions: 2`
  # runs two stories at once, each walking a thirteen-stage line, and a runner that has been
  # offline through a rolling deploy ships every transition it buffered the moment it
  # rejoins. A per-channel FLOOR would refuse the second story's message because the first
  # story's had just landed. Each message is a database transaction and some of them append
  # to the tenant's audit chain, so it is metered; the bucket lets a burst through and then
  # paces it.
  @stage_burst %{"capacity" => 12, "refill_interval_ms" => 250}

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

  @doc """
  The `stage` bucket: `capacity` transitions back to back, refilled one per
  `refill_interval_ms`. The channel enforces it and the export publishes it.
  """
  @spec stage_burst() :: %{String.t() => pos_integer()}
  def stage_burst, do: @stage_burst

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

  Beyond the schema it applies the three cross-field rules JSON Schema cannot state, all
  three of which keep something off a machine that would execute it:

  - the `kind` is one loopctl actually sends (`RunnerDispatch.dispatchable_kinds/0`). Triage
    is declared and not dispatchable; see the moduledoc.
  - a `story` rides only an `implement` dispatch, and its `id` is the dispatch's own
    `story_id`. A dispatch naming one story and carrying another's text is the confusion
    worth refusing rather than resolving.
  - the story is within `RunnerStory.max_bytes/0` under `ByteRule`. Refused, never truncated:
    the caller escalates the story instead (`Loopctl.Delivery.StoryPayload`).
  """
  @spec cast_dispatch(term()) :: {:ok, map()} | {:error, term()}
  def cast_dispatch(payload) do
    with {:ok, cast} <- cast(payload, RunnerDispatch.schema()) do
      dispatch = known_fields(cast, RunnerDispatch.schema())

      case dispatch_shape_errors(dispatch) do
        [] -> {:ok, dispatch}
        errors -> {:error, {:invalid, errors}}
      end
    end
  end

  defp dispatch_shape_errors(dispatch) do
    kind_errors(dispatch) ++ story_errors(dispatch)
  end

  defp kind_errors(%{kind: kind}) do
    if kind in RunnerDispatch.dispatchable_kinds(),
      do: [],
      else: [
        "kind #{kind} is declared but not dispatchable: loopctl sends only " <>
          Enum.join(RunnerDispatch.dispatchable_kinds(), ", ")
      ]
  end

  defp kind_errors(_dispatch), do: []

  defp story_errors(%{story: story, kind: kind, story_id: story_id}) do
    cond do
      kind != "implement" ->
        ["story is only allowed when kind is implement"]

      Map.get(story, :id) != story_id ->
        ["story.id must be the dispatch's story_id"]

      ByteRule.bytes(story) > RunnerStory.max_bytes() ->
        ["story exceeds #{RunnerStory.max_bytes()} bytes under the byte rule"]

      true ->
        []
    end
  end

  defp story_errors(_dispatch), do: []

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

  @doc """
  Validates a `stage` payload (since 1.4.0). Returns the declared fields only, with the
  stage and edge as ATOMS — `%{dispatch_id:, claim_epoch:, from:, to:, edge:, reason:,
  effects:}` — or `{:error, {:invalid, messages}}`.

  `edge` defaults to `:forward`. Beyond the schema it checks the two cross-field rules JSON
  Schema cannot state:

  - the TRIPLE is a transition a runner may report
    (`Loopctl.Delivery.StageMachine.runner_reportable?/3`). Three independent enums admit
    combinations the machine has no edge for, and refusing them here means a nonsense
    transition never opens a database transaction.
  - a reason is present where the machine requires one (entering `escalated`, and
    `merge_refused`). `Loopctl.Delivery.Stages` refuses it too — this is the copy that
    answers the runner before the write, not the enforcement.

  The stage and edge atoms come from a COMPILE-TIME map of the machine's own atoms, so no
  wire value ever creates one — and, unlike the `String.to_existing_atom/1` this used to
  call, the conversion does not depend on `Loopctl.Delivery.StageMachine` already having been
  loaded. See the comment above `@wire_atoms`.
  """
  @spec cast_stage(term()) :: {:ok, map()} | {:error, term()}
  def cast_stage(payload) do
    with :ok <- values_ok(payload),
         {:ok, cast} <- cast(payload, RunnerStageReport.schema()) do
      stage =
        cast
        |> known_fields(RunnerStageReport.schema())
        |> Map.put_new(:edge, "forward")
        |> then(
          &%{&1 | from: stage_atom(&1.from), to: stage_atom(&1.to), edge: stage_atom(&1.edge)}
        )

      case stage_shape_errors(stage) do
        [] -> {:ok, stage}
        errors -> {:error, {:invalid, errors}}
      end
    end
  end

  # Wire string -> the machine's own atom, resolved through a COMPILE-TIME map and never
  # through `String.to_existing_atom/1`.
  #
  # That function raised here, and the bug is worth naming because it looks impossible: the
  # atoms plainly exist, they are written as literals in `Loopctl.Delivery.StageMachine`. But
  # an atom in a module's constant pool comes into being when that MODULE IS LOADED, and
  # Elixir loads lazily. This module's enums are compiled down to STRINGS
  # (`Atom.to_string/1` at compile time), so nothing in `cast_stage/1`'s path forces
  # `StageMachine` to load before the conversion — the first call in a fresh VM raised
  # `ArgumentError: not an already existing atom` and took the runner's channel down with it.
  # It passed for a while only because some earlier test happened to load the module first,
  # which is a test-ordering accident and not a property of the code.
  #
  # The map's VALUES are atom literals in THIS module's constant pool, so they exist the
  # moment this code runs. `Map.get/2` rather than `fetch!/2`: an unmapped string yields nil,
  # `runner_reportable?/3` refuses the triple, and the caller gets `invalid_payload` instead
  # of a raise. The OpenApiSpex enum has already rejected anything unmapped, but "another
  # validator already checked it" is exactly the reasoning that produced the raise above.
  @wire_atoms Map.new(
                StageMachine.stages() ++ StageMachine.runner_edges(),
                &{Atom.to_string(&1), &1}
              )

  defp stage_atom(name), do: Map.get(@wire_atoms, name)

  defp stage_shape_errors(%{from: from, to: to, edge: edge} = stage) do
    transition_errors(from, to, edge) ++
      reason_errors(to, edge, stage) ++
      reason_length_errors(stage)
  end

  # The `maxLength` on the schema counts GRAPHEMES; Postgres counts CODEPOINTS. Left to the
  # schema alone the wire bound was LOOSER than the `story_stages_text_bounds` CHECK, so a
  # reason of 4000 graphemes and more codepoints was accepted here, refused by
  # `Loopctl.Delivery.Stages` deeper in, and on the HTTP path reached the database and died
  # as a 23514 the caller could do nothing with. Counted here, the wire, the context and the
  # CHECK all agree on one number.
  defp reason_length_errors(%{reason: reason}) when is_binary(reason) do
    if RunnerStage.codepoints(reason) > RunnerStage.max_reason_length(),
      do: ["reason may be at most #{RunnerStage.max_reason_length()} codepoints"],
      else: []
  end

  defp reason_length_errors(_stage), do: []

  defp transition_errors(from, to, edge) do
    if StageMachine.runner_reportable?(from, to, edge),
      do: [],
      else: ["#{from} -> #{to} over #{edge} is not a transition a runner may report"]
  end

  defp reason_errors(to, edge, stage) do
    if StageMachine.reason_required?(to, edge) and not Map.has_key?(stage, :reason),
      do: ["reason is required entering #{to} over #{edge}"],
      else: []
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
          "disconnecting" => "RunnerDisconnecting",
          "stage" => "RunnerStageReport",
          "story" => "RunnerStory"
        },
        # The kinds loopctl will actually send. `RunnerDispatch.kind`'s enum is the
        # VOCABULARY, which is wider: `triage` is declared and refused by `cast_dispatch/1`
        # until it has its own payload. Published so a runner knows which it must handle.
        "dispatchable_kinds" => RunnerDispatch.dispatchable_kinds(),
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
          "dispatch_reply_burst" => @dispatch_reply_burst,
          "stage_burst" => @stage_burst,
          "stage_max_reason_length" => RunnerStage.max_reason_length(),
          "story" => RunnerStory.limits()
        },
        # The transition table a `stage` message is checked against, published so a runner
        # can refuse an impossible transition locally instead of learning it from a refusal.
        # Derived from `Loopctl.Delivery.StageMachine`, which is what the server enforces.
        "stage_transitions" =>
          Enum.map(StageMachine.runner_transitions(), fn {from, to, edge} ->
            %{"from" => to_string(from), "to" => to_string(to), "edge" => to_string(edge)}
          end)
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
