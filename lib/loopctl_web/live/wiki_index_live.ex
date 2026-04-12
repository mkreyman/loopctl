defmodule LoopctlWeb.WikiIndexLive do
  @moduledoc """
  US-26.0.3 — Public wiki index listing all system articles.

  Displays system articles grouped by category with keyword search.
  No authentication required.
  """

  use LoopctlWeb, :live_view

  alias Loopctl.Knowledge

  @impl true
  def mount(_params, _session, socket) do
    grouped = Knowledge.list_system_articles_grouped()

    {:ok,
     socket
     |> assign(:page_title, "loopctl Wiki")
     |> assign(:grouped_articles, grouped)
     |> assign(:search_query, "")
     |> assign(:search_results, nil)
     |> assign(:category_order, [:convention, :pattern, :decision, :finding, :reference])}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) when byte_size(query) > 0 do
    results =
      Knowledge.list_system_articles()
      |> Enum.filter(fn a ->
        String.contains?(String.downcase(a.title), String.downcase(query)) or
          String.contains?(String.downcase(a.body || ""), String.downcase(query))
      end)

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:search_results, results)}
  end

  def handle_event("search", _params, socket) do
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> assign(:search_results, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="mx-auto w-full max-w-4xl px-6 py-16" id="wiki-index">
      <header class="mb-8">
        <h1 class="font-display text-2xl font-semibold text-slate-100">loopctl Wiki</h1>
        <p class="mt-2 text-sm text-slate-400">
          Canonical documentation for the loopctl trust model, custody protocol, and agent lifecycle.
        </p>
      </header>

      <form phx-change="search" class="mb-8" id="wiki-search-form">
        <input
          type="text"
          name="q"
          value={@search_query}
          placeholder="Search articles..."
          class="w-full rounded-md border border-slate-700 bg-slate-900 px-4 py-2 font-mono text-sm text-slate-200 placeholder-slate-500 focus:border-accent-500 focus:outline-none focus:ring-1 focus:ring-accent-500"
          autocomplete="off"
          phx-debounce="300"
        />
      </form>

      <%= if @search_results do %>
        <div id="search-results" class="space-y-3">
          <h2 class="font-mono text-xs uppercase tracking-wide text-slate-500">
            {length(@search_results)} result(s) for "{@search_query}"
          </h2>
          <div
            :for={article <- @search_results}
            class="rounded-md border border-slate-800 bg-slate-900/60 p-4"
          >
            <.link
              navigate={~p"/wiki/#{article.slug}"}
              class="text-accent-400 hover:text-accent-300 font-display text-sm"
            >
              {article.title}
            </.link>
            <span class="ml-2 font-mono text-xs text-slate-500">{article.category}</span>
          </div>
          <p :if={@search_results == []} class="text-sm text-slate-500">
            No articles match your search.
          </p>
        </div>
      <% else %>
        <div id="wiki-categories" class="space-y-8">
          <%= for category <- @category_order, articles = Map.get(@grouped_articles, category, []), articles != [] do %>
            <section id={"category-#{category}"}>
              <h2 class="mb-3 font-mono text-xs font-semibold uppercase tracking-wide text-slate-400">
                {category}
              </h2>
              <ul class="space-y-2">
                <li :for={article <- articles} class="flex items-center gap-3">
                  <.link
                    navigate={~p"/wiki/#{article.slug}"}
                    class="text-accent-400 hover:text-accent-300 text-sm"
                  >
                    {article.title}
                  </.link>
                </li>
              </ul>
            </section>
          <% end %>
          <p :if={@grouped_articles == %{}} class="text-sm text-slate-500">
            No system articles published yet.
          </p>
        </div>
      <% end %>
    </section>
    """
  end
end
