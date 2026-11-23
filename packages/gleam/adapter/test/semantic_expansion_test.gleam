// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/option.{None, Some}
import necoherence/exact_json as json
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import semantic_test_support as support

fn rejection(
  nodes: List(types.TypeNode),
  value: json.JsonValue,
) -> types.ValueFailure {
  let assert types.RejectedValue(failure) =
    validation.accepts_value(
      validation.prepare(support.graph(nodes)),
      support.reference("t"),
      value,
    )
  failure
}

fn shape(shape: types.TypeShape) -> List(types.TypeNode) {
  [support.node("t", shape)]
}

fn assert_condition(
  nodes: List(types.TypeNode),
  value: json.JsonValue,
  condition: types.ValueCondition,
) {
  let failure = rejection(nodes, value)
  let assert True = failure.condition == condition
  let assert True = failure.value_path == []
}

fn integer_spec() -> types.IntegerSpec {
  types.IntegerSpec(None, None, None, None, None, None)
}

pub fn boolean_shape_rejects_const_mismatch_and_wrong_kind_test() {
  let nodes = shape(types.BooleanShape(types.BooleanSpec(Some(True), None)))
  assert_condition(
    nodes,
    json.JsonValueBool(False),
    types.ConstMismatchCondition,
  )
  assert_condition(
    nodes,
    json.JsonValueNum(1),
    types.WrongValueKindCondition("boolean"),
  )
}

pub fn integer_shape_rejects_each_integer_condition_test() {
  assert_condition(
    shape(types.IntegerShape(integer_spec())),
    json.JsonValueBool(True),
    types.WrongValueKindCondition("integer"),
  )
  let profile = support.profile()
  let bounded =
    types.SemanticGraph(
      types.SemanticProfile(..profile, integer_domains: [
        types.IntegerDomainBinding(
          "integer",
          support.profile_ref(),
          types.IntegerInterval(0, 9),
          [types.Number],
        ),
      ]),
      shape(types.IntegerShape(integer_spec())),
      [support.source()],
    )
  let assert types.RejectedValue(failure) =
    validation.accepts_value(
      validation.prepare(bounded),
      support.reference("t"),
      json.JsonValueNum(10),
    )
  let assert True = failure.condition == types.IntegerDomainCondition
  assert_condition(
    shape(types.IntegerShape(
      types.IntegerSpec(..integer_spec(), const_value: Some(2)),
    )),
    json.JsonValueNum(1),
    types.ConstMismatchCondition,
  )
  assert_condition(
    shape(types.IntegerShape(
      types.IntegerSpec(..integer_spec(), enum_values: Some([2, 3])),
    )),
    json.JsonValueNum(1),
    types.EnumMismatchCondition,
  )
  assert_condition(
    shape(types.IntegerShape(
      types.IntegerSpec(..integer_spec(), minimum: Some(2)),
    )),
    json.JsonValueNum(1),
    types.BelowMinimumCondition,
  )
  assert_condition(
    shape(types.IntegerShape(
      types.IntegerSpec(..integer_spec(), maximum: Some(0)),
    )),
    json.JsonValueNum(1),
    types.AboveMaximumCondition,
  )
}

pub fn decimal_shape_rejects_wrong_kind_invalid_text_and_bounds_test() {
  let bounded =
    shape(
      types.DecimalShape(types.DecimalSpec(
        Some(types.DecimalBound(1, 0, False)),
        None,
      )),
    )
  assert_condition(
    bounded,
    json.JsonValueNum(1),
    types.WrongValueKindCondition("decimal"),
  )
  assert_condition(
    bounded,
    json.JsonValueDec("1."),
    types.InvalidDataModelCondition,
  )
  assert_condition(bounded, json.JsonValueDec("0"), types.BelowMinimumCondition)
  assert_condition(
    shape(
      types.DecimalShape(types.DecimalSpec(
        Some(types.DecimalBound(0, 0, True)),
        None,
      )),
    ),
    json.JsonValueDec("0"),
    types.BelowMinimumCondition,
  )
  assert_condition(
    shape(
      types.DecimalShape(types.DecimalSpec(
        None,
        Some(types.DecimalBound(-1, 0, False)),
      )),
    ),
    json.JsonValueDec("0"),
    types.AboveMaximumCondition,
  )
}

pub fn string_shape_rejects_each_string_condition_test() {
  let plain = support.string_spec(None)
  assert_condition(
    shape(types.StringShape(plain)),
    json.JsonValueNum(1),
    types.WrongValueKindCondition("string"),
  )
  assert_condition(
    shape(types.StringShape(types.StringSpec(..plain, const_value: Some("a")))),
    json.JsonValueStr("b"),
    types.ConstMismatchCondition,
  )
  assert_condition(
    shape(types.StringShape(types.StringSpec(..plain, enum_values: Some(["a"])))),
    json.JsonValueStr("b"),
    types.EnumMismatchCondition,
  )
  assert_condition(
    shape(types.StringShape(
      types.StringSpec(..plain, lengths: [
        types.LengthBound(types.Utf8Bytes, Some(2), None),
      ]),
    )),
    json.JsonValueStr("a"),
    types.StringLengthCondition,
  )
  assert_condition(
    shape(types.StringShape(
      types.StringSpec(..plain, format: Some(types.NamedFormat("key-x"))),
    )),
    json.JsonValueStr("y"),
    types.FormatFailureCondition("key-x"),
  )
  assert_condition(
    shape(types.StringShape(
      types.StringSpec(
        ..plain,
        format: Some(types.InlineFormat(types.Literal("x"))),
      ),
    )),
    json.JsonValueStr("y"),
    types.FormatFailureCondition("inline"),
  )
}

pub fn string_wrapper_rejects_wrong_wrapper_and_payload_test() {
  let wrapped =
    shape(types.StringShape(
      types.StringSpec(..support.string_spec(None), wrapper: Some("text")),
    ))
  assert_condition(
    wrapped,
    json.JsonValueStr("plain"),
    types.WrongValueKindCondition("string wrapper"),
  )
  assert_condition(
    wrapped,
    json.JsonValueObj([#("bytes", json.JsonValueStr("AA=="))]),
    types.WrongValueKindCondition("string wrapper"),
  )
  assert_condition(
    wrapped,
    json.JsonValueObj([#("text", json.JsonValueNum(1))]),
    types.WrongValueKindCondition("wrapper text"),
  )
}

pub fn bytes_shape_rejects_invalid_and_out_of_range_length_test() {
  let nodes = shape(types.BytesShape(types.LengthSpec(Some(2), None)))
  assert_condition(
    nodes,
    json.JsonValueObj([#("bytes", json.JsonValueStr("!"))]),
    types.InvalidBytesCondition,
  )
  assert_condition(
    nodes,
    json.JsonValueObj([#("bytes", json.JsonValueStr("AA=="))]),
    types.BytesLengthCondition,
  )
  assert_condition(
    shape(types.RawBodyShape("base64")),
    json.JsonValueStr("AA=="),
    types.InvalidBytesCondition,
  )
}

pub fn product_shape_rejects_each_member_condition_test() {
  let product =
    types.ProductShape(types.ProductSpec(
      [support.field("a", "t", True, False)],
      types.RejectExtras,
    ))
  let nodes = shape(product)
  assert_condition(
    nodes,
    json.JsonValueNum(1),
    types.WrongValueKindCondition("object"),
  )
  assert_condition(
    nodes,
    json.JsonValueObj([#("tag", json.JsonValueStr("sealed"))]),
    types.WrongValueKindCondition("plain data object"),
  )
  let failure = rejection(nodes, json.JsonValueObj([]))
  let assert True = failure.condition == types.MissingRequiredCondition
  let assert True = failure.value_path == [types.Field("a")]
  let assert True = failure.observed == types.Absent
  let failure =
    rejection(nodes, json.JsonValueObj([#("a", json.JsonValueNull)]))
  let assert True = failure.condition == types.NullNotAllowedCondition
  let assert True = failure.observed == types.Null
  let failure =
    rejection(
      shape(types.ProductShape(types.ProductSpec([], types.RejectExtras))),
      json.JsonValueObj([#("b", json.JsonValueNum(1))]),
    )
  let assert True = failure.condition == types.UnexpectedFieldCondition("b")
  let assert True = failure.value_path == [types.Field("b")]
  let keyed =
    types.ProductShape(types.ProductSpec(
      [],
      types.AllowExtras(
        Some(types.NamedFormat("key-x")),
        types.ElementContract(support.reference("t"), False),
      ),
    ))
  let failure =
    rejection(shape(keyed), json.JsonValueObj([#("y", json.JsonValueNum(1))]))
  let assert True = failure.condition == types.KeyFormatCondition("y")
  let failure =
    rejection(
      nodes,
      json.JsonValueObj([
        #("a", json.JsonValueObj([])),
        #("a", json.JsonValueObj([])),
      ]),
    )
  let assert True = failure.condition == types.DuplicateFieldCondition("a")
}

pub fn array_shape_rejects_wrong_kind_and_length_test() {
  let nodes =
    shape(
      types.ArrayShape(types.ArraySpec(
        types.ElementContract(support.reference("t"), False),
        Some(1),
        None,
      )),
    )
  assert_condition(
    nodes,
    json.JsonValueNum(1),
    types.WrongValueKindCondition("array"),
  )
  assert_condition(nodes, json.JsonValueArr([]), types.ArrayLengthCondition)
}

pub fn tagged_union_rejects_unselected_value_and_invalid_tag_test() {
  let union =
    shape(
      types.TaggedUnionShape(
        types.UnionSpec([
          types.UnionBranch(
            support.reference("t"),
            "a",
            types.Kind(types.ObjectKind),
            support.occurrence(),
          ),
        ]),
      ),
    )
  assert_condition(union, json.JsonValueNum(1), types.NoBranchSelectedCondition)
  let failure =
    rejection(union, json.JsonValueObj([#("tag", json.JsonValueNum(1))]))
  let assert True = failure.condition == types.InvalidTagCondition
  let assert True = failure.value_path == [types.Field("tag")]
}

pub fn sealed_shape_rejects_wrong_class_tag_and_leaf_test() {
  let leaf =
    types.SealedField(
      "n",
      True,
      types.SealedInteger(types.IntegerSpec(..integer_spec(), minimum: Some(5))),
    )
  let profile = support.profile()
  let assert Some(tag) = profile.tag
  let graph =
    types.SemanticGraph(
      types.SemanticProfile(
        ..profile,
        tag: Some(
          types.TagModel(tag.key, tag.format, [
            types.SealedForm("sealed", [leaf], types.SealedReject),
            types.SealedForm("other", [], types.SealedReject),
          ]),
        ),
      ),
      shape(types.SealedShape("sealed", [])),
      [support.source()],
    )
  let decide = fn(value) {
    let assert types.RejectedValue(failure) =
      validation.accepts_value(
        validation.prepare(graph),
        support.reference("t"),
        value,
      )
    failure
  }
  let failure = decide(json.JsonValueNum(1))
  let assert True =
    failure.condition == types.WrongValueKindCondition("sealed object")
  let failure =
    decide(json.JsonValueObj([#("tag", json.JsonValueStr("other"))]))
  let assert True = failure.condition == types.InvalidDataModelCondition
  let failure =
    decide(
      json.JsonValueObj([
        #("tag", json.JsonValueStr("sealed")),
        #("n", json.JsonValueNum(1)),
      ]),
    )
  let assert True = failure.condition == types.BelowMinimumCondition
  let assert True = failure.value_path == [types.Field("n")]
  let failure =
    decide(json.JsonValueObj([#("tag", json.JsonValueStr("sealed"))]))
  let assert True = failure.condition == types.MissingRequiredCondition
  let assert True = failure.observed == types.Absent
}

pub fn remaining_shapes_reject_and_leave_opaque_types_unresolved_test() {
  assert_condition(
    shape(types.Never),
    json.JsonValueNull,
    types.InvalidDataModelCondition,
  )
  assert_condition(
    shape(types.UnknownShape(types.OrdinaryObject)),
    json.JsonValueNum(1),
    types.WrongValueKindCondition("ordinary object"),
  )
  assert_condition(
    shape(types.UnknownShape(types.OrdinaryObject)),
    json.JsonValueObj([#("bytes", json.JsonValueStr("AA=="))]),
    types.WrongValueKindCondition("ordinary object"),
  )
  assert_condition(
    shape(types.UnknownShape(types.AnyValue)),
    json.JsonValueDec("1."),
    types.InvalidDataModelCondition,
  )
  assert_condition(
    shape(types.UnitShape),
    json.JsonValueNum(1),
    types.WrongValueKindCondition("unit"),
  )
  let graph = support.graph(shape(types.OpaqueShape("o")))
  let assert types.UnresolvedValue(_) =
    validation.accepts_value(
      validation.prepare(graph),
      support.reference("t"),
      json.JsonValueNull,
    )
}

pub fn expand_value_reports_unresolved_type_and_children_test() {
  let graph = support.graph([])
  let assert validation.UnresolvedExpansion([
    types.SemanticObligation(_, [], types.UnresolvedTypeReason, _, _),
  ]) =
    validation.expand_value(
      validation.prepare(graph),
      support.reference("t"),
      [],
      json.JsonValueNull,
    )
  let graph =
    support.graph(shape(types.AliasShape(support.reference("u"), "u")))
  let assert validation.Requirements([
    validation.ValueRequirement(target, [], json.JsonValueNull),
  ]) =
    validation.expand_value(
      validation.prepare(graph),
      support.reference("t"),
      [],
      json.JsonValueNull,
    )
  let assert True = target == support.reference("u")
}

pub fn stale_value_derivation_rejects_a_value_outside_the_contract_test() {
  let graph =
    support.graph(shape(types.BooleanShape(types.BooleanSpec(None, None))))
  let slot = types.SlotContract(support.reference("t"), True, False)
  let value = types.Present(json.JsonValueBool(True))
  let assert Ok(_) =
    validation.validate_slot(validation.prepare(graph), slot, value)
  let proof = validation.MemberProof([])
  let assert Error(_) =
    validation.validate_value(
      validation.prepare(graph),
      support.reference("t"),
      json.JsonValueNum(1),
      Some(proof),
    )
}

pub fn value_derivation_children_must_match_expansion_test() {
  let graph =
    support.graph(
      shape(types.AliasShape(support.reference("u"), "u"))
      |> fn(nodes) {
        [
          support.node("u", types.BooleanShape(types.BooleanSpec(None, None))),
          ..nodes
        ]
      },
    )
  let reference = support.reference("t")
  let value = json.JsonValueBool(True)
  let assert Ok(_) =
    validation.validate_value(validation.prepare(graph), reference, value, None)
  let proof = validation.MemberProof([validation.MemberProof([])])
  let assert Ok(_) =
    validation.validate_value(
      validation.prepare(graph),
      reference,
      value,
      Some(proof),
    )
  let assert Error(validation.CertificateMismatchFailure(
    "extra membership children",
  )) =
    validation.validate_value(
      validation.prepare(graph),
      reference,
      value,
      Some(validation.MemberProof([proof, proof])),
    )
  let assert Error(validation.CertificateMismatchFailure(
    "missing membership children",
  )) =
    validation.validate_value(
      validation.prepare(graph),
      reference,
      value,
      Some(validation.MemberProof([])),
    )
}

pub fn slot_validation_checks_meaning_before_presence_test() {
  let graph = support.graph(shape(types.OpaqueShape("o")))
  let slot = types.SlotContract(support.reference("t"), False, False)
  let assert Error(validation.Unresolved([_])) =
    validation.validate_slot(validation.prepare(graph), slot, types.Absent)
}

fn decimal_nodes(
  minimum: option.Option(types.DecimalBound),
  maximum: option.Option(types.DecimalBound),
) -> List(types.TypeNode) {
  shape(types.DecimalShape(types.DecimalSpec(minimum, maximum)))
}

fn decimal_decision(
  nodes: List(types.TypeNode),
  text: String,
) -> types.ValueDecision {
  validation.accepts_value(
    validation.prepare(support.graph(nodes)),
    support.reference("t"),
    json.JsonValueDec(text),
  )
}

pub fn decimal_bounds_compare_mathematical_values_test() {
  let minimum = decimal_nodes(Some(types.DecimalBound(15, 1, False)), None)
  let assert types.AcceptedValue = decimal_decision(minimum, "1.5")
  let assert types.AcceptedValue = decimal_decision(minimum, "15e-1")
  let assert types.AcceptedValue = decimal_decision(minimum, "2")
  let assert types.RejectedValue(failure) = decimal_decision(minimum, "1.49")
  let assert types.BelowMinimumCondition = failure.condition
  let exclusive = decimal_nodes(Some(types.DecimalBound(15, 1, True)), None)
  let assert types.RejectedValue(failure) = decimal_decision(exclusive, "1.5")
  let assert types.BelowMinimumCondition = failure.condition
  let assert types.AcceptedValue = decimal_decision(exclusive, "1.51")
  let tiny = decimal_nodes(Some(types.DecimalBound(1, 1, False)), None)
  let assert types.RejectedValue(failure) = decimal_decision(tiny, "0.05")
  let assert types.BelowMinimumCondition = failure.condition
  let maximum = decimal_nodes(None, Some(types.DecimalBound(100, 0, False)))
  let assert types.AcceptedValue = decimal_decision(maximum, "100")
  let assert types.AcceptedValue = decimal_decision(maximum, "1e2")
  let assert types.RejectedValue(failure) = decimal_decision(maximum, "1.01e2")
  let assert types.AboveMaximumCondition = failure.condition
  let upper = decimal_nodes(None, Some(types.DecimalBound(15, 1, True)))
  let assert types.RejectedValue(failure) = decimal_decision(upper, "1.5")
  let assert types.AboveMaximumCondition = failure.condition
}

fn sealed_graph(
  extras: types.SealedExtras,
  refinements: List(types.SealedRefinement),
) -> types.SemanticGraph {
  let profile = support.profile()
  let assert Some(tag) = profile.tag
  types.SemanticGraph(
    types.SemanticProfile(
      ..profile,
      tag: Some(
        types.TagModel(tag.key, tag.format, [
          types.SealedForm("sealed", [], extras),
        ]),
      ),
    ),
    shape(types.SealedShape("sealed", refinements)),
    [support.source()],
  )
}

fn sealed_decision(
  graph: types.SemanticGraph,
  members: List(#(String, json.JsonValue)),
) -> types.ValueDecision {
  validation.accepts_value(
    validation.prepare(graph),
    support.reference("t"),
    json.JsonValueObj([#("tag", json.JsonValueStr("sealed")), ..members]),
  )
}

pub fn sealed_members_are_checked_before_refinements_test() {
  let refinement =
    types.SealedRefinement(
      "n",
      types.SealedInteger(types.IntegerSpec(..integer_spec(), minimum: Some(5))),
    )
  let rejecting = sealed_graph(types.SealedReject, [refinement])
  let assert types.RejectedValue(failure) =
    sealed_decision(rejecting, [
      #("n", json.JsonValueNum(1)),
      #("x", json.JsonValueNum(1)),
    ])
  let assert types.UnexpectedFieldCondition("n") = failure.condition
  let assert [types.Field("n")] = failure.value_path
  let allowing = sealed_graph(types.SealedAny, [refinement])
  let assert types.RejectedValue(failure) =
    sealed_decision(allowing, [
      #("n", json.JsonValueNum(1)),
      #("x", json.JsonValueDec("1.")),
    ])
  let assert types.InvalidDataModelCondition = failure.condition
  let assert [types.Field("x")] = failure.value_path
  let assert types.RejectedValue(failure) =
    sealed_decision(allowing, [#("n", json.JsonValueNum(1))])
  let assert types.BelowMinimumCondition = failure.condition
  let assert types.AcceptedValue =
    sealed_decision(allowing, [#("n", json.JsonValueNum(5))])
}

pub fn projection_failures_follow_lean_contract_walk_test() {
  let tagged =
    types.TaggedUnionShape(
      types.UnionSpec([
        types.UnionBranch(
          support.reference("a"),
          "x",
          types.Kind(types.StringKind),
          support.occurrence(),
        ),
        types.UnionBranch(
          support.reference("a"),
          "y",
          types.InternalTag,
          support.occurrence(),
        ),
      ]),
    )
  let graph =
    support.graph([
      support.node("a", types.BooleanShape(types.BooleanSpec(None, None))),
      support.node("u", tagged),
      support.node(
        "p",
        types.ProductShape(types.ProductSpec(
          [support.field("f", "a", True, False)],
          types.RejectExtras,
        )),
      ),
      support.node("loop", types.AliasShape(support.reference("loop"), "loop")),
    ])
  let slot = fn(name) {
    types.SlotContract(support.reference(name), True, False)
  }
  let project = fn(name, path, assumptions) {
    validation.project_slot(
      validation.prepare(graph),
      slot(name),
      path,
      assumptions,
    )
  }
  let assert Ok(_) = project("p", [types.Field("f")], [])
  let assert Error(validation.MissingField(_, "g")) =
    project("p", [types.Field("g")], [])
  let assert Error(validation.WrongShape(_, [])) =
    project("p", [types.Index(0)], [])
  let assert Error(validation.BranchAssumptionRequired([], "y")) =
    project("u", [types.Variant("y")], [])
  let assert Error(validation.MissingVariant(_, "z")) =
    project("u", [types.Variant("z")], [validation.Variant([], "z")])
  let assert Error(validation.VariantSelectionUndetermined([], "x")) =
    project("u", [types.Variant("x")], [validation.Variant([], "x")])
  let assert Ok(_) =
    project("u", [types.Variant("y")], [validation.Variant([], "y")])
  let assert Error(validation.ProjectionUnresolved([
    types.SemanticObligation(_, _, types.MembershipBoundReason, _, _),
  ])) = project("loop", [types.Field("f")], [])
}

pub fn value_paths_project_through_tagged_objects_test() {
  let profile = support.profile()
  let value =
    json.JsonValueObj([
      #("tag", json.JsonValueStr("x")),
      #("list", json.JsonValueArr([json.JsonValueNull])),
    ])
  let assert types.Present(_) = validation.value_at_path(profile, value, [])
  let assert types.Present(_) =
    validation.value_at_path(profile, value, [types.Variant("x")])
  let assert types.Absent =
    validation.value_at_path(profile, value, [types.Variant("y")])
  let assert types.Null =
    validation.value_at_path(profile, value, [
      types.Field("list"),
      types.Index(0),
    ])
  let assert types.Absent =
    validation.value_at_path(profile, value, [
      types.Field("list"),
      types.Index(1),
    ])
  let assert types.Absent =
    validation.value_at_path(profile, value, [types.Field("none")])
  let assert types.Null =
    validation.projected_value(profile, types.Null, [types.Field("f")])
}

pub fn language_tag_grandfathered_entries_compare_without_case_test() {
  let accepts = fn(entries, text) {
    validation.recognizes(None, types.LanguageTag(entries), text)
  }
  let assert True = accepts(["en-GB-oed"], "en-GB-oed")
  let assert True = accepts(["en-GB-oed"], "en-gb-oed")
  let assert True = accepts(["en-GB-oed"], "EN-GB-OED")
  let assert False = accepts([], "en-GB-oed")
  let assert True = accepts([], "en-GB")
  let assert True = accepts(["en-GB-oed"], "de-DE")
  let assert False = accepts(["en-GB-oed"], "en-GB-oe")
  let assert False = accepts(["en-GB-oed"], "1")
  let assert False = accepts(["en-GB-oed"], "")
  let assert False = accepts([], "")
  let assert True = accepts([""], "")
}

pub fn language_tag_region_follows_the_script_test() {
  let accepts = fn(text) {
    validation.recognizes(None, types.LanguageTag([]), text)
  }
  let assert True = accepts("sr-Latn-RS")
  let assert False = accepts("sr-RS-Latn")
}
