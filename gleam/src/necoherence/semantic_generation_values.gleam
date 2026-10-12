// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import necoherence/exact_json as kdl

pub type ValueCodecFailure {
  InvalidSyntax
  InvalidExactValue
}

type Parsed {
  Parsed(value: kdl.JsonValue, remaining: List(String))
}

pub fn parse_wire(text: String) -> Result(kdl.JsonValue, ValueCodecFailure) {
  let chars =
    text
    |> string.to_utf_codepoints
    |> list.map(fn(point) { string.from_utf_codepoints([point]) })
  use parsed <- result.try(parse_value(spaces(chars)))
  case spaces(parsed.remaining) {
    [] -> Ok(parsed.value)
    _ -> Error(InvalidSyntax)
  }
}

pub fn encode_wire(value: kdl.JsonValue) -> Result(String, ValueCodecFailure) {
  case value {
    kdl.JsonValueNull -> Ok("null")
    kdl.JsonValueBool(True) -> Ok("true")
    kdl.JsonValueBool(False) -> Ok("false")
    kdl.JsonValueNum(number) -> Ok(int.to_string(number))
    kdl.JsonValueDec(text) ->
      case number_token(text) {
        True -> Ok(text)
        False -> Error(InvalidSyntax)
      }
    kdl.JsonValueStr(text) -> Ok(json.to_string(json.string(text)))
    kdl.JsonValueArr(items) -> {
      use values <- result.try(list.try_map(items, encode_wire))
      Ok("[" <> string.join(values, ",") <> "]")
    }
    kdl.JsonValueObj(members) -> {
      use values <- result.try(
        list.try_map(members, fn(member) {
          use value <- result.try(encode_wire(member.1))
          Ok(json.to_string(json.string(member.0)) <> ":" <> value)
        }),
      )
      Ok("{" <> string.join(values, ",") <> "}")
    }
  }
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

pub fn decode_exact(
  value: kdl.JsonValue,
) -> Result(kdl.JsonValue, ValueCodecFailure) {
  case value {
    kdl.JsonValueObj(members) -> {
      use _ <- result.try(unique_members(members))
      case list.key_find(members, "tag"), list.length(members) {
        Ok(kdl.JsonValueStr("Null")), 1 -> Ok(kdl.JsonValueNull)
        Ok(kdl.JsonValueStr(tag)), 2 -> decode_payload(tag, members)
        _, _ -> Error(InvalidExactValue)
      }
    }
    _ -> Error(InvalidExactValue)
  }
}

fn decode_payload(
  tag: String,
  members: List(#(String, kdl.JsonValue)),
) -> Result(kdl.JsonValue, ValueCodecFailure) {
  case
    tag,
    list.key_find(members, "value"),
    list.key_find(members, "text"),
    list.key_find(members, "items"),
    list.key_find(members, "members")
  {
    "Bool", Ok(kdl.JsonValueBool(flag)), _, _, _ -> Ok(kdl.JsonValueBool(flag))
    "String", Ok(kdl.JsonValueStr(text)), _, _, _ -> Ok(kdl.JsonValueStr(text))
    "Integer", Ok(kdl.JsonValueStr(text)), _, _, _ ->
      case int.parse(text) {
        Ok(number) ->
          case int.to_string(number) == text {
            True -> Ok(kdl.JsonValueNum(number))
            False -> Error(InvalidExactValue)
          }
        _ -> Error(InvalidExactValue)
      }
    "Decimal", _, Ok(kdl.JsonValueStr(text)), _, _ ->
      case number_token(text) {
        True -> Ok(kdl.JsonValueDec(text))
        False -> Error(InvalidExactValue)
      }
    "Array", _, _, Ok(kdl.JsonValueArr(items)), _ -> {
      use decoded <- result.try(list.try_map(items, decode_exact))
      Ok(kdl.JsonValueArr(decoded))
    }
    "Object", _, _, _, Ok(kdl.JsonValueArr(items)) -> {
      use decoded <- result.try(
        list.try_map(items, fn(item) {
          case item {
            kdl.JsonValueObj([first, second]) -> {
              let members = [first, second]
              use _ <- result.try(unique_members(members))
              case
                list.key_find(members, "key"),
                list.key_find(members, "value")
              {
                Ok(kdl.JsonValueStr(key)), Ok(value) -> {
                  use value <- result.try(decode_exact(value))
                  Ok(#(key, value))
                }
                _, _ -> Error(InvalidExactValue)
              }
            }
            _ -> Error(InvalidExactValue)
          }
        }),
      )
      Ok(kdl.JsonValueObj(decoded))
    }
    _, _, _, _, _ -> Error(InvalidExactValue)
  }
}

fn unique_members(
  members: List(#(String, kdl.JsonValue)),
) -> Result(Nil, ValueCodecFailure) {
  case members {
    [] -> Ok(Nil)
    [first, ..rest] ->
      case list.any(rest, fn(member) { member.0 == first.0 }) {
        True -> Error(InvalidExactValue)
        False -> unique_members(rest)
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
        chars -> parse_object(chars, [])
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
) -> Result(Parsed, ValueCodecFailure) {
  case chars {
    ["\"", ..rest] -> {
      use key <- result.try(parse_string(rest, ["\""]))
      case key.value, spaces(key.remaining) {
        kdl.JsonValueStr(name), [":", ..rest] -> {
          use parsed <- result.try(parse_value(spaces(rest)))
          let members = [#(name, parsed.value), ..reversed]
          case spaces(parsed.remaining) {
            ["}", ..rest] ->
              Ok(Parsed(kdl.JsonValueObj(list.reverse(members)), rest))
            [",", ..rest] -> parse_object(spaces(rest), members)
            _ -> Error(InvalidSyntax)
          }
        }
        _, _ -> Error(InvalidSyntax)
      }
    }
    _ -> Error(InvalidSyntax)
  }
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
  case number_token(token) {
    False -> Error(InvalidSyntax)
    True ->
      case
        string.contains(token, ".")
        || string.contains(token, "e")
        || string.contains(token, "E")
      {
        True -> Ok(Parsed(kdl.JsonValueDec(token), rest))
        False ->
          case int.parse(token) {
            Ok(number) -> Ok(Parsed(kdl.JsonValueNum(number), rest))
            Error(_) -> Error(InvalidSyntax)
          }
      }
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
