defmodule Illume.Tools.Git do
  @moduledoc """
  Direct-call implementations of the read-only git tools, shelling out to
  the `git` CLI confined to the target directory.
  """

  @default_max_count 20

  @doc """
  Show recent commit log. `input` is `%{}` or `%{"max_count" => integer}`.
  """
  @spec git_log(Path.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def git_log(target_dir, input) do
    max_count = max_count(input)

    run(target_dir, [
      "log",
      "--max-count=#{max_count}",
      "--date=short",
      "--pretty=format:%h %ad %an — %s"
    ])
  end

  @doc """
  Show a single commit's message and diff. `input` is
  `%{"revision" => git_revision}`.
  """
  @spec git_show(Path.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def git_show(target_dir, %{"revision" => revision}) do
    if String.starts_with?(revision, "-") do
      {:error, "invalid revision: #{revision}"}
    else
      run(target_dir, ["show", "--stat", "-p", revision])
    end
  end

  def git_show(_target_dir, _input), do: {:error, "missing required input: revision"}

  @spec max_count(map()) :: pos_integer()
  defp max_count(%{"max_count" => n}) when is_integer(n) and n > 0, do: n
  defp max_count(_input), do: @default_max_count

  @spec run(Path.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  defp run(target_dir, args) do
    if File.dir?(Path.join(target_dir, ".git")) do
      case System.cmd("git", args, cd: target_dir, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, _status} -> {:error, "git #{Enum.join(args, " ")} failed: #{output}"}
      end
    else
      {:error, "not a git repository: #{target_dir}"}
    end
  end
end
