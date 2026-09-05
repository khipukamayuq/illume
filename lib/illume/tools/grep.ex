defmodule Illume.Tools.Grep do
  @moduledoc """
  Fixed-string (not regex) content search, confined to the target
  directory. Has no MCP equivalent — neither reference server exposes
  content search, so this stays a direct call permanently.
  """

  alias Illume.Tools.PathConfinement

  @max_lines 200
  @ignored_dirs ~w(.git _build deps node_modules .elixir_ls cover)

  @doc """
  Search file contents for a fixed string. `input` is
  `%{"pattern" => string}`, optionally `%{"path" => relative_subdir}` to
  scope the search. Caps matches per file at #{@max_lines} (via grep's own
  `-m`) so a single huge file (a data dump, a minified bundle that dodged
  `@ignored_dirs`) can't blow up memory before `cap/2`'s total-output
  truncation ever gets a chance to run.
  """
  @spec grep_content(Path.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def grep_content(target_dir, %{"pattern" => pattern} = input) do
    root = Path.expand(target_dir)
    subdir = Map.get(input, "path", ".")

    with {:ok, search_root} <- PathConfinement.confine(root, subdir) do
      exclude_args = Enum.flat_map(@ignored_dirs, &["--exclude-dir=#{&1}"])
      args = ["-rn", "-F", "-m", "#{@max_lines}"] ++ exclude_args ++ ["--", pattern, search_root]

      case System.cmd("grep", args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, cap(output, root)}
        {_output, 1} -> {:ok, "no matches"}
        {output, _} -> {:error, "grep failed: #{output}"}
      end
    end
  end

  def grep_content(_target_dir, _input), do: {:error, "missing required input: pattern"}

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
