defmodule Loopctl.Coordination.ChannelPost do
  @moduledoc """
  Schema for the `channel_posts` table — the coordination bus (the third memory
  plane: Knowledge = durable, Memory = agent-private, Channel = repo-scoped and
  transient).

  A post is one attributed, short-lived message on a project's coordination
  channel. A **channel is a `project_id`**; sessions on the same repo — across
  machines — read the channel to see what other sessions found, did, or are
  doing. Retention is a uniform 30 days (`expires_at`); there is deliberately
  **no message-type taxonomy** (`:kind`/`:category`/`:type`) — the fleet audit
  showed the category taxonomy was essentially unused. An optional `key` reserves
  a per-session working-state slot: in US-39.1 a second write to the same
  `(tenant, project, session, key)` is **rejected** by the partial unique index
  (`{:error, changeset}`), not merged; the `on_conflict` upsert that lets a
  session refresh its own slot lands in US-39.2.

  ## Trust boundary

  `tenant_id`, `project_id`, `agent_id`, and `expires_at` are set programmatically
  on the struct in `Loopctl.Coordination` — NEVER via `cast/3`. `agent_id` is the
  verified key identity (a caller can never post as another agent); `host` and
  `session_id` are client-supplied, informational, and spoofable — never used for
  authorization or as authoritative attribution.

  ## Isolation

  Runtime isolation is `AdminRepo` (BYPASSRLS) + an explicit `tenant_id` filter in
  every `Loopctl.Coordination` query (the Knowledge/Projects pattern). RLS is
  ENABLED on the table as defense-in-depth — a query missing the tenant filter is
  a bug even though RLS would also stop it.
  """

  use Loopctl.Schema

  require Logger

  alias Loopctl.Security.SecretDenylist

  @type t :: %__MODULE__{}

  @body_max_length 16_384
  @key_max_length 200
  @session_id_max_length 200
  @host_max_length 255
  @ref_value_max_length 512
  @refs_serialized_max_bytes 4_096
  @allowed_ref_keys ~w(file pr branch commit)

  # Text fields that must never carry a NUL byte (Postgres rejects them at insert
  # time with a raw Postgrex.Error/500) nor a denylisted credential shape.
  @scanned_text_fields [:body, :key, :session_id, :host]

  @derive {Jason.Encoder,
           only: [
             :id,
             :tenant_id,
             :project_id,
             :agent_id,
             :session_id,
             :host,
             :key,
             :body,
             :refs,
             :expires_at,
             :inserted_at,
             :updated_at
           ]}

  schema "channel_posts" do
    tenant_field()
    field :project_id, :binary_id
    field :agent_id, :binary_id
    field :session_id, :string
    field :host, :string
    field :key, :string
    field :body, :string
    field :refs, :map

    field :expires_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Changeset for creating a channel post.

  Casts ONLY the caller-supplied fields `[:session_id, :host, :key, :body, :refs]`.
  `tenant_id`, `project_id`, `agent_id`, and `expires_at` are set programmatically
  on the struct by the context and are validated for presence here as a guard
  against a context bug — they are never castable.

  Enforces the size/shape bounds (`body` <= 16KB, `key` <= 200 bytes,
  `session_id` <= 200 bytes, `host` <= 255 bytes, constrained `refs`), rejects
  NUL bytes in every text field (Postgres cannot store them — the guard turns a
  raw 500 into a 422), and runs the shared secret denylist over `body`, `key`,
  `session_id`, `host`, and every `refs` value — a match rejects the write
  (surfaced as a 422) rather than silently dropping the content or leaking a
  credential onto the shared, cross-session-readable channel.

  A blank (`""`/whitespace) `key` is normalised to `nil` so it means "no keyed
  slot" rather than occupying the `(tenant, project, session, key)` slot with an
  empty string. A keyed post is a per-session working-state slot, so `session_id`
  is required whenever `key` is present — without it the partial unique index
  (which treats a NULL `session_id` as distinct) can never dedupe the slot. The
  DB constraints (the session-key partial unique index and the
  tenant/project/agent foreign keys) are declared here so a collision or missing
  parent surfaces as `{:error, changeset}` (422) rather than an unhandled
  `Ecto.ConstraintError` (500).
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(post, attrs) do
    post
    |> cast(attrs, [:session_id, :host, :key, :body, :refs])
    |> normalize_blank([:key, :session_id, :host])
    |> validate_required([:tenant_id, :project_id, :agent_id, :body, :expires_at])
    |> validate_length(:body, max: @body_max_length, count: :bytes)
    |> validate_length(:key, max: @key_max_length, count: :bytes)
    |> validate_length(:session_id, max: @session_id_max_length, count: :bytes)
    |> validate_length(:host, max: @host_max_length, count: :bytes)
    |> validate_no_null_bytes()
    |> maybe_require_session_for_key()
    |> validate_refs()
    |> validate_no_secrets()
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint(:key,
      name: :channel_posts_session_key_uidx,
      message: "has already been used by this session (working-state slot)"
    )
  end

  @doc "Maximum allowed `body` length in bytes."
  @spec body_max_length() :: pos_integer()
  def body_max_length, do: @body_max_length

  @doc "Allowed keys for the `refs` map."
  @spec allowed_ref_keys() :: [String.t()]
  def allowed_ref_keys, do: @allowed_ref_keys

  # JSON clients routinely send `""` for an absent field, and in Elixir `""` is
  # truthy — so a blank `key` would force `session_id` to be required AND occupy a
  # real `(tenant, project, session, key)` slot (the partial index keys on
  # `key IS NOT NULL`), colliding on the next blank-key post. Normalise blank text
  # to `nil` so `""` means "no value", not a real slot / spoofable field.
  defp normalize_blank(changeset, fields) do
    Enum.reduce(fields, changeset, &blank_change_to_nil/2)
  end

  defp blank_change_to_nil(field, changeset) do
    case get_change(changeset, field) do
      value when is_binary(value) and value != "" ->
        if String.trim(value) == "", do: put_change(changeset, field, nil), else: changeset

      "" ->
        put_change(changeset, field, nil)

      _ ->
        changeset
    end
  end

  # Postgres `text`/`varchar` columns cannot store a NUL byte and raise a raw
  # Postgrex.Error (500) at insert time. JSON permits a NUL byte and Elixir strings
  # accept it, so reject it in the changeset — the caller learns it did not land
  # as a 422, honouring the create_post error contract.
  defp validate_no_null_bytes(changeset) do
    Enum.reduce(@scanned_text_fields, changeset, &reject_null_bytes/2)
  end

  defp reject_null_bytes(field, changeset) do
    value = get_field(changeset, field)

    if is_binary(value) and String.contains?(value, <<0>>) do
      add_error(changeset, field, "must not contain NUL bytes")
    else
      changeset
    end
  end

  # A keyed post occupies a per-(tenant, project, session) working-state slot. The
  # partial unique index includes session_id, and Postgres treats a NULL session_id
  # as distinct — so without a session_id a keyed post can never upsert/dedupe and
  # would accumulate unbounded duplicate rows. Require session_id whenever key is set.
  defp maybe_require_session_for_key(changeset) do
    if get_field(changeset, :key) do
      validate_required(changeset, :session_id)
    else
      changeset
    end
  end

  defp validate_refs(changeset) do
    validate_change(changeset, :refs, fn :refs, refs ->
      cond do
        not (is_map(refs) and not is_struct(refs)) ->
          [refs: "must be a map"]

        not (Map.keys(refs) |> Enum.map(&to_string/1) |> Enum.all?(&(&1 in @allowed_ref_keys))) ->
          [refs: "may only contain keys #{Enum.join(@allowed_ref_keys, ", ")}"]

        not Enum.all?(Map.values(refs), &valid_ref_value?/1) ->
          [refs: "values must be strings of at most #{@ref_value_max_length} characters"]

        refs_serialized_size(refs) > @refs_serialized_max_bytes ->
          [refs: "serialized size exceeds #{@refs_serialized_max_bytes} bytes"]

        true ->
          []
      end
    end)
  end

  defp valid_ref_value?(value) when is_binary(value),
    do: String.length(value) <= @ref_value_max_length

  defp valid_ref_value?(_), do: false

  defp refs_serialized_size(refs) do
    case Jason.encode(refs) do
      {:ok, json} -> byte_size(json)
      # Unencodable refs are already rejected by the key/value checks above; treat
      # an encode failure as over-limit so it can never slip through.
      {:error, _} -> @refs_serialized_max_bytes + 1
    end
  end

  # Scan every persisted, JSON-served field for a credential shape. `session_id`
  # and `host` are client-supplied and echoed to every peer session reading the
  # channel, so they must be scanned too — a Bearer/`sk-`/`lc_` token stuffed into
  # them would otherwise exfiltrate onto the shared bus with no rejection.
  #
  # Errors are ACCUMULATED (not short-circuited) so a caller learns about every
  # offending field in one round trip. A hit emits telemetry + a structured log
  # (no secret value) so an operator can see repeated credential-leak attempts.
  defp validate_no_secrets(changeset) do
    changeset
    |> add_secret_errors(@scanned_text_fields, &get_field(changeset, &1))
    |> add_secret_errors([:refs], fn :refs ->
      changeset |> get_field(:refs) |> Kernel.||(%{}) |> Map.values()
    end)
  end

  defp add_secret_errors(changeset, fields, extractor) do
    Enum.reduce(fields, changeset, fn field, acc ->
      value = extractor.(field)

      has_secret? =
        if is_list(value),
          do: SecretDenylist.any_contains_secret?(value),
          else: SecretDenylist.contains_secret?(value)

      if has_secret? do
        emit_secret_blocked(acc, field)
        add_error(acc, field, "must not contain a secret or credential")
      else
        acc
      end
    end)
  end

  defp emit_secret_blocked(changeset, field) do
    metadata = %{
      tenant_id: get_field(changeset, :tenant_id),
      project_id: get_field(changeset, :project_id),
      agent_id: get_field(changeset, :agent_id),
      field: field
    }

    :telemetry.execute([:loopctl, :coordination, :secret_blocked], %{count: 1}, metadata)

    Logger.warning(
      "coordination denylist hit: blocked #{field} carrying a credential shape " <>
        "(tenant=#{metadata.tenant_id} project=#{metadata.project_id} agent=#{metadata.agent_id})"
    )

    :ok
  end
end
