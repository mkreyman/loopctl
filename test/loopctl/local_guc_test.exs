defmodule Loopctl.LocalGucTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.LocalGuc
  alias Loopctl.Repo

  # The stack `scoped/3` and the hand-paired `capture/2`+`restore/2` share. Read directly
  # because the ownership bug it guards has no cheaper observable: its damage lands only on a
  # LATER nested capture FAILURE, which needs a wedged connection to reproduce.
  @active_names_key {LocalGuc, :active_names}

  describe "scoped/3 ownership bookkeeping" do
    test "a nested scope pops exactly its own names, leaving the enclosing owner intact" do
      Repo.transaction(fn ->
        LocalGuc.scoped(Repo, ["statement_timeout"], fn ->
          LocalGuc.scoped(Repo, ["statement_timeout"], fn -> :ok end)

          # A double pop (`restore/2` pops, and `scoped/3` popping again) removes the OUTER
          # scope's occurrence too, so this reads `nil` — and the next nested capture failure
          # takes `capture_fallback!/2`'s RESET branch instead of ABORT, clobbering a
          # `statement_timeout` this scope is still holding.
          assert Process.get(@active_names_key) == ["statement_timeout"]
        end)
      end)

      assert Process.get(@active_names_key) == nil
    end
  end
end
