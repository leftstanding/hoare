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
  end
end
