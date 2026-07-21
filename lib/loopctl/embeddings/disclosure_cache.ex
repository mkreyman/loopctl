defmodule Loopctl.Embeddings.DisclosureCache do
  @moduledoc """
  US-41.1 (review) — a tiny, supervised, TTL'd ETS cache for the semantic-search
  DISCLOSURE meta (`system_corpus_*` + `reembed_*`).

  ## Why this exists

  `Loopctl.Knowledge.search_semantic/3` merges `Embeddings.system_corpus_meta/2` and
  `Embeddings.reembed_meta/2` into EVERY semantic response. In the STEADY state those
  are three round trips that always answer the same thing:

    * `system_corpus_meta/2` runs an anti-join over every `scope: :system` article
      with a per-row index probe into `article_embeddings`. Fully materialized, NO row
      qualifies — so the `LIMIT 1` short-circuit never fires and the cost grows
      linearly with loopctl's own canonical wiki corpus, on the hottest read in the
      product;
    * `reembed_meta/2` adds two more `exists?` probes.

  The answer only changes when the materialization worker runs, a system article is
  added/published, or a re-embed makes progress — none of which is request-driven.
  A short TTL therefore removes the per-request cost while bounding staleness to the
  TTL (a disclosure string, never a result-set predicate).

  ## The table is OWNED by this process

  An ETS table dies with its creator. Created lazily by a web request it would vanish
  when that request finished and crash a peer mid-lookup. This GenServer owns it for
  the node's lifetime — the same pattern as `Loopctl.Knowledge.EmbeddingCircuitBreaker`.

  ## Disabling

  `config :loopctl, :embedding_disclosure_cache_ms, 0` disables caching entirely
  (config-based DI — `config/test.exs` sets 0 so tests observe disclosure changes
  immediately, with no `Application.put_env` anywhere).
  """

  use GenServer

  @table :loopctl_embedding_disclosure_cache
  @default_ttl_ms 5_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ok = init_table()
    {:ok, %{}}
  end

  @doc false
  @spec init_table() :: :ok
  def init_table do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
      rescue
        ArgumentError -> :already_exists
      end
    end

    :ok
  end

  @doc "The cache TTL in milliseconds; `0` disables caching."
  @spec ttl_ms() :: non_neg_integer()
  def ttl_ms, do: Application.get_env(:loopctl, :embedding_disclosure_cache_ms, @default_ttl_ms)

  @doc """
  Returns the cached value for `key`, or computes it with `fun`, caches it and
  returns it. With a `0` TTL `fun` is always called and nothing is stored.
  """
  @spec fetch(term(), (-> value)) :: value when value: term()
  def fetch(key, fun) when is_function(fun, 0) do
    case ttl_ms() do
      0 -> fun.()
      ttl -> cached_fetch(key, fun, ttl)
    end
  end

  @doc "Drops every cached entry (used by the operator levers that invalidate a disclosure)."
  @spec flush() :: :ok
  def flush do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  defp cached_fetch(key, fun, ttl) do
    now = System.monotonic_time(:millisecond)

    case lookup(key, now) do
      {:ok, value} ->
        value

      :miss ->
        value = fun.()
        store(key, value, now + ttl)
        value
    end
  end

  defp lookup(key, now) do
    if :ets.whereis(@table) == :undefined do
      :miss
    else
      case :ets.lookup(@table, key) do
        [{^key, value, expires_at}] when expires_at > now -> {:ok, value}
        _ -> :miss
      end
    end
  end

  # A best-effort write: if the owner restarted between the lookup and the insert the
  # table may be momentarily absent, and a caching miss must never fail a search.
  defp store(key, value, expires_at) do
    :ets.insert(@table, {key, value, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end
end
