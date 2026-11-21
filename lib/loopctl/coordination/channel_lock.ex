defmodule Loopctl.Coordination.ChannelLock do
  @moduledoc """
  Schema for the `channel_locks` table: one ADVISORY file soft-lock (US-40.4, moved
  out of `channel_posts` by US-52.21).

  A soft-lock is a coordination HINT ("I'm editing lib/foo.ex"), not a message. It
  never blocks anybody, grants no exclusivity, and two sessions may hold one on the
  same file at once. It is NOT the exactly-once handoff claim (`channel_claims`).

  ## Slot

  One row per `(tenant_id, project_id, agent_id, session_id, target)`, held by the
  unique index `channel_locks_slot_uidx`: the same session re-locking the same target
  upserts that row in place, while another session or agent gets its own row. The
  `target` is path-normalized by `Loopctl.Coordination.lock_file/5` before it gets
  here, so `./lib/foo.ex` and `lib//foo.ex` address one slot.

  ## Trust boundary

  `tenant_id`, `project_id`, `agent_id` and `expires_at` are set programmatically on
  the struct by `Loopctl.Coordination`, never cast. `agent_id` is the verified key
  identity. `session_id` and `host` are client-supplied and spoofable, never used for
  authorization. `expires_at` is `now + Coordination.lock_ttl_seconds/1`, clamped to
  at most 3600 s, so a lock never outlives the session that took it.

  ## Wire shape

  The lock endpoints answer with the same fields they did while a lock was a
  `channel_posts` row: `key/1` (`"claim:" <> target`), `refs/1` (one file ref) and
  `body/1` (the note, or a default one-liner) derive those from this row.

  ## Isolation

  `AdminRepo` (BYPASSRLS) plus an explicit `tenant_id` filter in every
  `Loopctl.Coordination` query; RLS is ENABLED on the table as defense in depth.
  """

  use Loopctl.Schema

  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Security.SecretDenylist

  @type t :: %__MODULE__{}

  # The wire key prefix the lock endpoints have always answered with.
  @key_prefix "claim:"

  # A target keeps the derived wire key within the 200 bytes a channel_posts key
  # allowed, so the response shape is unchanged.
  @target_max_length 200 - byte_size(@key_prefix)

  # Per-field bounds, the same as ChannelPost's (the note took the post body's place).
  @note_max_length ChannelPost.body_max_length()
  @session_id_max_length 200
  @host_max_length 255

  # The message `ChannelPost.emit_secret_blocked_events/1` keys on, so a credential in
  # a lock raises the same `[:loopctl, :coordination, :secret_blocked]` signal.
  @secret_error_message "must not contain a secret or credential"

  @scanned_text_fields [:target, :note, :session_id, :host]

  schema "channel_locks" do
    tenant_field()
    field :project_id, :binary_id
    field :agent_id, :binary_id
    field :session_id, :string
    field :host, :string
    field :target, :string
    field :note, :string
    field :expires_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Changeset for taking (or refreshing) a lock. Casts only `target`, `note`,
  `session_id` and `host`; the server-stamped fields must already be on the struct.

  Bounds every text field, rejects a NUL byte in any of them (Postgres cannot store
  one), and runs `SecretDenylist.contains_secret?/1` over each, so a credential in a
  note, session id, host or target is a 422 rather than a row every peer reads.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(lock, attrs) do
    lock
    |> cast(attrs, [:target, :note, :session_id, :host])
    |> trim_note()
    |> blank_to_nil([:note, :host])
    |> validate_required([
      :tenant_id,
      :project_id,
      :agent_id,
      :session_id,
      :target,
      :expires_at
    ])
    |> validate_length(:target, max: @target_max_length, count: :bytes)
    |> validate_length(:note, max: @note_max_length, count: :bytes)
    |> validate_length(:session_id, max: @session_id_max_length, count: :bytes)
    |> validate_length(:host, max: @host_max_length, count: :bytes)
    |> scan_text_fields()
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:agent_id)
  end

  @doc "The wire key a lock answers with: `\"#{@key_prefix}\" <> target`."
  @spec key(t()) :: String.t()
  def key(%__MODULE__{target: target}), do: @key_prefix <> target

  @doc "The wire `refs` a lock answers with: one file ref naming its target."
  @spec refs(t()) :: [map()]
  def refs(%__MODULE__{target: target}), do: [%{"type" => "file", "value" => target}]

  @doc """
  The lock's text: its note, or a terse self-describing default. It is read by peer
  sessions as untrusted data, so the default says what the lock IS rather than
  issuing an instruction.
  """
  @spec body(t()) :: String.t()
  def body(%__MODULE__{note: note}) when is_binary(note) and note != "", do: note

  def body(%__MODULE__{target: target}),
    do: "advisory soft-lock: editing #{target} (advisory only — it does not block you)"

  @doc "Maximum target length in bytes."
  @spec target_max_length() :: pos_integer()
  def target_max_length, do: @target_max_length

  # The note is stored trimmed, as the lock body was before US-52.21.
  defp trim_note(changeset) do
    case get_change(changeset, :note) do
      note when is_binary(note) -> put_change(changeset, :note, String.trim(note))
      _ -> changeset
    end
  end

  defp blank_to_nil(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      if blank?(get_change(acc, field)), do: put_change(acc, field, nil), else: acc
    end)
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  # Scan a bounded prefix of each field: an oversized field is rejected on length
  # anyway, so the scanners never walk more than the largest legal value.
  defp scan_text_fields(changeset) do
    Enum.reduce(@scanned_text_fields, changeset, fn field, acc ->
      value = acc |> get_field(field) |> scan_slice()

      cond do
        not is_binary(value) -> acc
        String.contains?(value, <<0>>) -> add_error(acc, field, "must not contain NUL bytes")
        SecretDenylist.contains_secret?(value) -> add_error(acc, field, @secret_error_message)
        true -> acc
      end
    end)
  end

  defp scan_slice(value) when is_binary(value) and byte_size(value) > @note_max_length,
    do: binary_part(value, 0, @note_max_length)

  defp scan_slice(value), do: value
end
