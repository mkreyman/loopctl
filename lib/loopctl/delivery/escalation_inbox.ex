defmodule Loopctl.Delivery.EscalationInbox do
  @moduledoc """
  The escalation inbox (US-48.11): every story parked at `escalated`, findable by WHY.

  Before this, `story_stage` and `resolve_escalation` were the whole surface, and both take a
  story id. HCB #3922's first implement run committed its fix and was killed at 3600 s mid-push
  (`session_ended:wall_clock_exceeded`); it was found again only because the session that
  placed it still held the id. A parked story nobody holds the id of is a story nobody works.

  ## `reason_class` is derived from the EDGE, never from the reason text

  `story_stages.escalation_reason` is free text, and much of it is SESSION-AUTHORED (the
  `:session_escalated` edge carries whatever the model wrote). Classifying by parsing it would
  let a session choose its own class. What is closed is the EDGE the story entered `escalated`
  over: every `{_from, :escalated, edge}` in `Loopctl.Delivery.StageMachine.transitions/0`,
  recorded by `Loopctl.Delivery.Stages` on the story's `transitioned` stage event. That is
  the vocabulary `reason_class/1` is written over, ONE pure function, and the test binds the
  two: an edge added to the machine with no line in `@reason_classes` fails it rather than
  silently landing in `other`.

  An edge the function does not know — a row written by a future version, a `nil` edge on a
  row whose escalation event is missing — is `:other`, never dropped from the list.

  | edge | class |
  |---|---|
  | `budget_reported` (`session_ended` `wall_clock_exceeded` / `max_turns_exceeded`) | `budget_exhausted` |
  | `attempts_exhausted` (crashes and lost runners up to the retry ceiling), `session_escalated` (the session parked it itself) | `session_failed` |
  | `triage_escalate` | `triage_escalated` |
  | `merge_gate`, `verification_failed`, `review_missing`, `no_independent_verifier_runner` (US-48.18: only the implementer's own agent can take the verification) | `gate_refused` |
  | `operator_released` | `operator_released` |
  | `change_outside_lifecycle`, `reverted_after_verify` | `other` |

  ## What a row says about the run, and where each fact comes from

  The dispatch that parked a story is its newest ledger row (`runner_dispatches`) inserted
  before the escalation event — loopctl's own record, never session text. Its `kind` resolves
  to the agent spec through `Loopctl.Agents.Registry.for_kind/1`. A `budget_exhausted` row
  also carries the run: elapsed seconds from the dispatch's acceptance (`replied_at`) to the
  runner's `session_ended_at`, against the wall clock it was placed under
  (`wall_clock_seconds_max`, else `wall_clock_seconds`), and the branch it was sent on.

  It also carries the turns the session took against the turn budget it was placed under, and
  whether it left work behind — each from the ledger row, never from session text:

  - **`max_turns`** — the budget the dispatch was placed under, which the ledger binds at
    placement like `wall_clock_seconds` (`Loopctl.Runners.DispatchLedger`). `nil` on a row
    written before it recorded one.
  - **`turns_used`** — the runner's own count from its `session_ended` report (contract
    1.27.0), stored with the report. `nil` when the report carried none.
  - **`work_left_behind`** — the same report's word on whether the session's branch had
    commits not on the remote at exit: `true` or `false` as the runner said, and `:unknown`
    when it said nothing (a 1.26.0 runner, or one that could not tell). Never inferred.

  ## Isolation

  `list/2` reads on the RLS `Loopctl.Repo` inside `Repo.with_tenant/2` with an explicit
  `tenant_id` predicate on every table. The digest's fleet-wide read (`digest_tenants/1`) runs
  on `AdminRepo` and returns tenant ids ONLY; each tenant's digest is then built by `list`'s
  tenant-scoped read, so a digest can never carry another tenant's story.

  ## The digest

  `post_digest/2` posts one channel post per project of the tenant that holds
  `budget_exhausted` rows escalated more than an hour before `now`: the count, the story ids
  and `work_left_behind` — never `escalation_reason`, which is untrusted text and would reach
  every peer session's SessionStart preview. Its key is `escalation-digest:<project>:<UTC
  date>`, and the post slot's unique index makes a second run on the same day a no-op
  (`:already_posted`) rather than a second post.

  It posts as a per-tenant SYSTEM agent, `system:escalation-digest`. The `system:` prefix is
  reserved (`Loopctl.Agents.Agent.reserved_name_prefix/0`): no key can register or rename an
  agent into it, so a squatter cannot pre-create the identity the digest is attributed to.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Agents.Agent
  alias Loopctl.Agents.Registry
  alias Loopctl.Coordination
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.KeysetCursor
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.WorkBreakdown.Story

  require Logger

  @cursor_namespace "escalation_cursor"
  @default_limit 50
  @max_limit 100

  # The digest's per-tenant read bound, and how many story ids one post names. The rest are
  # counted, so the count is always the true one.
  @digest_row_limit 500
  @digest_ids_listed 50
  @digest_min_age_seconds 3_600
  @digest_tenant_limit 1_000

  @digest_agent_name "system:escalation-digest"
  @digest_session "loopctl:escalation-digest"

  # THE ONE MAPPING. Keyed by every edge that enters `escalated` in
  # `StageMachine.transitions/0`; the test asserts the key set equals that set exactly.
  @reason_classes %{
    budget_reported: :budget_exhausted,
    attempts_exhausted: :session_failed,
    session_escalated: :session_failed,
    triage_escalate: :triage_escalated,
    merge_gate: :gate_refused,
    verification_failed: :gate_refused,
    review_missing: :gate_refused,
    no_independent_verifier_runner: :gate_refused,
    operator_released: :operator_released,
    change_outside_lifecycle: :other,
    reverted_after_verify: :other
  }

  # The stored form of each edge: `story_stage_events.edge` is a string. Built here so a string
  # is matched against known values and never turned into an atom.
  @by_stored_edge Map.new(@reason_classes, fn {edge, class} -> {Atom.to_string(edge), class} end)

  @classes [
    :budget_exhausted,
    :session_failed,
    :triage_escalated,
    :gate_refused,
    :operator_released,
    :other
  ]

  @type reason_class ::
          :budget_exhausted
          | :session_failed
          | :triage_escalated
          | :gate_refused
          | :operator_released
          | :other

  @type run :: %{
          dispatch_id: Ecto.UUID.t() | nil,
          elapsed_seconds: non_neg_integer() | nil,
          wall_clock_seconds: pos_integer() | nil,
          turns_used: non_neg_integer() | nil,
          max_turns: pos_integer() | nil,
          branch: String.t() | nil,
          session_ended_reason: String.t() | nil,
          work_left_behind: boolean() | :unknown
        }

  @type entry :: %{
          story_id: Ecto.UUID.t(),
          project_id: Ecto.UUID.t(),
          stage_id: Ecto.UUID.t(),
          escalated_at: DateTime.t(),
          edge: String.t() | nil,
          reason_class: reason_class(),
          escalation_reason: String.t() | nil,
          dispatch_id: Ecto.UUID.t() | nil,
          spec: %{id: String.t(), version: pos_integer()} | nil,
          run: run() | nil
        }

  @type page :: %{
          data: [entry()],
          has_more: boolean(),
          next_cursor: KeysetCursor.position() | nil
        }

  @type digest_outcome ::
          {:posted, Ecto.UUID.t()} | :already_posted | {:error, Ecto.UUID.t(), term()}

  # ── classification ─────────────────────────────────────────────────────────────────────────

  @doc """
  The class of an escalation, from the EDGE the story entered `escalated` over — an atom, or
  the string `story_stage_events.edge` stores. Pure. An edge this does not know, and `nil`, is
  `:other`.
  """
  @spec reason_class(atom() | String.t() | nil) :: reason_class()
  def reason_class(edge) when is_atom(edge) and not is_nil(edge),
    do: Map.get(@reason_classes, edge, :other)

  def reason_class(edge) when is_binary(edge), do: Map.get(@by_stored_edge, edge, :other)
  def reason_class(_edge), do: :other

  @doc "The edges `reason_class/1` is written over: its closed input vocabulary."
  @spec reason_vocabulary() :: [atom()]
  def reason_vocabulary, do: @reason_classes |> Map.keys() |> Enum.sort()

  @doc "Every class `reason_class/1` can return."
  @spec reason_classes() :: [reason_class()]
  def reason_classes, do: @classes

  @doc """
  The class named by `value` — an atom or its string — or `:error` for anything else. For the
  API's filter, which must refuse an unknown class rather than read it as `other`.
  """
  @spec parse_reason_class(term()) :: {:ok, reason_class()} | :error
  def parse_reason_class(value) when is_atom(value) and value in @classes, do: {:ok, value}

  def parse_reason_class(value) when is_binary(value) do
    case Enum.find(@classes, &(Atom.to_string(&1) == value)) do
      nil -> :error
      class -> {:ok, class}
    end
  end

  def parse_reason_class(_value), do: :error

  # The stored edges of `class`. `:other` is not one of these: it is "none of the others".
  defp stored_edges(class),
    do: for({edge, ^class} <- @by_stored_edge, do: edge)

  defp classified_edges,
    do: for({edge, class} <- @by_stored_edge, class != :other, do: edge)

  # ── the inbox ──────────────────────────────────────────────────────────────────────────────

  @doc """
  One page of `tenant_id`'s escalated stories, newest escalation first.

  Options:

  - `:reason_class` — one of `reason_classes/0`;
  - `:project_id` — the story's project;
  - `:since` — a `DateTime`; only escalations at or after it;
  - `:escalated_before` — a `DateTime`; only escalations at or before it (the digest's age);
  - `:cursor` — a position `decode_cursor/2` returned;
  - `:limit` — default #{@default_limit}, at most #{@max_limit}.
  """
  @spec list(Ecto.UUID.t(), keyword()) :: {:ok, page()}
  def list(tenant_id, opts \\ []) when is_binary(tenant_id) do
    limit = (Keyword.get(opts, :limit) || @default_limit) |> min(@max_limit) |> max(1)
    {:ok, page} = read(tenant_id, opts, limit)
    {:ok, page}
  end

  @doc "The opaque, tenant-bound string for a `list/2` position."
  @spec encode_cursor(Ecto.UUID.t(), KeysetCursor.position()) :: String.t()
  def encode_cursor(tenant_id, position),
    do: KeysetCursor.encode(@cursor_namespace, tenant_id, position)

  @doc "A `list/2` position from its string, or `{:error, :invalid}` for any other string."
  @spec decode_cursor(Ecto.UUID.t(), String.t()) ::
          {:ok, KeysetCursor.position()} | {:error, :invalid}
  def decode_cursor(tenant_id, cursor),
    do: KeysetCursor.decode(@cursor_namespace, tenant_id, cursor)

  defp read(tenant_id, opts, limit) do
    Repo.with_tenant(tenant_id, fn ->
      rows =
        from(r in subquery(escalated_rows(tenant_id)),
          order_by: [desc: r.escalated_at, desc: r.stage_id],
          limit: ^(limit + 1)
        )
        |> filter(opts)
        |> Repo.all()

      {page, rest} = Enum.split(rows, limit)
      ledgers = ledger_rows(tenant_id, Enum.map(page, & &1.story_id))

      next =
        case {rest, List.last(page)} do
          {[_ | _], %{} = last} -> {last.escalated_at, last.stage_id}
          _ -> nil
        end

      %{
        data: Enum.map(page, &entry(&1, Map.get(ledgers, &1.story_id, []))),
        has_more: rest != [],
        next_cursor: next
      }
    end)
  end

  # Every escalated stage row of the tenant with the edge and time of its LATEST escalation.
  # The lateral read is one indexed lookup per escalated row (`story_stage_events` is indexed
  # on `story_stage_id`), and only escalated rows are visited (`story_stages (tenant_id,
  # stage)`). A row with no escalation event — none is written without one today — keeps
  # `edge: nil` (class `other`) and falls back to the row's own `updated_at`.
  defp escalated_rows(tenant_id) do
    latest =
      from e in StageEvent,
        where: e.story_stage_id == parent_as(:stage).id,
        where: e.tenant_id == parent_as(:stage).tenant_id,
        where: e.event == "transitioned" and e.to_stage == "escalated",
        order_by: [desc: e.inserted_at, desc: e.lock_version],
        limit: 1,
        select: %{edge: e.edge, inserted_at: e.inserted_at}

    from s in StoryStage,
      as: :stage,
      join: st in Story,
      on: st.id == s.story_id and st.tenant_id == s.tenant_id,
      left_lateral_join: e in subquery(latest),
      on: true,
      where: s.tenant_id == ^tenant_id and st.tenant_id == ^tenant_id,
      where: s.stage == :escalated,
      select: %{
        stage_id: s.id,
        story_id: s.story_id,
        project_id: st.project_id,
        branch: s.branch,
        escalation_reason: s.escalation_reason,
        edge: e.edge,
        escalated_at: type(coalesce(e.inserted_at, s.updated_at), :utc_datetime_usec)
      }
  end

  defp filter(query, opts) do
    Enum.reduce(opts, query, fn
      {:reason_class, nil}, q ->
        q

      {:reason_class, :other}, q ->
        where(q, [r], is_nil(r.edge) or r.edge not in ^classified_edges())

      {:reason_class, class}, q ->
        where(q, [r], r.edge in ^stored_edges(class))

      {:project_id, nil}, q ->
        q

      {:project_id, project_id}, q ->
        where(q, [r], r.project_id == ^project_id)

      {:since, nil}, q ->
        q

      {:since, %DateTime{} = since}, q ->
        where(q, [r], r.escalated_at >= ^since)

      {:escalated_before, nil}, q ->
        q

      {:escalated_before, %DateTime{} = at}, q ->
        where(q, [r], r.escalated_at <= ^at)

      {:cursor, nil}, q ->
        q

      {:cursor, {%DateTime{} = at, id}}, q ->
        after_cursor(q, at, id)

      _other, q ->
        q
    end)
  end

  defp after_cursor(query, at, id),
    do:
      where(
        query,
        [r],
        r.escalated_at < ^at or (r.escalated_at == ^at and r.stage_id < type(^id, :binary_id))
      )

  # The page's ledger rows, newest first, in ONE read keyed `(tenant_id, story_id)` — the
  # `runner_dispatches (tenant_id, story_id)` index. Grouped by story.
  defp ledger_rows(_tenant_id, []), do: %{}

  defp ledger_rows(tenant_id, story_ids) do
    from(d in DispatchRecord,
      where: d.tenant_id == ^tenant_id and d.story_id in ^Enum.uniq(story_ids),
      order_by: [desc: d.inserted_at, desc: d.id],
      select:
        map(d, [
          :story_id,
          :dispatch_id,
          :kind,
          :branch,
          :inserted_at,
          :replied_at,
          :wall_clock_seconds,
          :wall_clock_seconds_max,
          :max_turns,
          :session_ended_reason,
          :session_ended_at,
          :session_turns_used,
          :work_left_behind
        ])
    )
    |> Repo.all()
    |> Enum.group_by(& &1.story_id)
  end

  defp entry(row, ledgers) do
    class = reason_class(row.edge)
    # The dispatch that parked it: the newest ledger row written before the escalation.
    parked_by = Enum.find(ledgers, &(DateTime.compare(&1.inserted_at, row.escalated_at) != :gt))

    %{
      story_id: row.story_id,
      project_id: row.project_id,
      stage_id: row.stage_id,
      escalated_at: row.escalated_at,
      edge: row.edge,
      reason_class: class,
      escalation_reason: row.escalation_reason,
      dispatch_id: parked_by && parked_by.dispatch_id,
      spec: spec_of(parked_by),
      run: run(class, parked_by, row)
    }
  end

  defp spec_of(nil), do: nil

  defp spec_of(%{kind: kind}) do
    case Registry.for_kind(kind || Registry.default_kind()) do
      {:ok, spec} -> %{id: spec.id, version: spec.version}
      {:error, :unknown_kind} -> nil
    end
  end

  defp run(:budget_exhausted, %{} = ledger, row) do
    %{
      dispatch_id: ledger.dispatch_id,
      elapsed_seconds: elapsed(ledger.replied_at, ledger.session_ended_at),
      wall_clock_seconds: ledger.wall_clock_seconds_max || ledger.wall_clock_seconds,
      turns_used: ledger.session_turns_used,
      max_turns: ledger.max_turns,
      branch: ledger.branch || row.branch,
      session_ended_reason: ledger.session_ended_reason,
      work_left_behind: left_behind(ledger.work_left_behind)
    }
  end

  # A budget kill whose ledger row is gone (or was never written) still says it was one: the
  # facts only the ledger holds are null, and what is left behind is unknown.
  defp run(:budget_exhausted, nil, row) do
    %{
      dispatch_id: nil,
      elapsed_seconds: nil,
      wall_clock_seconds: nil,
      turns_used: nil,
      max_turns: nil,
      branch: row.branch,
      session_ended_reason: nil,
      work_left_behind: :unknown
    }
  end

  defp run(_class, _ledger, _row), do: nil

  # The runner's boolean as it reported it; NULL — it said nothing — is `:unknown`, never false.
  defp left_behind(value) when is_boolean(value), do: value
  defp left_behind(nil), do: :unknown

  defp elapsed(%DateTime{} = started, %DateTime{} = ended),
    do: max(DateTime.diff(ended, started, :second), 0)

  defp elapsed(_started, _ended), do: nil

  # ── the digest ─────────────────────────────────────────────────────────────────────────────

  @doc """
  EVERY tenant holding at least one escalated story, for the digest's fan-out: a lazy stream
  of `digest_tenants/1` pages of `page_size`, so no tenant past a page bound is skipped.
  """
  @spec all_digest_tenants(pos_integer()) :: Enumerable.t()
  def all_digest_tenants(page_size \\ @digest_tenant_limit)
      when is_integer(page_size) and page_size > 0 do
    Stream.unfold({:after, nil}, fn
      :done ->
        nil

      {:after, after_id} ->
        case digest_tenants(limit: page_size, after: after_id) do
          [] -> nil
          page when length(page) < page_size -> {page, :done}
          page -> {page, {:after, List.last(page)}}
        end
    end)
    |> Stream.concat()
  end

  @doc """
  One page of the tenants holding at least one escalated story, in tenant-id order. A
  fleet-wide read on `AdminRepo` that returns tenant ids and nothing else.

  Options: `:limit` (default #{@digest_tenant_limit}) and `:after`, a tenant id the page
  starts past.
  """
  @spec digest_tenants(keyword()) :: [Ecto.UUID.t()]
  def digest_tenants(opts \\ []) do
    limit = Keyword.get(opts, :limit, @digest_tenant_limit)

    query =
      from s in StoryStage,
        where: s.stage == :escalated,
        distinct: true,
        order_by: [asc: s.tenant_id],
        limit: ^limit,
        select: s.tenant_id

    query =
      case Keyword.get(opts, :after) do
        nil -> query
        after_id -> where(query, [s], s.tenant_id > type(^after_id, :binary_id))
      end

    AdminRepo.all(query)
  end

  @doc """
  Posts `tenant_id`'s escalation digest as of `now`: one post on each project's coordination
  channel that holds `budget_exhausted` rows escalated more than an hour before `now`. Posts
  nothing for a project with none.

  Idempotent per project per UTC day of `now`: the post's `key` carries both, and a second run
  that day answers `:already_posted` for that project. Returns one outcome per project posted
  to or attempted, in no particular order.
  """
  @spec post_digest(Ecto.UUID.t(), DateTime.t()) :: [digest_outcome()]
  def post_digest(tenant_id, %DateTime{} = now) when is_binary(tenant_id) do
    cutoff = DateTime.add(now, -@digest_min_age_seconds, :second)

    {:ok, %{data: rows}} =
      read(
        tenant_id,
        [reason_class: :budget_exhausted, escalated_before: cutoff],
        @digest_row_limit
      )

    case Enum.group_by(rows, & &1.project_id) do
      grouped when map_size(grouped) == 0 -> []
      grouped -> post_grouped(tenant_id, grouped, now)
    end
  end

  # The system agent is resolved only once something qualifies, so a quiet tenant gains no row.
  defp post_grouped(tenant_id, grouped, now) do
    case digest_agent(tenant_id) do
      {:ok, agent_id} ->
        for {project_id, project_rows} <- grouped,
            do: post_project(tenant_id, project_id, agent_id, project_rows, now)

      {:error, reason} ->
        for {project_id, _rows} <- grouped, do: {:error, project_id, reason}
    end
  end

  @doc "The post key a project's digest for `now`'s UTC day carries."
  @spec digest_key(Ecto.UUID.t(), DateTime.t()) :: String.t()
  def digest_key(project_id, %DateTime{} = now),
    do: "escalation-digest:#{project_id}:#{Date.to_iso8601(DateTime.to_date(now))}"

  @doc "The reserved name of the per-tenant agent a digest is posted as."
  @spec digest_agent_name() :: String.t()
  def digest_agent_name, do: @digest_agent_name

  @doc "The digest body for `rows` of one project on `now`'s UTC day. Never names a reason."
  @spec digest_body([entry()], DateTime.t()) :: String.t()
  def digest_body(rows, %DateTime{} = now) do
    count = length(rows)
    {listed, unlisted} = Enum.split(rows, @digest_ids_listed)

    lines =
      Enum.map(listed, fn row ->
        "- #{row.story_id} work_left_behind=#{work_left_behind(row)}"
      end)

    more = if unlisted == [], do: [], else: ["- and #{length(unlisted)} more"]

    Enum.join(
      [
        "Escalation digest #{Date.to_iso8601(DateTime.to_date(now))} (UTC): #{count} " <>
          "#{if count == 1, do: "story is", else: "stories are"} parked at escalated in this " <>
          "project because the implement session ran out of budget (wall clock or turns) " <>
          "more than an hour ago."
      ] ++
        lines ++
        more ++
        [
          "List them with escalation_list (reason_class: budget_exhausted). Work one again " <>
            "with resolve_escalation to: queued, on a user key."
        ],
      "\n"
    )
  end

  defp work_left_behind(%{run: %{work_left_behind: value}}), do: value
  defp work_left_behind(_row), do: :unknown

  defp post_project(tenant_id, project_id, agent_id, rows, now) do
    attrs = %{
      body: digest_body(rows, now),
      key: digest_key(project_id, now),
      session_id: @digest_session
    }

    case Coordination.create_post(tenant_id, project_id, agent_id, attrs) do
      {:ok, post} ->
        {:posted, post.id}

      {:error, %Ecto.Changeset{} = changeset} ->
        if slot_taken?(changeset),
          do: :already_posted,
          else: {:error, project_id, changeset_errors(changeset)}

      {:error, :unprocessable_entity, message} ->
        {:error, project_id, message}

      {:error, reason} ->
        {:error, project_id, reason}
    end
  end

  defp slot_taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {field, {_message, meta}} ->
      field == :key and Keyword.get(meta, :constraint) == :unique
    end)
  end

  defp changeset_errors(%Ecto.Changeset{errors: errors}), do: Keyword.keys(errors)

  # The per-tenant system agent the digest is attributed to. Its name is in the reserved
  # `system:` prefix, which no key can register or rename into, so whichever row carries it was
  # written here. `ON CONFLICT DO NOTHING` and then a read keep two concurrent first runs from
  # failing each other.
  defp digest_agent(tenant_id) do
    now = DateTime.utc_now()

    AdminRepo.insert_all(
      Agent,
      [
        %{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          name: @digest_agent_name,
          agent_type: :orchestrator,
          status: :active,
          last_seen_at: now,
          metadata: %{},
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :name]
    )

    case AdminRepo.one(
           from a in Agent,
             where: a.tenant_id == ^tenant_id and a.name == ^@digest_agent_name,
             select: a.id
         ) do
      nil -> {:error, :digest_agent_not_resolved}
      id -> {:ok, id}
    end
  end
end
