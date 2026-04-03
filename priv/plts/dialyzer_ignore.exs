[
  # Ecto.Multi.t() opaque type warnings — known upstream issue
  # https://github.com/elixir-ecto/ecto/issues/1882
  ~r/call_without_opaque/,

  # MapSet opaque type warnings — known upstream issue in Erlang/OTP dialyzer
  # The reachable?/4 function passes MapSet to recursive calls, which dialyzer
  # flags as opaque term crossing function boundaries.
  ~r/call_with_opaque.*reachable\?/
]
