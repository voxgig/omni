# The omni JSON parser.
#
# The omni runner must be able to test *any* library, and must add no
# third-party dependencies, so it carries its own JSON parsing rather than
# borrowing Jason, Poison or the system under test. (Elixir gained a built
# in JSON module only in 1.18; omni supports older releases too.)
#
# Parses into native Elixir values: maps with string keys, lists, binaries,
# floats, booleans and nil.

defmodule Voxgig.Omni.Json do
  @moduledoc "Minimal JSON parser for the omni test runner."

  @doc "Parse JSON text into native Elixir values."
  def parse(text) do
    {value, rest} = parse_value(skipws(text))

    case skipws(rest) do
      "" -> value
      trailing -> raise "omni: trailing JSON content: #{String.slice(trailing, 0, 20)}"
    end
  end

  defp skipws(<<ch, rest::binary>>) when ch in [?\s, ?\t, ?\n, ?\r], do: skipws(rest)
  defp skipws(text), do: text

  defp parse_value("{" <> rest), do: parse_map(skipws(rest), %{})
  defp parse_value("[" <> rest), do: parse_list(skipws(rest), [])
  defp parse_value("\"" <> rest), do: parse_string(rest, [])
  defp parse_value("true" <> rest), do: {true, rest}
  defp parse_value("false" <> rest), do: {false, rest}
  defp parse_value("null" <> rest), do: {nil, rest}
  defp parse_value(""), do: raise("omni: unexpected end of JSON")
  defp parse_value(text), do: parse_number(text)

  defp parse_map("}" <> rest, out), do: {out, rest}

  defp parse_map(text, out) do
    {key, rest} =
      case skipws(text) do
        "\"" <> keytext -> parse_string(keytext, [])
        other -> raise "omni: expected string key: #{String.slice(other, 0, 20)}"
      end

    rest =
      case skipws(rest) do
        ":" <> after_colon -> after_colon
        other -> raise "omni: expected ':': #{String.slice(other, 0, 20)}"
      end

    {value, rest} = parse_value(skipws(rest))
    out = Map.put(out, key, value)

    case skipws(rest) do
      "," <> more -> parse_map(skipws(more), out)
      "}" <> more -> {out, more}
      other -> raise "omni: expected ',' or '}': #{String.slice(other, 0, 20)}"
    end
  end

  defp parse_list("]" <> rest, out), do: {Enum.reverse(out), rest}

  defp parse_list(text, out) do
    {value, rest} = parse_value(skipws(text))
    out = [value | out]

    case skipws(rest) do
      "," <> more -> parse_list(skipws(more), out)
      "]" <> more -> {Enum.reverse(out), more}
      other -> raise "omni: expected ',' or ']': #{String.slice(other, 0, 20)}"
    end
  end

  defp parse_string("\"" <> rest, out), do: {out |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp parse_string("\\u" <> rest, out) do
    <<hex::binary-size(4), more::binary>> = rest
    {code, ""} = Integer.parse(hex, 16)
    parse_string(more, [<<code::utf8>> | out])
  end

  defp parse_string("\\" <> <<escape, rest::binary>>, out) do
    char =
      case escape do
        ?" -> "\""
        ?\\ -> "\\"
        ?/ -> "/"
        ?b -> "\b"
        ?f -> "\f"
        ?n -> "\n"
        ?r -> "\r"
        ?t -> "\t"
        other -> raise "omni: bad JSON escape [#{<<other>>}]"
      end

    parse_string(rest, [char | out])
  end

  defp parse_string(<<ch::utf8, rest::binary>>, out),
    do: parse_string(rest, [<<ch::utf8>> | out])

  defp parse_string("", _out), do: raise("omni: unterminated JSON string")

  defp parse_number(text) do
    {span, rest} = take_number(text, [])
    span = span |> Enum.reverse() |> IO.iodata_to_binary()

    case Float.parse(span) do
      {value, ""} -> {value, rest}
      _ -> raise "omni: bad JSON number [#{span}]"
    end
  end

  defp take_number(<<ch, rest::binary>>, out)
       when ch in ?0..?9 or ch in [?-, ?+, ?., ?e, ?E],
       do: take_number(rest, [<<ch>> | out])

  defp take_number(text, out), do: {out, text}
end
