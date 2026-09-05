defmodule Illume.Tools.PathConfinement do
  @moduledoc """
  Shared path-confinement checks so every tool that accepts a
  model-supplied path is confined to the target directory the same way.

  `within?/2` resolves symlinks before comparing (like `realpath`) rather
  than comparing lexically-expanded paths — a symlink anywhere in the
  path, not just at the final component, can otherwise lead outside the
  confined root while still passing a purely lexical prefix check.
  Resolution walks every path component that actually exists on disk;
  a path (or path prefix) that doesn't exist yet is left as-is for that
  portion, since there's nothing on disk to redirect it.
  """

  @max_symlink_hops 40

  @doc "Resolve `rel_path` against `target_dir`, rejecting anything outside it."
  @spec confine(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def confine(target_dir, rel_path) do
    root = Path.expand(target_dir)
    full = Path.expand(rel_path, root)

    if within?(full, root) do
      {:ok, full}
    else
      {:error, "path escapes target directory: #{rel_path}"}
    end
  end

  @doc "Whether `path` resolves to somewhere inside `root`, symlinks included."
  @spec within?(Path.t(), Path.t()) :: boolean()
  def within?(path, root) do
    case {real_path(path), real_path(root)} do
      {nil, _} ->
        false

      {_, nil} ->
        false

      {real_path, real_root} ->
        real_path == real_root or String.starts_with?(real_path, real_root <> "/")
    end
  end

  @doc """
  Resolve `path` to its symlink-free, absolute form, the way `realpath`
  does. Returns `nil` if resolution doesn't terminate (a symlink cycle).
  """
  @spec real_path(Path.t()) :: Path.t() | nil
  def real_path(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> resolve_segments("/", 0)
  end

  defp resolve_segments(_segments, _resolved, hops) when hops > @max_symlink_hops, do: nil
  defp resolve_segments([], resolved, _hops), do: resolved

  defp resolve_segments([segment | rest], resolved, hops) do
    candidate = Path.join(resolved, segment)

    case File.read_link(candidate) do
      {:ok, target} ->
        target
        |> Path.expand(resolved)
        |> Path.split()
        |> Kernel.++(rest)
        |> resolve_segments("/", hops + 1)

      {:error, _not_a_symlink_or_missing} ->
        resolve_segments(rest, candidate, hops)
    end
  end
end
