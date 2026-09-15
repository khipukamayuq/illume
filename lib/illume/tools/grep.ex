defmodule Illume.Tools.Grep do
  @moduledoc """
  Fixed-string (not regex) content search, confined to the target
  directory. Has no MCP equivalent — neither reference server exposes
  content search, so this stays a direct call permanently.
  """

  alias Illume.Tools.{FileDiscovery, PathConfinement}

  @max_lines 200
  @batch_size 500

  @doc """
  Search file contents for a fixed string. `input` is
  `%{"pattern" => string}`, optionally `%{"path" => relative_subdir}` to
  scope the search. Caps matches per file at #{@max_lines} (via grep's own
  `-m`) so a single huge file (a data dump, a minified bundle) can't blow
  up memory before `cap/2`'s total-output truncation ever gets a chance
  to run. Searches only the files `Illume.Tools.FileDiscovery.list/1`
  returns, `@batch_size` at a time as explicit `grep` arguments rather
  than letting `grep -r` walk the directory itself — keeps a single
  huge-file-count target from building one unbounded argument list.

  Passing an explicit file list (rather than a directory for `grep -r`
  to walk itself) means `grep` sees, and must tolerate, conditions its
  own recursive walk would have silently skipped: a broken symlink, a
  submodule/gitlink path, a file that became unreadable or was deleted
  between `FileDiscovery.list/1` and this call. `-s` suppresses grep's
  own error text for these (which would otherwise leak into what's
  returned to the model, since stderr is folded into the captured
  output); exit status `2` (which `grep` still returns for them even
  with `-s`) is treated as a partial result, not a hard failure — a
  match already found in the same batch isn't discarded just because
  a different file in that batch couldn't be read (see DECISIONS.md).
  """
  @spec grep_content(Path.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def grep_content(target_dir, %{"pattern" => pattern} = input) do
    root = Path.expand(target_dir)
    subdir = Map.get(input, "path", ".")

    with {:ok, search_root} <- PathConfinement.confine(root, subdir) do
      search_root
      |> FileDiscovery.list()
      |> Enum.map(&Path.join(search_root, &1))
      |> Enum.chunk_every(@batch_size)
      |> run_batches(pattern)
      |> case do
        {:ok, output} -> {:ok, cap(output, root)}
        :no_matches -> {:ok, "no matches"}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def grep_content(_target_dir, _input), do: {:error, "missing required input: pattern"}

  @spec run_batches([[Path.t()]], String.t()) ::
          {:ok, String.t()} | :no_matches | {:error, String.t()}
  defp run_batches(batches, pattern) do
    Enum.reduce_while(batches, :no_matches, fn batch, acc ->
      args = ["-Hns", "-F", "-m", "#{@max_lines}", "--", pattern] ++ batch

      case System.cmd("grep", args, stderr_to_stdout: true) do
        {"", status} when status in [0, 1, 2] -> {:cont, acc}
        {output, status} when status in [0, 1, 2] -> {:cont, {:ok, merge(acc, output)}}
        {output, _status} -> {:halt, {:error, "grep failed: #{output}"}}
      end
    end)
  end

  @spec merge(:no_matches | {:ok, String.t()}, String.t()) :: String.t()
  defp merge(:no_matches, output), do: output
  defp merge({:ok, previous}, output), do: previous <> output

  @spec cap(String.t(), Path.t()) :: String.t()
  defp cap(output, root) do
    lines = output |> String.trim_trailing("\n") |> String.split("\n")
    relativized = Enum.map(lines, &String.replace_prefix(&1, root <> "/", ""))

    case Enum.split(relativized, @max_lines) do
      {kept, []} ->
        Enum.join(kept, "\n")

      {kept, rest} ->
        Enum.join(kept, "\n") <> "\n\n[... truncated, #{length(rest)} more matches ...]"
    end
  end
end
