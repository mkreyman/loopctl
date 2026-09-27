defmodule Loopctl.Intake.Source do
  @moduledoc """
  Schema for the `intake_sources` table — one GitHub repository bound to one work project
  (issue #803).

  A source is ADDRESSED by its id: GitHub posts to `/api/v1/intake/github/:source_id`, so
  the tenant is resolved from the URL, never from the payload. The payload's
  `repository.full_name` must then equal `repo_full_name` (case-insensitively, as GitHub
  names are) or the delivery is refused.

  `webhook_secret` is the HMAC key GitHub signs deliveries with. It is generated
  server-side, encrypted at rest (`Loopctl.Vault.Binary`, AES-256-GCM), returned once at
  creation and never serialised again.

  ## Trust boundary

  `tenant_id`, `project_id`, `webhook_secret` and `revoked_at` are set programmatically in
  `Loopctl.Intake`, never via `cast/3`. `repo_full_name` is the only cast field.

  ## Isolation

  `AdminRepo` plus an explicit `tenant_id` predicate in every `Loopctl.Intake` query, the
  convention `Loopctl.Runners` follows. The one cross-tenant read is the delivery lookup
  by id, which has no tenant yet and resolves it from the row. RLS is ENABLED on the table
  as defense-in-depth.
  """

  use Loopctl.Schema

  alias Loopctl.GitRef

  @type t :: %__MODULE__{}

  # GitHub owner: alphanumeric or hyphen, starting alphanumeric, at most 39. Repository:
  # letters, digits, '.', '_' or '-', at most 100. Mirrored by `intake_sources_repo_shape`.
  @repo_format ~r/^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}$/

  @derive {Jason.Encoder,
           only: [
             :id,
             :project_id,
             :repo_full_name,
             :base_branch,
             :mode,
             :target_epic_id,
             :revoked_at,
             :inserted_at,
             :updated_at
           ]}

  schema "intake_sources" do
    tenant_field()
    belongs_to :project, Loopctl.Projects.Project

    # WHERE A TRIAGED STORY LANDS (#803 §4). A story requires an epic and this source only
    # knows its project, so without it the worker that turns a reported issue into a story
    # has nowhere to put it. NULLABLE: a source enrolled before the field existed keeps
    # working, and a record from a source that names no epic is ESCALATED to a human rather
    # than landing in one chosen for it. Unset means the question has not been answered,
    # which is not the same as any answer loopctl could invent.
    belongs_to :target_epic, Loopctl.WorkBreakdown.Epic
    field :repo_full_name, :string

    # THE BRANCH A DISPATCH IS CUT FROM, per repository (#803 round 1, finding 7). NOT NULL
    # with a default of "master", which is what every dispatch carried before the column
    # existed; a repository whose default branch is `main` — GitHub's default since 2020 —
    # is repointed through `PATCH /api/v1/intake/sources/:id` rather than by guessing.
    field :base_branch, :string, default: "master"

    # HOW THIS REPOSITORY'S CHANGES REACH ITS BASE (US-45.4). `:pr` is the route every source
    # took before the column existed: the merge gate reads a pull request by number. `:thread`
    # is the change-thread route, where the gate reads the story's latest RECORDED checkpoint
    # and no pull request exists. NOT NULL, default `:pr`, so an existing source is unchanged.
    field :mode, Ecto.Enum, values: [:pr, :thread], default: :pr
    field :webhook_secret, Loopctl.Vault.Binary, redact: true
    field :revoked_at, :utc_datetime_usec

    timestamps()
  end

  @doc "The `owner/name` format a source's repository must have."
  @spec repo_format() :: Regex.t()
  def repo_format, do: @repo_format

  @doc """
  Changeset for creating a source. `tenant_id`, `project_id` and `webhook_secret` must
  already be set on the struct.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = source, attrs) do
    source
    |> cast(attrs, [:repo_full_name])
    # THE BRANCH IS CAST ON ITS OWN, with `empty_values: []`, which is NOT Ecto's default.
    # The default treats `""` as absent, so an empty branch would be dropped from the
    # changeset and the row would take the schema default while the caller believed it had
    # named one — a silent substitution for a request that was plainly wrong. This is the
    # same choice `Loopctl.Intake.update_source/4` makes, for the same reason: a caller that
    # SENT a value gets an answer about the value it sent.
    #
    # A key that is ABSENT is still absent: nothing is cast, so the schema default `master`
    # stands and `validate_required/2` below is satisfied by it. That is what keeps an
    # enrolment that names no branch working exactly as it did before the field was offered.
    |> cast(attrs, [:base_branch], empty_values: [])
    # By PRESENCE, as the branch is: absent keeps the `:pr` default, and a caller that names
    # the field gets its value validated rather than a silent substitution.
    |> cast(attrs, [:mode], empty_values: [])
    |> validate_required([:repo_full_name])
    |> validate_mode()
    |> validate_base_branch()
    |> validate_format(:repo_full_name, @repo_format, message: "must be owner/name")
    |> check_constraint(:repo_full_name, name: :intake_sources_repo_shape)
    |> unique_constraint(:repo_full_name,
      name: :intake_sources_active_repo_uidx,
      message: "an active intake source already binds this repository"
    )
    |> foreign_key_constraint(:project_id)
  end

  @doc """
  Everything `base_branch` must satisfy, in ONE place, for every path that writes it.

  THE SHAPE CHECK IS THE HALF THAT WAS MISSING, and it is a security check rather than a
  nicety (#874 review round 2, finding 1). The column is handed to git: `Loopctl.Delivery`'s
  placement path judges it again in `DispatchPayload.fill/3`, but
  `Loopctl.Delivery.TriageDispatcher` builds its own payload and puts this value in as BOTH
  `branch` and `base_branch`, so a length check alone let `--upload-pack=/bin/sh` enrol at 22
  characters and reach git on a dev machine the first time an issue arrived. The predicate is
  `Loopctl.GitRef.valid_name?/1` — the SAME function that path calls, not a copy of it, so the
  two cannot drift and leave the weaker one facing the caller.

  The benign half is why this belongs at the WRITE and not only at the read: `feature branch`
  or `a..b` would enrol happily and then refuse every `place_dispatch` for that project for
  ever, with no signal at the point the value was written.

  Length is bounded here rather than in `GitRef` because 1..255 is this COLUMN's own fact —
  `varchar(255)` plus `intake_sources_base_branch_shape`.
  """
  @spec validate_base_branch(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_base_branch(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:base_branch])
    |> validate_length(:base_branch, min: 1, max: 255)
    |> validate_change(:base_branch, fn :base_branch, value ->
      if GitRef.valid_name?(value),
        do: [],
        else: [base_branch: {GitRef.refusal_message(), [validation: :git_ref_name]}]
    end)
  end

  @doc """
  Everything `mode` must satisfy, for every path that writes it: present (the column is NOT
  NULL, so there is no cleared state) and one of `pr` or `thread`, which the `Ecto.Enum` cast
  already refuses otherwise. `intake_sources_mode` is the database's copy of the same rule.
  """
  @spec validate_mode(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_mode(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:mode])
    |> check_constraint(:mode, name: :intake_sources_mode)
  end

  @doc "The modes a source may take."
  @spec modes() :: [atom()]
  def modes, do: Ecto.Enum.values(__MODULE__, :mode)

  @doc "Changeset that revokes a source."
  @spec revoke_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  # CLEARS `target_epic_id` as well, and that is load-bearing rather than tidiness. The
  # reference to `epics` refuses a delete while it stands, and revoking is the remedy the
  # refusal NAMES — so if a revoked source kept pointing at its epic, the remedy would be a
  # lie and the epic would be undeletable for ever with no action available short of SQL.
  # (Re-enrolling the repository is allowed, because the active-repo uniqueness is partial on
  # `revoked_at IS NULL`, so those dead references would accumulate invisibly.)
  #
  # Nothing is lost by clearing it: a revoked source produces no more reports, so where its
  # stories would have landed is a question with no remaining subject.
  def revoke_changeset(%__MODULE__{} = source, now),
    do: change(source, revoked_at: now, target_epic_id: nil)
end
