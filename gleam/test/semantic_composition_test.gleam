// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import gleam/string
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

fn cid_rule() -> types.FormatRule {
  types.Choice(
    list.map(["bafkrei", "bafyrei"], fn(prefix) {
      types.Sequence([
        types.Literal(prefix),
        types.Identifier("abcdefgh", "abcdefgh", Some(1), 1, Some(1), []),
        types.Identifier(
          "abcdefghijklmnopqrstuvwxyz234567",
          "abcdefghijklmnopqrstuvwxyz234567",
          Some(50),
          50,
          Some(50),
          [],
        ),
        types.Identifier("aeimquy4", "aeimquy4", Some(1), 1, Some(1), []),
      ])
    }),
  )
}

fn bounded_graph(rule: types.FormatRule) -> types.SemanticGraph {
  let scalar =
    types.TypeNode(
      reference("scalar"),
      types.StringShape(types.StringSpec(
        Some(types.InlineFormat(rule)),
        [],
        None,
        None,
        None,
        [],
        None,
      )),
      None,
      [],
      [],
    )
  let products =
    list.map(
      [
        #("getRecord-parameters", [
          #("repo", True),
          #("collection", True),
          #("rkey", True),
          #("cid", False),
        ]),
        #("errorBody", [#("error", True), #("message", False)]),
        #("cid-holder", [#("cid", True)]),
      ],
      fn(item) {
        types.TypeNode(
          reference(item.0),
          types.ProductShape(types.ProductSpec(
            list.map(item.1, fn(field) {
              types.FieldSpec(
                field.0,
                types.SlotContract(reference("scalar"), field.1, False),
                types.OccurrenceRef(source(), []),
              )
            }),
            types.RejectExtras,
          )),
          None,
          [],
          [],
        )
      },
    )
  types.SemanticGraph(profile(), [scalar, ..products], [source()])
}

fn bounded_input(
  g: types.SemanticGraph,
  bounds: composition.SearchBounds,
) -> composition.CompositionInput {
  composition.CompositionInput(
    "bounded",
    "1",
    composition.semantic_basis(g),
    [],
    [
      composition.InitialInput(
        composition.InputId("initial"),
        slot("scalar"),
        composition.Argument,
        None,
      ),
    ],
    [],
    composition.GoalSpec(
      list.map(["getRecord-parameters", "errorBody"], fn(name) {
        composition.GoalPort(
          composition.GoalPortId(name),
          slot(name),
          composition.AnyCompatible,
        )
      }),
      [],
      [],
    ),
    composition.InvocationDomain("domain", "1", [], [], [], [], []),
    [],
    [],
    Some(composition.AnyFeasible),
    bounds,
  )
}

fn bounded_comparison(rule: types.FormatRule, text: String) {
  let g = bounded_graph(rule)
  let length = string.length(text)
  list.each([length - 1, length], fn(maximum) {
    let bounds =
      composition.SearchBounds(
        ..composition.default_search_bounds(),
        max_sample_length: maximum,
      )
    list.each(["getRecord-parameters", "errorBody"], fn(name) {
      let samples =
        composition.inclusion_samples_bounded(
          g,
          reference("scalar"),
          reference(name),
          bounds,
        )
      let decision =
        composition.check_assignable_bounded(
          g,
          slot("scalar"),
          slot(name),
          bounds,
        )
      case maximum < length {
        True -> {
          let assert [] = samples.values
          let assert True =
            list.contains(samples.obligations, composition.SampleBound)
          let assert composition.CompatibilityUnknown(_) = decision
          Nil
        }
        False -> {
          let assert True =
            list.contains(samples.values, json.JsonValueStr(text))
          let assert composition.Incompatible(certificate) = decision
          let assert types.Present(json.JsonValueStr(value)) = certificate.value
          let assert True = string.length(value) == length
          let assert True =
            validation.accepts_value(
              g,
              reference("scalar"),
              json.JsonValueStr(value),
            )
          let assert types.WrongValueKindCondition("object") =
            certificate.destination_failure.condition
          Nil
        }
      }
    })
    let assert Ok(projection) =
      validation.project_slot(g, slot("cid-holder"), [types.Field("cid")], [])
    let assert composition.Compatible(_) =
      composition.check_assignable_bounded(
        g,
        projection.destination,
        slot("scalar"),
        bounds,
      )
    let assert Ok(prepared) =
      composition.prepare_composition(g, bounded_input(g, bounds), fn(_) {
        Ok(Nil)
      })
    let candidates =
      composition.enumerate_state(
        prepared,
        composition.initial_state(prepared),
        composition.fresh_budget(),
      )
    let assert [] = candidates.terminals
    case maximum < length {
      True -> {
        let assert True = candidates.unknown != []
        Nil
      }
      False -> {
        let assert [] = candidates.unknown
        list.each(["getRecord-parameters", "errorBody"], fn(name) {
          let assert True =
            list.any(candidates.failures, fn(failure) {
              failure.destination == slot(name)
            })
        })
      }
    }
  })
}

pub fn generic_scalar_product_l_minus_one_l_test() {
  bounded_comparison(types.Literal("generic"), "generic")
}

pub fn canonical_cid_two_products_58_59_test() {
  let text = "bafkrei" <> string.repeat("a", 52)
  let assert 59 = string.length(text)
  bounded_comparison(cid_rule(), text)
}

pub fn product_additional_candidates_obey_bound_test() {
  let g =
    types.SemanticGraph(
      profile(),
      [
        types.TypeNode(
          reference("boolean"),
          types.BooleanShape(types.BooleanSpec(None, None)),
          None,
          [],
          [],
        ),
        types.TypeNode(
          reference("source"),
          types.ProductShape(types.ProductSpec(
            [],
            types.AllowExtras(
              None,
              types.ElementContract(reference("boolean"), False),
            ),
          )),
          None,
          [],
          [],
        ),
        types.TypeNode(
          reference("destination"),
          types.ProductShape(types.ProductSpec(
            [
              types.FieldSpec(
                "long-key",
                types.SlotContract(reference("boolean"), False, False),
                types.OccurrenceRef(source(), []),
              ),
            ],
            types.RejectExtras,
          )),
          None,
          [],
          [],
        ),
      ],
      [source()],
    )
  list.each([0, 1], fn(maximum) {
    let samples =
      composition.inclusion_samples_bounded(
        g,
        reference("source"),
        reference("destination"),
        composition.SearchBounds(
          ..composition.default_search_bounds(),
          max_sample_length: maximum,
        ),
      )
    let present =
      list.any(samples.values, fn(value) {
        case value {
          json.JsonValueObj(members) ->
            list.any(members, fn(member) { member.0 == "long-key" })
          _ -> False
        }
      })
    let assert True = present == { maximum == 1 }
    let assert True =
      maximum == 1
      || list.contains(samples.obligations, composition.SampleBound)
    let assert True =
      list.all(samples.values, fn(value) {
        validation.accepts_value(g, reference("source"), value)
      })
  })
}
