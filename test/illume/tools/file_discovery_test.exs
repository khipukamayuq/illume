defmodule Illume.Tools.FileDiscoveryTest do
  use ExUnit.Case, async: true

  alias Illume.Tools.FileDiscovery

  @moduletag :tmp_dir

  test "in a git repo, respects that repo's own .gitignore", %{tmp_dir: tmp_dir} do
    System.cmd("git", ["init", "-q"], cd: tmp_dir)
    File.write!(Path.join(tmp_dir, ".gitignore"), "ignored_dir/\n")
    File.mkdir_p!(Path.join(tmp_dir, "ignored_dir"))
    File.write!(Path.join(tmp_dir, "ignored_dir/noise.ex"), "")
    File.write!(Path.join(tmp_dir, "real.ex"), "")

    files = FileDiscovery.list(tmp_dir)

    assert "real.ex" in files
    assert ".gitignore" in files
    refute Enum.any?(files, &String.starts_with?(&1, "ignored_dir"))
  end

  test "in a git repo, includes untracked-but-not-ignored files too", %{tmp_dir: tmp_dir} do
    System.cmd("git", ["init", "-q"], cd: tmp_dir)
    File.write!(Path.join(tmp_dir, "untracked.ex"), "")

    assert "untracked.ex" in FileDiscovery.list(tmp_dir)
  end

  test "outside a git repo, falls back to a plain walk skipping the static ignore list", %{
    tmp_dir: tmp_dir
  } do
    File.mkdir_p!(Path.join(tmp_dir, "_build"))
    File.write!(Path.join(tmp_dir, "_build/noise.ex"), "")
    File.write!(Path.join(tmp_dir, "real.ex"), "")

    files = FileDiscovery.list(tmp_dir)

    assert "real.ex" in files
    refute Enum.any?(files, &String.starts_with?(&1, "_build"))
  end

  test "the fallback walk rejects a symlinked directory pointing outside the target dir", %{
    tmp_dir: tmp_dir
  } do
    outside_dir =
      Path.join(System.tmp_dir!(), "illume_fd_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside_dir)
    File.write!(Path.join(outside_dir, "secret.ex"), "")
    on_exit(fn -> File.rm_rf!(outside_dir) end)

    File.ln_s!(outside_dir, Path.join(tmp_dir, "escape"))

    refute Enum.any?(FileDiscovery.list(tmp_dir), &String.starts_with?(&1, "escape"))
  end
end
