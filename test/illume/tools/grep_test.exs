defmodule Illume.Tools.GrepTest do
  use ExUnit.Case, async: true

  alias Illume.Tools.Grep

  @moduletag :tmp_dir

  test "finds a fixed-string match and reports the relative path", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "foo.ex"), "def needle, do: :ok")

    assert {:ok, output} = Grep.grep_content(tmp_dir, %{"pattern" => "needle"})
    assert output =~ "foo.ex"
    assert output =~ "needle"
  end

  test "respects the target dir's own .gitignore when it's a git repo", %{tmp_dir: tmp_dir} do
    System.cmd("git", ["init", "-q"], cd: tmp_dir)
    File.write!(Path.join(tmp_dir, ".gitignore"), "ignored_dir/\n")
    File.mkdir_p!(Path.join(tmp_dir, "ignored_dir"))
    File.write!(Path.join(tmp_dir, "ignored_dir/noise.ex"), "def needle, do: :ok")
    File.write!(Path.join(tmp_dir, "real.ex"), "def needle, do: :ok")

    assert {:ok, output} = Grep.grep_content(tmp_dir, %{"pattern" => "needle"})
    assert output =~ "real.ex"
    refute output =~ "ignored_dir"
  end

  test "reports no matches without treating it as an error", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "foo.ex"), "nothing interesting here")
    assert Grep.grep_content(tmp_dir, %{"pattern" => "needle"}) == {:ok, "no matches"}
  end

  test "treats the pattern as a fixed string, not a regex", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "foo.ex"), "a.b")
    assert {:ok, output} = Grep.grep_content(tmp_dir, %{"pattern" => "a.b"})
    assert output =~ "foo.ex"
    assert Grep.grep_content(tmp_dir, %{"pattern" => "axb"}) == {:ok, "no matches"}
  end

  test "caps matches per file so one huge file can't blow up the result", %{tmp_dir: tmp_dir} do
    content = Enum.map_join(1..1000, "\n", &"needle line #{&1}")
    File.write!(Path.join(tmp_dir, "big.txt"), content)

    assert {:ok, output} = Grep.grep_content(tmp_dir, %{"pattern" => "needle"})
    assert length(String.split(output, "\n")) == 20
  end

  # The per-file cap (above) and the total-output cap used to be the same
  # number, which meant a single prolific file could consume the *entire*
  # output budget by itself — a second file's real matches would be
  # silently absent from the result, with nothing in the output
  # indicating any other file was ever searched (see DECISIONS.md).
  test "a noisy file does not crowd out a second file's matches entirely", %{tmp_dir: tmp_dir} do
    File.write!(
      Path.join(tmp_dir, "a_noisy_file.ex"),
      Enum.map_join(1..300, "\n", &"needle line #{&1}")
    )

    File.write!(Path.join(tmp_dir, "b_specific_file.ex"), "needle one\nneedle two")

    assert {:ok, output} = Grep.grep_content(tmp_dir, %{"pattern" => "needle"})
    assert output =~ "a_noisy_file.ex"
    assert output =~ "b_specific_file.ex"
  end

  test "rejects a subdirectory path that escapes the target dir", %{tmp_dir: tmp_dir} do
    assert {:error, message} =
             Grep.grep_content(tmp_dir, %{"pattern" => "needle", "path" => "../../../../etc"})

    assert message =~ "escapes target directory"
  end

  # A regression this exact tool shipped: `grep -r` never followed a
  # symlinked file named only by its recursive directory walk, but this
  # module passes each `FileDiscovery`-listed file to `grep` as an explicit
  # argument, and `grep` *does* follow a symlink named directly. A
  # git-tracked symlink pointing outside the target dir leaked its content
  # until `FileDiscovery.list/1` started confinement-checking its git-path
  # results too (see DECISIONS.md).
  test "does not follow a tracked symlink pointing outside the target dir", %{tmp_dir: tmp_dir} do
    outside_dir =
      Path.join(System.tmp_dir!(), "illume_grep_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside_dir)
    File.write!(Path.join(outside_dir, "secret.ex"), "def needle, do: :top_secret")
    on_exit(fn -> File.rm_rf!(outside_dir) end)

    System.cmd("git", ["init", "-q"], cd: tmp_dir)
    File.ln_s!(Path.join(outside_dir, "secret.ex"), Path.join(tmp_dir, "innocuous.ex"))
    System.cmd("git", ["add", "innocuous.ex"], cd: tmp_dir)

    assert Grep.grep_content(tmp_dir, %{"pattern" => "needle"}) == {:ok, "no matches"}
  end

  # Another regression the explicit-file-list design (above) introduced:
  # `grep -r` silently skips a broken symlink during its own recursive
  # walk, but a discovered-and-listed broken symlink passed as an explicit
  # argument makes `grep` exit 2 ("No such file or directory") for that
  # one operand — which used to abort the *entire* search, discarding any
  # real matches already found in the same batch (see DECISIONS.md).
  #
  # `File.regular?/1` (the fallback walk's own filter) already excludes a
  # broken symlink, so this needs the git-aware path specifically — `git
  # ls-files` lists a tracked symlink regardless of whether its target
  # exists — to actually reach `grep` with one.
  test "a broken symlink alongside a real match does not abort the whole search", %{
    tmp_dir: tmp_dir
  } do
    File.write!(Path.join(tmp_dir, "real.ex"), "def needle, do: :ok")
    File.ln_s!("does_not_exist_target", Path.join(tmp_dir, "broken_link.ex"))
    System.cmd("git", ["init", "-q"], cd: tmp_dir)
    System.cmd("git", ["add", "-A"], cd: tmp_dir)

    assert {:ok, output} = Grep.grep_content(tmp_dir, %{"pattern" => "needle"})
    assert output =~ "real.ex"
    refute output =~ "No such file"
  end

  test "a broken symlink with no other matches is a clean no-matches, not an error", %{
    tmp_dir: tmp_dir
  } do
    File.ln_s!("does_not_exist_target", Path.join(tmp_dir, "broken_link.ex"))
    System.cmd("git", ["init", "-q"], cd: tmp_dir)
    System.cmd("git", ["add", "-A"], cd: tmp_dir)

    assert Grep.grep_content(tmp_dir, %{"pattern" => "needle"}) == {:ok, "no matches"}
  end
end
