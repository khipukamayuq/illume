defmodule Illume.Tools.Filesystem do
  @moduledoc """
  Direct-call implementations of the read-only filesystem tools. Every
  path is confined to the target directory the CLI was invoked with.
  """

  alias Illume.Tools.PathConfinement

  @max_bytes 300_000
  @max_results 200
  @ignored_dirs ~w(.git _build deps node_modules .elixir_ls cover)

  @doc """
  Read a file's contents as text. `input` is `%{"path" => relative_path}`.
  Rejects non-UTF-8 content (a binary file isn't meaningful for a codebase
  Q&A tool, and would break JSON-encoding the tool result anyway) and
  truncates oversized files at a valid UTF-8 boundary rather than an exact
  byte offset, which can otherwise split a multi-byte character in two.
  """
  @spec read_file(Path.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def read_file(target_dir, %{"path" => rel_path}) do
    with {:ok, full_path} <- PathConfinement.confine(target_dir, rel_path) do
      case File.read(full_path) do
        {:ok, content} ->
          read_content(content, rel_path)

        {:error, :enoent} ->
          {:error, "no such file: #{rel_path}"}

        {:error, :eisdir} ->
          {:error, "#{rel_path} is a directory, not a file"}

        {:error, reason} ->
          {:error, "could not read #{rel_path}: #{:file.format_error(reason)}"}
      end
    end
  end

  def read_file(_target_dir, _input), do: {:error, "missing required input: path"}

  @spec read_content(binary(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp read_content(content, rel_path) do
    if String.valid?(content) do
      {:ok, truncate(content)}
    else
      {:error, "#{rel_path} is not a UTF-8 text file"}
    end
  end

  @spec truncate(String.t()) :: String.t()
  defp truncate(content) when byte_size(content) <= @max_bytes, do: content

  defp truncate(content) do
    truncated =
      content
      |> binary_part(0, @max_bytes)
      |> drop_trailing_partial_utf8()

    truncated <> "\n\n[... truncated, file exceeds #{@max_bytes} bytes ...]"
  end

  @spec drop_trailing_partial_utf8(binary()) :: String.t()
  defp drop_trailing_partial_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      drop_trailing_partial_utf8(binary_part(binary, 0, byte_size(binary) - 1))
    end
  end

  @doc """
  Find files whose *name* matches a glob pattern, recursively. Does not
  search file contents — use `Illume.Tools.Grep.grep_content/2` for that.
  `input` is `%{"pattern" => glob}`.
  """
  @spec search_files(Path.t(), map()) :: {:ok, [String.t()]} | {:error, String.t()}
  def search_files(target_dir, %{"pattern" => pattern}) do
    root = Path.expand(target_dir)

    matches =
      root
      |> Path.join("**/#{pattern}")
      |> Path.wildcard(match_dot: false)
      |> Enum.map(&Path.expand/1)
      |> Enum.filter(&PathConfinement.within?(&1, root))
      |> Enum.reject(&ignored?(&1, root))
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()
      |> Enum.take(@max_results)

    {:ok, matches}
  end

  def search_files(_target_dir, _input), do: {:error, "missing required input: pattern"}

  @spec ignored?(Path.t(), Path.t()) :: boolean()
  defp ignored?(path, root) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.any?(&(&1 in @ignored_dirs))
  end
end
