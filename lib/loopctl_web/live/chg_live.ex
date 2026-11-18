defmodule LoopctlWeb.ChgLive do
  @moduledoc """
  US-50.5 — the chg dashboard: one page that answers the 2026-10-28 chg audit questions, for
  the operator signed in through `LoopctlWeb.LoginLive`.

  It mounts only in the `:operator` live_session, whose `on_mount`
  (`LoopctlWeb.BrowserAuth.on_mount/4`) refuses a socket without a live browser session and
  assigns `:browser_principal`. The tenant every panel reads is that principal's, and nothing
  else: no param, filter or event names a tenant. While the page is open the session is asked
  again every `@revalidate_ms`, so a logout elsewhere, a revoked authenticator or an expired
  session closes the page on the next tick rather than at the next page load.

  The page only reads. Every panel is one `Loopctl.Changes.Dashboard` function on
  `HeavyReadRepo`; a panel with no rows says so, and a panel whose read was shed says that
  instead, without taking the other panels down.

  Filters (repo, host, period) live in the URL, so a filtered view can be linked. A value that
  is not one of the offered options is ignored rather than trusted: `repo` and `host` must be
  among `Dashboard.options/2`, `period` among `@periods`.
  """

  use LoopctlWeb, :live_view

  alias Loopctl.Changes.Dashboard
  alias Loopctl.WebAuthn.BrowserLogin
  alias LoopctlWeb.BrowserAuth

  @periods [{"24h", "Last 24 hours", 1}, {"7d", "Last 7 days", 7}, {"30d", "Last 30 days", 30}]
  @default_period "7d"
  @revalidate_ms 60_000

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Process.send_after(self(), :revalidate, @revalidate_ms)

    {:ok,
     socket
     |> assign(:page_title, "chg dashboard")
     |> assign(:browser_session, session[BrowserAuth.session_key()])
     |> assign(:periods, @periods)
     |> stream_configure(:outcomes, dom_id: &outcome_dom_id/1)
     |> stream(:misses, [])
     |> stream(:flaky, [])
     |> stream(:runner, [])
     |> stream(:outcomes, [])
     |> stream(:attention, [])
     |> stream(:escalated, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tenant_id = socket.assigns.browser_principal.tenant_id
    period = period(params["period"])
    since = DateTime.add(DateTime.utc_now(), -days(period) * 86_400, :second)
    options = Dashboard.options(tenant_id, since)

    filters = %{
      repo: offered(params["repo"], options.repos),
      host: offered(params["host"], options.hosts),
      since: since
    }

    {:noreply,
     socket
     |> assign(:options, options)
     |> assign(:period, period)
     |> assign(:filters, filters)
     |> assign(:filter_form, filter_form(filters, period))
     |> load_panels(tenant_id, filters)}
  end

  @impl true
  def handle_event("filter", %{"filter" => params}, socket) when is_map(params) do
    query =
      params
      |> Map.take(~w(repo host period))
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/chg?#{query}")}
  end

  # The page is behind a session but its events are still client input: anything else is a
  # no-op rather than a crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:revalidate, socket) do
    case BrowserLogin.validate(socket.assigns.browser_session) do
      {:ok, _principal} ->
        Process.send_after(self(), :revalidate, @revalidate_ms)
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Your session ended. Sign in again to continue.")
         |> redirect(to: ~p"/login")}
    end
  end

  @doc """
  The DOM id of a review outcome's row: its repo hex-encoded, then its PR number. Hex keeps the
  id a plain CSS selector AND injective: replacing `/` and `.` with `-` gave `a/b-c` and
  `a-b/c` one id, and a stream with two rows under one id renders one of them.
  """
  @spec outcome_dom_id(%{repo: String.t(), pr_number: pos_integer()}) :: String.t()
  def outcome_dom_id(%{repo: repo, pr_number: n}),
    do: "outcome-" <> Base.encode16(repo, case: :lower) <> "-#{n}"

  defp period(value) do
    if Enum.any?(@periods, fn {key, _label, _days} -> key == value end),
      do: value,
      else: @default_period
  end

  defp days(period) do
    Enum.find_value(@periods, fn {key, _label, days} -> key == period && days end)
  end

  defp offered(value, offered) when is_binary(value) do
    if value in offered, do: value
  end

  defp offered(_value, _offered), do: nil

  defp filter_form(filters, period) do
    to_form(%{"repo" => filters.repo || "", "host" => filters.host || "", "period" => period},
      as: :filter
    )
  end

  defp load_panels(socket, tenant_id, filters) do
    selection = Dashboard.selection(tenant_id, filters)
    flaky = Dashboard.flaky(tenant_id, filters)
    runner = Dashboard.runner_samples(tenant_id, filters)
    reviews = Dashboard.review_outcomes(tenant_id, filters)
    attention = Dashboard.attention(tenant_id, filters)
    findings = Dashboard.findings(tenant_id, filters)

    socket
    |> assign(
      :findings,
      if(findings == :unavailable, do: :unavailable, else: Map.delete(findings, :escalated))
    )
    |> stream(:escalated, list_rows(findings, :escalated), reset: true)
    |> assign(:outcomes_by_day, Dashboard.gate_outcomes(tenant_id, filters))
    |> assign(:fallbacks, Dashboard.fallbacks(tenant_id, filters))
    |> assign(:selection, selection)
    |> assign(:phases, Dashboard.phase_times(tenant_id, filters))
    |> assign(:flaky_state, list_state(flaky))
    |> assign(:runner_state, list_state(runner))
    |> assign(
      :reviews,
      if(reviews == :unavailable, do: :unavailable, else: Map.delete(reviews, :outcomes))
    )
    |> assign(:attention_state, list_state(attention))
    |> stream(:misses, list_rows(selection, :misses), reset: true)
    |> stream(:flaky, list_rows(flaky), reset: true)
    |> stream(:runner, list_rows(runner), reset: true)
    |> stream(:outcomes, list_rows(reviews, :outcomes), reset: true)
    |> stream(:attention, list_rows(attention), reset: true)
  end

  defp list_state(:unavailable), do: :unavailable
  defp list_state(rows), do: length(rows)

  defp list_rows(:unavailable), do: []
  defp list_rows(rows), do: rows

  defp list_rows(:unavailable, _key), do: []
  defp list_rows(data, key), do: Map.fetch!(data, key)

  @impl true
  def render(assigns) do
    ~H"""
    <section class="mx-auto w-full max-w-6xl px-4 py-8 sm:px-6" id="chg-dashboard">
      <header class="mb-6 flex flex-wrap items-start justify-between gap-4 border-b border-slate-800 pb-4">
        <div class="min-w-0">
          <h1 class="font-display text-xl font-semibold text-slate-100">chg dashboard</h1>
          <p class="mt-1 text-sm text-slate-400">
            Gate outcomes, selection, phase times, flaky tests, review outcomes and flagged changes
            from the fleet's chg ledger.
          </p>
          <p class="mt-1 truncate font-mono text-xs text-slate-500" id="chg-tenant">
            tenant {@browser_principal.tenant_id}
          </p>
        </div>
        <.link
          href={~p"/logout"}
          method="delete"
          id="chg-logout"
          class="rounded-md border border-slate-700 px-3 py-1.5 font-mono text-xs uppercase tracking-wide text-slate-300 transition-colors hover:border-slate-600 hover:text-slate-100 focus:outline-none focus:ring-2 focus:ring-accent-500"
        >
          Sign out
        </.link>
      </header>

      <.form
        for={@filter_form}
        id="chg-filters"
        phx-change="filter"
        class="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-3"
      >
        <.filter_select
          id="chg-filter-repo"
          label="Repo"
          field={@filter_form[:repo]}
          options={[{"All repos", ""} | Enum.map(@options.repos, &{&1, &1})]}
        />
        <.filter_select
          id="chg-filter-host"
          label="Host"
          field={@filter_form[:host]}
          options={[{"All hosts", ""} | Enum.map(@options.hosts, &{&1, &1})]}
        />
        <.filter_select
          id="chg-filter-period"
          label="Period"
          field={@filter_form[:period]}
          options={Enum.map(@periods, fn {key, label, _days} -> {label, key} end)}
        />
      </.form>

      <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <.panel id="panel-gate-outcomes" title="Gate outcomes" class="lg:col-span-2">
          <.unavailable :if={@outcomes_by_day == :unavailable} />
          <.empty :if={@outcomes_by_day == []} text="No chg or gate rows in this range." />
          <div :if={is_list(@outcomes_by_day) and @outcomes_by_day != []} class="overflow-x-auto">
            <table class="w-full text-sm">
              <thead class="border-b border-slate-700 text-left font-mono text-xs uppercase tracking-wider text-slate-500">
                <tr>
                  <th class="px-2 py-2">Day</th>
                  <th class="px-2 py-2">Kind</th>
                  <th :for={verdict <- Dashboard.verdicts()} class="px-2 py-2 text-right">
                    {verdict}
                  </th>
                  <th class="px-2 py-2 text-right">Total</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- @outcomes_by_day}
                  id={"gate-outcome-#{row.day}-#{row.kind}"}
                  class="border-b border-slate-800/60"
                >
                  <td class="whitespace-nowrap px-2 py-1.5 font-mono text-slate-300">{row.day}</td>
                  <td class="px-2 py-1.5 font-mono text-slate-400">{row.kind}</td>
                  <td
                    :for={verdict <- Dashboard.verdicts()}
                    class={[
                      "px-2 py-1.5 text-right font-mono",
                      verdict_class(verdict, row.counts[verdict])
                    ]}
                  >
                    {number(row.counts[verdict] || 0)}
                  </td>
                  <td class="px-2 py-1.5 text-right font-mono text-slate-300">{number(row.total)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.panel>

        <.panel id="panel-fallbacks" title="Fallback rate">
          <.unavailable :if={@fallbacks == :unavailable} />
          <.empty
            :if={is_map(@fallbacks) and @fallbacks.checks == 0}
            text="No chg checks in this range."
          />
          <div :if={is_map(@fallbacks) and @fallbacks.checks > 0} class="space-y-3">
            <p class="font-mono text-sm text-slate-300">
              <span id="fallback-rate" class="text-lg text-slate-100">
                {percent(@fallbacks.rate)}
              </span>
              <span class="text-slate-500">
                · {number(@fallbacks.fallbacks)} of {number(@fallbacks.checks)} checks ran mode all
              </span>
            </p>
            <ul :if={@fallbacks.reasons != []} class="space-y-1.5" id="fallback-reasons">
              <li :for={r <- @fallbacks.reasons} class="flex gap-3 text-xs">
                <span class="w-10 shrink-0 text-right font-mono text-slate-300">
                  {number(r.count)}
                </span>
                <span class="min-w-0 break-words text-slate-400">
                  {blank(r.reason, "no reason given")}
                </span>
              </li>
            </ul>
          </div>
        </.panel>

        <.panel id="panel-selection" title="Selection quality">
          <.unavailable :if={@selection == :unavailable} />
          <.empty
            :if={is_map(@selection) and @selection.checks == 0}
            text="No selecting chg checks in this range."
          />
          <div :if={is_map(@selection) and @selection.checks > 0} class="space-y-3">
            <dl class="grid grid-cols-2 gap-x-4 gap-y-2 font-mono text-sm sm:grid-cols-4">
              <.stat label="checks" value={number(@selection.checks)} id="selection-checks" />
              <.stat label="mean selected" value={decimal(@selection.mean_selected)} />
              <.stat label="max selected" value={number(@selection.max_selected)} />
              <.stat label="mean floor" value={decimal(@selection.mean_floor)} />
            </dl>
            <p class="text-xs text-slate-500">
              A miss is a chg check that passed on a commit whose gate failed.
            </p>
            <ul id="selection-misses" phx-update="stream" class="space-y-1">
              <li id="misses-empty" class="hidden text-xs text-slate-500 only:block">
                No misses in this range.
              </li>
              <li
                :for={{dom_id, miss} <- @streams.misses}
                id={dom_id}
                class="flex flex-wrap gap-x-3 text-xs"
              >
                <span class="font-mono text-rose-400">{short_sha(miss.sha)}</span>
                <span class="font-mono text-slate-400">{miss.repo}</span>
                <span class="font-mono text-slate-500">{miss.host}</span>
                <span class="font-mono text-slate-500">{timestamp(miss.at)}</span>
              </li>
            </ul>
          </div>
        </.panel>

        <.panel id="panel-phases" title="Time per gate phase" class="lg:col-span-2">
          <.unavailable :if={@phases == :unavailable} />
          <.empty
            :if={is_list(@phases) and Enum.all?(@phases, &(&1.rows == 0))}
            text="No chg rows carry phase times in this range."
          />
          <div :if={is_list(@phases) and Enum.any?(@phases, &(&1.rows > 0))} class="overflow-x-auto">
            <table class="w-full text-sm">
              <thead class="border-b border-slate-700 text-left font-mono text-xs uppercase tracking-wider text-slate-500">
                <tr>
                  <th class="px-2 py-2">Phase</th>
                  <th class="px-2 py-2 text-right">Rows</th>
                  <th class="px-2 py-2 text-right">Mean ms</th>
                  <th class="px-2 py-2 text-right">Max ms</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={p <- @phases}
                  :if={p.rows > 0}
                  id={"phase-#{p.phase}"}
                  class="border-b border-slate-800/60"
                >
                  <td class="px-2 py-1.5 font-mono text-slate-300">{p.phase}</td>
                  <td class="px-2 py-1.5 text-right font-mono text-slate-400">{number(p.rows)}</td>
                  <td class="px-2 py-1.5 text-right font-mono text-slate-300">
                    {decimal(p.mean_ms)}
                  </td>
                  <td class="px-2 py-1.5 text-right font-mono text-slate-300">{number(p.max_ms)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.panel>

        <.panel id="panel-flaky" title="Flaky tests">
          <.unavailable :if={@flaky_state == :unavailable} />
          <ul :if={@flaky_state != :unavailable} id="flaky-list" phx-update="stream" class="space-y-2">
            <li id="flaky-empty" class="hidden text-sm text-slate-500 only:block">
              No flaky tests reported in this range.
            </li>
            <li :for={{dom_id, f} <- @streams.flaky} id={dom_id} class="space-y-0.5 text-xs">
              <p class="break-all font-mono text-slate-200">{blank(f.test, "unnamed test")}</p>
              <p class="flex flex-wrap gap-x-3 font-mono text-slate-500">
                <span>{f.host}</span>
                <span>{timestamp(f.at)}</span>
                <span :if={f.quarantine} class="text-amber-400">quarantine {f.quarantine}</span>
                <span :if={f.issue} class="text-accent-400">issue {f.issue}</span>
              </p>
            </li>
          </ul>
        </.panel>

        <.panel id="panel-runner" title="Runner samples">
          <.unavailable :if={@runner_state == :unavailable} />
          <ul
            :if={@runner_state != :unavailable}
            id="runner-list"
            phx-update="stream"
            class="space-y-2"
          >
            <li id="runner-empty" class="hidden text-sm text-slate-500 only:block">
              No runner samples in this range.
            </li>
            <li :for={{dom_id, s} <- @streams.runner} id={dom_id} class="space-y-0.5 text-xs">
              <p class="flex flex-wrap gap-x-3 font-mono">
                <span class="text-accent-400">{s.host}</span>
                <span class="text-slate-500">{timestamp(s.at)}</span>
                <span :if={s.ms} class="text-slate-300">{number(s.ms)} ms</span>
              </p>
              <p :if={s.fields != []} class="break-all font-mono text-slate-500">
                {Enum.map_join(s.fields, " · ", fn {k, v} -> "#{k}=#{v}" end)}
              </p>
            </li>
          </ul>
        </.panel>

        <.panel id="panel-reviews" title="Review outcomes" class="lg:col-span-2">
          <.unavailable :if={@reviews == :unavailable} />
          <div :if={@reviews != :unavailable} class="space-y-3">
            <div class="flex flex-wrap gap-x-6 gap-y-2 font-mono text-xs">
              <p id="reviews-without-round" class="text-slate-400">
                merged without a counted round:
                <span class={[
                  @reviews.without_round > 0 && "text-rose-400",
                  @reviews.without_round == 0 && "text-slate-300"
                ]}>
                  {number(@reviews.without_round)}
                </span>
              </p>
              <p :if={@reviews.by_severity != %{}} id="reviews-by-severity" class="text-slate-500">
                severity: {counts_line(@reviews.by_severity)}
              </p>
              <p
                :if={@reviews.by_disposition != %{}}
                id="reviews-by-disposition"
                class="text-slate-500"
              >
                disposition: {counts_line(@reviews.by_disposition)}
              </p>
            </div>
            <ul id="review-outcomes" phx-update="stream" class="divide-y divide-slate-800/60">
              <li id="outcomes-empty" class="hidden py-2 text-sm text-slate-500 only:block">
                No merged PRs recorded in this range.
              </li>
              <li
                :for={{dom_id, o} <- @streams.outcomes}
                id={dom_id}
                class="flex flex-wrap items-center gap-x-3 gap-y-1 py-2 text-xs"
              >
                <span class="font-mono text-slate-200">{o.repo}#{o.pr_number}</span>
                <span class="font-mono text-slate-500">{timestamp(o.merged_at)}</span>
                <span class="font-mono text-slate-400">{number(o.rounds)} round(s)</span>
                <span class="font-mono text-slate-400">{length(o.findings)} finding(s)</span>
                <span
                  :if={o.merged_without_counted_round}
                  class="inline-flex items-center rounded-sm bg-rose-950 px-2 py-0.5 font-mono text-xs font-medium text-rose-300"
                >
                  no counted round
                </span>
                <span
                  :if={!o.has_review_section}
                  class="inline-flex items-center rounded-sm bg-slate-800 px-2 py-0.5 font-mono text-xs font-medium text-slate-400"
                >
                  no findings section
                </span>
              </li>
            </ul>
          </div>
        </.panel>

        <.panel id="panel-attention" title="Changes flagged gap or stale" class="lg:col-span-2">
          <.unavailable :if={@attention_state == :unavailable} />
          <ul
            :if={@attention_state != :unavailable}
            id="attention-list"
            phx-update="stream"
            class="divide-y divide-slate-800/60"
          >
            <li id="attention-empty" class="hidden py-2 text-sm text-slate-500 only:block">
              No change is flagged.
            </li>
            <li
              :for={{dom_id, c} <- @streams.attention}
              id={dom_id}
              class="flex flex-wrap items-center gap-x-3 gap-y-1 py-2 text-xs"
            >
              <span class={[
                "inline-flex items-center rounded-sm px-2 py-0.5 font-mono font-medium",
                c.attention == "gap" && "bg-amber-950 text-amber-300",
                c.attention != "gap" && "bg-slate-800 text-slate-300"
              ]}>
                {c.attention}
              </span>
              <span class="font-mono text-slate-200">{c.repo}</span>
              <span class="break-all font-mono text-slate-400">{c.change_id}</span>
              <span class="font-mono text-slate-500">applied seq {c.applied_seq}</span>
              <span class="font-mono text-slate-500">flagged {timestamp(c.attention_at)}</span>
              <span class="font-mono text-slate-500">last event {timestamp(c.last_event_at)}</span>
            </li>
          </ul>
        </.panel>

        <.panel id="panel-findings" title="Feedback loop findings" class="lg:col-span-2">
          <.unavailable :if={@findings == :unavailable} />
          <div :if={@findings != :unavailable} class="space-y-3">
            <dl id="findings-by-state" class="flex flex-wrap gap-x-4 gap-y-1 text-xs">
              <div :for={state <- ~w(queued filed fixed closed escalated)} class="flex gap-1">
                <dt class="font-mono text-slate-500">{state}</dt>
                <dd class="font-mono text-slate-200">{Map.get(@findings.by_state, state, 0)}</dd>
              </div>
            </dl>
            <dl id="findings-by-kind" class="flex flex-wrap gap-x-4 gap-y-1 text-xs">
              <div :for={{kind, n} <- Enum.sort(@findings.by_kind)} class="flex gap-1">
                <dt class="font-mono text-slate-500">{kind}</dt>
                <dd class="font-mono text-slate-200">{n}</dd>
              </div>
            </dl>
            <ul id="escalated-list" phx-update="stream" class="divide-y divide-slate-800/60">
              <li id="escalated-empty" class="hidden py-2 text-sm text-slate-500 only:block">
                No finding is escalated.
              </li>
              <li
                :for={{dom_id, f} <- @streams.escalated}
                id={dom_id}
                class="flex flex-wrap items-center gap-x-3 gap-y-1 py-2 text-xs"
              >
                <span class="inline-flex items-center rounded-sm bg-amber-950 px-2 py-0.5 font-mono font-medium text-amber-300">
                  {f.kind}
                </span>
                <span class="font-mono text-slate-200">{f.repo}</span>
                <span :if={f.issue_number} class="font-mono text-slate-400">#{f.issue_number}</span>
                <span class="font-mono text-slate-500">
                  seen {f.occurrences}, fixes {f.fix_attempts}
                </span>
                <span class="font-mono text-slate-500">escalated {timestamp(f.escalated_at)}</span>
                <span class="w-full text-slate-400">{f.reason}</span>
              </li>
            </ul>
          </div>
        </.panel>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  defp panel(assigns) do
    ~H"""
    <section
      id={@id}
      class={["min-w-0 rounded-md border border-slate-800 bg-slate-900/60 p-4", @class]}
    >
      <h2 class="mb-3 font-mono text-xs font-medium uppercase tracking-wider text-slate-400">
        {@title}
      </h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :text, :string, required: true

  defp empty(assigns) do
    ~H"""
    <p class="empty-state text-sm text-slate-500">{@text}</p>
    """
  end

  defp unavailable(assigns) do
    ~H"""
    <p class="unavailable-state text-sm text-amber-400">
      This panel could not be read right now (the read pool is busy). Reload to try again.
    </p>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :id, :string, default: nil

  defp stat(assigns) do
    ~H"""
    <div>
      <dt class="text-xs text-slate-500">{@label}</dt>
      <dd id={@id} class="text-slate-100">{@value}</dd>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :field, Phoenix.HTML.FormField, required: true
  attr :options, :list, required: true

  defp filter_select(assigns) do
    ~H"""
    <label for={@id} class="block">
      <span class="mb-1 block font-mono text-xs uppercase tracking-wider text-slate-500">
        {@label}
      </span>
      <select
        id={@id}
        name={@field.name}
        class="w-full rounded-sm border border-slate-700 bg-slate-900 px-2 py-1.5 font-mono text-sm text-slate-200 focus:border-accent-500 focus:outline-none focus:ring-2 focus:ring-accent-500"
      >
        {Phoenix.HTML.Form.options_for_select(@options, @field.value)}
      </select>
    </label>
    """
  end

  defp verdict_class(_verdict, nil), do: "text-slate-600"
  defp verdict_class("pass", _n), do: "text-emerald-400"
  defp verdict_class("fail", _n), do: "text-rose-400"
  defp verdict_class("error", _n), do: "text-amber-400"
  defp verdict_class(_verdict, _n), do: "text-slate-400"

  defp number(nil), do: "–"

  defp number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp decimal(nil), do: "–"
  # One decimal place, with the integer part grouped like `number/1`, so a mean sits beside
  # its max in the same shape (`24,500.0` next to `29,000`).
  defp decimal(f) when is_float(f) do
    [whole, frac] = f |> :erlang.float_to_binary(decimals: 1) |> String.split(".")
    number(String.to_integer(whole)) <> "." <> frac
  end

  defp percent(nil), do: "–"
  defp percent(f), do: :erlang.float_to_binary(f * 100, decimals: 1) <> "%"

  defp short_sha(nil), do: "–"
  defp short_sha(sha), do: String.slice(sha, 0, 12)

  defp timestamp(nil), do: "–"
  defp timestamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%MZ")

  defp blank(nil, fallback), do: fallback
  defp blank("", fallback), do: fallback
  defp blank(value, _fallback), do: value

  defp counts_line(counts) do
    counts |> Enum.sort() |> Enum.map_join(" · ", fn {k, n} -> "#{k} #{n}" end)
  end
end
