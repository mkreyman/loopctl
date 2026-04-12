defmodule Loopctl.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Loopctl.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Loopctl.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Loopctl.DataCase
      import Loopctl.Fixtures
      import Mox
    end
  end

  setup tags do
    Loopctl.DataCase.setup_sandbox(tags)
    Mox.set_mox_from_context(tags)
    stub_all_defaults()
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  Configures both Repo and AdminRepo for test isolation.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Loopctl.Repo, shared: not tags[:async])
    admin_pid = Sandbox.start_owner!(Loopctl.AdminRepo, shared: not tags[:async])

    on_exit(fn ->
      Sandbox.stop_owner(pid)
      Sandbox.stop_owner(admin_pid)
    end)
  end

  @doc """
  Sets permissive default stubs for all Mox mocks.

  These stubs allow tests to run without explicitly setting up
  expectations for every mock. Override with `expect/3` in individual
  tests as needed.
  """
  def stub_all_defaults do
    Mox.stub(Loopctl.MockHealthChecker, :check, fn ->
      {:ok,
       %{
         status: "ok",
         version: "0.1.0-test",
         checks: %{database: "ok", oban: "ok"}
       }}
    end)

    Mox.stub(Loopctl.MockRateLimiter, :check_rate, fn _bucket, _window, _limit ->
      {:allow, 1}
    end)

    Mox.stub(Loopctl.MockClock, :utc_now, fn ->
      DateTime.utc_now()
    end)

    # Default stub for cost rollup -- returns empty results
    Mox.stub(Loopctl.MockCostRollup, :aggregate, fn _tenant_id, _start, _end ->
      {:ok, []}
    end)

    # Default stub for token archival -- returns zero counts
    Mox.stub(Loopctl.MockTokenArchival, :soft_delete_old_reports, fn _tenant_id, _days ->
      {:ok, 0}
    end)

    Mox.stub(Loopctl.MockTokenArchival, :hard_delete_expired_reports, fn _tenant_id ->
      {:ok, 0}
    end)

    Mox.stub(Loopctl.MockTokenArchival, :archive_old_anomalies, fn _tenant_id, _days ->
      {:ok, 0}
    end)

    # Default stub for embedding client -- returns a 1536-dim vector of 0.1
    Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _text ->
      {:ok, List.duplicate(0.1, 1536)}
    end)

    # Default stub for knowledge extractor -- returns empty list (no articles)
    Mox.stub(Loopctl.MockExtractor, :extract_articles, fn _ctx ->
      {:ok, []}
    end)

    # Default stub for content extractor -- returns empty list (no articles)
    Mox.stub(Loopctl.MockContentExtractor, :extract_from_content, fn _content, _opts ->
      {:ok, []}
    end)

    # Default Req.Test stub for content ingestion URL fetching
    Req.Test.stub(Loopctl.Workers.ContentIngestionWorker, fn conn ->
      Req.Test.text(conn, "Default ingestion stub content")
    end)

    # Default Req.Test stub for webhook delivery -- allows Oban inline mode
    # to process delivery jobs without test-specific HTTP stub setup.
    Req.Test.stub(Loopctl.Webhooks.ReqDelivery, fn conn ->
      Req.Test.json(conn, %{"ok" => true})
    end)

    # Default Req.Test stub for CLI HTTP client
    Req.Test.stub(Loopctl.CLI.Client, fn conn ->
      Req.Test.json(conn, %{"error" => "not stubbed"})
    end)

    # Default stub for WebAuthn adapter — returns a deterministic fake
    # registration challenge and a valid attestation result so tests that
    # touch signup without opting in still work.
    Mox.stub(Loopctl.MockWebAuthn, :new_registration_challenge, fn _opts ->
      %{bytes: <<0::256>>, rp_id: "localhost"}
    end)

    Mox.stub(Loopctl.MockWebAuthn, :verify_registration, fn payload, _challenge, _opts ->
      {:ok,
       %{
         credential_id: Map.get(payload, :credential_id) || :crypto.strong_rand_bytes(32),
         public_key: <<"stub-cose-key-", :rand.uniform(1_000_000)::32>>,
         attestation_format: "none",
         sign_count: 0
       }}
    end)

    Mox.stub(Loopctl.MockWebAuthn, :new_authentication_challenge, fn _opts ->
      %{bytes: <<0::256>>, rp_id: "localhost"}
    end)

    Mox.stub(Loopctl.MockWebAuthn, :verify_authentication, fn _payload, _challenge, _opts ->
      {:ok, %{sign_count: 1}}
    end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
