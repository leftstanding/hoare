defmodule Hoare.Result do
  @moduledoc """
  Combinators over `{:ok, value} | {:error, reason}`.

  The tagged tuple is the ecosystem's result type, so nothing is wrapped: `with`
  is the bind, and these name the few compositions a transition needs so it
  can be a value. `kleisli/1` composes a list of arrows into one; `ensure/2`
  lifts a predicate into an arrow, for guards and properties that only test.
  """

  @type ok(value) :: {:ok, value}
  @type error :: {:error, term()}
  @type t(value) :: ok(value) | error()
  @type arrow(a, b) :: (a -> t(b))

  @spec bind(t(a), arrow(a, b)) :: t(b) when a: term(), b: term()
  def bind({:ok, value}, fun), do: fun.(value)
  def bind({:error, _} = error, _fun), do: error

  @doc "Composes arrows left to right into one arrow; the empty list is the identity."
  @spec kleisli([arrow(term(), term())]) :: arrow(term(), term())
  def kleisli(arrows), do: fn value -> Enum.reduce(arrows, {:ok, value}, &bind(&2, &1)) end

  @doc "An arrow that passes its value through when `pred` holds and is `{:error, reason}` otherwise."
  @spec ensure((a -> as_boolean(term())), term()) :: arrow(a, a) when a: term()
  def ensure(pred, reason),
    do: fn value -> if pred.(value), do: {:ok, value}, else: {:error, reason} end

  @spec tap_ok(t(a), (a -> term())) :: t(a) when a: term()
  def tap_ok({:ok, value} = ok, fun) do
    fun.(value)
    ok
  end

  def tap_ok({:error, _} = error, _fun), do: error

  @spec tap_error(t(a), (term() -> term())) :: t(a) when a: term()
  def tap_error({:ok, _} = ok, _fun), do: ok

  def tap_error({:error, reason} = error, fun) do
    fun.(reason)
    error
  end

  @spec map_error(t(a), (term() -> term())) :: t(a) when a: term()
  def map_error({:ok, _} = ok, _fun), do: ok
  def map_error({:error, reason}, fun), do: {:error, fun.(reason)}
end
