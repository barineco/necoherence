// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/option.{None, Some}
import necoherence/composition_input
import necoherence/composition_plan
import necoherence/exact_json as json
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import semantic_test_support as support

fn graph() -> types.SemanticGraph {
  support.graph([
    support.node("a", types.BooleanShape(types.BooleanSpec(None, None))),
    support.node(
      "p",
      types.ProductShape(types.ProductSpec(
        [support.field("f", "a", True, False)],
        types.RejectExtras,
      )),
    ),
    support.node(
      "t",
      types.ProductShape(types.ProductSpec(
        [support.field("next", "u", True, False)],
        types.RejectExtras,
      )),
    ),
    support.node(
      "w",
      types.ProductShape(types.ProductSpec(
        [support.field("self", "w", True, False)],
        types.RejectExtras,
      )),
    ),
    support.node(
      "u",
      types.ProductShape(types.ProductSpec(
        [support.field("back", "t", True, False)],
        types.RejectExtras,
      )),
    ),
    support.node(
      "q",
      types.ProductShape(types.ProductSpec(
        [support.field("g", "p", True, False)],
        types.RejectExtras,
      )),
    ),
  ])
}

fn slot(name: String) -> types.SlotContract {
  types.SlotContract(support.reference(name), True, False)
}

fn function_reference(name: String) -> composition_plan.FunctionRef {
  composition_plan.FunctionRef(name, "1", "digest")
}

fn function(name: String) -> composition_plan.FunctionSignature {
  composition_plan.FunctionSignature(
    function_reference(name),
    composition_plan.Pure,
    composition_plan.PureFunction,
    [],
    [
      composition_plan.OutcomeContract(
        composition_plan.OutcomeId("ok"),
        composition_plan.Success,
        [],
        [],
      ),
    ],
    [],
    "assumptions",
    None,
  )
}

fn input() -> composition_plan.CompositionInput {
  composition_plan.CompositionInput(
    "input",
    "1",
    composition_plan.semantic_basis_of(graph()),
    [],
    [],
    [],
    composition_plan.GoalSpec(
      [
        composition_plan.GoalPort(
          composition_plan.GoalPortId("goal"),
          slot("a"),
          composition_plan.AnyCompatible,
        ),
      ],
      [],
      [],
    ),
    composition_plan.InvocationDomain("domain", "1", [], [], [], [], []),
    [],
    [],
    None,
    composition_plan.SearchBounds(10_000, 100_000, 10_000, 100_000, 32, None),
  )
}

fn domain(
  input: composition_plan.CompositionInput,
  update: fn(composition_plan.InvocationDomain) ->
    composition_plan.InvocationDomain,
) -> composition_plan.CompositionInput {
  composition_plan.CompositionInput(
    ..input,
    invocation_domain: update(input.invocation_domain),
  )
}

fn prepare(
  input: composition_plan.CompositionInput,
) -> Result(
  composition_plan.PreparedCompositionInput,
  composition_plan.CompositionInputFailure,
) {
  composition_input.prepare_direct_composition(
    validation.prepare(graph()),
    input,
    fn(_, _) { Ok(Nil) },
    fn(_, _) { [] },
  )
}

fn failure(
  input: composition_plan.CompositionInput,
) -> composition_plan.CompositionInputFailure {
  let assert Error(failure) = prepare(input)
  failure
}

fn initial(name: String) -> composition_plan.InitialInput {
  composition_plan.InitialInput(
    composition_plan.InputId(name),
    slot("a"),
    composition_plan.Argument,
    None,
  )
}

fn rule(
  identity: String,
  type_name: String,
  nested: List(#(String, String)),
) -> composition_plan.ConstructionRule {
  composition_plan.ConstructionRule(
    identity,
    support.reference(type_name),
    nested,
    [],
  )
}

pub fn valid_input_is_prepared_test() {
  let assert Ok(_) = prepare(input())
}

pub fn basis_mismatch_precedes_identity_checks_test() {
  let other =
    composition_plan.SemanticBasis(
      types.SemanticProfile(
        ..support.profile(),
        default_integer_domain: "other",
      ),
      [],
    )
  let assert composition_plan.InputBasisMismatch =
    failure(
      composition_plan.CompositionInput(
        ..input(),
        basis: other,
        initial_inputs: [
          initial("x"),
          initial("x"),
        ],
      ),
    )
}

pub fn duplicate_identity_reports_the_later_occurrence_test() {
  let assert composition_plan.DuplicateIdentity("input", "y") =
    failure(
      composition_plan.CompositionInput(..input(), initial_inputs: [
        initial("x"),
        initial("y"),
        initial("y"),
        initial("x"),
      ]),
    )
  let assert composition_plan.DuplicateIdentity("input", "") =
    failure(
      composition_plan.CompositionInput(..input(), initial_inputs: [initial("")]),
    )
}

pub fn signature_checks_follow_lean_order_test() {
  let invalid = fn(function) {
    failure(
      composition_plan.CompositionInput(..input(), signatures: [function]),
    )
  }
  let assert composition_plan.InvalidSignature(
    _,
    "identity, revision, digest, assumptions, or outcomes",
  ) = invalid(composition_plan.FunctionSignature(..function("f"), outcomes: []))
  let assert composition_plan.InvalidSignature(_, "pure function effect") =
    invalid(
      composition_plan.FunctionSignature(
        ..function("f"),
        effect: composition_plan.DataOnly,
      ),
    )
  let port =
    composition_plan.InputPort(
      composition_plan.PortId("in"),
      slot("missing"),
      composition_plan.AnyCompatible,
      None,
    )
  let operation =
    composition_plan.FunctionSignature(
      ..function("f"),
      form: composition_plan.Operation(types.DefinitionRef(
        support.source(),
        "op",
      )),
      inputs: [port],
    )
  let checked =
    composition_input.prepare_direct_composition(
      validation.prepare(graph()),
      composition_plan.CompositionInput(..input(), signatures: [operation]),
      fn(_, _) {
        Error(composition_plan.InvalidSignature(
          function_reference("f"),
          "checker",
        ))
      },
      fn(_, _) { [] },
    )
  let assert Error(composition_plan.InvalidSignature(_, "checker")) = checked
  let assert composition_plan.UnresolvedType(_) =
    invalid(composition_plan.FunctionSignature(..function("f"), inputs: [port]))
  let assert composition_plan.InvalidSignature(_, "input source constraint") =
    invalid(
      composition_plan.FunctionSignature(..function("f"), inputs: [
        composition_plan.InputPort(
          composition_plan.PortId("in"),
          slot("a"),
          composition_plan.InitialOnly(composition_plan.InputId("none"), []),
          None,
        ),
      ]),
    )
  let assert composition_plan.InvalidSignature(_, "input resource requirement") =
    invalid(
      composition_plan.FunctionSignature(..function("f"), inputs: [
        composition_plan.InputPort(
          composition_plan.PortId("in"),
          slot("a"),
          composition_plan.AnyCompatible,
          Some(composition_plan.RequirementId("none")),
        ),
      ]),
    )
  let assert composition_plan.InvalidSignature(_, "output resource production") =
    invalid(
      composition_plan.FunctionSignature(..function("f"), outcomes: [
        composition_plan.OutcomeContract(
          composition_plan.OutcomeId("ok"),
          composition_plan.Success,
          [
            composition_plan.OutputPort(
              composition_plan.PortId("out"),
              slot("a"),
              Some(composition_plan.ProductionId("none")),
            ),
          ],
          [],
        ),
      ]),
    )
  let assert composition_plan.InvalidSignature(_, "failure handler origin") =
    invalid(
      composition_plan.FunctionSignature(
        ..function("f"),
        handles_failure: Some(composition_plan.GuardFailure(
          composition_plan.GuardId("none"),
          composition_plan.GuardRejected,
        )),
      ),
    )
}

pub fn site_checks_reject_unresolved_and_forbidden_functions_test() {
  let site =
    composition_plan.InvocationSite(
      composition_plan.SiteId("s"),
      function_reference("f"),
    )
  let with_site = fn(signatures, effects, permitted) {
    composition_plan.CompositionInput(
      ..domain(input(), fn(domain) {
        composition_plan.InvocationDomain(
          ..domain,
          sites: [site],
          permitted_transforms: permitted,
        )
      }),
      signatures: signatures,
      allowed_effects: effects,
    )
  }
  let assert composition_plan.UnresolvedFunction(_) =
    failure(with_site([], [], []))
  let assert composition_plan.SiteEffectNotPermitted(_, _) =
    failure(with_site([function("f")], [], []))
  let transform =
    composition_plan.FunctionSignature(
      ..function("f"),
      form: composition_plan.DeclaredTransform,
    )
  let assert composition_plan.TransformNotPermitted(_) =
    failure(with_site([transform], [composition_plan.PureFunction], []))
  let assert Ok(_) =
    prepare(
      with_site([transform], [composition_plan.PureFunction], [
        function_reference("f"),
      ]),
    )
}

pub fn initial_values_and_lots_are_checked_test() {
  let assert composition_plan.InvalidInitialValue(_, rejected) =
    failure(
      composition_plan.CompositionInput(..input(), initial_inputs: [
        composition_plan.InitialInput(
          composition_plan.InputId("x"),
          slot("a"),
          composition_plan.SuppliedValue(types.Present(json.JsonValueNum(1))),
          None,
        ),
      ]),
    )
  let assert types.WrongValueKindCondition("boolean") = rejected.condition
  let assert composition_plan.InvalidResourceDeclaration("initial backing lot") =
    failure(
      composition_plan.CompositionInput(..input(), initial_inputs: [
        composition_plan.InitialInput(
          composition_plan.InputId("x"),
          slot("a"),
          composition_plan.Argument,
          Some(composition_plan.LotId("none")),
        ),
      ]),
    )
  let lot = fn(producer, provenance) {
    failure(
      composition_plan.CompositionInput(..input(), initial_resources: [
        composition_plan.ResourceLot(
          composition_plan.LotId("lot"),
          support.reference("a"),
          producer,
          1,
          1,
          provenance,
        ),
      ]),
    )
  }
  let assert composition_plan.InvalidResourceDeclaration(
    "initial producer or provenance",
  ) = lot(composition_plan.InitialResource("origin", "1"), "")
  let assert composition_plan.InvalidResourceDeclaration(
    "initial lot has an invocation producer",
  ) =
    lot(
      composition_plan.OutcomeResource(
        composition_plan.SiteId("s"),
        composition_plan.OutcomeId("o"),
      ),
      "p",
    )
}

pub fn goals_and_failure_embeddings_are_checked_test() {
  let assert composition_plan.EmptyGoal =
    failure(
      composition_plan.CompositionInput(
        ..input(),
        goal: composition_plan.GoalSpec([], [], []),
      ),
    )
  let goal = fn(constraint) {
    composition_plan.CompositionInput(
      ..input(),
      goal: composition_plan.GoalSpec(
        [
          composition_plan.GoalPort(
            composition_plan.GoalPortId("goal"),
            slot("a"),
            constraint,
          ),
        ],
        [],
        [],
      ),
    )
  }
  let assert composition_plan.GoalSourceConstraintUndefined(_, _) =
    failure(
      goal(composition_plan.InitialOnly(composition_plan.InputId("none"), [])),
    )
  let assert Ok(_) =
    prepare(
      composition_plan.CompositionInput(
        ..goal(composition_plan.InitialOnly(composition_plan.InputId("x"), [])),
        initial_inputs: [initial("x")],
      ),
    )
  let assert composition_plan.GoalSourceConstraintUndefined(_, _) =
    failure(
      composition_plan.CompositionInput(
        ..goal(
          composition_plan.InitialOnly(composition_plan.InputId("x"), [
            types.Field("f"),
          ]),
        ),
        initial_inputs: [initial("x")],
      ),
    )
  let assert composition_plan.FailureEmbeddingOriginUndefined(_, _) =
    failure(
      composition_plan.CompositionInput(
        ..input(),
        goal: composition_plan.GoalSpec(
          input().goal.outputs,
          [
            composition_plan.FailureEmbedding(
              composition_plan.FailureEmbeddingId("embedding"),
              composition_plan.GuardFailure(
                composition_plan.GuardId("none"),
                composition_plan.GuardRejected,
              ),
              slot("a"),
              [],
            ),
          ],
          [],
        ),
      ),
    )
}

pub fn construction_rules_are_checked_test() {
  let rules = fn(permitted) {
    failure(
      domain(input(), fn(domain) {
        composition_plan.InvocationDomain(
          ..domain,
          permitted_constructions: permitted,
        )
      }),
    )
  }
  let assert composition_plan.ConstructionNotProduct("r", _) =
    rules([rule("r", "a", [])])
  let assert composition_plan.NestedFieldUndeclared("r", "missing") =
    rules([rule("r", "p", [#("missing", "r")])])
  let assert composition_plan.NestedConstructionMismatch("r", "g", "none", _) =
    rules([rule("r", "q", [#("g", "none")])])
  let assert composition_plan.CyclicConstruction("r") =
    rules([rule("r", "w", [#("self", "r")])])
  let assert composition_plan.CyclicConstruction("r") =
    rules([
      rule("r", "t", [#("next", "s")]),
      rule("s", "u", [#("back", "r")]),
    ])
  let assert composition_plan.DuplicateIdentity("nested field", "g") =
    rules([rule("r", "q", [#("g", "r"), #("g", "r")])])
  let constraint = fn(field, nested) {
    composition_plan.ConstructionRule("r", support.reference("q"), nested, [
      composition_plan.FieldConstraint(
        field,
        composition_plan.InitialOnly(composition_plan.InputId("none"), []),
        composition_plan.Required,
      ),
    ])
  }
  let assert composition_plan.FieldConstraintUnknownField("r", "missing") =
    rules([constraint("missing", [])])
  let assert composition_plan.ConstrainedNestedField("r", "g") =
    rules([constraint("g", [#("g", "r")])])
  let assert composition_plan.ConstructionFieldSourceUndefined("r", _) =
    rules([constraint("g", [])])
}

pub fn guards_orders_and_terminal_lots_are_checked_test() {
  let assert composition_plan.UnresolvedType(_) =
    failure(
      domain(input(), fn(domain) {
        composition_plan.InvocationDomain(..domain, guards: [
          composition_plan.DeclaredGuard(
            composition_plan.GuardId("g"),
            support.reference("missing"),
            [],
            composition_plan.Presence,
          ),
        ])
      }),
    )
  let assert composition_plan.ExplicitSiteOrderInvalid(_, _) =
    failure(
      composition_plan.CompositionInput(..input(), explicit_order: [
        #(composition_plan.SiteId("s"), composition_plan.SiteId("s")),
      ]),
    )
  let assert composition_plan.InvalidResourceDeclaration(
    "terminal resource lot",
  ) =
    failure(
      composition_plan.CompositionInput(
        ..input(),
        goal: composition_plan.GoalSpec(input().goal.outputs, [], [
          composition_plan.ResourceGoal(
            composition_plan.InitialLot(composition_plan.LotId("none")),
            1,
            1,
          ),
        ]),
      ),
    )
}
