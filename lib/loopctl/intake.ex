defmodule Loopctl.Intake do
  @moduledoc """
  GitHub webhook intake for the agent delivery loop (issues #803 and #804).

  ## Sources

  An intake source binds one GitHub repository to one work project under a webhook secret
  (`create_source/3`, `list_sources/2`, `revoke_source/3`). The secret is generated here,
  encrypted at rest, and returned once.

  ## Deliveries

  `receive_github_delivery/2` is the whole of the public webhook, in order:

  1. **Authenticate.** Load the ACTIVE source named by the URL (its tenant active too) and
     verify `X-Hub-Signature-256` over the RAW body in constant time. An unknown id, a
     revoked source, a suspended tenant, a missing or wrong signature all return the same
     `{:error, :unauthorized}`, and an unknown id still computes an HMAC, so neither the
     answer nor its timing says which.
  2. **Decode** the JSON from those same raw bytes.
  3. **Bind the repository.** `repository.full_name` must equal the source's repository,
     case-insensitively, or the answer is the same `:unauthorized`: a valid signature for
     the wrong repository is a misrouted or replayed delivery, not a partial success.
  4. **Record the delivery**, keyed by `X-GitHub-Delivery` under a unique index. A replay
     inserts nothing and changes nothing.
  5. **Apply the event.** `ping` is logged. `issues` with `opened`, `edited`, `reopened`,
     `closed`, `labeled` or `unlabeled` updates the issue's intake record. Everything else is
     logged as `ignored`.

  Steps 4 and 5 share one transaction, so a delivery is never marked seen without its
  effect.

  ## The record is the queue entry, and its text is untrusted

  An intake record holds reporter text ONLY in `untrusted_*` fields (`Loopctl.Intake.Record`).
  Nothing here creates a story. `Loopctl.Delivery.InjectionDetector` and
  `Loopctl.Intake.TicketFacts` run over the uncapped text of every applied delivery; any
  reason escalates the record, is never cleared by a later delivery, and appends an
  `intake_escalated` entry to the audit chain naming the signals — never the text.

  Out-of-order deliveries: the stored content, `last_action` and `last_delivery_id` are
  replaced only by a delivery whose `issue.updated_at` is not older than the stored one, so
  the record always describes one coherent delivery. A stale delivery's signals are still
  scanned, since they arrived signed.

  ## Isolation

  `AdminRepo` with an explicit `tenant_id` predicate on every query, as `Loopctl.Runners`
  does. The delivery lookup by source id is the one read without a tenant, because the
  tenant is what it resolves.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.Delivery.InjectionDetector
  alias Loopctl.Intake.Delivery
  alias Loopctl.Intake.GithubPayload
  alias Loopctl.Intake.Record
  alias Loopctl.Intake.Signature
  alias Loopctl.Intake.Source
  alias Loopctl.Intake.TicketFacts
  alias Loopctl.Projects.Project
  alias Loopctl.Tenants.Tenant

  # The largest webhook body the intake route reads. An `issues` payload with a maximal
  # 65,536-character body, escaped, plus its repository and user objects, stays well under
  # it. `LoopctlWeb.Plugs.IntakeRawBody` enforces it and the OpenAPI spec states it.
  @max_body_bytes 1_048_576

  @issue_actions ~w(opened edited reopened closed labeled unlabeled)

  @delivery_id_format ~r/\A[A-Za-z0-9-]{1,128}\z/
  @event_format ~r/\A[a-z_]{1,64}\z/

  # Used only to spend an HMAC's worth of work on an unknown source id.
  @timing_key :crypto.hash(:sha256, "loopctl-intake-unknown-source")

  @type delivery_input :: %{
          raw_body: binary(),
          signature: String.t() | nil,
          event: String.t() | nil,
          delivery_id: String.t() | nil,
          content_type: String.t() | nil
        }

  @type outcome :: :ping | :recorded | :ignored | :duplicate

  @doc "The largest webhook body, in bytes, the intake route reads."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc "The `issues` actions that update an intake record."
  @spec issue_actions() :: [String.t()]
  def issue_actions, do: @issue_actions

  # ---------------------------------------------------------------------------
  # Sources
  # ---------------------------------------------------------------------------

  @doc """
  Creates an intake source binding `repo_full_name` to the tenant's ACTIVE WORK project
  `project_id`, and records it on the audit chain.

  Returns `{:ok, %{source: source, webhook_secret: secret}}`. The secret is returned once.

  ## Options

  - `:actor_lineage` — the creating caller's dispatch lineage, for the audit entry.
  """
  @spec create_source(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, %{source: Source.t(), webhook_secret: String.t()}}
          | {:error, Ecto.Changeset.t() | term()}
  def create_source(tenant_id, attrs, opts \\ []) when is_binary(tenant_id) do
    secret = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    project_id = Map.get(attrs, :project_id) || Map.get(attrs, "project_id")
    repo = Map.get(attrs, :repo_full_name) || Map.get(attrs, "repo_full_name")

    changeset =
      %Source{tenant_id: tenant_id, webhook_secret: secret}
      |> Source.create_changeset(%{repo_full_name: repo})
      |> put_project(tenant_id, project_id)

    with {:ok, changeset} <- valid(changeset),
         {:ok, source} <- insert_source(tenant_id, changeset, opts) do
      {:ok, %{source: source, webhook_secret: secret}}
    end
  end

  defp put_project(changeset, tenant_id, project_id) do
    case active_work_project(tenant_id, project_id) do
      {:ok, project} ->
        Ecto.Changeset.put_change(changeset, :project_id, project.id)

      {:error, message} ->
        Ecto.Changeset.add_error(changeset, :project_id, message)
    end
  end

  defp active_work_project(tenant_id, project_id) when is_binary(project_id) do
    with {:ok, id} <- Ecto.UUID.cast(project_id),
         %Project{} = project <- AdminRepo.get_by(Project, id: id, tenant_id: tenant_id) do
      if project.kind == :work and project.status == :active,
        do: {:ok, project},
        else: {:error, "must be an active work project"}
    else
      _ -> {:error, "project not found"}
    end
  end

  defp active_work_project(_tenant_id, _project_id), do: {:error, "can't be blank"}

  defp valid(%Ecto.Changeset{valid?: true} = changeset), do: {:ok, changeset}
  defp valid(changeset), do: {:error, changeset}

  defp insert_source(tenant_id, changeset, opts) do
    AdminRepo.transaction(fn ->
      with {:ok, source} <- AdminRepo.insert(changeset),
           {:ok, _entry} <-
             AuditChain.append(tenant_id, %{
               action: "intake_source_created",
               actor_lineage: Keyword.get(opts, :actor_lineage, []),
               entity_type: "intake_source",
               entity_id: source.id,
               payload: %{
                 "repo_full_name" => source.repo_full_name,
                 "project_id" => source.project_id
               }
             }) do
        source
      else
        {:error, reason} -> AdminRepo.rollback(reason)
      end
    end)
  end

  @doc "Lists a tenant's intake sources, newest first. Pass `include_revoked: true` for all."
  @spec list_sources(Ecto.UUID.t(), keyword()) :: [Source.t()]
  def list_sources(tenant_id, opts \\ []) when is_binary(tenant_id) do
    query =
      from s in Source,
        where: s.tenant_id == ^tenant_id,
        order_by: [desc: s.inserted_at]

    query =
      if Keyword.get(opts, :include_revoked, false),
        do: query,
        else: where(query, [s], is_nil(s.revoked_at))

    AdminRepo.all(query)
  end

  @doc "Gets one intake source of a tenant."
  @spec get_source(Ecto.UUID.t(), term()) :: {:ok, Source.t()} | {:error, :not_found}
  def get_source(tenant_id, source_id) when is_binary(tenant_id) do
    with {:ok, id} <- Ecto.UUID.cast(source_id),
         %Source{} = source <- AdminRepo.get_by(Source, id: id, tenant_id: tenant_id) do
      {:ok, source}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Revokes an intake source, after which every delivery to it is refused exactly like a bad
  signature. The row is locked, so concurrent revokes write one `revoked_at` and one
  `intake_source_revoked` audit entry. Idempotent.
  """
  @spec revoke_source(Ecto.UUID.t(), term(), keyword()) ::
          {:ok, Source.t()} | {:error, :not_found | term()}
  def revoke_source(tenant_id, source_id, opts \\ []) when is_binary(tenant_id) do
    with {:ok, id} <- cast_not_found(source_id) do
      AdminRepo.transaction(fn -> revoke_locked(tenant_id, id, opts) end)
    end
  end

  defp revoke_locked(tenant_id, id, opts) do
    case lock_source(tenant_id, id) do
      nil -> AdminRepo.rollback(:not_found)
      %Source{revoked_at: nil} = source -> do_revoke(tenant_id, source, opts)
      %Source{} = source -> source
    end
  end

  defp cast_not_found(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp lock_source(tenant_id, id) do
    AdminRepo.one(
      from s in Source, where: s.id == ^id and s.tenant_id == ^tenant_id, lock: "FOR UPDATE"
    )
  end

  defp do_revoke(tenant_id, source, opts) do
    with {:ok, revoked} <- AdminRepo.update(Source.revoke_changeset(source, DateTime.utc_now())),
         {:ok, _entry} <-
           AuditChain.append(tenant_id, %{
             action: "intake_source_revoked",
             actor_lineage: Keyword.get(opts, :actor_lineage, []),
             entity_type: "intake_source",
             entity_id: revoked.id,
             payload: %{"repo_full_name" => revoked.repo_full_name}
           }) do
      revoked
    else
      {:error, reason} -> AdminRepo.rollback(reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Records
  # ---------------------------------------------------------------------------

  @doc """
  Lists a tenant's intake records, oldest first — the order triage consumes them in.

  ## Options

  - `:status` — only records with this status.
  - `:source_id` — only this source's records.
  - `:limit` — at most this many (default 100, max 500).
  """
  @spec list_records(Ecto.UUID.t(), keyword()) :: [Record.t()]
  def list_records(tenant_id, opts \\ []) when is_binary(tenant_id) do
    limit = opts |> Keyword.get(:limit, 100) |> max(1) |> min(500)

    from(r in Record,
      where: r.tenant_id == ^tenant_id,
      order_by: [asc: r.inserted_at, asc: r.id],
      limit: ^limit
    )
    |> filter_records(opts)
    |> AdminRepo.all()
  end

  defp filter_records(query, opts) do
    Enum.reduce(opts, query, fn
      {:status, status}, q -> where(q, [r], r.status == ^status)
      {:source_id, source_id}, q -> where(q, [r], r.source_id == ^source_id)
      _other, q -> q
    end)
  end

  @doc "Gets one intake record of a tenant."
  @spec get_record(Ecto.UUID.t(), term()) :: {:ok, Record.t()} | {:error, :not_found}
  def get_record(tenant_id, record_id) when is_binary(tenant_id) do
    with {:ok, id} <- Ecto.UUID.cast(record_id),
         %Record{} = record <- AdminRepo.get_by(Record, id: id, tenant_id: tenant_id) do
      {:ok, record}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Lists the deliveries a tenant's source accepted, oldest first."
  @spec list_deliveries(Ecto.UUID.t(), Ecto.UUID.t()) :: [Delivery.t()]
  def list_deliveries(tenant_id, source_id) when is_binary(tenant_id) and is_binary(source_id) do
    AdminRepo.all(
      from d in Delivery,
        where: d.tenant_id == ^tenant_id and d.source_id == ^source_id,
        order_by: [asc: d.inserted_at, asc: d.id]
    )
  end

  # ---------------------------------------------------------------------------
  # Deliveries
  # ---------------------------------------------------------------------------

  @doc """
  Receives one GitHub webhook delivery for the source `source_id`. See the moduledoc for
  the order of checks.

  Returns `{:ok, outcome}` where outcome is `:ping`, `:recorded`, `:ignored` or
  `:duplicate`; `{:error, :unauthorized}` for every authentication and repository-binding
  failure; `{:error, {:bad_request, code}}` for a signed delivery that is malformed.
  """
  @spec receive_github_delivery(term(), delivery_input()) ::
          {:ok, outcome()}
          | {:error, :unauthorized | {:bad_request, String.t()} | term()}
  def receive_github_delivery(source_id, %{raw_body: raw_body} = input)
      when is_binary(raw_body) do
    with {:ok, source} <- authenticate(source_id, raw_body, input[:signature]),
         {:ok, payload} <- decode(raw_body, input[:content_type]),
         :ok <- bind_repository(source, payload),
         {:ok, event, delivery_id} <- delivery_headers(input[:event], input[:delivery_id]),
         {:ok, plan} <- plan(event, payload, source) do
      Logger.metadata(tenant_id: source.tenant_id)
      apply_delivery(source, event, delivery_id, raw_body, plan)
    end
  end

  defp authenticate(source_id, raw_body, signature) do
    case active_source(source_id) do
      %Source{webhook_secret: secret} = source when is_binary(secret) ->
        if Signature.valid?(secret, raw_body, signature),
          do: {:ok, source},
          else: {:error, :unauthorized}

      _ ->
        _ = Signature.valid?(@timing_key, raw_body, signature)
        {:error, :unauthorized}
    end
  end

  defp active_source(source_id) do
    case Ecto.UUID.cast(source_id) do
      {:ok, id} ->
        AdminRepo.one(
          from s in Source,
            join: t in Tenant,
            on: t.id == s.tenant_id,
            where: s.id == ^id and is_nil(s.revoked_at) and t.status == :active
        )

      :error ->
        nil
    end
  end

  defp decode(raw_body, content_type) do
    case GithubPayload.decode(raw_body, content_type) do
      {:ok, payload} -> {:ok, payload}
      {:error, :invalid_payload} -> {:error, {:bad_request, "invalid_payload"}}
    end
  end

  defp bind_repository(%Source{repo_full_name: repo}, payload) do
    case GithubPayload.repository_full_name(payload) do
      name when is_binary(name) ->
        if String.downcase(name) == String.downcase(repo),
          do: :ok,
          else: {:error, :unauthorized}

      nil ->
        {:error, :unauthorized}
    end
  end

  defp delivery_headers(event, delivery_id) when is_binary(event) and is_binary(delivery_id) do
    if Regex.match?(@event_format, event) and Regex.match?(@delivery_id_format, delivery_id),
      do: {:ok, event, delivery_id},
      else: {:error, {:bad_request, "invalid_delivery_headers"}}
  end

  defp delivery_headers(_event, _delivery_id),
    do: {:error, {:bad_request, "invalid_delivery_headers"}}

  defp plan("ping", _payload, _source), do: {:ok, {:ping, nil}}

  defp plan("issues", payload, source) do
    action = GithubPayload.action(payload)

    if action in @issue_actions do
      case GithubPayload.issue(payload, source.repo_full_name) do
        {:ok, issue} -> {:ok, {:issue, action, issue}}
        {:error, :invalid_payload} -> {:error, {:bad_request, "invalid_payload"}}
      end
    else
      {:ok, {:ignored, action}}
    end
  end

  defp plan(_event, payload, _source), do: {:ok, {:ignored, GithubPayload.action(payload)}}

  defp apply_delivery(source, event, delivery_id, raw_body, plan) do
    AdminRepo.transaction(fn ->
      case insert_delivery(source, event, delivery_id, raw_body, plan) do
        :duplicate -> :duplicate
        :inserted -> apply_plan(source, delivery_id, plan)
      end
    end)
  end

  # The unique index decides a replay: `ON CONFLICT DO NOTHING` inserts zero rows for a
  # delivery id this source has already seen, including when two posts race.
  defp insert_delivery(source, event, delivery_id, raw_body, plan) do
    now = DateTime.utc_now()

    {outcome, action, issue_number} =
      case plan do
        {:ping, _} -> {"ping", nil, nil}
        {:issue, action, issue} -> {"recorded", action, issue.number}
        {:ignored, action} -> {"ignored", action, nil}
      end

    row = %{
      id: Ecto.UUID.generate(),
      tenant_id: source.tenant_id,
      source_id: source.id,
      github_delivery_id: delivery_id,
      event: event,
      action: action,
      outcome: outcome,
      issue_number: issue_number,
      payload_sha256: :sha256 |> :crypto.hash(raw_body) |> Base.encode16(case: :lower),
      inserted_at: now,
      updated_at: now
    }

    case AdminRepo.insert_all(Delivery, [row],
           on_conflict: :nothing,
           conflict_target: [:source_id, :github_delivery_id]
         ) do
      {1, _} -> :inserted
      {0, _} -> :duplicate
    end
  end

  defp apply_plan(_source, _delivery_id, {:ping, _}), do: :ping
  defp apply_plan(_source, _delivery_id, {:ignored, _action}), do: :ignored

  defp apply_plan(source, delivery_id, {:issue, action, issue}) do
    record = ensure_record(source, issue.number)
    extraction = TicketFacts.extract(issue.title, issue.body)
    new_reasons = scan(issue, extraction) -- record.escalation_reasons
    now = DateTime.utc_now()

    changes =
      record
      |> content_changes(issue, extraction, action, delivery_id)
      |> Map.merge(escalation_changes(record, new_reasons, now))

    with {:ok, updated} <- AdminRepo.update(Record.apply_changeset(record, changes)),
         :ok <- escalate(updated, new_reasons, delivery_id) do
      :recorded
    else
      {:error, reason} -> AdminRepo.rollback(reason)
    end
  end

  # Insert-or-nothing, then lock: two deliveries for a new issue cannot both create it,
  # and the second waits for the first's changes before it merges its own.
  defp ensure_record(source, number) do
    now = DateTime.utc_now()

    AdminRepo.insert_all(
      Record,
      [
        %{
          id: Ecto.UUID.generate(),
          tenant_id: source.tenant_id,
          source_id: source.id,
          project_id: source.project_id,
          issue_number: number,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :source_id, :issue_number]
    )

    AdminRepo.one!(
      from r in Record,
        where: r.tenant_id == ^source.tenant_id,
        where: r.source_id == ^source.id and r.issue_number == ^number,
        lock: "FOR UPDATE"
    )
  end

  # Everything the detector and the fact extractor read is the UNCAPPED payload text.
  defp scan(issue, extraction) do
    detected =
      InjectionDetector.scan([
        {"untrusted_title", issue.title},
        {"untrusted_body", issue.body},
        {"untrusted_labels", Enum.join(issue.labels, "\n")},
        {"untrusted_author_login", issue.author_login},
        {"page_url", extraction.page_url}
      ]) ++ InjectionDetector.scan_user_agent("user_agent", extraction.user_agent)

    Enum.sort(Enum.uniq(detected ++ extraction.reasons))
  end

  # A stale delivery changes nothing but escalation: its action and id stay out of the record
  # too, or a reordered closed/reopened pair would leave `issue_state` and `last_action`
  # describing different deliveries.
  defp content_changes(record, issue, extraction, action, delivery_id) do
    if stale?(record.issue_updated_at, issue.updated_at) do
      %{}
    else
      issue
      |> GithubPayload.untrusted_fields()
      |> Map.merge(%{last_action: action, last_delivery_id: delivery_id})
      |> Map.merge(extraction.facts)
      |> Map.merge(%{
        github_issue_id: issue.github_issue_id,
        html_url: issue.html_url,
        issue_state: issue.state,
        issue_updated_at: issue.updated_at
      })
    end
  end

  defp stale?(%DateTime{} = stored, %DateTime{} = incoming),
    do: DateTime.compare(incoming, stored) == :lt

  defp stale?(%DateTime{}, nil), do: true
  defp stale?(nil, _incoming), do: false

  defp escalation_changes(_record, [], _now), do: %{}

  defp escalation_changes(record, new_reasons, now) do
    %{
      status: :escalated,
      escalation_reasons: Enum.sort(Enum.uniq(record.escalation_reasons ++ new_reasons)),
      escalated_at: record.escalated_at || now
    }
  end

  defp escalate(_record, [], _delivery_id), do: :ok

  defp escalate(record, new_reasons, delivery_id) do
    Logger.warning(
      "intake: escalated issue ##{record.issue_number} of source #{record.source_id} " <>
        "(record #{record.id}): #{Enum.join(new_reasons, ", ")}"
    )

    case AuditChain.append(record.tenant_id, %{
           action: "intake_escalated",
           actor_lineage: [],
           entity_type: "intake_record",
           entity_id: record.id,
           payload: %{
             "source_id" => record.source_id,
             "issue_number" => record.issue_number,
             "github_delivery_id" => delivery_id,
             "signals" => new_reasons,
             "escalation_reasons" => record.escalation_reasons
           }
         }) do
      {:ok, _entry} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
