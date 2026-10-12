// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import necoherence/exact_json as json
import necoherence/semantic_composition as composition
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation

fn source() -> types.SourceRef {
  types.SourceRef("test", "4", "types.json", "digest", "test", None)
}

fn reference(name: String) -> types.TypeRef {
  types.TypeRef(source(), name, [name])
}

fn profile() -> types.SemanticProfile {
  let profile_ref = types.ProfileRef("test", "4", "digest")
  types.SemanticProfile(
    profile_ref,
    [],
    [
      types.IntegerDomainBinding(
        "default",
        profile_ref,
        types.IntegerInterval(-100, 100),
        [types.Number, types.DecimalString],
      ),
    ],
    "default",
    types.NumberModel(True),
    None,
    [
      types.FormatBinding("text", profile_ref, types.Text),
      types.FormatBinding("not-x", profile_ref, types.Not(types.Literal("x"))),
      types.FormatBinding("not-a", profile_ref, types.Not(types.Literal("a"))),
      types.FormatBinding("x", profile_ref, types.Literal("x")),
    ],
    None,
    [],
    None,
  )
}

fn string_spec(format: String) -> types.StringSpec {
  types.StringSpec(
    Some(types.NamedFormat(format)),
    [],
    None,
    None,
    None,
    [],
    None,
  )
}

fn graph() -> types.SemanticGraph {
  let any = reference("any")
  types.SemanticGraph(
    profile(),
    [
      types.TypeNode(
        reference("text"),
        types.StringShape(string_spec("text")),
        None,
        [],
        [],
      ),
      types.TypeNode(
        reference("not-a"),
        types.StringShape(string_spec("not-a")),
        None,
        [],
        [],
      ),
      types.TypeNode(
        reference("not-x"),
        types.StringShape(string_spec("not-x")),
        None,
        [],
        [],
      ),
      types.TypeNode(any, types.UnknownShape(types.AnyValue), None, [], []),
      types.TypeNode(
        reference("extras"),
        types.ProductShape(types.ProductSpec(
          [],
          types.AllowExtras(
            Some(types.NamedFormat("x")),
            types.ElementContract(any, False),
          ),
        )),
        None,
        [],
        [],
      ),
      types.TypeNode(
        reference("closed"),
        types.ProductShape(types.ProductSpec([], types.RejectExtras)),
        None,
        [],
        [],
      ),
      types.TypeNode(reference("never"), types.Never, None, [], []),
    ],
    [source()],
  )
}

fn slot(name: String) -> types.SlotContract {
  types.SlotContract(reference(name), True, False)
}

pub fn format_counterexample_is_reported_test() {
  let assert composition.Incompatible(certificate) =
    composition.check_assignable(graph(), slot("text"), slot("not-a"), 64)
  let assert types.Present(json.JsonValueStr("a")) = certificate.value
  let assert types.FormatFailureCondition("not-a") =
    certificate.destination_failure.condition
}

pub fn product_extra_counterexample_is_reported_test() {
  let assert composition.Incompatible(certificate) =
    composition.check_assignable(graph(), slot("extras"), slot("closed"), 64)
  let assert types.Present(json.JsonValueObj([#("x", _)])) = certificate.value
  let assert types.UnexpectedFieldCondition("x") =
    certificate.destination_failure.condition
}

pub fn generated_samples_are_members_test() {
  let values = composition.samples(graph(), reference("not-x"), [], 64)
  let assert True = values != []
  let assert True =
    list.all(values, fn(value) {
      validation.declared_value_decision(graph(), reference("not-x"), value)
      == types.AcceptedValue
    })
}

pub fn never_has_no_samples_test() {
  let assert [] = composition.samples(graph(), reference("never"), [], 64)
}
