// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/string
import necoherence/network_effect_json as codec

@external(erlang, "necoherence_network_effect_runner_ffi", "read_stdin")
fn read_stdin() -> String

pub fn main() {
  io.println(run(read_stdin()))
}

pub fn run(input: String) -> String {
  case
    json.parse(
      sanitize_lone_surrogates(input),
      using: codec.invocation_decoder(),
    )
  {
    Ok(invocation) -> invocation |> codec.execute |> json.to_string
    Error(_) -> invalid("invalid invocation")
  }
}

fn invalid(reason: String) -> String {
  json.object([
    #("result", json.string("InvalidInvocation")),
    #("error", json.string(reason)),
  ])
  |> json.to_string
}

/// Erlang/OTP's `json:decode/1` rejects lone (unpaired) UTF-16 surrogate
/// escapes outright, while the Lean reference decoder replaces them with the
/// Unicode replacement character (`\ufffd`) and keeps decoding. Rewrite lone
/// surrogate escapes the same way before parsing so both lanes observe the
/// same decoded invocation.
fn sanitize_lone_surrogates(input: String) -> String {
  scan(input, []) |> list.reverse |> string.concat
}

fn scan(remaining: String, acc: List(String)) -> List(String) {
  case string.pop_grapheme(remaining) {
    Error(Nil) -> acc
    Ok(#("\\", rest)) -> scan_escape(rest, acc)
    Ok(#(grapheme, rest)) -> scan(rest, [grapheme, ..acc])
  }
}

fn scan_escape(after_backslash: String, acc: List(String)) -> List(String) {
  case string.pop_grapheme(after_backslash) {
    Error(Nil) -> ["\\", ..acc]
    Ok(#("u", after_u)) ->
      case take_hex4(after_u) {
        Error(Nil) -> scan(after_u, ["u", "\\", ..acc])
        Ok(#(code, raw, after_hex)) ->
          scan_unicode_escape(code, raw, after_hex, acc)
      }
    Ok(#(other, after_other)) -> scan(after_other, [other, "\\", ..acc])
  }
}

fn scan_unicode_escape(
  code: Int,
  raw: String,
  after_hex: String,
  acc: List(String),
) -> List(String) {
  case is_high_surrogate(code) {
    True ->
      case peek_low_surrogate(after_hex) {
        Ok(#(low_raw, after_pair)) ->
          scan(after_pair, [low_raw, raw, "\\u", ..acc])
        Error(Nil) -> scan(after_hex, ["\\ufffd", ..acc])
      }
    False ->
      case is_low_surrogate(code) {
        True -> scan(after_hex, ["\\ufffd", ..acc])
        False -> scan(after_hex, [raw, "\\u", ..acc])
      }
  }
}

fn peek_low_surrogate(s: String) -> Result(#(String, String), Nil) {
  case string.pop_grapheme(s) {
    Ok(#("\\", r1)) ->
      case string.pop_grapheme(r1) {
        Ok(#("u", r2)) ->
          case take_hex4(r2) {
            Ok(#(code, raw, rest)) ->
              case is_low_surrogate(code) {
                True -> Ok(#("\\u" <> raw, rest))
                False -> Error(Nil)
              }
            Error(Nil) -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn take_hex4(s: String) -> Result(#(Int, String, String), Nil) {
  case string.pop_grapheme(s) {
    Error(Nil) -> Error(Nil)
    Ok(#(c1, r1)) ->
      case string.pop_grapheme(r1) {
        Error(Nil) -> Error(Nil)
        Ok(#(c2, r2)) ->
          case string.pop_grapheme(r2) {
            Error(Nil) -> Error(Nil)
            Ok(#(c3, r3)) ->
              case string.pop_grapheme(r3) {
                Error(Nil) -> Error(Nil)
                Ok(#(c4, r4)) -> {
                  let raw = c1 <> c2 <> c3 <> c4
                  case int.base_parse(raw, 16) {
                    Ok(code) -> Ok(#(code, raw, r4))
                    Error(Nil) -> Error(Nil)
                  }
                }
              }
          }
      }
  }
}

fn is_high_surrogate(code: Int) -> Bool {
  code >= 0xD800 && code <= 0xDBFF
}

fn is_low_surrogate(code: Int) -> Bool {
  code >= 0xDC00 && code <= 0xDFFF
}
