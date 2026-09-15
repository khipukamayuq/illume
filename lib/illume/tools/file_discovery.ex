defmodule Illume.Tools.FileDiscovery do
  @moduledoc """
  Enumerates the files under a directory that "count" for
  `search_files`/`grep_content` — tracked-or-untracked-but-not-gitignored
  files, via `git ls-files`, whenever the directory is part of a git
  repo; a plain recursive walk skipping a small static list of common
  noise directories otherwise. Shared by `Illume.Tools.Filesystem` and
  `Illume.Tools.Grep` so both respect whatever the target project itself
  considers noise (via its own `.gitignore`) instead of each maintaining
  a separate, perpetually-incomplete hardcoded list (see DECISIONS.md).

  Paths are returned relative to `dir`. The git path is NUL-delimited
  (`git ls-files -z`), so filenames containing newlines are handled
  correctly; the fallback walk is confinement-checked the same way
  `Illume.Tools.PathConfinement` guards every other path in this project,
  since `Path.wildcard/2`'s `**` — unlike git or `grep -r`'s own default
  — does follow symlinked directories.

  Falls back when `dir` isn't inside a git repo at all, and also when
  `dir` itself is gitignored by an *enclosing* repo it happens to sit
  inside (`git -C dir ls-files` inherits that repo's ignore rules for
  the path to `dir`, not just paths under it — checked explicitly with
  `git check-ignore` rather than silently returning an empty list for a
  directory that plainly has real files in it).
  """

  alias Illume.Tools.PathConfinement

  @ignored_dirs ~w(.git _build deps node_modules .elixir_ls cover)

  @doc "File paths under `dir`, relative to it, git-aware when possible."
  @spec list(Path.t()) :: [String.t()]
  def list(dir) do
    case git_tracked_files(dir) do
      {:ok, files} -> files
      :not_a_git_repo -> walk(dir)
    end
  end

  @spec git_tracked_files(Path.t()) :: {:ok, [String.t()]} | :not_a_git_repo
  defp git_tracked_files(dir) do
    if dir_ignored_by_enclosing_repo?(dir) do
      :not_a_git_repo
    else
      args = ["-C", dir, "ls-files", "--cached", "--others", "--exclude-standard", "-z"]

      case System.cmd("git", args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, String.split(output, "\0", trim: true)}
        {_output, _status} -> :not_a_git_repo
      end
    end
  end

  @spec dir_ignored_by_enclosing_repo?(Path.t()) :: boolean()
  defp dir_ignored_by_enclosing_repo?(dir) do
    case System.cmd("git", ["-C", dir, "check-ignore", "-q", "."], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  @spec walk(Path.t()) :: [String.t()]
  defp walk(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&(File.regular?(&1) and PathConfinement.within?(&1, dir)))
    |> Enum.reject(&ignored?(&1, dir))
    |> Enum.map(&Path.relative_to(&1, dir))
  end

  @spec ignored?(Path.t(), Path.t()) :: boolean()
  defp ignored?(path, root) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.any?(&(&1 in @ignored_dirs))
  end
end
