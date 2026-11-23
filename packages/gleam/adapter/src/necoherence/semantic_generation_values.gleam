// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import necoherence/exact_json as kdl

pub type ValueCodecFailure {
  InvalidSyntax
  InvalidExactValue
  ExponentTooLarge
  UnpairedSurrogate
  DuplicateField(name: String)
}

type Parsed {
  Parsed(value: kdl.JsonValue, remaining: List(String))
}

pub fn parse_wire(text: String) -> Result(kdl.JsonValue, ValueCodecFailure) {
  let chars =
    text
    |> string.to_utf_codepoints
    |> list.map(fn(point) { string.from_utf_codepoints([point]) })
  use _ <- result.try(admit(text))
  use parsed <- result.try(parse_value(spaces(chars)))
  case spaces(parsed.remaining) {
    [] -> Ok(parsed.value)
    _ -> Error(InvalidSyntax)
  }
}

fn admit(text: String) -> Result(Nil, ValueCodecFailure) {
  case kdl.admission_failure(text) {
    None -> Ok(Nil)
    Some("exponent too large") -> Error(ExponentTooLarge)
    Some(_) -> Error(UnpairedSurrogate)
  }
}

pub fn unique_members(value: kdl.JsonValue) -> Result(Nil, ValueCodecFailure) {
  case value {
    kdl.JsonValueObj(members) -> {
      use _ <- result.try(
        list.try_fold(members, dict.new(), fn(seen, member) {
          case dict.has_key(seen, member.0) {
            True -> Error(DuplicateField(member.0))
            False -> Ok(dict.insert(seen, member.0, Nil))
          }
        }),
      )
      list.try_map(members, fn(member) { unique_members(member.1) })
      |> result.map(fn(_) { Nil })
    }
    kdl.JsonValueArr(items) ->
      list.try_map(items, unique_members) |> result.map(fn(_) { Nil })
    _ -> Ok(Nil)
  }
}

pub fn encode_wire(value: kdl.JsonValue) -> Result(String, ValueCodecFailure) {
  case value {
    kdl.JsonValueNull -> Ok("null")
    kdl.JsonValueBool(True) -> Ok("true")
    kdl.JsonValueBool(False) -> Ok("false")
    kdl.JsonValueNum(number) -> Ok(int.to_string(number))
    kdl.JsonValueDec(text) ->
      case option.is_some(kdl.admission_failure(text)), number_token(text) {
        True, _ -> Error(ExponentTooLarge)
        False, True -> Ok(text)
        False, False -> Error(InvalidSyntax)
      }
    kdl.JsonValueStr(text) -> Ok(encode_string(text))
    kdl.JsonValueArr(items) -> {
      use values <- result.try(list.try_map(items, encode_wire))
      Ok("[" <> string.join(values, ",") <> "]")
    }
    kdl.JsonValueObj(members) -> {
      use values <- result.try(
        list.try_map(members, fn(member) {
          use value <- result.try(encode_wire(member.1))
          Ok(encode_string(member.0) <> ":" <> value)
        }),
      )
      Ok("{" <> string.join(values, ",") <> "}")
    }
  }
}

fn encode_string(text: String) -> String {
  let body =
    text
    |> string.to_utf_codepoints
    |> list.map(fn(point) {
      case string.utf_codepoint_to_int(point) {
        0x22 -> "\\\""
        0x5c -> "\\\\"
        0x0a -> "\\n"
        0x0d -> "\\r"
        code if code < 0x20 ->
          "\\u"
          <> string.pad_start(string.lowercase(int.to_base16(code)), 4, "0")
        _ -> string.from_utf_codepoints([point])
      }
    })
    |> string.concat
  "\"" <> body <> "\""
}

pub fn encode_exact(
  value: kdl.JsonValue,
) -> Result(kdl.JsonValue, ValueCodecFailure) {
  let tagged = fn(tag, members) {
    Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr(tag)), ..members]))
  }
  case value {
    kdl.JsonValueNull -> tagged("Null", [])
    kdl.JsonValueBool(flag) ->
      tagged("Bool", [#("value", kdl.JsonValueBool(flag))])
    kdl.JsonValueNum(number) ->
      tagged("Integer", [#("value", kdl.JsonValueStr(int.to_string(number)))])
    kdl.JsonValueDec(text) ->
      case number_token(text) {
        True -> tagged("Decimal", [#("text", kdl.JsonValueStr(text))])
        False -> Error(InvalidExactValue)
      }
    kdl.JsonValueStr(text) ->
      tagged("String", [#("value", kdl.JsonValueStr(text))])
    kdl.JsonValueArr(items) -> {
      use items <- result.try(list.try_map(items, encode_exact))
      tagged("Array", [#("items", kdl.JsonValueArr(items))])
    }
    kdl.JsonValueObj(members) -> {
      use members <- result.try(
        list.try_map(members, fn(member) {
          use value <- result.try(encode_exact(member.1))
          Ok(
            kdl.JsonValueObj([
              #("key", kdl.JsonValueStr(member.0)),
              #("value", value),
            ]),
          )
        }),
      )
      tagged("Object", [#("members", kdl.JsonValueArr(members))])
    }
  }
}

fn spaces(chars: List(String)) -> List(String) {
  case chars {
    [" ", ..rest] | ["\n", ..rest] | ["\r", ..rest] | ["\t", ..rest] ->
      spaces(rest)
    _ -> chars
  }
}

fn parse_value(chars: List(String)) -> Result(Parsed, ValueCodecFailure) {
  case chars {
    ["n", "u", "l", "l", ..rest] -> Ok(Parsed(kdl.JsonValueNull, rest))
    ["t", "r", "u", "e", ..rest] -> Ok(Parsed(kdl.JsonValueBool(True), rest))
    ["f", "a", "l", "s", "e", ..rest] ->
      Ok(Parsed(kdl.JsonValueBool(False), rest))
    ["\"", ..rest] -> parse_string(rest, ["\""])
    ["[", ..rest] ->
      case spaces(rest) {
        ["]", ..rest] -> Ok(Parsed(kdl.JsonValueArr([]), rest))
        chars -> parse_array(chars, [])
      }
    ["{", ..rest] ->
      case spaces(rest) {
        ["}", ..rest] -> Ok(Parsed(kdl.JsonValueObj([]), rest))
        chars -> parse_object(chars, [], dict.new())
      }
    _ -> parse_number(chars)
  }
}

fn parse_string(
  chars: List(String),
  reversed: List(String),
) -> Result(Parsed, ValueCodecFailure) {
  case chars {
    [] -> Error(InvalidSyntax)
    ["\\", escaped, ..rest] -> parse_string(rest, [escaped, "\\", ..reversed])
    ["\"", ..rest] -> {
      let token = string.concat(list.reverse(["\"", ..reversed]))
      case json.parse(token, decode.string) {
        Ok(text) -> Ok(Parsed(kdl.JsonValueStr(text), rest))
        Error(_) -> Error(InvalidSyntax)
      }
    }
    [char, ..rest] -> parse_string(rest, [char, ..reversed])
  }
}

fn parse_array(
  chars: List(String),
  reversed: List(kdl.JsonValue),
) -> Result(Parsed, ValueCodecFailure) {
  use parsed <- result.try(parse_value(chars))
  let values = [parsed.value, ..reversed]
  case spaces(parsed.remaining) {
    ["]", ..rest] -> Ok(Parsed(kdl.JsonValueArr(list.reverse(values)), rest))
    [",", ..rest] -> parse_array(spaces(rest), values)
    _ -> Error(InvalidSyntax)
  }
}

fn parse_object(
  chars: List(String),
  reversed: List(#(String, kdl.JsonValue)),
  seen: Dict(String, Nil),
) -> Result(Parsed, ValueCodecFailure) {
  case chars {
    ["\"", ..rest] -> {
      use key <- result.try(parse_string(rest, ["\""]))
      case key.value, spaces(key.remaining) {
        kdl.JsonValueStr(name), [":", ..rest] -> {
          use <- bool.guard(
            when: dict.has_key(seen, name),
            return: Error(InvalidSyntax),
          )
          use parsed <- result.try(parse_value(spaces(rest)))
          let members = [#(name, parsed.value), ..reversed]
          case spaces(parsed.remaining) {
            ["}", ..rest] ->
              Ok(Parsed(kdl.JsonValueObj(sorted_members(members)), rest))
            [",", ..rest] ->
              parse_object(spaces(rest), members, dict.insert(seen, name, Nil))
            _ -> Error(InvalidSyntax)
          }
        }
        _, _ -> Error(InvalidSyntax)
      }
    }
    _ -> Error(InvalidSyntax)
  }
}

fn sorted_members(
  members: List(#(String, kdl.JsonValue)),
) -> List(#(String, kdl.JsonValue)) {
  list.sort(members, fn(left, right) { string.compare(left.0, right.0) })
}

fn numeric_char(char: String) -> Bool {
  list.contains(
    ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "-", "+", ".", "e", "E"],
    char,
  )
}

fn take_number(
  chars: List(String),
  reversed: List(String),
) -> #(String, List(String)) {
  case chars {
    [char, ..rest] ->
      case numeric_char(char) {
        True -> take_number(rest, [char, ..reversed])
        False -> #(string.concat(list.reverse(reversed)), chars)
      }
    [] -> #(string.concat(list.reverse(reversed)), [])
  }
}

fn parse_number(chars: List(String)) -> Result(Parsed, ValueCodecFailure) {
  let #(token, rest) = take_number(chars, [])
  case option.is_some(kdl.admission_failure(token)), number_token(token) {
    True, _ -> Error(ExponentTooLarge)
    False, False -> Error(InvalidSyntax)
    False, True -> {
      use value <- result.try(lean_number(token))
      Ok(Parsed(value, rest))
    }
  }
}

fn json_number(token: String) -> Result(#(Int, Int), ValueCodecFailure) {
  let #(negative, unsigned) = case string.starts_with(token, "-") {
    True -> #(True, string.drop_start(token, 1))
    False -> #(False, token)
  }
  let lowered = string.lowercase(unsigned)
  let #(mantissa_text, exponent_text) = case string.split_once(lowered, "e") {
    Ok(parts) -> #(parts.0, Ok(parts.1))
    Error(_) -> #(lowered, Error(Nil))
  }
  let #(whole, fraction) = case string.split_once(mantissa_text, ".") {
    Ok(parts) -> parts
    Error(_) -> #(mantissa_text, "")
  }
  use #(digits, exponent) <- result.try(case exponent_text {
    Error(_) -> Ok(#(whole <> fraction, string.length(fraction)))
    Ok(text) -> fold_exponent(whole <> fraction, string.length(fraction), text)
  })
  use magnitude <- result.try(
    int.parse(digits) |> result.replace_error(InvalidSyntax),
  )
  let mantissa = case negative {
    True -> 0 - magnitude
    False -> magnitude
  }
  Ok(#(mantissa, exponent))
}

fn lean_number(token: String) -> Result(kdl.JsonValue, ValueCodecFailure) {
  use #(mantissa, exponent) <- result.try(json_number(token))
  case exponent {
    0 -> Ok(kdl.JsonValueNum(mantissa))
    _ -> Ok(kdl.JsonValueDec(decimal_text(mantissa, exponent)))
  }
}

fn fold_exponent(
  digits: String,
  scale: Int,
  exponent_text: String,
) -> Result(#(String, Int), ValueCodecFailure) {
  let #(negative, count_text) = case string.starts_with(exponent_text, "-") {
    True -> #(True, string.drop_start(exponent_text, 1))
    False -> #(False, string.remove_prefix(exponent_text, "+"))
  }
  use count <- result.try(
    int.parse(count_text) |> result.replace_error(InvalidSyntax),
  )
  case negative {
    True -> Ok(#(digits, scale + count))
    False ->
      case count >= scale {
        True -> Ok(#(digits <> string.repeat("0", count - scale), 0))
        False -> Ok(#(digits, scale - count))
      }
  }
}

fn decimal_text(mantissa: Int, exponent: Int) -> String {
  case mantissa {
    0 -> "0"
    _ -> {
      let sign = case mantissa < 0 {
        True -> "-"
        False -> ""
      }
      let magnitude = int.absolute_value(mantissa)
      let scientific = 9 + string.length(int.to_string(magnitude)) - exponent
      let shift = int.min(scientific, 0)
      let divisor = power_of_ten(exponent - int.absolute_value(shift))
      let left = int.to_string(magnitude / divisor)
      case magnitude % divisor == 0 && shift == 0 {
        True -> sign <> left
        False -> {
          let right =
            int.to_string(divisor + magnitude % divisor)
            |> string.drop_start(1)
            |> trim_trailing_zeros
          let suffix = case shift == 0 {
            True -> ""
            False -> "e" <> int.to_string(shift)
          }
          sign <> left <> "." <> right <> suffix
        }
      }
    }
  }
}

fn power_of_ten(exponent: Int) -> Int {
  let assert Ok(value) = int.parse("1" <> string.repeat("0", exponent))
  value
}

fn trim_trailing_zeros(text: String) -> String {
  case string.ends_with(text, "0") {
    True -> trim_trailing_zeros(string.drop_end(text, 1))
    False -> text
  }
}

fn digit(char: String) -> Bool {
  list.contains(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"], char)
}

fn skip_digits(chars: List(String)) -> List(String) {
  case chars {
    [char, ..rest] ->
      case digit(char) {
        True -> skip_digits(rest)
        False -> chars
      }
    [] -> []
  }
}

pub fn json_spelling(
  value: kdl.JsonValue,
) -> Result(String, ValueCodecFailure) {
  case value {
    kdl.JsonValueNull -> Ok("null")
    kdl.JsonValueBool(True) -> Ok("true")
    kdl.JsonValueBool(False) -> Ok("false")
    kdl.JsonValueNum(number) -> Ok(int.to_string(number))
    kdl.JsonValueDec(text) ->
      case number_token(text), option.is_some(kdl.admission_failure(text)) {
        True, False -> {
          use #(mantissa, exponent) <- result.try(json_number(text))
          let #(mantissa, exponent) = decimal_number(mantissa, exponent)
          Ok(number_text(mantissa, exponent))
        }
        True, True -> Error(ExponentTooLarge)
        False, _ -> Error(InvalidExactValue)
      }
    kdl.JsonValueStr(text) -> Ok(encode_string(text))
    kdl.JsonValueArr(items) -> {
      use values <- result.try(list.try_map(items, json_spelling))
      Ok("[" <> string.join(values, ",") <> "]")
    }
    kdl.JsonValueObj(members) -> {
      let sorted = list.sort(members, fn(a, b) { string.compare(a.0, b.0) })
      use values <- result.try(
        list.try_map(sorted, fn(member) {
          use value <- result.try(json_spelling(member.1))
          Ok(encode_string(member.0) <> ":" <> value)
        }),
      )
      Ok("{" <> string.join(values, ",") <> "}")
    }
  }
}

fn number_text(mantissa: Int, exponent: Int) -> String {
  case exponent != 0 && mantissa % power_of_ten(exponent) == 0 {
    True -> int.to_string(mantissa / power_of_ten(exponent)) <> ".0"
    False -> decimal_text(mantissa, exponent)
  }
}

fn decimal_number(mantissa: Int, exponent: Int) -> #(Int, Int) {
  case mantissa % power_of_ten(exponent) == 0 {
    True -> #(mantissa / power_of_ten(exponent) * 10, 1)
    False -> #(mantissa, exponent)
  }
}

pub fn integral_decimal_value(value: Int) -> kdl.JsonValue {
  kdl.JsonValueDec(int.to_string(value) <> ".0")
}

pub fn decimal_string_value(value: Int) -> kdl.JsonValue {
  kdl.JsonValueStr(int.to_string(value))
}

pub fn is_json_number(text: String) -> Bool {
  number_token(text)
}

fn number_token(text: String) -> Bool {
  let chars = string.to_graphemes(text)
  let chars = case chars {
    ["-", ..rest] -> rest
    _ -> chars
  }
  case chars {
    ["0", ..rest] -> fraction_and_exponent(rest)
    [char, ..rest] ->
      case digit(char) {
        True -> fraction_and_exponent(skip_digits(rest))
        False -> False
      }
    [] -> False
  }
}

fn fraction_and_exponent(chars: List(String)) -> Bool {
  case chars {
    [".", char, ..rest] -> digit(char) && exponent(skip_digits(rest))
    _ -> exponent(chars)
  }
}

fn exponent(chars: List(String)) -> Bool {
  case chars {
    [] -> True
    ["e", ..rest] | ["E", ..rest] -> {
      let rest = case rest {
        ["+", ..rest] | ["-", ..rest] -> rest
        _ -> rest
      }
      case rest {
        [char, ..rest] -> digit(char) && skip_digits(rest) == []
        _ -> False
      }
    }
    _ -> False
  }
}
