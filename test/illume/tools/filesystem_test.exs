defmodule Illume.Tools.FilesystemTest do
  use ExUnit.Case, async: true

  alias Illume.Tools.Filesystem

  @moduletag :tmp_dir

  test "read_file reads a file within the target dir", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "hello.txt"), "hi")
    assert {:ok, "hi"} = Filesystem.read_file(tmp_dir, %{"path" => "hello.txt"})
  end

  test "read_file rejects a path that escapes the target dir", %{tmp_dir: tmp_dir} do
    assert {:error, message} =
             Filesystem.read_file(tmp_dir, %{"path" => "../../../../etc/passwd"})

    assert message =~ "escapes target directory"
  end

  test "search_files finds files by name pattern within the target dir", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "foo.exs"), "")
    assert {:ok, ["foo.exs"]} = Filesystem.search_files(tmp_dir, %{"pattern" => "*.exs"})
  end

  test "search_files does not leak matches outside the target dir via `..` in the pattern", %{
    tmp_dir: tmp_dir
  } do
    assert {:ok, []} =
             Filesystem.search_files(tmp_dir, %{"pattern" => "*/../../../../../etc/passwd"})

    assert {:ok, []} =
             Filesystem.search_files(tmp_dir, %{"pattern" => "../../../../etc/passwd"})
  end

  test "read_file rejects non-UTF-8 (binary) content", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "fake.png")
    File.write!(path, <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 1, 2, 0xFF, 0xFE>>)

    assert {:error, message} = Filesystem.read_file(tmp_dir, %{"path" => "fake.png"})
    assert message =~ "not a UTF-8 text file"
  end

  test "read_file truncates an oversized file at a valid UTF-8 boundary, not mid-character", %{
    tmp_dir: tmp_dir
  } do
    # "中" is 3 bytes — pad so the byte cap lands inside a multi-byte run.
    content = String.duplicate("a", 299_999) <> String.duplicate("中", 10)
    File.write!(Path.join(tmp_dir, "big.txt"), content)

    assert {:ok, result} = Filesystem.read_file(tmp_dir, %{"path" => "big.txt"})
    assert String.valid?(result)
    assert result =~ "truncated"
  end

  test "read_file rejects a symlink inside the target dir pointing outside it", %{
    tmp_dir: tmp_dir
  } do
    outside_dir =
      Path.join(System.tmp_dir!(), "illume_fs_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside_dir)
    File.write!(Path.join(outside_dir, "secret.txt"), "top secret")
    on_exit(fn -> File.rm_rf!(outside_dir) end)

    File.ln_s!(outside_dir, Path.join(tmp_dir, "escape"))

    assert {:error, message} = Filesystem.read_file(tmp_dir, %{"path" => "escape/secret.txt"})
    assert message =~ "escapes target directory"
  end
end
