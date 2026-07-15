defmodule Loopctl.AuditChain do
  @moduledoc """
  US-26.1.1 — Context module for the hash-chained, append-only audit log.

  Every custody-critical event is recorded as a chain entry with a SHA-256
  hash linking it to the previous entry. DB triggers enforce immutability
  (no updates, no deletes) and chain integrity (sequential positions,
  correct prev_entry_hash).

  ## Usage

      Loopctl.AuditChain.append(tenant_id, %{
        action: "story_claimed",
        actor_lineage: ["dispatch-id-1"],
        entity_type: "story",
        entity_id: story_id,
        payload: %{"title" => "..."}
      })
  """

  import Bitwise
  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain.Entry
  alias Loopctl.AuditChain.PubSub, as: ChainPubSub
  alias Loopctl.AuditChain.SignedTreeHead
  alias Loopctl.AuditChain.SthCheckpoint
  alias Loopctl.HeavyRead
  alias Loopctl.TenantKeys

  @zero_hash :binary.copy(<<0>>, 32)

  @doc """
  Appends a new entry to a tenant's audit chain.

  Computes chain_position, prev_entry_hash, and entry_hash. Uses
  SELECT...FOR UPDATE to serialize concurrent appends within the
  same tenant.

  ## Parameters

  - `tenant_id` — the tenant UUID
  - `attrs` — map with:
    - `:action` (required) — event type string
    - `:actor_lineage` (required) — list of dispatch/key IDs
    - `:entity_type` (required) — entity type string
    - `:entity_id` (optional) — entity UUID
    - `:payload` (required) — event details as a map

  ## Returns

  - `{:ok, %Entry{}}` on success
  - `{:error, reason}` on failure
  """
  @spec append(Ecto.UUID.t(), map()) :: {:ok, Entry.t()} | {:error, term()}
  def append(tenant_id, attrs) when is_binary(tenant_id) and is_map(attrs) do
    now = DateTime.utc_now()

    multi =
      Multi.new()
      |> Multi.run(:lock_and_read, fn _repo, _changes ->
        lock_and_read_previous(tenant_id)
      end)
      |> Multi.run(:insert_entry, fn _repo, %{lock_and_read: {position, prev_hash}} ->
        entry_attrs = build_entry_attrs(tenant_id, position, prev_hash, attrs, now)

        %Entry{tenant_id: tenant_id}
        |> Entry.changeset(entry_attrs)
        |> AdminRepo.insert()
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{insert_entry: entry}} ->
        # US-26.5.1: broadcast new entry to the tenant's per-tenant subscribers.
        ChainPubSub.broadcast_entry(tenant_id, entry)
        # US-35.2: ALSO broadcast a MINIMAL tenant-scoped notification to the
        # fixed cross-tenant firehose so the supervised SthEnqueuer can
        # activity-gate STH computation. Only entry.tenant_id crosses this shared
        # topic (never the entry payload/actor_lineage). Additive and
        # fire-and-forget — it never changes or gates the existing per-tenant
        # broadcast, and a firehose delivery fault never affects the append.
        ChainPubSub.broadcast_entry_firehose(entry)
        {:ok, entry}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Lists audit chain entries for a tenant with pagination.

  ## Options

  - `:limit` — max entries (default 50, max 100)
  - `:offset` — skip N entries (default 0)
  - `:action` — filter by action type

  ## Returns

  `%{data: [Entry.t()], meta: %{total_count, limit, offset}}`
  """
  @spec list_entries(Ecto.UUID.t(), keyword()) :: %{
          data: [Entry.t()],
          meta: %{total_count: non_neg_integer(), limit: pos_integer(), offset: non_neg_integer()}
        }
  def list_entries(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(100)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    base =
      from(e in Entry,
        where: e.tenant_id == ^tenant_id,
        order_by: [asc: e.chain_position]
      )

    base =
      case Keyword.get(opts, :action) do
        nil -> base
        action -> from(e in base, where: e.action == ^action)
      end

    total_count = AdminRepo.aggregate(base, :count, :id)

    entries =
      base
      |> limit(^limit)
      |> offset(^offset)
      |> AdminRepo.all()

    %{data: entries, meta: %{total_count: total_count, limit: limit, offset: offset}}
  end

  @doc """
  Returns the latest entry for a tenant (the chain head).
  """
  @spec latest_entry(Ecto.UUID.t()) :: Entry.t() | nil
  def latest_entry(tenant_id) do
    from(e in Entry,
      where: e.tenant_id == ^tenant_id,
      order_by: [desc: e.chain_position],
      limit: 1
    )
    |> AdminRepo.one()
  end

  # --- STH functions ---

  @doc """
  Computes the SHA-256 merkle root of all entry_hashes for a tenant's chain.
  Returns `{:ok, merkle_root_bytes}` or `{:ok, nil}` if the chain is empty.
  """
  @spec compute_merkle_root(Ecto.UUID.t()) :: {:ok, binary() | nil}
  def compute_merkle_root(tenant_id) do
    hashes =
      from(e in Entry,
        where: e.tenant_id == ^tenant_id,
        order_by: [asc: e.chain_position],
        select: e.entry_hash
      )
      |> AdminRepo.all()

    case hashes do
      [] -> {:ok, nil}
      _ -> {:ok, merkle_tree(hashes)}
    end
  end

  @doc """
  US-35.1 — Incremental Merkle root: byte-identical to `compute_merkle_root/1`.

  Computes the tenant's current Merkle root using the persisted checkpoint of
  stable peaks, loading ONLY entries with `chain_position` above the checkpoint
  (a bounded, tenant-scoped, statement-timeout-guarded read via
  `Loopctl.HeavyRead`) and folding them into those peaks. Returns the root AND
  the refreshed checkpoint data (`%{chain_position, peaks}`) so the caller can
  persist it atomically with the STH it signs.

  Falls back to a correct FULL rebuild — over `compute_merkle_root/1`'s oracle
  construction — whenever there is no checkpoint, or the checkpoint is stale /
  structurally inconsistent with the actual chain (AC-35.1.1 / AC-35.1.5). The
  checkpoint is a pure performance cache: a STRUCTURAL inconsistency (position
  ahead of the head, wrong peak count, non-32-byte peak) degrades to a correct
  root, never a wrong one.

  ## Trust boundary — checkpoint peaks are re-derived against the signed STH

  Validation is two-layered. `valid_checkpoint?/2` first rejects a STRUCTURALLY
  impossible checkpoint (position ahead of the head, wrong peak count, non-32-byte
  peak). Then `checkpoint_root_matches_sth?/2` performs a CHEAP EXACT
  content-integrity check IN-BAND before the peaks are ever folded into a signed
  root: the checkpoint at `cp_pos` is always co-written with the STH at `cp_pos`
  (whose `merkle_root` is retained in `audit_signed_tree_heads`), so we rehydrate
  the cached peaks, bag them, and require the result to equal that stored,
  independently-derived root. A checkpoint with the right peak count and 32-byte
  peaks but WRONG bytes (bit-rot, a bad write, or a direct write to
  `audit_sth_checkpoints` by anyone WITHOUT the tenant signing key) therefore
  FAILS this check and degrades to a correct full rebuild — the legitimate signer
  never signs a wrong root off a corrupt cache. This upholds the "never emit a
  wrong root" invariant in-band; it does NOT replace the out-of-band L6
  divergent-STH byzantine/custody-halt detection, which still guards against a
  corruption of the STH root itself. The check costs one indexed STH lookup plus
  O(log n) hashing — still O(Δ), dominated by the tail read it precedes.

  ## Returns

  - `{:ok, root_bytes, %{chain_position: pos, peaks: [binary]}}` for a non-empty chain
  - `{:ok, nil, nil}` for an empty chain
  """
  @spec compute_merkle_root_incremental(Ecto.UUID.t()) ::
          {:ok, binary(), %{chain_position: non_neg_integer(), peaks: [binary()]}}
          | {:ok, nil, nil}
  def compute_merkle_root_incremental(tenant_id) when is_binary(tenant_id) do
    case latest_entry(tenant_id) do
      nil ->
        {:ok, nil, nil}

      %Entry{chain_position: latest_pos} ->
        case load_valid_checkpoint(tenant_id, latest_pos) do
          {:ok, %SthCheckpoint{chain_position: cp_pos, peaks: cp_peaks}} ->
            incremental_root(tenant_id, latest_pos, cp_pos, cp_peaks)

          :fallback ->
            full_rebuild_root(tenant_id, latest_pos)
        end
    end
  end

  # Incremental path: fold ONLY the tail (positions above the checkpoint) into
  # the checkpoint's stable peaks. When the checkpoint is already at the head
  # (no tail) the peaks are bagged directly.
  defp incremental_root(tenant_id, latest_pos, cp_pos, cp_peaks) do
    peaks0 = peaks_with_heights(cp_peaks, cp_pos + 1)

    tail_hashes =
      if latest_pos > cp_pos do
        load_tail_hashes(tenant_id, cp_pos, latest_pos)
      else
        []
      end

    peaks = mmr_append_all(peaks0, tail_hashes)
    root = bag_peaks(peaks)
    {:ok, root, %{chain_position: latest_pos, peaks: peak_hashes(peaks)}}
  end

  # Whole-chain rebuild page size. Each keyset page is ONE bounded HeavyRead
  # statement, so no single statement's cost grows with total chain length.
  @rebuild_page_size 10_000

  # Fallback: rebuild from the whole chain. `root` is the oracle
  # `merkle_tree/2` construction (byte-identical guarantee); the peaks are folded
  # from the same load so a fresh checkpoint can be persisted for next time.
  #
  # This is the O(n) whole-chain read that fires for EVERY tenant on its first STH
  # after deploy (no checkpoint yet) and on any checkpoint loss/corruption — the
  # heaviest read on this path. It is KEYSET-PAGED (`load_all_hashes_paged/2`): each
  # page is a separate bounded, tenant-scoped, `SET LOCAL statement_timeout`-guarded
  # `HeavyRead` statement of at most `@rebuild_page_size` rows, so a very large chain
  # can NEVER trip a self-reinforcing STH lockout — the failure mode where a single
  # unbounded whole-chain read exceeds the pool statement_timeout, aborts the sign
  # job forever, and so never persists the first checkpoint that would shrink the
  # read. (On master this read went un-timed via `AdminRepo` and always completed;
  # routing it through the timed `HeavyRead` path without paging would reintroduce
  # exactly that lockout for the large-chain tenant #350 / epic 35 exist to help.)
  # Paging across transactions is safe because `audit_chain` is append-only and
  # immutable (DB triggers forbid update/delete), so the [0..latest_pos] prefix is a
  # stable, gap-free snapshot regardless of how many statements read it.
  defp full_rebuild_root(tenant_id, latest_pos) do
    hashes = load_all_hashes_paged(tenant_id, latest_pos)

    root = merkle_tree(hashes)
    peaks = mmr_append_all([], hashes)
    {:ok, root, %{chain_position: latest_pos, peaks: peak_hashes(peaks)}}
  end

  # Reads entry_hashes for [0..latest_pos] ascending in bounded keyset pages, each a
  # single `HeavyRead` statement (tenant-scoped, timeout-guarded). Bounded by
  # `latest_pos` (the head read a moment ago) so a concurrent append can't pull
  # leaves beyond the position we're about to sign. Like the tail read, the
  # `:sth_incremental` endpoint is PRIMARY-PINNED (US-38.1), so every page reads the
  # PRIMARY — never a lagging replica that could truncate the rebuilt prefix.
  defp load_all_hashes_paged(tenant_id, latest_pos) do
    load_all_hashes_paged(tenant_id, latest_pos, -1, [])
  end

  defp load_all_hashes_paged(tenant_id, latest_pos, after_pos, acc) do
    query =
      from(e in Entry,
        where:
          e.tenant_id == ^tenant_id and e.chain_position > ^after_pos and
            e.chain_position <= ^latest_pos,
        order_by: [asc: e.chain_position],
        limit: ^@rebuild_page_size,
        select: {e.chain_position, e.entry_hash}
      )

    case HeavyRead.all(tenant_id, query, HeavyRead.opts(:sth_incremental)) do
      [] ->
        Enum.reverse(acc)

      rows ->
        {last_pos, _} = List.last(rows)
        acc = Enum.reduce(rows, acc, fn {_pos, hash}, a -> [hash | a] end)

        if length(rows) < @rebuild_page_size do
          Enum.reverse(acc)
        else
          load_all_hashes_paged(tenant_id, latest_pos, last_pos, acc)
        end
    end
  end

  # Bounded, tenant-scoped tail read: entries strictly above the checkpoint
  # position, up to and INCLUDING the chain head read a moment ago (`latest_pos`)
  # so a concurrent append can't fold in leaves beyond the position we sign.
  # Ordered ascending. Routed through `HeavyRead` so it runs under a per-query
  # `SET LOCAL statement_timeout` (pgbouncer-safe) and its structural guard proves
  # the `tenant_id` predicate is present (AC-35.1.6).
  #
  # US-38.1 CONSISTENCY: the `:sth_incremental` endpoint is PRIMARY-PINNED
  # (`HeavyRead.primary_pinned_endpoints/0`), so this tail read runs on the PRIMARY pool
  # (AdminRepo) — the SAME source as `latest_entry/1` (head) and `load_valid_checkpoint/2`
  # (checkpoint) — even when `REPLICA_DATABASE_URL` routes other heavy reads to a replica. A
  # replica lagging by k entries would return only up to `latest_pos - k` for this tail and
  # the signer would fold an INCOMPLETE tail into a WRONG root labeled at `latest_pos`; pinning
  # to the primary keeps head/checkpoint/tail on one consistent snapshot. In test env both
  # pools resolve to `AdminRepo`, so this shares the sandbox.
  defp load_tail_hashes(tenant_id, cp_pos, latest_pos) do
    query =
      from(e in Entry,
        where:
          e.tenant_id == ^tenant_id and e.chain_position > ^cp_pos and
            e.chain_position <= ^latest_pos,
        order_by: [asc: e.chain_position],
        select: e.entry_hash
      )

    HeavyRead.all(tenant_id, query, HeavyRead.opts(:sth_incremental))
  end

  # Loads the tenant's checkpoint and validates it against the actual chain
  # head. Returns `{:ok, checkpoint}` only when it is safe to fold onto;
  # otherwise `:fallback` so the caller does a full recompute (AC-35.1.5).
  #
  # Two gates, cheapest first: (1) STRUCTURAL — position not ahead of the head,
  # right peak count, 32-byte peaks; then (2) EXACT CONTENT — the cached peaks,
  # bagged, must equal the `merkle_root` of the STH co-written at `cp_pos`. Gate 2
  # catches right-shape/wrong-bytes corruption (bit-rot / bad or unauthorized
  # write to `audit_sth_checkpoints`) that gate 1 cannot, so a corrupt cache
  # degrades to a correct rebuild instead of being folded into a signed root.
  defp load_valid_checkpoint(tenant_id, latest_pos) do
    checkpoint =
      from(c in SthCheckpoint, where: c.tenant_id == ^tenant_id)
      |> AdminRepo.one()

    if valid_checkpoint?(checkpoint, latest_pos) and
         checkpoint_root_matches_sth?(tenant_id, checkpoint) do
      {:ok, checkpoint}
    else
      :fallback
    end
  end

  # EXACT content-integrity check: rehydrate the cached peaks, bag them, and require
  # the result to byte-match the `merkle_root` of the STH signed at the checkpoint's
  # own position (co-written in `sign_and_store_tree_head/1`, retained forever in
  # `audit_signed_tree_heads`). If no such STH row exists we cannot prove the cache
  # is authentic, so we conservatively reject it and full-rebuild. One indexed
  # lookup + O(log n) hashing — O(Δ), dominated by the tail read it precedes.
  defp checkpoint_root_matches_sth?(tenant_id, %SthCheckpoint{
         chain_position: cp_pos,
         peaks: cp_peaks
       }) do
    case sth_at_exact_position(tenant_id, cp_pos) do
      %SignedTreeHead{merkle_root: stored_root} when is_binary(stored_root) ->
        rebuilt =
          cp_peaks
          |> peaks_with_heights(cp_pos + 1)
          |> bag_peaks()

        rebuilt == stored_root

      _ ->
        false
    end
  end

  # The STH at EXACTLY this position (not `>=`, unlike `get_sth_at_position/2`) —
  # the one co-written with the checkpoint at `cp_pos`.
  defp sth_at_exact_position(tenant_id, position) do
    from(s in SignedTreeHead,
      where: s.tenant_id == ^tenant_id and s.chain_position == ^position,
      limit: 1
    )
    |> AdminRepo.one()
  end

  # A checkpoint is usable iff:
  #   * it exists with a non-negative position that is NOT ahead of the chain
  #     head (a position ahead signals a stale/partial write), and
  #   * every stored peak is a 32-byte hash, and
  #   * the number of peaks equals the popcount of the covered leaf count
  #     (`chain_position + 1`) — the structural invariant of the peak set.
  # Anything else is treated as corrupt and ignored in favour of a full rebuild.
  defp valid_checkpoint?(nil, _latest_pos), do: false

  defp valid_checkpoint?(%SthCheckpoint{chain_position: cp_pos, peaks: peaks}, latest_pos)
       when is_integer(cp_pos) and cp_pos >= 0 and cp_pos <= latest_pos and is_list(peaks) do
    Enum.all?(peaks, &(is_binary(&1) and byte_size(&1) == 32)) and
      length(peaks) == popcount(cp_pos + 1)
  end

  defp valid_checkpoint?(_checkpoint, _latest_pos), do: false

  @doc """
  Signs a tree head for a tenant using the tenant's audit-signing key.
  Stores the result in `audit_signed_tree_heads`.

  Returns `{:ok, %SignedTreeHead{}}` or `{:error, reason}`.
  """
  @spec sign_and_store_tree_head(Ecto.UUID.t()) :: {:ok, SignedTreeHead.t()} | {:error, term()}
  def sign_and_store_tree_head(tenant_id) do
    with {:ok, merkle_root, %{chain_position: position, peaks: peaks}}
         when not is_nil(merkle_root) <- compute_merkle_root_incremental(tenant_id),
         {:ok, private_key} <- TenantKeys.get_private_key(tenant_id) do
      now = DateTime.utc_now()

      # US-35.1: sign the SAME position the incremental root was computed at (both
      # derived from one `latest_entry` read), so the checkpoint we persist is
      # consistent with the position just signed. The signed message and ed25519
      # signing are UNCHANGED — a verifier that recomputes the root the old way
      # still validates (AC-35.1.4).
      message = build_sth_message(tenant_id, position, merkle_root, now)
      signature = :crypto.sign(:eddsa, :sha512, message, [private_key, :ed25519])

      sth_changeset =
        %SignedTreeHead{tenant_id: tenant_id}
        |> SignedTreeHead.changeset(%{
          chain_position: position,
          merkle_root: merkle_root,
          signed_at: now,
          signature: signature
        })

      # US-35.1: the STH (source of truth) is committed FIRST and ON ITS OWN; the
      # checkpoint (a pure performance cache) is upserted best-effort AFTERWARD.
      # This deliberately does NOT share a transaction with the STH insert so a
      # cache-write fault (FK, serialization/lock under the concurrent per-tenant
      # fanout, disk error, a future constraint) can never roll back the
      # custody-critical STH signing (priority inversion). AC-35.1.3's atomicity
      # requirement is about the DANGEROUS direction — a checkpoint AHEAD of any
      # signed STH — which STH-first ordering makes impossible: the checkpoint at
      # `position` only ever appears after the STH at `position` has committed. A
      # lost checkpoint write merely makes the NEXT sign do a (correct) full
      # rebuild; `sth_needed?/1` re-fires so nothing is lost.
      case AdminRepo.insert(sth_changeset,
             on_conflict: {:replace, [:merkle_root, :signed_at, :signature]},
             conflict_target: [:tenant_id, :chain_position]
           ) do
        {:ok, stored_sth} ->
          upsert_checkpoint_best_effort(tenant_id, position, peaks)
          # US-26.5.1: broadcast STH to PubSub subscribers
          ChainPubSub.broadcast_sth(tenant_id, stored_sth)
          {:ok, stored_sth}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, nil, nil} -> {:error, :empty_chain}
      {:error, reason} -> {:error, reason}
    end
  end

  # Best-effort, MONOTONIC checkpoint cache upsert (US-35.1). Runs AFTER the STH
  # commit and never raises into the caller — a cache write is not allowed to fail
  # the sign.
  #
  # `on_conflict` replaces the row only when the incoming `chain_position` is
  # STRICTLY GREATER than the stored one, so a slower concurrent sign job that
  # computed at an earlier position can never regress the checkpoint backward
  # (the per-tenant fanout is not `unique`-deduped on the Basic Engine, so two
  # sign jobs can race). When the guard holds (incoming position not newer),
  # Postgres updates nothing and RETURNING is empty, which Ecto surfaces as
  # `Ecto.StaleEntryError`; that is the EXPECTED monotonic no-op — a newer
  # checkpoint already won — so we swallow it silently.
  defp upsert_checkpoint_best_effort(tenant_id, position, peaks) do
    changeset =
      %SthCheckpoint{tenant_id: tenant_id}
      |> SthCheckpoint.changeset(%{chain_position: position, peaks: peaks})

    case AdminRepo.insert(changeset,
           on_conflict: monotonic_checkpoint_on_conflict(),
           conflict_target: [:tenant_id]
         ) do
      {:ok, _checkpoint} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "AuditChain: STH signed for tenant #{tenant_id} at position #{position} but " <>
            "checkpoint cache write failed (#{inspect(reason)}); next sign will full-rebuild"
        )

        :ok
    end
  rescue
    Ecto.StaleEntryError -> :ok
  end

  # DO UPDATE ... WHERE the stored position is older than the incoming one — the
  # monotonic guard. `EXCLUDED.*` is the row we tried to insert.
  defp monotonic_checkpoint_on_conflict do
    from(c in SthCheckpoint,
      update: [
        set: [
          chain_position: fragment("EXCLUDED.chain_position"),
          peaks: fragment("EXCLUDED.peaks"),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ],
      where: c.chain_position < fragment("EXCLUDED.chain_position")
    )
  end

  @doc """
  Returns the latest STH for a tenant.
  """
  @spec get_latest_sth(Ecto.UUID.t()) :: SignedTreeHead.t() | nil
  def get_latest_sth(tenant_id) do
    from(s in SignedTreeHead,
      where: s.tenant_id == ^tenant_id,
      order_by: [desc: s.chain_position],
      limit: 1
    )
    |> AdminRepo.one()
  end

  # Postgres bigint (int8) upper bound. `chain_position` is a bigint, so a
  # position outside 0..max cannot exist in the chain AND would raise
  # DBConnection.EncodeError if handed to Postgrex — out-of-range lookups
  # short-circuit to nil instead. Single source of truth for callers that guard
  # the input up front (e.g. the witness plug).
  @max_chain_position 9_223_372_036_854_775_807

  @doc "The maximum valid chain position (Postgres bigint upper bound)."
  @spec max_chain_position() :: pos_integer()
  def max_chain_position, do: @max_chain_position

  @doc """
  Returns the smallest STH with chain_position >= the given position.

  Defensively returns `nil` for a non-integer or out-of-bigint-range position, so
  no caller (including the public, unauthenticated STH endpoint) can hand an
  unencodable value to Postgrex.
  """
  @spec get_sth_at_position(Ecto.UUID.t(), integer()) :: SignedTreeHead.t() | nil
  def get_sth_at_position(_tenant_id, position)
      when not is_integer(position) or position < 0 or position > @max_chain_position,
      do: nil

  def get_sth_at_position(tenant_id, position) do
    from(s in SignedTreeHead,
      where: s.tenant_id == ^tenant_id and s.chain_position >= ^position,
      order_by: [asc: s.chain_position],
      limit: 1
    )
    |> AdminRepo.one()
  end

  @doc """
  Checks if a new STH is needed (chain has grown since last STH).
  """
  @spec sth_needed?(Ecto.UUID.t()) :: boolean()
  def sth_needed?(tenant_id) do
    latest = latest_entry(tenant_id)
    latest_sth = get_latest_sth(tenant_id)

    case {latest, latest_sth} do
      {nil, _} -> false
      {_, nil} -> true
      {entry, sth} -> entry.chain_position > sth.chain_position
    end
  end

  # --- STH helpers ---

  defp build_sth_message(tenant_id, position, merkle_root, signed_at) do
    unix_ts = DateTime.to_unix(signed_at)
    tenant_id <> Integer.to_string(position) <> merkle_root <> Integer.to_string(unix_ts)
  end

  defp merkle_tree([single]), do: single

  defp merkle_tree(hashes) do
    # Pad to even length by duplicating the last element
    padded = if rem(length(hashes), 2) == 1, do: hashes ++ [List.last(hashes)], else: hashes

    next_level =
      padded
      |> Enum.chunk_every(2)
      |> Enum.map(fn [a, b] -> :crypto.hash(:sha256, a <> b) end)

    merkle_tree(next_level)
  end

  # --- US-35.1 incremental Merkle peaks ---
  #
  # A peak is `{height, hash}`: the root of a complete left-aligned 2^height
  # block. Peaks are kept left-to-right by DESCENDING height (an MMR frontier);
  # the heights are exactly the set-bit positions of the leaf count.
  #
  # `mmr_append_all/2` appends leaves to the frontier — pairwise-merging equal
  # height neighbours — producing peaks whose values are byte-identical to the
  # corresponding complete-subtree roots of `merkle_tree/2`. `bag_peaks/1` folds
  # the frontier into the final root, replicating `merkle_tree/2`'s EXACT
  # Bitcoin-style per-level pad-and-hash order (verified byte-for-byte by the
  # property test, TC-35.1.1). `merkle_tree/2` remains the reference oracle and
  # is NOT modified.

  # Rehydrate `{height, hash}` peaks from stored hashes + covered leaf count.
  # Heights are the set-bit positions of `count`, descending — the same order
  # `mmr_append_all/2` maintains. Caller has already checked the count matches.
  defp peaks_with_heights(hashes, count) do
    Enum.zip(heights_from_count(count), hashes)
  end

  defp peak_hashes(peaks), do: Enum.map(peaks, fn {_height, hash} -> hash end)

  defp mmr_append_all(peaks, leaves) do
    Enum.reduce(leaves, peaks, fn leaf, acc -> mmr_append(acc, leaf) end)
  end

  # Push a height-0 leaf onto the frontier and merge equal-height neighbours
  # from the right (left element first in the hash: left <> right).
  defp mmr_append(peaks, leaf), do: mmr_merge(peaks ++ [{0, leaf}])

  defp mmr_merge(peaks) do
    case Enum.reverse(peaks) do
      [{height, right}, {height, left} | rest] ->
        merged = {height + 1, :crypto.hash(:sha256, left <> right)}
        mmr_merge(Enum.reverse([merged | rest]))

      _ ->
        peaks
    end
  end

  # Fold a descending-height frontier into the single Bitcoin-style root.
  # Starting from the rightmost (lowest) peak as the carry, each peak to the left
  # is combined after lifting the carry up to that peak's height by repeated
  # self-pairing (replicating merkle_tree's "duplicate the last element" pad).
  defp bag_peaks([{_height, hash}]), do: hash

  defp bag_peaks(peaks) do
    [{low_h, low_v} | rest_right_to_left] = Enum.reverse(peaks)

    {_height, root} =
      Enum.reduce(rest_right_to_left, {low_h, low_v}, fn {peak_h, peak_v}, {carry_h, carry_v} ->
        lifted = lift_carry(carry_h, carry_v, peak_h)
        {peak_h + 1, :crypto.hash(:sha256, peak_v <> lifted)}
      end)

    root
  end

  defp lift_carry(height, value, target) when height < target do
    lift_carry(height + 1, :crypto.hash(:sha256, value <> value), target)
  end

  defp lift_carry(_height, value, _target), do: value

  defp heights_from_count(count) do
    0..63
    |> Enum.filter(fn bit -> (count >>> bit &&& 1) == 1 end)
    |> Enum.reverse()
  end

  defp popcount(count), do: count |> heights_from_count() |> length()

  # --- Private ---

  defp lock_and_read_previous(tenant_id) do
    # Lock the latest entry to serialize concurrent appends
    case from(e in Entry,
           where: e.tenant_id == ^tenant_id,
           order_by: [desc: e.chain_position],
           limit: 1,
           lock: "FOR UPDATE"
         )
         |> AdminRepo.one() do
      nil ->
        # Genesis entry
        {:ok, {0, @zero_hash}}

      prev ->
        {:ok, {prev.chain_position + 1, prev.entry_hash}}
    end
  end

  defp build_entry_attrs(tenant_id, position, prev_hash, attrs, now) do
    action = Map.fetch!(attrs, :action)
    actor_lineage = Map.get(attrs, :actor_lineage, [])
    entity_type = Map.fetch!(attrs, :entity_type)
    entity_id = Map.get(attrs, :entity_id)
    payload = Map.get(attrs, :payload, %{})

    entry_hash =
      compute_hash(%{
        tenant_id: tenant_id,
        position: position,
        prev_hash: prev_hash,
        action: action,
        actor_lineage: actor_lineage,
        entity_type: entity_type,
        entity_id: entity_id,
        payload: payload,
        inserted_at: now
      })

    %{
      chain_position: position,
      prev_entry_hash: prev_hash,
      action: action,
      actor_lineage: actor_lineage,
      entity_type: entity_type,
      entity_id: entity_id,
      payload: payload,
      entry_hash: entry_hash,
      inserted_at: now
    }
  end

  defp compute_hash(%{
         tenant_id: tenant_id,
         position: position,
         prev_hash: prev_hash,
         action: action,
         actor_lineage: actor_lineage,
         entity_type: entity_type,
         entity_id: entity_id,
         payload: payload,
         inserted_at: inserted_at
       }) do
    canonical =
      Jason.encode!(%{
        action: action,
        actor_lineage: actor_lineage,
        entity_id: entity_id,
        entity_type: entity_type,
        payload: payload
      })

    data =
      tenant_id <>
        Integer.to_string(position) <>
        prev_hash <>
        canonical <>
        DateTime.to_iso8601(inserted_at)

    :crypto.hash(:sha256, data)
  end
end
