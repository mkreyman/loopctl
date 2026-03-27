[
  # Phoenix router pattern match warning — known upstream issue in Phoenix 1.8.x
  # The router macro generates code that dialyzer flags as unmatchable.
  ~r/deps\/phoenix\/lib\/phoenix\/router\.ex.*pattern_match/,

  # Ecto.Multi.t() opaque type warnings — known upstream issue
  # https://github.com/elixir-ecto/ecto/issues/1882
  ~r/call_without_opaque/
]
