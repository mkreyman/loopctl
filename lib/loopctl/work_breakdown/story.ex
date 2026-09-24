defmodule Loopctl.WorkBreakdown.Story do
  @moduledoc """
  Schema for the `stories` table.

  Stories are the fundamental work unit in loopctl. The two-tier status model
  (agent_status + verified_status) is the core innovation: implementing agents
  set agent_status, while orchestrators independently set verified_status.

  ## Fields

  - `number` -- string (e.g., "2.1", "2.2"), unique within a project
  - `title` -- display name
  - `description` -- freeform text description
  - `acceptance_criteria` -- JSONB array of AC items
  - `estimated_hours` -- decimal for precision (e.g., 0.5 hours)
  - `agent_status` -- enum: pending, contracted, assigned, implementing, reported_done
  - `verified_status` -- enum: unverified, verified, rejected
  - `assigned_agent_id` -- FK to agents table
  - `sort_key` -- integer computed from story number for natural numeric sort
  - `metadata` -- JSONB map for extensibility
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @agent_statuses [:pending, :contracted, :assigned, :implementing, :reported_done]
  @verified_statuses [:unverified, :verified, :rejected]

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :project_id,
             :epic_id,
             :number,
             :title,
             :description,
             :acceptance_criteria,
             :estimated_hours,
             :agent_status,
             :verified_status,
             :assigned_agent_id,
             :reported_by_agent_id,
             :assigned_at,
             :reported_done_at,
             :verified_at,
             :rejected_at,
             :rejection_reason,
             :sort_key,
             :metadata,
             :implementer_dispatch_id,
             :verifier_dispatch_id,
             :verifier_needed,
             :lifecycle_entered_at,
             :intake_record_id,
             :claimed_until,
             :claim_epoch,
             :claim_lease_cap,
             :review_requested_at,
             :inserted_at,
             :updated_at
           ]}

  schema "stories" do
    tenant_field()
    belongs_to :project, Loopctl.Projects.Project
    belongs_to :epic, Loopctl.WorkBreakdown.Epic
    belongs_to :assigned_agent, Loopctl.Agents.Agent
    belongs_to :reported_by_agent, Loopctl.Agents.Agent

    field :number, :string
    field :title, :string
    field :description, :string
    field :acceptance_criteria, {:array, :map}, default: []
    field :estimated_hours, :decimal
    field :agent_status, Ecto.Enum, values: @agent_statuses, default: :pending
    field :verified_status, Ecto.Enum, values: @verified_statuses, default: :unverified
    field :assigned_at, :utc_datetime_usec
    field :reported_done_at, :utc_datetime_usec
    field :verified_at, :utc_datetime_usec
    field :rejected_at, :utc_datetime_usec
    field :rejection_reason, :string
    field :sort_key, :integer, default: 0
    field :metadata, :map, default: %{}

    # US-26.2.2: Dispatch lineage for chain-of-custody enforcement
    field :implementer_dispatch_id, Ecto.UUID
    field :verifier_dispatch_id, Ecto.UUID
    field :verifier_needed, :boolean, default: false

    # The backfill anti-launder marker: set the moment a path that clears the
    # dispatch markers on a WORKED story runs (unclaim, force-unclaim, reject
    # auto-reset), and never cleared. `Progress.guard_backfillable/2` refuses to
    # certify a story that carries it.
    #
    # It is DELIBERATELY absent from both changesets' `cast` lists below. It lived
    # in `metadata` first, and `metadata` is cast + whole-map-replaced by
    # `PATCH /api/v1/stories/:id`, so one ordinary request erased the marker and
    # restored the claim -> force-unclaim -> backfill-to-verified launder. Only
    # `Progress` writes it, via `Ecto.Changeset.change/2` on the struct. Never add
    # it to a `cast` list.
    field :lifecycle_entered_at, :utc_datetime_usec

    # #803 §4 / #805: the intake record this story was created FROM, or nil.
    #
    # PROVENANCE, exactly like `implementer_dispatch_id` above it: set once by
    # `Loopctl.WorkBreakdown.Stories.create_story/3` from an OPTION, never rewritten, and
    # deliberately absent from both `cast` lists below for the same reason
    # `lifecycle_entered_at` is — `metadata` is cast and whole-map-replaced by
    # `PATCH /api/v1/stories/:id`, and a link a caller could move is a link that can be
    # pointed at somebody else's reported issue before the loop closes it.
    #
    # NULLABLE and always will be: most stories are authored rather than reported, and
    # nothing may require one. A story with no link closes no issue and that is not an
    # error.
    #
    # The `stories_intake_record_fkey` composite FK on `(tenant_id, intake_record_id)` is
    # what makes a cross-tenant link impossible; the application check in `create_story/3`
    # is the friendly error in front of it, not the enforcement.
    field :intake_record_id, Ecto.UUID

    # #803: the claim's lease and its fence. `claimed_until` is when the claim may be
    # released by `Loopctl.Workers.ReclaimExpiredClaimsWorker` (NULL = no lease, which
    # the reclaimer ignores — every claim made before the lease existed). `claim_epoch`
    # is bumped by every claim and every release, so a message carrying an older epoch
    # is from a claim that has ended. Same rule as `lifecycle_entered_at`: only
    # `Progress` writes them, never a `cast` list — a PATCH that could set the epoch
    # could re-arm a zombie, and one that could set the lease could pin a claim forever.
    field :claimed_until, :utc_datetime_usec
    field :claim_epoch, :integer, default: 0
    # #879 (US-44.5): the latest instant `claimed_until` may ever reach, for a claim taken
    # FOR A RUNNER DISPATCH (`Progress.claim_story/3`'s `lease_until:`, passed only by
    # `Loopctl.Delivery.Placement`) — and the dispatch's `deadline_at`, which the runner stops
    # the session by. Moved only FORWARD, while the claim is live, when the runner accepts
    # (`Progress.reanchor_dispatch_lease/4`), so it is never earlier than that deadline, and a
    # renewal that moved the lease past it would hold the story for a session that no longer
    # exists. NULL on every other claim.
    # Cleared by every release. Same no-cast rule as the fields above — a PATCH that could
    # clear it could lift the cap — and never a `metadata` key, which PATCH replaces wholesale.
    field :claim_lease_cap, :utc_datetime_usec
    # Set (once) by `Progress.request_review/3`: the implementer handed the work to review,
    # so its lease no longer applies and the reclaimer leaves the story alone. Cleared by
    # every release. Same no-cast rule as the two fields above.
    field :review_requested_at, :utc_datetime_usec

    # Issue #621: the capability minted by the lifecycle transition that returned
    # this struct — the credential the caller needs for its NEXT custody op
    # (only `claim` mints one — a start_cap; no other transition mints at all,
    # see Progress.start_story/3 and Progress.verify_story/4). Virtual and deliberately
    # ABSENT from the @derive Jason.Encoder `only:` list above, so it is never
    # serialized as part of a story; the controller that performed the transition
    # reads it and returns it under a separate top-level `capability` key.
    # nil means no cap was minted (pre-v2 keyless tenant, or a mint failure —
    # see mint_cap/4 in Loopctl.Progress, which logs loudly when a KEYED tenant
    # fails to mint, because that tenant's next call would 403 missing_capability).
    field :minted_capability, :map, virtual: true

    timestamps()
  end

  @doc """
  Changeset for creating a new story.

  The `tenant_id`, `project_id`, and `epic_id` are set programmatically,
  not via cast. The `sort_key` is computed from the story number.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(story \\ %__MODULE__{}, attrs) do
    story
    |> cast(attrs, [
      :number,
      :title,
      :description,
      :acceptance_criteria,
      :estimated_hours,
      :metadata
    ])
    |> validate_required([:number, :title])
    |> validate_length(:title, max: 500)
    |> validate_length(:description, max: 50_000)
    |> validate_number_format()
    |> compute_sort_key()
    |> validate_metadata()
    |> unique_constraint([:tenant_id, :project_id, :number],
      message: "has already been taken for this project"
    )
  end

  @doc """
  Changeset for updating an existing story.

  Excludes agent_status and verified_status from cast -- those are
  managed via dedicated status endpoints.
  Number cannot be changed after creation.
  """
  @spec update_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def update_changeset(story, attrs) do
    story
    |> cast(attrs, [
      :title,
      :description,
      :acceptance_criteria,
      :estimated_hours,
      :metadata
    ])
    |> validate_length(:title, max: 500)
    |> validate_length(:description, max: 50_000)
    |> validate_metadata()
  end

  @doc """
  Returns the list of valid agent statuses.
  """
  @spec agent_statuses() :: [atom()]
  def agent_statuses, do: @agent_statuses

  @doc """
  Returns the list of valid verified statuses.
  """
  @spec verified_statuses() :: [atom()]
  def verified_statuses, do: @verified_statuses

  @doc """
  Computes a sort key from a story number string for natural numeric ordering.

  Examples:
  - "1.1" -> 10010
  - "1.2" -> 10020
  - "1.10" -> 10100
  - "2.1" -> 20010
  - "10.5" -> 100050

  The formula is: major * 10000 + minor * 10
  """
  @spec compute_sort_key_value(String.t()) :: integer()
  def compute_sort_key_value(number) when is_binary(number) do
    case String.split(number, ".") do
      [major_str, minor_str] ->
        major = safe_parse_int(major_str)
        minor = safe_parse_int(minor_str)
        major * 10_000 + minor * 10

      [major_str] ->
        safe_parse_int(major_str) * 10_000

      _ ->
        0
    end
  end

  def compute_sort_key_value(_), do: 0

  # --- Private helpers ---

  defp validate_number_format(changeset) do
    validate_change(changeset, :number, fn :number, value ->
      parts = String.split(value, ".")

      cond do
        length(parts) > 2 ->
          [number: "must be in format 'major.minor' or 'major'"]

        Enum.any?(parts, fn part ->
          case Integer.parse(part) do
            {n, ""} -> n < 0 or n >= 10_000
            _ -> true
          end
        end) ->
          [number: "each part must be a non-negative integer less than 10000"]

        true ->
          []
      end
    end)
  end

  defp compute_sort_key(changeset) do
    case get_change(changeset, :number) do
      nil -> changeset
      number -> put_change(changeset, :sort_key, compute_sort_key_value(number))
    end
  end

  defp validate_metadata(changeset) do
    validate_change(changeset, :metadata, fn :metadata, value ->
      if is_map(value) and not is_struct(value) do
        []
      else
        [metadata: "must be a map"]
      end
    end)
  end

  defp safe_parse_int(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> 0
    end
  end
end
