-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Lean.Data.Json
import Lean.Data.Json.Parser

namespace Necoherence.ExactJson

open Lean

inductive JsonValue where
  | null
  | bool (value : Bool)
  | num (value : Int)
  | dec (text : String)
  | str (value : String)
  | arr (items : List JsonValue)
  | obj (members : List (String × JsonValue))
  deriving BEq, Repr

def memberValue (key : String) (members : List (String × JsonValue)) : Option JsonValue :=
  (members.find? (fun m => m.1 == key)).map (·.2)

def firstRepeated (seen : List String) : List String → Option String
  | [] => none
  | key :: rest => if seen.contains key then some key else firstRepeated (key :: seen) rest

def allDigits (cs : List Char) : Bool :=
  !cs.isEmpty && cs.all Char.isDigit

mutual
  def jsonSize : JsonValue → Nat
    | .arr items => 1 + jsonSizeList items
    | .obj members => 1 + jsonSizeMembers members
    | _ => 1

  def jsonSizeList : List JsonValue → Nat
    | [] => 0
    | v :: rest => jsonSize v + jsonSizeList rest

  def jsonSizeMembers : List (String × JsonValue) → Nat
    | [] => 0
    | (_, v) :: rest => jsonSize v + jsonSizeMembers rest
end

def _root_.Option.toExcept (value : Option α) (message : String) : Except String α :=
  match value with
  | some value => .ok value
  | none => .error message

instance : Inhabited JsonValue := ⟨.null⟩

/-- The exponent limit of JSON numbers: a written exponent of this magnitude or more is rejected. -/
def exponentLimit : Nat := 10000

private def exponentValue : List Char → Nat → Nat → Nat × Nat
  | c :: rest, acc, count =>
    if '0' ≤ c && c ≤ '9' then exponentValue rest (min exponentLimit (acc * 10 + (c.toNat - '0'.toNat))) (count + 1)
    else (acc, count)
  | [], acc, count => (acc, count)

private def exponentDigits : List Char → List Char
  | '-' :: rest => rest
  | '+' :: rest => rest
  | rest => rest

/-- Whether the digits after an exponent marker reach `exponentLimit` in magnitude. -/
def exponentMagnitudeAtLimit (chars : List Char) : Bool :=
  let (value, count) := exponentValue (exponentDigits chars) 0 0
  0 < count && exponentLimit ≤ value

private def hexDigit? (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat)
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
  else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
  else none

private def hexCode? : List Char → Option Nat
  | [a, b, c, d] => do
    let a ← hexDigit? a
    let b ← hexDigit? b
    let c ← hexDigit? c
    let d ← hexDigit? d
    pure (((a * 16 + b) * 16 + c) * 16 + d)
  | _ => none

private def isHighSurrogate (code : Nat) : Bool := 0xD800 ≤ code && code ≤ 0xDBFF
private def isLowSurrogate (code : Nat) : Bool := 0xDC00 ≤ code && code ≤ 0xDFFF

private partial def admissionFailureChars : List Char → Bool → Option String
  | [], _ => none
  | '"' :: rest, false => admissionFailureChars rest true
  | '"' :: rest, true => admissionFailureChars rest false
  | '\\' :: 'u' :: rest, true =>
    match hexCode? (rest.take 4) with
    | none => admissionFailureChars rest true
    | some code =>
      if isLowSurrogate code then some "unpaired Unicode surrogate"
      else if isHighSurrogate code then
        match rest.drop 4 with
        | '\\' :: 'u' :: tail =>
          match hexCode? (tail.take 4) with
          | some low => if isLowSurrogate low then admissionFailureChars (tail.drop 4) true else some "unpaired Unicode surrogate"
          | none => some "unpaired Unicode surrogate"
        | _ => some "unpaired Unicode surrogate"
      else admissionFailureChars (rest.drop 4) true
  | '\\' :: _ :: rest, true => admissionFailureChars rest true
  | c :: rest, false =>
    if (c == 'e' || c == 'E') && exponentMagnitudeAtLimit rest then some "exponent too large"
    else admissionFailureChars rest false
  | _ :: rest, inString => admissionFailureChars rest inString

/-- The first failure of a JSON text in text order: an exponent that reaches `exponentLimit` outside its strings, or an escape of an unpaired surrogate inside a string. -/
def admissionFailure (text : String) : Option String :=
  admissionFailureChars text.toList false

section StrictParser
open Std.Internal.Parsec Std.Internal.Parsec.String

mutual
  private partial def strictValue : Parser Json := do
    let next ← peek!
    if next == '{' then
      skip
      ws
      if (← peek!) == '}' then
        skip
        ws
        pure (.obj ∅)
      else
        strictObject ∅
    else if next == '[' then
      skip
      ws
      if (← peek!) == ']' then
        skip
        ws
        pure (.arr #[])
      else
        strictArray #[]
    else
      Json.Parser.anyCore

  private partial def strictObject (members : Std.TreeMap.Raw String Json) : Parser Json := do
    Json.Parser.lookahead (· == '"') "object key"
    skip
    let key ← Json.Parser.str
    if members.contains key then fail ("duplicate object key: " ++ key)
    ws
    Json.Parser.lookahead (· == ':') "colon"
    skip
    ws
    let item ← strictValue
    let members := members.insert key item
    let separator ← any
    ws
    if separator == '}' then pure (.obj members)
    else if separator == ',' then strictObject members
    else fail "object separator"

  private partial def strictArray (items : Array Json) : Parser Json := do
    let item ← strictValue
    let items := items.push item
    let separator ← any
    ws
    if separator == ']' then pure (.arr items)
    else if separator == ',' then strictArray items
    else fail "array separator"
end

/-- Parse a JSON text under the signature entry rules: an admission failure first, then a strict parse that rejects duplicate object keys. -/
def boundedJsonParse (text : String) : Except String Json :=
  match admissionFailure text with
  | some message => .error message
  | none => Parser.run (do ws; let result ← strictValue; eof; pure result) text

end StrictParser

/-- The text of a JSON number with a fraction or an exponent, with zero written as `0` at any exponent. -/
def canonicalDecimalText (value : JsonNumber) : String :=
  if value.mantissa == 0 then "0" else value.toString

/-- The JSON number that carries a decimal: a zero or integer value gets exponent 1, so that `fromJson` reads it as `.dec`. -/
def decimalNumber (value : JsonNumber) : JsonNumber :=
  if value.mantissa % (10 : Int) ^ value.exponent == 0 then
    ⟨value.mantissa / (10 : Int) ^ value.exponent * 10, 1⟩
  else value

theorem decimalNumber_exponent_ne_zero (value : JsonNumber) : (decimalNumber value).exponent ≠ 0 := by
  unfold decimalNumber
  split
  · exact Nat.one_ne_zero
  · rename_i nonInteger
    intro zero
    apply nonInteger
    simp [zero]

/-- The spelling of a JSON number: a zero or integer value with an exponent keeps `.0`, and other values use the core spelling. -/
def numberText (value : JsonNumber) : String :=
  if value.exponent != 0 && value.mantissa % (10 : Int) ^ value.exponent == 0 then
    s!"{value.mantissa / (10 : Int) ^ value.exponent}.0"
  else value.toString

partial def fromJson : Json → JsonValue
  | .null => .null
  | .bool value => .bool value
  | .str value => .str value
  | .num value =>
    if value.exponent == 0 then .num value.mantissa
    else .dec (canonicalDecimalText value)
  | .arr values => .arr (values.toList.map fromJson)
  | .obj values => .obj (values.toList.map fun (key, value) => (key, fromJson value))

partial def toJson : JsonValue → Except String Json
  | .null => pure .null
  | .bool value => pure (.bool value)
  | .str value => pure (.str value)
  | .num value => pure (.num (JsonNumber.fromInt value))
  | .dec text => do
    let .num number ← boundedJsonParse text | throw s!"invalid exact decimal: {text}"
    pure (.num (decimalNumber number))
  | .arr values => return .arr (← values.mapM toJson).toArray
  | .obj values => return Json.mkObj (← values.mapM fun (key, value) => return (key, ← toJson value))

/-- Compact JSON text of a value, with numbers spelled by `numberText`. -/
partial def compressJson : Json → String
  | .null => "null"
  | .bool value => toString value
  | .num value => numberText value
  | .str value => (Json.str value).compress
  | .arr values => "[" ++ ",".intercalate (values.toList.map compressJson) ++ "]"
  | .obj values => "{" ++ ",".intercalate (values.toList.map fun (key, value) =>
      (Json.str key).compress ++ ":" ++ compressJson value) ++ "}"

end Necoherence.ExactJson
