-- SPDX-FileCopyrightText: 2026 barineco
-- SPDX-License-Identifier: MIT

import Lean.Data.Json.Parser

namespace Necoherence.SignatureJson
open Lean Std.Internal.Parsec Std.Internal.Parsec.String

mutual
  private partial def value : Parser Json := do
    let next ← peek!
    if next == '{' then
      skip
      ws
      if (← peek!) == '}' then
        skip
        ws
        pure (.obj ∅)
      else
        object ∅
    else if next == '[' then
      skip
      ws
      if (← peek!) == ']' then
        skip
        ws
        pure (.arr #[])
      else
        array #[]
    else
      Json.Parser.anyCore

  private partial def object (members : Std.TreeMap.Raw String Json) : Parser Json := do
    Json.Parser.lookahead (· == '"') "object key"
    skip
    let key ← Json.Parser.str
    if members.contains key then fail ("duplicate object key: " ++ key)
    ws
    Json.Parser.lookahead (· == ':') "colon"
    skip
    ws
    let item ← value
    let members := members.insert key item
    let separator ← any
    ws
    if separator == '}' then pure (.obj members)
    else if separator == ',' then object members
    else fail "object separator"

  private partial def array (items : Array Json) : Parser Json := do
    let item ← value
    let items := items.push item
    let separator ← any
    ws
    if separator == ']' then pure (.arr items)
    else if separator == ',' then array items
    else fail "array separator"
end

def parse (text : String) : Except String Json :=
  Parser.run (do ws; let result ← value; eof; pure result) text

end Necoherence.SignatureJson
