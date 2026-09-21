defmodule Hoare.GraphTest do
  use ExUnit.Case, async: true

  import Hoare.State, only: [defstate: 2]

  alias Hoare.Graph

  defstate Draft, status: :draft
  defstate Issued, status: :issued
  defstate Paid, status: :paid
  defstate Void, status: :void

  defmodule Issue do
    use Hoare.Transition, from: [Draft], to: Issued
  end

  defmodule Pay do
    use Hoare.Transition, from: [Issued], to: Paid
  end

  defmodule Cancel do
    use Hoare.Transition, from: [Draft, Issued], to: Void
  end

  @transitions [Issue, Pay, Cancel]

  test "edges/1 is one edge per state a transition leaves" do
    assert Graph.edges(@transitions) == [
             {Draft, Issue, Issued},
             {Issued, Pay, Paid},
             {Draft, Cancel, Void},
             {Issued, Cancel, Void}
           ]
  end

  test "states/1 is every state named, once" do
    assert Graph.states(@transitions) == [Draft, Issued, Paid, Void]
  end

  test "to_mermaid/1 draws the state diagram" do
    assert Graph.to_mermaid(@transitions) == """
           stateDiagram-v2
               Draft --> Issued: Issue
               Issued --> Paid: Pay
               Draft --> Void: Cancel
               Issued --> Void: Cancel
           """
  end
end
