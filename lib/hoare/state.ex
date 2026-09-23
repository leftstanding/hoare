defmodule Hoare.State do
  @moduledoc """
  A named record state: the tag that names it and the properties that refine
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

  The tag is read from `:status` unless `field:` names another column, and a
  state that declares no `status:` is untagged: it *is* its properties, which
  alone decide whether the record is in it.

      defmodule Reserved do
        use Hoare.State, witnesses: [:reservation], preloads: [:reservation]

        @impl Hoare.State
        def properties, do: [&reserved/1]

        defp reserved(%Reserved{record: %{reservation: nil}}), do: {:error, :not_reserved}
        defp reserved(%Reserved{record: %{reservation: r}} = state), do: {:ok, %{state | reservation: r}}
      end

  A property is an arrow over the state struct: it refines the tag, and may
  fill a witness so nothing downstream has to look again. `use` is a
  convenience over the behaviour; a module may implement the callbacks and
  define the struct itself. `defstate/3` declares several states in one module.
  """

  import Hoare.Result, only: [kleisli: 1]

  @type reason :: atom()
  @type subject :: %{optional(atom()) => term()}
  @type tag :: {field :: atom(), value :: atom()} | nil
  @type property :: (struct() -> {:ok, struct()} | {:error, reason()})

  @doc "The value that tags a record as being in this state; undefined when the state is untagged."
  @callback status() :: atom()

  @doc "The record field the tag is read from; `:status` unless declared."
  @callback field() :: atom()

  @doc "The reason reported when the record's tag does not tag it."
  @callback missing() :: reason()

  @doc "Arrows over the state struct that refine the tag and fill its witnesses."
  @callback properties() :: [property()]

  @doc "What the record must have loaded for the properties to read it."
  @callback preloads() :: [term()]

  @optional_callbacks preloads: 0, status: 0, field: 0, missing: 0

  @doc """
  Declares the state from its options; `properties/0` stays overridable.

      use Hoare.State, status: :issued, witnesses: [:lines], preloads: [:lines]
      use Hoare.State, status: :SHIPPED, field: :line_status
      use Hoare.State, witnesses: [:reservation]

  `:status` is the tag, read from `:field` (`:status` unless given); without
  it the state is untagged and its properties alone decide. `:missing`
  defaults to `:not_<status>`, downcased; `:witnesses` are the struct's keys
  after `record`; `:preloads` defaults to none. The struct's type is `t/0`.
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Hoare.State

      @hoare_preloads Keyword.get(opts, :preloads, [])

      defstruct [:record | Keyword.get(opts, :witnesses, [])]

      @type t :: %__MODULE__{}

      if tag = Keyword.get(opts, :status) do
        @hoare_status tag
        @hoare_field Keyword.get(opts, :field, :status)
        @hoare_missing Keyword.get_lazy(opts, :missing, fn ->
                         :"not_#{tag |> to_string() |> String.downcase()}"
                       end)

        @impl Hoare.State
        def status, do: @hoare_status

        @impl Hoare.State
        def field, do: @hoare_field

        @impl Hoare.State
        def missing, do: @hoare_missing
      end

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

  The states are `Invoice.State.Draft` and so on, and the module holding them
  gains `all/0`, the states in declared order, and `classify/1` over them. Add
  `import_deps: [:hoare]` to `.formatter.exs` to keep `defstate` free of
  parentheses.
  """
  defmacro defstate(name, opts, block \\ [do: nil]) do
    quote do
      unless Module.has_attribute?(__MODULE__, :hoare_states) do
        Module.register_attribute(__MODULE__, :hoare_states, accumulate: true)
        @before_compile Hoare.State
      end

      @hoare_states Module.concat(__MODULE__, unquote(name))

      defmodule unquote(name) do
        use Hoare.State, unquote(opts)
        unquote(block[:do])
      end
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      @doc "The states declared here, in declared order."
      @spec all() :: [module(), ...]
      def all, do: Enum.reverse(@hoare_states)

      @doc "The one declared state the record is in; see `Hoare.State.classify/2`."
      @spec classify(Hoare.State.subject()) ::
              {:ok, struct()} | {:error, :unclassified | {:ambiguous, [module(), ...]}}
      def classify(record), do: Hoare.State.classify(all(), record)
    end
  end

  @doc "The state's declared preloads; none when it declares none."
  @spec preloads(module()) :: [term()]
  def preloads(state) do
    Code.ensure_loaded!(state)
    if function_exported?(state, :preloads, 0), do: state.preloads(), else: []
  end

  @doc "The state's tag, `{field, value}`; `nil` when the state is its properties alone."
  @spec tag(module()) :: tag()
  def tag(state) do
    Code.ensure_loaded!(state)
    if function_exported?(state, :status, 0), do: {field(state), state.status()}
  end

  defp field(state),
    do: if(function_exported?(state, :field, 0), do: state.field(), else: :status)

  @doc """
  Builds the state from the record, or says why the record is not in it.

  A tagged state checks its tag, then its properties; an untagged state is its
  properties, so they alone decide.
  """
  @spec match(module(), subject()) :: {:ok, struct()} | {:error, reason()}
  def match(state, record) do
    case tag(state) do
      nil ->
        refine(state, record)

      {field, value} ->
        if Map.get(record, field) == value,
          do: refine(state, record),
          else: {:error, state.missing()}
    end
  end

  defp refine(state, record), do: kleisli(state.properties()).(struct!(state, record: record))

  @doc """
  Matches a sum of states: the first whose tag tags the record decides;
  otherwise the untagged states are tried in declared order.

  When none matches, the reason is the first failure in declared order: a
  tagged state's `missing/0`, an untagged state's first failing property.
  """
  @spec match_any([module(), ...], subject()) :: {:ok, struct()} | {:error, reason()}
  def match_any([_ | _] = states, record) do
    case Enum.find(states, &tags?(&1, record)) do
      nil -> first_match(states, record)
      state -> match(state, record)
    end
  end

  defp tags?(state, record) do
    case tag(state) do
      {field, value} -> Map.get(record, field) == value
      nil -> false
    end
  end

  defp first_match(states, record) do
    Enum.reduce_while(states, nil, fn state, first_error ->
      case attempt(state, record) do
        {:ok, _} = matched -> {:halt, matched}
        error -> {:cont, first_error || error}
      end
    end)
  end

  defp attempt(state, record) do
    if tag(state), do: {:error, state.missing()}, else: match(state, record)
  end

  @doc """
  The one state of `states` the record is in.

  Exactly one match is the executable form of "the states are exhaustive and
  exclusive": none is `:unclassified`, more than one is `{:ambiguous, states}`.
  Unlike `match_any/2` every state is tried, tag or no tag, so run it over the
  rows as a coverage audit before any writer moves onto a transition.
  """
  @spec classify([module(), ...], subject()) ::
          {:ok, struct()} | {:error, :unclassified | {:ambiguous, [module(), ...]}}
  def classify([_ | _] = states, record) do
    states
    |> Enum.filter(&match?({:ok, _}, match(&1, record)))
    |> case do
      [state] -> match(state, record)
      [] -> {:error, :unclassified}
      ambiguous -> {:error, {:ambiguous, ambiguous}}
    end
  end
end
