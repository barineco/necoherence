// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import necoherence/semantic_types as types

pub fn decode(
  text: String,
  padding_optional: Bool,
  alphabet: types.BytesAlphabet,
  strict_pad_bits: Bool,
) -> Result(List(Int), Nil) {
  let chars = string.to_graphemes(text)
  let length = list.length(chars)
  let padding = case list.reverse(chars) {
    ["=", "=", ..] -> 2
    ["=", ..] -> 1
    _ -> 0
  }
  let content = list.take(chars, length - padding)
  let content_length = list.length(content)
  let remainder = content_length % 4
  let padding_valid = case padding {
    0 ->
      case padding_optional {
        True -> remainder == 0 || remainder == 2 || remainder == 3
        False -> remainder == 0
      }
    1 -> length % 4 == 0 && remainder == 3
    2 -> length % 4 == 0 && remainder == 2
    _ -> False
  }
  use values <- result.try(
    list.try_map(content, fn(char) {
      case value(char, alphabet) {
        Some(value) -> Ok(value)
        None -> Error(Nil)
      }
    }),
  )
  let pad_bits_valid = case strict_pad_bits, list.reverse(values) {
    True, [last, ..] if remainder == 2 -> last % 16 == 0
    True, [last, ..] if remainder == 3 -> last % 4 == 0
    _, _ -> True
  }
  case padding_valid && pad_bits_valid {
    True -> Ok(decode_values(values))
    False -> Error(Nil)
  }
}

fn decode_values(values: List(Int)) -> List(Int) {
  case values {
    [a, b, c, d, ..rest] -> [
      a * 4 + b / 16,
      b % 16 * 16 + c / 4,
      c % 4 * 64 + d,
      ..decode_values(rest)
    ]
    [a, b, c] -> [a * 4 + b / 16, b % 16 * 16 + c / 4]
    [a, b] -> [a * 4 + b / 16]
    _ -> []
  }
}

fn value(char: String, alphabet: types.BytesAlphabet) -> Option(Int) {
  let common =
    string.to_graphemes(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
    )
  case value_at(common, char, 0) {
    Some(value) -> Some(value)
    None ->
      case alphabet, char {
        types.Standard, "+" | types.Either, "+" | types.Either, "-" -> Some(62)
        types.Standard, "/" | types.Either, "/" | types.Either, "_" -> Some(63)
        types.UrlSafe, "-" -> Some(62)
        types.UrlSafe, "_" -> Some(63)
        _, _ -> None
      }
  }
}

fn value_at(chars: List(String), expected: String, index: Int) -> Option(Int) {
  case chars {
    [] -> None
    [char, ..rest] ->
      case char == expected {
        True -> Some(index)
        False -> value_at(rest, expected, index + 1)
      }
  }
}
