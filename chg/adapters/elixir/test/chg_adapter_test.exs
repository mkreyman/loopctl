defmodule ChgAdapterTest do
  use ExUnit.Case, async: true

  import ChgAdapter, only: [dep_env: 2]

  test "a dependency's tasks run in test unless :only leaves test out" do
    assert dep_env(:credo, [{:credo, "~> 1.7"}]) == "test"
    assert dep_env(:credo, [{:credo, "~> 1.7", only: [:dev, :test], runtime: false}]) == "test"
    assert dep_env(:dialyxir, [{:dialyxir, "~> 1.4", only: :dev, runtime: false}]) == "dev"
    assert dep_env(:dialyxir, [{:dialyxir, path: "../dialyxir", only: :ci}]) == "ci"
    assert dep_env(:dialyxir, [{:dialyxir, path: "../dialyxir"}]) == "test"
  end

  test "a missing dependency has no env" do
    assert dep_env(:dialyxir, [{:credo, "~> 1.7"}]) == nil
  end
end
