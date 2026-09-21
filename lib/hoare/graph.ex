defmodule Hoare.Graph do
  @moduledoc """
  The graph a list of transition modules declares: states as vertices, each
  transition an edge from every state it leaves to the one it reaches.

  The list is explicit, kept wherever the record's transitions are known.
  Assert on `edges/1` so a change to the graph is a deliberate diff, or paste
  `to_mermaid/1` into the docs.
  """

  @type edge :: {from :: module(), via :: module(), to :: module()}

  @spec edges([module()]) :: [edge()]
  def edges(transitions) do
    for via <- transitions,
        %{from: from, to: to} = via.transition(),
        state <- from,
        do: {state, via, to}
  end

  @doc "The states the transitions name, in first-seen order."
  @spec states([module()]) :: [module()]
  def states(transitions) do
    transitions
    |> edges()
    |> Enum.flat_map(fn {from, _via, to} -> [from, to] end)
    |> Enum.uniq()
  end

  @doc "A Mermaid `stateDiagram-v2`, modules labelled by their last segment."
  @spec to_mermaid([module()]) :: String.t()
  def to_mermaid(transitions) do
    transitions
    |> edges()
    |> Enum.map_join("\n", fn {from, via, to} ->
      "    #{label(from)} --> #{label(to)}: #{label(via)}"
    end)
    |> then(&"stateDiagram-v2\n#{&1}\n")
  end

  defp label(module), do: module |> Module.split() |> List.last()
end
