// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import necoherence/semantic_types as types

pub fn decode(
  text: String,
  padding_optional: Bool,
  alphabet: types.BytesAlphabet,
  strict_pad_bits: Bool,
) -> Result(List(Int), Nil) {
  let bytes = bit_array.from_string(text)
  let length = bit_array.byte_size(bytes)
  let padding = case bit_array.slice(bytes, length - 2, 2) {
    Ok(<<61, 61>>) -> 2
    Ok(<<_, 61>>) -> 1
    _ ->
      case bytes {
        <<61>> -> 1
        _ -> 0
      }
  }
  let content_length = length - padding
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
  use reversed <- result.try(digits(bytes, content_length, alphabet, []))
  let pad_bits_valid = case strict_pad_bits, reversed {
    True, [last, ..] if remainder == 2 -> last % 16 == 0
    True, [last, ..] if remainder == 3 -> last % 4 == 0
    _, _ -> True
  }
  case padding_valid && pad_bits_valid {
    True -> Ok(decode_values(list.reverse(reversed)))
    False -> Error(Nil)
  }
}

fn digits(
  bytes: BitArray,
  remaining: Int,
  alphabet: types.BytesAlphabet,
  reversed: List(Int),
) -> Result(List(Int), Nil) {
  case remaining, bytes {
    0, _ -> Ok(reversed)
    _, <<byte, rest:bytes>> ->
      case value(byte, alphabet) {
        Some(digit) ->
          digits(rest, remaining - 1, alphabet, [digit, ..reversed])
        None -> Error(Nil)
      }
    _, _ -> Error(Nil)
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

fn value(byte: Int, alphabet: types.BytesAlphabet) -> Option(Int) {
  case byte {
    _ if byte >= 65 && byte <= 90 -> Some(byte - 65)
    _ if byte >= 97 && byte <= 122 -> Some(byte - 71)
    _ if byte >= 48 && byte <= 57 -> Some(byte + 4)
    _ ->
      case alphabet, byte {
        types.Standard, 43 | types.Either, 43 | types.Either, 45 -> Some(62)
        types.Standard, 47 | types.Either, 47 | types.Either, 95 -> Some(63)
        types.UrlSafe, 45 -> Some(62)
        types.UrlSafe, 95 -> Some(63)
        _, _ -> None
      }
  }
}

type Scan {
  Scan(count: Int, last: Option(Int), padding: Int)
}

fn scan_body(
  bytes: BitArray,
  alphabet: types.BytesAlphabet,
  count: Int,
  last: Option(Int),
) -> Option(Scan) {
  case bytes {
    <<>> -> Some(Scan(count, last, 0))
    <<61, rest:bytes>> ->
      option.map(scan_padding(rest, 1), fn(padding) {
        Scan(count, last, padding)
      })
    <<byte, rest:bytes>> ->
      case value(byte, alphabet) {
        Some(digit) -> scan_body(rest, alphabet, count + 1, Some(digit))
        None -> None
      }
    _ -> None
  }
}

fn scan_padding(bytes: BitArray, padding: Int) -> Option(Int) {
  case padding > 2, bytes {
    True, _ -> None
    False, <<>> -> Some(padding)
    False, <<61, rest:bytes>> -> scan_padding(rest, padding + 1)
    False, _ -> None
  }
}

pub fn length(policy: types.BytesPolicy, text: String) -> Option(Int) {
  use Scan(count, last, padding) <- option.then(scan_body(
    bit_array.from_string(text),
    policy.alphabet,
    0,
    None,
  ))
  let remainder = count % 4
  let tail_bits_valid = case last {
    None -> True
    Some(digit) ->
      case remainder {
        2 -> digit % 16 == 0
        3 -> digit % 4 == 0
        _ -> True
      }
  }
  case remainder == 1 || { policy.strict_pad_bits && !tail_bits_valid } {
    True -> None
    False ->
      case
        padding > 0
        && { { count + padding } % 4 != 0 || padding != { 4 - remainder } % 4 }
      {
        True -> None
        False ->
          case padding == 0 && !policy.padding_optional && remainder != 0 {
            True -> None
            False ->
              Some(
                count
                / 4
                * 3
                + case remainder == 0 {
                  True -> 0
                  False -> remainder - 1
                },
              )
          }
      }
  }
}
