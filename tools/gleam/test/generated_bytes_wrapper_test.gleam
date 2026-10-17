// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import generated_representative_types_test as representative
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import necoherence/exact_json as json
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types
import necoherence_tools/renderer
import semantic_tools_test_support as support
import simplifile

@external(erlang, "generated_compile_support", "run_shell")
fn run_shell(directory: String, command: String) -> #(Int, String)

@external(erlang, "generated_compile_support", "scratch_root")
fn scratch_root() -> String

@external(erlang, "generated_compile_support", "package_root")
fn package_root() -> String

fn quote(value: String) -> String {
  let escaped =
    value
    |> string.replace("\\", "\\\\")
    |> string.replace("\"", "\\\"")
    |> string.replace("\n", "\\n")
  "\"" <> escaped <> "\""
}

fn node(id: String, shape: signatures.LibraryShape) -> json.JsonValue {
  let assert Ok(shape) = signatures.encode_library_shape(shape)
  json.JsonValueObj([#("id", json.JsonValueStr(id)), #("shape", shape)])
}

fn checked(wrapper: Option(String)) -> signatures.CheckedGeneration {
  let base = support.profile()
  let wrappers = case wrapper {
    None -> []
    Some(name) -> [types.Wrapper(name, "$payload", types.WrapperBytes)]
  }
  let profile =
    types.SemanticProfile(
      ..base,
      bytes_policy: Some(types.BytesPolicy(
        base.reference,
        True,
        types.Standard,
        True,
        wrapper,
      )),
      wrappers: wrappers,
    )
  let assert Ok(profile) = decode.encode_semantic_profile(profile)
  let nodes =
    json.JsonValueArr([
      node("unit", signatures.UnitShape),
      node("bytes", signatures.BytesShape(types.LengthSpec(None, None))),
      node("rawbody", signatures.RawBodyShape("application/octet-stream")),
    ])
  let assert json.JsonValueObj(members) = support.library()
  let library =
    json.JsonValueObj(
      list.map(members, fn(member) {
        case member.0 {
          "profile" -> #(member.0, profile)
          "nodes" -> #(member.0, nodes)
          _ -> member
        }
      }),
    )
  let entries =
    json.JsonValueArr([
      json.JsonValueObj([
        #("identity", json.JsonValueStr("entry")),
        #("definition", json.JsonValueStr("entry")),
      ]),
    ])
  let assert Ok(assembled) =
    signatures.assemble_generation(
      support.wire(library),
      json.JsonValueNull,
      entries,
    )
  let assert Ok(checked) = signatures.admit_generation(assembled.0, assembled.1)
  checked
}

fn roundtrip_function(name: String) -> String {
  "fn verify_"
  <> name
  <> "(context: generated.Context, bytes: List(Int), expected: json.JsonValue) {\n"
  <> "  let assert Ok(value) = generated.new_"
  <> name
  <> "(context, bytes)\n"
  <> "  let assert Ok(wire) = generated.encode_"
  <> name
  <> "(context, value)\n"
  <> "  let assert Ok(encoded) = values.parse_wire(wire)\n"
  <> "  assert encoded == expected\n"
  <> "  let assert Ok(decoded) = generated.decode_"
  <> name
  <> "(context, wire)\n"
  <> "  assert generated.value_"
  <> name
  <> "(decoded) == bytes\n"
  <> "  let assert Ok(reencoded) = generated.encode_"
  <> name
  <> "(context, decoded)\n"
  <> "  assert reencoded == wire\n}\n"
}

fn consumer(
  basis: String,
  exchange: String,
  wrapper: Option(String),
) -> String {
  let expected = case wrapper {
    None -> "fn expected(text) { json.JsonValueStr(text) }\n"
    Some(_) ->
      "fn expected(text) { json.JsonValueObj([#(\"$payload\", json.JsonValueStr(text))]) }\n"
  }
  let #(imports, invalid) = case wrapper {
    None -> #("", "")
    Some(_) -> #(
      "import gleam/list\nimport necoherence/semantic_generation_runtime as runtime\nimport necoherence/semantic_validation as validation\nimport necoherence/semantic_types as types\n",
      "  list.each([json.JsonValueObj([#(\"wrong\", json.JsonValueStr(\"\"))]), json.JsonValueObj([#(\"$payload\", json.JsonValueBool(False))])], fn(value) {\n"
        <> "    let assert Error(runtime.Constraint(validation.Rejected(types.ValueFailure(condition: types.InvalidBytesCondition, ..)))) = generated.from_value_bytes(context, value)\n"
        <> "    let assert Error(runtime.Constraint(validation.Rejected(types.ValueFailure(condition: types.InvalidBytesCondition, ..)))) = generated.from_value_rawbody(context, value)\n"
        <> "  })\n",
    )
  }
  "// SPDX-" <> "License-Identifier: MIT\n"
  <> "import generated\nimport necoherence/exact_json as json\n"
  <> "import necoherence/semantic_generation_values as values\n"
  <> imports
  <> "import necoherence/semantic_signatures as signatures\n"
  <> expected
  <> roundtrip_function("bytes")
  <> roundtrip_function("rawbody")
  <> "pub fn main() {\n  let assert Ok(checked) = signatures.admit_generation("
  <> quote(basis)
  <> ", "
  <> quote(exchange)
  <> ")\n"
  <> "  let assert Ok(context) = generated.initialize(checked)\n"
  <> "  verify_bytes(context, [], expected(\"\"))\n"
  <> "  verify_bytes(context, [0, 128, 255], expected(\"AID/\"))\n"
  <> "  verify_rawbody(context, [], expected(\"\"))\n"
  <> "  verify_rawbody(context, [0, 128, 255], expected(\"AID/\"))\n"
  <> invalid
  <> "}\n"
}

fn compile_consumer(wrapper: Option(String)) {
  let checked = checked(wrapper)
  let assert Ok(source) = renderer.render_signatures(checked)
  let assert Ok(basis) = signatures.encode_basis(checked)
  let assert Ok(exchange) = signatures.encode_checked(checked)
  let suffix = case wrapper {
    None -> "-bytes-bare"
    Some(_) -> "-bytes-wrapped"
  }
  let root = scratch_root() <> suffix
  let assert Ok(Nil) = simplifile.delete_all([root])
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/src")
  let manifest =
    "name = \"generated_bytes_consumer\"\nversion = \"0.1.0\"\n[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\nnecoherence = { path = "
    <> quote(package_root())
    <> " }\n"
  let assert Ok(Nil) = simplifile.write(root <> "/gleam.toml", manifest)
  let assert Ok(Nil) = simplifile.write(root <> "/src/generated.gleam", source)
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/src/consumer.gleam",
      consumer(basis, exchange, wrapper),
    )
  let #(status, output) = run_shell(root, "gleam run -m consumer")
  case status {
    0 -> {
      let assert Ok(Nil) = simplifile.delete_all([root])
      Nil
    }
    _ -> panic as output
  }
}

pub fn declared_wrapper_bytes_and_rawbody_roundtrip() {
  compile_consumer(Some("binary_container"))
}

pub fn unwrapped_bytes_and_rawbody_roundtrip() {
  compile_consumer(None)
}

pub fn main() {
  declared_wrapper_bytes_and_rawbody_roundtrip()
  unwrapped_bytes_and_rawbody_roundtrip()
  representative.generated_representative_carriers_and_codecs_compile()
}
