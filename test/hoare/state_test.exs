defmodule Hoare.StateTest do
  use ExUnit.Case, async: true

  alias Hoare.State

  defmodule Bare do
    @behaviour State
    defstruct [:record]
    def status, do: :BARE
    def missing, do: :not_bare
    def properties, do: []
  end

  defmodule Refined do
    @behaviour State
    defstruct [:record, :first, :second]
    def status, do: :REFINED
    def missing, do: :not_refined
    def properties, do: [&first/1, &second/1]

    defp first(%Refined{record: %{first: nil}}), do: {:error, :no_first}
    defp first(%Refined{record: %{first: first}} = state), do: {:ok, %{state | first: first}}

    defp second(%Refined{record: %{second: nil}}), do: {:error, :no_second}
    defp second(%Refined{record: %{second: second}} = state), do: {:ok, %{state | second: second}}
  end

  defmodule Reserved do
    use State, witnesses: [:reservation]

    @impl State
    def properties, do: [&reservation/1]

    defp reservation(%Reserved{record: %{reservation: nil}}), do: {:error, :not_reserved}

    defp reservation(%Reserved{record: %{reservation: reservation}} = state),
      do: {:ok, %{state | reservation: reservation}}
  end

  defmodule Picked do
    use State, witnesses: [:picked_at]

    @impl State
    def properties, do: [&picked_at/1]

    defp picked_at(%Picked{record: %{picked_at: nil}}), do: {:error, :not_picked}

    defp picked_at(%Picked{record: %{picked_at: picked_at}} = state),
      do: {:ok, %{state | picked_at: picked_at}}
  end

  defmodule Shipped do
    use State, status: :SHIPPED, field: :line_status
  end

  describe "match/2" do
    test "builds a bare state from a record its status tags" do
      assert State.match(Bare, %{status: :BARE}) == {:ok, %Bare{record: %{status: :BARE}}}
    end

    test "returns the missing reason when the status does not tag the record" do
      assert State.match(Bare, %{status: :OTHER}) == {:error, :not_bare}
    end

    test "threads the witnesses through every property" do
      record = %{status: :REFINED, first: 1, second: 2}

      assert State.match(Refined, record) == {:ok, %Refined{record: record, first: 1, second: 2}}
    end

    test "returns the first failing property's reason" do
      assert State.match(Refined, %{status: :REFINED, first: nil, second: nil}) ==
               {:error, :no_first}

      assert State.match(Refined, %{status: :REFINED, first: 1, second: nil}) ==
               {:error, :no_second}
    end

    test "an untagged state is decided by its properties alone" do
      record = %{reservation: "r-1"}

      assert State.match(Reserved, record) == {:ok, %Reserved{record: record, reservation: "r-1"}}
      assert State.match(Reserved, %{reservation: nil}) == {:error, :not_reserved}
    end

    test "reads the tag from the declared field" do
      record = %{status: :OPEN, line_status: :SHIPPED}

      assert State.match(Shipped, record) == {:ok, %Shipped{record: record}}
      assert State.match(Shipped, %{record | line_status: :PENDING}) == {:error, :not_shipped}
    end
  end

  describe "tag/1" do
    test "names the field and value a tagged state reads, and nothing for an untagged one" do
      assert State.tag(Bare) == {:status, :BARE}
      assert State.tag(Shipped) == {:line_status, :SHIPPED}
      assert State.tag(Reserved) == nil
    end
  end

  describe "match_any/2" do
    test "the state whose status tags the record decides" do
      assert State.match_any([Bare, Refined], %{status: :BARE}) ==
               {:ok, %Bare{record: %{status: :BARE}}}

      assert State.match_any([Bare, Refined], %{status: :REFINED, first: nil, second: nil}) ==
               {:error, :no_first}
    end

    test "reports the first state's missing reason when none tags the record" do
      assert State.match_any([Bare, Refined], %{status: :OTHER}) == {:error, :not_bare}
    end

    test "tries untagged states in declared order" do
      record = %{reservation: nil, picked_at: ~U[2026-09-23 00:00:00Z]}

      assert State.match_any([Reserved, Picked], record) ==
               {:ok, %Picked{record: record, picked_at: ~U[2026-09-23 00:00:00Z]}}
    end

    test "reports the first untagged state's failing property when none matches" do
      assert State.match_any([Reserved, Picked], %{reservation: nil, picked_at: nil}) ==
               {:error, :not_reserved}
    end

    test "a tag decides over the untagged states, whatever their order" do
      record = %{status: :BARE, reservation: "r-1"}

      assert State.match_any([Reserved, Bare], record) == {:ok, %Bare{record: record}}
    end

    test "falls through to the untagged states when no tag matches" do
      record = %{status: :OTHER, reservation: "r-1"}

      assert State.match_any([Bare, Reserved], record) ==
               {:ok, %Reserved{record: record, reservation: "r-1"}}
    end

    test "prefers the earliest declared reason when a tagged state leads" do
      assert State.match_any([Bare, Reserved], %{status: :OTHER, reservation: nil}) ==
               {:error, :not_bare}
    end
  end

  defmodule Declared do
    import Hoare.State, only: [defstate: 2, defstate: 3]

    defstate Open, status: :OPEN
    defstate Closed, status: :CLOSED, missing: :still_open, preloads: [:closer]

    defstate Signed, status: :SIGNED_OFF, witnesses: [:signer] do
      @impl Hoare.State
      def properties, do: [&signer/1]

      defp signer(%__MODULE__{record: %{signer: nil}}), do: {:error, :unsigned}

      defp signer(%__MODULE__{record: %{signer: signer}} = state),
        do: {:ok, %{state | signer: signer}}
    end
  end

  describe "use Hoare.State" do
    alias Declared.Closed
    alias Declared.Open
    alias Declared.Signed

    test "declares a status-only state, its missing reason derived from the status" do
      assert State.match(Open, %{status: :OPEN}) == {:ok, %Open{record: %{status: :OPEN}}}
      assert State.match(Open, %{status: :CLOSED}) == {:error, :not_open}
      assert State.preloads(Open) == []
    end

    test "takes the missing reason and the preloads it is given" do
      assert State.match(Closed, %{status: :OPEN}) == {:error, :still_open}
      assert State.preloads(Closed) == [:closer]
    end

    test "fills declared witnesses through overridden properties" do
      record = %{status: :SIGNED_OFF, signer: "ada"}

      assert State.match(Signed, record) == {:ok, %Signed{record: record, signer: "ada"}}
      assert State.match(Signed, %{record | signer: nil}) == {:error, :unsigned}
      assert State.match(Signed, %{status: :OPEN}) == {:error, :not_signed_off}
    end

    test "the declaring module holds its states in declared order" do
      assert Declared.all() == [Declared.Open, Declared.Closed, Declared.Signed]
    end
  end

  defmodule Overlapping do
    import Hoare.State, only: [defstate: 3]

    defstate Held, witnesses: [:hold] do
      @impl Hoare.State
      def properties, do: [&hold/1]

      defp hold(%__MODULE__{record: %{hold: nil}}), do: {:error, :not_held}
      defp hold(%__MODULE__{record: %{hold: hold}} = state), do: {:ok, %{state | hold: hold}}
    end

    defstate Flagged, witnesses: [:flag] do
      @impl Hoare.State
      def properties, do: [&flag/1]

      defp flag(%__MODULE__{record: %{flag: nil}}), do: {:error, :not_flagged}
      defp flag(%__MODULE__{record: %{flag: flag}} = state), do: {:ok, %{state | flag: flag}}
    end
  end

  describe "classify/2" do
    alias Declared.Open
    alias Overlapping.Flagged
    alias Overlapping.Held

    test "returns the one state the record is in" do
      record = %{status: :OPEN}

      assert State.classify(Declared.all(), record) == {:ok, %Open{record: record}}
    end

    test "is unclassified when no state matches" do
      assert State.classify(Declared.all(), %{status: :ARCHIVED}) == {:error, :unclassified}

      assert State.classify(Overlapping.all(), %{hold: nil, flag: nil}) ==
               {:error, :unclassified}
    end

    test "names every state a record matches when more than one does" do
      assert State.classify(Overlapping.all(), %{hold: "h-1", flag: "f-1"}) ==
               {:error, {:ambiguous, [Held, Flagged]}}
    end

    test "the declaring module classifies over its own states" do
      record = %{hold: "h-1", flag: nil}

      assert Overlapping.classify(record) == {:ok, %Held{record: record, hold: "h-1"}}
    end
  end
end
