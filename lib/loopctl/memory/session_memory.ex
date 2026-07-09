defmodule Loopctl.Memory.SessionMemory do
  @moduledoc """
  Schema for the `session_memories` table — the short-term, append-only working
  memory of an agent session (Epic 28, Agent Memory Part 1).

  A `SessionMemory` row is a single turn/fact appended to a session's log. Rows
  carry an `expires_at` and are pruned by the US-28.2 prune worker; there is NO
  embedding column here (short-term memory is read chronologically, not by
  semantic similarity — see `Loopctl.Memory.Memory` for long-term vector memory).

  ## Scope / security boundary

  Every row is scoped by `tenant_id` (RLS-enforced on the OLTP path) plus a
  required `subject_id` — the API-key identity that owns the memory. `subject_id`
  is resolved SERVER-SIDE from the caller's key (see `Loopctl.Memory.subject_id_for/1`)
  and is NEVER accepted from request params. `tenant_id` and `subject_id` are set
  programmatically on the struct, never via `cast/3`.

  ## Fields

  - `session_id` — opaque session identifier (required)
  - `subject_id` — scope owner = the API-key identity (required)
  - `project_id` — optional FK to projects (null = tenant-wide)
  - `role` — the turn author: `:user`, `:assistant`, `:system`, or `:fact`
  - `content` — the message/fact text (byte-capped)
  - `metadata` — extensible JSONB
  - `expires_at` — prune deadline (required)
  - `inserted_at` — append time (append-only; there is no `updated_at`)
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @roles [:user, :assistant, :system, :fact]

  # Short-term turn content is byte-capped to bound memory/wire footprint. A
  # single conversational turn or fact is far smaller than a curated article
  # (100KB body), so 100_000 bytes is a generous ceiling that still rejects
  # pathological payloads.
  @max_content_bytes 100_000

  # A blank subject_id must never be a usable owner: an identity-less key would
  # scope reads to `subject_id = ""`, so a stored "" owner would be readable by
  # ANY such key (mirrors Article agent_id rationale, #163).
  @max_subject_id_length 200

  schema "session_memories" do
    tenant_field()
    belongs_to :project, Loopctl.Projects.Project

    field :session_id, :string
    field :subject_id, :string
    field :role, Ecto.Enum, values: @roles
    field :content, :string
    field :metadata, :map, default: %{}
    field :expires_at, :utc_datetime_usec

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @cast_fields [:session_id, :role, :content, :metadata, :expires_at]

  @doc """
  Changeset for appending a session memory.

  `tenant_id`, `subject_id`, and `project_id` are set programmatically on the
  struct and must NOT appear in `attrs`. `project_id`'s FK is checked with RLS
  BYPASSED, so casting it from request params would let a caller point at
  ANOTHER tenant's project (a cross-tenant graph edge + INSERT-time existence
  oracle); the US-28.2 write path sets it from the caller's already-authorized
  context, mirroring the sibling `Loopctl.WorkBreakdown.Story` schema. Validates
  required fields and caps `content` byte size.
  """
  @spec create_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(session_memory \\ %__MODULE__{}, attrs) do
    session_memory
    |> cast(attrs, @cast_fields)
    |> normalize_nil(:metadata, %{})
    |> validate_required([:session_id, :subject_id, :tenant_id, :content, :expires_at])
    |> validate_subject_id()
    |> validate_content_byte_size()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:tenant_id)
  end

  @doc "Allowed `role` values."
  @spec roles() :: [atom()]
  def roles, do: @roles

  @doc "Maximum `content` byte size."
  @spec max_content_bytes() :: pos_integer()
  def max_content_bytes, do: @max_content_bytes

  # A caller may pass an explicit `metadata: nil`; `cast/3` records that as a nil
  # CHANGE (the schema default `%{}` differs from nil), but the DB column is
  # `NOT NULL`. Without this, insert would raise a raw Postgrex
  # `not_null_violation` instead of honoring the changeset contract. Normalize a
  # nil back to the column default so the DB default governs.
  defp normalize_nil(changeset, field, default) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, default)
      _ -> changeset
    end
  end

  defp validate_subject_id(changeset) do
    case get_field(changeset, :subject_id) do
      nil ->
        changeset

      subject_id when is_binary(subject_id) ->
        cond do
          String.trim(subject_id) == "" ->
            add_error(changeset, :subject_id, "must not be blank")

          byte_size(subject_id) > @max_subject_id_length ->
            add_error(changeset, :subject_id, "too long (max %{max} bytes)",
              max: @max_subject_id_length
            )

          true ->
            changeset
        end

      _ ->
        add_error(changeset, :subject_id, "must be a string")
    end
  end

  defp validate_content_byte_size(changeset) do
    case get_change(changeset, :content) do
      content when is_binary(content) ->
        if byte_size(content) > @max_content_bytes do
          add_error(changeset, :content, "exceeds maximum size of %{max} bytes (got %{actual})",
            max: @max_content_bytes,
            actual: byte_size(content)
          )
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
