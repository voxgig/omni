# Omni internal JSON utilities.
#
# Self-contained by design: the omni runner must be able to test *any*
# library, including libraries that provide these same operations.

defmodule Voxgig.Omni.Util do
  @moduledoc "JSON value helpers for the omni test runner."

  # Value is JSON null.
  def nullmark, do: "__NULL__"
  # Value is not present.
  def undefmark, do: "__UNDEF__"
  # Value exists (not undefined).
  def existsmark, do: "__EXISTS__"

  # Elixir has nil for null, so absence needs its own marker.
  def absent, do: :"$omni_absent"

  def isabsent(val), do: val == absent()

  def ismap(val), do: is_map(val) and not is_struct(val)

  def islist(val), do: is_list(val)

  def isnode(val), do: ismap(val) or islist(val)

  # A JSON number? Booleans are not numbers.
  def isnum(val), do: is_number(val) and not is_boolean(val)

  def isstr(val), do: is_binary(val)

  def isnone(val), do: is_nil(val) or isabsent(val)

  @doc "Deep copy a JSON value (Elixir values are immutable)."
  def clone(val), do: val

  @doc "Read a map entry. Returns the absence marker when missing."
  def get(val, key) do
    if ismap(val) do
      Map.get(val, key, absent())
    else
      absent()
    end
  end

  def has(val, key), do: ismap(val) and Map.has_key?(val, key)

  @doc "Read a value by path. Returns the absence marker when a step is missing."
  def getpath(val, path) do
    Enum.reduce_while(path, val, fn part, current ->
      cond do
        islist(current) ->
          case Integer.parse(to_string(part)) do
            {index, ""} when index >= 0 ->
              if index < length(current) do
                {:cont, Enum.at(current, index)}
              else
                {:halt, absent()}
              end

            _ ->
              {:halt, absent()}
          end

        ismap(current) ->
          if Map.has_key?(current, to_string(part)) do
            {:cont, Map.get(current, to_string(part))}
          else
            {:halt, absent()}
          end

        true ->
          {:halt, absent()}
      end
    end)
  end

  @doc "Depth-first walk: children first, then the containing node."
  def walk(val, apply, path \\ []) do
    next =
      cond do
        islist(val) ->
          val
          |> Enum.with_index()
          |> Enum.map(fn {entry, index} -> walk(entry, apply, path ++ [to_string(index)]) end)

        ismap(val) ->
          Map.new(val, fn {key, entry} -> {key, walk(entry, apply, path ++ [key])} end)

        true ->
          val
      end

    apply.(next, path)
  end

  @doc "Deep structural equality: numbers by value, bools never numbers."
  def deepequal(a, b) do
    cond do
      is_boolean(a) or is_boolean(b) -> a === b
      isnum(a) or isnum(b) -> isnum(a) and isnum(b) and a == b
      isabsent(a) or isabsent(b) -> isabsent(a) and isabsent(b)
      is_nil(a) or is_nil(b) -> is_nil(a) and is_nil(b)
      islist(a) or islist(b) -> equal_lists(a, b)
      ismap(a) or ismap(b) -> equal_maps(a, b)
      true -> a === b
    end
  end

  defp equal_lists(a, b) do
    islist(a) and islist(b) and length(a) == length(b) and
      Enum.all?(Enum.zip(a, b), fn {x, y} -> deepequal(x, y) end)
  end

  defp equal_maps(a, b) do
    ismap(a) and ismap(b) and map_size(a) == map_size(b) and
      Enum.all?(a, fn {key, entry} ->
        Map.has_key?(b, key) and deepequal(entry, Map.get(b, key))
      end)
  end

  @doc "Render a number the same way in every port: 5.0 prints as 5."
  def numstr(val) do
    asfloat = val / 1

    cond do
      asfloat == Float.round(asfloat) and abs(asfloat) < 9_007_199_254_740_992.0 ->
        Integer.to_string(trunc(asfloat))

      true ->
        Float.to_string(asfloat)
    end
  end

  @doc "Render a string as a JSON string literal."
  def quote_str(val) do
    escaped =
      val
      |> String.to_charlist()
      |> Enum.map(fn ch ->
        case ch do
          ?" -> "\\\""
          ?\\ -> "\\\\"
          ?\n -> "\\n"
          ?\r -> "\\r"
          ?\t -> "\\t"
          other when other < 0x20 -> "\\u" <> String.pad_leading(Integer.to_string(other, 16), 4, "0")
          other -> <<other::utf8>>
        end
      end)
      |> Enum.join()

    "\"" <> escaped <> "\""
  end

  @doc "Compact JSON text with map keys sorted, identical in every port."
  def jsonstr(val) do
    cond do
      isabsent(val) -> "undefined"
      is_nil(val) -> "null"
      is_boolean(val) -> if val, do: "true", else: "false"
      isstr(val) -> quote_str(val)
      isnum(val) -> numstr(val)
      islist(val) -> "[" <> Enum.map_join(val, ",", &jsonstr/1) <> "]"
      ismap(val) -> "{" <> map_body(val) <> "}"
      true -> quote_str(inspect(val))
    end
  end

  defp map_body(val) do
    val
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map_join(",", fn key -> quote_str(to_string(key)) <> ":" <> jsonstr(Map.get(val, key)) end)
  end

  @doc "Strings verbatim, everything else as compact JSON."
  def stringify(val) do
    if isstr(val), do: val, else: jsonstr(val)
  end

  @doc "Render a path as a dotted string."
  def pathify(path), do: Enum.join(path, ".")
end
