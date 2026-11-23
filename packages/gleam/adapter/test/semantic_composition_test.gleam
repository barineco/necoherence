// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import necoherence/admission_failure as admission
import necoherence/composition_plan
import necoherence/exact_json as json
import necoherence/inclusion
import necoherence/resource_witness
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import necoherence/typed_mapping as resource
import simplifile

pub fn variant_guard_unknown_arm_is_admitted_without_derivation_check_test() {
  let assert Ok(exchange) =
    simplifile.read("test/fixtures/variant-guard-incomplete-coverage.json")
  let assert Ok(wire) = values.parse_wire(exchange)
  let assert Ok(expected) = signatures.expected_generation_text(wire)
  let assert Ok(_) = signatures.admit_generation_context(expected, exchange)
  let assert Ok(_) = signatures.admit_generation(expected, exchange)
}

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
  let assert inclusion.Incompatible(certificate) =
    inclusion.check_assignable(
      validation.prepare(graph()),
      slot("text"),
      slot("not-a"),
      64,
    )
  let assert types.Present(json.JsonValueStr("a")) = certificate.value
  let assert types.FormatFailureCondition("not-a") =
    certificate.destination_failure.condition
}

pub fn product_extra_counterexample_is_reported_test() {
  let assert inclusion.Incompatible(certificate) =
    inclusion.check_assignable(
      validation.prepare(graph()),
      slot("extras"),
      slot("closed"),
      64,
    )
  let assert types.Present(json.JsonValueObj([#("x", _)])) = certificate.value
  let assert types.UnexpectedFieldCondition("x") =
    certificate.destination_failure.condition
}

fn admission_of(path: String) {
  let assert Ok(exchange) = simplifile.read(path)
  let assert Ok(wire) = values.parse_wire(exchange)
  let assert Ok(expected) = signatures.expected_generation_text(wire)
  signatures.admit_generation(expected, exchange)
}

pub fn composition_input_is_prepared_before_the_derivation_is_translated_test() {
  let assert Error(admission.CompositionInput(composition_plan.InvalidInitialValue(
    _,
    _,
  ))) =
    admission_of("test/fixtures/invalid-initial-value-and-inclusion-basis.json")
}

pub fn derivation_translation_failure_is_a_wire_failure_test() {
  let assert Error(admission.Wire(decode.SyntaxFailure(
    _,
    "inclusion basis mismatch",
  ))) = admission_of("test/fixtures/inclusion-basis-mismatch.json")
}

pub fn function_ref_digest_shape_is_checked_by_signature_preparation_test() {
  list.each(
    [
      "test/fixtures/function-ref-digest-short.json",
      "test/fixtures/function-ref-digest-uppercase.json",
    ],
    fn(path) {
      let assert Error(admission.CompositionInput(composition_plan.InvalidSignature(
        _,
        _,
      ))) = admission_of(path)
    },
  )
}

pub fn function_ref_with_an_invalid_digest_is_an_unresolved_function_test() {
  let assert Error(admission.CompositionInput(composition_plan.UnresolvedFunction(
    _,
  ))) =
    admission_of("test/fixtures/function-ref-digest-unresolved-function.json")
}

fn resource_input(goal: resource.GoalPredicate) -> resource.SolverInput {
  let token =
    resource.ColoredToken(
      target: "res-a",
      index: 0,
      revision: 1,
      kind: resource.TokenInput,
    )
  resource.SolverInput(
    places: [
      resource.TypedPlace("p1", "tok", 1),
      resource.TypedPlace("p2", "tok", 1),
    ],
    transitions: [resource.TypedTransition("t1", ["p1"], ["p2"], [], 1)],
    bindings: [
      resource.InputBinding(
        transition_id: "t1",
        name: "b1",
        place: "p1",
        token_type: "tok",
        identity: "res-a",
        provenance: "decl",
        multiplicity: 1,
        mode: resource.Consume,
        required_revision: 1,
      ),
    ],
    goal: goal,
    graph: resource.DeclarationGraph(
      ["p1", "p2"],
      ["t1"],
      [#("p1", "t1"), #("t1", "p2")],
      1,
    ),
    marking: resource.Marking([#("p1", [token]), #("p2", [])]),
    bound: resource.DomainBound("res-a", 0, 1, 4, 4),
  )
}

pub fn reachability_witness_failures_follow_the_lean_order_test() {
  let input = resource_input(resource.PlaceHasAtLeast("p2", 1))
  let assert Some(final) = resource.step_at(input, input.marking, "t1")
  let assert Ok(_) =
    resource_witness.verify_reachability_witness(
      input,
      resource.ReachabilityWitness(["t1"], final),
    )
  let assert Error(resource_witness.ResourceReplayMismatch(
    "enabled path or final marking",
  )) =
    resource_witness.verify_reachability_witness(
      input,
      resource.ReachabilityWitness(["t1"], input.marking),
    )
  let assert Error(resource_witness.ResourceReplayMismatch("path step bound")) =
    resource_witness.verify_reachability_witness(
      input,
      resource.ReachabilityWitness(["t1", "t1", "t1", "t1", "t1"], final),
    )
  let unmet = resource_input(resource.PlaceHasAtLeast("p2", 2))
  let assert Error(resource_witness.ResourceReplayMismatch(
    "terminal resource goal",
  )) =
    resource_witness.verify_reachability_witness(
      unmet,
      resource.ReachabilityWitness(["t1"], final),
    )
}

pub fn closure_witness_failures_follow_the_lean_order_test() {
  let input = resource_input(resource.PlaceHasAtLeast("p2", 1))
  let assert Some(final) = resource.step_at(input, input.marking, "t1")
  let assert Error(resource_witness.ForgedClosure("enabled successor omitted")) =
    resource_witness.verify_closure_witness(
      input,
      resource.ClosureWitness([input.marking], 1, []),
    )
  let assert Error(resource_witness.ForgedClosure("initial marking omitted")) =
    resource_witness.verify_closure_witness(
      input,
      resource.ClosureWitness([final], 1, []),
    )
  let assert Error(resource_witness.ForgedClosure("duplicated explored marking")) =
    resource_witness.verify_closure_witness(
      input,
      resource.ClosureWitness([input.marking, input.marking], 2, []),
    )
  let assert Error(resource_witness.ForgedClosure(
    "closed marking satisfies the goal",
  )) =
    resource_witness.verify_closure_witness(
      input,
      resource.ClosureWitness([input.marking, final], 2, []),
    )
  let assert Ok(_) =
    resource_witness.verify_acyclic_witness(
      input,
      resource.AcyclicWitness([input.marking, final], 2, []),
    )
}
