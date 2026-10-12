// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

pub type JsonValue {
  JsonValueNull
  JsonValueBool(value: Bool)
  JsonValueNum(value: Int)
  JsonValueDec(text: String)
  JsonValueStr(value: String)
  JsonValueArr(items: List(JsonValue))
  JsonValueObj(members: List(#(String, JsonValue)))
}
