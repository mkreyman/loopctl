defmodule Loopctl.Workers.RevokeExpiredApiKeysWorkerTest do
  @moduledoc """
  The sweep that makes the two notions of "an active api_key" agree.

  `api_keys_one_role_per_agent_idx` is a PARTIAL UNIQUE index keyed on
  `(tenant_id, agent_id, role)` with the predicate `revoked_at IS NULL AND role NOT
  IN ('user','superadmin')`. It cannot test `expires_at` — a partial-index predicate
  must be IMMUTABLE and `now()` is STABLE — so an EXPIRED-but-unrevoked key is
  unusable for auth (`Auth.load_active_api_key/1` rejects it) while still OCCUPYING
  its agent's slot. The mint that follows is refused 422 `agent already has an active
  key with this role`, naming a key everything human-readable calls gone.

  `RevokeExpiredDispatchesWorker` covers keys a DISPATCH minted. A key minted straight
  at `POST /api/v1/api_keys` with an `expires_at` has no dispatch row, so nothing
  revoked it and it held the slot for ever. This worker is that sweep, keyed on the
  `api_keys` row rather than on a dispatch, so it covers every mint path.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query
  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.Auth
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Auth.ApiKeyCache
  alias Loopctl.Workers.RevokeExpiredApiKeysWorker

  # `Auth.generate_api_key/1` accepts an `expires_at`, but a key that is ALREADY expired
  # is not a state the API can mint, so the timestamp is forced past with AdminRepo —
  # the same shape `RevokeExpiredDispatchesWorkerTest` uses for its dispatches.
  defp force(key_id, fields) do
    {1, _} =
      from(k in ApiKey, where: k.id == ^key_id)
      |> AdminRepo.update_all(set: fields)

    AdminRepo.get!(ApiKey, key_id)
  end

  defp agent_key(tenant, attrs \\ %{}) do
    agent = fixture(:agent, tenant_id: tenant.id)

    {_raw, key} =
      fixture(
        :api_key,
        Map.merge(%{tenant_id: tenant.id, role: :agent, agent_id: agent.id}, attrs)
      )

    key
  end

  defp reload(key_id), do: AdminRepo.get!(ApiKey, key_id)

  describe "perform/1" do
    test "revokes an expired, un-revoked key and leaves a live one alone" do
      tenant = fixture(:tenant)
      expired = agent_key(tenant)
      live = agent_key(tenant)

      force(expired.id, expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      force(live.id, expires_at: DateTime.add(DateTime.utc_now(), 3600, :second))

      assert :ok = RevokeExpiredApiKeysWorker.perform(%Oban.Job{args: %{}})

      assert reload(expired.id).revoked_at, "the expired key must be revoked"
      refute reload(live.id).revoked_at, "a key inside its TTL must be untouched"
    end

    test "the revoked slot is free: a second agent-role key for the same agent now inserts" do
      # THE POINT OF THE WHOLE WORKER, asserted as the behaviour an operator sees rather
      # than as a column value. Before the sweep the mint is refused by the partial unique
      # index; after it, the same mint succeeds. A `revoked_at` assertion alone would stay
      # green if the index predicate ever stopped matching what this sweep writes.
      tenant = fixture(:tenant)
      agent = fixture(:agent, tenant_id: tenant.id)

      {_raw, first} =
        fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

      force(first.id, expires_at: DateTime.add(DateTime.utc_now(), -60, :second))

      assert {:error, changeset} =
               Auth.generate_api_key(%{
                 tenant_id: tenant.id,
                 name: "second",
                 role: :agent,
                 agent_id: agent.id
               })

      assert "agent already has an active key with this role" in errors_on(changeset).tenant_id

      assert :ok = RevokeExpiredApiKeysWorker.perform(%Oban.Job{args: %{}})

      assert {:ok, {_raw, second}} =
               Auth.generate_api_key(%{
                 tenant_id: tenant.id,
                 name: "second",
                 role: :agent,
                 agent_id: agent.id
               })

      assert second.id != first.id
    end

    test "a key with a NULL expires_at is never revoked" do
      # Non-expiring keys — every legacy env-var key is one. They are live by BOTH
      # notions, and a sweep that reaped them would log every long-lived operator out.
      tenant = fixture(:tenant)
      key = agent_key(tenant)
      force(key.id, expires_at: nil)

      assert :ok = RevokeExpiredApiKeysWorker.perform(%Oban.Job{args: %{}})

      refute reload(key.id).revoked_at
    end

    test "an already-revoked key keeps its ORIGINAL revoked_at" do
      # Idempotence with teeth: rewriting the timestamp would move a fact an audit
      # reader relies on every time the sweep runs.
      tenant = fixture(:tenant)
      key = agent_key(tenant)
      original = DateTime.truncate(DateTime.add(DateTime.utc_now(), -7200, :second), :microsecond)

      force(key.id,
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
        revoked_at: original
      )

      assert :ok = RevokeExpiredApiKeysWorker.perform(%Oban.Job{args: %{}})

      assert DateTime.compare(reload(key.id).revoked_at, original) == :eq
    end

    test "it sweeps ACROSS tenants — the predicate is expiry, not tenancy" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      key_a = agent_key(tenant_a)
      key_b = agent_key(tenant_b)

      for k <- [key_a, key_b] do
        force(k.id, expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      end

      assert :ok = RevokeExpiredApiKeysWorker.perform(%Oban.Job{args: %{}})

      assert reload(key_a.id).revoked_at
      assert reload(key_b.id).revoked_at
    end

    test "a `user`-role key expires into revocation too" do
      # The index ignores `user`/`superadmin`, but `Tenants.tenant_stats/1` and
      # `count_active_api_keys/0` both count `revoked_at IS NULL` alone, so an expired
      # user key inflates the operator-facing figure until something revokes it.
      tenant = fixture(:tenant)
      {_raw, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :user})
      force(key.id, expires_at: DateTime.add(DateTime.utc_now(), -60, :second))

      assert :ok = RevokeExpiredApiKeysWorker.perform(%Oban.Job{args: %{}})

      assert reload(key.id).revoked_at
    end

    test "a run with nothing expired is a no-op" do
      tenant = fixture(:tenant)
      key = agent_key(tenant)
      force(key.id, expires_at: DateTime.add(DateTime.utc_now(), 3600, :second))

      assert :ok = RevokeExpiredApiKeysWorker.perform(%Oban.Job{args: %{}})

      refute reload(key.id).revoked_at
    end
  end

  describe "revoke_batch/2 — the advisory read's re-assertion" do
    # The candidate read is ADVISORY, so the UPDATE re-asserts the whole predicate: a key
    # revoked, or given a later expiry, between the read and the write must not be rewritten
    # on the strength of a stale read. Through `perform/1` that re-assertion is INVISIBLE —
    # the candidate read never offers such a row — so the two guards used to mask each other
    # and `bin/mutate.sh` came back exit 1 on each in turn. These reach the write directly
    # with ids the read would never have produced, which is the only way the guard can go red.

    test "an id that is now revoked is skipped, keeping its ORIGINAL revoked_at" do
      tenant = fixture(:tenant)
      key = agent_key(tenant)
      original = DateTime.truncate(DateTime.add(DateTime.utc_now(), -7200, :second), :microsecond)

      force(key.id,
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
        revoked_at: original
      )

      assert :ok = RevokeExpiredApiKeysWorker.revoke_batch([key.id], DateTime.utc_now())

      assert DateTime.compare(reload(key.id).revoked_at, original) == :eq
    end

    test "an id whose expiry moved into the FUTURE is skipped" do
      tenant = fixture(:tenant)
      key = agent_key(tenant)
      force(key.id, expires_at: DateTime.add(DateTime.utc_now(), 3600, :second))

      assert :ok = RevokeExpiredApiKeysWorker.revoke_batch([key.id], DateTime.utc_now())

      refute reload(key.id).revoked_at
    end

    test "an id whose expiry is NULL is skipped" do
      tenant = fixture(:tenant)
      key = agent_key(tenant)
      force(key.id, expires_at: nil)

      assert :ok = RevokeExpiredApiKeysWorker.revoke_batch([key.id], DateTime.utc_now())

      refute reload(key.id).revoked_at
    end

    test "an id that still satisfies the predicate IS revoked" do
      # The positive control: without it the three refusals above are satisfied by a
      # `revoke_batch/2` that does nothing at all.
      tenant = fixture(:tenant)
      key = agent_key(tenant)
      force(key.id, expires_at: DateTime.add(DateTime.utc_now(), -60, :second))

      assert :ok = RevokeExpiredApiKeysWorker.revoke_batch([key.id], DateTime.utc_now())

      assert reload(key.id).revoked_at
    end
  end

  describe "cache invalidation" do
    test "the api-key cache entry is busted, not left to its TTL" do
      # The sweep writes via `update_all`, which bypasses changesets, so nothing busts
      # the cache implicitly (AC-33.3.2). This is observable at the CACHE layer and only
      # there: `ApiKeyCache.fetch/1`'s TTL is the ENTRY's, not the key's, so a cached
      # expired key stays a cache HIT and it is `verify_api_key/1` that rejects it on
      # wall clock. Asserting through `verify_api_key/1` would therefore be green with
      # the invalidation deleted.
      tenant = fixture(:tenant)
      key = agent_key(tenant)
      force(key.id, expires_at: DateTime.add(DateTime.utc_now(), -60, :second))

      ApiKeyCache.put(key.key_hash, AdminRepo.get!(ApiKey, key.id) |> AdminRepo.preload(:tenant))
      assert {:ok, %ApiKey{}} = ApiKeyCache.fetch(key.key_hash)

      assert :ok = RevokeExpiredApiKeysWorker.perform(%Oban.Job{args: %{}})

      assert ApiKeyCache.fetch(key.key_hash) == :miss
    end
  end

  describe "batching" do
    test "batch_size/0 bounds the candidate read" do
      # Named so the bound is assertable without seeding 500 rows. The sweep runs on
      # AdminRepo's 3-connection pool, so an unbounded backlog would pin it.
      assert RevokeExpiredApiKeysWorker.batch_size() > 0
    end
  end
end
