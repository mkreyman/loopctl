defmodule Loopctl.Coordination.ChannelClaim do
  @moduledoc """
  Schema for the `channel_claims` table — the exactly-once handoff-claim surface of
  the Repo Coordination Bus (Epic 40, US-40.B1).

  A claim reserves an out-of-band unit of work (a `ref`, e.g. `"handoff:repo#812"`)
  for exactly ONE agent among several racing on the same repo. It is DISTINCT from
  `Loopctl.Coordination.ChannelPost`: a post's per-session slot uniqueness INCLUDES
  the author (`agent_id`), so two agents claiming the same handoff would create two
  distinct slots and never collide. Exactly-once needs uniqueness EXCLUDING the
  claimant — `(tenant_id, project_id, ref)` — so the first inserter wins and every
  loser hits a UNIQUE violation surfaced as `{:error, :already_claimed}` (HTTP 409).

  ## Concurrency

  Claiming is a pure INSERT against the `channel_claims_ref_uidx` unique index —
  NEVER a read-then-insert. Postgres serializes concurrent inserts on the index:
  exactly one commits, the rest raise a unique violation that `unique_constraint/3`
  converts to a changeset error. This has NO TOCTOU window (unlike SELECT-then-
  INSERT), which is precisely why INSERT-to-claim was chosen over a row-lock/upsert
  claim.

  ## Trust boundary

  `tenant_id`, `project_id`, `claimant_agent_id`, `claimed_at`, and
  `lease_expires_at` are set programmatically on the struct in `Loopctl.Coordination`
  — NEVER via `cast/3` (mirroring `ChannelPost`). `claimant_agent_id` is the verified
  key identity, so a caller can never claim as another agent. `ref`, `claimed_by_session`
  and `claimed_by_host` (and, derived server-side, the lease) are the caller-influenced
  fields.

  ## The session discriminator is ADVISORY (issue #779)

  `claimed_by_session` and `claimed_by_host` are the SAME CLASS as
  `ChannelPost`'s `session_id`/`host` and `to_host`/`to_capability`: optional,
  client-supplied, informational and SPOOFABLE. They exist because
  `claimant_agent_id` cannot tell two sessions apart on a fleet where every session
  authenticates as one agent — so a peer's live claim reads back as the caller's own
  (KB `8d9156ca`), and `release` deletes it (KB `07f5e839`).

  They are read for exactly two things: REPORTING ownership (`already_held`,
  `same_session`), and refusing an ACCIDENTAL cross-session `done`/`release`, which a
  caller may always override with `force`. They are NEVER an authorization boundary —
  a spoofed session id can neither steal a claim nor free one that
  `(tenant, project, claimant_agent_id, ref)` does not already admit the caller to.
  Tenant + project membership + the claimant agent stay the enforced boundary.

  NULL means UNDISCRIMINABLE, not "no session": a pre-#779 row, or a client that sends
  none, falls back to the agent-scoped behaviour rather than being locked out.

  ## Isolation

  Runtime isolation is `AdminRepo` (BYPASSRLS) + an explicit `tenant_id` filter in
  every `Loopctl.Coordination` query (the coordination-module convention). RLS is
  ENABLED on the table as defense-in-depth — a query missing the tenant filter is a
  bug even though RLS would also stop it.
  """

  use Loopctl.Schema

  require Logger

  alias Loopctl.Security.SecretDenylist

  @secret_error_message "must not contain a credential"

  @type t :: %__MODULE__{}

  # A ref names an out-of-band unit of work ("handoff:repo#812"), not a row. Bound
  # its byte length like ChannelPost's other free text fields so it cannot be an
  # index-bloat / amplification vector.
  @ref_max_length 512

  # Advisory session/host discriminator bounds — the SAME caps `ChannelPost` uses for
  # its `session_id`/`host`, because these carry the same values from the same proxy.
  @session_max_length 200
  @host_max_length 255

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :project_id,
             :claimant_agent_id,
             :ref,
             :claimed_at,
             :lease_expires_at,
             :done_at,
             :claimed_by_session,
             :claimed_by_host,
             :inserted_at,
             :updated_at
           ]}

  schema "channel_claims" do
    tenant_field()
    field :project_id, :binary_id
    field :claimant_agent_id, :binary_id
    field :ref, :string
    field :claimed_at, :utc_datetime_usec
    field :lease_expires_at, :utc_datetime_usec
    field :done_at, :utc_datetime_usec

    # Advisory, client-supplied, spoofable — see the moduledoc. Never authorization.
    field :claimed_by_session, :string
    field :claimed_by_host, :string

    timestamps()
  end

  @doc """
  Changeset for creating a claim.

  Casts `:ref` (the caller-supplied anchor) and the two ADVISORY discriminator
  fields `:claimed_by_session` / `:claimed_by_host`; `tenant_id`, `project_id`,
  `claimant_agent_id`, `claimed_at`, and `lease_expires_at` are set programmatically
  on the struct by the context and are validated here for presence only — they are
  never castable (mirrors `ChannelPost.create_changeset/2`'s trust boundary).

  A blank (`""`/whitespace-only) `ref` is normalised to `nil` so `validate_required`
  rejects it (an empty anchor must never occupy the `(tenant, project, ref)` slot).
  Enforces the `ref` byte cap, the discriminator byte caps
  (`claimed_by_session` <= #{@session_max_length} bytes, `claimed_by_host` <=
  #{@host_max_length} bytes), rejects NUL bytes in all three (Postgres cannot store
  one in `text`, so the guard turns a raw 500 into a 422), and runs the shared secret
  denylist over the two discriminator fields — they are echoed to every peer session
  reading `GET /channel/claims`, so a credential stuffed into either must be refused
  rather than published onto the shared bus. Declares the `channel_claims_ref_uidx`
  `unique_constraint` (matching the DB index name) so a concurrent duplicate claim
  surfaces as `{:error, changeset}` — which the context maps to
  `{:error, :already_claimed}` (409) — rather than a raw `Ecto.ConstraintError`
  (500). The `foreign_key_constraint`s turn a missing parent into a 422 too.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(claim, attrs) do
    claim
    |> cast(attrs, [:ref, :claimed_by_session, :claimed_by_host])
    |> normalize_blank([:ref, :claimed_by_session, :claimed_by_host])
    |> validate_required([
      :tenant_id,
      :project_id,
      :claimant_agent_id,
      :ref,
      :claimed_at,
      :lease_expires_at
    ])
    |> validate_length(:ref, max: @ref_max_length, count: :bytes)
    |> validate_length(:claimed_by_session, max: @session_max_length, count: :bytes)
    |> validate_length(:claimed_by_host, max: @host_max_length, count: :bytes)
    |> validate_no_null_bytes()
    |> validate_no_secrets()
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:claimant_agent_id)
    |> unique_constraint(:ref,
      name: :channel_claims_ref_uidx,
      message: "has already been claimed"
    )
  end

  @doc "Maximum allowed `ref` length in bytes."
  @spec ref_max_length() :: pos_integer()
  def ref_max_length, do: @ref_max_length

  @doc "Maximum allowed `claimed_by_session` length in bytes."
  @spec session_max_length() :: pos_integer()
  def session_max_length, do: @session_max_length

  @doc "Maximum allowed `claimed_by_host` length in bytes."
  @spec host_max_length() :: pos_integer()
  def host_max_length, do: @host_max_length

  # A blank/whitespace value means "absent" — normalise to nil. For `ref` that makes
  # `validate_required` reject it rather than reserving the slot with an empty string;
  # for the two discriminators it means UNDISCRIMINABLE rather than a session literally
  # named `""`, which would otherwise match no live session and lock done/release out.
  defp normalize_blank(changeset, fields) do
    Enum.reduce(fields, changeset, &blank_change_to_nil/2)
  end

  defp blank_change_to_nil(field, changeset) do
    case get_change(changeset, field) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: put_change(changeset, field, nil), else: changeset

      _ ->
        changeset
    end
  end

  # Postgres `text` cannot store a NUL byte and raises a raw Postgrex.Error (500) at
  # insert. JSON permits it and Elixir strings accept it, so reject it in the
  # changeset — the caller learns it did not land as a 422.
  defp validate_no_null_bytes(changeset) do
    Enum.reduce([:ref, :claimed_by_session, :claimed_by_host], changeset, &reject_null_bytes/2)
  end

  defp reject_null_bytes(field, changeset) do
    case changeset |> get_field(field) |> scan_slice() do
      value when is_binary(value) ->
        if String.contains?(value, <<0>>),
          do: add_error(changeset, field, "must not contain NUL bytes"),
          else: changeset

      _ ->
        changeset
    end
  end

  # The two discriminators are client-supplied free text that `GET /channel/claims`
  # echoes to every peer session in the tenant, exactly like `ChannelPost`'s
  # `session_id`/`host` — so they get the same write-time credential gate. They are
  # proxy-generated (a session uuid, a hostname), so a denylist hit there is a real
  # credential, never a name that merely looks like one.
  #
  # `ref` is deliberately NOT scanned. The denylist's prefixed shapes need only a word
  # boundary, so an ordinary branch-shaped anchor — `handoff:feature/task-sk-integration_
  # with_stripe_v2` matches the `sk-` pattern — would be refused with NO way to clear it:
  # the ref can then never be claimed, and a pre-existing row whose ref now trips the
  # scan loses the idempotent owner re-claim (`claim/5` applies this changeset BEFORE the
  # collision is resolved), which is the dropped-handoff window that branch exists to
  # close. The exposure it would have covered is already covered where the ref's
  # instructions actually live: `ChannelPost.key` is scanned, so a credential-shaped ref
  # cannot be published with a handoff.
  defp validate_no_secrets(changeset) do
    Enum.reduce([:claimed_by_session, :claimed_by_host], changeset, &reject_secret/2)
  end

  defp reject_secret(field, changeset) do
    if changeset |> get_field(field) |> scan_slice() |> SecretDenylist.contains_secret?() do
      add_error(changeset, field, @secret_error_message)
    else
      changeset
    end
  end

  # Cap the bytes handed to the scanners, mirroring `ChannelPost.scan_slice/1`:
  # `validate_length/3` records an error but does NOT drop the change, so `get_field/2`
  # still returns the full body-sized value and an oversized field would otherwise walk
  # every regex on input the changeset is about to reject anyway. The cap is the LARGEST
  # of the three field caps, so no value that can actually land is ever truncated.
  @scan_byte_cap @ref_max_length

  defp scan_slice(value) when is_binary(value) and byte_size(value) > @scan_byte_cap,
    do: binary_part(value, 0, @scan_byte_cap)

  defp scan_slice(value), do: value

  @doc """
  Emits the SHARED `[:loopctl, :coordination, :secret_blocked]` signal for each field a
  REJECTED changeset flagged as carrying a credential — the same one `ChannelPost` fires,
  so the coordination plane's credential-attempt counter covers the claim path too rather
  than silently under-reporting it.

  Fired by `Loopctl.Coordination.claim/5` where the write is actually rejected, never from
  the (pure) changeset builder, which would re-count on every rebuild or preview.
  """
  @spec emit_secret_blocked_events(Ecto.Changeset.t()) :: :ok
  def emit_secret_blocked_events(%Ecto.Changeset{} = changeset) do
    for {field, {msg, _opts}} <- changeset.errors, msg == @secret_error_message do
      metadata = %{
        tenant_id: get_field(changeset, :tenant_id),
        project_id: get_field(changeset, :project_id),
        agent_id: get_field(changeset, :claimant_agent_id),
        field: field
      }

      :telemetry.execute([:loopctl, :coordination, :secret_blocked], %{count: 1}, metadata)

      Logger.warning(
        "coordination denylist hit: blocked claim #{field} carrying a credential shape " <>
          "(tenant=#{metadata.tenant_id} project=#{metadata.project_id} agent=#{metadata.agent_id})"
      )
    end

    :ok
  end
end
