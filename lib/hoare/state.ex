defmodule Hoare.State do
  @moduledoc """
  A named record state: the status that tags it and the properties that refine
  it.

  A state module is a struct of witnesses, `record` plus whatever its
  properties extract, and `match/2` builds it or says why the record is not in
  that state. A `Hoare.Transition` names states as its `from` and `to`.

      defmodule PendingUnpack do
        @behaviour Hoare.State
        defstruct [:record, :package]

        def status, do: :PENDING_UNPACK
        def missing, do: :not_pending_unpack
        def properties, do: [&single_package/1]

        defp single_package(%{record: %{packages: [package]}} = state),
          do: {:ok, %{state | package: package}}

        defp single_package(%{record: %{packages: []}}), do: {:error, :no_packages}
        defp single_package(_state), do: {:error, :multiple_packages}
      end
  """

  import Hoare.Result, only: [kleisli: 1]

  @type reason :: atom()
  @type subject :: %{:status => atom(), optional(atom()) => term()}
  @type property :: (struct() -> {:ok, struct()} | {:error, reason()})

  @doc "The status value that tags a record as being in this state."
  @callback status() :: atom()

  @doc "The reason reported when a record's status does not tag it."
  @callback missing() :: reason()

  @doc "Arrows over the state struct that refine the tag and fill its witnesses."
  @callback properties() :: [property()]

  @spec match(module(), subject()) :: {:ok, struct()} | {:error, reason()}
  def match(state, %{status: status} = record) do
    if status == state.status(),
      do: kleisli(state.properties()).(struct!(state, record: record)),
      else: {:error, state.missing()}
  end

  @doc """
  Matches a sum of states: the first whose status tags the record decides.

  When no state tags the record, the first state's `missing/0` is the reason.
  """
  @spec match_any([module(), ...], subject()) :: {:ok, struct()} | {:error, reason()}
  def match_any([first | _] = states, %{status: status} = record) do
    case Enum.find(states, &(&1.status() == status)) do
      nil -> {:error, first.missing()}
      state -> match(state, record)
    end
  end
end
