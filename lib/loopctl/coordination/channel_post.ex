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
  showed the category taxonomy was essentially unused. An optional `key` gives
  per-session upsert of working-state without a type system.

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

  alias Loopctl.Security.SecretDenylist

  @type t :: %__MODULE__{}

  @body_max_length 16_384
  @key_max_length 200
  @ref_value_max_length 512
  @refs_serialized_max_bytes 4_096
  @allowed_ref_keys ~w(file pr branch commit)

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

  Enforces the size/shape bounds (`body` <= 16KB, `key` <= 200, constrained
  `refs`) and runs the shared secret denylist over `body`, every `refs` value,
  and `key` — a match rejects the write (surfaced as a 422) rather than silently
  dropping the content.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(post, attrs) do
    post
    |> cast(attrs, [:session_id, :host, :key, :body, :refs])
    |> validate_required([:tenant_id, :project_id, :agent_id, :body, :expires_at])
    |> validate_length(:body, max: @body_max_length)
    |> validate_length(:key, max: @key_max_length)
    |> validate_refs()
    |> validate_no_secrets()
  end

  @doc "Maximum allowed `body` length in characters."
  @spec body_max_length() :: pos_integer()
  def body_max_length, do: @body_max_length

  @doc "Allowed keys for the `refs` map."
  @spec allowed_ref_keys() :: [String.t()]
  def allowed_ref_keys, do: @allowed_ref_keys

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

  defp validate_no_secrets(changeset) do
    body = get_field(changeset, :body)
    key = get_field(changeset, :key)
    refs = get_field(changeset, :refs) || %{}

    cond do
      SecretDenylist.contains_secret?(body) ->
        add_error(changeset, :body, "must not contain a secret or credential")

      SecretDenylist.contains_secret?(key) ->
        add_error(changeset, :key, "must not contain a secret or credential")

      SecretDenylist.any_contains_secret?(Map.values(refs)) ->
        add_error(changeset, :refs, "must not contain a secret or credential")

      true ->
        changeset
    end
  end
end
