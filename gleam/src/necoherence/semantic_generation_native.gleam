// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import necoherence/semantic_base64 as base64
import necoherence/semantic_types as types

@external(erlang, "necoherence_semantic_generation_native", "sha256_utf8")
pub fn sha256_utf8(text: String) -> String

@external(erlang, "necoherence_semantic_generation_native", "encode_bytes")
pub fn encode_bytes(bytes: List(Int)) -> Result(String, Nil)

pub fn decode_bytes(text: String) -> Result(List(Int), Nil) {
  base64.decode(text, True, types.Either, False)
}

pub fn decode_bytes_with_policy(
  policy: types.BytesPolicy,
  text: String,
) -> Result(List(Int), Nil) {
  base64.decode(
    text,
    policy.padding_optional,
    policy.alphabet,
    policy.strict_pad_bits,
  )
}
