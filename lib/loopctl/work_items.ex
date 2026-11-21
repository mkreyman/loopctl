defmodule Loopctl.WorkItems do
  @moduledoc """
  A work item's notes (US-52.17): what its holder planned, did, decided and is asking,
  filed by section on `story_notes` beside the story.

  Notes are a holder's progress on the item it holds, not work-breakdown data: a note never
  changes acceptance criteria, status or a custody field. So the writer is the item's
  CURRENT holder (the caller's `holder_id`, resolved from its key, equal to
  `stories.assigned_holder_id`) or an orchestrator, user or superadmin key. Every other
  agent-role caller is refused, the way every claimant verb refuses another holder
  (US-52.14).

  Why not `stories.metadata`: it is cast and whole-map-replaced by `PATCH
  /api/v1/stories/:id`, so progress written there is erased by an ordinary request.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Auth.Role
  alias Loopctl.Delivery.Stages
  alias Loopctl.KeysetCursor
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.WorkItems.Note

  @cursor_namespace "story_notes_cursor"
  @default_limit 50
  @max_limit 200

  @typedoc """
  The writer, resolved SERVER-SIDE from the authenticating key: never from request params.
  """
  @type author :: %{
          required(:api_key_id) => Ecto.UUID.t(),
          required(:role) => atom(),
          required(:holder_id) => Ecto.UUID.t() | nil
        }

  @type page :: %{
          data: [Note.t()],
          has_more: boolean(),
          next_cursor: String.t() | nil,
          current: %{optional(String.t()) => Note.t()} | nil
        }

  @doc "Opens an interactive session's work item for its branch: `Loopctl.WorkItems.Open`."
  defdelegate open_interactive(tenant_id, opener, attrs, opts \\ []), to: Loopctl.WorkItems.Open

  @doc "The default and the largest page `list_notes/3` returns."
  @spec page_limits() :: {pos_integer(), pos_integer()}
  def page_limits, do: {@default_limit, @max_limit}

  @doc """
  Appends a note to a story and records a `note_written` event on its log, in one
  transaction: if either refuses, neither is written.

  `attrs` carries `section`, `body` and an optional `idempotency_key`; `author` is the
  server-resolved writer (`t:author/0`).

  Options: `:story`, the story row as a value, for a caller (or a test) that has already
  read it; without it the story is read under `FOR SHARE`, so no release can commit between
  the holder check and the write.

  Returns `{:ok, note}` (the FIRST note when its own writer repeats `idempotency_key`, with
  no second note and no second event), `{:error, %Ecto.Changeset{}}`, `{:error,
  {:held_by_other_holder, holder_id}}`, `{:error, :not_holder}` (an agent-role caller on an
  item nobody holds), `{:error, :idempotency_key_reused}` (a caller allowed to write, reusing
  a key another writer's note already carries) or `{:error, :not_found}` (no such story in
  this tenant).
  """
  @spec write_note(Ecto.UUID.t(), Ecto.UUID.t(), map(), author(), keyword()) ::
          {:ok, Note.t()}
          | {:error,
             Ecto.Changeset.t()
             | {:held_by_other_holder, Ecto.UUID.t()}
             | :not_holder
             | :idempotency_key_reused
             | :not_found}
  def write_note(tenant_id, story_id, attrs, author, opts \\ []) do
    changeset = Note.create_changeset(%Note{}, attrs)

    if changeset.valid? do
      key = Ecto.Changeset.get_field(changeset, :idempotency_key)

      # The writer's own retry is answered even after the item changed hands; anyone else
      # repeating that key goes through may_write/2 first, so a caller who may not write is
      # refused for that, and one who may is told the key is another writer's.
      case existing_note(tenant_id, story_id, key) do
        %Note{} = note -> own_replay(note, tenant_id, story_id, changeset, author, opts)
        nil -> insert_note(tenant_id, story_id, changeset, author, opts)
      end
    else
      {:error, changeset}
    end
  end

  defp own_replay(note, tenant_id, story_id, changeset, author, opts) do
    if written_by?(note, author),
      do: {:ok, note},
      else: insert_note(tenant_id, story_id, changeset, author, opts)
  end

  defp written_by?(%Note{holder_id: nil} = note, author),
    do: note.author_api_key_id == author.api_key_id

  defp written_by?(%Note{holder_id: holder_id}, author), do: holder_id == author.holder_id

  defp insert_note(tenant_id, story_id, changeset, author, opts) do
    key = Ecto.Changeset.get_field(changeset, :idempotency_key)

    AdminRepo.transaction(fn ->
      with {:ok, story} <- story_for_write(tenant_id, story_id, opts),
           :ok <- may_write(story, author),
           {:ok, note} <- replay_or_append(tenant_id, story, changeset, author, key) do
        note
      else
        {:error, :replayed} -> AdminRepo.rollback(:replayed)
        {:error, refusal} -> AdminRepo.rollback(refusal)
      end
    end)
    |> case do
      # A concurrent write with the same key won the unique index: answer its note.
      {:error, :replayed} ->
        tenant_id |> existing_note(story_id, key) |> replay(author)

      result ->
        result
    end
  end

  defp story_for_write(tenant_id, story_id, opts) do
    case Keyword.get(opts, :story) do
      %Story{id: ^story_id, tenant_id: ^tenant_id} = story ->
        {:ok, story}

      # No row passed, or one for another story or tenant: read the row the path names.
      _ ->
        from(s in Story,
          where: s.id == ^story_id and s.tenant_id == ^tenant_id,
          lock: "FOR SHARE"
        )
        |> AdminRepo.one()
        |> case do
          nil -> {:error, :not_found}
          story -> {:ok, story}
        end
    end
  end

  defp may_write(%Story{} = story, %{role: role, holder_id: holder_id}) do
    cond do
      Role.role_at_least?(role, :orchestrator) -> :ok
      is_nil(story.assigned_holder_id) -> {:error, :not_holder}
      holder_id == story.assigned_holder_id -> :ok
      true -> {:error, {:held_by_other_holder, story.assigned_holder_id}}
    end
  end

  # The event first, with the note's id already chosen: a story gone between the read and
  # the write refuses there (`:not_found`), before the note is inserted.
  defp append(tenant_id, story, changeset, author) do
    note_id = Ecto.UUID.generate()
    section = Ecto.Changeset.get_field(changeset, :section)
    key = Ecto.Changeset.get_field(changeset, :idempotency_key)
    holder_id = writer_holder(story, author)

    event =
      Stages.record_item_event(tenant_id, story.id, "note_written",
        repo: AdminRepo,
        reason: section <> " note",
        actor_holder_id: holder_id,
        idempotency_key: key && "note:" <> key,
        data: %{"note_id" => note_id, "section" => section}
      )

    case event do
      {:ok, :replayed} ->
        {:error, :replayed}

      {:ok, %{}} ->
        insert_row(%{
          id: note_id,
          tenant_id: tenant_id,
          story_id: story.id,
          holder_id: holder_id,
          author_api_key_id: author.api_key_id,
          section: section,
          body: Ecto.Changeset.get_field(changeset, :body),
          idempotency_key: key,
          inserted_at: DateTime.utc_now()
        })

      {:error, refusal} ->
        {:error, refusal}
    end
  end

  defp insert_row(row) do
    case AdminRepo.insert_all(Note, [row],
           on_conflict: :nothing,
           conflict_target:
             {:unsafe_fragment,
              "(tenant_id, story_id, idempotency_key) WHERE idempotency_key IS NOT NULL"},
           returning: true
         ) do
      {1, [note]} -> {:ok, note}
      {0, []} -> {:error, :replayed}
    end
  end

  # The holder a note names: the caller's, when it is the item's holder. An orchestrator+
  # key writes as itself, so its note names no holder even if its key carries one.
  defp writer_holder(%Story{assigned_holder_id: held}, %{holder_id: holder_id})
       when not is_nil(held) and holder_id == held,
       do: holder_id

  defp writer_holder(_story, _author), do: nil

  defp replay_or_append(tenant_id, story, changeset, author, key) do
    case existing_note(tenant_id, story.id, key) do
      %Note{} = note -> replay(note, author)
      nil -> append(tenant_id, story, changeset, author)
    end
  end

  # An idempotency key names ONE writer's write. Another writer reusing it (the item's next
  # holder, an orchestrator) is told so, rather than answered a note it did not write while
  # its own is dropped.
  defp replay(%Note{} = note, author) do
    if written_by?(note, author), do: {:ok, note}, else: {:error, :idempotency_key_reused}
  end

  defp existing_note(_tenant_id, _story_id, nil), do: nil

  defp existing_note(tenant_id, story_id, key) do
    AdminRepo.one(
      from n in Note,
        where: n.tenant_id == ^tenant_id and n.story_id == ^story_id and n.idempotency_key == ^key
    )
  end

  @doc """
  A story's notes, oldest first, one page at a time.

  Options: `:section` (one of `Note.sections/0`), `:limit` (default 50, at most 200) and
  `:after` (the opaque `next_cursor` of the previous page). The FIRST page (no `:after`)
  also carries `current`: the newest note of each section, so the next holder reads where
  the item stands without walking the whole history.

  Returns `{:ok, page}`, `{:error, :not_found}` for a story that is not this tenant's, or
  `{:error, :invalid_cursor}` / `{:error, :invalid_section}`.
  """
  @spec list_notes(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, page()} | {:error, :not_found | :invalid_cursor | :invalid_section}
  def list_notes(tenant_id, story_id, opts \\ []) do
    limit = (Keyword.get(opts, :limit) || @default_limit) |> min(@max_limit) |> max(1)

    with {:ok, section} <- section_filter(Keyword.get(opts, :section)),
         {:ok, position} <- position(tenant_id, Keyword.get(opts, :after)) do
      {:ok, result} =
        Repo.with_tenant(tenant_id, fn ->
          page_if_found(tenant_id, story_id, section, position, limit)
        end)

      result
    end
  end

  defp page_if_found(tenant_id, story_id, section, position, limit) do
    if story_exists?(tenant_id, story_id),
      do: {:ok, read_page(tenant_id, story_id, section, position, limit)},
      else: {:error, :not_found}
  end

  defp section_filter(nil), do: {:ok, nil}

  defp section_filter(section) when is_binary(section) do
    if section in Note.sections(), do: {:ok, section}, else: {:error, :invalid_section}
  end

  defp section_filter(_section), do: {:error, :invalid_section}

  defp position(_tenant_id, nil), do: {:ok, nil}

  defp position(tenant_id, cursor) do
    case KeysetCursor.decode(@cursor_namespace, tenant_id, cursor) do
      {:ok, {_at, id} = position} when is_binary(id) -> {:ok, position}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp story_exists?(tenant_id, story_id) do
    Repo.exists?(from s in Story, where: s.id == ^story_id and s.tenant_id == ^tenant_id)
  end

  defp read_page(tenant_id, story_id, section, position, limit) do
    base = notes_query(tenant_id, story_id, section)

    rows =
      base
      |> after_position(position)
      |> order_by([n], asc: n.inserted_at, asc: n.id)
      |> limit(^(limit + 1))
      |> Repo.all()

    {data, more} = Enum.split(rows, limit)
    has_more = more != []

    %{
      data: data,
      has_more: has_more,
      next_cursor: if(has_more, do: cursor(tenant_id, List.last(data))),
      current: if(is_nil(position), do: current(tenant_id, story_id))
    }
  end

  defp notes_query(tenant_id, story_id, nil),
    do: from(n in Note, where: n.tenant_id == ^tenant_id and n.story_id == ^story_id)

  defp notes_query(tenant_id, story_id, section),
    do: from(n in notes_query(tenant_id, story_id, nil), where: n.section == ^section)

  defp after_position(query, nil), do: query

  defp after_position(query, {at, id}) do
    where(query, [n], n.inserted_at > ^at or (n.inserted_at == ^at and n.id > ^id))
  end

  defp cursor(tenant_id, %Note{inserted_at: at, id: id}),
    do: KeysetCursor.encode(@cursor_namespace, tenant_id, {at, id})

  # The newest note of each section, whatever page or filter was asked for.
  defp current(tenant_id, story_id) do
    from(n in Note,
      where: n.tenant_id == ^tenant_id and n.story_id == ^story_id,
      distinct: n.section,
      order_by: [asc: n.section, desc: n.inserted_at, desc: n.id]
    )
    |> Repo.all()
    |> Map.new(&{&1.section, &1})
  end
end
