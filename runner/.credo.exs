# The runner's own credo config. mix.exs passes it with --config-file, because credo otherwise
# merges every .credo.exs in the parent directories, and the repository root's one requires
# server-only checks (lib/loopctl/knowledge/...) that do not exist under runner/.
%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/"], excluded: [~r"/_build/", ~r"/deps/"]},
      strict: true
    }
  ]
}
