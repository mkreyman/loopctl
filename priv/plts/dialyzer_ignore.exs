[
  # False positive: Regex.scan's typespec in some Elixir versions doesn't
  # properly account for return: :index option. Our code is correct.
  ~r{lib/loopctl/knowledge/content_chunker.ex.*(find_split_point|find_last_regex_match|Regex.scan)}
]
