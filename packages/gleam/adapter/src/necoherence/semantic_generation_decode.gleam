// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import necoherence/composition_plan
import necoherence/exact_json as kdl
import necoherence/resource_witness
import necoherence/semantic_generation_values as values
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import necoherence/typed_mapping as resource

pub type DecodeFailure {
  ProfileFailure(failure: types.ProfileFailure)
  UnknownField(path: List(String), field: String)
  UnknownTag(path: List(String), tag: String)
  SyntaxFailure(path: List(String), reason: String)
  CompositionFailure(failure: resource_witness.WitnessFailure)
}

pub type DerivationDecoder {
  DerivationDecoder(
    shapes: fn(composition_plan.TypePair, kdl.JsonValue, kdl.JsonValue) ->
      Result(#(types.TypeShape, types.TypeShape), DecodeFailure),
    basis: fn(kdl.JsonValue) ->
      Result(composition_plan.SemanticBasis, DecodeFailure),
    token_identity: fn(String) -> String,
  )
}

pub type ProblemDecoder(cause) {
  ProblemDecoder(
    basis: fn(kdl.JsonValue) ->
      Result(composition_plan.SemanticBasis, DecodeFailure),
    cause: fn(kdl.JsonValue) -> Result(cause, DecodeFailure),
  )
}

pub type DecodedProblem(cause) {
  DecodedProblem(
    input: composition_plan.CompositionInput,
    causes: List(
      #(
        composition_plan.FunctionRef,
        List(#(composition_plan.OutcomeContract, cause)),
      ),
    ),
  )
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

pub fn decode_binding_compatibility(
  value: kdl.JsonValue,
  wire: DerivationDecoder,
) -> Result(composition_plan.BindingCompatibility, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "Inclusion" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        decode_inclusion_certificate(payload, wire),
      ))
      Ok(composition_plan.Inclusion(decoded))
    }
    "SuppliedValue" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["value"]))
      use raw_0 <- result.try(field(members, "value"))
      use a0 <- result.try(named("value", decode_slot_value(raw_0)))
      Ok(composition_plan.SuppliedBindingValue(a0))
    }
    other -> unknown_tag(other)
  }
}

pub fn decode_binding_expr(
  value: kdl.JsonValue,
  wire: DerivationDecoder,
) -> Result(composition_plan.BindingExpr, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "Source" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(
        object(payload, ["value", "projection", "compatibility"]),
      )
      use raw_2 <- result.try(field(members, "compatibility"))
      use a2 <- result.try(named(
        "compatibility",
        decode_binding_compatibility(raw_2, wire),
      ))
      use raw_0 <- result.try(field(members, "value"))
      use a0 <- result.try(named("value", decode_value_ref(raw_0)))
      use raw_1 <- result.try(field(members, "projection"))
      use a1 <- result.try(named(
        "projection",
        decode_projection_certificate(raw_1),
      ))
      Ok(composition_plan.Source(a0, a1, a2))
    }
    "Product" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(
        object(payload, ["construction", "type_id", "fields"]),
      )
      use raw_0 <- result.try(field(members, "construction"))
      use a0 <- result.try(named("construction", text(raw_0, "", "")))
      use raw_1 <- result.try(field(members, "type_id"))
      use a1 <- result.try(named("type_id", decode_type_id(raw_1)))
      use raw_2 <- result.try(field(members, "fields"))
      use a2 <- result.try(named(
        "fields",
        array(raw_2, fn(value) { decode_tuple_1(value, wire) }),
      ))
      Ok(composition_plan.Product(a0, a1, a2))
    }
    other -> unknown_tag(other)
  }
}

pub fn decode_binding_mode(
  value: kdl.JsonValue,
) -> Result(resource.BindingMode, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "Read" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(resource.Read)
    }
    "Consume" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(resource.Consume)
    }
    other -> unknown_tag(other)
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

fn exact_field(
  value: kdl.JsonValue,
  key: String,
) -> Result(kdl.JsonValue, DecodeFailure) {
  use members <- result.try(tagged(value))
  field(members, key)
}

pub fn decode_composition_effect(
  value: kdl.JsonValue,
) -> Result(composition_plan.CompositionEffect, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "PureFunction" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.PureFunction)
    }
    "HttpRequestResponse" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.HttpRequestResponse)
    }
    "DataOnly" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.DataOnly)
    }
    other -> unknown_tag(other)
  }
}

pub fn decode_composition_input(
  value: kdl.JsonValue,
  decoder: ProblemDecoder(cause),
) -> Result(DecodedProblem(cause), DecodeFailure) {
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
  use raw_basis <- result.try(field(members, "basis"))
  use basis <- result.try(named("basis", decoder.basis(raw_basis)))
  use raw_signatures <- result.try(field(members, "signatures"))
  use signatures <- result.try(named(
    "signatures",
    array(raw_signatures, fn(value) {
      decode_function_signature(value, decoder.cause)
    }),
  ))
  use raw_0 <- result.try(field(members, "identity"))
  use a0 <- result.try(named("identity", text(raw_0, "", "")))
  use raw_1 <- result.try(field(members, "revision"))
  use a1 <- result.try(named("revision", text(raw_1, "", "")))
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
  Ok(DecodedProblem(
    composition_plan.CompositionInput(
      a0,
      a1,
      basis,
      list.map(signatures, fn(signature) { signature.0 }),
      a4,
      a5,
      a6,
      a7,
      a8,
      a9,
      a10,
      a11,
    ),
    list.map(signatures, fn(signature) {
      #({ signature.0 }.reference, signature.1)
    }),
  ))
}

pub fn decode_field_presence(
  value: kdl.JsonValue,
) -> Result(composition_plan.FieldPresence, DecodeFailure) {
  use members <- result.try(tagged(value))
  use raw <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(raw, "", "")))
  case tag {
    "Required" -> unit_variant(value, composition_plan.Required)
    "Optional" -> unit_variant(value, composition_plan.Optional)
    other -> unknown_tag(other)
  }
}

pub fn decode_field_constraint(
  value: kdl.JsonValue,
) -> Result(composition_plan.FieldConstraint, DecodeFailure) {
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
  Ok(composition_plan.FieldConstraint(name, source, presence))
}

pub fn decode_construction_rule(
  value: kdl.JsonValue,
) -> Result(composition_plan.ConstructionRule, DecodeFailure) {
  use members <- result.try(
    object(value, ["identity", "type_id", "nested_fields", "field_constraints"]),
  )
  use raw_0 <- result.try(field(members, "identity"))
  use a0 <- result.try(named("identity", text(raw_0, "", "")))
  use raw_1 <- result.try(field(members, "type_id"))
  use a1 <- result.try(named("type_id", decode_type_id(raw_1)))
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
  Ok(composition_plan.ConstructionRule(a0, a1, a2, a3))
}

pub fn decode_declared_guard(
  value: kdl.JsonValue,
) -> Result(composition_plan.DeclaredGuard, DecodeFailure) {
  use members <- result.try(
    object(value, ["id", "source_type", "path", "kind"]),
  )
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition_plan.GuardId),
  ))
  use raw_1 <- result.try(field(members, "source_type"))
  use a1 <- result.try(named("source_type", decode_type_id(raw_1)))
  use raw_2 <- result.try(field(members, "path"))
  use a2 <- result.try(named(
    "path",
    array(raw_2, fn(value) { decode_path_step(value) }),
  ))
  use raw_3 <- result.try(field(members, "kind"))
  use a3 <- result.try(named("kind", decode_guard_kind(raw_3)))
  Ok(composition_plan.DeclaredGuard(a0, a1, a2, a3))
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

pub fn decode_effect_point(
  value: kdl.JsonValue,
) -> Result(types.EffectPoint, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "HttpRequestResponse" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.HttpRequestResponse)
    }
    "DataOnly" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.DataOnly)
    }
    other -> unknown_tag(other)
  }
}

pub fn decode_failure_embedding(
  value: kdl.JsonValue,
) -> Result(composition_plan.FailureEmbedding, DecodeFailure) {
  use members <- result.try(
    object(value, ["id", "origin", "contract", "final_resources"]),
  )
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition_plan.FailureEmbeddingId),
  ))
  use raw_1 <- result.try(field(members, "origin"))
  use a1 <- result.try(named("origin", decode_failure_origin(raw_1)))
  use raw_2 <- result.try(field(members, "contract"))
  use a2 <- result.try(named("contract", decode_signature_slot_contract(raw_2)))
  use raw_3 <- result.try(field(members, "final_resources"))
  use a3 <- result.try(named(
    "final_resources",
    array(raw_3, fn(value) { decode_resource_goal(value) }),
  ))
  Ok(composition_plan.FailureEmbedding(a0, a1, a2, a3))
}

pub fn decode_failure_origin(
  value: kdl.JsonValue,
) -> Result(composition_plan.FailureOrigin, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
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
        result.map(text(raw_1, "", ""), composition_plan.OutcomeId),
      ))
      Ok(composition_plan.FunctionFailure(a0, a1))
    }
    "Guard" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["guard", "arm"]))
      use raw_0 <- result.try(field(members, "guard"))
      use a0 <- result.try(named(
        "guard",
        result.map(text(raw_0, "", ""), composition_plan.GuardId),
      ))
      use raw_1 <- result.try(field(members, "arm"))
      use a1 <- result.try(named("arm", decode_guard_arm(raw_1)))
      Ok(composition_plan.GuardFailure(a0, a1))
    }
    other -> unknown_tag(other)
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
  use tag <- result.try(named("tag", text(tag_value, "", "")))
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
      use minimum <- result.try(named("min_count", integer(raw_min, True)))
      use raw_max <- result.try(field(row, "max_count"))
      use maximum <- result.try(named(
        "max_count",
        optional(raw_max, fn(item) { integer(item, True) }),
      ))
      use raw_total <- result.try(field(row, "total_max"))
      use total <- result.try(named(
        "total_max",
        optional(raw_total, fn(item) { integer(item, True) }),
      ))
      use raw_rule <- result.try(field(row, "rule"))
      use inner <- result.try(decode_format_rule(raw_rule))
      Ok(types.Labels(separator, minimum, maximum, total, inner))
    }
    "Bounded" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use row <- result.try(object(payload, ["unit", "maximum", "rule"]))
      use raw_unit <- result.try(field(row, "unit"))
      use unit <- result.try(named("unit", decode_string_length_unit(raw_unit)))
      use raw_max <- result.try(field(row, "maximum"))
      use maximum <- result.try(named("maximum", integer(raw_max, True)))
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
      use a0 <- result.try(named(
        "max_bytes",
        optional(raw_0, fn(value) { integer(value, True) }),
      ))
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
    other -> unknown_tag(other)
  }
}

pub fn decode_function_form(
  value: kdl.JsonValue,
) -> Result(composition_plan.FunctionForm, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "Pure" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.Pure)
    }
    "DeclaredTransform" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.DeclaredTransform)
    }
    "Operation" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", decode_definition_id(payload)))
      Ok(composition_plan.Operation(decoded))
    }
    other -> unknown_tag(other)
  }
}

pub fn decode_function_ref(
  value: kdl.JsonValue,
) -> Result(composition_plan.FunctionRef, DecodeFailure) {
  use members <- result.try(
    object(value, ["identity", "revision", "content_digest"]),
  )
  use raw_0 <- result.try(field(members, "identity"))
  use a0 <- result.try(named("identity", text(raw_0, "", "")))
  use raw_1 <- result.try(field(members, "revision"))
  use a1 <- result.try(named("revision", text(raw_1, "", "")))
  use raw_2 <- result.try(field(members, "content_digest"))
  use a2 <- result.try(named("content_digest", text(raw_2, "", "")))
  Ok(composition_plan.FunctionRef(a0, a1, a2))
}

pub fn decode_function_signature(
  value: kdl.JsonValue,
  decode_cause: fn(kdl.JsonValue) -> Result(cause, DecodeFailure),
) -> Result(
  #(
    composition_plan.FunctionSignature,
    List(#(composition_plan.OutcomeContract, cause)),
  ),
  DecodeFailure,
) {
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
  use outcomes <- result.try(named(
    "outcomes",
    array(raw_4, fn(value) { decode_outcome_contract(value, decode_cause) }),
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
  Ok(#(
    composition_plan.FunctionSignature(
      a0,
      a1,
      a2,
      a3,
      list.map(outcomes, fn(outcome) { outcome.0 }),
      a5,
      a6,
      a7,
    ),
    outcomes,
  ))
}

pub fn decode_goal_port(
  value: kdl.JsonValue,
) -> Result(composition_plan.GoalPort, DecodeFailure) {
  use members <- result.try(
    object(value, ["id", "contract", "source_constraint"]),
  )
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition_plan.GoalPortId),
  ))
  use raw_1 <- result.try(field(members, "contract"))
  use a1 <- result.try(named("contract", decode_signature_slot_contract(raw_1)))
  use raw_2 <- result.try(field(members, "source_constraint"))
  use a2 <- result.try(named(
    "source_constraint",
    decode_source_constraint(raw_2),
  ))
  Ok(composition_plan.GoalPort(a0, a1, a2))
}

pub fn decode_goal_spec(
  value: kdl.JsonValue,
) -> Result(composition_plan.GoalSpec, DecodeFailure) {
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
  Ok(composition_plan.GoalSpec(a0, a1, a2))
}

pub fn decode_grapheme_property(
  value: kdl.JsonValue,
) -> Result(types.GraphemeProperty, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
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
    other -> unknown_tag(other)
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
  use component <- result.try(named(
    "component",
    field(members, "component") |> result.try(decode_grapheme_component),
  ))
  use digest <- result.try(named(
    "table_sha256",
    field(members, "table_sha256")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  use sources <- result.try(named(
    "sources",
    field(members, "sources")
      |> result.try(fn(value) { array(value, decode_grapheme_source) }),
  ))
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
  Ok(types.GraphemeRules(a0, a1, a2, a3, component, digest, sources))
}

pub fn decode_grapheme_component(
  value: kdl.JsonValue,
) -> Result(types.GraphemeComponent, DecodeFailure) {
  use members <- result.try(
    object(value, ["unicode_version", "uax29_revision", "cluster_profile"]),
  )
  use version <- result.try(named(
    "unicode_version",
    field(members, "unicode_version")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  use revision <- result.try(named(
    "uax29_revision",
    field(members, "uax29_revision")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  use profile <- result.try(named(
    "cluster_profile",
    field(members, "cluster_profile")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  Ok(types.GraphemeComponent(version, revision, profile))
}

pub fn decode_grapheme_source(
  value: kdl.JsonValue,
) -> Result(types.GraphemeSource, DecodeFailure) {
  use members <- result.try(object(value, ["role", "origin"]))
  use role <- result.try(named(
    "role",
    field(members, "role") |> result.try(fn(value) { text(value, "", "") }),
  ))
  use origin <- result.try(named(
    "origin",
    field(members, "origin") |> result.try(decode_origin),
  ))
  Ok(types.GraphemeSource(role, origin))
}

pub fn decode_source_identity(
  value: kdl.JsonValue,
) -> Result(types.SourceIdentity, DecodeFailure) {
  use members <- result.try(
    object(value, ["repository", "revision", "path", "content_digest"]),
  )
  use repository <- result.try(named(
    "repository",
    field(members, "repository")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  use revision <- result.try(named(
    "revision",
    field(members, "revision") |> result.try(fn(value) { text(value, "", "") }),
  ))
  use path <- result.try(named(
    "path",
    field(members, "path") |> result.try(fn(value) { text(value, "", "") }),
  ))
  use digest <- result.try(named(
    "content_digest",
    field(members, "content_digest")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  Ok(types.SourceIdentity(repository, revision, path, digest))
}

pub fn decode_origin(
  value: kdl.JsonValue,
) -> Result(types.Origin, DecodeFailure) {
  use members <- result.try(object(value, ["source", "locator"]))
  use source <- result.try(named(
    "source",
    field(members, "source") |> result.try(decode_source_identity),
  ))
  use locator <- result.try(named(
    "locator",
    field(members, "locator")
      |> result.try(fn(value) {
        array(value, fn(value) { text(value, "", "") })
      }),
  ))
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
) -> Result(composition_plan.GuardArm, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "Present" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.GuardPresent)
    }
    "Absent" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.GuardAbsent)
    }
    "Null" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.GuardNull)
    }
    "UnknownVariant" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.UnknownVariant)
    }
    "Accepted" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.GuardAccepted)
    }
    "Rejected" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.GuardRejected)
    }
    "Variant" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", text(payload, "", "")))
      Ok(composition_plan.GuardVariant(decoded))
    }
    other -> unknown_tag(other)
  }
}

pub fn decode_guard_kind(
  value: kdl.JsonValue,
) -> Result(composition_plan.GuardKind, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "Presence" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.Presence)
    }
    "Variants" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.Variants)
    }
    "Validate" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        decode_signature_slot_contract(payload),
      ))
      Ok(composition_plan.Validate(decoded))
    }
    other -> unknown_tag(other)
  }
}

const inclusion_certificate_keys = [
  "basis",
  "source",
  "destination",
  "root",
  "empty_types",
  "pairs",
]

pub fn decode_inclusion_certificate(
  value: kdl.JsonValue,
  wire: DerivationDecoder,
) -> Result(composition_plan.InclusionCertificate, DecodeFailure) {
  use members <- result.try(object(value, inclusion_certificate_keys))
  use raw_0 <- result.try(field(members, "basis"))
  use a0 <- result.try(named("basis", wire.basis(raw_0)))
  use raw_5 <- result.try(field(members, "pairs"))
  use a5 <- result.try(named(
    "pairs",
    array(raw_5, fn(value) { decode_pair_entry(value, wire) }),
  ))
  use raw_1 <- result.try(field(members, "source"))
  use a1 <- result.try(named("source", decode_signature_slot_contract(raw_1)))
  use raw_2 <- result.try(field(members, "destination"))
  use a2 <- result.try(named(
    "destination",
    decode_signature_slot_contract(raw_2),
  ))
  use raw_4 <- result.try(field(members, "empty_types"))
  use a4 <- result.try(named(
    "empty_types",
    array(raw_4, fn(value) { decode_type_id(value) }),
  ))
  use raw_3 <- result.try(field(members, "root"))
  use a3 <- result.try(named("root", integer(raw_3, True)))
  Ok(composition_plan.InclusionCertificate(a0, a1, a2, a4, a5, a3))
}

pub fn decode_inclusion_rule(
  value: kdl.JsonValue,
) -> Result(composition_plan.InclusionRule, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "SameDefinedType" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.SameDefinedType)
    }
    "EmptySource" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.EmptySource)
    }
    "Boolean" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.InclusionBoolean)
    }
    "IntegerIntersection" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.IntegerIntersection)
    }
    "FiniteStrings" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.FiniteStrings)
    }
    "StringConditions" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.StringConditions)
    }
    "BytesLength" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.BytesLength)
    }
    "Unit" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.InclusionUnit)
    }
    "UnfoldSource" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.UnfoldSource)
    }
    "UnfoldDestination" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.UnfoldDestination)
    }
    "Array" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.InclusionArray)
    }
    "Product" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.InclusionProduct)
    }
    "SourceUnion" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.SourceUnion)
    }
    "DestinationUnion" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.DestinationUnion)
    }
    other -> unknown_tag(other)
  }
}

pub fn decode_indic_property(
  value: kdl.JsonValue,
) -> Result(types.IndicProperty, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
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
    other -> unknown_tag(other)
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
) -> Result(composition_plan.InitialInput, DecodeFailure) {
  use members <- result.try(
    object(value, ["id", "contract", "source", "resource"]),
  )
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition_plan.InputId),
  ))
  use raw_1 <- result.try(field(members, "contract"))
  use a1 <- result.try(named("contract", decode_signature_slot_contract(raw_1)))
  use raw_2 <- result.try(field(members, "source"))
  use a2 <- result.try(named("source", decode_initial_source(raw_2)))
  use raw_3 <- result.try(field(members, "resource"))
  use a3 <- result.try(named(
    "resource",
    optional(raw_3, fn(value) {
      result.map(text(value, "", ""), composition_plan.LotId)
    }),
  ))
  Ok(composition_plan.InitialInput(a0, a1, a2, a3))
}

pub fn decode_initial_source(
  value: kdl.JsonValue,
) -> Result(composition_plan.InitialSource, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "Argument" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.Argument)
    }
    "SuppliedValue" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named("value", decode_slot_value(payload)))
      Ok(composition_plan.SuppliedValue(decoded))
    }
    other -> unknown_tag(other)
  }
}

pub fn decode_input_port(
  value: kdl.JsonValue,
) -> Result(composition_plan.InputPort, DecodeFailure) {
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
    result.map(text(raw_0, "", ""), composition_plan.PortId),
  ))
  use raw_1 <- result.try(field(members, "contract"))
  use a1 <- result.try(named("contract", decode_signature_slot_contract(raw_1)))
  use raw_2 <- result.try(field(members, "source_constraint"))
  use a2 <- result.try(named(
    "source_constraint",
    decode_source_constraint(raw_2),
  ))
  use raw_3 <- result.try(field(members, "resource_requirement"))
  use a3 <- result.try(named(
    "resource_requirement",
    optional(raw_3, fn(value) {
      result.map(text(value, "", ""), composition_plan.RequirementId)
    }),
  ))
  Ok(composition_plan.InputPort(a0, a1, a2, a3))
}

pub fn decode_integer_domain(
  value: kdl.JsonValue,
) -> Result(types.IntegerDomain, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
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
    other -> unknown_tag(other)
  }
}

pub fn decode_invocation_domain(
  value: kdl.JsonValue,
) -> Result(composition_plan.InvocationDomain, DecodeFailure) {
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
  Ok(composition_plan.InvocationDomain(a0, a1, a2, a3, a4, a5, a6))
}

pub fn decode_invocation_plan(
  value: kdl.JsonValue,
  wire: DerivationDecoder,
) -> Result(composition_plan.InvocationPlan, DecodeFailure) {
  use members <- result.try(
    object(value, ["site", "function", "bindings", "resources"]),
  )
  use raw_3 <- result.try(field(members, "resources"))
  use a3 <- result.try(named(
    "resources",
    array(raw_3, fn(value) { decode_resource_binding(value, wire) }),
  ))
  use raw_2 <- result.try(field(members, "bindings"))
  use a2 <- result.try(named(
    "bindings",
    array(raw_2, fn(value) { decode_tuple_8(value, wire) }),
  ))
  use raw_0 <- result.try(field(members, "site"))
  use a0 <- result.try(named(
    "site",
    result.map(text(raw_0, "", ""), composition_plan.SiteId),
  ))
  use raw_1 <- result.try(field(members, "function"))
  use a1 <- result.try(named("function", decode_function_ref(raw_1)))
  Ok(composition_plan.InvocationPlan(a0, a1, a2, a3))
}

pub fn decode_invocation_site(
  value: kdl.JsonValue,
) -> Result(composition_plan.InvocationSite, DecodeFailure) {
  use members <- result.try(object(value, ["id", "function"]))
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition_plan.SiteId),
  ))
  use raw_1 <- result.try(field(members, "function"))
  use a1 <- result.try(named("function", decode_function_ref(raw_1)))
  Ok(composition_plan.InvocationSite(a0, a1))
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

pub fn decode_outcome_contract(
  value: kdl.JsonValue,
  decode_cause: fn(kdl.JsonValue) -> Result(cause, DecodeFailure),
) -> Result(#(composition_plan.OutcomeContract, cause), DecodeFailure) {
  use members <- result.try(
    object(value, [
      "id",
      "form",
      "cause",
      "value_ports",
      "produced_resources",
    ]),
  )
  use raw_cause <- result.try(field(members, "cause"))
  use cause <- result.try(named("cause", decode_cause(raw_cause)))
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition_plan.OutcomeId),
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
  Ok(#(composition_plan.OutcomeContract(a0, a1, a2, a3), cause))
}

pub fn decode_outcome_form(
  value: kdl.JsonValue,
) -> Result(composition_plan.OutcomeForm, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "Success" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.Success)
    }
    "DeclaredFailure" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.DeclaredFailure)
    }
    other -> unknown_tag(other)
  }
}

pub fn decode_output_port(
  value: kdl.JsonValue,
) -> Result(composition_plan.OutputPort, DecodeFailure) {
  use members <- result.try(
    object(value, ["id", "contract", "resource_production"]),
  )
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition_plan.PortId),
  ))
  use raw_1 <- result.try(field(members, "contract"))
  use a1 <- result.try(named("contract", decode_signature_slot_contract(raw_1)))
  use raw_2 <- result.try(field(members, "resource_production"))
  use a2 <- result.try(named(
    "resource_production",
    optional(raw_2, fn(value) {
      result.map(text(value, "", ""), composition_plan.ProductionId)
    }),
  ))
  Ok(composition_plan.OutputPort(a0, a1, a2))
}

pub fn decode_pair_entry(
  value: kdl.JsonValue,
  wire: DerivationDecoder,
) -> Result(composition_plan.PairEntry, DecodeFailure) {
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
  use raw_2 <- result.try(field(members, "destination_shape"))
  use shapes <- result.try(wire.shapes(a0, raw_1, raw_2))
  use raw_3 <- result.try(field(members, "rule"))
  use a3 <- result.try(named("rule", decode_inclusion_rule(raw_3)))
  use raw_4 <- result.try(field(members, "children"))
  use a4 <- result.try(named(
    "children",
    array(raw_4, fn(value) { integer(value, True) }),
  ))
  Ok(composition_plan.PairEntry(a0, shapes.0, shapes.1, a3, a4))
}

pub fn decode_path_step(
  value: kdl.JsonValue,
) -> Result(types.PathStep, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
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
    other -> unknown_tag(other)
  }
}

pub fn decode_permitted_projection(
  value: kdl.JsonValue,
) -> Result(composition_plan.PermittedProjection, DecodeFailure) {
  use members <- result.try(object(value, ["source_type", "path"]))
  use raw_0 <- result.try(field(members, "source_type"))
  use a0 <- result.try(named("source_type", decode_type_id(raw_0)))
  use raw_1 <- result.try(field(members, "path"))
  use a1 <- result.try(named(
    "path",
    array(raw_1, fn(value) { decode_path_step(value) }),
  ))
  Ok(composition_plan.PermittedProjection(a0, a1))
}

fn decode_plan_node(
  rank: Int,
  value: kdl.JsonValue,
  wire: DerivationDecoder,
) -> Result(composition_plan.PlanTree, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "Return" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        decode_return_plan(payload, wire),
      ))
      Ok(composition_plan.ReturnValue(rank, decoded))
    }
    "Invoke" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(
        object(payload, ["invocation", "arms", "empty_outcomes"]),
      )
      use raw_1 <- result.try(field(members, "arms"))
      use a1 <- result.try(named(
        "arms",
        array(raw_1, fn(value) { decode_tuple_12(value, wire) }),
      ))
      use raw_0 <- result.try(field(members, "invocation"))
      use a0 <- result.try(named(
        "invocation",
        decode_invocation_plan(raw_0, wire),
      ))
      use raw_2 <- result.try(field(members, "empty_outcomes"))
      use a2 <- result.try(named(
        "empty_outcomes",
        array(raw_2, fn(value) {
          result.map(text(value, "", ""), composition_plan.OutcomeId)
        }),
      ))
      Ok(composition_plan.Invoke(rank, a0, a1, a2))
    }
    "Guard" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["guard", "inspected", "arms"]))
      use raw_2 <- result.try(field(members, "arms"))
      use a2 <- result.try(named(
        "arms",
        array(raw_2, fn(value) { decode_tuple_13(value, wire) }),
      ))
      use raw_0 <- result.try(field(members, "guard"))
      use a0 <- result.try(named(
        "guard",
        result.map(text(raw_0, "", ""), composition_plan.GuardId),
      ))
      use raw_1 <- result.try(field(members, "inspected"))
      use a1 <- result.try(named("inspected", decode_value_ref(raw_1)))
      Ok(composition_plan.Guard(rank, a0, a1, a2))
    }
    other -> unknown_tag(other)
  }
}

pub fn decode_plan_tree(
  value: kdl.JsonValue,
  wire: DerivationDecoder,
) -> Result(composition_plan.PlanTree, DecodeFailure) {
  use members <- result.try(object(value, ["rank", "node"]))
  use raw_0 <- result.try(field(members, "rank"))
  use a0 <- result.try(named("rank", integer(raw_0, True)))
  use raw_1 <- result.try(field(members, "node"))
  named("node", decode_plan_node(a0, raw_1, wire))
}

pub fn decode_producer_ref(
  value: kdl.JsonValue,
) -> Result(composition_plan.ProducerRef, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "Initial" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        result.map(text(payload, "", ""), composition_plan.InputId),
      ))
      Ok(composition_plan.Initial(decoded))
    }
    "InvocationOutcome" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["site", "outcome", "port"]))
      use raw_0 <- result.try(field(members, "site"))
      use a0 <- result.try(named(
        "site",
        result.map(text(raw_0, "", ""), composition_plan.SiteId),
      ))
      use raw_1 <- result.try(field(members, "outcome"))
      use a1 <- result.try(named(
        "outcome",
        result.map(text(raw_1, "", ""), composition_plan.OutcomeId),
      ))
      use raw_2 <- result.try(field(members, "port"))
      use a2 <- result.try(named(
        "port",
        result.map(text(raw_2, "", ""), composition_plan.PortId),
      ))
      Ok(composition_plan.InvocationOutcome(a0, a1, a2))
    }
    other -> unknown_tag(other)
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
  use a2 <- result.try(named("content_digest", text(raw_2, "", "")))
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
    other -> unknown_tag(other)
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
  use a2 <- result.try(named("source", decode_signature_slot_contract(raw_2)))
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
  use a5 <- result.try(named(
    "destination",
    decode_signature_slot_contract(raw_5),
  ))
  Ok(validation.ProjectionCertificate(a0, a1, a2, a3, a4, a5))
}

pub fn decode_generation_plan(
  value: kdl.JsonValue,
  exact: kdl.JsonValue,
  wire: DerivationDecoder,
  same_json: fn(kdl.JsonValue, kdl.JsonValue) -> Bool,
) -> Result(composition_plan.CompositionPlan, DecodeFailure) {
  use members <- result.try(object(value, ["problem", "derivation"]))
  use raw_derivation <- result.try(field(members, "derivation"))
  use exact_problem <- result.try(exact_field(exact, "problem"))
  use exact_derivation <- result.try(exact_field(exact, "derivation"))
  decode_plan_composition(raw_derivation, exact_derivation, wire, fn(snapshot) {
    same_json(snapshot, exact_problem)
  })
}

pub fn decode_plan_composition(
  value: kdl.JsonValue,
  exact: kdl.JsonValue,
  wire: DerivationDecoder,
  same_problem: fn(kdl.JsonValue) -> Bool,
) -> Result(composition_plan.CompositionPlan, DecodeFailure) {
  use members <- result.try(object(value, ["plan", "witness", "selection"]))
  use raw_plan <- result.try(field(members, "plan"))
  use plan <- result.try(
    object(raw_plan, ["input_identity", "input_revision", "root"]),
  )
  use raw_witness <- result.try(field(members, "witness"))
  use _ <- result.try(
    object(raw_witness, [
      "input_snapshot",
      "initial_membership",
      "resource_traces",
    ]),
  )
  use exact_witness <- result.try(exact_field(exact, "witness"))
  use exact_snapshot <- result.try(exact_field(exact_witness, "input_snapshot"))
  use _ <- result.try(case same_problem(exact_snapshot) {
    True -> Ok(Nil)
    False -> Error(SyntaxFailure(["$"], "input snapshot mismatch"))
  })
  use raw_root <- result.try(field(plan, "root"))
  use root <- result.try(decode_plan_tree(raw_root, wire))
  use raw_selection <- result.try(field(members, "selection"))
  use _ <- result.try(decode_plan_selection(raw_selection))
  use raw_identity <- result.try(field(plan, "input_identity"))
  use identity <- result.try(named("input_identity", text(raw_identity, "", "")))
  use raw_revision <- result.try(field(plan, "input_revision"))
  use revision <- result.try(named("input_revision", text(raw_revision, "", "")))
  Ok(composition_plan.CompositionPlan(identity, revision, root))
}

fn decode_plan_selection(value: kdl.JsonValue) -> Result(Nil, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "AnyFeasible" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(Nil)
    }
    "Unique" -> Ok(Nil)
    other -> unknown_tag(other)
  }
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
  wire: DerivationDecoder,
) -> Result(composition_plan.ResourceBinding, DecodeFailure) {
  use members <- result.try(object(value, ["requirement", "lot", "inclusion"]))
  use raw_0 <- result.try(field(members, "requirement"))
  use a0 <- result.try(named(
    "requirement",
    result.map(text(raw_0, "", ""), composition_plan.RequirementId),
  ))
  use raw_1 <- result.try(field(members, "lot"))
  use a1 <- result.try(named("lot", decode_resource_lot_ref(raw_1)))
  use raw_2 <- result.try(field(members, "inclusion"))
  use a2 <- result.try(named(
    "inclusion",
    decode_inclusion_certificate(raw_2, wire),
  ))
  Ok(composition_plan.ResourceBinding(a0, a1, a2))
}

pub fn decode_resource_bounds(
  value: kdl.JsonValue,
) -> Result(composition_plan.ResourceBounds, DecodeFailure) {
  use members <- result.try(
    object(value, ["max_bindings", "max_search_steps", "max_tokens"]),
  )
  use raw_0 <- result.try(field(members, "max_bindings"))
  use a0 <- result.try(named("max_bindings", integer(raw_0, True)))
  use raw_1 <- result.try(field(members, "max_search_steps"))
  use a1 <- result.try(named("max_search_steps", integer(raw_1, True)))
  use raw_2 <- result.try(field(members, "max_tokens"))
  use a2 <- result.try(named("max_tokens", integer(raw_2, True)))
  Ok(composition_plan.ResourceBounds(a0, a1, a2))
}

pub fn decode_resource_goal(
  value: kdl.JsonValue,
) -> Result(composition_plan.ResourceGoal, DecodeFailure) {
  use members <- result.try(object(value, ["lot", "multiplicity", "revision"]))
  use raw_0 <- result.try(field(members, "lot"))
  use a0 <- result.try(named("lot", decode_resource_lot_ref(raw_0)))
  use raw_1 <- result.try(field(members, "multiplicity"))
  use a1 <- result.try(named("multiplicity", integer(raw_1, True)))
  use raw_2 <- result.try(field(members, "revision"))
  use a2 <- result.try(named("revision", integer(raw_2, True)))
  Ok(composition_plan.ResourceGoal(a0, a1, a2))
}

pub fn decode_resource_identity_constraint(
  value: kdl.JsonValue,
) -> Result(composition_plan.ResourceIdentityConstraint, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "Any" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.AnyResource)
    }
    "Exactly" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        decode_resource_producer(payload),
      ))
      Ok(composition_plan.Exactly(decoded))
    }
    other -> unknown_tag(other)
  }
}

pub fn decode_resource_lot(
  value: kdl.JsonValue,
) -> Result(composition_plan.ResourceLot, DecodeFailure) {
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
    result.map(text(raw_0, "", ""), composition_plan.LotId),
  ))
  use raw_1 <- result.try(field(members, "token_type"))
  use a1 <- result.try(named("token_type", decode_type_id(raw_1)))
  use raw_2 <- result.try(field(members, "producer"))
  use a2 <- result.try(named("producer", decode_resource_producer(raw_2)))
  use raw_3 <- result.try(field(members, "revision"))
  use a3 <- result.try(named("revision", integer(raw_3, True)))
  use raw_4 <- result.try(field(members, "quantity"))
  use a4 <- result.try(named("quantity", integer(raw_4, True)))
  use raw_5 <- result.try(field(members, "provenance"))
  use a5 <- result.try(named("provenance", text(raw_5, "", "")))
  Ok(composition_plan.ResourceLot(a0, a1, a2, a3, a4, a5))
}

pub fn decode_resource_lot_ref(
  value: kdl.JsonValue,
) -> Result(composition_plan.ResourceLotRef, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "Initial" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        result.map(text(payload, "", ""), composition_plan.LotId),
      ))
      Ok(composition_plan.InitialLot(decoded))
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
        result.map(text(raw_0, "", ""), composition_plan.SiteId),
      ))
      use raw_1 <- result.try(field(members, "outcome"))
      use a1 <- result.try(named(
        "outcome",
        result.map(text(raw_1, "", ""), composition_plan.OutcomeId),
      ))
      use raw_2 <- result.try(field(members, "production"))
      use a2 <- result.try(named(
        "production",
        result.map(text(raw_2, "", ""), composition_plan.ProductionId),
      ))
      Ok(composition_plan.ProducedLot(a0, a1, a2))
    }
    other -> unknown_tag(other)
  }
}

pub fn decode_resource_producer(
  value: kdl.JsonValue,
) -> Result(composition_plan.ResourceProducer, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "Initial" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["identity", "revision"]))
      use raw_0 <- result.try(field(members, "identity"))
      use a0 <- result.try(named("identity", text(raw_0, "", "")))
      use raw_1 <- result.try(field(members, "revision"))
      use a1 <- result.try(named("revision", text(raw_1, "", "")))
      Ok(composition_plan.InitialResource(a0, a1))
    }
    "InvocationOutcome" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["site", "outcome"]))
      use raw_0 <- result.try(field(members, "site"))
      use a0 <- result.try(named(
        "site",
        result.map(text(raw_0, "", ""), composition_plan.SiteId),
      ))
      use raw_1 <- result.try(field(members, "outcome"))
      use a1 <- result.try(named(
        "outcome",
        result.map(text(raw_1, "", ""), composition_plan.OutcomeId),
      ))
      Ok(composition_plan.OutcomeResource(a0, a1))
    }
    other -> unknown_tag(other)
  }
}

pub fn decode_resource_production(
  value: kdl.JsonValue,
) -> Result(composition_plan.ResourceProduction, DecodeFailure) {
  use members <- result.try(
    object(value, ["id", "token_type", "revision", "quantity", "provenance"]),
  )
  use raw_0 <- result.try(field(members, "id"))
  use a0 <- result.try(named(
    "id",
    result.map(text(raw_0, "", ""), composition_plan.ProductionId),
  ))
  use raw_1 <- result.try(field(members, "token_type"))
  use a1 <- result.try(named("token_type", decode_type_id(raw_1)))
  use raw_2 <- result.try(field(members, "revision"))
  use a2 <- result.try(named("revision", integer(raw_2, True)))
  use raw_3 <- result.try(field(members, "quantity"))
  use a3 <- result.try(named("quantity", integer(raw_3, True)))
  use raw_4 <- result.try(field(members, "provenance"))
  use a4 <- result.try(named("provenance", text(raw_4, "", "")))
  Ok(composition_plan.ResourceProduction(a0, a1, a2, a3, a4))
}

pub fn decode_resource_requirement(
  value: kdl.JsonValue,
) -> Result(composition_plan.ResourceRequirement, DecodeFailure) {
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
    result.map(text(raw_0, "", ""), composition_plan.RequirementId),
  ))
  use raw_1 <- result.try(field(members, "token_type"))
  use a1 <- result.try(named("token_type", decode_type_id(raw_1)))
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
  Ok(composition_plan.ResourceRequirement(a0, a1, a2, a3, a4, a5))
}

pub fn decode_return_plan(
  value: kdl.JsonValue,
  wire: DerivationDecoder,
) -> Result(composition_plan.ReturnPlan, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "Success" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      use decoded <- result.try(named(
        "value",
        array(payload, fn(value) { decode_tuple_15(value, wire) }),
      ))
      Ok(composition_plan.ReturnSuccess(decoded))
    }
    "Failure" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["embedding", "value"]))
      use raw_0 <- result.try(field(members, "embedding"))
      use a0 <- result.try(named(
        "embedding",
        result.map(text(raw_0, "", ""), composition_plan.FailureEmbeddingId),
      ))
      use raw_1 <- result.try(field(members, "value"))
      use a1 <- result.try(named("value", decode_binding_expr(raw_1, wire)))
      Ok(composition_plan.ReturnFailure(a0, a1))
    }
    other -> unknown_tag(other)
  }
}

pub fn decode_search_bounds(
  value: kdl.JsonValue,
) -> Result(composition_plan.SearchBounds, DecodeFailure) {
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
  Ok(composition_plan.SearchBounds(a0, a1, a2, a3, a5, a4))
}

pub fn decode_selection_policy(
  value: kdl.JsonValue,
) -> Result(composition_plan.SelectionPolicy, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "RequireUnique" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.RequireUnique)
    }
    "AnyFeasible" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.AnyFeasible)
    }
    other -> unknown_tag(other)
  }
}

pub fn decode_semantic_basis(
  value: kdl.JsonValue,
) -> Result(composition_plan.SemanticBasis, DecodeFailure) {
  use members <- result.try(object(value, ["profile", "sources"]))
  use raw_0 <- result.try(field(members, "profile"))
  use a0 <- result.try(named("profile", decode_semantic_profile(raw_0)))
  use raw_1 <- result.try(field(members, "sources"))
  use a1 <- result.try(named(
    "sources",
    array(raw_1, fn(value) { decode_source_ref(value) }),
  ))
  Ok(composition_plan.SemanticBasis(a0, a1))
}

pub fn decode_signature_slot_contract(
  value: kdl.JsonValue,
) -> Result(types.SlotContract, DecodeFailure) {
  use members <- result.try(object(value, ["type_id", "required", "nullable"]))
  use raw_0 <- result.try(field(members, "type_id"))
  use a0 <- result.try(named("type_id", decode_type_id(raw_0)))
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
  use tag <- result.try(named("tag", text(tag_value, "", "")))
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
      use decoded <- result.try(named("value", decode_exact(payload)))
      Ok(types.Present(decoded))
    }
    other -> unknown_tag(other)
  }
}

pub fn decode_source_constraint(
  value: kdl.JsonValue,
) -> Result(composition_plan.SourceConstraint, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
  case tag {
    "AnyCompatible" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(composition_plan.AnyCompatible)
    }
    "InitialOnly" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(members, "fields"))
      use members <- result.try(object(payload, ["input", "path"]))
      use raw_0 <- result.try(field(members, "input"))
      use a0 <- result.try(named(
        "input",
        result.map(text(raw_0, "", ""), composition_plan.InputId),
      ))
      use raw_1 <- result.try(field(members, "path"))
      use a1 <- result.try(named("path", array(raw_1, decode_path_step)))
      Ok(composition_plan.InitialOnly(a0, a1))
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
        result.map(text(raw_0, "", ""), composition_plan.SiteId),
      ))
      use raw_1 <- result.try(field(members, "outcome"))
      use a1 <- result.try(named(
        "outcome",
        result.map(text(raw_1, "", ""), composition_plan.OutcomeId),
      ))
      use raw_2 <- result.try(field(members, "port"))
      use a2 <- result.try(named(
        "port",
        result.map(text(raw_2, "", ""), composition_plan.PortId),
      ))
      use raw_3 <- result.try(field(members, "path"))
      use a3 <- result.try(named("path", array(raw_3, decode_path_step)))
      Ok(composition_plan.ProducedBy(a0, a1, a2, a3))
    }
    other -> unknown_tag(other)
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
  use a3 <- result.try(named("content_digest", text(raw_3, "", "")))
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
  use tag <- result.try(named("tag", text(tag_value, "", "")))
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
    other -> unknown_tag(other)
  }
}

pub fn decode_token_kind(
  value: kdl.JsonValue,
) -> Result(resource.TokenKind, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
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
    other -> unknown_tag(other)
  }
}

pub fn decode_type_pair(
  value: kdl.JsonValue,
) -> Result(composition_plan.TypePair, DecodeFailure) {
  use members <- result.try(
    object(value, ["source", "destination", "source_tag"]),
  )
  use raw_0 <- result.try(field(members, "source"))
  use a0 <- result.try(named("source", decode_signature_slot_contract(raw_0)))
  use raw_1 <- result.try(field(members, "destination"))
  use a1 <- result.try(named(
    "destination",
    decode_signature_slot_contract(raw_1),
  ))
  use raw_2 <- result.try(field(members, "source_tag"))
  use a2 <- result.try(named(
    "source_tag",
    optional(raw_2, fn(value) { text(value, "", "") }),
  ))
  Ok(composition_plan.TypePair(a0, a1, a2))
}

pub fn decode_type_id(
  value: kdl.JsonValue,
) -> Result(types.TypeRef, DecodeFailure) {
  result.map(text(value, "", ""), fn(id) {
    types.TypeRef(types.type_source(), id, [])
  })
}

pub fn decode_definition_id(
  value: kdl.JsonValue,
) -> Result(types.DefinitionRef, DecodeFailure) {
  result.map(text(value, "", ""), fn(id) {
    types.DefinitionRef(types.type_source(), id)
  })
}

pub fn decode_value_ref(
  value: kdl.JsonValue,
) -> Result(composition_plan.ValueRef, DecodeFailure) {
  use members <- result.try(object(value, ["producer", "path"]))
  use raw_0 <- result.try(field(members, "producer"))
  use a0 <- result.try(named("producer", decode_producer_ref(raw_0)))
  use raw_1 <- result.try(field(members, "path"))
  use a1 <- result.try(named(
    "path",
    array(raw_1, fn(value) { decode_path_step(value) }),
  ))
  Ok(composition_plan.ValueRef(a0, a1))
}

pub fn encode_value_failure(
  value: types.ValueFailure,
) -> Result(kdl.JsonValue, DecodeFailure) {
  let types.ValueFailure(
    type_ref,
    definition_ref,
    origin,
    path,
    condition,
    observed,
    trace,
  ) = value
  use type_ref <- result.try(encode_type_ref(type_ref))
  use definition_ref <- result.try(encode_definition_ref(definition_ref))
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
      #("type_ref", type_ref),
      #("definition_ref", definition_ref),
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
  wire: DerivationDecoder,
) -> Result(#(String, composition_plan.BindingExpr), DecodeFailure) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(0, text(v0, "", "")))
      use a1 <- result.try(at(1, decode_binding_expr(v1, wire)))
      Ok(#(a0, a1))
    }
    _ -> fail("exact tuple arity")
  }
}

fn decode_tuple_2(
  value: kdl.JsonValue,
) -> Result(#(composition_plan.SiteId, composition_plan.SiteId), DecodeFailure) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(
        0,
        result.map(text(v0, "", ""), composition_plan.SiteId),
      ))
      use a1 <- result.try(at(
        1,
        result.map(text(v1, "", ""), composition_plan.SiteId),
      ))
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

fn decode_tuple_8(
  value: kdl.JsonValue,
  wire: DerivationDecoder,
) -> Result(
  #(composition_plan.PortId, composition_plan.BindingExpr),
  DecodeFailure,
) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(
        0,
        result.map(text(v0, "", ""), composition_plan.PortId),
      ))
      use a1 <- result.try(at(1, decode_binding_expr(v1, wire)))
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
  wire: DerivationDecoder,
) -> Result(
  #(composition_plan.OutcomeId, composition_plan.PlanTree),
  DecodeFailure,
) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(
        0,
        result.map(text(v0, "", ""), composition_plan.OutcomeId),
      ))
      use a1 <- result.try(at(1, decode_plan_tree(v1, wire)))
      Ok(#(a0, a1))
    }
    _ -> fail("exact tuple arity")
  }
}

fn decode_tuple_13(
  value: kdl.JsonValue,
  wire: DerivationDecoder,
) -> Result(
  #(composition_plan.GuardArm, composition_plan.PlanTree),
  DecodeFailure,
) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(0, decode_guard_arm(v0)))
      use a1 <- result.try(at(1, decode_plan_tree(v1, wire)))
      Ok(#(a0, a1))
    }
    _ -> fail("exact tuple arity")
  }
}

fn decode_tuple_15(
  value: kdl.JsonValue,
  wire: DerivationDecoder,
) -> Result(
  #(composition_plan.GoalPortId, composition_plan.BindingExpr),
  DecodeFailure,
) {
  case value {
    kdl.JsonValueArr([v0, v1]) -> {
      use a0 <- result.try(at(
        0,
        result.map(text(v0, "", ""), composition_plan.GoalPortId),
      ))
      use a1 <- result.try(at(1, decode_binding_expr(v1, wire)))
      Ok(#(a0, a1))
    }
    _ -> fail("exact tuple arity")
  }
}

fn fail(reason: String) -> Result(a, DecodeFailure) {
  Error(SyntaxFailure([], reason))
}

pub fn unknown_tag_failure(tag: String) -> DecodeFailure {
  UnknownTag(["$", "tag"], tag)
}

pub fn failure_classification(failure: DecodeFailure) -> String {
  case failure {
    UnknownField(_, _) -> "UnknownField"
    UnknownTag(_, _) -> "UnknownTag"
    _ -> "Syntax"
  }
}

pub fn failure_path(failure: DecodeFailure) -> String {
  case failure {
    UnknownField(path, name) -> render_path(list.append(path, [name]))
    UnknownTag(path, _) -> render_path(path)
    SyntaxFailure(path, _) -> render_path(path)
    ProfileFailure(_) -> "$"
    CompositionFailure(_) -> "$"
  }
}

fn render_path(path: List(String)) -> String {
  let steps = case path {
    ["$", ..rest] -> rest
    _ -> path
  }
  list.fold(steps, "$", fn(rendered, step) {
    case string.starts_with(step, "[") {
      True -> rendered <> step
      False -> rendered <> "." <> step
    }
  })
}

fn unknown_tag(tag: String) -> Result(a, DecodeFailure) {
  Error(unknown_tag_failure(tag))
}

fn unit_variant(value: kdl.JsonValue, variant: a) -> Result(a, DecodeFailure) {
  use _ <- result.try(object(value, ["tag"]))
  Ok(variant)
}

fn payload_of(
  value: kdl.JsonValue,
  members: List(#(String, kdl.JsonValue)),
) -> Result(kdl.JsonValue, DecodeFailure) {
  use _ <- result.try(object(value, ["tag", "value"]))
  field(members, "value")
}

pub fn prepend_path(name: String, failure: DecodeFailure) -> DecodeFailure {
  case failure {
    ProfileFailure(_) -> failure
    CompositionFailure(_) -> failure
    UnknownField(path, field) -> UnknownField(prepend_step(name, path), field)
    UnknownTag(path, tag) -> UnknownTag(prepend_step(name, path), tag)
    SyntaxFailure(path, reason) ->
      SyntaxFailure(prepend_step(name, path), reason)
  }
}

fn prepend_step(name: String, path: List(String)) -> List(String) {
  case path {
    ["$", ..rest] -> ["$", name, ..rest]
    _ -> [name, ..path]
  }
}

fn named(
  name: String,
  value: Result(a, DecodeFailure),
) -> Result(a, DecodeFailure) {
  result.map_error(value, prepend_path(name, _))
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
  duplicate_from(dict.new(), members)
}

fn duplicate_from(
  seen: Dict(String, Nil),
  members: List(#(String, kdl.JsonValue)),
) -> Bool {
  case members {
    [] -> False
    [#(key, _), ..rest] ->
      dict.has_key(seen, key)
      || duplicate_from(dict.insert(seen, key, Nil), rest)
  }
}

pub fn object(
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
        Ok(key) -> Error(SyntaxFailure([key], "missing field"))
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
        fn(entry) {
          named("[" <> int.to_string(entry.1) <> "]", decoder(entry.0))
        },
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

pub fn decode_exact(
  value: kdl.JsonValue,
) -> Result(kdl.JsonValue, DecodeFailure) {
  use tag <- result.try(exact_tag(value))
  case tag {
    "Null" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(kdl.JsonValueNull)
    }
    "Bool" -> {
      use members <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      result.map(boolean(payload), kdl.JsonValueBool)
    }
    "Integer" -> {
      use members <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      result.map(integer(payload, False), kdl.JsonValueNum)
    }
    "String" -> {
      use members <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(members, "value"))
      result.map(text(payload, "", ""), kdl.JsonValueStr)
    }
    "Decimal" -> {
      use members <- result.try(object(value, ["tag", "text"]))
      use payload <- result.try(field(members, "text"))
      use decimal <- result.try(named("text", text(payload, "", "")))
      use _ <- result.try(case string.trim(decimal) == decimal {
        True -> Ok(Nil)
        False -> Error(SyntaxFailure(["text"], "decimal whitespace"))
      })
      case values.parse_wire(decimal) {
        Ok(kdl.JsonValueNum(_)) | Ok(kdl.JsonValueDec(_)) ->
          Ok(kdl.JsonValueDec(decimal))
        _ -> Error(SyntaxFailure(["text"], "invalid exact decimal"))
      }
    }
    "Array" -> {
      use members <- result.try(object(value, ["tag", "items"]))
      use payload <- result.try(field(members, "items"))
      use items <- result.try(exact_array(payload))
      result.map(list.try_map(items, decode_exact), kdl.JsonValueArr)
    }
    "Object" -> {
      use members <- result.try(object(value, ["tag", "members"]))
      use payload <- result.try(field(members, "members"))
      use entries <- result.try(exact_array(payload))
      result.map(list.try_map(entries, exact_member), kdl.JsonValueObj)
    }
    other -> unknown_tag(other)
  }
}

fn exact_tag(value: kdl.JsonValue) -> Result(String, DecodeFailure) {
  case value {
    kdl.JsonValueObj(members) ->
      case list.key_find(members, "tag") {
        Ok(kdl.JsonValueStr(tag)) -> Ok(tag)
        Ok(_) -> Error(SyntaxFailure(["tag"], "string required"))
        Error(_) -> Error(SyntaxFailure(["tag"], "missing field"))
      }
    _ -> Error(SyntaxFailure(["tag"], "object required"))
  }
}

fn exact_array(
  value: kdl.JsonValue,
) -> Result(List(kdl.JsonValue), DecodeFailure) {
  case value {
    kdl.JsonValueArr(items) -> Ok(items)
    _ -> fail("array required")
  }
}

fn exact_member(
  entry: kdl.JsonValue,
) -> Result(#(String, kdl.JsonValue), DecodeFailure) {
  use members <- result.try(object(entry, ["key", "value"]))
  use raw_key <- result.try(field(members, "key"))
  use key <- result.try(named("key", text(raw_key, "", "")))
  use raw_value <- result.try(field(members, "value"))
  use decoded <- result.try(decode_exact(raw_value))
  Ok(#(key, decoded))
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
  value: composition_plan.FieldPresence,
) -> Result(kdl.JsonValue, DecodeFailure) {
  let tag = case value {
    composition_plan.Required -> "Required"
    composition_plan.Optional -> "Optional"
  }
  Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr(tag))]))
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
      use e0 <- result.try(case v0 {
        None -> Ok(kdl.JsonValueNull)
        Some(item) -> Ok(kdl.JsonValueStr(int.to_string(item)))
      })
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
  value: composition_plan.SourceConstraint,
) -> Result(kdl.JsonValue, DecodeFailure) {
  case value {
    composition_plan.AnyCompatible -> {
      Ok(kdl.JsonValueObj([#("tag", kdl.JsonValueStr("AnyCompatible"))]))
    }
    composition_plan.InitialOnly(v0, v1) -> {
      use e0 <- result.try({
        let composition_plan.InputId(inner) = v0
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
    composition_plan.ProducedBy(v0, v1, v2, v3) -> {
      use e0 <- result.try({
        let composition_plan.SiteId(inner) = v0
        Ok(kdl.JsonValueStr(inner))
      })
      use e1 <- result.try({
        let composition_plan.OutcomeId(inner) = v1
        Ok(kdl.JsonValueStr(inner))
      })
      use e2 <- result.try({
        let composition_plan.PortId(inner) = v2
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
    SyntaxFailure([], "invalid ExactJson")
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
  use identity <- result.try(named(
    "identity",
    field(members, "identity") |> result.try(fn(value) { text(value, "", "") }),
  ))
  use revision <- result.try(named(
    "revision",
    field(members, "revision") |> result.try(fn(value) { text(value, "", "") }),
  ))
  use content_digest <- result.try(named(
    "content_digest",
    field(members, "content_digest")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
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
  use tag <- result.try(named(
    "tag",
    field(members, "tag")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  case tag {
    "Number" -> unit_variant(value, types.Number)
    "IntegralDecimal" -> unit_variant(value, types.IntegralDecimal)
    "DecimalString" -> unit_variant(value, types.DecimalString)
    other -> unknown_tag(other)
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
  use name <- result.try(named(
    "name",
    field(members, "name")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  use reference <- result.try(named(
    "reference",
    field(members, "reference") |> result.try(decode_profile_reference),
  ))
  use range <- result.try(named(
    "range",
    field(members, "range") |> result.try(decode_integer_domain),
  ))
  use forms <- result.try(named(
    "forms",
    field(members, "forms")
      |> result.try(fn(value) { array(value, decode_integer_form_field) }),
  ))
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
  use decimals <- result.try(named(
    "decimals",
    field(members, "decimals") |> result.try(boolean),
  ))
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
  use tag <- result.try(named(
    "tag",
    field(members, "tag")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  case tag {
    "Standard" -> unit_variant(value, types.Standard)
    "UrlSafe" -> unit_variant(value, types.UrlSafe)
    "Either" -> unit_variant(value, types.Either)
    other -> unknown_tag(other)
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
  use tag <- result.try(named(
    "tag",
    field(members, "tag")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
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
    other -> unknown_tag(other)
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
  use name <- result.try(named(
    "name",
    field(members, "name")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  use key <- result.try(named(
    "key",
    field(members, "key")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  use payload <- result.try(named(
    "payload",
    field(members, "payload") |> result.try(decode_wrapper_payload_field),
  ))
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
  use unit <- result.try(named(
    "unit",
    field(members, "unit") |> result.try(decode_string_length_unit),
  ))
  use minimum <- result.try(named(
    "minimum",
    field(members, "minimum")
      |> result.try(fn(value) {
        optional(value, fn(value) { integer(value, True) })
      }),
  ))
  use maximum <- result.try(named(
    "maximum",
    field(members, "maximum")
      |> result.try(fn(value) {
        optional(value, fn(value) { integer(value, True) })
      }),
  ))
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
  use tag <- result.try(named(
    "tag",
    field(members, "tag")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  case tag {
    "Named" -> {
      use payload <- result.try(payload_of(value, members))
      result.map(text(payload, "", ""), types.NamedFormat)
    }
    "Inline" -> {
      use payload <- result.try(payload_of(value, members))
      result.map(decode_format_rule(payload), types.InlineFormat)
    }
    other -> unknown_tag(other)
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
  use enum_values <- result.try(named(
    "enum_values",
    field(members, "enum_values")
      |> result.try(fn(value) {
        optional(value, fn(value) {
          array(value, fn(value) { integer(value, False) })
        })
      }),
  ))
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
    named(
      name,
      field(members, name)
        |> result.try(fn(value) {
          optional(value, fn(value) { text(value, "", "") })
        }),
    )
  }
  use format <- result.try(named(
    "format",
    field(members, "format")
      |> result.try(fn(value) { optional(value, decode_format_use) }),
  ))
  use lengths <- result.try(named(
    "lengths",
    field(members, "lengths")
      |> result.try(fn(value) { array(value, decode_length_bound_field) }),
  ))
  use wrapper <- result.try(optional_text("wrapper"))
  use const_value <- result.try(optional_text("const_value"))
  use enum_values <- result.try(named(
    "enum_values",
    field(members, "enum_values")
      |> result.try(fn(value) {
        optional(value, fn(value) {
          array(value, fn(value) { text(value, "", "") })
        })
      }),
  ))
  use examples <- result.try(named(
    "examples",
    field(members, "examples")
      |> result.try(fn(value) {
        array(value, fn(value) { text(value, "", "") })
      }),
  ))
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
  use tag <- result.try(named(
    "tag",
    field(members, "tag")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  case tag {
    "String" -> {
      use payload <- result.try(payload_of(value, members))
      result.map(decode_string_spec(payload), types.SealedString)
    }
    "Integer" -> {
      use payload <- result.try(payload_of(value, members))
      result.map(decode_integer_spec(payload), types.SealedInteger)
    }
    other -> unknown_tag(other)
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
  use key <- result.try(named(
    "key",
    field(members, "key")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  use required <- result.try(named(
    "required",
    field(members, "required") |> result.try(boolean),
  ))
  use leaf <- result.try(named(
    "leaf",
    field(members, "leaf") |> result.try(decode_sealed_leaf),
  ))
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
  use tag <- result.try(named(
    "tag",
    field(members, "tag")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  case tag {
    "Reject" -> unit_variant(value, types.SealedReject)
    "Any" -> unit_variant(value, types.SealedAny)
    other -> unknown_tag(other)
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
  use tag <- result.try(named(
    "tag",
    field(members, "tag")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  use fields <- result.try(named(
    "fields",
    field(members, "fields")
      |> result.try(fn(value) { array(value, decode_sealed_field_field) }),
  ))
  use extras <- result.try(named(
    "extras",
    field(members, "extras") |> result.try(decode_sealed_extras_field),
  ))
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
  use key <- result.try(named(
    "key",
    field(members, "key")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  use format <- result.try(named(
    "format",
    field(members, "format")
      |> result.try(fn(value) {
        optional(value, fn(value) { text(value, "", "") })
      }),
  ))
  use sealed <- result.try(named(
    "sealed",
    field(members, "sealed")
      |> result.try(fn(value) { array(value, decode_sealed_form_field) }),
  ))
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
  use reference <- result.try(named(
    "reference",
    field(members, "reference") |> result.try(decode_profile_reference),
  ))
  use padding_optional <- result.try(named(
    "padding_optional",
    field(members, "padding_optional") |> result.try(boolean),
  ))
  use alphabet <- result.try(named(
    "alphabet",
    field(members, "alphabet") |> result.try(decode_bytes_alphabet_field),
  ))
  use strict_pad_bits <- result.try(named(
    "strict_pad_bits",
    field(members, "strict_pad_bits") |> result.try(boolean),
  ))
  use wrapper <- result.try(named(
    "wrapper",
    field(members, "wrapper")
      |> result.try(fn(value) {
        optional(value, fn(value) { text(value, "", "") })
      }),
  ))
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
  use reference <- result.try(named(
    "reference",
    field(members, "reference") |> result.try(decode_profile_reference),
  ))
  use source_refs <- result.try(named(
    "source_refs",
    field(members, "source_refs")
      |> result.try(fn(value) { array(value, decode_source_identity_field) }),
  ))
  use integer_domains <- result.try(named(
    "integer_domains",
    field(members, "integer_domains")
      |> result.try(fn(value) {
        array(value, decode_integer_domain_binding_field)
      }),
  ))
  use default_integer_domain <- result.try(named(
    "default_integer_domain",
    field(members, "default_integer_domain")
      |> result.try(fn(value) { text(value, "", "") }),
  ))
  use numbers <- result.try(named(
    "numbers",
    field(members, "numbers") |> result.try(decode_number_model_field),
  ))
  use grapheme_rules <- result.try(named(
    "grapheme_rules",
    field(members, "grapheme_rules")
      |> result.try(fn(value) { optional(value, decode_grapheme_rules) }),
  ))
  use format_bindings <- result.try(named(
    "format_bindings",
    field(members, "format_bindings")
      |> result.try(fn(value) { array(value, decode_format_binding) }),
  ))
  use bytes_policy <- result.try(named(
    "bytes_policy",
    field(members, "bytes_policy")
      |> result.try(fn(value) { optional(value, decode_bytes_policy_field) }),
  ))
  use wrappers <- result.try(named(
    "wrappers",
    field(members, "wrappers")
      |> result.try(fn(value) { array(value, decode_wrapper_field) }),
  ))
  use tag <- result.try(named(
    "tag",
    field(members, "tag")
      |> result.try(fn(value) { optional(value, decode_tag_model_field) }),
  ))
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
) -> Result(validation.CheckedProfile, DecodeFailure) {
  use profile <- result.try(decode_semantic_profile(value))
  validation.check_profile(profile)
  |> result.map_error(ProfileFailure)
}

pub fn decode_value_condition(
  value: kdl.JsonValue,
) -> Result(types.ValueCondition, DecodeFailure) {
  use members <- result.try(tagged(value))
  use tag_value <- result.try(field(members, "tag"))
  use tag <- result.try(named("tag", text(tag_value, "", "")))
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
    other -> unknown_tag(other)
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

pub fn encode_semantic_reason(value: types.SemanticReason) -> kdl.JsonValue {
  let #(tag, payload) = case value {
    types.UnknownFormatReason(name) -> #("UnknownFormat", Some(name))
    types.MissingGraphemeRulesReason -> #("MissingGraphemeRules", None)
    types.MissingBytesPolicyReason -> #("MissingBytesPolicy", None)
    types.UnknownIntegerDomainReason(name) -> #(
      "UnknownIntegerDomain",
      Some(name),
    )
    types.UnknownWrapperReason(name) -> #("UnknownWrapper", Some(name))
    types.WrapperPayloadReason(name) -> #("WrapperPayload", Some(name))
    types.UnknownSealedTagReason(tag) -> #("UnknownSealedTag", Some(tag))
    types.DecimalNotAdmittedReason -> #("DecimalNotAdmitted", None)
    types.IntegerBoundReason -> #("IntegerBound", None)
    types.OpaqueTypeReason(name) -> #("OpaqueType", Some(name))
    types.MissingTagModelReason -> #("MissingTagModel", None)
    types.UnresolvedTypeReason -> #("UnresolvedType", None)
    types.MembershipBoundReason -> #("MembershipBound", None)
    types.UninterpretedExtensionReason(key) -> #(
      "UninterpretedExtension",
      Some(key),
    )
    types.InvalidProfileReason(condition) -> #(
      "InvalidProfile",
      Some(condition),
    )
    types.CertificateMismatchReason(condition) -> #(
      "CertificateMismatch",
      Some(condition),
    )
    types.ProjectionUnavailableReason(condition) -> #(
      "ProjectionUnavailable",
      Some(condition),
    )
  }
  case payload {
    None -> wire_unit_tag(tag)
    Some(payload) -> wire_tuple_tag(tag, kdl.JsonValueStr(payload))
  }
}

pub fn encode_semantic_obligation(
  value: types.SemanticObligation,
) -> Result(kdl.JsonValue, DecodeFailure) {
  let types.SemanticObligation(type_ref, value_path, reason, origin, profile) =
    value
  use type_ref <- result.try(encode_type_ref(type_ref))
  use value_path <- result.try(result.map(
    list.try_map(value_path, encode_path_step),
    kdl.JsonValueArr,
  ))
  use origin <- result.try(encode_occurrence_ref(origin))
  use profile <- result.try(encode_profile_ref(profile))
  Ok(
    kdl.JsonValueObj([
      #("type_ref", type_ref),
      #("origin", origin),
      #("value_path", value_path),
      #("profile", profile),
      #("reason", encode_semantic_reason(reason)),
    ]),
  )
}

fn wire_nat(value: Int) -> kdl.JsonValue {
  kdl.JsonValueStr(int.to_string(value))
}

fn wire_text_list(values: List(String)) -> kdl.JsonValue {
  kdl.JsonValueArr(list.map(values, kdl.JsonValueStr))
}

fn wire_unit_tag(tag: String) -> kdl.JsonValue {
  kdl.JsonValueObj([#("tag", kdl.JsonValueStr(tag))])
}

fn wire_tuple_tag(tag: String, value: kdl.JsonValue) -> kdl.JsonValue {
  kdl.JsonValueObj([#("tag", kdl.JsonValueStr(tag)), #("value", value)])
}

fn wire_record_tag(
  tag: String,
  fields: List(#(String, kdl.JsonValue)),
) -> kdl.JsonValue {
  kdl.JsonValueObj([
    #("tag", kdl.JsonValueStr(tag)),
    #("fields", kdl.JsonValueObj(fields)),
  ])
}

pub fn encode_token_kind(value: resource.TokenKind) -> kdl.JsonValue {
  wire_unit_tag(case value {
    resource.TokenInput -> "Input"
    resource.TokenOutput -> "Output"
    resource.TokenFailure -> "Failure"
    resource.TokenEffect -> "Effect"
    resource.TokenObservation -> "Observation"
    resource.TokenAccepted -> "Accepted"
  })
}

pub fn encode_binding_mode(value: resource.BindingMode) -> kdl.JsonValue {
  wire_unit_tag(case value {
    resource.Read -> "Read"
    resource.Consume -> "Consume"
  })
}

pub fn encode_colored_token(value: resource.ColoredToken) -> kdl.JsonValue {
  kdl.JsonValueObj([
    #("target", kdl.JsonValueStr(value.target)),
    #("index", wire_nat(value.index)),
    #("revision", wire_nat(value.revision)),
    #("kind", encode_token_kind(value.kind)),
  ])
}

pub fn encode_typed_place(value: resource.TypedPlace) -> kdl.JsonValue {
  kdl.JsonValueObj([
    #("identity", kdl.JsonValueStr(value.identity)),
    #("token_type", kdl.JsonValueStr(value.token_type)),
    #("revision", wire_nat(value.revision)),
  ])
}

pub fn encode_typed_transition(
  value: resource.TypedTransition,
) -> kdl.JsonValue {
  kdl.JsonValueObj([
    #("identity", kdl.JsonValueStr(value.identity)),
    #("input_places", wire_text_list(value.input_places)),
    #("output_places", wire_text_list(value.output_places)),
    #("failure_places", wire_text_list(value.failure_places)),
    #("revision", wire_nat(value.revision)),
  ])
}

pub fn encode_input_binding(value: resource.InputBinding) -> kdl.JsonValue {
  kdl.JsonValueObj([
    #("transition_id", kdl.JsonValueStr(value.transition_id)),
    #("name", kdl.JsonValueStr(value.name)),
    #("place", kdl.JsonValueStr(value.place)),
    #("token_type", kdl.JsonValueStr(value.token_type)),
    #("identity", kdl.JsonValueStr(value.identity)),
    #("provenance", kdl.JsonValueStr(value.provenance)),
    #("multiplicity", wire_nat(value.multiplicity)),
    #("mode", encode_binding_mode(value.mode)),
    #("required_revision", wire_nat(value.required_revision)),
  ])
}

pub fn encode_declaration_graph(
  value: resource.DeclarationGraph,
) -> kdl.JsonValue {
  kdl.JsonValueObj([
    #("places", wire_text_list(value.places)),
    #("transitions", wire_text_list(value.transitions)),
    #(
      "edges",
      kdl.JsonValueArr(
        list.map(value.edges, fn(edge) { wire_text_list([edge.0, edge.1]) }),
      ),
    ),
    #("revision", wire_nat(value.revision)),
  ])
}

pub fn encode_domain_bound(value: resource.DomainBound) -> kdl.JsonValue {
  kdl.JsonValueObj([
    #("target_identity", kdl.JsonValueStr(value.target_identity)),
    #("index", wire_nat(value.index)),
    #("revision", wire_nat(value.revision)),
    #("max_bindings", wire_nat(value.max_bindings)),
    #("max_search_steps", wire_nat(value.max_search_steps)),
  ])
}

pub fn encode_marking(value: resource.Marking) -> kdl.JsonValue {
  kdl.JsonValueObj([
    #(
      "places",
      kdl.JsonValueArr(
        list.map(value.places, fn(place) {
          kdl.JsonValueArr([
            kdl.JsonValueStr(place.0),
            kdl.JsonValueArr(list.map(place.1, encode_colored_token)),
          ])
        }),
      ),
    ),
  ])
}

pub fn encode_goal_predicate(value: resource.GoalPredicate) -> kdl.JsonValue {
  case value {
    resource.PlaceHasAtLeast(place, count) ->
      wire_record_tag("PlaceHasAtLeast", [
        #("place", kdl.JsonValueStr(place)),
        #("count", wire_nat(count)),
      ])
    resource.PlaceHasToken(place, target, index, revision) ->
      wire_record_tag("PlaceHasToken", [
        #("place", kdl.JsonValueStr(place)),
        #("target", kdl.JsonValueStr(target)),
        #("index", wire_nat(index)),
        #("revision", wire_nat(revision)),
      ])
    resource.GoalAnd(a, b) ->
      wire_tuple_tag(
        "And",
        kdl.JsonValueArr([encode_goal_predicate(a), encode_goal_predicate(b)]),
      )
    resource.GoalOr(a, b) ->
      wire_tuple_tag(
        "Or",
        kdl.JsonValueArr([encode_goal_predicate(a), encode_goal_predicate(b)]),
      )
    resource.GoalNot(a) -> wire_tuple_tag("Not", encode_goal_predicate(a))
  }
}

pub fn encode_solver_input(value: resource.SolverInput) -> kdl.JsonValue {
  kdl.JsonValueObj([
    #("places", kdl.JsonValueArr(list.map(value.places, encode_typed_place))),
    #(
      "transitions",
      kdl.JsonValueArr(list.map(value.transitions, encode_typed_transition)),
    ),
    #(
      "bindings",
      kdl.JsonValueArr(list.map(value.bindings, encode_input_binding)),
    ),
    #("goal", encode_goal_predicate(value.goal)),
    #("graph", encode_declaration_graph(value.graph)),
    #("marking", encode_marking(value.marking)),
    #("bound", encode_domain_bound(value.bound)),
  ])
}

pub fn encode_reachability_witness(
  value: resource.ReachabilityWitness,
) -> kdl.JsonValue {
  kdl.JsonValueObj([
    #("path", wire_text_list(value.path)),
    #("final_marking", encode_marking(value.final_marking)),
  ])
}

pub fn encode_acyclic_witness(value: resource.AcyclicWitness) -> kdl.JsonValue {
  kdl.JsonValueObj([
    #(
      "explored_markings",
      kdl.JsonValueArr(list.map(value.explored_markings, encode_marking)),
    ),
    #("steps", wire_nat(value.steps)),
    #("frontier", kdl.JsonValueArr(list.map(value.frontier, encode_marking))),
  ])
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
