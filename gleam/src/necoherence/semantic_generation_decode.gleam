// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import necoherence/exact_json as kdl
import necoherence/semantic_composition as composition
import necoherence/semantic_generation_values as values
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import necoherence/typed_mapping as resource

pub type DecodeFailure {
  DecodeFailure(path: List(String), reason: String)
  ProfileFailure(failure: types.ProfileFailure)
  UnsupportedSchema(observed: String)
  UnknownField(path: List(String), field: String)
  UnknownTag(path: List(String), tag: String)
  SyntaxFailure(path: List(String), reason: String)
}

pub type GenerationComposition {
  GenerationComposition(
    problem: composition.CompositionInput,
    derivation: composition.RawComposition,
  )
}

pub fn decode_generation_composition(
  value: kdl.JsonValue,
) -> Result(GenerationComposition, DecodeFailure) {
  use members <- result.try(object(value, ["problem", "derivation"]))
  use raw_problem <- result.try(field(members, "problem"))
  use problem <- result.try(named(
    "problem",
    decode_composition_input(raw_problem),
  ))
  use raw_derivation <- result.try(field(members, "derivation"))
  use derivation <- result.try(named(
    "derivation",
    decode_raw_composition(raw_derivation),
  ))
  Ok(GenerationComposition(problem, derivation))
}

pub fn decode_acyclic_witness(
  value: kdl.JsonValue,
) -> Result(resource.AcyclicWitness, DecodeFailure) {
  use members <- result.try(
    object(value, ["explored_markings", "steps", "frontier"]),
  )
  use raw_0 <- result.try(field(members, "explored_markings"))
  use a0 <- result.try(named(
    "explored_markings",
    array(raw_0, fn(value) { decode_marking(value) }),
  ))
  use raw_1 <- result.try(field(members, "steps"))
  use a1 <- result.try(named("steps", integer(raw_1, True)))
  use raw_2 <- result.try(field(members, "frontier"))
  use a2 <- result.try(named(
    "frontier",
    array(raw_2, fn(value) { decode_marking(value) }),
  ))
  Ok(resource.AcyclicWitness(a0, a1, a2))
}

fn decode_element_contract(
  value: kdl.JsonValue,
) -> Result(types.ElementContract, DecodeFailure) {
  use members <- result.try(object(value, ["type_ref", "nullable"]))
  use raw_type_ref <- result.try(field(members, "type_ref"))
  use type_ref <- result.try(named("type_ref", decode_type_ref(raw_type_ref)))
  use raw_nullable <- result.try(field(members, "nullable"))
  use nullable <- result.try(named("nullable", boolean(raw_nullable)))
  Ok(types.ElementContract(type_ref, nullable))
}

pub fn decode_array_spec(
  value: kdl.JsonValue,
) -> Result(types.ArraySpec, DecodeFailure) {
  use members <- result.try(object(value, ["item", "min_length", "max_length"]))
  use raw_0 <- result.try(field(members, "item"))
  use a0 <- result.try(named("item", decode_element_contract(raw_0)))
  use raw_1 <- result.try(field(members, "min_length"))
  use a1 <- result.try(named(
    "min_length",
    optional(raw_1, fn(value) { integer(value, True) }),
  ))
  use raw_2 <- result.try(field(members, "max_length"))
  use a2 <- result.try(named(
    "max_length",
    optional(raw_2, fn(value) { integer(value, True) }),
  ))
  Ok(types.ArraySpec(a0, a1, a2))
}

pub fn decode_available_value(
  value: kdl.JsonValue,
) -> Result(composition.AvailableValue, DecodeFailure) {
  use members <- result.try(object(value, ["producer", "contract", "resource"]))
  use raw_0 <- result.try(field(members, "producer"))
  use a0 <- result.try(named("producer", decode_producer_ref(raw_0)))
  use raw_1 <- result.try(field(members, "contract"))
  use a1 <- result.try(named("contract", decode_slot_contract(raw_1)))
  use raw_2 <- result.try(field(members, "resource"))
  use a2 <- result.try(named(
    "resource",
    optional(raw_2, fn(value) { decode_resource_lot_ref(value) }),
  ))
  Ok(composition.AvailableValue(a0, a1, a2))
}

pub fn decode_binding_compatibility(
  value: kdl.JsonValue,
) -> Result(composition.BindingCompatibility, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Inclusion" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        decode_inclusion_certificate(payload),
      ))
      Ok(composition.Inclusion(decoded))
    }
    "SuppliedValue" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["value"]))
      use raw_0 <- result.try(field(members, "value"))
      use a0 <- result.try(named("value", decode_slot_value(raw_0)))
      Ok(composition.SuppliedBindingValue(a0))
    }
    _ -> fail("unknown BindingCompatibility tag")
  }
}

pub fn decode_binding_expr(
  value: kdl.JsonValue,
) -> Result(composition.BindingExpr, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Source" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(
        object(payload, ["value", "projection", "compatibility"]),
      )
      use raw_0 <- result.try(field(members, "value"))
      use a0 <- result.try(named("value", decode_value_ref(raw_0)))
      use raw_1 <- result.try(field(members, "projection"))
      use a1 <- result.try(named(
        "projection",
        decode_projection_certificate(raw_1),
      ))
      use raw_2 <- result.try(field(members, "compatibility"))
      use a2 <- result.try(named(
        "compatibility",
        decode_binding_compatibility(raw_2),
      ))
      Ok(composition.Source(a0, a1, a2))
    }
    "Product" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(
        object(payload, ["construction", "type_ref", "fields"]),
      )
      use raw_0 <- result.try(field(members, "construction"))
      use a0 <- result.try(named("construction", text(raw_0, "", "")))
      use raw_1 <- result.try(field(members, "type_ref"))
      use a1 <- result.try(named("type_ref", decode_type_ref(raw_1)))
      use raw_2 <- result.try(field(members, "fields"))
      use a2 <- result.try(named(
        "fields",
        array(raw_2, fn(value) { decode_tuple_1(value) }),
      ))
      Ok(composition.Product(a0, a1, a2))
    }
    _ -> fail("unknown BindingExpr tag")
  }
}

pub fn decode_binding_mode(
  value: kdl.JsonValue,
) -> Result(resource.BindingMode, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Read" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(resource.Read)
    }
    "Consume" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(resource.Consume)
    }
    _ -> fail("unknown BindingMode tag")
  }
}

pub fn decode_boolean_spec(
  value: kdl.JsonValue,
) -> Result(types.BooleanSpec, DecodeFailure) {
  use members <- result.try(object(value, ["const_value", "default_value"]))
  use raw_0 <- result.try(field(members, "const_value"))
  use a0 <- result.try(named(
    "const_value",
    optional(raw_0, fn(value) { boolean(value) }),
  ))
  use raw_1 <- result.try(field(members, "default_value"))
  use a1 <- result.try(named(
    "default_value",
    optional(raw_1, fn(value) { boolean(value) }),
  ))
  Ok(types.BooleanSpec(a0, a1))
}

pub fn decode_branch_fact(
  value: kdl.JsonValue,
) -> Result(composition.BranchFact, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "guard",
      "inspected",
      "arm",
      "refinement",
      "assumptions",
      "exact",
    ]),
  )
  use raw_0 <- result.try(field(members, "guard"))
  use a0 <- result.try(named(
    "guard",
    result.map(text(raw_0, "", ""), composition.GuardId),
  ))
  use raw_1 <- result.try(field(members, "inspected"))
  use a1 <- result.try(named("inspected", decode_value_ref(raw_1)))
  use raw_2 <- result.try(field(members, "arm"))
  use a2 <- result.try(named("arm", decode_guard_arm(raw_2)))
  use raw_3 <- result.try(field(members, "refinement"))
  use a3 <- result.try(named(
    "refinement",
    optional(raw_3, fn(value) { decode_slot_contract(value) }),
  ))
  use raw_4 <- result.try(field(members, "assumptions"))
  use a4 <- result.try(named(
    "assumptions",
    array(raw_4, fn(value) { decode_projection_assumption(value) }),
  ))
  use raw_5 <- result.try(field(members, "exact"))
  use a5 <- result.try(named(
    "exact",
    optional(raw_5, fn(value) { decode_slot_value(value) }),
  ))
  Ok(composition.BranchFact(a0, a1, a2, a3, a4, a5))
}

pub fn decode_branch_trace(
  value: kdl.JsonValue,
) -> Result(composition.BranchTrace, DecodeFailure) {
  use members <- result.try(object(value, ["steps", "terminal"]))
  use raw_0 <- result.try(field(members, "steps"))
  use a0 <- result.try(named(
    "steps",
    array(raw_0, fn(value) { decode_trace_step(value) }),
  ))
  use raw_1 <- result.try(field(members, "terminal"))
  use a1 <- result.try(named("terminal", decode_return_plan(raw_1)))
  Ok(composition.BranchTrace(a0, a1))
}

pub fn decode_calendar_rule(
  value: kdl.JsonValue,
) -> Result(types.CalendarRule, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "allow_second_60",
      "minimum_year",
      "maximum_year",
      "rejectUtcYearOutsideRange",
    ]),
  )
  use raw_0 <- result.try(field(members, "allow_second_60"))
  use a0 <- result.try(named("allow_second_60", boolean(raw_0)))
  use raw_1 <- result.try(field(members, "minimum_year"))
  use a1 <- result.try(named("minimum_year", integer(raw_1, True)))
  use raw_2 <- result.try(field(members, "maximum_year"))
  use a2 <- result.try(named("maximum_year", integer(raw_2, True)))
  use raw_3 <- result.try(field(members, "rejectUtcYearOutsideRange"))
  use a3 <- result.try(named("rejectUtcYearOutsideRange", boolean(raw_3)))
  Ok(types.CalendarRule(a0, a1, a2, a3))
}

pub fn decode_choice_coverage(
  value: kdl.JsonValue,
) -> Result(composition.ChoiceCoverage, DecodeFailure) {
  use members <- result.try(object(value, ["choice", "children"]))
  use raw_0 <- result.try(field(members, "choice"))
  use a0 <- result.try(named("choice", decode_choice_skeleton(raw_0)))
  use raw_1 <- result.try(field(members, "children"))
  use a1 <- result.try(named(
    "children",
    array(raw_1, fn(value) { integer(value, True) }),
  ))
  Ok(composition.ChoiceCoverage(a0, a1))
}

pub fn decode_choice_skeleton(
  value: kdl.JsonValue,
) -> Result(composition.ChoiceSkeleton, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Invoke" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(
        object(payload, ["invocation", "outcomes", "empty_outcomes"]),
      )
      use raw_0 <- result.try(field(members, "invocation"))
      use a0 <- result.try(named("invocation", decode_invocation_plan(raw_0)))
      use raw_1 <- result.try(field(members, "outcomes"))
      use a1 <- result.try(named(
        "outcomes",
        array(raw_1, fn(value) {
          result.map(text(value, "", ""), composition.OutcomeId)
        }),
      ))
      use raw_2 <- result.try(field(members, "empty_outcomes"))
      use a2 <- result.try(named(
        "empty_outcomes",
        array(raw_2, fn(value) {
          result.map(text(value, "", ""), composition.OutcomeId)
        }),
      ))
      Ok(composition.InvocationChoice(a0, a1, a2))
    }
    "Guard" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["guard", "inspected", "arms"]))
      use raw_0 <- result.try(field(members, "guard"))
      use a0 <- result.try(named(
        "guard",
        result.map(text(raw_0, "", ""), composition.GuardId),
      ))
      use raw_1 <- result.try(field(members, "inspected"))
      use a1 <- result.try(named("inspected", decode_value_ref(raw_1)))
      use raw_2 <- result.try(field(members, "arms"))
      use a2 <- result.try(named(
        "arms",
        array(raw_2, fn(value) { decode_guard_arm(value) }),
      ))
      Ok(composition.GuardChoice(a0, a1, a2))
    }
    _ -> fail("unknown ChoiceSkeleton tag")
  }
}

pub fn decode_closed_search_state(
  value: kdl.JsonValue,
) -> Result(composition.ClosedSearchState, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "state",
      "terminals",
      "choices",
      "rejected_connections",
      "missing_supply",
    ]),
  )
  use raw_0 <- result.try(field(members, "state"))
  use a0 <- result.try(named("state", decode_search_state(raw_0)))
  use raw_1 <- result.try(field(members, "terminals"))
  use a1 <- result.try(named(
    "terminals",
    array(raw_1, fn(value) { decode_terminal_coverage(value) }),
  ))
  use raw_2 <- result.try(field(members, "choices"))
  use a2 <- result.try(named(
    "choices",
    array(raw_2, fn(value) { decode_choice_coverage(value) }),
  ))
  use raw_3 <- result.try(field(members, "rejected_connections"))
  use a3 <- result.try(named(
    "rejected_connections",
    array(raw_3, fn(value) { decode_connection_failure(value) }),
  ))
  use raw_4 <- result.try(field(members, "missing_supply"))
  use a4 <- result.try(named(
    "missing_supply",
    array(raw_4, fn(value) { decode_missing_supply(value) }),
  ))
  Ok(composition.ClosedSearchState(a0, a1, a2, a3, a4))
}

pub fn decode_closure_witness(
  value: kdl.JsonValue,
) -> Result(resource.ClosureWitness, DecodeFailure) {
  use members <- result.try(
    object(value, ["explored_markings", "steps", "frontier"]),
  )
  use raw_0 <- result.try(field(members, "explored_markings"))
  use a0 <- result.try(named(
    "explored_markings",
    array(raw_0, fn(value) { decode_marking(value) }),
  ))
  use raw_1 <- result.try(field(members, "steps"))
  use a1 <- result.try(named("steps", integer(raw_1, True)))
  use raw_2 <- result.try(field(members, "frontier"))
  use a2 <- result.try(named(
    "frontier",
    array(raw_2, fn(value) { decode_marking(value) }),
  ))
  Ok(resource.ClosureWitness(a0, a1, a2))
}

pub fn decode_codepoint_range(
  value: kdl.JsonValue,
) -> Result(types.CodepointRange, DecodeFailure) {
  use members <- result.try(object(value, ["first", "last"]))
  use raw_0 <- result.try(field(members, "first"))
  use a0 <- result.try(named("first", integer(raw_0, True)))
  use raw_1 <- result.try(field(members, "last"))
  use a1 <- result.try(named("last", integer(raw_1, True)))
  Ok(types.CodepointRange(a0, a1))
}

pub fn decode_colored_token(
  value: kdl.JsonValue,
) -> Result(resource.ColoredToken, DecodeFailure) {
  use members <- result.try(
    object(value, ["target", "index", "revision", "kind"]),
  )
  use raw_0 <- result.try(field(members, "target"))
  use a0 <- result.try(named("target", text(raw_0, "", "")))
  use raw_1 <- result.try(field(members, "index"))
  use a1 <- result.try(named("index", integer(raw_1, True)))
  use raw_2 <- result.try(field(members, "revision"))
  use a2 <- result.try(named("revision", integer(raw_2, True)))
  use raw_3 <- result.try(field(members, "kind"))
  use a3 <- result.try(named("kind", decode_token_kind(raw_3)))
  Ok(resource.ColoredToken(a0, a1, a2, a3))
}

pub fn decode_composition_closure_witness(
  value: kdl.JsonValue,
) -> Result(composition.CompositionClosureWitness, DecodeFailure) {
  use members <- result.try(object(value, ["input_snapshot", "root", "states"]))
  use raw_0 <- result.try(field(members, "input_snapshot"))
  use a0 <- result.try(named("input_snapshot", decode_composition_input(raw_0)))
  use raw_1 <- result.try(field(members, "root"))
  use a1 <- result.try(named("root", integer(raw_1, True)))
  use raw_2 <- result.try(field(members, "states"))
  use a2 <- result.try(named(
    "states",
    array(raw_2, fn(value) { decode_closed_search_state(value) }),
  ))
  Ok(composition.CompositionClosureWitness(a0, a1, a2))
}

pub fn decode_composition_effect(
  value: kdl.JsonValue,
) -> Result(composition.CompositionEffect, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "PureFunction" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.PureFunction)
    }
    "HttpRequestResponse" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.HttpRequestResponse)
    }
    "DataOnly" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.DataOnly)
    }
    _ -> fail("unknown CompositionEffect tag")
  }
}

pub fn decode_composition_input(
  value: kdl.JsonValue,
) -> Result(composition.CompositionInput, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "identity",
      "revision",
      "basis",
      "signatures",
      "initial_inputs",
      "initial_resources",
      "goal",
      "invocation_domain",
      "allowed_effects",
      "explicit_order",
      "selection_policy",
      "bounds",
    ]),
  )
  use raw_0 <- result.try(field(members, "identity"))
  use a0 <- result.try(named("identity", text(raw_0, "", "")))
  use raw_1 <- result.try(field(members, "revision"))
  use a1 <- result.try(named("revision", text(raw_1, "", "")))
  use raw_2 <- result.try(field(members, "basis"))
  use a2 <- result.try(named("basis", decode_semantic_basis(raw_2)))
  use raw_3 <- result.try(field(members, "signatures"))
  use a3 <- result.try(named(
    "signatures",
    array(raw_3, fn(value) { decode_function_signature(value) }),
  ))
  use raw_4 <- result.try(field(members, "initial_inputs"))
  use a4 <- result.try(named(
    "initial_inputs",
    array(raw_4, fn(value) { decode_initial_input(value) }),
  ))
  use raw_5 <- result.try(field(members, "initial_resources"))
  use a5 <- result.try(named(
    "initial_resources",
    array(raw_5, fn(value) { decode_resource_lot(value) }),
  ))
  use raw_6 <- result.try(field(members, "goal"))
  use a6 <- result.try(named("goal", decode_goal_spec(raw_6)))
  use raw_7 <- result.try(field(members, "invocation_domain"))
  use a7 <- result.try(named(
    "invocation_domain",
    decode_invocation_domain(raw_7),
  ))
  use raw_8 <- result.try(field(members, "allowed_effects"))
  use a8 <- result.try(named(
    "allowed_effects",
    array(raw_8, fn(value) { decode_composition_effect(value) }),
  ))
  use raw_9 <- result.try(field(members, "explicit_order"))
  use a9 <- result.try(named(
    "explicit_order",
    array(raw_9, fn(value) { decode_tuple_2(value) }),
  ))
  use raw_10 <- result.try(field(members, "selection_policy"))
  use a10 <- result.try(named(
    "selection_policy",
    optional(raw_10, fn(value) { decode_selection_policy(value) }),
  ))
  use raw_11 <- result.try(field(members, "bounds"))
  use a11 <- result.try(named("bounds", decode_search_bounds(raw_11)))
  Ok(composition.CompositionInput(
    a0,
    a1,
    a2,
    a3,
    a4,
    a5,
    a6,
    a7,
    a8,
    a9,
    a10,
    a11,
  ))
}

pub fn decode_composition_plan(
  value: kdl.JsonValue,
) -> Result(composition.CompositionPlan, DecodeFailure) {
  use members <- result.try(
    object(value, ["input_identity", "input_revision", "root"]),
  )
  use raw_0 <- result.try(field(members, "input_identity"))
  use a0 <- result.try(named("input_identity", text(raw_0, "", "")))
  use raw_1 <- result.try(field(members, "input_revision"))
  use a1 <- result.try(named("input_revision", text(raw_1, "", "")))
  use raw_2 <- result.try(field(members, "root"))
  use a2 <- result.try(named("root", decode_plan_tree(raw_2)))
  Ok(composition.CompositionPlan(a0, a1, a2))
}

pub fn decode_composition_witness(
  value: kdl.JsonValue,
) -> Result(composition.CompositionWitness, DecodeFailure) {
  use members <- result.try(
    object(value, ["input_snapshot", "initial_membership", "resource_traces"]),
  )
  use raw_0 <- result.try(field(members, "input_snapshot"))
  use a0 <- result.try(named("input_snapshot", decode_composition_input(raw_0)))
  use raw_1 <- result.try(field(members, "initial_membership"))
  use a1 <- result.try(named(
    "initial_membership",
    array(raw_1, fn(value) { decode_tuple_3(value) }),
  ))
  use raw_2 <- result.try(field(members, "resource_traces"))
  use a2 <- result.try(named(
    "resource_traces",
    array(raw_2, fn(value) { decode_resource_trace_certificate(value) }),
  ))
  Ok(composition.CompositionWitness(a0, a1, a2))
}

pub fn decode_connection_failure(
  value: kdl.JsonValue,
) -> Result(composition.ConnectionFailure, DecodeFailure) {
  use members <- result.try(
    object(value, ["value", "destination", "counterexample"]),
  )
  use raw_0 <- result.try(field(members, "value"))
  use a0 <- result.try(named(
    "value",
    optional(raw_0, fn(value) { decode_value_ref(value) }),
  ))
  use raw_1 <- result.try(field(members, "destination"))
  use a1 <- result.try(named("destination", decode_slot_contract(raw_1)))
  use raw_2 <- result.try(field(members, "counterexample"))
  use a2 <- result.try(named(
    "counterexample",
    decode_counterexample_certificate(raw_2),
  ))
  Ok(composition.ConnectionFailure(a0, a1, a2))
}

pub fn decode_field_presence(
  value: kdl.JsonValue,
) -> Result(composition.FieldPresence, DecodeFailure) {
  use members <- result.try(object(value, ["tag"]))
  use raw <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(raw, "", "")))
  case tag {
    "Required" -> Ok(composition.Required)
    "Optional" -> Ok(composition.Optional)
    _ -> fail("unknown FieldPresence tag")
  }
}

pub fn decode_field_constraint(
  value: kdl.JsonValue,
) -> Result(composition.FieldConstraint, DecodeFailure) {
  use members <- result.try(object(value, ["field", "source", "presence"]))
  use raw_field <- result.try(field(members, "field"))
  use name <- result.try(named("field", text(raw_field, "", "")))
  use raw_source <- result.try(field(members, "source"))
  use source <- result.try(named("source", decode_source_constraint(raw_source)))
  use raw_presence <- result.try(field(members, "presence"))
  use presence <- result.try(named(
    "presence",
    decode_field_presence(raw_presence),
  ))
  Ok(composition.FieldConstraint(name, source, presence))
}

pub fn decode_construction_rule(
  value: kdl.JsonValue,
) -> Result(composition.ConstructionRule, DecodeFailure) {
  use members <- result.try(
    object(value, ["identity", "type_ref", "nested_fields", "field_constraints"]),
  )
  use raw_0 <- result.try(field(members, "identity"))
  use a0 <- result.try(named("identity", text(raw_0, "", "")))
  use raw_1 <- result.try(field(members, "type_ref"))
  use a1 <- result.try(named("type_ref", decode_type_ref(raw_1)))
  use raw_2 <- result.try(field(members, "nested_fields"))
  use a2 <- result.try(named(
    "nested_fields",
    array(raw_2, fn(value) { decode_tuple_4(value) }),
  ))
  use raw_3 <- result.try(field(members, "field_constraints"))
  use a3 <- result.try(named(
    "field_constraints",
    array(raw_3, decode_field_constraint),
  ))
  Ok(composition.ConstructionRule(a0, a1, a2, a3))
}

pub fn decode_counterexample_certificate(
  value: kdl.JsonValue,
) -> Result(composition.CounterexampleCertificate, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "basis",
      "source",
      "destination",
      "value",
      "destination_failure",
    ]),
  )
  use raw_0 <- result.try(field(members, "basis"))
  use a0 <- result.try(named("basis", decode_semantic_basis(raw_0)))
  use raw_1 <- result.try(field(members, "source"))
  use a1 <- result.try(named("source", decode_slot_contract(raw_1)))
  use raw_2 <- result.try(field(members, "destination"))
  use a2 <- result.try(named("destination", decode_slot_contract(raw_2)))
  use raw_3 <- result.try(field(members, "value"))
  use a3 <- result.try(named("value", decode_slot_value(raw_3)))
  use raw_4 <- result.try(field(members, "destination_failure"))
  use a4 <- result.try(named("destination_failure", decode_value_failure(raw_4)))
  Ok(composition.CounterexampleCertificate(a0, a1, a2, a3, a4))
}

pub fn decode_declaration_graph(
  value: kdl.JsonValue,
) -> Result(resource.DeclarationGraph, DecodeFailure) {
  use members <- result.try(
    object(value, ["places", "transitions", "edges", "revision"]),
  )
  use raw_0 <- result.try(field(members, "places"))
  use a0 <- result.try(named(
    "places",
    array(raw_0, fn(value) { text(value, "", "") }),
  ))
  use raw_1 <- result.try(field(members, "transitions"))
  use a1 <- result.try(named(
    "transitions",
    array(raw_1, fn(value) { text(value, "", "") }),
  ))
  use raw_2 <- result.try(field(members, "edges"))
  use a2 <- result.try(named(
    "edges",
    array(raw_2, fn(value) { decode_tuple_5(value) }),
  ))
  use raw_3 <- result.try(field(members, "revision"))
  use a3 <- result.try(named("revision", integer(raw_3, True)))
  Ok(resource.DeclarationGraph(a0, a1, a2, a3))
}

pub fn decode_declared_guard(
  value: kdl.JsonValue,
) -> Result(composition.DeclaredGuard, DecodeFailure) {
  use members <- result.try(
    object(value, ["id", "source_type", "path", "kind"]),
  )
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition.GuardId),
  ))
  use raw_1 <- result.try(field(members, "source_type"))
  use a1 <- result.try(named("source_type", decode_type_ref(raw_1)))
  use raw_2 <- result.try(field(members, "path"))
  use a2 <- result.try(named(
    "path",
    array(raw_2, fn(value) { decode_path_step(value) }),
  ))
  use raw_3 <- result.try(field(members, "kind"))
  use a3 <- result.try(named("kind", decode_guard_kind(raw_3)))
  Ok(composition.DeclaredGuard(a0, a1, a2, a3))
}

pub fn decode_definition_ref(
  value: kdl.JsonValue,
) -> Result(types.DefinitionRef, DecodeFailure) {
  use members <- result.try(object(value, ["source", "name"]))
  use raw_0 <- result.try(field(members, "source"))
  use a0 <- result.try(named("source", decode_source_ref(raw_0)))
  use raw_1 <- result.try(field(members, "name"))
  use a1 <- result.try(named("name", text(raw_1, "", "")))
  Ok(types.DefinitionRef(a0, a1))
}

pub fn decode_dfa_spec(
  value: kdl.JsonValue,
) -> Result(types.DfaSpec, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "state_count",
      "initial_state",
      "accepting_states",
      "transitions",
    ]),
  )
  use raw_0 <- result.try(field(members, "state_count"))
  use a0 <- result.try(named("state_count", integer(raw_0, True)))
  use raw_1 <- result.try(field(members, "initial_state"))
  use a1 <- result.try(named("initial_state", integer(raw_1, True)))
  use raw_2 <- result.try(field(members, "accepting_states"))
  use a2 <- result.try(named(
    "accepting_states",
    array(raw_2, fn(value) { integer(value, True) }),
  ))
  use raw_3 <- result.try(field(members, "transitions"))
  use a3 <- result.try(named(
    "transitions",
    array(raw_3, fn(value) { decode_dfa_transition(value) }),
  ))
  Ok(types.DfaSpec(a0, a1, a2, a3))
}

pub fn decode_dfa_transition(
  value: kdl.JsonValue,
) -> Result(types.DfaTransition, DecodeFailure) {
  use members <- result.try(
    object(value, ["from_state", "first", "last", "to_state"]),
  )
  use raw_0 <- result.try(field(members, "from_state"))
  use a0 <- result.try(named("from_state", integer(raw_0, True)))
  use raw_1 <- result.try(field(members, "first"))
  use a1 <- result.try(named("first", integer(raw_1, True)))
  use raw_2 <- result.try(field(members, "last"))
  use a2 <- result.try(named("last", integer(raw_2, True)))
  use raw_3 <- result.try(field(members, "to_state"))
  use a3 <- result.try(named("to_state", integer(raw_3, True)))
  Ok(types.DfaTransition(a0, a1, a2, a3))
}

pub fn decode_domain_bound(
  value: kdl.JsonValue,
) -> Result(resource.DomainBound, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "target_identity",
      "index",
      "revision",
      "max_bindings",
      "max_search_steps",
    ]),
  )
  use raw_0 <- result.try(field(members, "target_identity"))
  use a0 <- result.try(named("target_identity", text(raw_0, "", "")))
  use raw_1 <- result.try(field(members, "index"))
  use a1 <- result.try(named("index", integer(raw_1, True)))
  use raw_2 <- result.try(field(members, "revision"))
  use a2 <- result.try(named("revision", integer(raw_2, True)))
  use raw_3 <- result.try(field(members, "max_bindings"))
  use a3 <- result.try(named("max_bindings", integer(raw_3, True)))
  use raw_4 <- result.try(field(members, "max_search_steps"))
  use a4 <- result.try(named("max_search_steps", integer(raw_4, True)))
  Ok(resource.DomainBound(a0, a1, a2, a3, a4))
}

pub fn decode_effect_point(
  value: kdl.JsonValue,
) -> Result(types.EffectPoint, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "HttpRequestResponse" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.HttpRequestResponse)
    }
    "DataOnly" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.DataOnly)
    }
    _ -> fail("unknown EffectPoint tag")
  }
}

pub fn decode_failure_embedding(
  value: kdl.JsonValue,
) -> Result(composition.FailureEmbedding, DecodeFailure) {
  use members <- result.try(
    object(value, ["id", "origin", "contract", "final_resources"]),
  )
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition.FailureEmbeddingId),
  ))
  use raw_1 <- result.try(field(members, "origin"))
  use a1 <- result.try(named("origin", decode_failure_origin(raw_1)))
  use raw_2 <- result.try(field(members, "contract"))
  use a2 <- result.try(named("contract", decode_slot_contract(raw_2)))
  use raw_3 <- result.try(field(members, "final_resources"))
  use a3 <- result.try(named(
    "final_resources",
    array(raw_3, fn(value) { decode_resource_goal(value) }),
  ))
  Ok(composition.FailureEmbedding(a0, a1, a2, a3))
}

pub fn decode_failure_origin(
  value: kdl.JsonValue,
) -> Result(composition.FailureOrigin, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Function" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["function", "outcome"]))
      use raw_0 <- result.try(field(members, "function"))
      use a0 <- result.try(named("function", decode_function_ref(raw_0)))
      use raw_1 <- result.try(field(members, "outcome"))
      use a1 <- result.try(named(
        "outcome",
        result.map(text(raw_1, "", ""), composition.OutcomeId),
      ))
      Ok(composition.FunctionFailure(a0, a1))
    }
    "Guard" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["guard", "arm"]))
      use raw_0 <- result.try(field(members, "guard"))
      use a0 <- result.try(named(
        "guard",
        result.map(text(raw_0, "", ""), composition.GuardId),
      ))
      use raw_1 <- result.try(field(members, "arm"))
      use a1 <- result.try(named("arm", decode_guard_arm(raw_1)))
      Ok(composition.GuardFailure(a0, a1))
    }
    _ -> fail("unknown FailureOrigin tag")
  }
}

pub fn decode_format_binding(
  value: kdl.JsonValue,
) -> Result(types.FormatBinding, DecodeFailure) {
  use members <- result.try(object(value, ["name", "reference", "rule"]))
  use raw_0 <- result.try(field(members, "name"))
  use a0 <- result.try(named("name", text(raw_0, "", "")))
  use raw_1 <- result.try(field(members, "reference"))
  use a1 <- result.try(named("reference", decode_profile_ref(raw_1)))
  use raw_2 <- result.try(field(members, "rule"))
  use a2 <- result.try(named("rule", decode_format_rule(raw_2)))
  Ok(types.FormatBinding(a0, a1, a2))
}

pub fn decode_format_rule(
  value: kdl.JsonValue,
) -> Result(types.FormatRule, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Literal" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", text(payload, "", "")))
      Ok(types.Literal(decoded))
    }
    "Sequence" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(
        array(payload, fn(item) { decode_format_rule(item) }),
      )
      Ok(types.Sequence(decoded))
    }
    "Optional" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(decode_format_rule(payload))
      Ok(types.Optional(decoded))
    }
    "Labels" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use row <- result.try(
        object(payload, [
          "separator",
          "min_count",
          "max_count",
          "total_max",
          "rule",
        ]),
      )
      use raw_separator <- result.try(field(row, "separator"))
      use separator <- result.try(named(
        "separator",
        text(raw_separator, "", ""),
      ))
      use raw_min <- result.try(field(row, "min_count"))
      use minimum <- result.try(integer(raw_min, True))
      use raw_max <- result.try(field(row, "max_count"))
      use maximum <- result.try(
        optional(raw_max, fn(item) { integer(item, True) }),
      )
      use raw_total <- result.try(field(row, "total_max"))
      use total <- result.try(
        optional(raw_total, fn(item) { integer(item, True) }),
      )
      use raw_rule <- result.try(field(row, "rule"))
      use inner <- result.try(decode_format_rule(raw_rule))
      Ok(types.Labels(separator, minimum, maximum, total, inner))
    }
    "Bounded" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use row <- result.try(object(payload, ["unit", "maximum", "rule"]))
      use raw_unit <- result.try(field(row, "unit"))
      use unit <- result.try(decode_string_length_unit(raw_unit))
      use raw_max <- result.try(field(row, "maximum"))
      use maximum <- result.try(integer(raw_max, True))
      use raw_rule <- result.try(field(row, "rule"))
      use inner <- result.try(decode_format_rule(raw_rule))
      Ok(types.Bounded(unit, maximum, inner))
    }
    "AsciiDfa" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", decode_dfa_spec(payload)))
      Ok(types.AsciiDfa(decoded))
    }
    "Timestamp" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", decode_calendar_rule(payload)))
      Ok(types.Timestamp(decoded))
    }
    "Choice" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        array(payload, fn(value) { decode_format_rule(value) }),
      ))
      Ok(types.Choice(decoded))
    }
    "Identifier" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(
        object(payload, [
          "first_alphabet",
          "rest_alphabet",
          "exact_length",
          "min_length",
          "max_length",
          "forbidden",
        ]),
      )
      use raw_0 <- result.try(field(members, "first_alphabet"))
      use a0 <- result.try(named("first_alphabet", text(raw_0, "", "")))
      use raw_1 <- result.try(field(members, "rest_alphabet"))
      use a1 <- result.try(named("rest_alphabet", text(raw_1, "", "")))
      use raw_2 <- result.try(field(members, "exact_length"))
      use a2 <- result.try(named(
        "exact_length",
        optional(raw_2, fn(value) { integer(value, True) }),
      ))
      use raw_3 <- result.try(field(members, "min_length"))
      use a3 <- result.try(named("min_length", integer(raw_3, True)))
      use raw_4 <- result.try(field(members, "max_length"))
      use a4 <- result.try(named(
        "max_length",
        optional(raw_4, fn(value) { integer(value, True) }),
      ))
      use raw_5 <- result.try(field(members, "forbidden"))
      use a5 <- result.try(named(
        "forbidden",
        array(raw_5, fn(value) { text(value, "", "") }),
      ))
      Ok(types.Identifier(a0, a1, a2, a3, a4, a5))
    }
    "AbsoluteUri" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["max_bytes"]))
      use raw_0 <- result.try(field(members, "max_bytes"))
      use a0 <- result.try(named("max_bytes", integer(raw_0, True)))
      Ok(types.AbsoluteUri(a0))
    }
    "LanguageTag" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["grandfathered"]))
      use raw_0 <- result.try(field(members, "grandfathered"))
      use a0 <- result.try(named(
        "grandfathered",
        array(raw_0, fn(value) { text(value, "", "") }),
      ))
      Ok(types.LanguageTag(a0))
    }
    "Text" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Text)
    }
    "Not" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", decode_format_rule(payload)))
      Ok(types.Not(decoded))
    }
    _ -> fail("unknown FormatRule tag")
  }
}

pub fn decode_function_form(
  value: kdl.JsonValue,
) -> Result(composition.FunctionForm, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Pure" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.Pure)
    }
    "DeclaredTransform" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.DeclaredTransform)
    }
    "Operation" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", decode_definition_ref(payload)))
      Ok(composition.Operation(decoded))
    }
    _ -> fail("unknown FunctionForm tag")
  }
}

pub fn decode_function_ref(
  value: kdl.JsonValue,
) -> Result(composition.FunctionRef, DecodeFailure) {
  use members <- result.try(
    object(value, ["identity", "revision", "content_digest"]),
  )
  use raw_0 <- result.try(field(members, "identity"))
  use a0 <- result.try(named("identity", text(raw_0, "", "")))
  use raw_1 <- result.try(field(members, "revision"))
  use a1 <- result.try(named("revision", text(raw_1, "", "")))
  use raw_2 <- result.try(field(members, "content_digest"))
  use a2 <- result.try(named(
    "content_digest",
    text(raw_2, "", "^[0-9a-f]{64}$"),
  ))
  Ok(composition.FunctionRef(a0, a1, a2))
}

pub fn decode_function_signature(
  value: kdl.JsonValue,
) -> Result(composition.FunctionSignature, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "reference",
      "form",
      "effect",
      "inputs",
      "outcomes",
      "resource_inputs",
      "assumption_ref",
      "handles_failure",
    ]),
  )
  use raw_0 <- result.try(field(members, "reference"))
  use a0 <- result.try(named("reference", decode_function_ref(raw_0)))
  use raw_1 <- result.try(field(members, "form"))
  use a1 <- result.try(named("form", decode_function_form(raw_1)))
  use raw_2 <- result.try(field(members, "effect"))
  use a2 <- result.try(named("effect", decode_composition_effect(raw_2)))
  use raw_3 <- result.try(field(members, "inputs"))
  use a3 <- result.try(named(
    "inputs",
    array(raw_3, fn(value) { decode_input_port(value) }),
  ))
  use raw_4 <- result.try(field(members, "outcomes"))
  use a4 <- result.try(named(
    "outcomes",
    array(raw_4, fn(value) { decode_outcome_contract(value) }),
  ))
  use raw_5 <- result.try(field(members, "resource_inputs"))
  use a5 <- result.try(named(
    "resource_inputs",
    array(raw_5, fn(value) { decode_resource_requirement(value) }),
  ))
  use raw_6 <- result.try(field(members, "assumption_ref"))
  use a6 <- result.try(named("assumption_ref", text(raw_6, "", "")))
  use raw_7 <- result.try(field(members, "handles_failure"))
  use a7 <- result.try(named(
    "handles_failure",
    optional(raw_7, fn(value) { decode_failure_origin(value) }),
  ))
  Ok(composition.FunctionSignature(a0, a1, a2, a3, a4, a5, a6, a7))
}

pub fn decode_goal_port(
  value: kdl.JsonValue,
) -> Result(composition.GoalPort, DecodeFailure) {
  use members <- result.try(
    object(value, ["id", "contract", "source_constraint"]),
  )
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition.GoalPortId),
  ))
  use raw_1 <- result.try(field(members, "contract"))
  use a1 <- result.try(named("contract", decode_slot_contract(raw_1)))
  use raw_2 <- result.try(field(members, "source_constraint"))
  use a2 <- result.try(named(
    "source_constraint",
    decode_source_constraint(raw_2),
  ))
  Ok(composition.GoalPort(a0, a1, a2))
}

pub fn decode_goal_predicate(
  value: kdl.JsonValue,
) -> Result(resource.GoalPredicate, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Not" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", decode_goal_predicate(payload)))
      Ok(resource.GoalNot(decoded))
    }
    "PlaceHasAtLeast" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["place", "count"]))
      use raw_0 <- result.try(field(members, "place"))
      use a0 <- result.try(named("place", text(raw_0, "", "")))
      use raw_1 <- result.try(field(members, "count"))
      use a1 <- result.try(named("count", integer(raw_1, True)))
      Ok(resource.PlaceHasAtLeast(a0, a1))
    }
    "PlaceHasToken" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(
        object(payload, ["place", "target", "index", "revision"]),
      )
      use raw_0 <- result.try(field(members, "place"))
      use a0 <- result.try(named("place", text(raw_0, "", "")))
      use raw_1 <- result.try(field(members, "target"))
      use a1 <- result.try(named("target", text(raw_1, "", "")))
      use raw_2 <- result.try(field(members, "index"))
      use a2 <- result.try(named("index", integer(raw_2, True)))
      use raw_3 <- result.try(field(members, "revision"))
      use a3 <- result.try(named("revision", integer(raw_3, True)))
      Ok(resource.PlaceHasToken(a0, a1, a2, a3))
    }
    "And" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", decode_tuple_6(payload)))
      Ok(resource.GoalAnd(decoded.0, decoded.1))
    }
    "Or" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", decode_tuple_7(payload)))
      Ok(resource.GoalOr(decoded.0, decoded.1))
    }
    _ -> fail("unknown GoalPredicate tag")
  }
}

pub fn decode_goal_spec(
  value: kdl.JsonValue,
) -> Result(composition.GoalSpec, DecodeFailure) {
  use members <- result.try(
    object(value, ["outputs", "failures", "final_resources"]),
  )
  use raw_0 <- result.try(field(members, "outputs"))
  use a0 <- result.try(named(
    "outputs",
    array(raw_0, fn(value) { decode_goal_port(value) }),
  ))
  use raw_1 <- result.try(field(members, "failures"))
  use a1 <- result.try(named(
    "failures",
    array(raw_1, fn(value) { decode_failure_embedding(value) }),
  ))
  use raw_2 <- result.try(field(members, "final_resources"))
  use a2 <- result.try(named(
    "final_resources",
    array(raw_2, fn(value) { decode_resource_goal(value) }),
  ))
  Ok(composition.GoalSpec(a0, a1, a2))
}

pub fn decode_grapheme_property(
  value: kdl.JsonValue,
) -> Result(types.GraphemeProperty, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Other" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Other)
    }
    "Cr" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Cr)
    }
    "Lf" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Lf)
    }
    "Control" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Control)
    }
    "Extend" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Extend)
    }
    "Zwj" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Zwj)
    }
    "RegionalIndicator" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.RegionalIndicator)
    }
    "Prepend" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Prepend)
    }
    "SpacingMark" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.SpacingMark)
    }
    "L" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.L)
    }
    "V" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.V)
    }
    "T" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.T)
    }
    "Lv" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Lv)
    }
    "Lvt" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Lvt)
    }
    _ -> fail("unknown GraphemeProperty tag")
  }
}

pub fn decode_grapheme_range(
  value: kdl.JsonValue,
) -> Result(types.GraphemeRange, DecodeFailure) {
  use members <- result.try(object(value, ["first", "last", "property"]))
  use raw_0 <- result.try(field(members, "first"))
  use a0 <- result.try(named("first", integer(raw_0, True)))
  use raw_1 <- result.try(field(members, "last"))
  use a1 <- result.try(named("last", integer(raw_1, True)))
  use raw_2 <- result.try(field(members, "property"))
  use a2 <- result.try(named("property", decode_grapheme_property(raw_2)))
  Ok(types.GraphemeRange(a0, a1, a2))
}

pub fn decode_grapheme_rules(
  value: kdl.JsonValue,
) -> Result(types.GraphemeRules, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "reference",
      "properties",
      "extended_pictographic",
      "indic_conjunct",
      "component",
      "table_sha256",
      "sources",
    ]),
  )
  use raw_0 <- result.try(field(members, "reference"))
  use a0 <- result.try(named("reference", decode_profile_ref(raw_0)))
  use raw_1 <- result.try(field(members, "properties"))
  use a1 <- result.try(named(
    "properties",
    array(raw_1, fn(value) { decode_grapheme_range(value) }),
  ))
  use raw_2 <- result.try(field(members, "extended_pictographic"))
  use a2 <- result.try(named(
    "extended_pictographic",
    array(raw_2, fn(value) { decode_codepoint_range(value) }),
  ))
  use raw_3 <- result.try(field(members, "indic_conjunct"))
  use a3 <- result.try(named(
    "indic_conjunct",
    array(raw_3, fn(value) { decode_indic_range(value) }),
  ))
  use component <- result.try(
    field(members, "component") |> result.try(decode_grapheme_component),
  )
  use digest <- result.try(
    field(members, "table_sha256")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  use sources <- result.try(
    field(members, "sources")
    |> result.try(fn(value) { array(value, decode_grapheme_source) }),
  )
  Ok(types.GraphemeRules(a0, a1, a2, a3, component, digest, sources))
}

pub fn decode_grapheme_component(
  value: kdl.JsonValue,
) -> Result(types.GraphemeComponent, DecodeFailure) {
  use members <- result.try(
    object(value, ["unicode_version", "uax29_revision", "cluster_profile"]),
  )
  use version <- result.try(
    field(members, "unicode_version")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  use revision <- result.try(
    field(members, "uax29_revision")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  use profile <- result.try(
    field(members, "cluster_profile")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  Ok(types.GraphemeComponent(version, revision, profile))
}

pub fn decode_grapheme_source(
  value: kdl.JsonValue,
) -> Result(types.GraphemeSource, DecodeFailure) {
  use members <- result.try(object(value, ["role", "origin"]))
  use role <- result.try(
    field(members, "role") |> result.try(fn(value) { text(value, "", "") }),
  )
  use origin <- result.try(
    field(members, "origin") |> result.try(decode_origin),
  )
  Ok(types.GraphemeSource(role, origin))
}

pub fn decode_source_identity(
  value: kdl.JsonValue,
) -> Result(types.SourceIdentity, DecodeFailure) {
  use members <- result.try(
    object(value, ["repository", "revision", "path", "content_digest"]),
  )
  use repository <- result.try(
    field(members, "repository")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  use revision <- result.try(
    field(members, "revision") |> result.try(fn(value) { text(value, "", "") }),
  )
  use path <- result.try(
    field(members, "path") |> result.try(fn(value) { text(value, "", "") }),
  )
  use digest <- result.try(
    field(members, "content_digest")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  Ok(types.SourceIdentity(repository, revision, path, digest))
}

pub fn decode_origin(
  value: kdl.JsonValue,
) -> Result(types.Origin, DecodeFailure) {
  use members <- result.try(object(value, ["source", "locator"]))
  use source <- result.try(
    field(members, "source") |> result.try(decode_source_identity),
  )
  use locator <- result.try(
    field(members, "locator")
    |> result.try(fn(value) { array(value, fn(value) { text(value, "", "") }) }),
  )
  Ok(types.Origin(source, locator))
}

pub fn encode_source_identity(
  value: types.SourceIdentity,
) -> Result(kdl.JsonValue, DecodeFailure) {
  Ok(
    kdl.JsonValueObj([
      #("repository", kdl.JsonValueStr(value.repository)),
      #("revision", kdl.JsonValueStr(value.revision)),
      #("path", kdl.JsonValueStr(value.path)),
      #("content_digest", kdl.JsonValueStr(value.content_digest)),
    ]),
  )
}

pub fn encode_origin(
  value: types.Origin,
) -> Result(kdl.JsonValue, DecodeFailure) {
  use source <- result.try(encode_source_identity(value.source))
  Ok(
    kdl.JsonValueObj([
      #("source", source),
      #("locator", kdl.JsonValueArr(list.map(value.locator, kdl.JsonValueStr))),
    ]),
  )
}

pub fn decode_guard_arm(
  value: kdl.JsonValue,
) -> Result(composition.GuardArm, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Present" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.GuardPresent)
    }
    "Absent" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.GuardAbsent)
    }
    "Null" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.GuardNull)
    }
    "UnknownVariant" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.UnknownVariant)
    }
    "Accepted" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.GuardAccepted)
    }
    "Rejected" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.GuardRejected)
    }
    "Variant" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", text(payload, "", "")))
      Ok(composition.GuardVariant(decoded))
    }
    _ -> fail("unknown GuardArm tag")
  }
}

pub fn decode_guard_kind(
  value: kdl.JsonValue,
) -> Result(composition.GuardKind, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Presence" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.Presence)
    }
    "Variants" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.Variants)
    }
    "Validate" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", decode_slot_contract(payload)))
      Ok(composition.Validate(decoded))
    }
    _ -> fail("unknown GuardKind tag")
  }
}

pub fn decode_inclusion_certificate(
  value: kdl.JsonValue,
) -> Result(composition.InclusionCertificate, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "basis",
      "source",
      "destination",
      "root",
      "empty_types",
      "pairs",
    ]),
  )
  use raw_0 <- result.try(field(members, "basis"))
  use a0 <- result.try(named("basis", decode_semantic_basis(raw_0)))
  use raw_1 <- result.try(field(members, "source"))
  use a1 <- result.try(named("source", decode_slot_contract(raw_1)))
  use raw_2 <- result.try(field(members, "destination"))
  use a2 <- result.try(named("destination", decode_slot_contract(raw_2)))
  use raw_3 <- result.try(field(members, "root"))
  use a3 <- result.try(named("root", integer(raw_3, True)))
  use raw_4 <- result.try(field(members, "empty_types"))
  use a4 <- result.try(named(
    "empty_types",
    array(raw_4, fn(value) { decode_type_ref(value) }),
  ))
  use raw_5 <- result.try(field(members, "pairs"))
  use a5 <- result.try(named(
    "pairs",
    array(raw_5, fn(value) { decode_pair_entry(value) }),
  ))
  Ok(composition.InclusionCertificate(a0, a1, a2, a3, a4, a5))
}

pub fn decode_inclusion_rule(
  value: kdl.JsonValue,
) -> Result(composition.InclusionRule, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "EmptySource" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.EmptySource)
    }
    "Boolean" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.InclusionBoolean)
    }
    "IntegerIntersection" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.IntegerIntersection)
    }
    "FiniteStrings" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.FiniteStrings)
    }
    "StringConditions" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.StringConditions)
    }
    "BytesLength" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.BytesLength)
    }
    "Unit" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.InclusionUnit)
    }
    "JsonDomain" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.JsonDomain)
    }
    "PlainObjectDomain" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.PlainObjectDomain)
    }
    "UnfoldSource" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.UnfoldSource)
    }
    "UnfoldDestination" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.UnfoldDestination)
    }
    "Array" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.InclusionArray)
    }
    "Product" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.InclusionProduct)
    }
    "SourceUnion" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.SourceUnion)
    }
    "DestinationUnion" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.DestinationUnion)
    }
    "SourceRecord" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.SourceRecord)
    }
    "DestinationRecord" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.DestinationRecord)
    }
    "ProductTagCases" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.ProductTagCases)
    }
    _ -> fail("unknown InclusionRule tag")
  }
}

pub fn decode_indic_property(
  value: kdl.JsonValue,
) -> Result(types.IndicProperty, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Other" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.IndicOther)
    }
    "Consonant" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Consonant)
    }
    "Extend" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.IndicExtend)
    }
    "Linker" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Linker)
    }
    _ -> fail("unknown IndicProperty tag")
  }
}

pub fn decode_indic_range(
  value: kdl.JsonValue,
) -> Result(types.IndicRange, DecodeFailure) {
  use members <- result.try(object(value, ["first", "last", "property"]))
  use raw_0 <- result.try(field(members, "first"))
  use a0 <- result.try(named("first", integer(raw_0, True)))
  use raw_1 <- result.try(field(members, "last"))
  use a1 <- result.try(named("last", integer(raw_1, True)))
  use raw_2 <- result.try(field(members, "property"))
  use a2 <- result.try(named("property", decode_indic_property(raw_2)))
  Ok(types.IndicRange(a0, a1, a2))
}

pub fn decode_initial_input(
  value: kdl.JsonValue,
) -> Result(composition.InitialInput, DecodeFailure) {
  use members <- result.try(
    object(value, ["id", "contract", "source", "resource"]),
  )
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition.InputId),
  ))
  use raw_1 <- result.try(field(members, "contract"))
  use a1 <- result.try(named("contract", decode_slot_contract(raw_1)))
  use raw_2 <- result.try(field(members, "source"))
  use a2 <- result.try(named("source", decode_initial_source(raw_2)))
  use raw_3 <- result.try(field(members, "resource"))
  use a3 <- result.try(named(
    "resource",
    optional(raw_3, fn(value) {
      result.map(text(value, "", ""), composition.LotId)
    }),
  ))
  Ok(composition.InitialInput(a0, a1, a2, a3))
}

pub fn decode_initial_source(
  value: kdl.JsonValue,
) -> Result(composition.InitialSource, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Argument" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.Argument)
    }
    "SuppliedValue" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", decode_slot_value(payload)))
      Ok(composition.SuppliedValue(decoded))
    }
    _ -> fail("unknown InitialSource tag")
  }
}

pub fn decode_input_binding(
  value: kdl.JsonValue,
) -> Result(resource.InputBinding, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "transition_id",
      "name",
      "place",
      "token_type",
      "identity",
      "provenance",
      "multiplicity",
      "mode",
      "required_revision",
    ]),
  )
  use raw_0 <- result.try(field(members, "transition_id"))
  use a0 <- result.try(named("transition_id", text(raw_0, "", "")))
  use raw_1 <- result.try(field(members, "name"))
  use a1 <- result.try(named("name", text(raw_1, "", "")))
  use raw_2 <- result.try(field(members, "place"))
  use a2 <- result.try(named("place", text(raw_2, "", "")))
  use raw_3 <- result.try(field(members, "token_type"))
  use a3 <- result.try(named("token_type", text(raw_3, "", "")))
  use raw_4 <- result.try(field(members, "identity"))
  use a4 <- result.try(named("identity", text(raw_4, "", "")))
  use raw_5 <- result.try(field(members, "provenance"))
  use a5 <- result.try(named("provenance", text(raw_5, "", "")))
  use raw_6 <- result.try(field(members, "multiplicity"))
  use a6 <- result.try(named("multiplicity", integer(raw_6, True)))
  use raw_7 <- result.try(field(members, "mode"))
  use a7 <- result.try(named("mode", decode_binding_mode(raw_7)))
  use raw_8 <- result.try(field(members, "required_revision"))
  use a8 <- result.try(named("required_revision", integer(raw_8, True)))
  Ok(resource.InputBinding(a0, a1, a2, a3, a4, a5, a6, a7, a8))
}

pub fn decode_input_port(
  value: kdl.JsonValue,
) -> Result(composition.InputPort, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "id",
      "contract",
      "source_constraint",
      "resource_requirement",
    ]),
  )
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition.PortId),
  ))
  use raw_1 <- result.try(field(members, "contract"))
  use a1 <- result.try(named("contract", decode_slot_contract(raw_1)))
  use raw_2 <- result.try(field(members, "source_constraint"))
  use a2 <- result.try(named(
    "source_constraint",
    decode_source_constraint(raw_2),
  ))
  use raw_3 <- result.try(field(members, "resource_requirement"))
  use a3 <- result.try(named(
    "resource_requirement",
    optional(raw_3, fn(value) {
      result.map(text(value, "", ""), composition.RequirementId)
    }),
  ))
  Ok(composition.InputPort(a0, a1, a2, a3))
}

pub fn decode_integer_domain(
  value: kdl.JsonValue,
) -> Result(types.IntegerDomain, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Unbounded" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Unbounded)
    }
    "Inclusive" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["minimum", "maximum"]))
      use raw_0 <- result.try(field(members, "minimum"))
      use a0 <- result.try(named("minimum", integer(raw_0, False)))
      use raw_1 <- result.try(field(members, "maximum"))
      use a1 <- result.try(named("maximum", integer(raw_1, False)))
      Ok(types.IntegerInterval(a0, a1))
    }
    _ -> fail("unknown IntegerDomain tag")
  }
}

pub fn decode_invocation_domain(
  value: kdl.JsonValue,
) -> Result(composition.InvocationDomain, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "identity",
      "revision",
      "sites",
      "permitted_projections",
      "permitted_constructions",
      "permitted_transforms",
      "guards",
    ]),
  )
  use raw_0 <- result.try(field(members, "identity"))
  use a0 <- result.try(named("identity", text(raw_0, "", "")))
  use raw_1 <- result.try(field(members, "revision"))
  use a1 <- result.try(named("revision", text(raw_1, "", "")))
  use raw_2 <- result.try(field(members, "sites"))
  use a2 <- result.try(named(
    "sites",
    array(raw_2, fn(value) { decode_invocation_site(value) }),
  ))
  use raw_3 <- result.try(field(members, "permitted_projections"))
  use a3 <- result.try(named(
    "permitted_projections",
    array(raw_3, fn(value) { decode_permitted_projection(value) }),
  ))
  use raw_4 <- result.try(field(members, "permitted_constructions"))
  use a4 <- result.try(named(
    "permitted_constructions",
    array(raw_4, fn(value) { decode_construction_rule(value) }),
  ))
  use raw_5 <- result.try(field(members, "permitted_transforms"))
  use a5 <- result.try(named(
    "permitted_transforms",
    array(raw_5, fn(value) { decode_function_ref(value) }),
  ))
  use raw_6 <- result.try(field(members, "guards"))
  use a6 <- result.try(named(
    "guards",
    array(raw_6, fn(value) { decode_declared_guard(value) }),
  ))
  Ok(composition.InvocationDomain(a0, a1, a2, a3, a4, a5, a6))
}

pub fn decode_invocation_plan(
  value: kdl.JsonValue,
) -> Result(composition.InvocationPlan, DecodeFailure) {
  use members <- result.try(
    object(value, ["site", "function", "bindings", "resources"]),
  )
  use raw_0 <- result.try(field(members, "site"))
  use a0 <- result.try(named(
    "site",
    result.map(text(raw_0, "", ""), composition.SiteId),
  ))
  use raw_1 <- result.try(field(members, "function"))
  use a1 <- result.try(named("function", decode_function_ref(raw_1)))
  use raw_2 <- result.try(field(members, "bindings"))
  use a2 <- result.try(named(
    "bindings",
    array(raw_2, fn(value) { decode_tuple_8(value) }),
  ))
  use raw_3 <- result.try(field(members, "resources"))
  use a3 <- result.try(named(
    "resources",
    array(raw_3, fn(value) { decode_resource_binding(value) }),
  ))
  Ok(composition.InvocationPlan(a0, a1, a2, a3))
}

pub fn decode_invocation_site(
  value: kdl.JsonValue,
) -> Result(composition.InvocationSite, DecodeFailure) {
  use members <- result.try(object(value, ["id", "function"]))
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition.SiteId),
  ))
  use raw_1 <- result.try(field(members, "function"))
  use a1 <- result.try(named("function", decode_function_ref(raw_1)))
  Ok(composition.InvocationSite(a0, a1))
}

pub fn decode_length_spec(
  value: kdl.JsonValue,
) -> Result(types.LengthSpec, DecodeFailure) {
  use members <- result.try(object(value, ["minimum", "maximum"]))
  use raw_0 <- result.try(field(members, "minimum"))
  use a0 <- result.try(named(
    "minimum",
    optional(raw_0, fn(value) { integer(value, True) }),
  ))
  use raw_1 <- result.try(field(members, "maximum"))
  use a1 <- result.try(named(
    "maximum",
    optional(raw_1, fn(value) { integer(value, True) }),
  ))
  Ok(types.LengthSpec(a0, a1))
}

pub fn decode_marking(
  value: kdl.JsonValue,
) -> Result(resource.Marking, DecodeFailure) {
  use members <- result.try(object(value, ["places"]))
  use raw_0 <- result.try(field(members, "places"))
  use a0 <- result.try(named(
    "places",
    array(raw_0, fn(value) { decode_tuple_9(value) }),
  ))
  Ok(resource.Marking(a0))
}

pub fn decode_missing_supply(
  value: kdl.JsonValue,
) -> Result(composition.MissingSupply, DecodeFailure) {
  use members <- result.try(object(value, ["site", "port", "contract"]))
  use raw_0 <- result.try(field(members, "site"))
  use a0 <- result.try(named(
    "site",
    optional(raw_0, fn(value) {
      result.map(text(value, "", ""), composition.SiteId)
    }),
  ))
  use raw_1 <- result.try(field(members, "port"))
  use a1 <- result.try(named("port", text(raw_1, "", "")))
  use raw_2 <- result.try(field(members, "contract"))
  use a2 <- result.try(named("contract", decode_slot_contract(raw_2)))
  Ok(composition.MissingSupply(a0, a1, a2))
}

pub fn decode_normalized_resource_binding(
  value: kdl.JsonValue,
) -> Result(composition.NormalizedResourceBinding, DecodeFailure) {
  use members <- result.try(
    object(value, ["transition", "lot", "read", "consume", "required_revision"]),
  )
  use raw_0 <- result.try(field(members, "transition"))
  use a0 <- result.try(named("transition", text(raw_0, "", "")))
  use raw_1 <- result.try(field(members, "lot"))
  use a1 <- result.try(named("lot", decode_resource_lot_ref(raw_1)))
  use raw_2 <- result.try(field(members, "read"))
  use a2 <- result.try(named("read", integer(raw_2, True)))
  use raw_3 <- result.try(field(members, "consume"))
  use a3 <- result.try(named("consume", integer(raw_3, True)))
  use raw_4 <- result.try(field(members, "required_revision"))
  use a4 <- result.try(named("required_revision", integer(raw_4, True)))
  Ok(composition.NormalizedResourceBinding(a0, a1, a2, a3, a4))
}

pub fn decode_occurrence_ref(
  value: kdl.JsonValue,
) -> Result(types.OccurrenceRef, DecodeFailure) {
  use members <- result.try(object(value, ["source", "pointer"]))
  use raw_0 <- result.try(field(members, "source"))
  use a0 <- result.try(named("source", decode_source_ref(raw_0)))
  use raw_1 <- result.try(field(members, "pointer"))
  use a1 <- result.try(named(
    "pointer",
    array(raw_1, fn(value) { text(value, "", "") }),
  ))
  Ok(types.OccurrenceRef(a0, a1))
}

pub fn decode_outcome_contract(
  value: kdl.JsonValue,
) -> Result(composition.OutcomeContract, DecodeFailure) {
  use members <- result.try(
    object(value, ["id", "form", "value_ports", "produced_resources"]),
  )
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition.OutcomeId),
  ))
  use raw_1 <- result.try(field(members, "form"))
  use a1 <- result.try(named("form", decode_outcome_form(raw_1)))
  use raw_2 <- result.try(field(members, "value_ports"))
  use a2 <- result.try(named(
    "value_ports",
    array(raw_2, fn(value) { decode_output_port(value) }),
  ))
  use raw_3 <- result.try(field(members, "produced_resources"))
  use a3 <- result.try(named(
    "produced_resources",
    array(raw_3, fn(value) { decode_resource_production(value) }),
  ))
  Ok(composition.OutcomeContract(a0, a1, a2, a3))
}

pub fn decode_outcome_form(
  value: kdl.JsonValue,
) -> Result(composition.OutcomeForm, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Success" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.Success)
    }
    "DeclaredFailure" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.DeclaredFailure)
    }
    _ -> fail("unknown OutcomeForm tag")
  }
}

pub fn decode_output_port(
  value: kdl.JsonValue,
) -> Result(composition.OutputPort, DecodeFailure) {
  use members <- result.try(
    object(value, ["id", "contract", "resource_production"]),
  )
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition.PortId),
  ))
  use raw_1 <- result.try(field(members, "contract"))
  use a1 <- result.try(named("contract", decode_slot_contract(raw_1)))
  use raw_2 <- result.try(field(members, "resource_production"))
  use a2 <- result.try(named(
    "resource_production",
    optional(raw_2, fn(value) {
      result.map(text(value, "", ""), composition.ProductionId)
    }),
  ))
  Ok(composition.OutputPort(a0, a1, a2))
}

pub fn decode_pair_entry(
  value: kdl.JsonValue,
) -> Result(composition.PairEntry, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "pair",
      "source_shape",
      "destination_shape",
      "rule",
      "children",
    ]),
  )
  use raw_0 <- result.try(field(members, "pair"))
  use a0 <- result.try(named("pair", decode_type_pair(raw_0)))
  use raw_1 <- result.try(field(members, "source_shape"))
  use a1 <- result.try(named("source_shape", decode_declared_type_shape(raw_1)))
  use raw_2 <- result.try(field(members, "destination_shape"))
  use a2 <- result.try(named(
    "destination_shape",
    decode_declared_type_shape(raw_2),
  ))
  use raw_3 <- result.try(field(members, "rule"))
  use a3 <- result.try(named("rule", decode_inclusion_rule(raw_3)))
  use raw_4 <- result.try(field(members, "children"))
  use a4 <- result.try(named(
    "children",
    array(raw_4, fn(value) { integer(value, True) }),
  ))
  Ok(composition.PairEntry(a0, a1, a2, a3, a4))
}

pub fn decode_path_step(
  value: kdl.JsonValue,
) -> Result(types.PathStep, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Field" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", text(payload, "", "")))
      Ok(types.Field(decoded))
    }
    "Index" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", integer(payload, True)))
      Ok(types.Index(decoded))
    }
    "Variant" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", text(payload, "", "")))
      Ok(types.Variant(decoded))
    }
    _ -> fail("unknown PathStep tag")
  }
}

pub fn decode_permitted_projection(
  value: kdl.JsonValue,
) -> Result(composition.PermittedProjection, DecodeFailure) {
  use members <- result.try(object(value, ["source_type", "path"]))
  use raw_0 <- result.try(field(members, "source_type"))
  use a0 <- result.try(named("source_type", decode_type_ref(raw_0)))
  use raw_1 <- result.try(field(members, "path"))
  use a1 <- result.try(named(
    "path",
    array(raw_1, fn(value) { decode_path_step(value) }),
  ))
  Ok(composition.PermittedProjection(a0, a1))
}

pub fn decode_plan_node(
  value: kdl.JsonValue,
) -> Result(composition.PlanNode, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Return" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", decode_return_plan(payload)))
      Ok(composition.Return(decoded))
    }
    "Invoke" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(
        object(payload, ["invocation", "arms", "empty_outcomes"]),
      )
      use raw_0 <- result.try(field(members, "invocation"))
      use a0 <- result.try(named("invocation", decode_invocation_plan(raw_0)))
      use raw_1 <- result.try(field(members, "arms"))
      use a1 <- result.try(named(
        "arms",
        array(raw_1, fn(value) { decode_tuple_12(value) }),
      ))
      use raw_2 <- result.try(field(members, "empty_outcomes"))
      use a2 <- result.try(named(
        "empty_outcomes",
        array(raw_2, fn(value) {
          result.map(text(value, "", ""), composition.OutcomeId)
        }),
      ))
      Ok(composition.Invoke(a0, a1, a2))
    }
    "Guard" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["guard", "inspected", "arms"]))
      use raw_0 <- result.try(field(members, "guard"))
      use a0 <- result.try(named(
        "guard",
        result.map(text(raw_0, "", ""), composition.GuardId),
      ))
      use raw_1 <- result.try(field(members, "inspected"))
      use a1 <- result.try(named("inspected", decode_value_ref(raw_1)))
      use raw_2 <- result.try(field(members, "arms"))
      use a2 <- result.try(named(
        "arms",
        array(raw_2, fn(value) { decode_tuple_13(value) }),
      ))
      Ok(composition.Guard(a0, a1, a2))
    }
    _ -> fail("unknown PlanNode tag")
  }
}

pub fn decode_plan_tree(
  value: kdl.JsonValue,
) -> Result(composition.PlanTree, DecodeFailure) {
  use members <- result.try(object(value, ["rank", "node"]))
  use raw_0 <- result.try(field(members, "rank"))
  use a0 <- result.try(named("rank", integer(raw_0, True)))
  use raw_1 <- result.try(field(members, "node"))
  use a1 <- result.try(named("node", decode_plan_node(raw_1)))
  Ok(composition.PlanTree(a0, a1))
}

pub fn decode_producer_ref(
  value: kdl.JsonValue,
) -> Result(composition.ProducerRef, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Initial" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        result.map(text(payload, "", ""), composition.InputId),
      ))
      Ok(composition.Initial(decoded))
    }
    "InvocationOutcome" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["site", "outcome", "port"]))
      use raw_0 <- result.try(field(members, "site"))
      use a0 <- result.try(named(
        "site",
        result.map(text(raw_0, "", ""), composition.SiteId),
      ))
      use raw_1 <- result.try(field(members, "outcome"))
      use a1 <- result.try(named(
        "outcome",
        result.map(text(raw_1, "", ""), composition.OutcomeId),
      ))
      use raw_2 <- result.try(field(members, "port"))
      use a2 <- result.try(named(
        "port",
        result.map(text(raw_2, "", ""), composition.PortId),
      ))
      Ok(composition.InvocationOutcome(a0, a1, a2))
    }
    _ -> fail("unknown ProducerRef tag")
  }
}

pub fn decode_profile_ref(
  value: kdl.JsonValue,
) -> Result(types.ProfileRef, DecodeFailure) {
  use members <- result.try(
    object(value, ["identity", "revision", "content_digest"]),
  )
  use raw_0 <- result.try(field(members, "identity"))
  use a0 <- result.try(named("identity", text(raw_0, "", "")))
  use raw_1 <- result.try(field(members, "revision"))
  use a1 <- result.try(named("revision", text(raw_1, "", "")))
  use raw_2 <- result.try(field(members, "content_digest"))
  use a2 <- result.try(named(
    "content_digest",
    text(raw_2, "", "^[0-9a-f]{64}$"),
  ))
  Ok(types.ProfileRef(a0, a1, a2))
}

pub fn decode_projection_assumption(
  value: kdl.JsonValue,
) -> Result(validation.ProjectionAssumption, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Present" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        array(payload, fn(value) { decode_path_step(value) }),
      ))
      Ok(validation.Present(decoded))
    }
    "NonNull" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        array(payload, fn(value) { decode_path_step(value) }),
      ))
      Ok(validation.NonNull(decoded))
    }
    "Variant" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["path", "tag"]))
      use raw_0 <- result.try(field(members, "path"))
      use a0 <- result.try(named(
        "path",
        array(raw_0, fn(value) { decode_path_step(value) }),
      ))
      use raw_1 <- result.try(field(members, "tag"))
      use a1 <- result.try(named("tag", text(raw_1, "", "")))
      Ok(validation.Variant(a0, a1))
    }
    "IndexPresent" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["path", "index"]))
      use raw_0 <- result.try(field(members, "path"))
      use a0 <- result.try(named(
        "path",
        array(raw_0, fn(value) { decode_path_step(value) }),
      ))
      use raw_1 <- result.try(field(members, "index"))
      use a1 <- result.try(named("index", integer(raw_1, True)))
      Ok(validation.IndexPresent(a0, a1))
    }
    _ -> fail("unknown ProjectionAssumption tag")
  }
}

pub fn decode_projection_certificate(
  value: kdl.JsonValue,
) -> Result(validation.ProjectionCertificate, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "profile",
      "source_refs",
      "source",
      "path",
      "assumptions",
      "destination",
    ]),
  )
  use raw_0 <- result.try(field(members, "profile"))
  use a0 <- result.try(named("profile", decode_profile_ref(raw_0)))
  use raw_1 <- result.try(field(members, "source_refs"))
  use a1 <- result.try(named(
    "source_refs",
    array(raw_1, fn(value) { decode_source_ref(value) }),
  ))
  use raw_2 <- result.try(field(members, "source"))
  use a2 <- result.try(named("source", decode_slot_contract(raw_2)))
  use raw_3 <- result.try(field(members, "path"))
  use a3 <- result.try(named(
    "path",
    array(raw_3, fn(value) { decode_path_step(value) }),
  ))
  use raw_4 <- result.try(field(members, "assumptions"))
  use a4 <- result.try(named(
    "assumptions",
    array(raw_4, fn(value) { decode_projection_assumption(value) }),
  ))
  use raw_5 <- result.try(field(members, "destination"))
  use a5 <- result.try(named("destination", decode_slot_contract(raw_5)))
  Ok(validation.ProjectionCertificate(a0, a1, a2, a3, a4, a5))
}

pub fn decode_raw_composition(
  value: kdl.JsonValue,
) -> Result(composition.RawComposition, DecodeFailure) {
  use members <- result.try(object(value, ["plan", "witness", "selection"]))
  use raw_0 <- result.try(field(members, "plan"))
  use a0 <- result.try(named("plan", decode_composition_plan(raw_0)))
  use raw_1 <- result.try(field(members, "witness"))
  use a1 <- result.try(named("witness", decode_composition_witness(raw_1)))
  use raw_2 <- result.try(field(members, "selection"))
  use a2 <- result.try(named("selection", decode_selection_evidence(raw_2)))
  Ok(composition.RawComposition(a0, a1, a2))
}

pub fn decode_reachability_witness(
  value: kdl.JsonValue,
) -> Result(resource.ReachabilityWitness, DecodeFailure) {
  use members <- result.try(object(value, ["path", "final_marking"]))
  use raw_0 <- result.try(field(members, "path"))
  use a0 <- result.try(named(
    "path",
    array(raw_0, fn(value) { text(value, "", "") }),
  ))
  use raw_1 <- result.try(field(members, "final_marking"))
  use a1 <- result.try(named("final_marking", decode_marking(raw_1)))
  Ok(resource.ReachabilityWitness(a0, a1))
}

pub fn decode_resource_binding(
  value: kdl.JsonValue,
) -> Result(composition.ResourceBinding, DecodeFailure) {
  use members <- result.try(object(value, ["requirement", "lot", "inclusion"]))
  use raw_0 <- result.try(field(members, "requirement"))
  use a0 <- result.try(named(
    "requirement",
    result.map(text(raw_0, "", ""), composition.RequirementId),
  ))
  use raw_1 <- result.try(field(members, "lot"))
  use a1 <- result.try(named("lot", decode_resource_lot_ref(raw_1)))
  use raw_2 <- result.try(field(members, "inclusion"))
  use a2 <- result.try(named("inclusion", decode_inclusion_certificate(raw_2)))
  Ok(composition.ResourceBinding(a0, a1, a2))
}

pub fn decode_resource_bounds(
  value: kdl.JsonValue,
) -> Result(composition.ResourceBounds, DecodeFailure) {
  use members <- result.try(
    object(value, ["max_bindings", "max_search_steps", "max_tokens"]),
  )
  use raw_0 <- result.try(field(members, "max_bindings"))
  use a0 <- result.try(named("max_bindings", integer(raw_0, True)))
  use raw_1 <- result.try(field(members, "max_search_steps"))
  use a1 <- result.try(named("max_search_steps", integer(raw_1, True)))
  use raw_2 <- result.try(field(members, "max_tokens"))
  use a2 <- result.try(named("max_tokens", integer(raw_2, True)))
  Ok(composition.ResourceBounds(a0, a1, a2))
}

pub fn decode_resource_correspondence(
  value: kdl.JsonValue,
) -> Result(composition.ResourceCorrespondence, DecodeFailure) {
  use members <- result.try(
    object(value, ["lots", "values", "normalized_bindings", "execution_order"]),
  )
  use raw_0 <- result.try(field(members, "lots"))
  use a0 <- result.try(named(
    "lots",
    array(raw_0, fn(value) { decode_resource_lot_correspondence(value) }),
  ))
  use raw_1 <- result.try(field(members, "values"))
  use a1 <- result.try(named(
    "values",
    array(raw_1, fn(value) { decode_value_correspondence(value) }),
  ))
  use raw_2 <- result.try(field(members, "normalized_bindings"))
  use a2 <- result.try(named(
    "normalized_bindings",
    array(raw_2, fn(value) { decode_normalized_resource_binding(value) }),
  ))
  use raw_3 <- result.try(field(members, "execution_order"))
  use a3 <- result.try(named(
    "execution_order",
    array(raw_3, fn(value) { text(value, "", "") }),
  ))
  Ok(composition.ResourceCorrespondence(a0, a1, a2, a3))
}

pub fn decode_resource_goal(
  value: kdl.JsonValue,
) -> Result(composition.ResourceGoal, DecodeFailure) {
  use members <- result.try(object(value, ["lot", "multiplicity", "revision"]))
  use raw_0 <- result.try(field(members, "lot"))
  use a0 <- result.try(named("lot", decode_resource_lot_ref(raw_0)))
  use raw_1 <- result.try(field(members, "multiplicity"))
  use a1 <- result.try(named("multiplicity", integer(raw_1, True)))
  use raw_2 <- result.try(field(members, "revision"))
  use a2 <- result.try(named("revision", integer(raw_2, True)))
  Ok(composition.ResourceGoal(a0, a1, a2))
}

pub fn decode_resource_identity_constraint(
  value: kdl.JsonValue,
) -> Result(composition.ResourceIdentityConstraint, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Any" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.AnyResource)
    }
    "Exactly" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        decode_resource_producer(payload),
      ))
      Ok(composition.Exactly(decoded))
    }
    _ -> fail("unknown ResourceIdentityConstraint tag")
  }
}

pub fn decode_resource_lot(
  value: kdl.JsonValue,
) -> Result(composition.ResourceLot, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "id",
      "token_type",
      "producer",
      "revision",
      "quantity",
      "provenance",
    ]),
  )
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition.LotId),
  ))
  use raw_1 <- result.try(field(members, "token_type"))
  use a1 <- result.try(named("token_type", decode_type_ref(raw_1)))
  use raw_2 <- result.try(field(members, "producer"))
  use a2 <- result.try(named("producer", decode_resource_producer(raw_2)))
  use raw_3 <- result.try(field(members, "revision"))
  use a3 <- result.try(named("revision", integer(raw_3, True)))
  use raw_4 <- result.try(field(members, "quantity"))
  use a4 <- result.try(named("quantity", integer(raw_4, True)))
  use raw_5 <- result.try(field(members, "provenance"))
  use a5 <- result.try(named("provenance", text(raw_5, "", "")))
  Ok(composition.ResourceLot(a0, a1, a2, a3, a4, a5))
}

pub fn decode_resource_lot_correspondence(
  value: kdl.JsonValue,
) -> Result(composition.ResourceLotCorrespondence, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "lot",
      "place",
      "producer",
      "token_target",
      "token_type",
      "revision",
      "quantity",
      "provenance",
    ]),
  )
  use raw_0 <- result.try(field(members, "lot"))
  use a0 <- result.try(named("lot", decode_resource_lot_ref(raw_0)))
  use raw_1 <- result.try(field(members, "place"))
  use a1 <- result.try(named("place", text(raw_1, "", "")))
  use raw_2 <- result.try(field(members, "producer"))
  use a2 <- result.try(named("producer", decode_resource_producer(raw_2)))
  use raw_3 <- result.try(field(members, "token_target"))
  use a3 <- result.try(named("token_target", text(raw_3, "", "")))
  use raw_4 <- result.try(field(members, "token_type"))
  use a4 <- result.try(named("token_type", text(raw_4, "", "")))
  use raw_5 <- result.try(field(members, "revision"))
  use a5 <- result.try(named("revision", integer(raw_5, True)))
  use raw_6 <- result.try(field(members, "quantity"))
  use a6 <- result.try(named("quantity", integer(raw_6, True)))
  use raw_7 <- result.try(field(members, "provenance"))
  use a7 <- result.try(named("provenance", text(raw_7, "", "")))
  Ok(composition.ResourceLotCorrespondence(a0, a1, a2, a3, a4, a5, a6, a7))
}

pub fn decode_resource_lot_ref(
  value: kdl.JsonValue,
) -> Result(composition.ResourceLotRef, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Initial" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        result.map(text(payload, "", ""), composition.LotId),
      ))
      Ok(composition.InitialLot(decoded))
    }
    "Produced" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(
        object(payload, ["site", "outcome", "production"]),
      )
      use raw_0 <- result.try(field(members, "site"))
      use a0 <- result.try(named(
        "site",
        result.map(text(raw_0, "", ""), composition.SiteId),
      ))
      use raw_1 <- result.try(field(members, "outcome"))
      use a1 <- result.try(named(
        "outcome",
        result.map(text(raw_1, "", ""), composition.OutcomeId),
      ))
      use raw_2 <- result.try(field(members, "production"))
      use a2 <- result.try(named(
        "production",
        result.map(text(raw_2, "", ""), composition.ProductionId),
      ))
      Ok(composition.ProducedLot(a0, a1, a2))
    }
    _ -> fail("unknown ResourceLotRef tag")
  }
}

pub fn decode_resource_producer(
  value: kdl.JsonValue,
) -> Result(composition.ResourceProducer, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Initial" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["identity", "revision"]))
      use raw_0 <- result.try(field(members, "identity"))
      use a0 <- result.try(named("identity", text(raw_0, "", "")))
      use raw_1 <- result.try(field(members, "revision"))
      use a1 <- result.try(named("revision", text(raw_1, "", "")))
      Ok(composition.InitialResource(a0, a1))
    }
    "InvocationOutcome" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["site", "outcome"]))
      use raw_0 <- result.try(field(members, "site"))
      use a0 <- result.try(named(
        "site",
        result.map(text(raw_0, "", ""), composition.SiteId),
      ))
      use raw_1 <- result.try(field(members, "outcome"))
      use a1 <- result.try(named(
        "outcome",
        result.map(text(raw_1, "", ""), composition.OutcomeId),
      ))
      Ok(composition.OutcomeResource(a0, a1))
    }
    _ -> fail("unknown ResourceProducer tag")
  }
}

pub fn decode_resource_production(
  value: kdl.JsonValue,
) -> Result(composition.ResourceProduction, DecodeFailure) {
  use members <- result.try(
    object(value, ["id", "token_type", "revision", "quantity", "provenance"]),
  )
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition.ProductionId),
  ))
  use raw_1 <- result.try(field(members, "token_type"))
  use a1 <- result.try(named("token_type", decode_type_ref(raw_1)))
  use raw_2 <- result.try(field(members, "revision"))
  use a2 <- result.try(named("revision", integer(raw_2, True)))
  use raw_3 <- result.try(field(members, "quantity"))
  use a3 <- result.try(named("quantity", integer(raw_3, True)))
  use raw_4 <- result.try(field(members, "provenance"))
  use a4 <- result.try(named("provenance", text(raw_4, "", "")))
  Ok(composition.ResourceProduction(a0, a1, a2, a3, a4))
}

pub fn decode_resource_requirement(
  value: kdl.JsonValue,
) -> Result(composition.ResourceRequirement, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "id",
      "token_type",
      "mode",
      "multiplicity",
      "required_revision",
      "identity",
    ]),
  )
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition.RequirementId),
  ))
  use raw_1 <- result.try(field(members, "token_type"))
  use a1 <- result.try(named("token_type", decode_type_ref(raw_1)))
  use raw_2 <- result.try(field(members, "mode"))
  use a2 <- result.try(named("mode", decode_binding_mode(raw_2)))
  use raw_3 <- result.try(field(members, "multiplicity"))
  use a3 <- result.try(named("multiplicity", integer(raw_3, True)))
  use raw_4 <- result.try(field(members, "required_revision"))
  use a4 <- result.try(named("required_revision", integer(raw_4, True)))
  use raw_5 <- result.try(field(members, "identity"))
  use a5 <- result.try(named(
    "identity",
    decode_resource_identity_constraint(raw_5),
  ))
  Ok(composition.ResourceRequirement(a0, a1, a2, a3, a4, a5))
}

pub fn decode_resource_trace_certificate(
  value: kdl.JsonValue,
) -> Result(composition.ResourceTraceCertificate, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "trace",
      "lowering",
      "correspondence",
      "reachability",
      "acyclicity",
      "value_sources",
    ]),
  )
  use raw_0 <- result.try(field(members, "trace"))
  use a0 <- result.try(named("trace", decode_branch_trace(raw_0)))
  use raw_1 <- result.try(field(members, "lowering"))
  use a1 <- result.try(named("lowering", decode_solver_input(raw_1)))
  use raw_2 <- result.try(field(members, "correspondence"))
  use a2 <- result.try(named(
    "correspondence",
    decode_resource_correspondence(raw_2),
  ))
  use raw_3 <- result.try(field(members, "reachability"))
  use a3 <- result.try(named("reachability", decode_reachability_witness(raw_3)))
  use raw_4 <- result.try(field(members, "acyclicity"))
  use a4 <- result.try(named("acyclicity", decode_acyclic_witness(raw_4)))
  use raw_5 <- result.try(field(members, "value_sources"))
  use a5 <- result.try(named(
    "value_sources",
    array(raw_5, fn(value) { decode_tuple_14(value) }),
  ))
  Ok(composition.ResourceTraceCertificate(a0, a1, a2, a3, a4, a5))
}

pub fn decode_return_plan(
  value: kdl.JsonValue,
) -> Result(composition.ReturnPlan, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Success" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        array(payload, fn(value) { decode_tuple_15(value) }),
      ))
      Ok(composition.ReturnSuccess(decoded))
    }
    "Failure" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["embedding", "value"]))
      use raw_0 <- result.try(field(members, "embedding"))
      use a0 <- result.try(named(
        "embedding",
        result.map(text(raw_0, "", ""), composition.FailureEmbeddingId),
      ))
      use raw_1 <- result.try(field(members, "value"))
      use a1 <- result.try(named("value", decode_binding_expr(raw_1)))
      Ok(composition.ReturnFailure(a0, a1))
    }
    _ -> fail("unknown ReturnPlan tag")
  }
}

pub fn decode_search_bounds(
  value: kdl.JsonValue,
) -> Result(composition.SearchBounds, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "max_expanded_states",
      "max_binding_candidates",
      "max_type_obligations",
      "max_branch_nodes",
      "resource_bounds",
      "max_sample_length",
    ]),
  )
  use raw_0 <- result.try(field(members, "max_expanded_states"))
  use a0 <- result.try(named("max_expanded_states", integer(raw_0, True)))
  use raw_1 <- result.try(field(members, "max_binding_candidates"))
  use a1 <- result.try(named("max_binding_candidates", integer(raw_1, True)))
  use raw_2 <- result.try(field(members, "max_type_obligations"))
  use a2 <- result.try(named("max_type_obligations", integer(raw_2, True)))
  use raw_3 <- result.try(field(members, "max_branch_nodes"))
  use a3 <- result.try(named("max_branch_nodes", integer(raw_3, True)))
  use raw_4 <- result.try(field(members, "resource_bounds"))
  use a4 <- result.try(named(
    "resource_bounds",
    optional(raw_4, fn(value) { decode_resource_bounds(value) }),
  ))
  use raw_5 <- result.try(field(members, "max_sample_length"))
  use a5 <- result.try(named("max_sample_length", integer(raw_5, True)))
  Ok(composition.SearchBounds(a0, a1, a2, a3, a4, a5))
}

pub fn decode_search_state(
  value: kdl.JsonValue,
) -> Result(composition.SearchState, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "available",
      "used_sites",
      "used_guards",
      "facts",
      "trace",
      "pending_failure",
    ]),
  )
  use raw_0 <- result.try(field(members, "available"))
  use a0 <- result.try(named(
    "available",
    array(raw_0, fn(value) { decode_available_value(value) }),
  ))
  use raw_1 <- result.try(field(members, "used_sites"))
  use a1 <- result.try(named(
    "used_sites",
    array(raw_1, fn(value) {
      result.map(text(value, "", ""), composition.SiteId)
    }),
  ))
  use raw_2 <- result.try(field(members, "used_guards"))
  use a2 <- result.try(named(
    "used_guards",
    array(raw_2, fn(value) {
      result.map(text(value, "", ""), composition.GuardId)
    }),
  ))
  use raw_3 <- result.try(field(members, "facts"))
  use a3 <- result.try(named(
    "facts",
    array(raw_3, fn(value) { decode_branch_fact(value) }),
  ))
  use raw_4 <- result.try(field(members, "trace"))
  use a4 <- result.try(named(
    "trace",
    array(raw_4, fn(value) { decode_trace_step(value) }),
  ))
  use raw_5 <- result.try(field(members, "pending_failure"))
  use a5 <- result.try(named(
    "pending_failure",
    optional(raw_5, fn(value) { decode_failure_origin(value) }),
  ))
  Ok(composition.SearchState(a0, a1, a2, a3, a4, a5))
}

pub fn decode_selection_evidence(
  value: kdl.JsonValue,
) -> Result(composition.SelectionEvidence, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "AnyFeasible" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.AnyFeasibleEvidence)
    }
    "Unique" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["closure", "canonical_plan"]))
      use raw_0 <- result.try(field(members, "closure"))
      use a0 <- result.try(named(
        "closure",
        decode_composition_closure_witness(raw_0),
      ))
      use raw_1 <- result.try(field(members, "canonical_plan"))
      use a1 <- result.try(named("canonical_plan", text(raw_1, "", "")))
      Ok(composition.Unique(a0, a1))
    }
    _ -> fail("unknown SelectionEvidence tag")
  }
}

pub fn decode_selection_policy(
  value: kdl.JsonValue,
) -> Result(composition.SelectionPolicy, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "RequireUnique" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.RequireUnique)
    }
    "AnyFeasible" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.AnyFeasible)
    }
    _ -> fail("unknown SelectionPolicy tag")
  }
}

pub fn decode_semantic_basis(
  value: kdl.JsonValue,
) -> Result(composition.SemanticBasis, DecodeFailure) {
  use members <- result.try(object(value, ["profile", "sources"]))
  use raw_0 <- result.try(field(members, "profile"))
  use a0 <- result.try(named("profile", decode_semantic_profile(raw_0)))
  use raw_1 <- result.try(field(members, "sources"))
  use a1 <- result.try(named(
    "sources",
    array(raw_1, fn(value) { decode_source_ref(value) }),
  ))
  Ok(composition.SemanticBasis(a0, a1))
}

pub fn decode_semantic_obligation(
  value: kdl.JsonValue,
) -> Result(types.SemanticObligation, DecodeFailure) {
  use members <- result.try(object(value, ["type_ref", "value_path", "reason"]))
  use reference <- result.try(
    field(members, "type_ref") |> result.try(decode_type_ref),
  )
  use path <- result.try(
    field(members, "value_path")
    |> result.try(fn(value) { array(value, decode_path_step) }),
  )
  use reason <- result.try(
    field(members, "reason") |> result.try(decode_semantic_reason),
  )
  Ok(types.SemanticObligation(reference, path, reason))
}

pub fn decode_semantic_reason(
  value: kdl.JsonValue,
) -> Result(types.SemanticReason, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag <- result.try(
    field(members, "tag") |> result.try(fn(value) { text(value, "", "") }),
  )
  let payload = fn() {
    field(members, "value") |> result.try(fn(value) { text(value, "", "") })
  }
  case tag {
    "MissingGraphemeRules" -> Ok(types.MissingGraphemeRulesReason)
    "MissingBytesPolicy" -> Ok(types.MissingBytesPolicyReason)
    "DecimalNotAdmitted" -> Ok(types.DecimalNotAdmittedReason)
    "IntegerBound" -> Ok(types.IntegerBoundReason)
    "MissingTagModel" -> Ok(types.MissingTagModelReason)
    "UnresolvedType" -> Ok(types.UnresolvedTypeReason)
    "MembershipBound" -> Ok(types.MembershipBoundReason)
    "UnknownFormat" -> result.map(payload(), types.UnknownFormatReason)
    "UnknownIntegerDomain" ->
      result.map(payload(), types.UnknownIntegerDomainReason)
    "UnknownWrapper" -> result.map(payload(), types.UnknownWrapperReason)
    "WrapperPayload" -> result.map(payload(), types.WrapperPayloadReason)
    "UnknownSealedTag" -> result.map(payload(), types.UnknownSealedTagReason)
    "OpaqueType" -> result.map(payload(), types.OpaqueTypeReason)
    _ -> fail("unknown SemanticReason tag")
  }
}

pub fn decode_slot_contract(
  value: kdl.JsonValue,
) -> Result(types.SlotContract, DecodeFailure) {
  use members <- result.try(object(value, ["type_ref", "required", "nullable"]))
  use raw_0 <- result.try(field(members, "type_ref"))
  use a0 <- result.try(named("type_ref", decode_type_ref(raw_0)))
  use raw_1 <- result.try(field(members, "required"))
  use a1 <- result.try(named("required", boolean(raw_1)))
  use raw_2 <- result.try(field(members, "nullable"))
  use a2 <- result.try(named("nullable", boolean(raw_2)))
  Ok(types.SlotContract(a0, a1, a2))
}

pub fn decode_slot_value(
  value: kdl.JsonValue,
) -> Result(types.SlotValue(kdl.JsonValue), DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Absent" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Absent)
    }
    "Null" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Null)
    }
    "Present" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", exact(payload)))
      Ok(types.Present(decoded))
    }
    _ -> fail("unknown SlotValue tag")
  }
}

pub fn decode_solver_input(
  value: kdl.JsonValue,
) -> Result(resource.SolverInput, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "places",
      "transitions",
      "bindings",
      "goal",
      "graph",
      "marking",
      "bound",
    ]),
  )
  use raw_0 <- result.try(field(members, "places"))
  use a0 <- result.try(named(
    "places",
    array(raw_0, fn(value) { decode_typed_place(value) }),
  ))
  use raw_1 <- result.try(field(members, "transitions"))
  use a1 <- result.try(named(
    "transitions",
    array(raw_1, fn(value) { decode_typed_transition(value) }),
  ))
  use raw_2 <- result.try(field(members, "bindings"))
  use a2 <- result.try(named(
    "bindings",
    array(raw_2, fn(value) { decode_input_binding(value) }),
  ))
  use raw_3 <- result.try(field(members, "goal"))
  use a3 <- result.try(named("goal", decode_goal_predicate(raw_3)))
  use raw_4 <- result.try(field(members, "graph"))
  use a4 <- result.try(named("graph", decode_declaration_graph(raw_4)))
  use raw_5 <- result.try(field(members, "marking"))
  use a5 <- result.try(named("marking", decode_marking(raw_5)))
  use raw_6 <- result.try(field(members, "bound"))
  use a6 <- result.try(named("bound", decode_domain_bound(raw_6)))
  Ok(resource.SolverInput(a0, a1, a2, a3, a4, a5, a6))
}

pub fn decode_source_constraint(
  value: kdl.JsonValue,
) -> Result(composition.SourceConstraint, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "AnyCompatible" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.AnyCompatible)
    }
    "InitialOnly" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["input", "path"]))
      use raw_0 <- result.try(field(members, "input"))
      use a0 <- result.try(named(
        "input",
        result.map(text(raw_0, "", ""), composition.InputId),
      ))
      use raw_1 <- result.try(field(members, "path"))
      use a1 <- result.try(named("path", array(raw_1, decode_path_step)))
      Ok(composition.InitialOnly(a0, a1))
    }
    "ProducedBy" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(
        object(payload, ["site", "outcome", "port", "path"]),
      )
      use raw_0 <- result.try(field(members, "site"))
      use a0 <- result.try(named(
        "site",
        result.map(text(raw_0, "", ""), composition.SiteId),
      ))
      use raw_1 <- result.try(field(members, "outcome"))
      use a1 <- result.try(named(
        "outcome",
        result.map(text(raw_1, "", ""), composition.OutcomeId),
      ))
      use raw_2 <- result.try(field(members, "port"))
      use a2 <- result.try(named(
        "port",
        result.map(text(raw_2, "", ""), composition.PortId),
      ))
      use raw_3 <- result.try(field(members, "path"))
      use a3 <- result.try(named("path", array(raw_3, decode_path_step)))
      Ok(composition.ProducedBy(a0, a1, a2, a3))
    }
    _ -> fail("unknown SourceConstraint tag")
  }
}

pub fn decode_source_ref(
  value: kdl.JsonValue,
) -> Result(types.SourceRef, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "repository",
      "revision",
      "path",
      "content_digest",
      "document_id",
      "declared_revision",
    ]),
  )
  use raw_0 <- result.try(field(members, "repository"))
  use a0 <- result.try(named("repository", text(raw_0, "", "")))
  use raw_1 <- result.try(field(members, "revision"))
  use a1 <- result.try(named("revision", text(raw_1, "", "")))
  use raw_2 <- result.try(field(members, "path"))
  use a2 <- result.try(named("path", text(raw_2, "", "")))
  use raw_3 <- result.try(field(members, "content_digest"))
  use a3 <- result.try(named(
    "content_digest",
    text(raw_3, "", "^[0-9a-f]{64}$"),
  ))
  use raw_4 <- result.try(field(members, "document_id"))
  use a4 <- result.try(named("document_id", text(raw_4, "", "")))
  use raw_5 <- result.try(field(members, "declared_revision"))
  use a5 <- result.try(named(
    "declared_revision",
    optional(raw_5, fn(value) { integer(value, False) }),
  ))
  Ok(types.SourceRef(a0, a1, a2, a3, a4, a5))
}

pub fn decode_string_length_unit(
  value: kdl.JsonValue,
) -> Result(types.StringLengthUnit, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Utf8Bytes" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Utf8Bytes)
    }
    "UnicodeScalars" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.UnicodeScalars)
    }
    "Graphemes" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Graphemes)
    }
    _ -> fail("unknown StringLengthUnit tag")
  }
}

pub fn decode_terminal_assessment(
  value: kdl.JsonValue,
) -> Result(composition.TerminalAssessment, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Feasible" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        decode_resource_trace_certificate(payload),
      ))
      Ok(composition.Feasible(decoded))
    }
    "EmptyValues" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        array(payload, fn(value) { decode_producer_ref(value) }),
      ))
      Ok(composition.EmptyValues(decoded))
    }
    "Unknown" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        array(payload, fn(value) { decode_unresolved_obligation(value) }),
      ))
      Ok(composition.TerminalUnknown(decoded))
    }
    "ResourceUnreachable" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(
        object(payload, ["trace", "lowering", "correspondence", "closure"]),
      )
      use raw_0 <- result.try(field(members, "trace"))
      use a0 <- result.try(named("trace", decode_branch_trace(raw_0)))
      use raw_1 <- result.try(field(members, "lowering"))
      use a1 <- result.try(named("lowering", decode_solver_input(raw_1)))
      use raw_2 <- result.try(field(members, "correspondence"))
      use a2 <- result.try(named(
        "correspondence",
        decode_resource_correspondence(raw_2),
      ))
      use raw_3 <- result.try(field(members, "closure"))
      use a3 <- result.try(named("closure", decode_closure_witness(raw_3)))
      Ok(composition.ResourceUnreachable(a0, a1, a2, a3))
    }
    "RejectedLowering" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["trace", "reason"]))
      use raw_0 <- result.try(field(members, "trace"))
      use a0 <- result.try(named("trace", decode_branch_trace(raw_0)))
      use raw_1 <- result.try(field(members, "reason"))
      use a1 <- result.try(named("reason", text(raw_1, "", "")))
      Ok(composition.RejectedLowering(a0, a1))
    }
    _ -> fail("unknown TerminalAssessment tag")
  }
}

pub fn decode_terminal_coverage(
  value: kdl.JsonValue,
) -> Result(composition.TerminalCoverage, DecodeFailure) {
  use members <- result.try(object(value, ["terminal", "assessment"]))
  use raw_0 <- result.try(field(members, "terminal"))
  use a0 <- result.try(named("terminal", decode_return_plan(raw_0)))
  use raw_1 <- result.try(field(members, "assessment"))
  use a1 <- result.try(named("assessment", decode_terminal_assessment(raw_1)))
  Ok(composition.TerminalCoverage(a0, a1))
}

pub fn decode_token_kind(
  value: kdl.JsonValue,
) -> Result(resource.TokenKind, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Input" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(resource.TokenInput)
    }
    "Output" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(resource.TokenOutput)
    }
    "Failure" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(resource.TokenFailure)
    }
    "Effect" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(resource.TokenEffect)
    }
    "Observation" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(resource.TokenObservation)
    }
    "Accepted" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(resource.TokenAccepted)
    }
    _ -> fail("unknown TokenKind tag")
  }
}

pub fn decode_trace_step(
  value: kdl.JsonValue,
) -> Result(composition.TraceStep, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "Invocation" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["invocation", "outcome"]))
      use raw_0 <- result.try(field(members, "invocation"))
      use a0 <- result.try(named("invocation", decode_invocation_plan(raw_0)))
      use raw_1 <- result.try(field(members, "outcome"))
      use a1 <- result.try(named(
        "outcome",
        result.map(text(raw_1, "", ""), composition.OutcomeId),
      ))
      Ok(composition.InvocationStep(a0, a1))
    }
    "Guard" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["guard", "inspected", "arm"]))
      use raw_0 <- result.try(field(members, "guard"))
      use a0 <- result.try(named(
        "guard",
        result.map(text(raw_0, "", ""), composition.GuardId),
      ))
      use raw_1 <- result.try(field(members, "inspected"))
      use a1 <- result.try(named("inspected", decode_value_ref(raw_1)))
      use raw_2 <- result.try(field(members, "arm"))
      use a2 <- result.try(named("arm", decode_guard_arm(raw_2)))
      Ok(composition.GuardStep(a0, a1, a2))
    }
    _ -> fail("unknown TraceStep tag")
  }
}

pub fn decode_type_obligation(
  value: kdl.JsonValue,
) -> Result(composition.TypeObligation, DecodeFailure) {
  use members <- result.try(object(value, ["pair", "path", "reason"]))
  use raw_0 <- result.try(field(members, "pair"))
  use a0 <- result.try(named("pair", decode_type_pair(raw_0)))
  use raw_1 <- result.try(field(members, "path"))
  use a1 <- result.try(named(
    "path",
    array(raw_1, fn(value) { decode_path_step(value) }),
  ))
  use raw_2 <- result.try(field(members, "reason"))
  use a2 <- result.try(named("reason", decode_type_obligation_reason(raw_2)))
  Ok(composition.TypeObligation(a0, a1, a2))
}

pub fn decode_type_obligation_reason(
  value: kdl.JsonValue,
) -> Result(composition.TypeObligationReason, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "ConstraintImplication" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.ConstraintImplication)
    }
    "Presence" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.TypePresence)
    }
    "UnionRemainder" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.UnionRemainder)
    }
    "Inhabitation" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.TypeInhabitation)
    }
    "ObligationBoundExhausted" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.ObligationBoundExhausted)
    }
    "Meaning" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        array(payload, fn(value) { decode_semantic_obligation(value) }),
      ))
      Ok(composition.TypeMeaning(decoded))
    }
    "ExtraField" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", text(payload, "", "")))
      Ok(composition.ExtraField(decoded))
    }
    _ -> fail("unknown TypeObligationReason tag")
  }
}

pub fn decode_type_pair(
  value: kdl.JsonValue,
) -> Result(composition.TypePair, DecodeFailure) {
  use members <- result.try(
    object(value, ["source", "destination", "source_tag"]),
  )
  use raw_0 <- result.try(field(members, "source"))
  use a0 <- result.try(named("source", decode_slot_contract(raw_0)))
  use raw_1 <- result.try(field(members, "destination"))
  use a1 <- result.try(named("destination", decode_slot_contract(raw_1)))
  use raw_2 <- result.try(field(members, "source_tag"))
  use a2 <- result.try(named(
    "source_tag",
    optional(raw_2, fn(value) { text(value, "", "") }),
  ))
  Ok(composition.TypePair(a0, a1, a2))
}

pub fn decode_type_ref(
  value: kdl.JsonValue,
) -> Result(types.TypeRef, DecodeFailure) {
  use members <- result.try(
    object(value, ["source", "definition_name", "pointer"]),
  )
  use raw_0 <- result.try(field(members, "source"))
  use a0 <- result.try(named("source", decode_source_ref(raw_0)))
  use raw_1 <- result.try(field(members, "definition_name"))
  use a1 <- result.try(named("definition_name", text(raw_1, "", "")))
  use raw_2 <- result.try(field(members, "pointer"))
  use a2 <- result.try(named(
    "pointer",
    array(raw_2, fn(value) { text(value, "", "") }),
  ))
  Ok(types.TypeRef(a0, a1, a2))
}

pub fn decode_typed_place(
  value: kdl.JsonValue,
) -> Result(resource.TypedPlace, DecodeFailure) {
  use members <- result.try(
    object(value, ["identity", "token_type", "revision"]),
  )
  use raw_0 <- result.try(field(members, "identity"))
  use a0 <- result.try(named("identity", text(raw_0, "", "")))
  use raw_1 <- result.try(field(members, "token_type"))
  use a1 <- result.try(named("token_type", text(raw_1, "", "")))
  use raw_2 <- result.try(field(members, "revision"))
  use a2 <- result.try(named("revision", integer(raw_2, True)))
  Ok(resource.TypedPlace(a0, a1, a2))
}

pub fn decode_typed_transition(
  value: kdl.JsonValue,
) -> Result(resource.TypedTransition, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "identity",
      "input_places",
      "output_places",
      "failure_places",
      "revision",
    ]),
  )
  use raw_0 <- result.try(field(members, "identity"))
  use a0 <- result.try(named("identity", text(raw_0, "", "")))
  use raw_1 <- result.try(field(members, "input_places"))
  use a1 <- result.try(named(
    "input_places",
    array(raw_1, fn(value) { text(value, "", "") }),
  ))
  use raw_2 <- result.try(field(members, "output_places"))
  use a2 <- result.try(named(
    "output_places",
    array(raw_2, fn(value) { text(value, "", "") }),
  ))
  use raw_3 <- result.try(field(members, "failure_places"))
  use a3 <- result.try(named(
    "failure_places",
    array(raw_3, fn(value) { text(value, "", "") }),
  ))
  use raw_4 <- result.try(field(members, "revision"))
  use a4 <- result.try(named("revision", integer(raw_4, True)))
  Ok(resource.TypedTransition(a0, a1, a2, a3, a4))
}

pub fn decode_unknown_reason(
  value: kdl.JsonValue,
) -> Result(resource.UnknownReason, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "BindingBoundExhausted" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", integer(payload, True)))
      Ok(resource.BindingBoundExhausted(decoded))
    }
    "SearchStepBoundExhausted" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", integer(payload, True)))
      Ok(resource.SearchStepBoundExhausted(decoded))
    }
    _ -> fail("unknown UnknownReason tag")
  }
}

pub fn decode_unresolved_obligation(
  value: kdl.JsonValue,
) -> Result(composition.UnresolvedObligation, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "BranchInhabitation" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.BranchInhabitation)
    }
    "StateBoundExhausted" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.StateBoundExhausted)
    }
    "BindingBoundExhausted" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.BindingBoundExhausted)
    }
    "BranchBoundExhausted" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.BranchBoundExhausted)
    }
    "UnresolvedUniqueness" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition.UnresolvedUniqueness)
    }
    "Meaning" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        array(payload, fn(value) { decode_semantic_obligation(value) }),
      ))
      Ok(composition.UnresolvedMeaning(decoded))
    }
    "ResourceSolverUnknown" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", decode_unknown_reason(payload)))
      Ok(composition.ResourceSolverUnknown(decoded))
    }
    "Type" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["value", "obligations"]))
      use raw_0 <- result.try(field(members, "value"))
      use a0 <- result.try(named(
        "value",
        optional(raw_0, fn(value) { decode_value_ref(value) }),
      ))
      use raw_1 <- result.try(field(members, "obligations"))
      use a1 <- result.try(named(
        "obligations",
        array(raw_1, fn(value) { decode_type_obligation(value) }),
      ))
      Ok(composition.UnresolvedTypeObligation(a0, a1))
    }
    "Inhabitation" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["producer", "contract"]))
      use raw_0 <- result.try(field(members, "producer"))
      use a0 <- result.try(named("producer", decode_producer_ref(raw_0)))
      use raw_1 <- result.try(field(members, "contract"))
      use a1 <- result.try(named("contract", decode_slot_contract(raw_1)))
      Ok(composition.Inhabitation(a0, a1))
    }
    "ResourceCapacityBound" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["required", "limit"]))
      use raw_0 <- result.try(field(members, "required"))
      use a0 <- result.try(named("required", integer(raw_0, True)))
      use raw_1 <- result.try(field(members, "limit"))
      use a1 <- result.try(named("limit", integer(raw_1, True)))
      Ok(composition.ResourceCapacityBound(a0, a1))
    }
    _ -> fail("unknown UnresolvedObligation tag")
  }
}

pub fn decode_value_correspondence(
  value: kdl.JsonValue,
) -> Result(composition.ValueCorrespondence, DecodeFailure) {
  use members <- result.try(
    object(value, ["producer", "place", "token_target", "revision"]),
  )
  use raw_0 <- result.try(field(members, "producer"))
  use a0 <- result.try(named("producer", decode_producer_ref(raw_0)))
  use raw_1 <- result.try(field(members, "place"))
  use a1 <- result.try(named("place", text(raw_1, "", "")))
  use raw_2 <- result.try(field(members, "token_target"))
  use a2 <- result.try(named("token_target", text(raw_2, "", "")))
  use raw_3 <- result.try(field(members, "revision"))
  use a3 <- result.try(named("revision", integer(raw_3, True)))
  Ok(composition.ValueCorrespondence(a0, a1, a2, a3))
}

pub fn decode_value_ref(
  value: kdl.JsonValue,
) -> Result(composition.ValueRef, DecodeFailure) {
  use members <- result.try(object(value, ["producer", "path"]))
  use raw_0 <- result.try(field(members, "producer"))
  use a0 <- result.try(named("producer", decode_producer_ref(raw_0)))
  use raw_1 <- result.try(field(members, "path"))
  use a1 <- result.try(named(
    "path",
    array(raw_1, fn(value) { decode_path_step(value) }),
  ))
  Ok(composition.ValueRef(a0, a1))
}

fn decode_declared_type_shape(
  _value: kdl.JsonValue,
) -> Result(types.TypeShape, DecodeFailure) {
  fail("canonical TypeShape snapshot is not supported")
}

pub fn decode_value_failure(
  value: kdl.JsonValue,
) -> Result(types.ValueFailure, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "type_ref",
      "definition_ref",
      "origin",
      "value_path",
      "condition",
      "observed",
      "reference_trace",
    ]),
  )
  use reference <- result.try(
    field(members, "type_ref") |> result.try(decode_type_ref),
  )
  use definition <- result.try(
    field(members, "definition_ref") |> result.try(decode_definition_ref),
  )
  use origin <- result.try(
    field(members, "origin") |> result.try(decode_occurrence_ref),
  )
  use path <- result.try(
    field(members, "value_path")
    |> result.try(fn(value) { array(value, decode_path_step) }),
  )
  use condition <- result.try(
    field(members, "condition") |> result.try(decode_value_condition),
  )
  use observed <- result.try(
    field(members, "observed") |> result.try(decode_slot_value),
  )
  use trace <- result.try(
    field(members, "reference_trace")
    |> result.try(fn(value) { array(value, decode_type_ref) }),
  )
  Ok(types.ValueFailure(
    reference,
    definition,
    origin,
    path,
    condition,
    observed,
    trace,
  ))
}

pub fn encode_value_failure(
  value: types.ValueFailure,
) -> Result(kdl.JsonValue, DecodeFailure) {
  let types.ValueFailure(
    reference,
    definition,
    origin,
    path,
    condition,
    observed,
    trace,
  ) = value
  use reference <- result.try(encode_type_ref(reference))
  use definition <- result.try(encode_definition_ref(definition))
  use origin <- result.try(encode_occurrence_ref(origin))
  use path <- result.try(result.map(
    list.try_map(path, encode_path_step),
    kdl.JsonValueArr,
  ))
  use condition <- result.try(encode_value_condition(condition))
  use observed <- result.try(encode_slot_value(observed))
  use trace <- result.try(result.map(
    list.try_map(trace, encode_type_ref),
    kdl.JsonValueArr,
  ))
  Ok(
    kdl.JsonValueObj([
      #("type_ref", reference),
      #("definition_ref", definition),
      #("origin", origin),
      #("value_path", path),
      #("condition", condition),
      #("observed", observed),
      #("reference_trace", trace),
    ]),
  )
}

fn decode_tuple_1(
  value: kdl.JsonValue,
) -> Result(#(String, composition.BindingExpr), DecodeFailure) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(0, text(v0, "", "")))
      use a1 <- result.try(at(1, decode_binding_expr(v1)))
      Ok(#(a0, a1))
    }
    _ -> fail("exact tuple arity")
  }
}

fn decode_tuple_2(
  value: kdl.JsonValue,
) -> Result(#(composition.SiteId, composition.SiteId), DecodeFailure) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(
        0,
        result.map(text(v0, "", ""), composition.SiteId),
      ))
      use a1 <- result.try(at(
        1,
        result.map(text(v1, "", ""), composition.SiteId),
      ))
      Ok(#(a0, a1))
    }
    _ -> fail("exact tuple arity")
  }
}

fn decode_tuple_3(
  value: kdl.JsonValue,
) -> Result(
  #(composition.InputId, types.SlotValue(kdl.JsonValue)),
  DecodeFailure,
) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(
        0,
        result.map(text(v0, "", ""), composition.InputId),
      ))
      use a1 <- result.try(at(1, decode_slot_value(v1)))
      Ok(#(a0, a1))
    }
    _ -> fail("exact tuple arity")
  }
}

fn decode_tuple_4(
  value: kdl.JsonValue,
) -> Result(#(String, String), DecodeFailure) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(0, text(v0, "", "")))
      use a1 <- result.try(at(1, text(v1, "", "")))
      Ok(#(a0, a1))
    }
    _ -> fail("exact tuple arity")
  }
}

fn decode_tuple_5(
  value: kdl.JsonValue,
) -> Result(#(String, String), DecodeFailure) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(0, text(v0, "", "")))
      use a1 <- result.try(at(1, text(v1, "", "")))
      Ok(#(a0, a1))
    }
    _ -> fail("exact tuple arity")
  }
}

fn decode_tuple_6(
  value: kdl.JsonValue,
) -> Result(#(resource.GoalPredicate, resource.GoalPredicate), DecodeFailure) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(0, decode_goal_predicate(v0)))
      use a1 <- result.try(at(1, decode_goal_predicate(v1)))
      Ok(#(a0, a1))
    }
    _ -> fail("exact tuple arity")
  }
}

fn decode_tuple_7(
  value: kdl.JsonValue,
) -> Result(#(resource.GoalPredicate, resource.GoalPredicate), DecodeFailure) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(0, decode_goal_predicate(v0)))
      use a1 <- result.try(at(1, decode_goal_predicate(v1)))
      Ok(#(a0, a1))
    }
    _ -> fail("exact tuple arity")
  }
}

fn decode_tuple_8(
  value: kdl.JsonValue,
) -> Result(#(composition.PortId, composition.BindingExpr), DecodeFailure) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(
        0,
        result.map(text(v0, "", ""), composition.PortId),
      ))
      use a1 <- result.try(at(1, decode_binding_expr(v1)))
      Ok(#(a0, a1))
    }
    _ -> fail("exact tuple arity")
  }
}

fn decode_tuple_9(
  value: kdl.JsonValue,
) -> Result(#(String, List(resource.ColoredToken)), DecodeFailure) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(0, text(v0, "", "")))
      use a1 <- result.try(at(
        1,
        array(v1, fn(value) { decode_colored_token(value) }),
      ))
      Ok(#(a0, a1))
    }
    _ -> fail("exact tuple arity")
  }
}

fn decode_tuple_12(
  value: kdl.JsonValue,
) -> Result(#(composition.OutcomeId, composition.PlanTree), DecodeFailure) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(
        0,
        result.map(text(v0, "", ""), composition.OutcomeId),
      ))
      use a1 <- result.try(at(1, decode_plan_tree(v1)))
      Ok(#(a0, a1))
    }
    _ -> fail("exact tuple arity")
  }
}

fn decode_tuple_13(
  value: kdl.JsonValue,
) -> Result(#(composition.GuardArm, composition.PlanTree), DecodeFailure) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(0, decode_guard_arm(v0)))
      use a1 <- result.try(at(1, decode_plan_tree(v1)))
      Ok(#(a0, a1))
    }
    _ -> fail("exact tuple arity")
  }
}

fn decode_tuple_14(
  value: kdl.JsonValue,
) -> Result(
  #(composition.ProducerRef, types.SlotValue(kdl.JsonValue)),
  DecodeFailure,
) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(0, decode_producer_ref(v0)))
      use a1 <- result.try(at(1, decode_slot_value(v1)))
      Ok(#(a0, a1))
    }
    _ -> fail("exact tuple arity")
  }
}

fn decode_tuple_15(
  value: kdl.JsonValue,
) -> Result(#(composition.GoalPortId, composition.BindingExpr), DecodeFailure) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(
        0,
        result.map(text(v0, "", ""), composition.GoalPortId),
      ))
      use a1 <- result.try(at(1, decode_binding_expr(v1)))
      Ok(#(a0, a1))
    }
    _ -> fail("exact tuple arity")
  }
}

fn fail(reason: String) -> Result(a, DecodeFailure) {
  Error(DecodeFailure([], reason))
}

fn named(
  name: String,
  value: Result(a, DecodeFailure),
) -> Result(a, DecodeFailure) {
  result.map_error(value, fn(failure) {
    case failure {
      DecodeFailure(path, reason) -> DecodeFailure([name, ..path], reason)
      ProfileFailure(_) -> failure
      UnknownField(path, field) -> UnknownField([name, ..path], field)
      UnknownTag(path, tag) -> UnknownTag([name, ..path], tag)
      SyntaxFailure(path, reason) -> SyntaxFailure([name, ..path], reason)
      UnsupportedSchema(_) -> failure
    }
  })
}

fn at(index: Int, value: Result(a, DecodeFailure)) -> Result(a, DecodeFailure) {
  named(int.to_string(index), value)
}

fn field(
  members: List(#(String, kdl.JsonValue)),
  key: String,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case list.key_find(members, key) {
    Ok(value) -> Ok(value)
    Error(_) -> fail("missing " <> key)
  }
}

fn tagged(
  value: kdl.JsonValue,
) -> Result(List(#(String, kdl.JsonValue)), DecodeFailure) {
  case value {
    kdl.JsonValueObj(members) ->
      case duplicate(members) {
        True -> fail("duplicate object member")
        False -> Ok(members)
      }
    _ -> fail("object required")
  }
}

fn duplicate(members: List(#(String, kdl.JsonValue))) -> Bool {
  case members {
    [] -> False
    [first, ..rest] ->
      list.any(rest, fn(member) { member.0 == first.0 }) || duplicate(rest)
  }
}

fn object(
  value: kdl.JsonValue,
  keys: List(String),
) -> Result(List(#(String, kdl.JsonValue)), DecodeFailure) {
  use members <- result.try(tagged(value))
  case list.find(members, fn(member) { !list.contains(keys, member.0) }) {
    Ok(member) -> Error(UnknownField([], member.0))
    Error(_) ->
      case
        list.find(keys, fn(key) {
          !list.any(members, fn(member) { member.0 == key })
        })
      {
        Ok(key) -> Error(UnknownField([], key))
        Error(_) -> Ok(members)
      }
  }
}

fn optional(
  value: kdl.JsonValue,
  decoder: fn(kdl.JsonValue) -> Result(a, DecodeFailure),
) -> Result(Option(a), DecodeFailure) {
  case value {
    kdl.JsonValueNull -> Ok(None)
    _ -> result.map(decoder(value), Some)
  }
}

fn array(
  value: kdl.JsonValue,
  decoder: fn(kdl.JsonValue) -> Result(a, DecodeFailure),
) -> Result(List(a), DecodeFailure) {
  case value {
    kdl.JsonValueArr(items) ->
      list.try_map(
        list.index_map(items, fn(item, index) { #(item, index) }),
        fn(entry) { at(entry.1, decoder(entry.0)) },
      )
    _ -> fail("array required")
  }
}

fn boolean(value: kdl.JsonValue) -> Result(Bool, DecodeFailure) {
  case value {
    kdl.JsonValueBool(flag) -> Ok(flag)
    _ -> fail("boolean required")
  }
}

fn integer(value: kdl.JsonValue, natural: Bool) -> Result(Int, DecodeFailure) {
  case value {
    kdl.JsonValueStr(text) ->
      case int.parse(text) {
        Ok(number) ->
          case int.to_string(number) == text && { !natural || number >= 0 } {
            True -> Ok(number)
            False -> fail("canonical decimal integer")
          }
        Error(_) -> fail("decimal integer required")
      }
    _ -> fail("integer must be a decimal string")
  }
}

fn text(
  value: kdl.JsonValue,
  constant: String,
  pattern: String,
) -> Result(String, DecodeFailure) {
  case value {
    kdl.JsonValueStr(text) -> {
      let valid_pattern = case pattern {
        "" -> True
        "^[0-9a-f]{64}$" ->
          string.byte_size(text) == 64
          && list.all(string.to_graphemes(text), fn(char) {
            string.contains("0123456789abcdef", char)
          })
        "^(0|[1-9][0-9]*)$" ->
          case integer(value, True) {
            Ok(_) -> True
            _ -> False
          }
        "^(0|-?[1-9][0-9]*)$" ->
          case integer(value, False) {
            Ok(_) -> True
            _ -> False
          }
        _ -> False
      }
      case { constant == "" || constant == text } && valid_pattern {
        True -> Ok(text)
        False -> fail("string constraint")
      }
    }
    _ -> fail("string required")
  }
}

fn exact(value: kdl.JsonValue) -> Result(kdl.JsonValue, DecodeFailure) {
  result.map_error(values.decode_exact(value), fn(_) {
    DecodeFailure([], "invalid ExactJson")
  })
}

fn encode_element_contract(
  value: types.ElementContract,
) -> Result(kdl.JsonValue, DecodeFailure) {
  use type_ref <- result.try(encode_type_ref(value.type_ref))
  Ok(
    kdl.JsonValueObj([
      #("type_ref", type_ref),
      #("nullable", kdl.JsonValueBool(value.nullable)),
    ]),
  )
}

pub fn encode_array_spec(
  value: types.ArraySpec,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.ArraySpec(v0, v1, v2) -> {
      use e0 <- result.try(encode_element_contract(v0))
      use e1 <- result.try(case v1 {
        None -> Ok(kdl.JsonValueNull)
        Some(item) -> Ok(kdl.JsonValueStr(int.to_string(item)))
      })
      use e2 <- result.try(case v2 {
        None -> Ok(kdl.JsonValueNull)
        Some(item) -> Ok(kdl.JsonValueStr(int.to_string(item)))
      })
      Ok(
        kdl.JsonValueObj([
          #("item", e0),
          #("min_length", e1),
          #("max_length", e2),
        ]),
      )
    }
  }
}

pub fn encode_boolean_spec(
  value: types.BooleanSpec,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.BooleanSpec(v0, v1) -> {
      use e0 <- result.try(case v0 {
        None -> Ok(kdl.JsonValueNull)
        Some(item) -> Ok(kdl.JsonValueBool(item))
      })
      use e1 <- result.try(case v1 {
        None -> Ok(kdl.JsonValueNull)
        Some(item) -> Ok(kdl.JsonValueBool(item))
      })
      Ok(kdl.JsonValueObj([#("const_value", e0), #("default_value", e1)]))
    }
  }
}

pub fn encode_calendar_rule(
  value: types.CalendarRule,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.CalendarRule(v0, v1, v2, v3) -> {
      use e0 <- result.try(Ok(kdl.JsonValueBool(v0)))
      use e1 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v1))))
      use e2 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v2))))
      use e3 <- result.try(Ok(kdl.JsonValueBool(v3)))
      Ok(
        kdl.JsonValueObj([
          #("allow_second_60", e0),
          #("minimum_year", e1),
          #("maximum_year", e2),
          #("rejectUtcYearOutsideRange", e3),
        ]),
      )
    }
  }
}

pub fn encode_codepoint_range(
  value: types.CodepointRange,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.CodepointRange(v0, v1) -> {
      use e0 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v0))))
      use e1 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v1))))
      Ok(kdl.JsonValueObj([#("first", e0), #("last", e1)]))
    }
  }
}

pub fn encode_field_presence(
  value: composition.FieldPresence,
) -> Result(kdl.JsonValue, DecodeFailure) {
  let tag = case value {
    composition.Required -> "Required"
    composition.Optional -> "Optional"
  }
  Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr(tag))]))
}

pub fn encode_field_constraint(
  value: composition.FieldConstraint,
) -> Result(kdl.JsonValue, DecodeFailure) {
  use source <- result.try(encode_source_constraint(value.source))
  use presence <- result.try(encode_field_presence(value.presence))
  Ok(
    kdl.JsonValueObj([
      #("field", kdl.JsonValueStr(value.field)),
      #("source", source),
      #("presence", presence),
    ]),
  )
}

pub fn encode_definition_ref(
  value: types.DefinitionRef,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.DefinitionRef(v0, v1) -> {
      use e0 <- result.try(encode_source_ref(v0))
      use e1 <- result.try(Ok(kdl.JsonValueStr(v1)))
      Ok(kdl.JsonValueObj([#("source", e0), #("name", e1)]))
    }
  }
}

pub fn encode_dfa_spec(
  value: types.DfaSpec,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.DfaSpec(v0, v1, v2, v3) -> {
      use e0 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v0))))
      use e1 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v1))))
      use e2 <- result.try(result.map(
        list.try_map(v2, fn(item) { Ok(kdl.JsonValueStr(int.to_string(item))) }),
        kdl.JsonValueArr,
      ))
      use e3 <- result.try(result.map(
        list.try_map(v3, fn(item) { encode_dfa_transition(item) }),
        kdl.JsonValueArr,
      ))
      Ok(
        kdl.JsonValueObj([
          #("state_count", e0),
          #("initial_state", e1),
          #("accepting_states", e2),
          #("transitions", e3),
        ]),
      )
    }
  }
}

pub fn encode_dfa_transition(
  value: types.DfaTransition,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.DfaTransition(v0, v1, v2, v3) -> {
      use e0 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v0))))
      use e1 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v1))))
      use e2 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v2))))
      use e3 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v3))))
      Ok(
        kdl.JsonValueObj([
          #("from_state", e0),
          #("first", e1),
          #("last", e2),
          #("to_state", e3),
        ]),
      )
    }
  }
}

pub fn encode_format_binding(
  value: types.FormatBinding,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.FormatBinding(v0, v1, v2) -> {
      use e0 <- result.try(Ok(kdl.JsonValueStr(v0)))
      use e1 <- result.try(encode_profile_ref(v1))
      use e2 <- result.try(encode_format_rule(v2))
      Ok(kdl.JsonValueObj([#("name", e0), #("reference", e1), #("rule", e2)]))
    }
  }
}

pub fn encode_format_rule(
  value: types.FormatRule,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.Literal(value) ->
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("Literal")),
          #("value", kdl.JsonValueStr(value)),
        ]),
      )
    types.Sequence(parts) -> {
      use encoded <- result.try(result.map(
        list.try_map(parts, encode_format_rule),
        kdl.JsonValueArr,
      ))
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("Sequence")),
          #("value", encoded),
        ]),
      )
    }
    types.Optional(inner) -> {
      use encoded <- result.try(encode_format_rule(inner))
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("Optional")),
          #("value", encoded),
        ]),
      )
    }
    types.Labels(separator, minimum, maximum, total_maximum, inner) -> {
      use encoded <- result.try(encode_format_rule(inner))
      let max_value = case maximum {
        None -> kdl.JsonValueNull
        Some(value) -> kdl.JsonValueStr(int.to_string(value))
      }
      let total_value = case total_maximum {
        None -> kdl.JsonValueNull
        Some(value) -> kdl.JsonValueStr(int.to_string(value))
      }
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("Labels")),
          #(
            "fields",
            kdl.JsonValueObj([
              #("separator", kdl.JsonValueStr(separator)),
              #("min_count", kdl.JsonValueStr(int.to_string(minimum))),
              #("max_count", max_value),
              #("total_max", total_value),
              #("rule", encoded),
            ]),
          ),
        ]),
      )
    }
    types.Bounded(unit, maximum, inner) -> {
      use encoded <- result.try(encode_format_rule(inner))
      use encoded_unit <- result.try(encode_string_length_unit(unit))
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("Bounded")),
          #(
            "fields",
            kdl.JsonValueObj([
              #("unit", encoded_unit),
              #("maximum", kdl.JsonValueStr(int.to_string(maximum))),
              #("rule", encoded),
            ]),
          ),
        ]),
      )
    }
    types.AsciiDfa(v0) -> {
      use payload <- result.try(encode_dfa_spec(v0))
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("AsciiDfa")),
          #("value", payload),
        ]),
      )
    }
    types.Timestamp(v0) -> {
      use payload <- result.try(encode_calendar_rule(v0))
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("Timestamp")),
          #("value", payload),
        ]),
      )
    }
    types.Choice(v0) -> {
      use payload <- result.try(result.map(
        list.try_map(v0, fn(item) { encode_format_rule(item) }),
        kdl.JsonValueArr,
      ))
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("Choice")),
          #("value", payload),
        ]),
      )
    }
    types.Identifier(v0, v1, v2, v3, v4, v5) -> {
      use e0 <- result.try(Ok(kdl.JsonValueStr(v0)))
      use e1 <- result.try(Ok(kdl.JsonValueStr(v1)))
      use e2 <- result.try(case v2 {
        None -> Ok(kdl.JsonValueNull)
        Some(item) -> Ok(kdl.JsonValueStr(int.to_string(item)))
      })
      use e3 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v3))))
      use e4 <- result.try(case v4 {
        None -> Ok(kdl.JsonValueNull)
        Some(item) -> Ok(kdl.JsonValueStr(int.to_string(item)))
      })
      use e5 <- result.try(result.map(
        list.try_map(v5, fn(item) { Ok(kdl.JsonValueStr(item)) }),
        kdl.JsonValueArr,
      ))
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("Identifier")),
          #(
            "fields",
            kdl.JsonValueObj([
              #("first_alphabet", e0),
              #("rest_alphabet", e1),
              #("exact_length", e2),
              #("min_length", e3),
              #("max_length", e4),
              #("forbidden", e5),
            ]),
          ),
        ]),
      )
    }
    types.AbsoluteUri(v0) -> {
      use e0 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v0))))
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("AbsoluteUri")),
          #("fields", kdl.JsonValueObj([#("max_bytes", e0)])),
        ]),
      )
    }
    types.LanguageTag(v0) -> {
      use e0 <- result.try(result.map(
        list.try_map(v0, fn(item) { Ok(kdl.JsonValueStr(item)) }),
        kdl.JsonValueArr,
      ))
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("LanguageTag")),
          #("fields", kdl.JsonValueObj([#("grandfathered", e0)])),
        ]),
      )
    }
    types.Text -> Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Text"))]))
    types.Not(rule) -> {
      use payload <- result.try(encode_format_rule(rule))
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("Not")),
          #("value", payload),
        ]),
      )
    }
  }
}

pub fn encode_grapheme_property(
  value: types.GraphemeProperty,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.Other -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Other"))]))
    }
    types.Cr -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Cr"))]))
    }
    types.Lf -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Lf"))]))
    }
    types.Control -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Control"))]))
    }
    types.Extend -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Extend"))]))
    }
    types.Zwj -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Zwj"))]))
    }
    types.RegionalIndicator -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("RegionalIndicator"))]))
    }
    types.Prepend -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Prepend"))]))
    }
    types.SpacingMark -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("SpacingMark"))]))
    }
    types.L -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("L"))]))
    }
    types.V -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("V"))]))
    }
    types.T -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("T"))]))
    }
    types.Lv -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Lv"))]))
    }
    types.Lvt -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Lvt"))]))
    }
  }
}

pub fn encode_grapheme_range(
  value: types.GraphemeRange,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.GraphemeRange(v0, v1, v2) -> {
      use e0 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v0))))
      use e1 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v1))))
      use e2 <- result.try(encode_grapheme_property(v2))
      Ok(kdl.JsonValueObj([#("first", e0), #("last", e1), #("property", e2)]))
    }
  }
}

pub fn encode_grapheme_rules(
  value: types.GraphemeRules,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.GraphemeRules(v0, v1, v2, v3, component, digest, sources) -> {
      use e0 <- result.try(encode_profile_ref(v0))
      use e1 <- result.try(result.map(
        list.try_map(v1, fn(item) { encode_grapheme_range(item) }),
        kdl.JsonValueArr,
      ))
      use e2 <- result.try(result.map(
        list.try_map(v2, fn(item) { encode_codepoint_range(item) }),
        kdl.JsonValueArr,
      ))
      use e3 <- result.try(result.map(
        list.try_map(v3, fn(item) { encode_indic_range(item) }),
        kdl.JsonValueArr,
      ))
      use sources <- result.try(
        list.try_map(sources, fn(entry) {
          use origin <- result.try(encode_origin(entry.origin))
          Ok(
            kdl.JsonValueObj([
              #("role", kdl.JsonValueStr(entry.role)),
              #("origin", origin),
            ]),
          )
        }),
      )
      let component =
        kdl.JsonValueObj([
          #("unicode_version", kdl.JsonValueStr(component.unicode_version)),
          #("uax29_revision", kdl.JsonValueStr(component.uax29_revision)),
          #("cluster_profile", kdl.JsonValueStr(component.cluster_profile)),
        ])
      Ok(
        kdl.JsonValueObj([
          #("reference", e0),
          #("component", component),
          #("table_sha256", kdl.JsonValueStr(digest)),
          #("sources", kdl.JsonValueArr(sources)),
          #("properties", e1),
          #("extended_pictographic", e2),
          #("indic_conjunct", e3),
        ]),
      )
    }
  }
}

pub fn encode_indic_property(
  value: types.IndicProperty,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.IndicOther -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Other"))]))
    }
    types.Consonant -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Consonant"))]))
    }
    types.IndicExtend -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Extend"))]))
    }
    types.Linker -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Linker"))]))
    }
  }
}

pub fn encode_indic_range(
  value: types.IndicRange,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.IndicRange(v0, v1, v2) -> {
      use e0 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v0))))
      use e1 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v1))))
      use e2 <- result.try(encode_indic_property(v2))
      Ok(kdl.JsonValueObj([#("first", e0), #("last", e1), #("property", e2)]))
    }
  }
}

pub fn encode_integer_domain(
  value: types.IntegerDomain,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.Unbounded -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Unbounded"))]))
    }
    types.IntegerInterval(v0, v1) -> {
      use e0 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v0))))
      use e1 <- result.try(Ok(kdl.JsonValueStr(int.to_string(v1))))
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("Inclusive")),
          #("fields", kdl.JsonValueObj([#("minimum", e0), #("maximum", e1)])),
        ]),
      )
    }
  }
}

pub fn encode_length_spec(
  value: types.LengthSpec,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.LengthSpec(v0, v1) -> {
      use e0 <- result.try(case v0 {
        None -> Ok(kdl.JsonValueNull)
        Some(item) -> Ok(kdl.JsonValueStr(int.to_string(item)))
      })
      use e1 <- result.try(case v1 {
        None -> Ok(kdl.JsonValueNull)
        Some(item) -> Ok(kdl.JsonValueStr(int.to_string(item)))
      })
      Ok(kdl.JsonValueObj([#("minimum", e0), #("maximum", e1)]))
    }
  }
}

pub fn encode_occurrence_ref(
  value: types.OccurrenceRef,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.OccurrenceRef(v0, v1) -> {
      use e0 <- result.try(encode_source_ref(v0))
      use e1 <- result.try(result.map(
        list.try_map(v1, fn(item) { Ok(kdl.JsonValueStr(item)) }),
        kdl.JsonValueArr,
      ))
      Ok(kdl.JsonValueObj([#("source", e0), #("pointer", e1)]))
    }
  }
}

pub fn encode_path_step(
  value: types.PathStep,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.Field(v0) -> {
      use payload <- result.try(Ok(kdl.JsonValueStr(v0)))
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("Field")),
          #("value", payload),
        ]),
      )
    }
    types.Index(v0) -> {
      use payload <- result.try(Ok(kdl.JsonValueStr(int.to_string(v0))))
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("Index")),
          #("value", payload),
        ]),
      )
    }
    types.Variant(v0) -> {
      use payload <- result.try(Ok(kdl.JsonValueStr(v0)))
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("Variant")),
          #("value", payload),
        ]),
      )
    }
  }
}

pub fn encode_profile_ref(
  value: types.ProfileRef,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.ProfileRef(v0, v1, v2) -> {
      use e0 <- result.try(Ok(kdl.JsonValueStr(v0)))
      use e1 <- result.try(Ok(kdl.JsonValueStr(v1)))
      use e2 <- result.try(Ok(kdl.JsonValueStr(v2)))
      Ok(
        kdl.JsonValueObj([
          #("identity", e0),
          #("revision", e1),
          #("content_digest", e2),
        ]),
      )
    }
  }
}

pub fn encode_semantic_basis(
  value: composition.SemanticBasis,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    composition.SemanticBasis(v0, v1) -> {
      use e0 <- result.try(encode_semantic_profile(v0))
      use e1 <- result.try(result.map(
        list.try_map(v1, fn(item) { encode_source_ref(item) }),
        kdl.JsonValueArr,
      ))
      Ok(kdl.JsonValueObj([#("profile", e0), #("sources", e1)]))
    }
  }
}

pub fn encode_slot_contract(
  value: types.SlotContract,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.SlotContract(v0, v1, v2) -> {
      use e0 <- result.try(encode_type_ref(v0))
      use e1 <- result.try(Ok(kdl.JsonValueBool(v1)))
      use e2 <- result.try(Ok(kdl.JsonValueBool(v2)))
      Ok(
        kdl.JsonValueObj([
          #("type_ref", e0),
          #("required", e1),
          #("nullable", e2),
        ]),
      )
    }
  }
}

pub fn encode_slot_value(
  value: types.SlotValue(kdl.JsonValue),
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.Absent -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Absent"))]))
    }
    types.Null -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Null"))]))
    }
    types.Present(v0) -> {
      use payload <- result.try(exact_encode(v0))
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("Present")),
          #("value", payload),
        ]),
      )
    }
  }
}

pub fn encode_source_constraint(
  value: composition.SourceConstraint,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    composition.AnyCompatible -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("AnyCompatible"))]))
    }
    composition.InitialOnly(v0, v1) -> {
      use e0 <- result.try({
        let composition.InputId(inner) = v0
        Ok(kdl.JsonValueStr(inner))
      })
      use e1 <- result.try(result.map(
        list.try_map(v1, encode_path_step),
        kdl.JsonValueArr,
      ))
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("InitialOnly")),
          #("fields", kdl.JsonValueObj([#("input", e0), #("path", e1)])),
        ]),
      )
    }
    composition.ProducedBy(v0, v1, v2, v3) -> {
      use e0 <- result.try({
        let composition.SiteId(inner) = v0
        Ok(kdl.JsonValueStr(inner))
      })
      use e1 <- result.try({
        let composition.OutcomeId(inner) = v1
        Ok(kdl.JsonValueStr(inner))
      })
      use e2 <- result.try({
        let composition.PortId(inner) = v2
        Ok(kdl.JsonValueStr(inner))
      })
      use e3 <- result.try(result.map(
        list.try_map(v3, encode_path_step),
        kdl.JsonValueArr,
      ))
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("ProducedBy")),
          #(
            "fields",
            kdl.JsonValueObj([
              #("site", e0),
              #("outcome", e1),
              #("port", e2),
              #("path", e3),
            ]),
          ),
        ]),
      )
    }
  }
}

pub fn encode_source_ref(
  value: types.SourceRef,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.SourceRef(v0, v1, v2, v3, v4, v5) -> {
      use e0 <- result.try(Ok(kdl.JsonValueStr(v0)))
      use e1 <- result.try(Ok(kdl.JsonValueStr(v1)))
      use e2 <- result.try(Ok(kdl.JsonValueStr(v2)))
      use e3 <- result.try(Ok(kdl.JsonValueStr(v3)))
      use e4 <- result.try(Ok(kdl.JsonValueStr(v4)))
      use e5 <- result.try(case v5 {
        None -> Ok(kdl.JsonValueNull)
        Some(item) -> Ok(kdl.JsonValueStr(int.to_string(item)))
      })
      Ok(
        kdl.JsonValueObj([
          #("repository", e0),
          #("revision", e1),
          #("path", e2),
          #("content_digest", e3),
          #("document_id", e4),
          #("declared_revision", e5),
        ]),
      )
    }
  }
}

pub fn encode_string_length_unit(
  value: types.StringLengthUnit,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.Utf8Bytes -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Utf8Bytes"))]))
    }
    types.UnicodeScalars -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("UnicodeScalars"))]))
    }
    types.Graphemes -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Graphemes"))]))
    }
  }
}

pub fn encode_type_ref(
  value: types.TypeRef,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.TypeRef(v0, v1, v2) -> {
      use e0 <- result.try(encode_source_ref(v0))
      use e1 <- result.try(Ok(kdl.JsonValueStr(v1)))
      use e2 <- result.try(result.map(
        list.try_map(v2, fn(item) { Ok(kdl.JsonValueStr(item)) }),
        kdl.JsonValueArr,
      ))
      Ok(
        kdl.JsonValueObj([
          #("source", e0),
          #("definition_name", e1),
          #("pointer", e2),
        ]),
      )
    }
  }
}

fn exact_encode(value: kdl.JsonValue) -> Result(kdl.JsonValue, DecodeFailure) {
  result.map_error(values.encode_exact(value), fn(_) {
    DecodeFailure([], "invalid ExactJson")
  })
}

fn declared_optional(
  value: Option(a),
  encoder: fn(a) -> Result(kdl.JsonValue, DecodeFailure),
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    None -> Ok(kdl.JsonValueNull)
    Some(value) -> encoder(value)
  }
}

fn declared_array(
  values: List(a),
  encoder: fn(a) -> Result(kdl.JsonValue, DecodeFailure),
) -> Result(kdl.JsonValue, DecodeFailure) {
  result.map(list.try_map(values, encoder), kdl.JsonValueArr)
}

fn decode_profile_reference(
  value: kdl.JsonValue,
) -> Result(types.ProfileRef, DecodeFailure) {
  use members <- result.try(
    object(value, ["identity", "revision", "content_digest"]),
  )
  use identity <- result.try(
    field(members, "identity") |> result.try(fn(value) { text(value, "", "") }),
  )
  use revision <- result.try(
    field(members, "revision") |> result.try(fn(value) { text(value, "", "") }),
  )
  use content_digest <- result.try(
    field(members, "content_digest")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  Ok(types.ProfileRef(identity, revision, content_digest))
}

fn decode_source_identity_field(
  value: kdl.JsonValue,
) -> Result(types.SourceIdentity, DecodeFailure) {
  use members <- result.try(
    object(value, ["repository", "revision", "path", "content_digest"]),
  )
  let read_text = fn(name) {
    field(members, name)
    |> result.try(fn(value) { text(value, "", "") })
  }
  use repository <- result.try(read_text("repository"))
  use revision <- result.try(read_text("revision"))
  use path <- result.try(read_text("path"))
  use content_digest <- result.try(read_text("content_digest"))
  Ok(types.SourceIdentity(repository, revision, path, content_digest))
}

fn decode_integer_form_field(
  value: kdl.JsonValue,
) -> Result(types.IntegerForm, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag <- result.try(
    field(members, "tag")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  use _ <- result.try(object(value, ["tag"]))
  case tag {
    "Number" -> Ok(types.Number)
    "IntegralDecimal" -> Ok(types.IntegralDecimal)
    "DecimalString" -> Ok(types.DecimalString)
    _ -> fail("unknown IntegerForm tag")
  }
}

fn encode_integer_form_field(
  value: types.IntegerForm,
) -> Result(kdl.JsonValue, DecodeFailure) {
  Ok(
    kdl.JsonValueObj([
      #(
        "tag",
        kdl.JsonValueStr(case value {
          types.Number -> "Number"
          types.IntegralDecimal -> "IntegralDecimal"
          types.DecimalString -> "DecimalString"
        }),
      ),
    ]),
  )
}

fn decode_integer_domain_binding_field(
  value: kdl.JsonValue,
) -> Result(types.IntegerDomainBinding, DecodeFailure) {
  use members <- result.try(
    object(value, ["name", "reference", "range", "forms"]),
  )
  use name <- result.try(
    field(members, "name")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  use reference <- result.try(
    field(members, "reference") |> result.try(decode_profile_reference),
  )
  use range <- result.try(
    field(members, "range") |> result.try(decode_integer_domain),
  )
  use forms <- result.try(
    field(members, "forms")
    |> result.try(fn(value) { array(value, decode_integer_form_field) }),
  )
  Ok(types.IntegerDomainBinding(name, reference, range, forms))
}

fn encode_integer_domain_binding_field(
  value: types.IntegerDomainBinding,
) -> Result(kdl.JsonValue, DecodeFailure) {
  use reference <- result.try(encode_profile_ref(value.reference))
  use range <- result.try(encode_integer_domain(value.range))
  use forms <- result.try(declared_array(value.forms, encode_integer_form_field))
  Ok(
    kdl.JsonValueObj([
      #("name", kdl.JsonValueStr(value.name)),
      #("reference", reference),
      #("range", range),
      #("forms", forms),
    ]),
  )
}

fn decode_number_model_field(
  value: kdl.JsonValue,
) -> Result(types.NumberModel, DecodeFailure) {
  use members <- result.try(object(value, ["decimals"]))
  use decimals <- result.try(field(members, "decimals") |> result.try(boolean))
  Ok(types.NumberModel(decimals))
}

fn encode_number_model_field(
  value: types.NumberModel,
) -> Result(kdl.JsonValue, DecodeFailure) {
  Ok(kdl.JsonValueObj([#("decimals", kdl.JsonValueBool(value.decimals))]))
}

fn decode_bytes_alphabet_field(
  value: kdl.JsonValue,
) -> Result(types.BytesAlphabet, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag <- result.try(
    field(members, "tag")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  use _ <- result.try(object(value, ["tag"]))
  case tag {
    "Standard" -> Ok(types.Standard)
    "UrlSafe" -> Ok(types.UrlSafe)
    "Either" -> Ok(types.Either)
    _ -> fail("unknown BytesAlphabet tag")
  }
}

fn encode_bytes_alphabet_field(
  value: types.BytesAlphabet,
) -> Result(kdl.JsonValue, DecodeFailure) {
  Ok(
    kdl.JsonValueObj([
      #(
        "tag",
        kdl.JsonValueStr(case value {
          types.Standard -> "Standard"
          types.UrlSafe -> "UrlSafe"
          types.Either -> "Either"
        }),
      ),
    ]),
  )
}

fn decode_wrapper_payload_field(
  value: kdl.JsonValue,
) -> Result(types.WrapperPayload, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag <- result.try(
    field(members, "tag")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  case tag {
    "Bytes" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.WrapperBytes)
    }
    "Text" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use format <- result.try(
        field(members, "value")
        |> result.try(fn(value) {
          optional(value, fn(value) { text(value, "", "") })
        }),
      )
      Ok(types.WrapperText(format))
    }
    _ -> fail("unknown WrapperPayload tag")
  }
}

fn encode_wrapper_payload_field(
  value: types.WrapperPayload,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    types.WrapperBytes ->
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("Bytes"))]))
    types.WrapperText(format) -> {
      use encoded <- result.try(
        declared_optional(format, fn(value) { Ok(kdl.JsonValueStr(value)) }),
      )
      Ok(
        kdl.JsonValueObj([
          #("tag", kdl.JsonValueStr("Text")),
          #("value", encoded),
        ]),
      )
    }
  }
}

fn decode_wrapper_field(
  value: kdl.JsonValue,
) -> Result(types.Wrapper, DecodeFailure) {
  use members <- result.try(object(value, ["name", "key", "payload"]))
  use name <- result.try(
    field(members, "name")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  use key <- result.try(
    field(members, "key")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  use payload <- result.try(
    field(members, "payload") |> result.try(decode_wrapper_payload_field),
  )
  Ok(types.Wrapper(name, key, payload))
}

fn encode_wrapper_field(
  value: types.Wrapper,
) -> Result(kdl.JsonValue, DecodeFailure) {
  use payload <- result.try(encode_wrapper_payload_field(value.payload))
  Ok(
    kdl.JsonValueObj([
      #("name", kdl.JsonValueStr(value.name)),
      #("key", kdl.JsonValueStr(value.key)),
      #("payload", payload),
    ]),
  )
}

fn decode_length_bound_field(
  value: kdl.JsonValue,
) -> Result(types.LengthBound, DecodeFailure) {
  use members <- result.try(object(value, ["unit", "minimum", "maximum"]))
  use unit <- result.try(
    field(members, "unit") |> result.try(decode_string_length_unit),
  )
  use minimum <- result.try(
    field(members, "minimum")
    |> result.try(fn(value) {
      optional(value, fn(value) { integer(value, True) })
    }),
  )
  use maximum <- result.try(
    field(members, "maximum")
    |> result.try(fn(value) {
      optional(value, fn(value) { integer(value, True) })
    }),
  )
  Ok(types.LengthBound(unit, minimum, maximum))
}

fn encode_length_bound_field(
  value: types.LengthBound,
) -> Result(kdl.JsonValue, DecodeFailure) {
  use unit <- result.try(encode_string_length_unit(value.unit))
  use minimum <- result.try(
    declared_optional(value.minimum, fn(value) {
      Ok(kdl.JsonValueStr(int.to_string(value)))
    }),
  )
  use maximum <- result.try(
    declared_optional(value.maximum, fn(value) {
      Ok(kdl.JsonValueStr(int.to_string(value)))
    }),
  )
  Ok(
    kdl.JsonValueObj([
      #("unit", unit),
      #("minimum", minimum),
      #("maximum", maximum),
    ]),
  )
}

pub fn decode_format_use(
  value: kdl.JsonValue,
) -> Result(types.FormatUse, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag <- result.try(
    field(members, "tag")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  use _ <- result.try(object(value, ["tag", "value"]))
  use payload <- result.try(field(members, "value"))
  case tag {
    "Named" -> result.map(text(payload, "", ""), types.NamedFormat)
    "Inline" -> result.map(decode_format_rule(payload), types.InlineFormat)
    _ -> fail("unknown FormatUse tag")
  }
}

pub fn encode_format_use(
  value: types.FormatUse,
) -> Result(kdl.JsonValue, DecodeFailure) {
  let tag = case value {
    types.NamedFormat(_) -> "Named"
    types.InlineFormat(_) -> "Inline"
  }
  use payload <- result.try(case value {
    types.NamedFormat(name) -> Ok(kdl.JsonValueStr(name))
    types.InlineFormat(rule) -> encode_format_rule(rule)
  })
  Ok(
    kdl.JsonValueObj([
      #("tag", kdl.JsonValueStr(tag)),
      #("value", payload),
    ]),
  )
}

pub fn decode_integer_spec(
  value: kdl.JsonValue,
) -> Result(types.IntegerSpec, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "domain",
      "minimum",
      "maximum",
      "const_value",
      "enum_values",
      "default_value",
    ]),
  )
  let optional_text = fn(name) {
    field(members, name)
    |> result.try(fn(value) {
      optional(value, fn(value) { text(value, "", "") })
    })
  }
  let optional_int = fn(name) {
    field(members, name)
    |> result.try(fn(value) {
      optional(value, fn(value) { integer(value, False) })
    })
  }
  use domain <- result.try(optional_text("domain"))
  use minimum <- result.try(optional_int("minimum"))
  use maximum <- result.try(optional_int("maximum"))
  use const_value <- result.try(optional_int("const_value"))
  use enum_values <- result.try(
    field(members, "enum_values")
    |> result.try(fn(value) {
      optional(value, fn(value) {
        array(value, fn(value) { integer(value, False) })
      })
    }),
  )
  use default_value <- result.try(optional_int("default_value"))
  Ok(types.IntegerSpec(
    domain,
    minimum,
    maximum,
    const_value,
    enum_values,
    default_value,
  ))
}

pub fn encode_integer_spec(
  value: types.IntegerSpec,
) -> Result(kdl.JsonValue, DecodeFailure) {
  let text_value = fn(value) { Ok(kdl.JsonValueStr(value)) }
  let int_value = fn(value) { Ok(kdl.JsonValueStr(int.to_string(value))) }
  use domain <- result.try(declared_optional(value.domain, text_value))
  use minimum <- result.try(declared_optional(value.minimum, int_value))
  use maximum <- result.try(declared_optional(value.maximum, int_value))
  use const_value <- result.try(declared_optional(value.const_value, int_value))
  use enum_values <- result.try(
    declared_optional(value.enum_values, fn(values) {
      declared_array(values, int_value)
    }),
  )
  use default_value <- result.try(declared_optional(
    value.default_value,
    int_value,
  ))
  Ok(
    kdl.JsonValueObj([
      #("domain", domain),
      #("minimum", minimum),
      #("maximum", maximum),
      #("const_value", const_value),
      #("enum_values", enum_values),
      #("default_value", default_value),
    ]),
  )
}

pub fn decode_string_spec(
  value: kdl.JsonValue,
) -> Result(types.StringSpec, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "format",
      "lengths",
      "wrapper",
      "const_value",
      "enum_values",
      "examples",
      "default_value",
    ]),
  )
  let optional_text = fn(name) {
    field(members, name)
    |> result.try(fn(value) {
      optional(value, fn(value) { text(value, "", "") })
    })
  }
  use format <- result.try(
    field(members, "format")
    |> result.try(fn(value) { optional(value, decode_format_use) }),
  )
  use lengths <- result.try(
    field(members, "lengths")
    |> result.try(fn(value) { array(value, decode_length_bound_field) }),
  )
  use wrapper <- result.try(optional_text("wrapper"))
  use const_value <- result.try(optional_text("const_value"))
  use enum_values <- result.try(
    field(members, "enum_values")
    |> result.try(fn(value) {
      optional(value, fn(value) {
        array(value, fn(value) { text(value, "", "") })
      })
    }),
  )
  use examples <- result.try(
    field(members, "examples")
    |> result.try(fn(value) { array(value, fn(value) { text(value, "", "") }) }),
  )
  use default_value <- result.try(optional_text("default_value"))
  Ok(types.StringSpec(
    format,
    lengths,
    wrapper,
    const_value,
    enum_values,
    examples,
    default_value,
  ))
}

pub fn encode_string_spec(
  value: types.StringSpec,
) -> Result(kdl.JsonValue, DecodeFailure) {
  let text_value = fn(value) { Ok(kdl.JsonValueStr(value)) }
  use format <- result.try(declared_optional(value.format, encode_format_use))
  use lengths <- result.try(declared_array(
    value.lengths,
    encode_length_bound_field,
  ))
  use wrapper <- result.try(declared_optional(value.wrapper, text_value))
  use const_value <- result.try(declared_optional(value.const_value, text_value))
  use enum_values <- result.try(
    declared_optional(value.enum_values, fn(values) {
      declared_array(values, text_value)
    }),
  )
  use examples <- result.try(declared_array(value.examples, text_value))
  use default_value <- result.try(declared_optional(
    value.default_value,
    text_value,
  ))
  Ok(
    kdl.JsonValueObj([
      #("format", format),
      #("lengths", lengths),
      #("wrapper", wrapper),
      #("const_value", const_value),
      #("enum_values", enum_values),
      #("examples", examples),
      #("default_value", default_value),
    ]),
  )
}

pub fn decode_sealed_leaf(
  value: kdl.JsonValue,
) -> Result(types.SealedLeaf, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag <- result.try(
    field(members, "tag")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  use _ <- result.try(object(value, ["tag", "value"]))
  use payload <- result.try(field(members, "value"))
  case tag {
    "String" -> result.map(decode_string_spec(payload), types.SealedString)
    "Integer" -> result.map(decode_integer_spec(payload), types.SealedInteger)
    _ -> fail("unknown SealedLeaf tag")
  }
}

pub fn encode_sealed_leaf(
  value: types.SealedLeaf,
) -> Result(kdl.JsonValue, DecodeFailure) {
  let tag = case value {
    types.SealedString(_) -> "String"
    types.SealedInteger(_) -> "Integer"
  }
  use payload <- result.try(case value {
    types.SealedString(spec) -> encode_string_spec(spec)
    types.SealedInteger(spec) -> encode_integer_spec(spec)
  })
  Ok(
    kdl.JsonValueObj([
      #("tag", kdl.JsonValueStr(tag)),
      #("value", payload),
    ]),
  )
}

fn decode_sealed_field_field(
  value: kdl.JsonValue,
) -> Result(types.SealedField, DecodeFailure) {
  use members <- result.try(object(value, ["key", "required", "leaf"]))
  use key <- result.try(
    field(members, "key")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  use required <- result.try(field(members, "required") |> result.try(boolean))
  use leaf <- result.try(
    field(members, "leaf") |> result.try(decode_sealed_leaf),
  )
  Ok(types.SealedField(key, required, leaf))
}

fn encode_sealed_field_field(
  value: types.SealedField,
) -> Result(kdl.JsonValue, DecodeFailure) {
  use leaf <- result.try(encode_sealed_leaf(value.leaf))
  Ok(
    kdl.JsonValueObj([
      #("key", kdl.JsonValueStr(value.key)),
      #("required", kdl.JsonValueBool(value.required)),
      #("leaf", leaf),
    ]),
  )
}

fn decode_sealed_extras_field(
  value: kdl.JsonValue,
) -> Result(types.SealedExtras, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag <- result.try(
    field(members, "tag")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  use _ <- result.try(object(value, ["tag"]))
  case tag {
    "Reject" -> Ok(types.SealedReject)
    "Any" -> Ok(types.SealedAny)
    _ -> fail("unknown SealedExtras tag")
  }
}

fn encode_sealed_extras_field(
  value: types.SealedExtras,
) -> Result(kdl.JsonValue, DecodeFailure) {
  Ok(
    kdl.JsonValueObj([
      #(
        "tag",
        kdl.JsonValueStr(case value {
          types.SealedReject -> "Reject"
          types.SealedAny -> "Any"
        }),
      ),
    ]),
  )
}

fn decode_sealed_form_field(
  value: kdl.JsonValue,
) -> Result(types.SealedForm, DecodeFailure) {
  use members <- result.try(object(value, ["tag", "fields", "extras"]))
  use tag <- result.try(
    field(members, "tag")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  use fields <- result.try(
    field(members, "fields")
    |> result.try(fn(value) { array(value, decode_sealed_field_field) }),
  )
  use extras <- result.try(
    field(members, "extras") |> result.try(decode_sealed_extras_field),
  )
  Ok(types.SealedForm(tag, fields, extras))
}

fn encode_sealed_form_field(
  value: types.SealedForm,
) -> Result(kdl.JsonValue, DecodeFailure) {
  use fields <- result.try(declared_array(
    value.fields,
    encode_sealed_field_field,
  ))
  use extras <- result.try(encode_sealed_extras_field(value.extras))
  Ok(
    kdl.JsonValueObj([
      #("tag", kdl.JsonValueStr(value.tag)),
      #("fields", fields),
      #("extras", extras),
    ]),
  )
}

fn decode_tag_model_field(
  value: kdl.JsonValue,
) -> Result(types.TagModel, DecodeFailure) {
  use members <- result.try(object(value, ["key", "format", "sealed"]))
  use key <- result.try(
    field(members, "key")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  use format <- result.try(
    field(members, "format")
    |> result.try(fn(value) {
      optional(value, fn(value) { text(value, "", "") })
    }),
  )
  use sealed <- result.try(
    field(members, "sealed")
    |> result.try(fn(value) { array(value, decode_sealed_form_field) }),
  )
  Ok(types.TagModel(key, format, sealed))
}

fn encode_tag_model_field(
  value: types.TagModel,
) -> Result(kdl.JsonValue, DecodeFailure) {
  use format <- result.try(
    declared_optional(value.format, fn(value) { Ok(kdl.JsonValueStr(value)) }),
  )
  use sealed <- result.try(declared_array(
    value.sealed,
    encode_sealed_form_field,
  ))
  Ok(
    kdl.JsonValueObj([
      #("key", kdl.JsonValueStr(value.key)),
      #("format", format),
      #("sealed", sealed),
    ]),
  )
}

fn decode_bytes_policy_field(
  value: kdl.JsonValue,
) -> Result(types.BytesPolicy, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "reference",
      "padding_optional",
      "alphabet",
      "strict_pad_bits",
      "wrapper",
    ]),
  )
  use reference <- result.try(
    field(members, "reference") |> result.try(decode_profile_reference),
  )
  use padding_optional <- result.try(
    field(members, "padding_optional") |> result.try(boolean),
  )
  use alphabet <- result.try(
    field(members, "alphabet") |> result.try(decode_bytes_alphabet_field),
  )
  use strict_pad_bits <- result.try(
    field(members, "strict_pad_bits") |> result.try(boolean),
  )
  use wrapper <- result.try(
    field(members, "wrapper")
    |> result.try(fn(value) {
      optional(value, fn(value) { text(value, "", "") })
    }),
  )
  Ok(types.BytesPolicy(
    reference,
    padding_optional,
    alphabet,
    strict_pad_bits,
    wrapper,
  ))
}

fn encode_bytes_policy_field(
  value: types.BytesPolicy,
) -> Result(kdl.JsonValue, DecodeFailure) {
  use reference <- result.try(encode_profile_ref(value.reference))
  use alphabet <- result.try(encode_bytes_alphabet_field(value.alphabet))
  use wrapper <- result.try(
    declared_optional(value.wrapper, fn(value) { Ok(kdl.JsonValueStr(value)) }),
  )
  Ok(
    kdl.JsonValueObj([
      #("reference", reference),
      #("padding_optional", kdl.JsonValueBool(value.padding_optional)),
      #("alphabet", alphabet),
      #("strict_pad_bits", kdl.JsonValueBool(value.strict_pad_bits)),
      #("wrapper", wrapper),
    ]),
  )
}

pub fn decode_semantic_profile(
  value: kdl.JsonValue,
) -> Result(types.SemanticProfile, DecodeFailure) {
  use members <- result.try(
    object(value, [
      "reference",
      "source_refs",
      "integer_domains",
      "default_integer_domain",
      "numbers",
      "grapheme_rules",
      "format_bindings",
      "bytes_policy",
      "wrappers",
      "tag",
    ]),
  )
  use reference <- result.try(
    field(members, "reference") |> result.try(decode_profile_reference),
  )
  use source_refs <- result.try(
    field(members, "source_refs")
    |> result.try(fn(value) { array(value, decode_source_identity_field) }),
  )
  use integer_domains <- result.try(
    field(members, "integer_domains")
    |> result.try(fn(value) {
      array(value, decode_integer_domain_binding_field)
    }),
  )
  use default_integer_domain <- result.try(
    field(members, "default_integer_domain")
    |> result.try(fn(value) { text(value, "", "") }),
  )
  use numbers <- result.try(
    field(members, "numbers") |> result.try(decode_number_model_field),
  )
  use grapheme_rules <- result.try(
    field(members, "grapheme_rules")
    |> result.try(fn(value) { optional(value, decode_grapheme_rules) }),
  )
  use format_bindings <- result.try(
    field(members, "format_bindings")
    |> result.try(fn(value) { array(value, decode_format_binding) }),
  )
  use bytes_policy <- result.try(
    field(members, "bytes_policy")
    |> result.try(fn(value) { optional(value, decode_bytes_policy_field) }),
  )
  use wrappers <- result.try(
    field(members, "wrappers")
    |> result.try(fn(value) { array(value, decode_wrapper_field) }),
  )
  use tag <- result.try(
    field(members, "tag")
    |> result.try(fn(value) { optional(value, decode_tag_model_field) }),
  )
  Ok(types.SemanticProfile(
    reference,
    source_refs,
    integer_domains,
    default_integer_domain,
    numbers,
    grapheme_rules,
    format_bindings,
    bytes_policy,
    wrappers,
    tag,
  ))
}

pub fn encode_semantic_profile(
  value: types.SemanticProfile,
) -> Result(kdl.JsonValue, DecodeFailure) {
  use reference <- result.try(encode_profile_ref(value.reference))
  use source_refs <- result.try(declared_array(
    value.source_refs,
    encode_source_identity,
  ))
  use integer_domains <- result.try(declared_array(
    value.integer_domains,
    encode_integer_domain_binding_field,
  ))
  use numbers <- result.try(encode_number_model_field(value.numbers))
  use grapheme_rules <- result.try(declared_optional(
    value.grapheme_rules,
    encode_grapheme_rules,
  ))
  use format_bindings <- result.try(declared_array(
    value.format_bindings,
    encode_format_binding,
  ))
  use bytes_policy <- result.try(declared_optional(
    value.bytes_policy,
    encode_bytes_policy_field,
  ))
  use wrappers <- result.try(declared_array(
    value.wrappers,
    encode_wrapper_field,
  ))
  use tag <- result.try(declared_optional(value.tag, encode_tag_model_field))
  Ok(
    kdl.JsonValueObj([
      #("reference", reference),
      #("source_refs", source_refs),
      #("integer_domains", integer_domains),
      #(
        "default_integer_domain",
        kdl.JsonValueStr(value.default_integer_domain),
      ),
      #("numbers", numbers),
      #("grapheme_rules", grapheme_rules),
      #("format_bindings", format_bindings),
      #("bytes_policy", bytes_policy),
      #("wrappers", wrappers),
      #("tag", tag),
    ]),
  )
}

pub fn decode_checked_semantic_profile(
  value: kdl.JsonValue,
) -> Result(types.CheckedProfile, DecodeFailure) {
  use profile <- result.try(decode_semantic_profile(value))
  validation.check_profile(profile)
  |> result.map_error(ProfileFailure)
}

pub fn decode_value_condition(
  value: kdl.JsonValue,
) -> Result(types.ValueCondition, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(text(tag_value, "", ""))
  case tag {
    "MissingRequired" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.MissingRequiredCondition)
    }
    "NullNotAllowed" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.NullNotAllowedCondition)
    }
    "ConstMismatch" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.ConstMismatchCondition)
    }
    "EnumMismatch" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.EnumMismatchCondition)
    }
    "BelowMinimum" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.BelowMinimumCondition)
    }
    "AboveMaximum" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.AboveMaximumCondition)
    }
    "IntegerDomain" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.IntegerDomainCondition)
    }
    "StringLength" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.StringLengthCondition)
    }
    "ArrayLength" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.ArrayLengthCondition)
    }
    "BytesLength" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.BytesLengthCondition)
    }
    "InvalidBytes" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.InvalidBytesCondition)
    }
    "InvalidTag" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.InvalidTagCondition)
    }
    "ReservedForm" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.ReservedFormCondition)
    }
    "NoBranchSelected" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.NoBranchSelectedCondition)
    }
    "Uninhabited" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.UninhabitedCondition)
    }
    "InvalidDataModel" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.InvalidDataModelCondition)
    }
    "ReferenceCycle" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.ReferenceCycleCondition)
    }
    "WrongValueKind" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", text(payload, "", "")))
      Ok(types.WrongValueKindCondition(decoded))
    }
    "Format" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", text(payload, "", "")))
      Ok(types.FormatFailureCondition(decoded))
    }
    "InvalidWrapper" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", text(payload, "", "")))
      Ok(types.InvalidWrapperCondition(decoded))
    }
    "KeyFormat" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", text(payload, "", "")))
      Ok(types.KeyFormatCondition(decoded))
    }
    "DuplicateField" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", text(payload, "", "")))
      Ok(types.DuplicateFieldCondition(decoded))
    }
    "UnexpectedField" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", text(payload, "", "")))
      Ok(types.UnexpectedFieldCondition(decoded))
    }
    _ -> fail("unknown ValueCondition tag")
  }
}

pub fn encode_value_condition(
  value: types.ValueCondition,
) -> Result(kdl.JsonValue, DecodeFailure) {
  let #(tag, payload) = case value {
    types.MissingRequiredCondition -> #("MissingRequired", None)
    types.NullNotAllowedCondition -> #("NullNotAllowed", None)
    types.WrongValueKindCondition(value) -> #("WrongValueKind", Some(value))
    types.ConstMismatchCondition -> #("ConstMismatch", None)
    types.EnumMismatchCondition -> #("EnumMismatch", None)
    types.BelowMinimumCondition -> #("BelowMinimum", None)
    types.AboveMaximumCondition -> #("AboveMaximum", None)
    types.IntegerDomainCondition -> #("IntegerDomain", None)
    types.StringLengthCondition -> #("StringLength", None)
    types.ArrayLengthCondition -> #("ArrayLength", None)
    types.BytesLengthCondition -> #("BytesLength", None)
    types.FormatFailureCondition(value) -> #("Format", Some(value))
    types.InvalidBytesCondition -> #("InvalidBytes", None)
    types.InvalidWrapperCondition(value) -> #("InvalidWrapper", Some(value))
    types.InvalidTagCondition -> #("InvalidTag", None)
    types.ReservedFormCondition -> #("ReservedForm", None)
    types.NoBranchSelectedCondition -> #("NoBranchSelected", None)
    types.KeyFormatCondition(value) -> #("KeyFormat", Some(value))
    types.UninhabitedCondition -> #("Uninhabited", None)
    types.DuplicateFieldCondition(value) -> #("DuplicateField", Some(value))
    types.UnexpectedFieldCondition(value) -> #("UnexpectedField", Some(value))
    types.InvalidDataModelCondition -> #("InvalidDataModel", None)
    types.ReferenceCycleCondition -> #("ReferenceCycle", None)
  }
  Ok(
    kdl.JsonValueObj([
      #("tag", kdl.JsonValueStr(tag)),
      ..case payload {
        None -> []
        Some(payload) -> [#("value", kdl.JsonValueStr(payload))]
      }
    ]),
  )
}
