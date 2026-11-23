// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type JsonValue {
  JsonValueNull
  JsonValueBool(value: Bool)
  JsonValueNum(value: Int)
  JsonValueDec(text: String)
  JsonValueStr(value: String)
  JsonValueArr(items: List(JsonValue))
  JsonValueObj(members: List(#(String, JsonValue)))
}

pub fn json_size(value: JsonValue) -> Int {
  case value {
    JsonValueArr(items) -> 1 + json_size_list(items)
    JsonValueObj(members) -> 1 + json_size_members(members)
    _ -> 1
  }
}

fn json_size_list(values: List(JsonValue)) -> Int {
  list.fold(values, 0, fn(size, value) { size + json_size(value) })
}

fn json_size_members(members: List(#(String, JsonValue))) -> Int {
  list.fold(members, 0, fn(size, member) { size + json_size(member.1) })
}

/// The written exponent magnitude from which a JSON number is rejected.
const exponent_limit = 10_000

const exponent_too_large_message = "exponent too large"

const unpaired_surrogate_message = "unpaired Unicode surrogate"

fn exponent_value(chars: List(String), acc: Int, count: Int) -> #(Int, Int) {
  case chars {
    [char, ..rest] ->
      case is_decimal_digit(char), int.parse(char) {
        True, Ok(digit) ->
          exponent_value(
            rest,
            int.min(exponent_limit, acc * 10 + digit),
            count + 1,
          )
        _, _ -> #(acc, count)
      }
    [] -> #(acc, count)
  }
}

fn exponent_digits(chars: List(String)) -> List(String) {
  case chars {
    ["-", ..rest] | ["+", ..rest] -> rest
    _ -> chars
  }
}

fn exponent_magnitude_at_limit(chars: List(String)) -> Bool {
  let #(value, count) = exponent_value(exponent_digits(chars), 0, 0)
  count > 0 && value >= exponent_limit
}

fn is_decimal_digit(char: String) -> Bool {
  list.contains(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"], char)
}

fn hex_digit(char: String) -> Option(Int) {
  option.from_result(int.base_parse(char, 16))
}

fn hex_code(chars: List(String)) -> Option(Int) {
  case chars {
    [a, b, c, d] -> {
      use a <- option.then(hex_digit(a))
      use b <- option.then(hex_digit(b))
      use c <- option.then(hex_digit(c))
      use d <- option.then(hex_digit(d))
      Some(a * 4096 + b * 256 + c * 16 + d)
    }
    _ -> None
  }
}

fn is_high_surrogate(code: Int) -> Bool {
  code >= 0xD800 && code <= 0xDBFF
}

fn is_low_surrogate(code: Int) -> Bool {
  code >= 0xDC00 && code <= 0xDFFF
}

fn admission_failure_chars(
  chars: List(String),
  in_string: Bool,
) -> Option(String) {
  case chars, in_string {
    [], _ -> None
    ["\"", ..rest], False -> admission_failure_chars(rest, True)
    ["\"", ..rest], True -> admission_failure_chars(rest, False)
    ["\\", "u", ..rest], True ->
      case hex_code(list.take(rest, 4)) {
        None -> admission_failure_chars(rest, True)
        Some(code) ->
          case is_low_surrogate(code), is_high_surrogate(code) {
            True, _ -> Some(unpaired_surrogate_message)
            False, True ->
              case list.drop(rest, 4) {
                ["\\", "u", ..tail] ->
                  case hex_code(list.take(tail, 4)) {
                    Some(low) ->
                      case is_low_surrogate(low) {
                        True ->
                          admission_failure_chars(list.drop(tail, 4), True)
                        False -> Some(unpaired_surrogate_message)
                      }
                    None -> Some(unpaired_surrogate_message)
                  }
                _ -> Some(unpaired_surrogate_message)
              }
            False, False -> admission_failure_chars(list.drop(rest, 4), True)
          }
      }
    ["\\", _, ..rest], True -> admission_failure_chars(rest, True)
    [char, ..rest], False ->
      case { char == "e" || char == "E" } && exponent_magnitude_at_limit(rest) {
        True -> Some(exponent_too_large_message)
        False -> admission_failure_chars(rest, False)
      }
    [_, ..rest], True -> admission_failure_chars(rest, True)
  }
}

/// The first failure of a JSON text in text order: an exponent that reaches `exponent_limit` outside its strings, or an escape of an unpaired surrogate inside a string.
pub fn admission_failure(text: String) -> Option(String) {
  admission_failure_chars(
    list.map(string.to_utf_codepoints(text), fn(point) {
      string.from_utf_codepoints([point])
    }),
    False,
  )
}
