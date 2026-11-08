defmodule ExJS.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_js,
      version: "0.2.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      description: description(),
      package: package(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    "JavaScript execution for Elixir, powered by the Kiesel engine embedded as a Zig NIF."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"Kiesel" => "https://kiesel.dev"},
      files:
        ~w(lib native/ex_js_nif/build.zig native/ex_js_nif/build.zig.zon
                 native/ex_js_nif/src native/ex_js_nif/vendor mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp deps do
    []
  end

  defp aliases do
    [
      compile: ["ex_js.build_nif", "compile"],
      clean: ["clean", &clean_nif/1]
    ]
  end

  defp clean_nif(_) do
    File.rm_rf!("priv")
    File.rm_rf!("native/ex_js_nif/zig-out")
    File.rm_rf!("native/ex_js_nif/.zig-cache")
  end
end
