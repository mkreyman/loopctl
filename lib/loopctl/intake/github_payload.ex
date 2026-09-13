defmodule Loopctl.Intake.GithubPayload do
  @moduledoc """
  Pure parsing of a GitHub webhook payload that has ALREADY passed signature verification
  (issue #803).

  Nothing here is called before `Loopctl.Intake.Signature.valid?/3` has accepted the raw
  body, and the JSON is decoded from those same raw bytes — never from `Plug.Parsers`'
  params — so what was signed is exactly what is read.

  ## Caps on untrusted fields

  Reporter-controlled text is capped before it is stored. The caps are generous for a
  real issue (GitHub itself limits a title to 256 characters and a body to 65,536) and
  exist so a stored field is bounded in BYTES, whatever the character mix:

  | field | cap |
  |---|---|
  | `untrusted_title` | 1,024 bytes |
  | `untrusted_body` | 65,536 bytes |
  | `untrusted_labels` | 50 labels, 100 bytes each |
  | `untrusted_author_login` | 64 bytes |

  A cut lands on a UTF-8 character boundary and sets `untrusted_truncated`. The injection
  detector reads the UNCAPPED text, so a payload placed past a cap still fires. NUL
  characters, which Postgres `text` cannot hold, are stored as U+FFFD and reported by the
  detector as `hidden_characters`.
  """

  @max_title_bytes 1_024
  @max_body_bytes 65_536
  @max_labels 50
  @max_label_bytes 100
  @max_login_bytes 64

  @issue_states ~w(open closed)

  @type issue :: %{
          number: pos_integer(),
          github_issue_id: integer() | nil,
          html_url: String.t() | nil,
          state: String.t() | nil,
          updated_at: DateTime.t() | nil,
          title: String.t(),
          body: String.t(),
          labels: [String.t()],
          author_login: String.t() | nil
        }

  @doc "The byte caps applied to untrusted fields, keyed by field."
  @spec caps() :: map()
  def caps do
    %{
      untrusted_title: @max_title_bytes,
      untrusted_body: @max_body_bytes,
      untrusted_labels: {@max_labels, @max_label_bytes},
      untrusted_author_login: @max_login_bytes
    }
  end

  @doc """
  Decodes the raw body. GitHub sends either `application/json` or
  `application/x-www-form-urlencoded` with the JSON in a `payload` field, depending on how
  the webhook was configured; both are accepted. The result must be a JSON object.
  """
  @spec decode(binary(), String.t() | nil) :: {:ok, map()} | {:error, :invalid_payload}
  def decode(raw_body, content_type) when is_binary(raw_body) do
    with {:ok, json} <- json_text(raw_body, content_type),
         {:ok, %{} = payload} <- Jason.decode(json) do
      {:ok, payload}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp json_text(raw_body, content_type) do
    if form_encoded?(content_type) do
      case safe_decode_query(raw_body) do
        %{"payload" => json} when is_binary(json) -> {:ok, json}
        _ -> :error
      end
    else
      {:ok, raw_body}
    end
  end

  defp form_encoded?(nil), do: false

  defp form_encoded?(content_type) do
    content_type |> String.downcase() |> String.starts_with?("application/x-www-form-urlencoded")
  end

  defp safe_decode_query(raw_body) do
    URI.decode_query(raw_body)
  rescue
    ArgumentError -> %{}
  end

  @doc "The payload's `repository.full_name`, or nil."
  @spec repository_full_name(map()) :: String.t() | nil
  def repository_full_name(%{"repository" => %{"full_name" => name}}) when is_binary(name),
    do: name

  def repository_full_name(_payload), do: nil

  @doc "The payload's `action`, when it is a short lowercase word, or nil."
  @spec action(map()) :: String.t() | nil
  def action(%{"action" => action}) when is_binary(action) do
    if Regex.match?(~r/\A[a-z_]{1,64}\z/, action), do: action
  end

  def action(_payload), do: nil

  @doc """
  The issue of an `issues` event, UNCAPPED. `repo_full_name` is the source's repository:
  `html_url` is kept only when it is that repository's URL for this issue number.
  """
  @spec issue(map(), String.t()) :: {:ok, issue()} | {:error, :invalid_payload}
  def issue(%{"issue" => %{"number" => number} = issue}, repo_full_name)
      when is_integer(number) and number > 0 do
    {:ok,
     %{
       number: number,
       github_issue_id: integer_or_nil(issue["id"]),
       html_url: html_url(issue["html_url"], repo_full_name, number),
       state: if(issue["state"] in @issue_states, do: issue["state"]),
       updated_at: datetime(issue["updated_at"]),
       title: string_or_empty(issue["title"]),
       body: string_or_empty(issue["body"]),
       labels: label_names(issue["labels"]),
       author_login: author_login(issue["user"])
     }}
  end

  def issue(_payload, _repo_full_name), do: {:error, :invalid_payload}

  @doc """
  The untrusted fields of an issue, capped, plus `untrusted_truncated`. See the moduledoc.
  """
  @spec untrusted_fields(issue()) :: map()
  def untrusted_fields(issue) do
    {title, title_cut} = cap(issue.title, @max_title_bytes)
    {body, body_cut} = cap(issue.body, @max_body_bytes)
    {login, login_cut} = cap_nullable(issue.author_login, @max_login_bytes)

    label_cuts = Enum.map(issue.labels, &cap(&1, @max_label_bytes))
    labels = label_cuts |> Enum.take(@max_labels) |> Enum.map(&elem(&1, 0))

    labels_cut =
      length(issue.labels) > @max_labels or Enum.any?(label_cuts, &elem(&1, 1))

    %{
      untrusted_title: title,
      untrusted_body: body,
      untrusted_labels: labels,
      untrusted_author_login: login,
      untrusted_truncated: title_cut or body_cut or login_cut or labels_cut
    }
  end

  defp cap_nullable(nil, _max), do: {nil, false}
  defp cap_nullable(text, max), do: cap(text, max)

  defp cap(text, max) do
    text = String.replace(text, <<0>>, <<0xFFFD::utf8>>)

    if byte_size(text) <= max do
      {text, false}
    else
      {text |> binary_part(0, max) |> trim_to_valid(), true}
    end
  end

  # A byte cut can split a multi-byte character; drop the partial tail (at most 3 bytes).
  defp trim_to_valid(binary) do
    if String.valid?(binary),
      do: binary,
      else: binary |> binary_part(0, byte_size(binary) - 1) |> trim_to_valid()
  end

  defp label_names(labels) when is_list(labels) do
    for %{"name" => name} when is_binary(name) <- labels, do: name
  end

  defp label_names(_labels), do: []

  defp html_url(url, repo_full_name, number) when is_binary(url) do
    expected = "https://github.com/#{repo_full_name}/issues/#{number}"
    if String.downcase(url) == String.downcase(expected), do: url
  end

  defp html_url(_url, _repo, _number), do: nil

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{microsecond: {usec, _precision}} = datetime, _offset} ->
        %{datetime | microsecond: {usec, 6}}

      _ ->
        nil
    end
  end

  defp datetime(_value), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp string_or_empty(value) when is_binary(value), do: value
  defp string_or_empty(_value), do: ""

  defp author_login(%{"login" => login}) when is_binary(login), do: login
  defp author_login(_user), do: nil
end
