// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types

fn reference() -> types.ProfileRef {
  types.ProfileRef("profile", "4", string.repeat("a", 64))
}

fn profile() -> types.SemanticProfile {
  types.SemanticProfile(
    reference(),
    [],
    [
      types.IntegerDomainBinding("integer", reference(), types.Unbounded, [
        types.Number,
      ]),
    ],
    "integer",
    types.NumberModel(True),
    None,
    [],
    None,
    [],
    Some(types.TagModel("kind", None, [])),
  )
}

fn empty_string_spec() -> types.StringSpec {
  types.StringSpec(None, [], None, None, None, [], None)
}

fn library(
  nodes: List(signatures.LibraryNode),
) -> signatures.TypeSignatureLibrary {
  signatures.TypeSignatureLibrary(
    "ncoh-type-signatures@1",
    "library",
    "1",
    profile(),
    [],
    [],
    [],
    [],
    nodes,
    [],
  )
}

fn internal_tag_library(second_tag: String) -> signatures.TypeSignatureLibrary {
  let tag_node = fn(id, tag) {
    signatures.LibraryNode(
      id,
      signatures.StringShape(types.StringSpec(
        None,
        [],
        None,
        Some(tag),
        None,
        [],
        None,
      )),
    )
  }
  let product_node = fn(id, tag_id) {
    signatures.LibraryNode(
      id,
      signatures.ProductShape(signatures.LibraryProductSpec(
        [
          signatures.SignatureField(
            "$type",
            signatures.SignatureSlot(tag_id, True, False),
          ),
        ],
        signatures.LibraryRejectExtras,
      )),
    )
  }
  let value =
    library([
      tag_node("tag-a", "a"),
      tag_node("tag-b", second_tag),
      product_node("product-a", "tag-a"),
      product_node("product-b", "tag-b"),
      signatures.LibraryNode(
        "union",
        signatures.TaggedUnionShape(
          signatures.LibraryUnionSpec([
            signatures.LibraryUnionBranch("product-a", "a", types.InternalTag),
            signatures.LibraryUnionBranch(
              "product-b",
              second_tag,
              types.InternalTag,
            ),
          ]),
        ),
      ),
    ])
  signatures.TypeSignatureLibrary(
    ..value,
    profile: types.SemanticProfile(
      ..value.profile,
      tag: Some(types.TagModel("$type", None, [])),
    ),
  )
}

pub fn library_check_admits_distinct_internal_tags_test() {
  let value = internal_tag_library("b")
  let assert Ok(checked) = signatures.check_library(value)
  let assert True = signatures.checked_library_value(checked) == value
}

pub fn library_check_rejects_duplicate_internal_tags_with_lb04_test() {
  let assert Error(types.LibraryCheck(types.LibraryFailure(
    "library",
    types.Lb04,
    ["library"],
  ))) = signatures.check_library(internal_tag_library("a"))
}

fn duplicate_selector_library(
  selector: types.BranchSelector,
) -> signatures.TypeSignatureLibrary {
  library([
    signatures.LibraryNode("target", signatures.UnitShape),
    signatures.LibraryNode(
      "union",
      signatures.TaggedUnionShape(
        signatures.LibraryUnionSpec([
          signatures.LibraryUnionBranch("target", "first", selector),
          signatures.LibraryUnionBranch("target", "second", selector),
        ]),
      ),
    ),
  ])
}

pub fn library_check_rejects_duplicate_kind_selectors_with_lb18_test() {
  let assert Error(types.LibraryCheck(types.LibraryFailure(
    "library",
    types.Lb18,
    ["library"],
  ))) =
    signatures.check_library(
      duplicate_selector_library(types.Kind(types.NullKind)),
    )
}

pub fn library_check_rejects_duplicate_member_shapes_with_lb18_test() {
  let assert Error(types.LibraryCheck(types.LibraryFailure(
    "library",
    types.Lb18,
    ["library"],
  ))) =
    signatures.check_library(
      duplicate_selector_library(
        types.MemberShape([#("key", types.AbsentMember)]),
      ),
    )
}

pub fn library_check_returns_checked_value_test() {
  let value = library([])
  let assert Ok(checked) = signatures.check_library(value)
  let assert True = signatures.checked_library_value(checked) == value
}

pub fn library_check_preserves_lb04_for_duplicate_union_tags_test() {
  let branch = fn() {
    signatures.LibraryUnionBranch(
      "target",
      "duplicate",
      types.Kind(types.StringKind),
    )
  }
  let value =
    library([
      signatures.LibraryNode(
        "target",
        signatures.StringShape(empty_string_spec()),
      ),
      signatures.LibraryNode(
        "union",
        signatures.TaggedUnionShape(
          signatures.LibraryUnionSpec([branch(), branch()]),
        ),
      ),
    ])
  let assert Error(types.LibraryCheck(types.LibraryFailure(
    "library",
    types.Lb04,
    ["library"],
  ))) = signatures.check_library(value)
}

pub fn library_check_preserves_lb17_for_invalid_tag_field_test() {
  let value =
    library([
      signatures.LibraryNode(
        "tag",
        signatures.StringShape(types.StringSpec(
          None,
          [],
          None,
          Some("expected"),
          None,
          [],
          None,
        )),
      ),
      signatures.LibraryNode(
        "product",
        signatures.ProductShape(signatures.LibraryProductSpec(
          [
            signatures.SignatureField(
              "kind",
              signatures.SignatureSlot("tag", True, False),
            ),
          ],
          signatures.LibraryRejectExtras,
        )),
      ),
      signatures.LibraryNode(
        "union",
        signatures.TaggedUnionShape(
          signatures.LibraryUnionSpec([
            signatures.LibraryUnionBranch(
              "product",
              "actual",
              types.InternalTag,
            ),
          ]),
        ),
      ),
    ])
  let assert Error(types.LibraryCheck(types.LibraryFailure(
    "library",
    types.Lb17,
    ["library"],
  ))) = signatures.check_library(value)
}

pub fn library_check_preserves_lb19_for_invalid_declared_value_test() {
  let value =
    library([
      signatures.LibraryNode(
        "subject",
        signatures.StringShape(types.StringSpec(
          Some(types.InlineFormat(types.Literal("expected"))),
          [],
          None,
          Some("actual"),
          None,
          [],
          None,
        )),
      ),
    ])
  let assert Error(types.LibraryCheck(types.LibraryFailure(
    "library",
    types.Lb19,
    ["library"],
  ))) = signatures.check_library(value)
}

fn union_library(
  branches: List(signatures.LibraryUnionBranch),
) -> signatures.TypeSignatureLibrary {
  library([
    signatures.LibraryNode(
      "target",
      signatures.StringShape(empty_string_spec()),
    ),
    signatures.LibraryNode(
      "union",
      signatures.TaggedUnionShape(signatures.LibraryUnionSpec(branches)),
    ),
  ])
}

fn library_predicate(
  value: signatures.TypeSignatureLibrary,
) -> types.LibraryPredicate {
  let assert Error(types.LibraryCheck(types.LibraryFailure(
    "library",
    predicate,
    ["library"],
  ))) = signatures.check_library(value)
  predicate
}

pub fn library_check_reports_an_empty_wire_tag_with_lb06_test() {
  let value =
    union_library([
      signatures.LibraryUnionBranch("target", "", types.Kind(types.StringKind)),
    ])
  let assert types.Lb06 = library_predicate(value)
}

pub fn library_check_reports_lb06_before_lb09_test() {
  let value =
    union_library([
      signatures.LibraryUnionBranch(
        "target",
        "",
        types.MemberShape([
          #("key", types.AbsentMember),
          #("key", types.AbsentMember),
        ]),
      ),
    ])
  let assert types.Lb06 = library_predicate(value)
}

pub fn library_check_reports_duplicate_empty_wire_tags_with_lb04_test() {
  let branch = fn(kind) { signatures.LibraryUnionBranch("target", "", kind) }
  let value =
    union_library([
      branch(types.Kind(types.StringKind)),
      branch(types.Kind(types.NullKind)),
    ])
  let assert types.Lb04 = library_predicate(value)
}

fn sealed_profile(leaf: types.SealedLeaf) -> types.SemanticProfile {
  types.SemanticProfile(
    ..profile(),
    tag: Some(
      types.TagModel("kind", None, [
        types.SealedForm(
          "form",
          [types.SealedField("key", True, leaf)],
          types.SealedReject,
        ),
      ]),
    ),
  )
}

fn sealed_library(
  declared: types.SealedLeaf,
  refined: types.SealedLeaf,
) -> signatures.TypeSignatureLibrary {
  signatures.TypeSignatureLibrary(
    ..library([
      signatures.LibraryNode(
        "sealed",
        signatures.SealedShape("form", [types.SealedRefinement("key", refined)]),
      ),
    ]),
    profile: sealed_profile(declared),
  )
}

pub fn library_check_rejects_a_refinement_leaf_of_another_kind_with_lb10_test() {
  let integer =
    types.SealedInteger(types.IntegerSpec(None, None, None, None, None, None))
  let string = types.SealedString(empty_string_spec())
  let assert types.Lb10 = library_predicate(sealed_library(string, integer))
  let assert types.Lb10 = library_predicate(sealed_library(integer, string))
  let assert Ok(_) = signatures.check_library(sealed_library(string, string))
  let assert Ok(_) = signatures.check_library(sealed_library(integer, integer))
}

fn inline_format_library(
  rule: types.FormatRule,
) -> signatures.TypeSignatureLibrary {
  library([
    signatures.LibraryNode(
      "text",
      signatures.StringShape(types.StringSpec(
        Some(types.InlineFormat(rule)),
        [],
        None,
        None,
        None,
        [],
        None,
      )),
    ),
  ])
}

pub fn library_check_rejects_an_ill_formed_inline_format_with_lb13_test() {
  let timestamp = fn(minimum, maximum) {
    types.Timestamp(types.CalendarRule(False, minimum, maximum, False))
  }
  let assert types.Lb13 =
    library_predicate(inline_format_library(timestamp(2000, 1999)))
  let assert types.Lb13 =
    library_predicate(
      inline_format_library(
        types.Sequence([types.Optional(timestamp(2000, 1999))]),
      ),
    )
  let assert types.Lb13 =
    library_predicate(
      inline_format_library(types.Labels("", 1, Some(2), None, types.Text)),
    )
  let assert Ok(_) =
    signatures.check_library(inline_format_library(timestamp(1999, 2000)))
}

pub fn library_shape_codec_roundtrips_every_constructor_test() {
  let shapes = [
    signatures.UnknownShape(types.AnyValue),
    signatures.UnitShape,
    signatures.BooleanShape(types.BooleanSpec(None, None)),
    signatures.IntegerShape(types.IntegerSpec(
      None,
      None,
      None,
      None,
      None,
      None,
    )),
    signatures.DecimalShape(types.DecimalSpec(
      Some(types.DecimalBound(1, 2, False)),
      None,
    )),
    signatures.StringShape(empty_string_spec()),
    signatures.BytesShape(types.LengthSpec(None, Some(8))),
    signatures.ProductShape(signatures.LibraryProductSpec(
      [
        signatures.SignatureField(
          "field",
          signatures.SignatureSlot("target", True, False),
        ),
      ],
      signatures.LibraryAllowExtras(
        Some(types.InlineFormat(types.Text)),
        signatures.LibraryElementContract("target", True),
      ),
    )),
    signatures.ArrayShape(signatures.LibraryArraySpec(
      signatures.LibraryElementContract("target", False),
      Some(1),
      Some(2),
    )),
    signatures.TaggedUnionShape(
      signatures.LibraryUnionSpec([
        signatures.LibraryUnionBranch(
          "target",
          "text",
          types.Kind(types.StringKind),
        ),
      ]),
    ),
    signatures.SealedShape("sealed", [
      types.SealedRefinement("field", types.SealedString(empty_string_spec())),
    ]),
    signatures.NeverShape,
    signatures.AliasShape("target"),
    signatures.RawBodyShape("raw"),
    signatures.OpaqueShape("opaque"),
  ]
  list.each(shapes, fn(shape) {
    let assert Ok(encoded) = signatures.encode_library_shape(shape)
    let assert Ok(decoded) = signatures.decode_library_shape(encoded)
    let assert True = decoded == shape
    let assert Ok(reencoded) = signatures.encode_library_shape(decoded)
    let assert True = reencoded == encoded
  })
}
