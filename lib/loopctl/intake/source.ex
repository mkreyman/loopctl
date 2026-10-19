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

  ## Mode `chg` (US-47.2)

  A source in `mode: :chg` has its changes landed by the change protocol rather than by a pull
  request, and `Loopctl.Delivery.MergePrecondition` refuses the PR route for it
  (`409 change_protocol_enrolled`). Such a source carries two more things, BOTH required:

  - `change_events_secret` — the HMAC key chg-server signs its event webhook with. Supplied by
    the operator (chg-server must hold the same value), encrypted at rest like
    `webhook_secret`, `redact: true`, and NEVER serialised: it is absent from the
    `Jason.Encoder` list below, so no response can echo it and no client can round-trip it.
  - `chg_root_dispatch_id` — the parentless, unrevoked, orchestrator-role dispatch of this
    tenant chg-server's key was minted from. A custody input (PRD §6), so `Loopctl.Intake`
    checks it against the `dispatches` row inside the write's transaction; this module only
    validates presence and shape.

  Switching a `chg` source back to `pr` KEEPS both: they are ignored while the mode is `pr`,
  and switching back to `chg` re-checks the root rather than trusting the kept id. A caller
  who wants them gone on a `pr` source sends an explicit `null`, which is a clear rather than
  a silent loss; on a `chg` source the same `null` is a 422.

  ## Trust boundary

  `tenant_id`, `project_id`, `webhook_secret` and `revoked_at` are set programmatically in
  `Loopctl.Intake`, never via `cast/3`. The caller-supplied fields are cast by PRESENCE
  (`empty_values: []`), so an explicit null is a request about the field rather than an
  absent key.

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

  # An HMAC key for chg-server's event webhook (PRD §5). 32 bytes is the entropy the
  # server-generated `webhook_secret` carries (as 64 hex characters); 256 bounds what is
  # encrypted and stored per row.
  @min_change_events_secret_bytes 32
  @max_change_events_secret_bytes 256

  @derive {Jason.Encoder,
           only: [
             :id,
             :project_id,
             :repo_full_name,
             :base_branch,
             :mode,
             :required_checks,
             :chg_root_dispatch_id,
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

    # HOW THIS REPOSITORY'S CHANGES REACH ITS BASE. `:pr`: the merge gate reads a pull request by
    # number. `:chg` (US-47.2): the change protocol lands them, and the merge gate refuses the
    # PR route outright. NOT NULL, default `:pr`; `intake_sources_mode` is the database's copy.
    field :mode, Ecto.Enum, values: [:pr, :chg], default: :pr

    # THE CHECKS STORY VERIFICATION JUDGES A STORY'S COMMIT BY (US-26.4.6): GitHub Actions JOB
    # names, as they appear on the commit (a commit-status context can never satisfy one; see
    # `Loopctl.Delivery.CiEvidence`). A pull request's merge is held to its base branch's
    # protection by GitHub; this list is what loopctl itself reads. It first needs a GitHub
    # credential for the tenant, its own token (`Loopctl.Forge`) or an entry in
    # `VERIFICATION_OPERATOR_TOKEN_TENANTS` (`credential_unavailable` otherwise, whatever this
    # list holds); then a source that names none records
    # `no_required_checks` and reads nothing, which is how it opts in, and a source that names
    # some has its (tenant, repository) credential resolved before any GitHub read
    # (`credential_unavailable` if there is none).
    field :required_checks, {:array, :string}, default: []
    field :webhook_secret, Loopctl.Vault.Binary, redact: true

    # `:chg` only (see the moduledoc). Never in the encoder list: write-only.
    field :change_events_secret, Loopctl.Vault.Binary, redact: true
    field :chg_root_dispatch_id, :binary_id
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
    |> cast(attrs, [:required_checks], empty_values: [])
    |> cast(attrs, [:change_events_secret, :chg_root_dispatch_id], empty_values: [])
    |> validate_required([:repo_full_name])
    |> validate_mode()
    |> validate_required_checks()
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
  Everything `mode` and the `chg` credentials must satisfy, for every path that writes any of
  them: `mode` present (the column is NOT NULL, so there is no cleared state) and `pr` or
  `chg`, which the `Ecto.Enum` cast already refuses otherwise; and, when the RESULTING mode is
  `:chg`, both `change_events_secret` and `chg_root_dispatch_id` present
  (`intake_sources_chg_requires_credentials` is the database's copy). Resulting, not changed: switching back to `chg` with the values a `pr` stint kept is
  accepted here, and `Loopctl.Intake` re-checks the root.

  A secret, when one is written, is #{@min_change_events_secret_bytes} to
  #{@max_change_events_secret_bytes} bytes: it is an HMAC key, and a short one is guessable.
  """
  @spec validate_mode(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_mode(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:mode])
    |> validate_chg_credentials()
    |> validate_change(:change_events_secret, &check_secret/2)
    |> check_constraint(:mode, name: :intake_sources_mode)
    |> check_constraint(:mode,
      name: :intake_sources_chg_requires_credentials,
      message: "chg requires change_events_secret and chg_root_dispatch_id"
    )
    |> foreign_key_constraint(:chg_root_dispatch_id,
      name: :intake_sources_chg_root_dispatch_id_fkey
    )
  end

  defp validate_chg_credentials(changeset) do
    if get_field(changeset, :mode) == :chg,
      do:
        validate_required(changeset, [:change_events_secret, :chg_root_dispatch_id],
          message: "is required when mode is chg"
        ),
      else: changeset
  end

  defp check_secret(:change_events_secret, secret) when is_binary(secret) do
    if byte_size(secret) in @min_change_events_secret_bytes..@max_change_events_secret_bytes,
      do: [],
      else: [change_events_secret: change_events_secret_rule()]
  end

  defp check_secret(:change_events_secret, _not_a_string),
    do: [change_events_secret: change_events_secret_rule()]

  @doc "The fewest bytes a `change_events_secret` may have."
  @spec min_change_events_secret_bytes() :: pos_integer()
  def min_change_events_secret_bytes, do: @min_change_events_secret_bytes

  @doc "The most bytes a `change_events_secret` may have."
  @spec max_change_events_secret_bytes() :: pos_integer()
  def max_change_events_secret_bytes, do: @max_change_events_secret_bytes

  @doc "The rule a `change_events_secret` is held to, as the refusal and the API docs state it."
  @spec change_events_secret_rule() :: String.t()
  def change_events_secret_rule,
    do:
      "must be a string of #{@min_change_events_secret_bytes} to " <>
        "#{@max_change_events_secret_bytes} bytes"

  @doc """
  What `chg_root_dispatch_id` must name, as the `chg_root_invalid` refusal and the API docs
  state it. ONE string for both, so the two cannot describe different rules.
  """
  @spec chg_root_requirement() :: String.t()
  def chg_root_requirement,
    do:
      "chg_root_dispatch_id must name a PARENTLESS, UNREVOKED, ORCHESTRATOR-role dispatch of " <>
        "this tenant: the root chg-server's key was minted from, created by the tenant's " <>
        "operator key with POST /api/v1/dispatches and no parent_dispatch_id. An id that " <>
        "names no such dispatch of this tenant, including another tenant's, is refused the " <>
        "same way."

  # The status a session posts about its OWN work (claude-config#677): the implementer attesting
  # itself, the shape chain of custody refuses, so it can never be a required check.
  @local_gate "local-gate"
  @max_required_checks 20
  @max_check_name_bytes 200

  @doc "The most required checks a source may name."
  @spec max_required_checks() :: pos_integer()
  def max_required_checks, do: @max_required_checks

  @doc "The longest required check name, in bytes."
  @spec max_check_name_bytes() :: pos_integer()
  def max_check_name_bytes, do: @max_check_name_bytes

  @doc "The status context a session's own local gate posts; never requirable."
  @spec local_gate() :: String.t()
  def local_gate, do: @local_gate

  @doc """
  Everything `required_checks` must satisfy, for every path that writes it:

  - a list of at most #{@max_required_checks} distinct, non-blank names of at most
    #{@max_check_name_bytes} bytes each
  - never `#{@local_gate}`: that status is posted by whoever pushed, so it is the implementer
    attesting its own work
  """
  @spec validate_required_checks(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_required_checks(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:required_checks])
    |> validate_length(:required_checks, max: @max_required_checks)
    |> validate_change(:required_checks, fn :required_checks, names -> check_names(names) end)
  end

  defp check_names(names) do
    cond do
      # `{:array, :string}` casts a JSON null element to nil, so the element type is checked
      # here, before anything calls a String function on it (a 500 otherwise).
      not Enum.all?(names, &usable_name?/1) ->
        [
          required_checks:
            "each name must be a string of 1 to #{@max_check_name_bytes} bytes with no " <>
              "surrounding whitespace"
        ]

      @local_gate in names ->
        [
          required_checks:
            {"#{@local_gate} is posted by whoever pushed and can never be a required check",
             [validation: :local_gate_not_requirable]}
        ]

      Enum.uniq(names) != names ->
        [required_checks: "names must be distinct"]

      true ->
        []
    end
  end

  # Surrounding whitespace is refused, not trimmed: a job name never carries it, so `"test "`
  # could never match and every verification would wait out its CI limit on a typo.
  defp usable_name?(name) when is_binary(name),
    do: name != "" and String.trim(name) == name and byte_size(name) <= @max_check_name_bytes

  defp usable_name?(_not_a_string), do: false

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
