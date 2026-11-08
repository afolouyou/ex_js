defmodule Mix.Tasks.ExJs.BuildNif do
  use Mix.Task

  @shortdoc "Compiles the ExJS Zig NIF with Kiesel"

  def run(_args) do
    nif_dir = Path.join(File.cwd!(), "native/ex_js_nif")
    priv_dir = Path.join(File.cwd!(), "priv")
    kiesel_link = Path.join(nif_dir, "kiesel_src")

    File.mkdir_p!(priv_dir)

    kiesel_path = resolve_kiesel_path(nif_dir)

    erl_root = :code.root_dir() |> to_string()
    erl_include = Path.join(erl_root, "usr/include")

    unless File.dir?(erl_include) do
      raise "Erlang include directory not found at #{erl_include}"
    end

    link_dir(kiesel_link, kiesel_path, nif_dir)
    link_dir(Path.join(nif_dir, "erl_include"), erl_include, nif_dir)

    Mix.shell().info("Compiling ExJS NIF...")
    Mix.shell().info("Kiesel source: #{kiesel_path}")

    case System.cmd("zig", ["build", "-Doptimize=ReleaseSafe"],
           cd: nif_dir,
           into: IO.stream(:stdio, :line),
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        Mix.shell().info("ExJS NIF compiled successfully.")
        :ok

      {_, status} ->
        Mix.raise("Failed to compile ExJS NIF (exit code #{status})")
    end
  end

  defp resolve_kiesel_path(nif_dir) do
    case System.get_env("KIESEL_PATH") do
      nil ->
        Path.join(nif_dir, "vendor/kiesel")

      path ->
        unless File.dir?(path) do
          raise "KIESEL_PATH does not exist or is not a directory: #{path}"
        end

        Path.expand(path)
    end
  end

  defp link_dir(link_path, target_path, base_dir) do
    File.rm_rf!(link_path)
    relative = Path.relative_to(target_path, base_dir)

    case File.ln_s(relative, link_path) do
      :ok ->
        Mix.shell().info("Linked #{link_path} -> #{relative}")

      {:error, reason} ->
        Mix.raise("Failed to create symlink #{link_path}: #{inspect(reason)}")
    end
  end
end
