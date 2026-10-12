// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import necoherence/exact_json as json
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_values as values
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

fn replace_field(
  value: json.JsonValue,
  key: String,
  replacement: json.JsonValue,
) -> json.JsonValue {
  let assert json.JsonValueObj(members) = value
  json.JsonValueObj(
    list.map(members, fn(member) {
      case member.0 == key {
        True -> #(key, replacement)
        False -> member
      }
    }),
  )
}

fn node(id: String, shape: signatures.LibraryShape) -> json.JsonValue {
  let assert Ok(shape) = signatures.encode_library_shape(shape)
  json.JsonValueObj([
    #("id", json.JsonValueStr(id)),
    #("shape", shape),
  ])
}

fn representative_library() -> json.JsonValue {
  let profile =
    types.SemanticProfile(
      ..support.profile(),
      wrappers: [types.Wrapper("text", "$wrapped", types.WrapperText(None))],
      tag: Some(
        types.TagModel("$type", None, [
          types.SealedForm("sealed", [], types.SealedAny),
        ]),
      ),
    )
  let assert Ok(profile) = decode.encode_semantic_profile(profile)
  let string_spec =
    types.StringSpec(None, [], Some("text"), None, None, ["value"], None)
  let product =
    signatures.LibraryProductSpec(
      [
        signatures.SignatureField(
          "value",
          signatures.SignatureSlot("wrapped", True, False),
        ),
      ],
      signatures.LibraryRejectExtras,
    )
  let union =
    signatures.LibraryUnionSpec([
      signatures.LibraryUnionBranch(
        "product",
        "product",
        types.Kind(types.ObjectKind),
      ),
    ])
  let tagged_product_a =
    signatures.LibraryProductSpec(
      [
        signatures.SignatureField(
          "$type",
          signatures.SignatureSlot("tag", True, False),
        ),
        signatures.SignatureField(
          "payload",
          signatures.SignatureSlot("wrapped", True, False),
        ),
      ],
      signatures.LibraryRejectExtras,
    )
  let tagged_product_b =
    signatures.LibraryProductSpec(
      [
        signatures.SignatureField(
          "$type",
          signatures.SignatureSlot("tag", True, False),
        ),
        signatures.SignatureField(
          "payload",
          signatures.SignatureSlot("decimal", True, False),
        ),
      ],
      signatures.LibraryRejectExtras,
    )
  let internal_union =
    signatures.LibraryUnionSpec([
      signatures.LibraryUnionBranch("tagged_product_a", "a", types.InternalTag),
      signatures.LibraryUnionBranch("tagged_product_b", "b", types.InternalTag),
    ])
  support.library()
  |> replace_field("profile", profile)
  |> replace_field(
    "nodes",
    json.JsonValueArr([
      node("unit", signatures.UnitShape),
      node("wrapped", signatures.StringShape(string_spec)),
      node("decimal", signatures.DecimalShape(types.DecimalSpec(None, None))),
      node("sealed", signatures.SealedShape("sealed", [])),
      node("product", signatures.ProductShape(product)),
      node("union", signatures.TaggedUnionShape(union)),
      node(
        "tag",
        signatures.StringShape(types.StringSpec(
          None,
          [],
          None,
          None,
          None,
          ["a", "b"],
          None,
        )),
      ),
      node("tagged_product_a", signatures.ProductShape(tagged_product_a)),
      node("tagged_product_b", signatures.ProductShape(tagged_product_b)),
      node("internal_union", signatures.TaggedUnionShape(internal_union)),
      node("never", signatures.NeverShape),
    ]),
  )
}

fn checked() -> signatures.CheckedGeneration {
  let library_wire = support.wire(representative_library())
  let entries =
    json.JsonValueArr([
      json.JsonValueObj([
        #("identity", json.JsonValueStr("entry")),
        #("definition", json.JsonValueStr("entry")),
      ]),
    ])
  let assert Ok(assembled) =
    signatures.assemble_generation(library_wire, json.JsonValueNull, entries)
  let assert Ok(checked) = signatures.admit_generation(assembled.0, assembled.1)
  checked
}

pub fn pr01_is_preserved_through_all_generation_entries_test() {
  let invalid_profile =
    types.SemanticProfile(
      ..support.profile(),
      reference: types.ProfileRef("", "4", string.repeat("a", 64)),
    )
  let assert Ok(invalid_profile_wire) =
    decode.encode_semantic_profile(invalid_profile)
  let invalid_library =
    replace_field(representative_library(), "profile", invalid_profile_wire)
  let assert Error(decode.ProfileFailure(types.ProfileFailure(
    _,
    types.Pr01,
    ["profile"],
  ))) = decode.decode_checked_semantic_profile(invalid_profile_wire)
  let assert Error(signatures.Profile(types.ProfileFailure(
    _,
    types.Pr01,
    ["profile"],
  ))) = signatures.decode_library(support.wire(invalid_library))
  let checked = checked()
  let assert Ok(basis) = signatures.encode_basis(checked)
  let assert Ok(exchange_wire) = signatures.encode_checked(checked)
  let assert Ok(exchange) = values.parse_wire(exchange_wire)
  let invalid_exchange = replace_field(exchange, "signatures", invalid_library)
  let invalid_exchange_wire = support.wire(invalid_exchange)
  let assert Error(signatures.Profile(types.ProfileFailure(
    _,
    types.Pr01,
    ["profile"],
  ))) = signatures.admit_generation(basis, invalid_exchange_wire)
  let assert Error(renderer.Signature(signatures.Profile(types.ProfileFailure(
    _,
    types.Pr01,
    ["profile"],
  )))) = renderer.render_generation(basis, invalid_exchange_wire)
}

fn gleam_literal(value: String) -> String {
  "\""
  <> value
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  <> "\""
}

pub fn generated_representative_carriers_and_codecs_compile_test() {
  let checked = checked()
  let assert Ok(source) = renderer.render_signatures(checked)
  let assert Ok(basis) = signatures.encode_basis(checked)
  let assert Ok(exchange) = signatures.encode_checked(checked)
  let assert True = string.contains(source, "runtime.wrap_encode")
  let assert True = string.contains(source, "runtime.wrap_decode")
  let assert True = string.contains(source, "JsonValueDec")
  let assert True = string.contains(source, "Uninhabited")
  let assert True = string.contains(source, "runtime.with_member")
  let assert True = string.contains(source, "runtime.select_branch")
  let root = scratch_root()
  let assert Ok(Nil) = simplifile.delete_all([root])
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/src")
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/test")
  let manifest =
    "name = \"generated_representative\"\nversion = \"0.1.0\"\ngleam = \">= 1.17.0 and < 2.0.0\"\n[dependencies]\nnecoherence = { path = \""
    <> package_root()
    <> "\" }\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n[dev-dependencies]\ngleeunit = \">= 1.0.0 and < 2.0.0\"\n"
  let generated_test =
    "// SPDX-License-"
    <> "Identifier: MIT\nimport gleeunit\nimport generated\nimport necoherence/exact_json as json\nimport necoherence/semantic_signatures as signatures\nimport necoherence/semantic_types as types\npub fn main() { gleeunit.main() }\npub fn representative_values_roundtrip_test() {\n  let assert Ok(checked) = signatures.admit_generation("
    <> gleam_literal(basis)
    <> ", "
    <> gleam_literal(exchange)
    <> ")\n  let assert Ok(context) = generated.initialize(checked)\n  let assert Ok(wrapped) = generated.new_wrapped(context, \"value\")\n  let assert Ok(wrapped_wire) = generated.encode_wrapped(context, wrapped)\n  let assert Ok(wrapped_decoded) = generated.decode_wrapped(context, wrapped_wire)\n  assert generated.value_wrapped(wrapped_decoded) == \"value\"\n  let assert Ok(decimal) = generated.new_decimal(context, \"1.25\")\n  let assert Ok(decimal_wire) = generated.encode_decimal(context, decimal)\n  let assert Ok(decimal_decoded) = generated.decode_decimal(context, decimal_wire)\n  assert generated.value_decimal(decimal_decoded) == \"1.25\"\n  let assert Ok(sealed) = generated.decode_sealed(context, \"{\\\"$type\\\":\\\"sealed\\\"}\")\n  let assert Ok(\"{\\\"$type\\\":\\\"sealed\\\"}\") = generated.encode_sealed(context, sealed)\n  let assert Ok(product) = generated.new_product(context, generated.ProductPayload(types.Present(wrapped), []))\n  let assert Ok(product_wire) = generated.encode_product(context, product)\n  let assert Ok(product_decoded) = generated.decode_product(context, product_wire)\n  let assert generated.ProductPayload(types.Present(product_value), []) = generated.value_product(product_decoded)\n  assert generated.value_wrapped(product_value) == \"value\"\n  let assert Ok(union) = generated.new_union(context, generated.UnionProduct(product))\n  let assert Ok(union_wire) = generated.encode_union(context, union)\n  let assert Ok(union_decoded) = generated.decode_union(context, union_wire)\n  let generated.UnionProduct(_) = generated.value_union(union_decoded)\n  let assert Error(_) = generated.decode_never(context, \"null\")\n  let _ = json.JsonValueNull\n}\n"
  let generated_test =
    generated_test
    <> "pub fn internal_tag_branches_preserve_all_product_slots_and_wire_test() {\n"
    <> "  let assert Ok(checked) = signatures.admit_generation("
    <> gleam_literal(basis)
    <> ", "
    <> gleam_literal(exchange)
    <> ")\n"
    <> "  let assert Ok(context) = generated.initialize(checked)\n"
    <> "  let assert Ok(tag_a) = generated.new_tag(context, \"a\")\n"
    <> "  let assert Ok(payload_a) = generated.new_wrapped(context, \"value\")\n"
    <> "  let assert Ok(product_a) = generated.new_taggedproducta(context, generated.TaggedProductAPayload(types.Present(tag_a), types.Present(payload_a), []))\n"
    <> "  let assert Ok(union_a) = generated.new_internalunion(context, generated.InternalUnionA(product_a))\n"
    <> "  let assert Ok(wire_a) = generated.encode_internalunion(context, union_a)\n"
    <> "  let assert Ok(product_wire_a) = generated.encode_taggedproducta(context, product_a)\n"
    <> "  assert wire_a == product_wire_a\n"
    <> "  let assert Ok(decoded_a) = generated.decode_internalunion(context, wire_a)\n"
    <> "  let assert generated.InternalUnionA(decoded_product_a) = generated.value_internalunion(decoded_a)\n"
    <> "  let assert generated.TaggedProductAPayload(types.Present(decoded_tag_a), types.Present(decoded_payload_a), []) = generated.value_taggedproducta(decoded_product_a)\n"
    <> "  assert generated.value_tag(decoded_tag_a) == \"a\"\n"
    <> "  assert generated.value_wrapped(decoded_payload_a) == \"value\"\n"
    <> "  assert generated.value_taggedproducta(decoded_product_a) == generated.value_taggedproducta(product_a)\n"
    <> "  let assert Ok(reencoded_a) = generated.encode_internalunion(context, decoded_a)\n"
    <> "  assert reencoded_a == wire_a\n"
    <> "  let assert Ok(tag_b) = generated.new_tag(context, \"b\")\n"
    <> "  let assert Ok(payload_b) = generated.new_decimal(context, \"1.25\")\n"
    <> "  let assert Ok(product_b) = generated.new_taggedproductb(context, generated.TaggedProductBPayload(types.Present(tag_b), types.Present(payload_b), []))\n"
    <> "  let assert Ok(union_b) = generated.new_internalunion(context, generated.InternalUnionB(product_b))\n"
    <> "  let assert Ok(wire_b) = generated.encode_internalunion(context, union_b)\n"
    <> "  let assert Ok(product_wire_b) = generated.encode_taggedproductb(context, product_b)\n"
    <> "  assert wire_b == product_wire_b\n"
    <> "  let assert Ok(decoded_b) = generated.decode_internalunion(context, wire_b)\n"
    <> "  let assert generated.InternalUnionB(decoded_product_b) = generated.value_internalunion(decoded_b)\n"
    <> "  let assert generated.TaggedProductBPayload(types.Present(decoded_tag_b), types.Present(decoded_payload_b), []) = generated.value_taggedproductb(decoded_product_b)\n"
    <> "  assert generated.value_tag(decoded_tag_b) == \"b\"\n"
    <> "  assert generated.value_decimal(decoded_payload_b) == \"1.25\"\n"
    <> "  assert generated.value_taggedproductb(decoded_product_b) == generated.value_taggedproductb(product_b)\n"
    <> "  let assert Ok(reencoded_b) = generated.encode_internalunion(context, decoded_b)\n"
    <> "  assert reencoded_b == wire_b\n"
    <> "}\n"
  let assert Ok(Nil) = simplifile.write(root <> "/gleam.toml", manifest)
  let assert Ok(Nil) = simplifile.write(root <> "/src/generated.gleam", source)
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/test/generated_representative_test.gleam",
      generated_test,
    )
  let #(status, output) = run_shell(root, "gleam test")
  case status {
    0 -> Nil
    _ -> panic as output
  }
}
