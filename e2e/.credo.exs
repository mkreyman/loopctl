# e2e's own credo config, passed with --config-file: credo otherwise merges every .credo.exs in
# the parent directories, and the repository root's one requires server-only checks.
%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/"], excluded: [~r"/_build/", ~r"/deps/"]},
      strict: true
    }
  ]
}
