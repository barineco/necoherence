// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

@external(erlang, "necoherence_semantic_generation_native", "sha256_utf8")
pub fn sha256_utf8(text: String) -> String

@external(erlang, "necoherence_semantic_generation_native", "encode_bytes")
pub fn encode_bytes(bytes: List(Int)) -> Result(String, Nil)

@external(erlang, "necoherence_semantic_generation_native", "decode_bytes")
pub fn decode_bytes(text: String) -> Result(List(Int), Nil)
