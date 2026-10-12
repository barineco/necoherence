-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Necoherence.SemanticComposition
import Necoherence.SemanticProfile

namespace Necoherence.SemanticCodec

open Necoherence.ExactJson Necoherence.SemanticTypes Necoherence.SemanticValidation

inductive Presence (α : Type) where
  | absent | null | present (value : α)
  deriving Repr

def presenceMapM [Monad m] (f : α → m β) : Presence α → m (Presence β)
  | .absent => pure .absent
  | .null => pure .null
  | .present value => return .present (← f value)

structure Bytes where
  data : List UInt8
  wire : Option String := none
  deriving Repr

structure CheckedValue (α : Type) (graph : SemanticGraph) (ref : TypeRef)
    (encode : α → JsonValue) where
  value : α
  valid : ValidatedValue graph ref (encode value)

def construct (graph : SemanticGraph) (ref : TypeRef) (encode : α → JsonValue) (value : α) :
    Except ValidationFailure (CheckedValue α graph ref encode) := do
  let valid ← validateValue graph ref (encode value)
  pure { value, valid }

theorem constructedMember (value : CheckedValue α graph ref encode) :
    ValueMember graph ref [] (encode value.value) := value.valid.member

def invariantFailure (message : String) : Except ValidationFailure α :=
  .error (.certificateMismatch message)

private def base64Digit (alphabet : BytesAlphabet) (c : Char) : Option Nat :=
  if 'A' ≤ c && c ≤ 'Z' then some (c.toNat - 'A'.toNat)
  else if 'a' ≤ c && c ≤ 'z' then some (26 + c.toNat - 'a'.toNat)
  else if '0' ≤ c && c ≤ '9' then some (52 + c.toNat - '0'.toNat)
  else match alphabet with
    | .standard => if c == '+' then some 62 else if c == '/' then some 63 else none
    | .urlSafe => if c == '-' then some 62 else if c == '_' then some 63 else none
    | .either =>
      if c == '+' || c == '-' then some 62
      else if c == '/' || c == '_' then some 63
      else none

def decodeBase64 (alphabet : BytesAlphabet) (wire : String) : Option (List UInt8) := do
  let body := ((wire.splitOn "=").head?).getD ""
  let (_, _, bytes) ← body.toList.foldlM (init := (0, 0, [])) fun (bits, buffer, bytes) c => do
    let digit ← base64Digit alphabet c
    let bits := bits + 6
    let buffer := buffer * 64 + digit
    if bits ≥ 8 then
      let remaining := bits - 8
      let scale := 2 ^ remaining
      pure (remaining, buffer % scale, UInt8.ofNat (buffer / scale) :: bytes)
    else pure (bits, buffer, bytes)
  pure bytes.reverse

private def base64Alphabet : BytesAlphabet → Array Char
  | .urlSafe => "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".toList.toArray
  | .standard | .either =>
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toList.toArray

private def encodeBase64Chars (alphabet : BytesAlphabet) : List UInt8 → List Char
  | [] => []
  | [a] => [(base64Alphabet alphabet)[a.toNat / 4]!,
      (base64Alphabet alphabet)[(a.toNat % 4) * 16]!, '=', '=']
  | [a, b] => [(base64Alphabet alphabet)[a.toNat / 4]!,
      (base64Alphabet alphabet)[(a.toNat % 4) * 16 + b.toNat / 16]!,
      (base64Alphabet alphabet)[(b.toNat % 16) * 4]!, '=']
  | a :: b :: c :: rest =>
    (base64Alphabet alphabet)[a.toNat / 4]! ::
      (base64Alphabet alphabet)[(a.toNat % 4) * 16 + b.toNat / 16]! ::
      (base64Alphabet alphabet)[(b.toNat % 16) * 4 + c.toNat / 64]! ::
      (base64Alphabet alphabet)[c.toNat % 64]! :: encodeBase64Chars alphabet rest

def encodeBase64For (alphabet : BytesAlphabet) (value : List UInt8) : String :=
  String.ofList (encodeBase64Chars alphabet value)

def encodeBase64 (value : List UInt8) : String := encodeBase64For .standard value

def wrapEncode (wrapper : Wrapper) (value : String) : JsonValue :=
  .obj [(wrapper.key, .str value)]

def wrapDecode (wrapper : Wrapper) : JsonValue → Except ValidationFailure String
  | .obj [(key, .str value)] =>
    if key == wrapper.key then pure value else invariantFailure "validated wrapper shape"
  | _ => invariantFailure "validated wrapper shape"

def bytesEncode (profile : VersionedSemanticProfile) (value : Bytes) : JsonValue :=
  let policy := profile.bytesPolicy.getD {
    reference := profile.reference, paddingOptional := false, alphabet := .standard,
    strictPadBits := true }
  let encoded := encodeBase64For policy.alphabet value.data
  let wire := match value.wire with
    | some wire =>
      if (base64Length policy wire).isSome &&
          decodeBase64 policy.alphabet wire == some value.data then wire
      else encoded
    | none => encoded
  match policy.wrapper with
  | some name => match profile.wrappers.find? (fun wrapper => wrapper.name == name) with
    | some wrapper => wrapEncode wrapper wire
    | none => .str wire
  | none => .str wire

def bytesDecode (profile : VersionedSemanticProfile) (value : JsonValue) :
    Except ValidationFailure Bytes := do
  let policy ← match profile.bytesPolicy with
    | some policy => pure policy
    | none => invariantFailure "validated bytes policy"
  let wire ← match policy.wrapper with
    | some name => match profile.wrappers.find? (fun wrapper => wrapper.name == name) with
      | some wrapper => wrapDecode wrapper value
      | none => invariantFailure "validated bytes wrapper"
    | none => match value with
      | .str wire => pure wire
      | _ => invariantFailure "validated bytes shape"
  if (base64Length policy wire).isNone then
    invariantFailure "validated bytes encoding"
  else match decodeBase64 policy.alphabet wire with
    | some data => pure { data, wire := some wire }
    | none => invariantFailure "validated bytes encoding"

def withMember (key : String) (value : JsonValue) : JsonValue → JsonValue
  | .obj members => .obj ((key, value) :: members.filter (fun pair => pair.1 != key))
  | other => other

def fieldValue (members : List (String × JsonValue)) (name : String) : SlotValue :=
  match memberValue name members with
  | none => .absent | some .null => .null | some value => .present value

def decodeRequired (decode : JsonValue → Except ValidationFailure α) : SlotValue → Except ValidationFailure α
  | .present value => decode value
  | _ => invariantFailure "validated required field"

def decodeOptional (decode : JsonValue → Except ValidationFailure α) : SlotValue → Except ValidationFailure (Option α)
  | .absent => pure none
  | .present value => return some (← decode value)
  | .null => invariantFailure "validated nonnullable field"

def decodeNullable (decode : JsonValue → Except ValidationFailure α) : SlotValue → Except ValidationFailure (Option α)
  | .null => pure none
  | .present value => return some (← decode value)
  | .absent => invariantFailure "validated required nullable field"

def decodePresence (decode : JsonValue → Except ValidationFailure α) : SlotValue → Except ValidationFailure (Presence α)
  | .absent => pure .absent | .null => pure .null
  | .present value => return .present (← decode value)

def requiredField (name : String) (encode : α → JsonValue) (value : α) : List (String × JsonValue) :=
  [(name, encode value)]
def optionalField (name : String) (encode : α → JsonValue) : Option α → List (String × JsonValue)
  | none => [] | some value => [(name, encode value)]
def nullableField (name : String) (encode : α → JsonValue) : Option α → List (String × JsonValue)
  | none => [(name, .null)] | some value => [(name, encode value)]
def presenceField (name : String) (encode : α → JsonValue) : Presence α → List (String × JsonValue)
  | .absent => [] | .null => [(name, .null)] | .present value => [(name, encode value)]

end Necoherence.SemanticCodec
