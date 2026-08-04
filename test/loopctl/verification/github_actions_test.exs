defmodule Loopctl.Verification.GitHubActionsTest do
  use ExUnit.Case, async: true

  alias Loopctl.Verification.GitHubActions

  describe "auth_headers/1" do
    test "a usable token becomes a bearer header" do
      assert GitHubActions.auth_headers("ghp_abc") == [{"authorization", "Bearer ghp_abc"}]
      assert GitHubActions.auth_headers(" ghp_abc\n") == [{"authorization", "Bearer ghp_abc"}]
    end

    test "no token sends no authorization header" do
      assert GitHubActions.auth_headers(nil) == []
    end

    test "a BLANK token sends none either — an empty bearer is worse than none" do
      # `if token do` is truthy for "", which is the shape a templated deploy config
      # produces for an unset secret. That sent `Authorization: Bearer ` and GitHub 401'd
      # every check-run lookup, so verification reported github_api_error instead of a CI
      # verdict — strictly worse than the anonymous path, which works for a public repo.
      for blank <- ["", "   ", "\n", "\t "] do
        assert GitHubActions.auth_headers(blank) == [],
               "a blank token must not become a bearer header"
      end
    end
  end
end
