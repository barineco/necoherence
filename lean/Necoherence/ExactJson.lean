-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Lean.Data.Json

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

partial def fromJson : Json → JsonValue
  | .null => .null
  | .bool value => .bool value
  | .str value => .str value
  | .num value => if value.exponent == 0 then .num value.mantissa else .dec value.toString
  | .arr values => .arr (values.toList.map fromJson)
  | .obj values => .obj (values.toList.map fun (key, value) => (key, fromJson value))

partial def toJson : JsonValue → Except String Json
  | .null => pure .null
  | .bool value => pure (.bool value)
  | .str value => pure (.str value)
  | .num value => pure (.num (JsonNumber.fromInt value))
  | .dec value => Json.parse value
  | .arr values => return .arr (← values.mapM toJson).toArray
  | .obj values => return Json.mkObj (← values.mapM fun (key, value) => return (key, ← toJson value))

end Necoherence.ExactJson
