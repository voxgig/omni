# The system under test: a tiny Fibonacci library.
#
# Every omni port ships this same library, with the same behaviour and the
# same error messages, and tests it with the same spec file
# (spec/fib.json).

defmodule Voxgig.Omni.FibError do
  @moduledoc """
  The Fibonacci library's own error type. A subject must never raise the
  runner's OmniError - that type is reserved for test failures.
  """
  defexception [:message]
end

defmodule Voxgig.Omni.Fib do
  @moduledoc "A tiny Fibonacci library: the system under test."

  alias Voxgig.Omni.FibError
  alias Voxgig.Omni.Util, as: U

  @doc "Validate a Fibonacci index. The spec matches on these messages."
  def fibindex(val) do
    if not U.isnum(val) do
      raise FibError, message: "fib: not a number: " <> U.stringify(val)
    end

    num = val / 1

    if num != Float.round(num) do
      raise FibError, message: "fib: non-integer index: " <> U.stringify(val)
    end

    if 0 > num do
      raise FibError, message: "fib: negative index: " <> U.stringify(val)
    end

    trunc(num)
  end

  @doc "The nth Fibonacci number: fib(0)=0, fib(1)=1."
  def fibnum(0), do: 0
  def fibnum(index), do: fibstep(1, index, 0, 1)

  defp fibstep(step, index, _prev, cur) when step >= index, do: cur
  defp fibstep(step, index, prev, cur), do: fibstep(step + 1, index, cur, prev + cur)

  def fib(val), do: fibnum(fibindex(val)) / 1

  @doc "The first n Fibonacci numbers."
  def fibseq(val) do
    count = fibindex(val)
    Enum.map(0..(count - 1)//1, fn index -> fibnum(index) / 1 end)
  end

  @doc "The Fibonacci numbers from index start to index end, inclusive."
  def fibrange(start, stop) do
    from = fibindex(start)
    to = fibindex(stop)
    Enum.map(from..to//1, fn index -> fibnum(index) / 1 end)
  end

  @doc """
  A description of the nth Fibonacci number. `prev` is nil at index 0,
  which exercises the runner's null handling.
  """
  def fibinfo(val) do
    index = fibindex(val)
    num = fibnum(index)

    %{
      "n" => index / 1,
      "val" => num / 1,
      "even" => 0 == rem(num, 2),
      "prev" => if(0 == index, do: nil, else: fibnum(index - 1) / 1),
      "label" => "fib(" <> U.numstr(index) <> ")=" <> U.numstr(num)
    }
  end
end
