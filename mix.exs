defmodule Hoare.MixProject do
  use Mix.Project

  def project do
    [
      app: :hoare,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: [],
      description:
        "Declared state transitions as pre/post contracts: states, guards, undoable effects, one locked commit.",
      package: [licenses: ["MIT"], links: %{}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
