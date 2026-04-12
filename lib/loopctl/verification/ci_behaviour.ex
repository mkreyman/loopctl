defmodule Loopctl.Verification.CiBehaviour do
  @moduledoc """
  US-26.4.3 — Behaviour for CI provider integration.

  Abstracts CI status querying so the verification runner can check
  GitHub Actions, GitLab CI, or any future provider.
  """

  @doc "Fetches the CI status for a commit SHA in a repository."
  @callback get_status(repo_url :: String.t(), commit_sha :: String.t()) ::
              {:ok, %{status: String.t(), conclusion: String.t() | nil, url: String.t()}}
              | {:error, term()}

  @doc "Lists test results from a CI run."
  @callback get_test_results(repo_url :: String.t(), run_id :: String.t()) ::
              {:ok, [%{name: String.t(), status: String.t()}]}
              | {:error, term()}
end
