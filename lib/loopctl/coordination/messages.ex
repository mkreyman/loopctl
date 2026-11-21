defmodule Loopctl.Coordination.Messages do
  @moduledoc """
  The one insert path into `channel_posts` (US-52.22). A row is a message attached to
  exactly one thing, and this module is what makes the attachment, its order and its
  lifetime hold:

    * **Attachment.** A thread message (`story_id`) takes its story's `project_id`, read here
      inside the caller's tenant, so a thread can never name another project. A DM
      (`to_holder_id`) carries no project. A channel message carries `project_id` alone. The
      database check `channel_posts_one_attachment` refuses every other shape.
    * **Order.** `attachment_seq` is the attachment's current maximum plus one, taken under
      `pg_advisory_xact_lock(hashtextextended(tenant_id || attachment_id, 0))` in the insert's
      own transaction. Two inserts on one attachment therefore serialise on the lock, take
      consecutive values and commit in that order; the unique index
      `channel_posts_attachment_seq_uidx` on `(tenant_id, COALESCE(story_id, to_holder_id,
      project_id), attachment_seq)` is the backstop. Unlike the global `seq` (assigned before
      commit, so a later value can commit first), this order is commit order. A rolled-back
      insert consumes nothing. Other attachments never wait on the lock.
    * **Lifetime.** `expires_at` is set from the attachment: NULL for a thread or a DM (it
      lives as long as its story or holder: the foreign keys cascade), now + the tenant setting
      `channel_message_retention_days` (default 7, `default_channel_retention_days/0`) for a channel message, and now +
      `Loopctl.Coordination.retention_days/0` for a channel row keyed `handoff:<anchor>`.
      `Loopctl.Workers.ChannelPostSweeper` deletes on `expires_at < now`, so a thread or DM row
      is never swept by age.
    * **Retired keys.** A key that does not start `handoff:` is refused
      `{:error, :keyed_slot_retired}`: working state is work-item notes now.

  A keyed `handoff:` upsert that lands on an existing slot keeps that row's `attachment_seq`
  (the conflict update does not set it).
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Loopctl.AdminRepo
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Tenants
  alias Loopctl.WorkBreakdown.Story

  @default_channel_retention_days 7
  @retention_setting "channel_message_retention_days"
  @handoff_prefix "handoff:"

  @keyed_slot_retired_message "keyed working-state slots are retired: write plan, progress, " <>
                                "decisions and questions as work-item notes (story_notes, " <>
                                "release 3), and messages with message_send"

  @doc "Days a channel message lives when the tenant sets no `#{@retention_setting}`."
  @spec default_channel_retention_days() :: pos_integer()
  def default_channel_retention_days, do: @default_channel_retention_days

  @doc "The tenant setting that overrides `default_channel_retention_days/0`."
  @spec retention_setting() :: String.t()
  def retention_setting, do: @retention_setting

  @doc "The message the `keyed_slot_retired` refusal carries."
  @spec keyed_slot_retired_message() :: String.t()
  def keyed_slot_retired_message, do: @keyed_slot_retired_message

  @doc "True for a key the retired-slot rule refuses: present and not `handoff:`."
  @spec retired_key?(term()) :: boolean()
  def retired_key?(key) when is_binary(key) do
    String.trim(key) != "" and not String.starts_with?(key, @handoff_prefix)
  end

  def retired_key?(_key), do: false

  @doc """
  The advisory-lock key for one attachment: `tenant_id || attachment_id`, hashed by
  `hashtextextended(_, 0)` in SQL. `Loopctl.Projects.Merge` takes the same lock on the target
  channel while it renumbers.
  """
  @spec lock_key(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def lock_key(tenant_id, attachment_id), do: "#{tenant_id}#{attachment_id}"

  @doc "Takes the attachment's transaction-scoped advisory lock. Call inside a transaction."
  @spec lock_attachment(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def lock_attachment(tenant_id, attachment_id) do
    AdminRepo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      lock_key(tenant_id, attachment_id)
    ])

    :ok
  end

  @doc """
  The number of days a channel message lives for `tenant_id`: its
  `#{@retention_setting}` setting when that is a positive integer, else
  #{@default_channel_retention_days}.
  """
  @spec channel_retention_days(Ecto.UUID.t()) :: pos_integer()
  def channel_retention_days(tenant_id) do
    case Tenants.get_tenant(tenant_id) do
      {:ok, tenant} ->
        case Tenants.get_tenant_settings(tenant, @retention_setting) do
          days when is_integer(days) and days > 0 -> days
          _ -> @default_channel_retention_days
        end

      {:error, :not_found} ->
        @default_channel_retention_days
    end
  end

  @doc """
  The retention window, in days, of an already-stored row: nil for a thread or a DM, the
  handoff window for a `handoff:` key, otherwise the tenant's channel window. The quarantine
  release rolls a row back to this (`ChannelPost.release_changeset/3`).
  """
  @spec retention_days_for(ChannelPost.t()) :: pos_integer() | nil
  def retention_days_for(%ChannelPost{} = post) do
    retention_for(post.tenant_id, attachment(post.story_id, post.to_holder_id), post.key)
  end

  @doc """
  Inserts the message `changeset` describes, attached, numbered and given its lifetime here.

  `opts` are passed to `AdminRepo.insert/2` (the keyed `handoff:` upsert passes its
  `on_conflict`), except `:now`, the clock `expires_at` is computed from (default
  `DateTime.utc_now/0`). Runs inside the caller's transaction when there is one, else in its
  own, because the advisory lock lives as long as the transaction.

  Returns `{:ok, post}`, `{:error, changeset}`, `{:error, :keyed_slot_retired}`, or
  `{:error, :not_found}` for a thread whose story is not in the tenant.
  """
  @spec insert(Changeset.t(), keyword()) ::
          {:ok, ChannelPost.t()}
          | {:error, Changeset.t()}
          | {:error, :keyed_slot_retired | :not_found}
  def insert(%Changeset{} = changeset, opts \\ []) do
    {now, opts} = Keyword.pop_lazy(opts, :now, &DateTime.utc_now/0)

    cond do
      retired_key?(Changeset.get_field(changeset, :key)) or keyed_off_channel?(changeset) ->
        {:error, :keyed_slot_retired}

      not changeset.valid? ->
        AdminRepo.insert(changeset, opts)

      AdminRepo.in_transaction?() ->
        attach_and_insert(changeset, opts, now)

      true ->
        AdminRepo.transaction(fn -> attach_or_rollback(changeset, opts, now) end)
    end
  end

  defp attach_or_rollback(changeset, opts, now) do
    case attach_and_insert(changeset, opts, now) do
      {:ok, post} -> post
      {:error, reason} -> AdminRepo.rollback(reason)
    end
  end

  # A `handoff:` slot is a channel construct (its index, its claim and its discovery read
  # are all per project channel); a thread or DM message carries no key.
  defp keyed_off_channel?(changeset) do
    not is_nil(Changeset.get_field(changeset, :key)) and
      (not is_nil(Changeset.get_field(changeset, :story_id)) or
         not is_nil(Changeset.get_field(changeset, :to_holder_id)))
  end

  defp attach_and_insert(changeset, opts, now) do
    tenant_id = Changeset.get_field(changeset, :tenant_id)

    with {:ok, changeset} <- resolve_thread_project(changeset, tenant_id) do
      story_id = Changeset.get_field(changeset, :story_id)
      to_holder_id = Changeset.get_field(changeset, :to_holder_id)
      project_id = Changeset.get_field(changeset, :project_id)
      attachment_id = story_id || to_holder_id || project_id
      kind = attachment(story_id, to_holder_id)

      :ok = lock_attachment(tenant_id, attachment_id)

      changeset
      |> Changeset.put_change(:attachment_seq, next_seq(tenant_id, attachment_id))
      |> Changeset.put_change(
        :expires_at,
        expires_at(tenant_id, kind, Changeset.get_field(changeset, :key), now)
      )
      |> AdminRepo.insert(opts)
    end
  end

  # A thread's project is its story's, read inside the tenant. A story outside the tenant (or
  # gone) is `:not_found`. A thread that also names a holder is left for the check to refuse.
  defp resolve_thread_project(changeset, tenant_id) do
    case {Changeset.get_field(changeset, :story_id),
          Changeset.get_field(changeset, :to_holder_id)} do
      {nil, _holder} ->
        {:ok, changeset}

      {_story_id, holder} when not is_nil(holder) ->
        {:ok, changeset}

      {story_id, nil} ->
        case AdminRepo.one(
               from(s in Story,
                 where: s.id == ^story_id and s.tenant_id == ^tenant_id,
                 select: s.project_id
               )
             ) do
          nil -> {:error, :not_found}
          project_id -> {:ok, Changeset.put_change(changeset, :project_id, project_id)}
        end
    end
  end

  defp next_seq(tenant_id, attachment_id) do
    from(p in ChannelPost,
      where: p.tenant_id == ^tenant_id,
      where:
        fragment("COALESCE(?, ?, ?)", p.story_id, p.to_holder_id, p.project_id) ==
          type(^attachment_id, :binary_id),
      select: coalesce(max(p.attachment_seq), 0)
    )
    |> AdminRepo.one()
    |> Kernel.+(1)
  end

  defp attachment(story_id, _to_holder_id) when not is_nil(story_id), do: :thread
  defp attachment(nil, to_holder_id) when not is_nil(to_holder_id), do: :dm
  defp attachment(nil, nil), do: :channel

  defp expires_at(tenant_id, kind, key, now) do
    case retention_for(tenant_id, kind, key) do
      nil -> nil
      days -> DateTime.add(now, days * 86_400, :second)
    end
  end

  defp retention_for(_tenant_id, kind, _key) when kind in [:thread, :dm], do: nil

  defp retention_for(tenant_id, :channel, key) do
    if is_binary(key) and String.starts_with?(key, @handoff_prefix),
      do: Coordination.retention_days(),
      else: channel_retention_days(tenant_id)
  end
end
