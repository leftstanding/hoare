defmodule Hoare.State do
  @moduledoc """
  A named record state: the status that tags it and the properties that refine
  it.

  A state module is a struct of witnesses, `record` plus whatever its
  properties extract, and `match/2` builds it or says why the record is not in
  that state. A `Hoare.Transition` names states as its `from` and `to`.

      defmodule Issued do
        use Hoare.State, status: :issued, witnesses: [:lines], preloads: [:lines]

        @impl Hoare.State
        def properties, do: [&billable_lines/1]

        defp billable_lines(%Issued{record: %{lines: []}}), do: {:error, :no_lines}
        defp billable_lines(%Issued{record: %{lines: lines}} = state), do: {:ok, %{state | lines: lines}}
      end

      Hoare.State.match(Issued, invoice)
      #=> {:ok, %Issued{record: invoice, lines: [...]}} | {:error, :not_issued | :no_lines}

  A property is an arrow over the state struct: it refines the tag, and may
  fill a witness so nothing downstream has to look again. `use` is a
  convenience over the behaviour; a module may implement the callbacks and
  define the struct itself. `defstate/3` declares several states in one module.
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

  @doc "What the record must have loaded for the properties to read it."
  @callback preloads() :: [term()]

  @optional_callbacks preloads: 0

  @doc """
  Declares the state from its options; `properties/0` stays overridable.

      use Hoare.State, status: :issued, witnesses: [:lines], preloads: [:lines]

  `:missing` defaults to `:not_<status>`, downcased; `:witnesses` are the
  struct's keys after `record`; `:preloads` defaults to none. The struct's
  type is `t/0`.
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Hoare.State

      @hoare_status Keyword.fetch!(opts, :status)
      @hoare_missing Keyword.get_lazy(opts, :missing, fn ->
                       :"not_#{@hoare_status |> to_string() |> String.downcase()}"
                     end)
      @hoare_preloads Keyword.get(opts, :preloads, [])

      defstruct [:record | Keyword.get(opts, :witnesses, [])]

      @type t :: %__MODULE__{}

      @impl Hoare.State
      def status, do: @hoare_status

      @impl Hoare.State
      def missing, do: @hoare_missing

      @impl Hoare.State
      def preloads, do: @hoare_preloads

      @impl Hoare.State
      def properties, do: []

      defoverridable properties: 0
    end
  end

  @doc """
  Declares a state as a module nested in the caller, so one module holds a
  record's states and each stays a struct of its own.

      defmodule Invoice.State do
        import Hoare.State, only: [defstate: 2, defstate: 3]

        defstate Draft, status: :draft
        defstate Paid, status: :paid

        defstate Issued, status: :issued, witnesses: [:lines], preloads: [:lines] do
          @impl Hoare.State
          def properties, do: [&billable_lines/1]
          ...
        end
      end

  The states are `Invoice.State.Draft` and so on. Add `import_deps: [:hoare]`
  to `.formatter.exs` to keep `defstate` free of parentheses.
  """
  defmacro defstate(name, opts, block \\ [do: nil]) do
    quote do
      defmodule unquote(name) do
        use Hoare.State, unquote(opts)
        unquote(block[:do])
      end
    end
  end

  @doc "The state's declared preloads; none when it declares none."
  @spec preloads(module()) :: [term()]
  def preloads(state) do
    Code.ensure_loaded!(state)
    if function_exported?(state, :preloads, 0), do: state.preloads(), else: []
  end

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
