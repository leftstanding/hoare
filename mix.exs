defmodule Hoare.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/leftstanding/hoare"

  def project do
    [
      app: :hoare,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      description:
        "Declared state transitions as pre/post contracts: states, guards, undoable effects, one locked commit.",
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp deps, do: [{:ex_doc, "~> 0.34", only: :dev, runtime: false}]
end
