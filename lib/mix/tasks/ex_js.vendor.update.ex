defmodule Mix.Tasks.ExJs.Vendor.Update do
  use Mix.Task

  @shortdoc "Vendoriza uma revisão do Kiesel"

  @moduledoc """
  Copia o código-fonte do Kiesel para `native/ex_js_nif/vendor/kiesel`.

      mix ex_js.vendor.update --ref main
      mix ex_js.vendor.update --repo /caminho/local --ref HEAD

  Opções:

    * `:ref` - branch, tag ou commit (padrão: `main`)
    * `:repo` - URL ou caminho do repositório
      (padrão: `https://codeberg.org/kiesel-js/kiesel`)
  """

  @default_repo "https://codeberg.org/kiesel-js/kiesel"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [ref: :string, repo: :string]
      )

    repo = opts[:repo] || @default_repo
    ref = opts[:ref] || "main"

    vendor_dir = Path.join(File.cwd!(), "native/ex_js_nif/vendor/kiesel")
    tmp_dir = Path.join(System.tmp_dir!(), "ex_js_kiesel_vendor")

    File.rm_rf!(tmp_dir)

    try do
      Mix.shell().info("Clonando #{repo} (#{ref})...")
      git!(["clone", "--quiet", repo, tmp_dir])
      git!(["-C", tmp_dir, "checkout", "--quiet", ref])

      copy_vendor(tmp_dir, vendor_dir, ref, repo)

      Mix.shell().info("Kiesel vendorizado em #{vendor_dir}")
      Mix.shell().info("Revise as mudanças e rode: mix compile && mix test")
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp copy_vendor(source, destination, ref, repo) do
    File.rm_rf!(destination)
    File.mkdir_p!(Path.join(destination, "pkg"))

    File.cp_r!(Path.join(source, "src"), Path.join(destination, "src"))

    for pkg <- ["libregexp", "temporal_rs", "zement"] do
      File.cp_r!(Path.join(source, "pkg/#{pkg}"), Path.join(destination, "pkg/#{pkg}"))
    end

    for file <- ["build.zig", "build.zig.zon", "LICENSE"] do
      File.cp!(Path.join(source, file), Path.join(destination, file))
    end

    commit = git!(["-C", source, "rev-parse", "HEAD"]) |> String.trim()

    describe =
      case System.cmd("git", ["-C", source, "describe", "--tags", "--abbrev=9"],
             stderr_to_stdout: true
           ) do
        {out, 0} -> String.trim(out)
        _ -> "unknown"
      end

    version =
      case File.read(Path.join(source, "build.zig.zon")) do
        {:ok, zon} ->
          case Regex.run(~r/\.version\s*=\s*"([^"]+)"/, zon) do
            [_, version] -> version
            _ -> "unknown"
          end

        _ ->
          "unknown"
      end

    File.write!(Path.join(destination, "REVISION"), """
    repository=#{repo}
    commit=#{commit}
    describe=#{describe}
    version=#{version}
    license=MIT
    """)

    Mix.shell().info("Revisão #{ref} -> #{commit}")
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, status} -> Mix.raise("git #{Enum.join(args, " ")} falhou (#{status}):\n#{out}")
    end
  end
end
