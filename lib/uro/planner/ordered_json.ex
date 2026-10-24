# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Planner.OrderedJson do
  @moduledoc """
  Minimal JSON decoder preserving object key insertion order, matching
  `standalone/tw_value.hpp`'s `TwValue::Dict = tsl::ordered_map<...>` --
  plain `Jason.decode!/1` returns ordinary Elixir maps, whose iteration
  order is unspecified, which silently breaks any domain construct
  whose *order* is semantically meaningful (RFD66606-0023's Stage 5A: a
  `multigoal`'s per-var/per-key binding order determines which binding
  the HTN search tries first). Neither `json_ld` (decodes into RDF
  datasets -- unordered triples, worse than plain JSON here) nor
  `json_ordered` (an *encoder* key-ordering helper, not a decoder) on
  hex.pm solves this; nothing in the Elixir JSON ecosystem preserves
  decode-side object order, so this is a small hand-rolled parser
  rather than a dependency.

  Objects decode to `{:obj, [{key, value}, ...]}` (order preserved);
  arrays decode to plain lists; scalars decode to ordinary Elixir
  terms. Use `Uro.Planner.OrderedJson.get/2` for named field access.
  """

  @type t :: {:obj, [{String.t(), t()}]} | [t()] | String.t() | number() | boolean() | nil

  @spec decode!(String.t()) :: t()
  def decode!(json) do
    {value, rest} = parse_value(skip_ws(json))

    case skip_ws(rest) do
      "" -> value
      _ -> raise "OrderedJson: trailing content after top-level value"
    end
  end

  @doc "Named field access into a decoded {:obj, pairs} -- nil if absent."
  @spec get(t(), String.t()) :: t() | nil
  def get({:obj, pairs}, key) do
    case List.keyfind(pairs, key, 0) do
      {^key, value} -> value
      nil -> nil
    end
  end

  @doc "All {key, value} pairs of a decoded object, in document order."
  @spec pairs(t()) :: [{String.t(), t()}]
  def pairs({:obj, pairs}), do: pairs

  defp skip_ws(<<c, rest::binary>>) when c in ~c[ \t\n\r], do: skip_ws(rest)
  defp skip_ws(s), do: s

  defp parse_value("{" <> rest), do: parse_object(skip_ws(rest), [])
  defp parse_value("[" <> rest), do: parse_array(skip_ws(rest), [])
  defp parse_value("\"" <> rest), do: parse_string(rest, [])
  defp parse_value("true" <> rest), do: {true, rest}
  defp parse_value("false" <> rest), do: {false, rest}
  defp parse_value("null" <> rest), do: {nil, rest}
  defp parse_value(<<c, _::binary>> = s) when c in ~c[-0123456789], do: parse_number(s)

  defp parse_value(other),
    do: raise("OrderedJson: unexpected input near #{inspect(String.slice(other, 0, 20))}")

  defp parse_object("}" <> rest, acc), do: {{:obj, Enum.reverse(acc)}, rest}

  defp parse_object(s, acc) do
    {key, after_key} = parse_key(s)
    ":" <> after_colon = skip_ws(after_key)
    {value, after_value} = parse_value(skip_ws(after_colon))
    acc = [{key, value} | acc]

    case skip_ws(after_value) do
      "," <> more -> parse_object(skip_ws(more), acc)
      "}" <> more -> {{:obj, Enum.reverse(acc)}, more}
      other -> raise "OrderedJson: expected , or } near #{inspect(String.slice(other, 0, 20))}"
    end
  end

  defp parse_key("\"" <> rest) do
    {str, after_str} = parse_string(rest, [])
    {str, after_str}
  end

  defp parse_key(other),
    do: raise("OrderedJson: expected object key near #{inspect(String.slice(other, 0, 20))}")

  defp parse_array("]" <> rest, acc), do: {Enum.reverse(acc), rest}

  defp parse_array(s, acc) do
    {value, after_value} = parse_value(s)
    acc = [value | acc]

    case skip_ws(after_value) do
      "," <> more -> parse_array(skip_ws(more), acc)
      "]" <> more -> {Enum.reverse(acc), more}
      other -> raise "OrderedJson: expected , or ] near #{inspect(String.slice(other, 0, 20))}"
    end
  end

  defp parse_string("\"" <> rest, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp parse_string("\\" <> <<esc, rest::binary>>, acc) do
    parse_string(rest, [escape_char(esc) | acc])
  end

  defp parse_string(<<c::utf8, rest::binary>>, acc), do: parse_string(rest, [<<c::utf8>> | acc])

  defp escape_char(?"), do: "\""
  defp escape_char(?\\), do: "\\"
  defp escape_char(?/), do: "/"
  defp escape_char(?b), do: "\b"
  defp escape_char(?f), do: "\f"
  defp escape_char(?n), do: "\n"
  defp escape_char(?r), do: "\r"
  defp escape_char(?t), do: "\t"
  defp escape_char(other), do: raise("OrderedJson: unsupported escape \\#{<<other>>}")

  defp parse_number(s) do
    case Regex.run(~r/^-?\d+(\.\d+)?([eE][+-]?\d+)?/, s) do
      [match] ->
        rest = binary_part(s, byte_size(match), byte_size(s) - byte_size(match))

        value =
          if String.contains?(match, [".", "e", "E"]),
            do: String.to_float(match),
            else: String.to_integer(match)

        {value, rest}
    end
  end
end
