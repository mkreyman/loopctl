defmodule Loopctl.Verification.LocalRunner do
  @moduledoc """
  The L3 local fallback's contract (US-26.4.6): clone `repo_url` at `commit_sha` through the
  verification credential seam (`Loopctl.Verification.Credential`) and run its suite.

  A behaviour so the verification worker's decision of WHEN to fall back, and WHICH repository
  it clones, is testable without cloning anything: `Loopctl.Verification.TestRunner` is the
  implementation, and it is disabled by default in every environment.
  """

  alias Loopctl.Verification.Credential

  @callback run_tests(repo_url :: String.t(), commit_sha :: String.t(), Credential.t()) ::
              {:ok,
               %{
                 status: String.t(),
                 tests_run: non_neg_integer(),
                 tests_passed: non_neg_integer(),
                 tests_failed: non_neg_integer(),
                 output: String.t()
               }}
              | {:error, term()}
end
