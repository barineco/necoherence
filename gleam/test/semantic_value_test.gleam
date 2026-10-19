// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import necoherence/exact_json as json
import necoherence/semantic_generation_decode as wire
import necoherence/semantic_generation_runtime as runtime
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation

fn reference() -> types.ProfileRef {
  types.ProfileRef("profile", "4", "digest")
}

fn type_reference(name: String) -> types.TypeRef {
  types.TypeRef(
    types.SourceRef(
      "repository",
      "revision",
      "path",
      "digest",
      "document",
      None,
    ),
    name,
    [],
  )
}

fn occurrence() -> types.OccurrenceRef {
  let types.TypeRef(source, _, _) = type_reference("")
  types.OccurrenceRef(source, [])
}

fn profile(
  wrappers: List(types.Wrapper),
  tag: types.TagModel,
) -> types.SemanticProfile {
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
    wrappers,
    Some(tag),
  )
}

pub fn sequence_with_optional_prefix_accepts_empty_left_test() {
  let rule =
    types.Sequence([
      types.Optional(types.Literal("a")),
      types.Literal("b"),
    ])
  let assert True = validation.recognizes(rule, "b")
  let assert True = validation.recognizes(types.Text, "anything")
  let assert True = validation.recognizes(types.Not(types.Literal("x")), "y")
}

pub fn profile_failure_preserves_pr01_and_location_test() {
  let invalid =
    types.SemanticProfile(
      types.ProfileRef("", "4", "digest"),
      [],
      [],
      "",
      types.NumberModel(False),
      None,
      [],
      None,
      [],
      None,
    )
  let assert Error(types.ProfileFailure(_, types.Pr01, ["profile"])) =
    validation.check_profile(invalid)
}

pub fn runtime_classifies_sealed_before_wrapper_test() {
  let wrapper = types.Wrapper("text", "wrapped", types.WrapperText(None))
  let sealed = types.SealedForm("sealed", [], types.SealedAny)
  let semantic_profile =
    profile([wrapper], types.TagModel("kind", None, [sealed]))
  let value =
    json.JsonValueObj([
      #("kind", json.JsonValueStr("sealed")),
      #("wrapped", json.JsonValueStr("payload")),
    ])
  let assert types.SealedObject(observed) =
    runtime.class_of(semantic_profile, value)
  let assert True = observed == sealed
}

pub fn runtime_wrapper_and_branch_operations_roundtrip_test() {
  let wrapper = types.Wrapper("text", "wrapped", types.WrapperText(None))
  let semantic_profile = profile([wrapper], types.TagModel("kind", None, []))
  let payload = json.JsonValueStr("value")
  let assert Ok(encoded) =
    runtime.wrap_encode(semantic_profile, "text", payload)
  let assert Ok(decoded) =
    runtime.wrap_decode(semantic_profile, "text", encoded)
  let assert True = decoded == payload
  let assert Ok(tagged) =
    runtime.with_member("kind", "a", json.JsonValueObj([]))
  let assert Ok(0) =
    runtime.select_branch(
      semantic_profile,
      [#("a", types.InternalTag), #("", types.Otherwise)],
      tagged,
    )
}

fn named_node(name: String, shape: types.TypeShape) -> types.TypeNode {
  types.TypeNode(type_reference(name), shape, None, [], [])
}

fn declared_node(shape: types.TypeShape) -> types.TypeNode {
  named_node("subject", shape)
}

fn assert_meaning_failure(
  semantic_profile: types.SemanticProfile,
  shape: types.TypeShape,
  predicate: types.MeaningObligation,
) {
  let graph = types.SemanticGraph(semantic_profile, [declared_node(shape)], [])
  let assert Error(types.MeaningFailure(_, observed, [])) =
    validation.check_meaning_defined(graph, [type_reference("subject")])
  let assert True = observed == predicate
}

fn empty_string_spec() -> types.StringSpec {
  types.StringSpec(None, [], None, None, None, [], None)
}

pub fn meaning_obligations_preserve_mo01_through_mo11_test() {
  let base = profile([], types.TagModel("kind", None, []))
  assert_meaning_failure(
    base,
    types.StringShape(types.StringSpec(
      Some(types.NamedFormat("missing")),
      [],
      None,
      None,
      None,
      [],
      None,
    )),
    types.Mo01,
  )
  assert_meaning_failure(
    base,
    types.StringShape(types.StringSpec(
      None,
      [types.LengthBound(types.Graphemes, None, None)],
      None,
      None,
      None,
      [],
      None,
    )),
    types.Mo02,
  )
  assert_meaning_failure(
    base,
    types.BytesShape(types.LengthSpec(None, None)),
    types.Mo03,
  )
  assert_meaning_failure(
    base,
    types.IntegerShape(types.IntegerSpec(
      Some("missing"),
      None,
      None,
      None,
      None,
      None,
    )),
    types.Mo04,
  )
  assert_meaning_failure(
    base,
    types.StringShape(types.StringSpec(
      None,
      [],
      Some("missing"),
      None,
      None,
      [],
      None,
    )),
    types.Mo05,
  )
  let bytes_wrapper =
    types.SemanticProfile(..base, wrappers: [
      types.Wrapper("bytes", "wrapped", types.WrapperBytes),
    ])
  assert_meaning_failure(
    bytes_wrapper,
    types.StringShape(types.StringSpec(
      None,
      [],
      Some("bytes"),
      None,
      None,
      [],
      None,
    )),
    types.Mo06,
  )
  assert_meaning_failure(base, types.SealedShape("missing", []), types.Mo07)
  assert_meaning_failure(
    types.SemanticProfile(..base, numbers: types.NumberModel(False)),
    types.DecimalShape(types.DecimalSpec(None, None)),
    types.Mo08,
  )
  let bounded =
    types.SemanticProfile(..base, integer_domains: [
      types.IntegerDomainBinding(
        "integer",
        reference(),
        types.IntegerInterval(0, 10),
        [types.Number],
      ),
    ])
  assert_meaning_failure(
    bounded,
    types.IntegerShape(types.IntegerSpec(None, Some(-1), None, None, None, None)),
    types.Mo09,
  )
  assert_meaning_failure(base, types.OpaqueShape("opaque"), types.Mo10)
  let no_tag = types.SemanticProfile(..base, tag: None)
  assert_meaning_failure(
    no_tag,
    types.TaggedUnionShape(
      types.UnionSpec([
        types.UnionBranch(
          type_reference("subject"),
          "tag",
          types.InternalTag,
          occurrence(),
        ),
      ]),
    ),
    types.Mo11,
  )
  let graph =
    types.SemanticGraph(
      base,
      [declared_node(types.StringShape(empty_string_spec()))],
      [],
    )
  let assert Ok(Nil) =
    validation.check_meaning_defined(graph, [type_reference("subject")])
}

fn decision(
  semantic_profile: types.SemanticProfile,
  nodes: List(types.TypeNode),
  name: String,
  value: json.JsonValue,
) -> types.ValueDecision {
  validation.declared_value_decision(
    types.SemanticGraph(semantic_profile, nodes, []),
    type_reference(name),
    value,
  )
}

pub fn value_decision_uses_integer_forms_and_domains_test() {
  let semantic_profile =
    types.SemanticProfile(
      ..profile([], types.TagModel("kind", None, [])),
      integer_domains: [
        types.IntegerDomainBinding(
          "integer",
          reference(),
          types.IntegerInterval(-10, 10),
          [types.Number, types.IntegralDecimal, types.DecimalString],
        ),
      ],
    )
  let node =
    declared_node(
      types.IntegerShape(types.IntegerSpec(None, None, None, None, None, None)),
    )
  let assert types.AcceptedValue =
    decision(semantic_profile, [node], "subject", json.JsonValueNum(1))
  let assert types.AcceptedValue =
    decision(semantic_profile, [node], "subject", json.JsonValueDec("1.0"))
  let assert types.AcceptedValue =
    decision(semantic_profile, [node], "subject", json.JsonValueStr("1"))
  let assert types.RejectedValue(types.ValueFailure(
    _,
    _,
    _,
    [],
    types.IntegerDomainCondition,
    _,
    _,
  )) = decision(semantic_profile, [node], "subject", json.JsonValueNum(11))
}

pub fn value_decision_accepts_integral_exponent_number_test() {
  let semantic_profile =
    types.SemanticProfile(
      ..profile([], types.TagModel("kind", None, [])),
      integer_domains: [
        types.IntegerDomainBinding("integer", reference(), types.Unbounded, [
          types.Number,
          types.IntegralDecimal,
        ]),
      ],
    )
  let node =
    declared_node(
      types.IntegerShape(types.IntegerSpec(None, None, None, None, None, None)),
    )
  let assert types.AcceptedValue =
    decision(semantic_profile, [node], "subject", json.JsonValueDec("1e+18"))
  let assert types.RejectedValue(types.ValueFailure(
    _,
    _,
    _,
    [],
    types.WrongValueKindCondition("integer"),
    _,
    _,
  )) = decision(semantic_profile, [node], "subject", json.JsonValueDec("1e-1"))
}

pub fn value_decision_preserves_wrapper_sealed_union_and_never_test() {
  let wrapper = types.Wrapper("text", "wrapped", types.WrapperText(None))
  let sealed_form =
    types.SealedForm(
      "sealed",
      [
        types.SealedField("name", True, types.SealedString(empty_string_spec())),
      ],
      types.SealedReject,
    )
  let semantic_profile =
    profile([wrapper], types.TagModel("kind", None, [sealed_form]))
  let wrapper_node =
    declared_node(
      types.StringShape(types.StringSpec(
        None,
        [],
        Some("text"),
        None,
        None,
        [],
        None,
      )),
    )
  let assert types.AcceptedValue =
    decision(
      semantic_profile,
      [wrapper_node],
      "subject",
      json.JsonValueObj([#("wrapped", json.JsonValueStr("value"))]),
    )
  let sealed_node = declared_node(types.SealedShape("sealed", []))
  let assert types.AcceptedValue =
    decision(
      semantic_profile,
      [sealed_node],
      "subject",
      json.JsonValueObj([
        #("kind", json.JsonValueStr("sealed")),
        #("name", json.JsonValueStr("value")),
      ]),
    )
  let target =
    types.TypeNode(
      type_reference("target"),
      types.StringShape(empty_string_spec()),
      None,
      [],
      [],
    )
  let union =
    declared_node(
      types.TaggedUnionShape(
        types.UnionSpec([
          types.UnionBranch(
            type_reference("target"),
            "text",
            types.Kind(types.StringKind),
            occurrence(),
          ),
        ]),
      ),
    )
  let assert types.AcceptedValue =
    decision(
      semantic_profile,
      [union, target],
      "subject",
      json.JsonValueStr("value"),
    )
  let never_node = declared_node(types.Never)
  let assert types.RejectedValue(types.ValueFailure(
    _,
    _,
    _,
    [],
    types.InvalidDataModelCondition,
    _,
    _,
  )) = decision(semantic_profile, [never_node], "subject", json.JsonValueNull)
}

pub fn value_decision_preserves_decimal_and_product_extras_test() {
  let semantic_profile = profile([], types.TagModel("kind", None, []))
  let decimal_node =
    declared_node(types.DecimalShape(types.DecimalSpec(None, None)))
  let assert types.AcceptedValue =
    decision(
      semantic_profile,
      [decimal_node],
      "subject",
      json.JsonValueDec("1.25"),
    )
  let product_node =
    declared_node(types.ProductShape(types.ProductSpec([], types.RejectExtras)))
  let assert types.RejectedValue(types.ValueFailure(
    _,
    _,
    _,
    [types.Field("extra")],
    types.UnexpectedFieldCondition("extra"),
    _,
    _,
  )) =
    decision(
      semantic_profile,
      [product_node],
      "subject",
      json.JsonValueObj([#("extra", json.JsonValueBool(True))]),
    )
}

pub fn nullable_string_array_accepts_null_item_test() {
  let semantic_profile = profile([], types.TagModel("kind", None, []))
  let nodes = [
    named_node("string", types.StringShape(empty_string_spec())),
    declared_node(
      types.ArrayShape(types.ArraySpec(
        types.ElementContract(type_reference("string"), True),
        None,
        None,
      )),
    ),
  ]
  let assert types.AcceptedValue =
    decision(
      semantic_profile,
      nodes,
      "subject",
      json.JsonValueArr([json.JsonValueNull]),
    )
}

pub fn nonnullable_string_array_rejects_null_item_test() {
  let semantic_profile = profile([], types.TagModel("kind", None, []))
  let nodes = [
    named_node("string", types.StringShape(empty_string_spec())),
    declared_node(
      types.ArrayShape(types.ArraySpec(
        types.ElementContract(type_reference("string"), False),
        None,
        None,
      )),
    ),
  ]
  let assert types.RejectedValue(_) =
    decision(
      semantic_profile,
      nodes,
      "subject",
      json.JsonValueArr([json.JsonValueNull]),
    )
}

pub fn nonnullable_any_elements_accept_null_in_array_and_map_test() {
  let semantic_profile = profile([], types.TagModel("kind", None, []))
  let any = named_node("any", types.UnknownShape(types.AnyValue))
  let array =
    declared_node(
      types.ArrayShape(types.ArraySpec(
        types.ElementContract(type_reference("any"), False),
        None,
        None,
      )),
    )
  let assert types.AcceptedValue =
    decision(
      semantic_profile,
      [array, any],
      "subject",
      json.JsonValueArr([json.JsonValueNull]),
    )
  let product =
    declared_node(
      types.ProductShape(types.ProductSpec(
        [],
        types.AllowExtras(
          None,
          types.ElementContract(type_reference("any"), False),
        ),
      )),
    )
  let assert types.AcceptedValue =
    decision(
      semantic_profile,
      [product, any],
      "subject",
      json.JsonValueObj([#("value", json.JsonValueNull)]),
    )
}

pub fn general_decimal_data_prioritizes_integral_decimal_test() {
  let base = profile([], types.TagModel("kind", None, []))
  let number_only =
    types.SemanticProfile(..base, integer_domains: [
      types.IntegerDomainBinding(
        "integer",
        reference(),
        types.IntegerInterval(-10, 10),
        [
          types.Number,
        ],
      ),
    ])
  let any = named_node("any", types.UnknownShape(types.AnyValue))
  let array =
    declared_node(
      types.ArrayShape(types.ArraySpec(
        types.ElementContract(type_reference("any"), False),
        None,
        None,
      )),
    )
  let product =
    declared_node(
      types.ProductShape(types.ProductSpec(
        [],
        types.AllowExtras(
          None,
          types.ElementContract(type_reference("any"), False),
        ),
      )),
    )
  let assert types.AcceptedValue =
    decision(number_only, [any], "any", json.JsonValueDec("-1.25"))
  let assert types.AcceptedValue =
    decision(
      number_only,
      [array, any],
      "subject",
      json.JsonValueArr([
        json.JsonValueDec("6.02e23"),
      ]),
    )
  let assert types.AcceptedValue =
    decision(
      number_only,
      [product, any],
      "subject",
      json.JsonValueObj([
        #("nested", json.JsonValueArr([json.JsonValueDec("-1.25")])),
      ]),
    )
  let assert types.AcceptedValue =
    decision(number_only, [any], "any", json.JsonValueDec("11.0"))
  let priority =
    types.SemanticProfile(..base, integer_domains: [
      types.IntegerDomainBinding(
        "integer",
        reference(),
        types.IntegerInterval(-10, 10),
        [
          types.Number,
          types.IntegralDecimal,
        ],
      ),
    ])
  let assert types.AcceptedValue =
    decision(priority, [any], "any", json.JsonValueDec("1.0"))
  let assert types.AcceptedValue =
    decision(priority, [any], "any", json.JsonValueDec("1.25"))
  let assert types.RejectedValue(failure) =
    decision(priority, [any], "any", json.JsonValueDec("11.0"))
  let assert types.IntegerDomainCondition = failure.condition
  let assert types.RejectedValue(failure) =
    decision(priority, [any], "any", json.JsonValueDec("1e999999"))
  let assert types.IntegerDomainCondition = failure.condition
  let disabled =
    types.SemanticProfile(..priority, numbers: types.NumberModel(False))
  let assert types.AcceptedValue =
    decision(disabled, [any], "any", json.JsonValueDec("1.0"))
  let assert types.RejectedValue(failure) =
    decision(disabled, [any], "any", json.JsonValueDec("11.0"))
  let assert types.IntegerDomainCondition = failure.condition
  let assert types.RejectedValue(failure) =
    decision(disabled, [any], "any", json.JsonValueDec("1.25"))
  let assert types.InvalidDataModelCondition = failure.condition
  let unbounded =
    types.SemanticProfile(..priority, integer_domains: [
      types.IntegerDomainBinding("integer", reference(), types.Unbounded, [
        types.Number,
        types.IntegralDecimal,
      ]),
    ])
  let assert types.AcceptedValue =
    decision(unbounded, [any], "any", json.JsonValueDec("1e999999"))
  let assert types.RejectedValue(failure) =
    decision(number_only, [any], "any", json.JsonValueDec("1."))
  let assert types.InvalidDataModelCondition = failure.condition
}

pub fn nonnullable_integer_map_rejects_null_value_test() {
  let semantic_profile = profile([], types.TagModel("kind", None, []))
  let integer =
    named_node(
      "integer",
      types.IntegerShape(types.IntegerSpec(None, None, None, None, None, None)),
    )
  let product =
    declared_node(
      types.ProductShape(types.ProductSpec(
        [],
        types.AllowExtras(
          None,
          types.ElementContract(type_reference("integer"), False),
        ),
      )),
    )
  let assert types.RejectedValue(_) =
    decision(
      semantic_profile,
      [product, integer],
      "subject",
      json.JsonValueObj([#("value", json.JsonValueNull)]),
    )
}

pub fn element_child_failures_preserve_parent_reference_trace_test() {
  let semantic_profile = profile([], types.TagModel("kind", None, []))
  let integer =
    named_node(
      "integer",
      types.IntegerShape(types.IntegerSpec(None, None, None, None, None, None)),
    )
  let array =
    declared_node(
      types.ArrayShape(types.ArraySpec(
        types.ElementContract(type_reference("integer"), False),
        None,
        None,
      )),
    )
  let assert types.RejectedValue(types.ValueFailure(
    _,
    _,
    _,
    _,
    types.WrongValueKindCondition("integer"),
    _,
    array_trace,
  )) =
    decision(
      semantic_profile,
      [array, integer],
      "subject",
      json.JsonValueArr([json.JsonValueNull]),
    )
  let assert [array_outer] = array_trace
  let assert True = array_outer == type_reference("subject")
  let product =
    declared_node(
      types.ProductShape(types.ProductSpec(
        [],
        types.AllowExtras(
          None,
          types.ElementContract(type_reference("integer"), False),
        ),
      )),
    )
  let assert types.RejectedValue(types.ValueFailure(
    _,
    _,
    _,
    _,
    types.WrongValueKindCondition("integer"),
    _,
    map_trace,
  )) =
    decision(
      semantic_profile,
      [product, integer],
      "subject",
      json.JsonValueObj([#("value", json.JsonValueNull)]),
    )
  let assert [map_outer] = map_trace
  let assert True = map_outer == type_reference("subject")
}

pub fn value_decision_rejects_tag_outside_declared_format_test() {
  let semantic_profile =
    types.SemanticProfile(
      ..profile([], types.TagModel("kind", Some("tag-format"), [])),
      format_bindings: [
        types.FormatBinding(
          "tag-format",
          reference(),
          types.Not(types.Literal("")),
        ),
      ],
    )
  let node = declared_node(types.UnknownShape(types.OrdinaryObject))
  let assert types.RejectedValue(types.ValueFailure(
    _,
    _,
    _,
    [types.Field("kind")],
    types.InvalidTagCondition,
    _,
    _,
  )) =
    decision(
      semantic_profile,
      [node],
      "subject",
      json.JsonValueObj([#("kind", json.JsonValueStr(""))]),
    )
  let assert types.RejectedValue(types.ValueFailure(
    _,
    _,
    _,
    [types.Field("kind")],
    types.InvalidTagCondition,
    _,
    _,
  )) =
    decision(
      semantic_profile,
      [node],
      "subject",
      json.JsonValueObj([#("kind", json.JsonValueNum(1))]),
    )
}

pub fn profile_canonical_codec_preserves_both_roundtrip_identities_test() {
  let value =
    types.SemanticProfile(
      ..profile(
        [types.Wrapper("text", "wrapped", types.WrapperText(None))],
        types.TagModel("kind", None, []),
      ),
      integer_domains: [
        types.IntegerDomainBinding(
          "integer",
          reference(),
          types.IntegerInterval(-10, 10),
          [types.Number, types.IntegralDecimal, types.DecimalString],
        ),
      ],
      bytes_policy: Some(types.BytesPolicy(
        reference(),
        True,
        types.Either,
        True,
        None,
      )),
    )
  let assert Ok(encoded) = wire.encode_semantic_profile(value)
  let assert Ok(decoded) = wire.decode_semantic_profile(encoded)
  let assert True = decoded == value
  let assert Ok(reencoded) = wire.encode_semantic_profile(decoded)
  let assert True = reencoded == encoded
}

pub fn checked_profile_decoder_preserves_pr01_and_rejects_old_keys_test() {
  let invalid =
    types.SemanticProfile(
      ..profile([], types.TagModel("kind", None, [])),
      reference: types.ProfileRef("", "4", "digest"),
    )
  let assert Ok(encoded) = wire.encode_semantic_profile(invalid)
  let assert Error(wire.ProfileFailure(types.ProfileFailure(
    _,
    types.Pr01,
    ["profile"],
  ))) = wire.decode_checked_semantic_profile(encoded)
  let assert json.JsonValueObj(members) = encoded
  let old =
    json.JsonValueObj([#("representation", json.JsonValueNull), ..members])
  let assert Error(wire.UnknownField([], "representation")) =
    wire.decode_semantic_profile(old)
}

pub fn value_condition_canonical_codec_preserves_all_variants_test() {
  let values = [
    types.MissingRequiredCondition,
    types.NullNotAllowedCondition,
    types.WrongValueKindCondition("string"),
    types.ConstMismatchCondition,
    types.EnumMismatchCondition,
    types.BelowMinimumCondition,
    types.AboveMaximumCondition,
    types.IntegerDomainCondition,
    types.StringLengthCondition,
    types.ArrayLengthCondition,
    types.BytesLengthCondition,
    types.FormatFailureCondition("format"),
    types.InvalidBytesCondition,
    types.InvalidWrapperCondition("wrapper"),
    types.InvalidTagCondition,
    types.ReservedFormCondition,
    types.NoBranchSelectedCondition,
    types.KeyFormatCondition("key"),
    types.UninhabitedCondition,
    types.DuplicateFieldCondition("duplicate"),
    types.UnexpectedFieldCondition("unexpected"),
    types.InvalidDataModelCondition,
    types.ReferenceCycleCondition,
  ]
  list.each(values, fn(value) {
    let assert Ok(encoded) = wire.encode_value_condition(value)
    let assert Ok(decoded) = wire.decode_value_condition(encoded)
    let assert True = decoded == value
    let assert Ok(reencoded) = wire.encode_value_condition(decoded)
    let assert True = reencoded == encoded
  })
}

pub fn value_condition_canonical_decoder_rejects_removed_tags_test() {
  list.each(
    [
      "InvalidCid",
      "InvalidBlob",
      "GraphemeLength",
      "RecordKey",
      "MissingDiscriminator",
      "InvalidDiscriminator",
      "UnknownClosedVariant",
    ],
    fn(tag) {
      let assert Error(_) =
        wire.decode_value_condition(
          json.JsonValueObj([
            #("tag", json.JsonValueStr(tag)),
          ]),
        )
    },
  )
}

fn recursive_product(fields: List(#(String, String))) -> types.TypeShape {
  types.ProductShape(types.ProductSpec(
    list.map(fields, fn(field) {
      types.FieldSpec(
        field.0,
        types.SlotContract(type_reference(field.1), True, False),
        occurrence(),
      )
    }),
    types.RejectExtras,
  ))
}

fn recursive_union(branches: List(#(String, String))) -> types.TypeShape {
  types.TaggedUnionShape(
    types.UnionSpec(
      list.map(branches, fn(branch) {
        types.UnionBranch(
          type_reference(branch.1),
          branch.0,
          types.InternalTag,
          occurrence(),
        )
      }),
    ),
  )
}

fn recursive_array(target: String) -> types.TypeShape {
  types.ArrayShape(types.ArraySpec(
    types.ElementContract(type_reference(target), False),
    None,
    None,
  ))
}

pub fn finite_recursive_leaf_not_and_or_test() {
  let nodes = [
    named_node(
      "Goal",
      recursive_union([
        #("leaf", "leaf"),
        #("not", "not"),
        #("and", "and"),
        #("or", "or"),
      ]),
    ),
    named_node("leaf", recursive_product([])),
    named_node("not", recursive_product([#("goal", "Goal")])),
    named_node("and", recursive_product([#("goals", "Goals")])),
    named_node("or", recursive_product([#("goals", "Goals")])),
    named_node("Goals", recursive_array("Goal")),
  ]
  let leaf = json.JsonValueObj([#("kind", json.JsonValueStr("leaf"))])
  let negated =
    json.JsonValueObj([#("kind", json.JsonValueStr("not")), #("goal", leaf)])
  let twice =
    json.JsonValueObj([#("kind", json.JsonValueStr("not")), #("goal", negated)])
  let conjunction =
    json.JsonValueObj([
      #("kind", json.JsonValueStr("and")),
      #("goals", json.JsonValueArr([leaf, negated])),
    ])
  let disjunction =
    json.JsonValueObj([
      #("kind", json.JsonValueStr("or")),
      #("goals", json.JsonValueArr([twice, leaf])),
    ])
  list.each([leaf, negated, conjunction, disjunction], fn(value) {
    let assert types.AcceptedValue =
      decision(
        profile([], types.TagModel("kind", None, [])),
        nodes,
        "Goal",
        value,
      )
  })
}

fn nested_array(depth: Int) -> json.JsonValue {
  case depth {
    0 -> json.JsonValueArr([])
    _ -> json.JsonValueArr([nested_array(depth - 1), json.JsonValueArr([])])
  }
}

pub fn recursive_array_deeper_than_node_count_and_extras_test() {
  let base = profile([], types.TagModel("kind", None, []))
  let assert types.AcceptedValue =
    decision(
      base,
      [named_node("Array", recursive_array("Array"))],
      "Array",
      nested_array(32),
    )
  let map =
    named_node(
      "Map",
      types.ProductShape(types.ProductSpec(
        [],
        types.AllowExtras(
          None,
          types.ElementContract(type_reference("Map"), False),
        ),
      )),
    )
  let value =
    json.JsonValueObj([
      #("child", json.JsonValueObj([#("child", json.JsonValueObj([]))])),
      #("sibling", json.JsonValueObj([])),
    ])
  let assert types.AcceptedValue = decision(base, [map], "Map", value)
}

pub fn reference_cycles_preserve_failure_fields_test() {
  let base = profile([], types.TagModel("kind", None, []))
  let a = type_reference("A")
  let b = type_reference("B")
  let u = type_reference("U")
  let cases = [
    #([named_node("A", types.AliasShape(a, "A"))], [a], []),
    #(
      [
        named_node("A", types.AliasShape(b, "B")),
        named_node("B", types.AliasShape(a, "A")),
      ],
      [a, b],
      [],
    ),
    #([named_node("A", recursive_union([#("loop", "A")]))], [a], []),
    #(
      [
        named_node("A", types.AliasShape(u, "U")),
        named_node("U", recursive_union([#("loop", "A")])),
      ],
      [a, u],
      [],
    ),
  ]
  let observed = json.JsonValueObj([#("kind", json.JsonValueStr("loop"))])
  list.each(cases, fn(test_case) {
    list.each([False, True], fn(child) {
      let nodes = [
        named_node("Parent", recursive_product([#("child", "A")])),
        ..test_case.0
      ]
      let #(root, value, path, trace) = case child {
        True -> #(
          "Parent",
          json.JsonValueObj([#("child", observed)]),
          [types.Field("child"), ..test_case.2],
          [type_reference("Parent"), ..test_case.1],
        )
        False -> #("A", observed, test_case.2, test_case.1)
      }
      let assert types.RejectedValue(failure) =
        decision(base, nodes, root, value)
      let assert True = failure.type_ref == a
      let assert True = failure.condition == types.ReferenceCycleCondition
      let assert True = failure.value_path == path
      let assert True = failure.observed == types.Present(observed)
      let assert True = failure.reference_trace == trace
    })
  })
}

pub fn defaults_preserve_order_alias_provenance_and_idempotence_test() {
  let primitive =
    named_node("flag", types.BooleanShape(types.BooleanSpec(None, Some(False))))
  let alias =
    named_node("alias", types.AliasShape(type_reference("flag"), "flag"))
  let product =
    named_node(
      "object",
      types.ProductShape(types.ProductSpec(
        [
          types.FieldSpec(
            "flag",
            types.SlotContract(type_reference("alias"), True, False),
            occurrence(),
          ),
        ],
        types.RejectExtras,
      )),
    )
  let graph =
    types.SemanticGraph(
      profile([], types.TagModel("kind", None, [])),
      [primitive, alias, product],
      [],
    )
  let before = json.JsonValueObj([])
  let assert Ok(defaulted) =
    validation.materialize_defaults(graph, type_reference("object"), before)
  let after = validation.defaulted_value(defaulted)
  let assert True =
    after == json.JsonValueObj([#("flag", json.JsonValueBool(False))])
  let assert [application] = validation.defaulted_value_applications(defaulted)
  let assert True = application.type_ref == type_reference("flag")
  let assert True =
    application.origin == types.occurrence_at(type_reference("flag"), "default")
  let assert True = application.value_path == [types.Field("flag")]
  let assert Ok(second) =
    validation.materialize_defaults(graph, type_reference("object"), after)
  let assert True = validation.defaulted_value(second) == after
  let assert True = validation.defaulted_value_applications(second) == []
  let forged =
    validation.DefaultApplication(
      ..application,
      value: json.JsonValueBool(True),
    )
  let assert False =
    validation.check_default_applications(graph, before, after, [forged])
  let assert False =
    validation.check_default_applications(graph, json.JsonValueNull, after, [
      application,
    ])
}

pub fn invalid_default_is_checked_at_resolved_primitive_root_test() {
  let primitive =
    named_node(
      "number",
      types.IntegerShape(types.IntegerSpec(
        None,
        Some(1),
        None,
        None,
        None,
        Some(0),
      )),
    )
  let alias =
    named_node("alias", types.AliasShape(type_reference("number"), "number"))
  let product =
    named_node(
      "object",
      types.ProductShape(types.ProductSpec(
        [
          types.FieldSpec(
            "number",
            types.SlotContract(type_reference("alias"), True, False),
            occurrence(),
          ),
        ],
        types.RejectExtras,
      )),
    )
  let graph =
    types.SemanticGraph(
      profile([], types.TagModel("kind", None, [])),
      [primitive, alias, product],
      [],
    )
  let assert Error(validation.Rejected(failure)) =
    validation.materialize_defaults(
      graph,
      type_reference("object"),
      json.JsonValueObj([]),
    )
  let assert True = failure.type_ref == type_reference("number")
  let assert True = failure.value_path == []
  let assert True = failure.condition == types.BelowMinimumCondition
}

pub fn default_alias_cycle_exhausts_lean_fuel_test() {
  let graph =
    types.SemanticGraph(
      profile([], types.TagModel("kind", None, [])),
      [
        named_node("cycle", types.AliasShape(type_reference("cycle"), "cycle")),
      ],
      [],
    )
  let assert Error(validation.Unresolved([
    types.SemanticObligation(reference, [], types.MembershipBoundReason),
  ])) =
    validation.materialize_defaults(
      graph,
      type_reference("cycle"),
      json.JsonValueBool(False),
    )
  let assert True = reference == type_reference("cycle")
}

pub fn materialization_checks_reachable_meaning_at_primitive_and_final_root_test() {
  let base = profile([], types.TagModel("kind", None, []))
  let root =
    named_node(
      "root",
      types.ProductShape(types.ProductSpec(
        [
          types.FieldSpec(
            "optional",
            types.SlotContract(type_reference("gone"), False, False),
            occurrence(),
          ),
        ],
        types.RejectExtras,
      )),
    )
  let assert Error(validation.Unresolved([
    types.SemanticObligation(gone, [], types.UnresolvedTypeReason),
  ])) =
    validation.materialize_defaults(
      types.SemanticGraph(base, [root], []),
      type_reference("root"),
      json.JsonValueObj([]),
    )
  let assert True = gone == type_reference("gone")
  let text =
    named_node(
      "text",
      types.StringShape(types.StringSpec(
        Some(types.NamedFormat("missing-format")),
        [],
        None,
        None,
        None,
        [],
        Some(""),
      )),
    )
  let product =
    named_node(
      "root",
      types.ProductShape(types.ProductSpec(
        [
          types.FieldSpec(
            "label",
            types.SlotContract(type_reference("text"), True, False),
            occurrence(),
          ),
        ],
        types.RejectExtras,
      )),
    )
  let graph = types.SemanticGraph(base, [text, product], [])
  list.each(
    [
      #(type_reference("root"), json.JsonValueObj([])),
      #(type_reference("text"), json.JsonValueStr("")),
    ],
    fn(input) {
      let assert Error(validation.Unresolved([
        types.SemanticObligation(
          reference,
          [],
          types.UnknownFormatReason("missing-format"),
        ),
      ])) = validation.materialize_defaults(graph, input.0, input.1)
      let assert True = reference == type_reference("text")
    },
  )
}

pub fn unknown_nested_wrappers_preserve_payload_condition_and_path_test() {
  let semantic_profile =
    types.SemanticProfile(
      ..profile(
        [types.Wrapper("text", "text", types.WrapperText(Some("literal")))],
        types.TagModel("kind", None, []),
      ),
      format_bindings: [
        types.FormatBinding("literal", reference(), types.Literal("accepted")),
      ],
    )
  let any = declared_node(types.UnknownShape(types.AnyValue))
  let wrapped = json.JsonValueObj([#("text", json.JsonValueStr("wrong"))])
  let value = json.JsonValueObj([#("items", json.JsonValueArr([wrapped]))])
  let assert types.RejectedValue(failure) =
    decision(semantic_profile, [any], "subject", value)
  let assert types.FormatFailureCondition("literal") = failure.condition
  let assert [types.Field("items"), types.Index(0)] = failure.value_path
  let assert True = failure.observed == types.Present(wrapped)
  let ordinary = declared_node(types.UnknownShape(types.OrdinaryObject))
  let assert types.RejectedValue(failure) =
    decision(semantic_profile, [ordinary], "subject", value)
  let assert types.FormatFailureCondition("literal") = failure.condition
  let assert [types.Field("items"), types.Index(0)] = failure.value_path
  let assert types.RejectedValue(failure) =
    decision(semantic_profile, [ordinary], "subject", wrapped)
  let assert types.WrongValueKindCondition("ordinary object") =
    failure.condition
}

pub fn standalone_wrapper_decode_checks_shared_payload_rules_test() {
  let semantic_profile =
    types.SemanticProfile(
      ..profile(
        [types.Wrapper("text", "text", types.WrapperText(Some("literal")))],
        types.TagModel("kind", None, []),
      ),
      format_bindings: [
        types.FormatBinding("literal", reference(), types.Literal("accepted")),
      ],
    )
  let value = json.JsonValueObj([#("text", json.JsonValueStr("accepted"))])
  let assert Ok(json.JsonValueStr("accepted")) =
    runtime.wrap_decode(semantic_profile, "text", value)
  list.each(
    [
      json.JsonValueObj([#("text", json.JsonValueStr("wrong"))]),
      json.JsonValueObj([#("text", json.JsonValueNum(1))]),
      json.JsonValueObj([
        #("text", json.JsonValueStr("accepted")),
        #("extra", json.JsonValueBool(True)),
      ]),
    ],
    fn(value) {
      let assert types.WrapperObject(_) =
        runtime.class_of(semantic_profile, value)
      let assert Error(runtime.WrongWrapperPayload("text")) =
        runtime.wrap_decode(semantic_profile, "text", value)
    },
  )
}
