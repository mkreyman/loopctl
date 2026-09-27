defmodule LoopctlWeb.ThreadLive do
  @moduledoc """
  US-45.7 — the thread page (Epic 45 PRD §6.1): where the tenant's human reads a story's change
  thread without GitHub, and writes `message` and `finding` entries on it.

  ## What it reads, and from where

  The ledger — checkpoints with their kind and CI evidence, entries, findings — comes from
  `Loopctl.Threads.page/3`, one transaction under the tenant's RLS (`Repo.with_tenant/2`),
  never `AdminRepo`. A story of another tenant is simply not found.

  A checkpoint's DIFF comes from the forge, by SHA, only when asked for, and is never stored
  (`Loopctl.Threads.checkpoint_diff/3`). It is fetched in a `start_async` task, so the ledger
  renders whatever the forge is doing: a slow forge shows a loading panel for that one
  checkpoint, a down one shows its error there, and nothing else on the page waits.

  ## Entries are untrusted

  Every entry body was written by a session or a person and is rendered as TEXT: HEEx escapes
  it, it sits in a `<pre>` so its whitespace is its own, and it is marked untrusted. There is no
  Markdown rendering and no raw HTML anywhere on this page.

  ## What it writes, and the failures it answers

  - **A replayed submit.** Each form carries a nonce minted when it was rendered, and the nonce
    IS the entry's idempotency key. The key is taken from the SUBMITTED form, not the socket, so
    a double click, a resubmit after a lost reply or a reconnect replays the same key and
    `Loopctl.Threads` answers it from the row: one entry. A fresh nonce is minted only once the
    write is recorded.
  - **Who writes.** The principal is `Loopctl.Threads.human_principal/0` with an EMPTY lineage,
    through the same context entry points the API reaches, under the same story lock and rules
    (`record_entry/4` for a message, `record_human_finding/3` for a finding). Nothing here
    decides custody.
  - **A revoked authenticator mid-session.** The session is re-validated before every write and
    on a timer while the page is open (`Loopctl.WebAuthn.BrowserLogin.validate/2`), not only at
    mount, so revoking the authenticator ends an open page within a minute and refuses its
    next write at once.
  - **A tenant halt.** Reads stay open, as they do on the API, and the page says the tenant is
    halted. A finding is refused `tenant_halted` by `Loopctl.Threads`, as every judgement is; a
    message is not, as it is not on the API (`LoopctlWeb.CustodySurface`).
  """

  use LoopctlWeb, :live_view

  alias Loopctl.Threads
  alias Loopctl.WebAuthn.BrowserLogin
  alias Loopctl.Workers.ReviewCeilingWorker

  @revalidate_ms 60_000

  @impl true
  def mount(%{"story_id" => story_id}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Thread")
      |> assign(:open_diff, nil)
      |> assign(:notice, nil)
      |> stream_configure(:entries, dom_id: &"entry-#{&1.id}")

    case Ecto.UUID.cast(story_id) do
      {:ok, story_id} ->
        if connected?(socket), do: schedule_revalidate()

        {:ok,
         socket
         |> assign(:story_id, story_id)
         |> assign(:message_form, message_form())
         |> load()}

      :error ->
        {:ok, assign(socket, :story, nil)}
    end
  end

  # Once, at mount: the NEWEST page of entries. A write adds its own entry
  # (`record_written/3`); "load older" walks backwards. Nothing re-reads the whole thread.
  defp load(socket) do
    case Threads.page(socket.assigns.browser_principal.tenant_id, socket.assigns.story_id) do
      {:ok, page} ->
        socket
        |> assign(:story, page.story)
        |> assign(:page_title, page.story.title)
        |> assign(:repo, page.repo)
        |> assign(:checkpoints, page.checkpoints)
        |> assign(:checkpoints_truncated, page.checkpoints_truncated)
        |> assign(:older_before_seq, page.older_before_seq)
        |> assign(:findings, page.findings)
        |> assign(:halted, page.halted)
        |> assign(:finding_form, finding_form(page.checkpoints))
        |> stream(:entries, page.entries, reset: true)

      {:error, :not_found} ->
        assign(socket, :story, nil)
    end
  end

  defp schedule_revalidate, do: Process.send_after(self(), :revalidate, @revalidate_ms)

  # ---------------------------------------------------------------------------
  # Forms
  # ---------------------------------------------------------------------------

  defp nonce, do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp message_form, do: to_form(%{"body" => "", "nonce" => nonce()}, as: :message)

  defp finding_form(checkpoints) do
    latest = checkpoints |> Enum.filter(&(&1.kind == :checkpoint)) |> List.last()

    to_form(
      %{
        "body" => "",
        "nonce" => nonce(),
        "checkpoint_id" => latest && latest.id,
        "severity" => "medium",
        "location" => "",
        "introduced_by" => ""
      },
      as: :finding
    )
  end

  # A page with no story (a malformed id, or a story this tenant cannot see) has nothing to
  # write to or read from: every event is refused here, before any clause reads a story id.
  @impl true
  def handle_event(_event, _params, %{assigns: %{story: nil}} = socket), do: {:noreply, socket}

  def handle_event("post_message", %{"message" => %{"body" => body, "nonce" => key}}, socket) do
    write(socket, :message_form, :message, fn principal ->
      Threads.record_entry(
        principal.tenant_id,
        socket.assigns.story_id,
        %{"kind" => "message", "idempotency_key" => key, "body" => body},
        author_principal: Threads.human_principal(),
        actor_lineage: []
      )
    end)
  end

  def handle_event("post_finding", %{"finding" => params}, socket) when is_map(params) do
    attrs = %{
      "idempotency_key" => params["nonce"],
      "body" => params["body"],
      "checkpoint_id" => blank_to_nil(params["checkpoint_id"]),
      "severity" => params["severity"],
      "location" => blank_to_nil(params["location"]),
      "introduced_by" => blank_to_nil(params["introduced_by"])
    }

    write(socket, :finding_form, :finding, fn principal ->
      Threads.record_human_finding(principal.tenant_id, socket.assigns.story_id, attrs)
    end)
  end

  # ONE diff is open at a time: opening another closes it, and the page never holds more than
  # one diff's text. Only a checkpoint on this page may be opened, and asking for the one that
  # is already open or loading does nothing; a failed one may be asked for again (retry).
  def handle_event("load_diff", %{"id" => checkpoint_id}, socket) when is_binary(checkpoint_id) do
    cond do
      not Enum.any?(socket.assigns.checkpoints, &(&1.id == checkpoint_id)) ->
        {:noreply, socket}

      open_or_loading?(socket.assigns.open_diff, checkpoint_id) ->
        {:noreply, socket}

      true ->
        {:noreply, open_diff(socket, checkpoint_id)}
    end
  end

  # The page before the oldest one shown, inserted above it. Each entry goes in at the top, so
  # the page is fed newest first to leave it oldest first on screen.
  def handle_event("load_older", _params, %{assigns: %{older_before_seq: seq}} = socket)
      when is_integer(seq) do
    case Threads.page(socket.assigns.browser_principal.tenant_id, socket.assigns.story_id,
           before_seq: seq
         ) do
      {:ok, page} ->
        {:noreply,
         socket
         |> assign(:older_before_seq, page.older_before_seq)
         |> stream(:entries, Enum.reverse(page.entries), at: 0)}

      {:error, :not_found} ->
        {:noreply, assign(socket, :story, nil)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp open_diff(socket, checkpoint_id) do
    tenant_id = socket.assigns.browser_principal.tenant_id
    story_id = socket.assigns.story_id

    socket
    |> close_diff()
    |> assign(:open_diff, {checkpoint_id, :loading})
    |> start_async({:diff, checkpoint_id}, fn ->
      Threads.checkpoint_diff(tenant_id, story_id, checkpoint_id)
    end)
  end

  defp close_diff(%{assigns: %{open_diff: {id, :loading}}} = socket),
    do: cancel_async(socket, {:diff, id})

  defp close_diff(socket), do: socket

  # Every write re-validates the session FIRST: a page opened before the authenticator was
  # revoked must not write after it. On a refusal the form is kept AS IT WAS — same nonce — so
  # resending it is the same write, never a second one.
  defp write(socket, form_key, kind, fun) do
    case BrowserLogin.validate(BrowserLogin.to_session(socket.assigns.browser_principal)) do
      {:ok, principal} ->
        case fun.(principal) do
          {:ok, written, _created_or_existing} ->
            {:noreply,
             socket
             |> assign(form_key, fresh_form(kind, socket))
             |> record_written(kind, written)}

          error ->
            {:noreply, assign(socket, :notice, {kind, :error, error_message(error)})}
        end

      {:error, _reason} ->
        {:noreply, signed_out(socket)}
    end
  end

  # The written entry goes into the page as it is; checkpoints, diffs and older pages are left
  # alone. A finding that met the review ceiling brings its escalation with it, and the page
  # says so rather than "Recorded.": the stage move is enqueued now, and the minute sweep of
  # `ReviewCeilingWorker` is its backstop.
  defp record_written(socket, :message, entry) do
    socket
    |> stream_insert(:entries, entry)
    |> assign(:notice, {:message, :ok, "Recorded."})
  end

  defp record_written(socket, :finding, %{entry: entry, escalation: escalation}) do
    socket =
      socket
      |> stream_insert(:entries, entry)
      |> assign(:findings, upsert(socket.assigns.findings, entry))

    case escalation do
      nil ->
        assign(socket, :notice, {:finding, :ok, "Recorded."})

      {:escalated, escalation} ->
        ReviewCeilingWorker.enqueue(entry.tenant_id, entry.story_id)

        socket
        |> stream_insert(:entries, escalation)
        |> assign(
          :notice,
          {:finding, :ok,
           "Recorded. The review rounds are at their ceiling, so this finding escalated the " <>
             "story (review_ceiling)."}
        )

      {:already_escalated, _escalation} ->
        assign(
          socket,
          :notice,
          {:finding, :ok,
           "Recorded. The story was already escalated at the review ceiling; this finding " <>
             "adds to that, and escalates nothing new."}
        )
    end
  end

  defp upsert(findings, entry) do
    if Enum.any?(findings, &(&1.id == entry.id)), do: findings, else: findings ++ [entry]
  end

  defp fresh_form(:message, _socket), do: message_form()
  defp fresh_form(:finding, socket), do: finding_form(socket.assigns.checkpoints)

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp error_message({:error, {:conflict, _code, message}}), do: message
  defp error_message({:error, {_status, _code, message}}) when is_binary(message), do: message
  defp error_message({:error, :unprocessable_entity, %{message: message}}), do: message

  defp error_message({:error, :unprocessable_entity, message}) when is_binary(message),
    do: message

  defp error_message({:error, %Ecto.Changeset{} = changeset}) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp error_message({:error, :tenant_halted}),
    do: "The tenant's custody is halted: findings are refused until the halt is cleared."

  defp error_message({:error, :busy}),
    do: "The thread is busy. Submit again: the same form is safe to resend."

  defp error_message({:error, :not_found}), do: "This thread no longer exists."
  defp error_message(_error), do: "The entry was not recorded."

  # ---------------------------------------------------------------------------
  # Async diff and the session timer
  # ---------------------------------------------------------------------------

  @impl true
  # A result lands only on the diff still open: one whose checkpoint was closed in favour of
  # another is dropped.
  def handle_async({:diff, checkpoint_id}, result, socket) do
    case socket.assigns.open_diff do
      {^checkpoint_id, :loading} ->
        {:noreply, assign(socket, :open_diff, {checkpoint_id, diff_outcome(result)})}

      _other ->
        {:noreply, socket}
    end
  end

  defp diff_outcome({:ok, result}), do: result
  defp diff_outcome({:exit, reason}), do: {:error, reason}

  defp open_or_loading?({id, :loading}, id), do: true
  defp open_or_loading?({id, {:ok, _diff}}, id), do: true
  defp open_or_loading?(_open, _id), do: false

  defp diff_state({id, state}, id), do: state
  defp diff_state(_open, _id), do: nil

  @impl true
  def handle_info(:revalidate, socket) do
    case BrowserLogin.validate(BrowserLogin.to_session(socket.assigns.browser_principal)) do
      {:ok, _principal} ->
        schedule_revalidate()
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, signed_out(socket)}
    end
  end

  defp signed_out(socket) do
    socket
    |> put_flash(:error, "Your session ended. Sign in again.")
    |> redirect(to: ~p"/login")
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  @impl true
  def render(%{story: nil} = assigns) do
    ~H"""
    <section class="mx-auto max-w-3xl px-6 py-16" id="thread-not-found">
      <h1 class="font-display text-xl font-semibold text-slate-100">Thread not found</h1>
      <p class="mt-2 text-sm text-slate-400">
        No story with that id is visible to this tenant.
      </p>
    </section>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-6xl px-4 py-8 sm:px-6" id="thread-page">
      <header class="mb-6 flex flex-wrap items-start justify-between gap-4 border-b border-slate-800 pb-4">
        <div class="min-w-0">
          <p class="font-mono text-xs uppercase tracking-wide text-slate-500">
            thread <span :if={@story.number}>· {@story.number}</span>
          </p>
          <h1
            id="thread-title"
            class="mt-1 break-words font-display text-xl font-semibold text-slate-100"
          >
            {@story.title}
          </h1>
          <p class="mt-1 font-mono text-xs text-slate-500">
            {@repo || "no intake repository"} · signed in as human:webauthn
          </p>
        </div>
        <.link
          href={~p"/logout"}
          method="delete"
          id="thread-logout"
          class="font-mono text-xs uppercase tracking-wide text-slate-400 hover:text-slate-200"
        >
          Sign out
        </.link>
      </header>

      <div
        :if={@halted}
        id="thread-halted"
        class="mb-6 rounded-md border border-rose-900 bg-rose-950/40 px-4 py-3 text-sm text-rose-300"
      >
        Custody is halted for this tenant. The thread stays readable; findings are refused until
        the halt is cleared.
      </div>

      <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_22rem]">
        <div class="min-w-0 space-y-6">
          <section id="thread-checkpoints" class="rounded-md border border-slate-800">
            <h2 class="border-b border-slate-800 px-4 py-2 font-mono text-xs uppercase tracking-wide text-slate-400">
              Checkpoints
            </h2>
            <p :if={@checkpoints == []} class="px-4 py-3 text-sm text-slate-500">
              No checkpoint recorded yet.
            </p>
            <p :if={@checkpoints_truncated} class="px-4 py-2 font-mono text-xs text-slate-500">
              Showing the most recent checkpoints.
            </p>
            <ol class="divide-y divide-slate-800">
              <li :for={cp <- @checkpoints} id={"checkpoint-#{cp.id}"} class="px-4 py-3">
                <div class="flex flex-wrap items-center gap-x-3 gap-y-1 font-mono text-xs">
                  <span class="text-slate-500">#{cp.seq}</span>
                  <span class={[
                    "rounded-sm border px-1.5 py-0.5",
                    cp.kind == :checkpoint && "border-accent-800 text-accent-300",
                    cp.kind == :base_update && "border-slate-700 text-slate-400"
                  ]}>
                    {cp.kind}
                  </span>
                  <span class="text-slate-200" title={cp.commit_sha}>
                    {String.slice(cp.commit_sha, 0, 12)}
                  </span>
                  <span class="text-slate-500">epoch {cp.claim_epoch}</span>
                  <span :if={cp.merge_commit_sha} class="text-emerald-400">
                    merged {String.slice(cp.merge_commit_sha, 0, 12)}
                  </span>
                </div>
                <.ci_evidence id={"ci-#{cp.id}"} record={cp.gate_evidence["ci"]} />
                <div class="mt-2">
                  <button
                    :if={diff_state(@open_diff, cp.id) == nil}
                    type="button"
                    id={"diff-button-#{cp.id}"}
                    phx-click="load_diff"
                    phx-value-id={cp.id}
                    class="font-mono text-xs text-accent-400 hover:text-accent-300"
                  >
                    show diff
                  </button>
                  <.diff
                    id={"diff-#{cp.id}"}
                    checkpoint_id={cp.id}
                    state={diff_state(@open_diff, cp.id)}
                  />
                </div>
              </li>
            </ol>
          </section>

          <section class="rounded-md border border-slate-800">
            <h2 class="border-b border-slate-800 px-4 py-2 font-mono text-xs uppercase tracking-wide text-slate-400">
              Entries
            </h2>
            <div :if={@older_before_seq} class="border-b border-slate-800 px-4 py-2">
              <button
                type="button"
                id="thread-load-older"
                phx-click="load_older"
                class="font-mono text-xs text-accent-400 hover:text-accent-300"
              >
                load older entries
              </button>
            </div>
            <ol id="thread-entries" phx-update="stream" class="divide-y divide-slate-800">
              <li :for={{dom_id, entry} <- @streams.entries} id={dom_id} class="px-4 py-3">
                <.entry_header entry={entry} />
                <pre
                  class="mt-2 whitespace-pre-wrap break-words font-mono text-sm text-slate-300"
                  data-untrusted="true"
                >{entry.body}</pre>
              </li>
            </ol>
          </section>
        </div>

        <aside class="min-w-0 space-y-6">
          <section id="thread-findings" class="rounded-md border border-slate-800">
            <h2 class="border-b border-slate-800 px-4 py-2 font-mono text-xs uppercase tracking-wide text-slate-400">
              Findings
            </h2>
            <p :if={@findings == []} class="px-4 py-3 text-sm text-slate-500">No findings.</p>
            <ol class="divide-y divide-slate-800">
              <li :for={f <- @findings} id={"finding-#{f.id}"} class="px-4 py-3">
                <div class="flex flex-wrap items-center gap-2 font-mono text-xs">
                  <span class={["uppercase", severity_class(f.severity)]}>{f.severity}</span>
                  <span class="text-slate-500">{f.author_principal}</span>
                </div>
                <p :if={f.location} class="mt-1 break-all font-mono text-xs text-slate-400">
                  {f.location}
                </p>
                <pre
                  class="mt-1 whitespace-pre-wrap break-words font-mono text-xs text-slate-300"
                  data-untrusted="true"
                >{f.body}</pre>
              </li>
            </ol>
          </section>

          <section class="rounded-md border border-slate-800 p-4">
            <h2 class="mb-3 font-mono text-xs uppercase tracking-wide text-slate-400">
              Write a message
            </h2>
            <.form for={@message_form} id="message-form" phx-submit="post_message" class="space-y-3">
              <input
                type="hidden"
                name={@message_form[:nonce].name}
                value={@message_form[:nonce].value}
              />
              <textarea
                name={@message_form[:body].name}
                id="message-body"
                rows="4"
                required
                class={textarea_class()}
              >{@message_form[:body].value}</textarea>
              <button type="submit" id="message-submit" class={button_class()}>Post message</button>
              <.notice notice={@notice} kind={:message} />
            </.form>
          </section>

          <section class="rounded-md border border-slate-800 p-4">
            <h2 class="mb-3 font-mono text-xs uppercase tracking-wide text-slate-400">
              Record a finding
            </h2>
            <.form for={@finding_form} id="finding-form" phx-submit="post_finding" class="space-y-3">
              <input
                type="hidden"
                name={@finding_form[:nonce].name}
                value={@finding_form[:nonce].value}
              />
              <label
                class="block text-xs uppercase tracking-wide text-slate-400"
                for="finding-checkpoint"
              >
                Checkpoint
              </label>
              <select
                name={@finding_form[:checkpoint_id].name}
                id="finding-checkpoint"
                class={select_class()}
              >
                <option
                  :for={cp <- Enum.filter(@checkpoints, &(&1.kind == :checkpoint))}
                  value={cp.id}
                  selected={cp.id == @finding_form[:checkpoint_id].value}
                >
                  #{cp.seq} {String.slice(cp.commit_sha, 0, 12)}
                </option>
              </select>
              <label
                class="block text-xs uppercase tracking-wide text-slate-400"
                for="finding-severity"
              >
                Severity
              </label>
              <select
                name={@finding_form[:severity].name}
                id="finding-severity"
                class={select_class()}
              >
                <option
                  :for={s <- Loopctl.Threads.Entry.severities()}
                  value={s}
                  selected={to_string(s) == @finding_form[:severity].value}
                >
                  {s}
                </option>
              </select>
              <.input field={@finding_form[:location]} label="Location" placeholder="lib/file.ex:42" />
              <label
                class="block text-xs uppercase tracking-wide text-slate-400"
                for="finding-introduced-by"
              >
                Introduced by
              </label>
              <select
                name={@finding_form[:introduced_by].name}
                id="finding-introduced-by"
                class={select_class()}
              >
                <option value="">(round 1: leave empty)</option>
                <option value="none" selected={@finding_form[:introduced_by].value == "none"}>
                  none
                </option>
                <option
                  :for={cp <- Enum.filter(@checkpoints, &(&1.kind == :checkpoint))}
                  value={cp.id}
                  selected={cp.id == @finding_form[:introduced_by].value}
                >
                  #{cp.seq} {String.slice(cp.commit_sha, 0, 12)}
                </option>
              </select>
              <textarea
                name={@finding_form[:body].name}
                id="finding-body"
                rows="4"
                required
                placeholder="What is wrong, and the failure it causes"
                class={textarea_class()}
              >{@finding_form[:body].value}</textarea>
              <button type="submit" id="finding-submit" class={button_class()}>
                Record finding
              </button>
              <.notice notice={@notice} kind={:finding} />
            </.form>
          </section>
        </aside>
      </div>
    </div>
    """
  end

  attr :entry, :map, required: true

  defp entry_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-3 gap-y-1 font-mono text-xs">
      <span class="text-slate-500">#{@entry.seq}</span>
      <span class="text-slate-200">{@entry.kind}</span>
      <span :if={@entry.severity} class={["uppercase", severity_class(@entry.severity)]}>
        {@entry.severity}
      </span>
      <span class="break-all text-slate-500">{@entry.author_principal}</span>
      <span class="rounded-sm border border-amber-900 px-1 text-amber-400/80">untrusted</span>
      <span class="text-slate-600">{Calendar.strftime(@entry.inserted_at, "%Y-%m-%d %H:%M")}</span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :record, :any, required: true

  defp ci_evidence(%{record: %{} = record} = assigns) do
    assigns =
      assign(assigns,
        passed: length(List.wrap(record["passed"])),
        pending: length(List.wrap(record["pending"])),
        missing: length(List.wrap(record["missing"])),
        failed: List.wrap(record["failed"]),
        jobs: List.wrap(record["jobs"])
      )

    ~H"""
    <div id={@id} class="mt-2 space-y-1 font-mono text-xs">
      <p class="text-slate-400">
        CI <span class="text-emerald-400">{@passed} passed</span>
        · <span class="text-slate-300">{@pending} pending</span>
        · <span class="text-amber-400">{@missing} missing</span>
        · <span class="text-rose-400">{length(@failed)} failed</span>
        <span class="text-slate-600">read {@record["read_at"]}</span>
      </p>
      <ul class="text-slate-500">
        <li :for={job <- @jobs}>{job["name"]}: {job["conclusion"] || job["status"]}</li>
      </ul>
    </div>
    """
  end

  defp ci_evidence(assigns) do
    ~H"""
    <p id={@id} class="mt-2 font-mono text-xs text-slate-600">CI not read yet</p>
    """
  end

  attr :id, :string, required: true
  attr :checkpoint_id, :string, required: true
  attr :state, :any, required: true

  defp diff(%{state: nil} = assigns), do: ~H""

  defp diff(%{state: :loading} = assigns) do
    ~H"""
    <p id={@id} class="font-mono text-xs text-slate-500">fetching diff from the forge…</p>
    """
  end

  defp diff(%{state: {:ok, %{text: text, truncated: truncated} = result}} = assigns) do
    assigns =
      assign(assigns,
        lines: String.split(text, "\n"),
        truncated: truncated,
        base: result.base,
        base_placed: result.base_placed
      )

    ~H"""
    <div id={@id} class="mt-1 overflow-x-auto rounded-md border border-slate-800 bg-slate-900">
      <p id={"#{@id}-base"} class="px-3 py-1 font-mono text-xs text-slate-500">
        against <span class="text-slate-300">{@base}</span>
        <span :if={!@base_placed} class="text-amber-400">
          — this claim recorded no placed base, so this is the source's CURRENT base branch
        </span>
      </p>
      <p :if={@truncated} class="px-3 py-1 font-mono text-xs text-amber-400">
        diff truncated: showing the first part only
      </p>
      <pre class="px-3 py-2 font-mono text-xs leading-5"><span
          :for={line <- @lines}
          class={["block", diff_line_class(line)]}
        >{line}</span></pre>
    </div>
    """
  end

  defp diff(%{state: {:error, reason}} = assigns) do
    assigns = assign(assigns, :reason, diff_error(reason))

    ~H"""
    <p id={@id} class="font-mono text-xs text-rose-400">
      diff unavailable: {@reason}
      <button
        type="button"
        id={"#{@id}-retry"}
        phx-click="load_diff"
        phx-value-id={@checkpoint_id}
        class="ml-2 text-accent-400 hover:text-accent-300"
      >
        retry
      </button>
    </p>
    """
  end

  attr :notice, :any, required: true
  attr :kind, :atom, required: true

  defp notice(%{notice: {kind, status, message}, kind: kind} = assigns) do
    assigns = assign(assigns, status: status, message: message)

    ~H"""
    <p
      id={"#{@kind}-notice"}
      class={[
        "font-mono text-xs",
        @status == :ok && "text-emerald-400",
        @status == :error && "text-rose-400"
      ]}
    >
      {@message}
    </p>
    """
  end

  defp notice(assigns), do: ~H""

  defp diff_error({:no_intake_source, _project}), do: "the project has no intake repository"

  defp diff_error({:ambiguous_intake_source, _project, _count}),
    do: "the project has more than one intake repository"

  defp diff_error({:github_unreachable, _}), do: "the forge did not answer in time"
  defp diff_error({:github_rate_limited, _, _}), do: "the forge is rate limiting; try later"
  defp diff_error({:github_api_error, status}), do: "the forge answered #{status}"
  defp diff_error(_reason), do: "the forge could not be read"

  defp diff_line_class("+++" <> _), do: "text-slate-400"
  defp diff_line_class("---" <> _), do: "text-slate-400"
  defp diff_line_class("+" <> _), do: "text-emerald-400"
  defp diff_line_class("-" <> _), do: "text-rose-400"
  defp diff_line_class("@@" <> _), do: "text-accent-400"
  defp diff_line_class(_line), do: "text-slate-300"

  defp severity_class(:critical), do: "text-rose-400"
  defp severity_class(:high), do: "text-orange-400"
  defp severity_class(:medium), do: "text-amber-400"
  defp severity_class(_severity), do: "text-slate-400"

  defp textarea_class,
    do:
      "block w-full rounded-md border border-slate-800 bg-slate-900 px-3 py-2 font-mono text-sm " <>
        "text-slate-100 placeholder:text-slate-600 focus:border-accent-500 focus:outline-none " <>
        "focus:ring-1 focus:ring-accent-500"

  defp select_class,
    do:
      "block w-full rounded-md border border-slate-800 bg-slate-900 px-3 py-2 font-mono text-sm " <>
        "text-slate-100 focus:border-accent-500 focus:outline-none focus:ring-1 focus:ring-accent-500"

  defp button_class,
    do:
      "w-full rounded-md bg-accent-700 px-4 py-2 text-sm font-medium text-slate-50 " <>
        "transition-colors hover:bg-accent-600"
end
