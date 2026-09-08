defmodule Illume.Tools.GitTest do
  use ExUnit.Case, async: true

  alias Illume.Tools.Git

  @moduletag :tmp_dir

  defp init_repo(dir) do
    {_, 0} = System.cmd("git", ["init", "--initial-branch=main"], cd: dir, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: dir)
    :ok
  end

  defp commit!(dir, filename, content, message) do
    File.write!(Path.join(dir, filename), content)
    {_, 0} = System.cmd("git", ["add", filename], cd: dir)
    {_, 0} = System.cmd("git", ["commit", "-m", message], cd: dir, stderr_to_stdout: true)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    String.trim(sha)
  end

  test "git_log returns an error for a directory that is not a git repo", %{tmp_dir: tmp_dir} do
    assert {:error, message} = Git.git_log(tmp_dir, %{})
    assert message =~ "not a git repository"
  end

  test "git_log lists commits, most recent first, respecting max_count", %{tmp_dir: tmp_dir} do
    init_repo(tmp_dir)
    commit!(tmp_dir, "a.txt", "a", "first commit")
    commit!(tmp_dir, "b.txt", "b", "second commit")

    assert {:ok, log} = Git.git_log(tmp_dir, %{})
    assert log =~ "first commit"
    assert log =~ "second commit"

    assert {:ok, one_line} = Git.git_log(tmp_dir, %{"max_count" => 1})
    assert one_line =~ "second commit"
    refute one_line =~ "first commit"
  end

  test "git_log ignores a non-positive-integer max_count and uses the default", %{
    tmp_dir: tmp_dir
  } do
    init_repo(tmp_dir)
    commit!(tmp_dir, "a.txt", "a", "only commit")

    assert {:ok, log} = Git.git_log(tmp_dir, %{"max_count" => "not a number"})
    assert log =~ "only commit"
  end

  test "git_show shows a commit's message and diff", %{tmp_dir: tmp_dir} do
    init_repo(tmp_dir)
    sha = commit!(tmp_dir, "a.txt", "hello", "add a.txt")

    assert {:ok, output} = Git.git_show(tmp_dir, %{"revision" => sha})
    assert output =~ "add a.txt"
    assert output =~ "hello"
  end

  test "git_show returns an error for an unresolvable revision", %{tmp_dir: tmp_dir} do
    init_repo(tmp_dir)
    commit!(tmp_dir, "a.txt", "hello", "add a.txt")

    assert {:error, _message} = Git.git_show(tmp_dir, %{"revision" => "not-a-real-revision"})
  end

  test "git_show does not itself validate the revision — that's Illume.Tools.validate_input/3's job",
       %{tmp_dir: tmp_dir} do
    init_repo(tmp_dir)
    commit!(tmp_dir, "a.txt", "hello", "add a.txt")

    # git's own `--` only disambiguates paths from revisions — it doesn't
    # shield a revision from being parsed as a flag, so a leading-dash
    # revision reaching git_show/2 directly (bypassing Tools.dispatch/4)
    # is git's own problem, not this function's. Confirmed safe here only
    # because git rejects this particular unrecognized option itself;
    # Illume.Tools.validate_input/3 is what actually has to catch this
    # before it ever reaches here — see tools_test.exs.
    assert {:error, message} =
             Git.git_show(tmp_dir, %{"revision" => "--upload-pack=touch /tmp/pwned"})

    assert message =~ "unrecognized argument"
  end

  test "git_show requires a revision" do
    assert {:error, message} = Git.git_show("/tmp", %{})
    assert message =~ "missing required input: revision"
  end
end
