// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import necoherence/composition_plan.{
  type InclusionCertificate, type InclusionFailure, type PairEntry,
  type SearchBounds, type SemanticBasis, type TypeObligation, ChildCoverage,
  ConstraintImplication, CounterexampleMismatch, EmptySource, ExtraField,
  FiniteStrings, ForgedEmptiness, InclusionArray, InclusionBasisMismatch,
  InclusionBoolean, InclusionCertificate, InclusionProduct, InclusionUnresolved,
  IntegerIntersection, MissingPair, ObligationBoundExhausted, PairEntry,
  PairMismatch, RuleMismatch, SameDefinedType, SearchBounds, SourceUnion,
  StringConditions, TypeMeaning, TypeObligation, TypePair, TypePresence,
  UndefinedMeaning, UnfoldDestination, UnfoldSource, UnionRemainder,
  semantic_basis_of,
}
import necoherence/exact_json as kdl
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation

pub type CounterexampleCertificate {
  CounterexampleCertificate(
    basis: SemanticBasis,
    source: types.SlotContract,
    destination: types.SlotContract,
    value: types.SlotValue(kdl.JsonValue),
    destination_failure: types.ValueFailure,
  )
}

pub type CompatibilityDecision {
  Compatible(certificate: InclusionCertificate)
  Incompatible(certificate: CounterexampleCertificate)
  CompatibilityUnknown(obligations: List(TypeObligation))
}

pub opaque type CheckedInclusion {
  CheckedInclusion(
    graph: types.SemanticGraph,
    certificate: InclusionCertificate,
  )
}

pub opaque type CheckedCounterexample {
  CheckedCounterexample(
    graph: types.SemanticGraph,
    certificate: CounterexampleCertificate,
  )
}

fn default_search_bounds() -> SearchBounds {
  SearchBounds(10_000, 100_000, 10_000, 100_000, 32, None)
}

fn distinct_from(items: List(a), seen: Dict(a, Nil), kept: List(a)) -> List(a) {
  case items {
    [] -> list.reverse(kept)
    [head, ..rest] ->
      case dict.has_key(seen, head) {
        True -> distinct_from(rest, seen, kept)
        False ->
          distinct_from(rest, dict.insert(seen, head, Nil), [head, ..kept])
      }
  }
}

pub fn distinct(items: List(a)) -> List(a) {
  distinct_from(items, dict.new(), [])
}

fn reference_set(refs: List(a)) -> Dict(a, Nil) {
  list.fold(refs, dict.new(), fn(set, reference) {
    dict.insert(set, reference, Nil)
  })
}

fn present_contract(reference: types.TypeRef) -> types.SlotContract {
  types.SlotContract(reference, True, False)
}

fn nat_range_empty(minimum: Option(Int), maximum: Option(Int)) -> Bool {
  case minimum, maximum {
    Some(minimum), Some(maximum) -> maximum < minimum
    _, _ -> False
  }
}

fn string_finite(spec: types.StringSpec) -> Option(List(String)) {
  case spec.const_value {
    Some(value) -> Some([value])
    None -> spec.enum_values
  }
}

pub fn resolved_shape(
  graph: types.SemanticGraph,
  reference: types.TypeRef,
) -> Option(types.TypeShape) {
  resolved_shape_fuel(graph, list.length(graph.nodes) + 1, reference)
}

fn resolved_shape_fuel(
  graph: types.SemanticGraph,
  fuel: Int,
  reference: types.TypeRef,
) -> Option(types.TypeShape) {
  case fuel <= 0 {
    True -> None
    False ->
      case
        option.from_result(
          list.find(graph.nodes, fn(node) { node.reference == reference }),
        )
      {
        None -> None
        Some(node) ->
          case node.shape {
            types.AliasShape(target, _) ->
              resolved_shape_fuel(graph, fuel - 1, target)
            shape -> Some(shape)
          }
      }
  }
}

fn check_empty_row(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
  refs: Dict(types.TypeRef, Nil),
  reference: types.TypeRef,
) -> Result(Nil, InclusionFailure) {
  use found <- result.try(option.to_result(
    validation.indexed_type(indexed, reference),
    ForgedEmptiness,
  ))
  case found.shape {
    types.AliasShape(target, _) ->
      case dict.has_key(refs, target) {
        True -> Ok(Nil)
        False -> Error(ForgedEmptiness)
      }
    types.IntegerShape(_) -> Error(ForgedEmptiness)
    types.StringShape(spec) ->
      case spec.wrapper {
        Some(_) -> Error(ForgedEmptiness)
        None ->
          case string_finite(spec) {
            Some(values) ->
              case
                list.all(values, fn(value) {
                  option.is_some(validation.string_condition(
                    graph.profile,
                    spec,
                    value,
                  ))
                })
              {
                True -> Ok(Nil)
                False -> Error(ForgedEmptiness)
              }
            None -> Error(ForgedEmptiness)
          }
      }
    types.BytesShape(spec) ->
      case nat_range_empty(spec.minimum, spec.maximum) {
        True -> Ok(Nil)
        False -> Error(ForgedEmptiness)
      }
    types.ProductShape(spec) ->
      case list.find(spec.fields, fn(field) { slot_empty(field.slot, refs) }) {
        Ok(_) -> Ok(Nil)
        Error(_) -> Error(ForgedEmptiness)
      }
    types.ArrayShape(spec) ->
      case nat_range_empty(spec.min_length, spec.max_length) {
        True -> Ok(Nil)
        False ->
          case
            0 < option.unwrap(spec.min_length, 0)
            && !spec.item.nullable
            && dict.has_key(refs, spec.item.type_ref)
          {
            True -> Ok(Nil)
            False -> Error(ForgedEmptiness)
          }
      }
    types.TaggedUnionShape(spec) ->
      case
        list.all(spec.branches, fn(branch) { dict.has_key(refs, branch.target) })
      {
        True -> Ok(Nil)
        False -> Error(ForgedEmptiness)
      }
    _ -> Error(ForgedEmptiness)
  }
}

pub fn verify_empty_types(
  indexed: validation.PreparedGraph,
  refs: List(types.TypeRef),
) -> Result(Nil, InclusionFailure) {
  indexed_verify_empty_types(validation.prepared_graph(indexed), indexed, refs)
}

fn indexed_verify_empty_types(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
  refs: List(types.TypeRef),
) -> Result(Nil, InclusionFailure) {
  use _ <- result.try(case distinct(refs) == refs {
    True -> Ok(Nil)
    False -> Error(ForgedEmptiness)
  })
  let set = reference_set(refs)
  list.try_each(refs, fn(reference) {
    check_empty_row(graph, indexed, set, reference)
  })
}

fn empty_row_dependencies(shape: types.TypeShape) -> List(types.TypeRef) {
  case shape {
    types.AliasShape(target, _) -> [target]
    types.ProductShape(spec) ->
      list.map(spec.fields, fn(field) { field.slot.type_ref })
    types.ArrayShape(spec) -> [spec.item.type_ref]
    types.TaggedUnionShape(spec) ->
      list.map(spec.branches, fn(branch) { branch.target })
    _ -> []
  }
}

fn prune_empty_types(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
  dependents: Dict(types.TypeRef, List(types.TypeRef)),
  pending: List(types.TypeRef),
  refs: Dict(types.TypeRef, Nil),
) -> Dict(types.TypeRef, Nil) {
  case pending {
    [] -> refs
    [reference, ..rest] ->
      case
        dict.has_key(refs, reference)
        && result.is_error(check_empty_row(graph, indexed, refs, reference))
      {
        True ->
          prune_empty_types(
            graph,
            indexed,
            dependents,
            list.append(
              result.unwrap(dict.get(dependents, reference), []),
              rest,
            ),
            dict.delete(refs, reference),
          )
        False -> prune_empty_types(graph, indexed, dependents, rest, refs)
      }
  }
}

pub fn empty_types(indexed: validation.PreparedGraph) -> List(types.TypeRef) {
  indexed_empty_types(validation.prepared_graph(indexed), indexed)
}

fn indexed_empty_types(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
) -> List(types.TypeRef) {
  let refs = distinct(list.map(graph.nodes, fn(node) { node.reference }))
  let dependents =
    list.fold(refs, dict.new(), fn(dependents, reference) {
      case validation.indexed_type(indexed, reference) {
        None -> dependents
        Some(node) ->
          list.fold(
            empty_row_dependencies(node.shape),
            dependents,
            fn(dependents, dependency) {
              dict.upsert(dependents, dependency, fn(existing) {
                [reference, ..option.unwrap(existing, [])]
              })
            },
          )
      }
    })
  let retained =
    prune_empty_types(graph, indexed, dependents, refs, reference_set(refs))
  list.filter(refs, dict.has_key(retained, _))
}

fn slot_empty(
  contract: types.SlotContract,
  empty: Dict(types.TypeRef, Nil),
) -> Bool {
  contract.required
  && !contract.nullable
  && dict.has_key(empty, contract.type_ref)
}

fn format_rule_included(
  source: types.FormatRule,
  destination: types.FormatRule,
) -> Bool {
  format_rule_included_fuel(
    types.format_rule_depth(destination) + 1,
    source,
    destination,
  )
}

fn format_rule_included_fuel(
  fuel: Int,
  source: types.FormatRule,
  destination: types.FormatRule,
) -> Bool {
  case fuel <= 0 {
    True -> source == destination
    False ->
      source == destination
      || case destination {
        types.Text -> True
        types.Choice(rules) ->
          list.any(rules, fn(rule) {
            format_rule_included_fuel(fuel - 1, source, rule)
          })
        _ -> False
      }
  }
}

fn format_use_rule(
  profile: types.SemanticProfile,
  format_use: types.FormatUse,
) -> Option(types.FormatRule) {
  case format_use {
    types.InlineFormat(rule) -> Some(rule)
    types.NamedFormat(name) ->
      option.from_result(
        list.find(profile.format_bindings, fn(binding) { binding.name == name }),
      )
      |> option.map(fn(binding) { binding.rule })
  }
}

fn format_included(
  graph: types.SemanticGraph,
  source: Option(types.FormatUse),
  destination: Option(types.FormatUse),
) -> Bool {
  case destination {
    None -> True
    Some(destination) ->
      case
        option.then(source, format_use_rule(graph.profile, _)),
        format_use_rule(graph.profile, destination)
      {
        Some(source), Some(destination) ->
          format_rule_included(source, destination)
        _, _ -> False
      }
  }
}

pub fn verify_inclusion(
  indexed: validation.PreparedGraph,
  source: types.SlotContract,
  destination: types.SlotContract,
  certificate: InclusionCertificate,
) -> Result(CheckedInclusion, InclusionFailure) {
  indexed_verify_inclusion(
    validation.prepared_graph(indexed),
    indexed,
    source,
    destination,
    certificate,
  )
}

fn indexed_verify_inclusion(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
  source: types.SlotContract,
  destination: types.SlotContract,
  certificate: InclusionCertificate,
) -> Result(CheckedInclusion, InclusionFailure) {
  let root_matches =
    option.map(
      case certificate.root >= 0 {
        True ->
          option.from_result(
            list.first(list.drop(certificate.pairs, certificate.root)),
          )
        False -> None
      },
      fn(entry) {
        entry.pair.source.type_ref == source.type_ref
        && entry.pair.destination.type_ref == destination.type_ref
        && entry.pair.source_tag == None
      },
    )
    == Some(True)
  use _ <- result.try(
    case
      certificate.basis == semantic_basis_of(graph)
      && certificate.source == source
      && certificate.destination == destination
      && root_matches
    {
      True -> Ok(Nil)
      False -> Error(InclusionBasisMismatch)
    },
  )
  let source_meaning =
    validation.meaning_obligations(indexed, [source.type_ref])
  let destination_meaning =
    validation.meaning_obligations(indexed, [destination.type_ref])
  use _ <- result.try(case source_meaning, destination_meaning {
    [], [] -> Ok(Nil)
    _, _ ->
      Error(UndefinedMeaning(list.append(source_meaning, destination_meaning)))
  })
  use _ <- result.try(case presence_included(source, destination) {
    True -> Ok(Nil)
    False ->
      Error(
        InclusionUnresolved(TypeObligation(
          TypePair(source, destination, None),
          [],
          TypePresence,
        )),
      )
  })
  use _ <- result.try(
    case
      list.contains(pair_refs(certificate.pairs), #(
        source.type_ref,
        destination.type_ref,
      ))
    {
      True -> Ok(Nil)
      False -> Error(MissingPair)
    },
  )
  use _ <- result.try(indexed_verify_empty_types(
    graph,
    indexed,
    certificate.empty_types,
  ))
  use _ <- result.try(check_pair_table(
    graph,
    indexed,
    certificate.empty_types,
    certificate.pairs,
  ))
  Ok(CheckedInclusion(graph, certificate))
}

fn presence_included(
  source: types.SlotContract,
  destination: types.SlotContract,
) -> Bool {
  { source.required || !destination.required }
  && { !source.nullable || destination.nullable }
}

fn pair_refs(table: List(PairEntry)) -> List(#(types.TypeRef, types.TypeRef)) {
  list.map(table, fn(entry) {
    #(entry.pair.source.type_ref, entry.pair.destination.type_ref)
  })
}

fn lower_contained_int(source: Option(Int), destination: Option(Int)) -> Bool {
  case destination, source {
    None, _ -> True
    Some(bound), Some(minimum) -> bound <= minimum
    Some(_), None -> False
  }
}

fn upper_contained_int(source: Option(Int), destination: Option(Int)) -> Bool {
  case destination, source {
    None, _ -> True
    Some(bound), Some(maximum) -> maximum <= bound
    Some(_), None -> False
  }
}

fn upper_contained_nat(source: Option(Int), destination: Option(Int)) -> Bool {
  case destination, source {
    None, _ -> True
    Some(bound), Some(maximum) -> maximum <= bound
    Some(_), None -> False
  }
}

fn lower_contained_nat(source: Option(Int), destination: Option(Int)) -> Bool {
  case destination, source {
    None, _ -> True
    Some(bound), Some(minimum) -> bound <= minimum
    Some(bound), None -> bound == 0
  }
}

fn integer_number_only(
  profile: types.SemanticProfile,
  spec: types.IntegerSpec,
) -> Bool {
  case validation.integer_binding(profile, spec.domain) {
    Some(binding) -> binding.forms == [types.Number]
    None -> False
  }
}

fn integer_finite(spec: types.IntegerSpec) -> Option(List(Int)) {
  case spec.const_value {
    Some(value) -> Some([value])
    None -> spec.enum_values
  }
}

fn integer_rule_check(
  graph: types.SemanticGraph,
  source: types.IntegerSpec,
  destination: types.IntegerSpec,
) -> Bool {
  integer_number_only(graph.profile, source)
  && integer_number_only(graph.profile, destination)
  && source.domain == destination.domain
  && case integer_finite(source) {
    Some(values) ->
      list.all(values, fn(value) {
        case
          validation.integer_condition(
            graph.profile,
            source,
            kdl.JsonValueNum(value),
          )
        {
          None ->
            validation.integer_condition(
              graph.profile,
              destination,
              kdl.JsonValueNum(value),
            )
            == None
          Some(_) -> True
        }
      })
    None ->
      destination.const_value == None
      && destination.enum_values == None
      && lower_contained_int(source.minimum, destination.minimum)
      && upper_contained_int(source.maximum, destination.maximum)
  }
}

fn length_bounds_included(
  source: List(types.LengthBound),
  destination: List(types.LengthBound),
) -> Bool {
  list.all(destination, fn(target) {
    list.any(source, fn(candidate) {
      candidate.unit == target.unit
      && lower_contained_nat(candidate.minimum, target.minimum)
      && upper_contained_nat(candidate.maximum, target.maximum)
    })
  })
}

fn string_rule_check(
  source: types.StringSpec,
  destination: types.StringSpec,
) -> Bool {
  types.StringSpec(..source, lengths: [])
  == types.StringSpec(..destination, lengths: [])
  && length_bounds_included(source.lengths, destination.lengths)
}

fn field_named(
  fields: List(types.FieldSpec),
  name: String,
) -> Option(types.FieldSpec) {
  option.from_result(list.find(fields, fn(field) { field.wire_name == name }))
}

fn product_field_pairs(
  graph: types.SemanticGraph,
  source: types.ProductSpec,
  destination: types.ProductSpec,
) -> List(#(types.TypeRef, types.TypeRef)) {
  let destination_pairs =
    option.values(
      list.map(destination.fields, fn(field) {
        case field_named(source.fields, field.wire_name) {
          Some(source_field) ->
            Some(#(source_field.slot.type_ref, field.slot.type_ref))
          None ->
            case
              field.slot.required
              || {
                option.map(graph.profile.tag, fn(tag) { tag.key })
                == Some(field.wire_name)
              }
            {
              True -> None
              False ->
                case source.extras {
                  types.RejectExtras -> None
                  types.AllowExtras(_, contract) ->
                    Some(#(contract.type_ref, field.slot.type_ref))
                }
            }
        }
      }),
    )
  let source_extra_pairs =
    option.values(
      list.map(source.fields, fn(field) {
        case field_named(destination.fields, field.wire_name) {
          Some(_) -> None
          None ->
            case destination.extras {
              types.RejectExtras -> None
              types.AllowExtras(_, contract) ->
                Some(#(field.slot.type_ref, contract.type_ref))
            }
        }
      }),
    )
  let extras_pairs = case source.extras, destination.extras {
    types.AllowExtras(_, source_contract),
      types.AllowExtras(_, destination_contract)
    -> [#(source_contract.type_ref, destination_contract.type_ref)]
    _, _ -> []
  }
  list.append(destination_pairs, list.append(source_extra_pairs, extras_pairs))
}

fn type_rejects_null(
  indexed: validation.PreparedGraph,
  reference: types.TypeRef,
) -> Bool {
  case validation.expand_value(indexed, reference, [], kdl.JsonValueNull) {
    validation.RejectedExpansion(_) -> True
    _ -> False
  }
}

fn extra_allows_key(
  profile: types.SemanticProfile,
  key_format: Option(types.FormatUse),
  key: String,
) -> Bool {
  option.unwrap(
    option.map(key_format, fn(format_use) {
      validation.format_use_accepts(profile, format_use, key)
    }),
    True,
  )
}

fn product_rule_shape_check(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
  source: types.ProductSpec,
  destination: types.ProductSpec,
) -> Bool {
  list.all(destination.fields, fn(destination_field) {
    case field_named(source.fields, destination_field.wire_name) {
      Some(source_field) ->
        presence_included(source_field.slot, destination_field.slot)
      None ->
        !destination_field.slot.required
        && !{
          option.map(graph.profile.tag, fn(tag) { tag.key })
          == Some(destination_field.wire_name)
        }
        && case source.extras {
          types.RejectExtras -> False
          types.AllowExtras(_, source_contract) ->
            {
              !source_contract.nullable
              && type_rejects_null(indexed, source_contract.type_ref)
            }
            || destination_field.slot.nullable
        }
    }
  })
  && list.all(source.fields, fn(source_field) {
    case field_named(destination.fields, source_field.wire_name) {
      Some(_) -> True
      None ->
        {
          option.map(graph.profile.tag, fn(tag) { tag.key })
          == Some(source_field.wire_name)
        }
        || case destination.extras {
          types.RejectExtras -> False
          types.AllowExtras(key_format, contract) ->
            validation.unicode_valid(source_field.wire_name)
            && extra_allows_key(
              graph.profile,
              key_format,
              source_field.wire_name,
            )
            && { !source_field.slot.nullable || contract.nullable }
        }
    }
  })
  && case source.extras, destination.extras {
    types.RejectExtras, _ -> True
    types.AllowExtras(_, _), types.RejectExtras -> False
    types.AllowExtras(source_key, source_contract),
      types.AllowExtras(destination_key, destination_contract)
    ->
      format_included(graph, source_key, destination_key)
      && { !source_contract.nullable || destination_contract.nullable }
  }
}

fn product_rule_check(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
  refs: Dict(#(types.TypeRef, types.TypeRef), Nil),
  source: types.ProductSpec,
  destination: types.ProductSpec,
) -> Bool {
  list.all(destination.fields, fn(destination_field) {
    case field_named(source.fields, destination_field.wire_name) {
      Some(source_field) ->
        presence_included(source_field.slot, destination_field.slot)
        && dict.has_key(refs, #(
          source_field.slot.type_ref,
          destination_field.slot.type_ref,
        ))
      None ->
        !destination_field.slot.required
        && !{
          option.map(graph.profile.tag, fn(tag) { tag.key })
          == Some(destination_field.wire_name)
        }
        && case source.extras {
          types.RejectExtras -> False
          types.AllowExtras(_, source_contract) ->
            {
              {
                !source_contract.nullable
                && type_rejects_null(indexed, source_contract.type_ref)
              }
              || destination_field.slot.nullable
            }
            && dict.has_key(refs, #(
              source_contract.type_ref,
              destination_field.slot.type_ref,
            ))
        }
    }
  })
  && list.all(source.fields, fn(source_field) {
    case field_named(destination.fields, source_field.wire_name) {
      Some(_) -> True
      None ->
        {
          option.map(graph.profile.tag, fn(tag) { tag.key })
          == Some(source_field.wire_name)
        }
        || case destination.extras {
          types.RejectExtras -> False
          types.AllowExtras(key_format, contract) ->
            validation.unicode_valid(source_field.wire_name)
            && extra_allows_key(
              graph.profile,
              key_format,
              source_field.wire_name,
            )
            && { !source_field.slot.nullable || contract.nullable }
            && dict.has_key(refs, #(
              source_field.slot.type_ref,
              contract.type_ref,
            ))
        }
    }
  })
  && case source.extras, destination.extras {
    types.RejectExtras, _ -> True
    types.AllowExtras(_, _), types.RejectExtras -> False
    types.AllowExtras(source_key, source_contract),
      types.AllowExtras(destination_key, destination_contract)
    ->
      format_included(graph, source_key, destination_key)
      && { !source_contract.nullable || destination_contract.nullable }
      && dict.has_key(refs, #(
        source_contract.type_ref,
        destination_contract.type_ref,
      ))
  }
}

fn selectors_equal(
  source: types.UnionBranch,
  destination: types.UnionBranch,
) -> Bool {
  case source.selector, destination.selector {
    types.InternalTag, types.InternalTag ->
      source.wire_tag == destination.wire_tag
    types.MemberShape(left), types.MemberShape(right) -> left == right
    types.Kind(left), types.Kind(right) -> left == right
    types.Otherwise, types.Otherwise -> True
    _, _ -> False
  }
}

fn selector_disjoint(
  left: types.UnionBranch,
  right: types.UnionBranch,
) -> Bool {
  case left.selector, right.selector {
    types.InternalTag, types.InternalTag -> left.wire_tag != right.wire_tag
    types.Kind(left), types.Kind(right) -> left != right
    types.InternalTag, types.Kind(kind) | types.Kind(kind), types.InternalTag ->
      kind != types.ObjectKind
    _, _ -> False
  }
}

fn disjoint_from_all(
  destination: types.UnionBranch,
  sources: List(types.UnionBranch),
) -> Bool {
  list.all(sources, fn(source) { selector_disjoint(destination, source) })
}

fn union_branch_pairs(
  sources: List(types.UnionBranch),
  destinations: List(types.UnionBranch),
) -> Option(List(#(types.TypeRef, types.TypeRef))) {
  case sources, destinations {
    [], _ -> Some([])
    [_, ..], [] -> None
    [source, ..rest], [destination, ..remaining] ->
      case selectors_equal(source, destination) {
        True ->
          option.map(union_branch_pairs(rest, remaining), fn(pairs) {
            [#(source.target, destination.target), ..pairs]
          })
        False ->
          case disjoint_from_all(destination, sources) {
            True -> union_branch_pairs(sources, remaining)
            False -> None
          }
      }
  }
}

fn rule_u_child_pairs(
  source: types.UnionSpec,
  destination: types.UnionSpec,
) -> List(#(types.TypeRef, types.TypeRef)) {
  option.unwrap(union_branch_pairs(source.branches, destination.branches), [])
}

fn has_otherwise(branches: List(types.UnionBranch)) -> Bool {
  list.any(branches, fn(branch) { branch.selector == types.Otherwise })
}

fn rule_u_coverage(
  source: types.UnionSpec,
  destination: types.UnionSpec,
) -> Bool {
  case has_otherwise(source.branches) {
    True -> source == destination
    False ->
      option.is_some(union_branch_pairs(source.branches, destination.branches))
  }
}

type PairTable {
  PairTable(
    entries: Dict(Int, PairEntry),
    refs: Dict(#(types.TypeRef, types.TypeRef), Nil),
    first: Dict(#(types.TypeRef, types.TypeRef), PairEntry),
  )
}

fn pair_table(table: List(PairEntry)) -> PairTable {
  let entries =
    list.index_fold(table, dict.new(), fn(entries, entry, index) {
      dict.insert(entries, index, entry)
    })
  let first =
    list.fold(list.reverse(table), dict.new(), fn(first, entry) {
      dict.insert(
        first,
        #(entry.pair.source.type_ref, entry.pair.destination.type_ref),
        entry,
      )
    })
  PairTable(entries, dict.map_values(first, fn(_, _) { Nil }), first)
}

fn check_child_coverage(
  table: PairTable,
  entry: PairEntry,
  required: List(#(types.TypeRef, types.TypeRef)),
) -> Result(Nil, InclusionFailure) {
  let actual =
    option.values(
      list.map(entry.children, fn(index) {
        option.map(
          option.from_result(dict.get(table.entries, index)),
          fn(child) {
            #(child.pair.source.type_ref, child.pair.destination.type_ref)
          },
        )
      }),
    )
  let actual_set = reference_set(actual)
  let required_set = reference_set(required)
  case
    list.length(actual) != list.length(entry.children)
    || !list.all(required, dict.has_key(actual_set, _))
    || !list.all(actual, dict.has_key(required_set, _))
  {
    True -> Error(ChildCoverage(0))
    False ->
      case list.all(required, dict.has_key(table.refs, _)) {
        True -> Ok(Nil)
        False -> Error(ChildCoverage(0))
      }
  }
}

fn check_pair_fuel(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
  empty_refs: Dict(types.TypeRef, Nil),
  table: PairTable,
  fuel: Int,
  entry: PairEntry,
) -> Result(Nil, InclusionFailure) {
  case fuel <= 0 {
    True ->
      Error(
        InclusionUnresolved(TypeObligation(
          entry.pair,
          [],
          ObligationBoundExhausted,
        )),
      )
    False -> {
      let source = entry.pair.source.type_ref
      let destination = entry.pair.destination.type_ref
      use source_node <- result.try(option.to_result(
        validation.indexed_type(indexed, source),
        PairMismatch(0),
      ))
      use destination_node <- result.try(option.to_result(
        validation.indexed_type(indexed, destination),
        PairMismatch(0),
      ))
      use _ <- result.try(
        case
          entry.source_shape == source_node.shape
          && entry.destination_shape == destination_node.shape
          && entry.pair.source_tag == None
        {
          True -> Ok(Nil)
          False -> Error(PairMismatch(0))
        },
      )
      let rule_is = fn(rule) {
        case entry.rule == rule {
          True -> Ok(Nil)
          False -> Error(RuleMismatch(0))
        }
      }
      let constraint = fn(condition) {
        case condition {
          True -> Ok(Nil)
          False ->
            Error(
              InclusionUnresolved(TypeObligation(
                entry.pair,
                [],
                ConstraintImplication,
              )),
            )
        }
      }
      case dict.has_key(empty_refs, source) {
        True -> {
          use _ <- result.try(rule_is(EmptySource))
          check_child_coverage(table, entry, [])
        }
        False ->
          case source_node.shape == destination_node.shape {
            True -> {
              use _ <- result.try(rule_is(SameDefinedType))
              check_child_coverage(table, entry, [])
            }
            False ->
              case source_node.shape, destination_node.shape {
                types.AliasShape(target, _), _ -> {
                  use _ <- result.try(rule_is(UnfoldSource))
                  check_child_coverage(table, entry, [#(target, destination)])
                }
                _, types.AliasShape(target, _) -> {
                  use _ <- result.try(rule_is(UnfoldDestination))
                  use _ <- result.try(
                    check_child_coverage(table, entry, [#(source, target)]),
                  )
                  use child <- result.try(result.replace_error(
                    dict.get(table.first, #(source, target)),
                    MissingPair,
                  ))
                  check_pair_fuel(
                    graph,
                    indexed,
                    empty_refs,
                    table,
                    fuel - 1,
                    child,
                  )
                }
                types.BooleanShape(s), types.BooleanShape(d) -> {
                  use _ <- result.try(rule_is(InclusionBoolean))
                  use _ <- result.try(check_child_coverage(table, entry, []))
                  constraint(
                    d.const_value == None || s.const_value == d.const_value,
                  )
                }
                types.IntegerShape(s), types.IntegerShape(d) -> {
                  use _ <- result.try(rule_is(IntegerIntersection))
                  use _ <- result.try(check_child_coverage(table, entry, []))
                  constraint(integer_rule_check(graph, s, d))
                }
                types.StringShape(s), types.StringShape(d) -> {
                  use _ <- result.try(
                    case
                      entry.rule == StringConditions
                      || entry.rule == FiniteStrings
                    {
                      True -> Ok(Nil)
                      False -> Error(RuleMismatch(0))
                    },
                  )
                  use _ <- result.try(check_child_coverage(table, entry, []))
                  constraint(string_rule_check(s, d))
                }
                types.ArrayShape(s), types.ArrayShape(d) -> {
                  use _ <- result.try(rule_is(InclusionArray))
                  use _ <- result.try(
                    check_child_coverage(table, entry, [
                      #(s.item.type_ref, d.item.type_ref),
                    ]),
                  )
                  constraint(
                    lower_contained_nat(s.min_length, d.min_length)
                    && upper_contained_nat(s.max_length, d.max_length)
                    && { !s.item.nullable || d.item.nullable },
                  )
                }
                types.ProductShape(s), types.ProductShape(d) -> {
                  use _ <- result.try(rule_is(InclusionProduct))
                  use _ <- result.try(check_child_coverage(
                    table,
                    entry,
                    product_field_pairs(graph, s, d),
                  ))
                  case product_rule_check(graph, indexed, table.refs, s, d) {
                    True -> Ok(Nil)
                    False ->
                      Error(
                        InclusionUnresolved(TypeObligation(
                          entry.pair,
                          [],
                          ExtraField("product rule P"),
                        )),
                      )
                  }
                }
                types.BytesShape(_), types.BytesShape(_) ->
                  Error(
                    InclusionUnresolved(TypeObligation(
                      entry.pair,
                      [],
                      ConstraintImplication,
                    )),
                  )
                types.TaggedUnionShape(s), types.TaggedUnionShape(d) -> {
                  use _ <- result.try(rule_is(SourceUnion))
                  use _ <- result.try(check_child_coverage(
                    table,
                    entry,
                    rule_u_child_pairs(s, d),
                  ))
                  case rule_u_coverage(s, d) {
                    True -> Ok(Nil)
                    False ->
                      Error(
                        InclusionUnresolved(TypeObligation(
                          entry.pair,
                          [],
                          UnionRemainder,
                        )),
                      )
                  }
                }
                _, _ ->
                  Error(
                    InclusionUnresolved(TypeObligation(
                      entry.pair,
                      [],
                      ConstraintImplication,
                    )),
                  )
              }
          }
      }
    }
  }
}

fn check_pair_table(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
  empty_refs: List(types.TypeRef),
  table: List(PairEntry),
) -> Result(Nil, InclusionFailure) {
  let empty = reference_set(empty_refs)
  let pairs = pair_table(table)
  let fuel = list.length(graph.nodes) + 1
  list.try_each(table, fn(entry) {
    check_pair_fuel(graph, indexed, empty, pairs, fuel, entry)
  })
}

fn rejection_failure(
  reference: types.TypeRef,
  value: types.SlotValue(kdl.JsonValue),
  condition: types.ValueCondition,
) -> types.ValueFailure {
  types.ValueFailure(
    reference,
    types.DefinitionRef(reference.source, reference.definition_name),
    types.occurrence(reference),
    [],
    condition,
    value,
    [],
  )
}

fn reject_value_fuel(
  indexed: validation.PreparedGraph,
  fuel: Int,
  reference: types.TypeRef,
  path: types.ValuePath,
  value: kdl.JsonValue,
) -> Option(types.ValueFailure) {
  case fuel <= 0 {
    True -> None
    False ->
      case validation.expand_value(indexed, reference, path, value) {
        validation.UnresolvedExpansion(_) -> None
        validation.RejectedExpansion(failure) -> Some(failure)
        validation.Requirements(children) ->
          rejected_child(indexed, fuel - 1, children)
      }
  }
}

fn rejected_child(
  indexed: validation.PreparedGraph,
  fuel: Int,
  requests: List(validation.ValueRequirement),
) -> Option(types.ValueFailure) {
  case requests {
    [] -> None
    [child, ..rest] ->
      case
        reject_value_fuel(
          indexed,
          fuel,
          child.type_ref,
          child.value_path,
          child.value,
        )
      {
        Some(failure) -> Some(failure)
        None -> rejected_child(indexed, fuel, rest)
      }
  }
}

pub fn verify_counterexample(
  indexed: validation.PreparedGraph,
  source: types.SlotContract,
  destination: types.SlotContract,
  certificate: CounterexampleCertificate,
) -> Result(CheckedCounterexample, InclusionFailure) {
  indexed_verify_counterexample(
    validation.prepared_graph(indexed),
    indexed,
    source,
    destination,
    certificate,
  )
}

fn indexed_verify_counterexample(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
  source: types.SlotContract,
  destination: types.SlotContract,
  certificate: CounterexampleCertificate,
) -> Result(CheckedCounterexample, InclusionFailure) {
  use _ <- result.try(
    case
      certificate.basis == semantic_basis_of(graph)
      && certificate.source == source
      && certificate.destination == destination
    {
      True -> Ok(Nil)
      False -> Error(InclusionBasisMismatch)
    },
  )
  use _ <- result.try(
    case
      validation.accepts_slot(indexed, source, certificate.value)
      == types.AcceptedValue
    {
      True -> Ok(Nil)
      False -> Error(CounterexampleMismatch)
    },
  )
  let rejected = fn(failure) {
    use _ <- result.try(case failure == certificate.destination_failure {
      True -> Ok(Nil)
      False -> Error(CounterexampleMismatch)
    })
    Ok(CheckedCounterexample(graph, certificate))
  }
  case certificate.value {
    types.Absent ->
      case destination.required {
        True ->
          rejected(rejection_failure(
            destination.type_ref,
            types.Absent,
            types.MissingRequiredCondition,
          ))
        False -> Error(CounterexampleMismatch)
      }
    types.Null ->
      case destination.nullable {
        False ->
          rejected(rejection_failure(
            destination.type_ref,
            types.Null,
            types.NullNotAllowedCondition,
          ))
        True -> Error(CounterexampleMismatch)
      }
    types.Present(value) ->
      case
        reject_value_fuel(
          indexed,
          { kdl.json_size(value) + 1 } * { list.length(graph.nodes) + 1 },
          destination.type_ref,
          [],
          value,
        )
      {
        Some(failure) -> rejected(failure)
        None -> Error(CounterexampleMismatch)
      }
  }
}

fn check_assignable_with_empty(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
  empty_refs: List(types.TypeRef),
  source: types.SlotContract,
  destination: types.SlotContract,
  bounds: SearchBounds,
) -> CompatibilityDecision {
  case
    structural_assignable(
      graph,
      indexed,
      empty_refs,
      source,
      destination,
      bounds.max_type_obligations,
    )
  {
    Compatible(certificate) -> Compatible(certificate)
    Incompatible(certificate) -> Incompatible(certificate)
    CompatibilityUnknown(obligations) -> {
      let prepared_samples =
        inclusion_samples_bounded(
          graph,
          indexed,
          source.type_ref,
          destination.type_ref,
          bounds,
        )
      let samples =
        list.flatten([
          case source.required {
            True -> []
            False -> [types.Absent]
          },
          case source.nullable {
            True -> [types.Null]
            False -> []
          },
          list.map(prepared_samples.values, types.Present),
        ])
      case counterexample(graph, indexed, source, destination, samples) {
        Some(checked) -> Incompatible(checked.certificate)
        None -> CompatibilityUnknown(obligations)
      }
    }
  }
}

fn counterexample(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
  source: types.SlotContract,
  destination: types.SlotContract,
  samples: List(types.SlotValue(kdl.JsonValue)),
) -> Option(CheckedCounterexample) {
  case samples {
    [] -> None
    [value, ..rest] -> {
      let failure = case value {
        types.Absent ->
          case destination.required {
            True ->
              Some(rejection_failure(
                destination.type_ref,
                value,
                types.MissingRequiredCondition,
              ))
            False -> None
          }
        types.Null ->
          case destination.nullable {
            False ->
              Some(rejection_failure(
                destination.type_ref,
                value,
                types.NullNotAllowedCondition,
              ))
            True -> None
          }
        types.Present(actual) ->
          reject_value_fuel(
            indexed,
            { kdl.json_size(actual) + 1 } * { list.length(graph.nodes) + 1 },
            destination.type_ref,
            [],
            actual,
          )
      }
      case failure {
        None -> counterexample(graph, indexed, source, destination, rest)
        Some(destination_failure) ->
          case
            indexed_verify_counterexample(
              graph,
              indexed,
              source,
              destination,
              CounterexampleCertificate(
                semantic_basis_of(graph),
                source,
                destination,
                value,
                destination_failure,
              ),
            )
          {
            Ok(checked) -> Some(checked)
            Error(_) ->
              counterexample(graph, indexed, source, destination, rest)
          }
      }
    }
  }
}

fn check_assignable_bounded(
  indexed: validation.PreparedGraph,
  source: types.SlotContract,
  destination: types.SlotContract,
  bounds: SearchBounds,
) -> CompatibilityDecision {
  let graph = validation.prepared_graph(indexed)
  check_assignable_with_empty(
    graph,
    indexed,
    indexed_empty_types(graph, indexed),
    source,
    destination,
    bounds,
  )
}

pub fn check_assignable(
  indexed: validation.PreparedGraph,
  source: types.SlotContract,
  destination: types.SlotContract,
  max_obligations: Int,
) -> CompatibilityDecision {
  check_assignable_bounded(
    indexed,
    source,
    destination,
    SearchBounds(
      ..default_search_bounds(),
      max_type_obligations: max_obligations,
    ),
  )
}

fn structural_assignable(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
  empty: List(types.TypeRef),
  source: types.SlotContract,
  destination: types.SlotContract,
  max_obligations: Int,
) -> CompatibilityDecision {
  case
    inclusion_table(
      graph,
      indexed,
      reference_set(empty),
      max_obligations,
      [#(source.type_ref, destination.type_ref)],
      dict.new(),
      [],
    )
  {
    Error(obligation) -> CompatibilityUnknown([obligation])
    Ok(entries) -> {
      let certificate =
        InclusionCertificate(
          semantic_basis_of(graph),
          source,
          destination,
          empty,
          entries,
          0,
        )
      case
        indexed_verify_inclusion(
          graph,
          indexed,
          source,
          destination,
          certificate,
        )
      {
        Ok(_) -> Compatible(certificate)
        Error(UndefinedMeaning(obligations)) ->
          CompatibilityUnknown([
            TypeObligation(
              TypePair(source, destination, None),
              [],
              TypeMeaning(obligations),
            ),
          ])
        Error(InclusionUnresolved(obligation)) ->
          CompatibilityUnknown([obligation])
        Error(_) ->
          CompatibilityUnknown([
            TypeObligation(
              TypePair(source, destination, None),
              [],
              ConstraintImplication,
            ),
          ])
      }
    }
  }
}

fn inclusion_table(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
  empty: Dict(types.TypeRef, Nil),
  fuel: Int,
  pending: List(#(types.TypeRef, types.TypeRef)),
  seen: Dict(#(types.TypeRef, types.TypeRef), Nil),
  rows: List(#(PairEntry, List(#(types.TypeRef, types.TypeRef)))),
) -> Result(List(PairEntry), TypeObligation) {
  case fuel <= 0, pending {
    True, [] -> table_indices(list.reverse(rows))
    True, [#(source, destination), ..] ->
      Error(TypeObligation(
        TypePair(present_contract(source), present_contract(destination), None),
        [],
        ObligationBoundExhausted,
      ))
    False, [] -> table_indices(list.reverse(rows))
    False, [pair, ..rest] ->
      case dict.has_key(seen, pair) {
        True ->
          inclusion_table(graph, indexed, empty, fuel - 1, rest, seen, rows)
        False -> {
          use described <- result.try(describe_pair(
            graph,
            indexed,
            empty,
            pair.0,
            pair.1,
          ))
          inclusion_table(
            graph,
            indexed,
            empty,
            fuel - 1,
            list.append(described.1, rest),
            dict.insert(seen, pair, Nil),
            [described, ..rows],
          )
        }
      }
  }
}

fn table_indices(
  rows: List(#(PairEntry, List(#(types.TypeRef, types.TypeRef)))),
) -> Result(List(PairEntry), TypeObligation) {
  let positions =
    list.index_fold(rows, dict.new(), fn(positions, row, index) {
      let key = #(row.0.pair.source.type_ref, row.0.pair.destination.type_ref)
      case dict.has_key(positions, key) {
        True -> positions
        False -> dict.insert(positions, key, index)
      }
    })
  list.try_map(rows, fn(row) {
    use children <- result.try(
      list.try_map(row.1, fn(child) {
        case dict.get(positions, child) {
          Ok(index) -> Ok(index)
          Error(_) ->
            Error(TypeObligation(row.0.pair, [], ObligationBoundExhausted))
        }
      }),
    )
    Ok(PairEntry(..row.0, children: children))
  })
}

pub fn index_of(value: a, values: List(a)) -> Option(Int) {
  case values {
    [] -> None
    [first, ..rest] ->
      case value == first {
        True -> Some(0)
        False -> option.map(index_of(value, rest), fn(index) { index + 1 })
      }
  }
}

fn describe_pair(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
  empty: Dict(types.TypeRef, Nil),
  source: types.TypeRef,
  destination: types.TypeRef,
) -> Result(#(PairEntry, List(#(types.TypeRef, types.TypeRef))), TypeObligation) {
  let pair =
    TypePair(present_contract(source), present_contract(destination), None)
  let node = fn(reference) {
    case validation.indexed_type(indexed, reference) {
      Some(node) -> Ok(node)
      None ->
        Error(TypeObligation(
          pair,
          [],
          TypeMeaning(validation.meaning_obligations(indexed, [reference])),
        ))
    }
  }
  use source_node <- result.try(node(source))
  use destination_node <- result.try(node(destination))
  let row = fn(rule, children) {
    Ok(#(
      PairEntry(pair, source_node.shape, destination_node.shape, rule, []),
      children,
    ))
  }
  let rejected = fn(reason) { Error(TypeObligation(pair, [], reason)) }
  case dict.has_key(empty, source) {
    True -> row(EmptySource, [])
    False ->
      case source_node.shape == destination_node.shape {
        True -> row(SameDefinedType, [])
        False ->
          case source_node.shape, destination_node.shape {
            types.AliasShape(target, _), _ ->
              row(UnfoldSource, [#(target, destination)])
            _, types.AliasShape(target, _) ->
              row(UnfoldDestination, [#(source, target)])
            types.BooleanShape(s), types.BooleanShape(d) ->
              case d.const_value == None || s.const_value == d.const_value {
                True -> row(InclusionBoolean, [])
                False -> rejected(ConstraintImplication)
              }
            types.IntegerShape(s), types.IntegerShape(d) ->
              case integer_rule_check(graph, s, d) {
                True -> row(IntegerIntersection, [])
                False -> rejected(ConstraintImplication)
              }
            types.StringShape(s), types.StringShape(d) ->
              case string_rule_check(s, d) {
                True -> row(StringConditions, [])
                False -> rejected(ConstraintImplication)
              }
            types.ArrayShape(s), types.ArrayShape(d) ->
              case
                lower_contained_nat(s.min_length, d.min_length)
                && upper_contained_nat(s.max_length, d.max_length)
                && { !s.item.nullable || d.item.nullable }
              {
                True ->
                  row(InclusionArray, [#(s.item.type_ref, d.item.type_ref)])
                False -> rejected(ConstraintImplication)
              }
            types.ProductShape(s), types.ProductShape(d) ->
              case product_rule_shape_check(graph, indexed, s, d) {
                True -> row(InclusionProduct, product_field_pairs(graph, s, d))
                False -> rejected(TypePresence)
              }
            types.BytesShape(_), types.BytesShape(_) ->
              rejected(ConstraintImplication)
            types.TaggedUnionShape(s), types.TaggedUnionShape(d) ->
              case rule_u_coverage(s, d) {
                True -> row(SourceUnion, rule_u_child_pairs(s, d))
                False -> rejected(UnionRemainder)
              }
            _, _ -> rejected(ConstraintImplication)
          }
      }
  }
}

fn dfa_shortest_word(
  spec: types.DfaSpec,
  fuel: Int,
  frontier: List(#(Int, String)),
  visited: List(Int),
) -> Option(String) {
  case fuel <= 0 {
    True -> None
    False ->
      case
        list.find(frontier, fn(entry) {
          list.contains(spec.accepting_states, entry.0)
        })
      {
        Ok(#(_, path)) -> Some(path)
        Error(_) -> {
          let reached =
            list.flat_map(frontier, fn(entry) {
              let #(state, path) = entry
              spec.transitions
              |> list.filter(fn(transition) { transition.from_state == state })
              |> list.map(fn(transition) {
                #(
                  transition.to_state,
                  path <> codepoint_string(transition.first),
                )
              })
            })
          let fresh =
            list.fold(reached, [], fn(kept, entry) {
              case
                list.contains(visited, entry.0)
                || list.any(kept, fn(known: #(Int, String)) {
                  known.0 == entry.0
                })
              {
                True -> kept
                False -> list.append(kept, [entry])
              }
            })
          dfa_shortest_word(
            spec,
            fuel - 1,
            fresh,
            list.append(visited, list.map(fresh, fn(entry) { entry.0 })),
          )
        }
      }
  }
}

fn codepoint_string(value: Int) -> String {
  case string.utf_codepoint(value) {
    Ok(codepoint) -> string.from_utf_codepoints([codepoint])
    Error(_) -> "\u{0}"
  }
}

fn characters(text: String) -> List(String) {
  list.map(string.to_utf_codepoints(text), fn(codepoint) {
    string.from_utf_codepoints([codepoint])
  })
}

fn identifier_samples(
  first: String,
  rest: String,
  exact_length: Option(Int),
  minimum_length: Int,
  forbidden: List(String),
  accepts: fn(String) -> Bool,
) -> List(String) {
  let lengths = case exact_length {
    Some(length) -> [length]
    None ->
      list.map(
        int.range(0, list.length(forbidden) + 1, [], fn(all, index) {
          [index, ..all]
        })
          |> list.reverse,
        fn(extra) { int.max(minimum_length, 1) + extra },
      )
  }
  let candidates =
    list.flat_map(lengths, fn(length) {
      list.flat_map(characters(first), fn(head) {
        case length == 1 {
          True -> [head]
          False ->
            list.map(characters(rest), fn(tail) {
              head <> string.repeat(tail, int.max(length - 1, 0))
            })
        }
      })
    })
  case list.find(candidates, accepts) {
    Ok(text) -> [text]
    Error(_) -> []
  }
}

fn sequence_samples(limit: Int, parts: List(List(String))) -> List(String) {
  let heads = list.map(parts, list.first)
  case list.all(heads, result.is_ok) {
    False -> []
    True -> {
      let heads = result.values(heads)
      let varied =
        list.flat_map(
          list.index_map(parts, fn(samples, index) { #(samples, index) }),
          fn(entry) {
            let #(samples, index) = entry
            list.map(list.drop(samples, 1), fn(sample) {
              string.join(
                list.index_map(heads, fn(current_item, current_index) {
                  case current_index == index {
                    True -> sample
                    False -> current_item
                  }
                }),
                "",
              )
            })
          },
        )
      list.take([string.join(heads, ""), ..varied], limit)
    }
  }
}

fn timestamp_sample(rule: types.CalendarRule) -> String {
  string.pad_start(int.to_string(rule.minimum_year), 4, "0")
  <> "-01-01T00:00:00Z"
}

fn format_rule_samples_fuel(
  grapheme_rules: Option(types.GraphemeRules),
  limit: Int,
  fuel: Int,
  rule: types.FormatRule,
) -> List(String) {
  case fuel <= 0 {
    True -> []
    False -> {
      let inner = fn(part) {
        format_rule_samples_fuel(grapheme_rules, limit, fuel - 1, part)
      }
      let candidates = case rule {
        types.Literal(value) -> [value]
        types.Sequence(parts) -> sequence_samples(limit, list.map(parts, inner))
        types.Optional(part) -> ["", ..inner(part)]
        types.Choice(rules) -> list.flat_map(rules, inner)
        types.Labels(separator, minimum, _, _, part) ->
          list.map(inner(part), fn(sample) {
            string.join(list.repeat(sample, int.max(minimum, 1)), separator)
          })
        types.Bounded(_, _, part) -> inner(part)
        types.AsciiDfa(spec) ->
          option.values([
            dfa_shortest_word(
              spec,
              spec.state_count + 1,
              [#(spec.initial_state, "")],
              [spec.initial_state],
            ),
          ])
        types.Identifier(first, rest, exact_length, minimum, _, forbidden) ->
          identifier_samples(
            first,
            rest,
            exact_length,
            minimum,
            forbidden,
            fn(text) { validation.format_accepts(grapheme_rules, rule, text) },
          )
        types.Timestamp(calendar) -> [timestamp_sample(calendar)]
        types.AbsoluteUri(_) ->
          option.values([
            option.from_result(
              list.find(["a:", "a:b"], fn(text) {
                validation.format_accepts(grapheme_rules, rule, text)
              }),
            ),
          ])
        types.LanguageTag(_) -> ["aa"]
        types.Text -> ["", "a"]
        types.Not(child) -> {
          let excluded = inner(child)
          list.flatten([
            ["", "a", "aa"],
            excluded,
            list.map(excluded, fn(text) { text <> "x" }),
          ])
        }
      }
      list.take(
        list.filter(candidates, fn(text) {
          validation.format_accepts(grapheme_rules, rule, text)
        }),
        limit,
      )
    }
  }
}

fn format_samples(
  profile: types.SemanticProfile,
  format: Option(String),
  limit: Int,
) -> List(String) {
  case
    option.then(format, fn(name) {
      option.from_result(
        list.find(profile.format_bindings, fn(binding) { binding.name == name }),
      )
    })
  {
    Some(binding) ->
      format_rule_samples_fuel(
        profile.grapheme_rules,
        limit,
        types.format_rule_depth(binding.rule),
        binding.rule,
      )
    None -> []
  }
}

fn integer_sample(form: types.IntegerForm, value: Int) -> kdl.JsonValue {
  case form {
    types.Number -> kdl.JsonValueNum(value)
    types.IntegralDecimal -> kdl.JsonValueDec(int.to_string(value))
    types.DecimalString -> kdl.JsonValueStr(int.to_string(value))
  }
}

fn format_use_samples(
  profile: types.SemanticProfile,
  format_use: Option(types.FormatUse),
  limit: Int,
) -> List(String) {
  case format_use {
    None -> ["x"]
    Some(types.NamedFormat(name)) -> format_samples(profile, Some(name), limit)
    Some(types.InlineFormat(rule)) ->
      format_rule_samples_fuel(
        profile.grapheme_rules,
        limit,
        types.format_rule_depth(rule),
        rule,
      )
  }
}

type SampleObligation {
  SampleBound
}

type SampleResult(a) {
  SampleResult(values: List(a), obligations: List(SampleObligation))
}

fn construct(
  fields: List(types.FieldSpec),
  recurse: fn(types.TypeRef) -> List(kdl.JsonValue),
  fuel: Int,
) -> List(List(#(String, kdl.JsonValue))) {
  case fields {
    [] -> [[]]
    [field, ..rest] -> {
      let remaining = construct(rest, recurse, fuel)
      let values = recurse(field.slot.type_ref)
      let here =
        list.flatten([
          case field.slot.required {
            True -> []
            False -> [None]
          },
          case field.slot.nullable {
            True -> [Some(kdl.JsonValueNull)]
            False -> []
          },
          list.map(values, Some),
        ])
      construct_rows(field.wire_name, here, remaining, remaining, fuel, [])
    }
  }
}

fn construct_rows(
  name: String,
  here: List(Option(kdl.JsonValue)),
  remaining: List(List(#(String, kdl.JsonValue))),
  pending: List(List(#(String, kdl.JsonValue))),
  fuel: Int,
  rows: List(List(#(String, kdl.JsonValue))),
) -> List(List(#(String, kdl.JsonValue))) {
  case fuel <= 0, here, pending {
    True, _, _ | False, [], _ -> list.reverse(rows)
    False, [_, ..later], [] ->
      construct_rows(name, later, remaining, remaining, fuel, rows)
    False, [value, ..], [members, ..rest] ->
      construct_rows(name, here, remaining, rest, fuel - 1, [
        case value {
          None -> members
          Some(value) -> [#(name, value), ..members]
        },
        ..rows
      ])
  }
}

fn bytes_sample_values(
  profile: types.SemanticProfile,
  lengths: List(Int),
) -> List(kdl.JsonValue) {
  case profile.bytes_policy {
    None -> []
    Some(policy) -> {
      let #(quad, one, two) = case policy.alphabet {
        types.UrlSafe -> #("____", "_w==", "__8=")
        types.Standard | types.Either -> #("////", "/w==", "//8=")
      }
      let wire = fn(length) {
        string.concat(list.repeat(quad, length / 3))
        <> case length % 3 {
          1 -> one
          2 -> two
          _ -> ""
        }
      }
      case policy.wrapper {
        None -> list.map(lengths, fn(length) { kdl.JsonValueStr(wire(length)) })
        Some(name) ->
          case
            option.from_result(
              list.find(profile.wrappers, fn(wrapper) { wrapper.name == name }),
            )
          {
            None -> []
            Some(wrapper) ->
              list.map(lengths, fn(length) {
                kdl.JsonValueObj([
                  #(wrapper.key, kdl.JsonValueStr(wire(length))),
                ])
              })
          }
      }
    }
  }
}

fn sample_value_candidates_fuel(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
  fuel: Int,
  seen: List(types.TypeRef),
  reference: types.TypeRef,
) -> List(kdl.JsonValue) {
  case fuel <= 0 || list.contains(seen, reference) {
    True -> []
    False -> {
      let profile = graph.profile
      let recurse = fn(target) {
        sample_value_candidates_fuel(
          graph,
          indexed,
          fuel - 1,
          [reference, ..seen],
          target,
        )
      }
      let candidates = case validation.indexed_type(indexed, reference) {
        None -> []
        Some(node) ->
          case node.shape {
            types.BooleanShape(spec) ->
              case spec.const_value {
                Some(value) -> [kdl.JsonValueBool(value)]
                None -> [kdl.JsonValueBool(False), kdl.JsonValueBool(True)]
              }
            types.IntegerShape(spec) -> {
              let binding = validation.integer_binding(profile, spec.domain)
              let domain = case
                option.map(binding, fn(binding) { binding.range })
              {
                Some(types.IntegerInterval(minimum, maximum)) -> [
                  minimum,
                  maximum,
                ]
                _ -> []
              }
              let values =
                list.flatten([
                  option.values([spec.const_value]),
                  option.unwrap(spec.enum_values, []),
                  option.values([spec.minimum]),
                  option.values([spec.maximum]),
                  domain,
                  [0, 1, -1],
                ])
              case binding {
                None -> []
                Some(binding) ->
                  list.flat_map(binding.forms, fn(form) {
                    list.map(values, integer_sample(form, _))
                  })
              }
            }
            types.DecimalShape(spec) ->
              list.append(
                list.map(
                  list.append(
                    option.values([spec.minimum]),
                    option.values([spec.maximum]),
                  ),
                  fn(bound: types.DecimalBound) {
                    kdl.JsonValueDec(
                      int.to_string(bound.mantissa)
                      <> "e-"
                      <> int.to_string(bound.scale),
                    )
                  },
                ),
                [
                  kdl.JsonValueDec("0.0"),
                  kdl.JsonValueDec("1.0"),
                  kdl.JsonValueDec("-1.0"),
                ],
              )
            types.StringShape(spec) -> {
              let lengths =
                list.flat_map(spec.lengths, fn(bound) {
                  list.append(
                    option.values([bound.minimum]),
                    option.values([bound.maximum]),
                  )
                })
              let texts =
                list.flatten([
                  option.values([spec.const_value]),
                  option.unwrap(spec.enum_values, []),
                  spec.examples,
                  format_use_samples(profile, spec.format, fuel),
                  ["", "a"],
                  list.map(lengths, fn(length) { string.repeat("a", length) }),
                ])
              case spec.wrapper {
                None -> list.map(texts, kdl.JsonValueStr)
                Some(name) ->
                  case
                    option.from_result(
                      list.find(profile.wrappers, fn(wrapper) {
                        wrapper.name == name
                      }),
                    )
                  {
                    None -> []
                    Some(wrapper) ->
                      list.map(texts, fn(text) {
                        kdl.JsonValueObj([
                          #(wrapper.key, kdl.JsonValueStr(text)),
                        ])
                      })
                  }
              }
            }
            types.BytesShape(spec) ->
              bytes_sample_values(
                profile,
                list.flatten([
                  option.values([spec.minimum]),
                  option.values([spec.maximum]),
                  [0, 1],
                ]),
              )
            types.SealedShape(sealed_tag, refinements) ->
              case profile.tag {
                None -> []
                Some(tag) ->
                  case
                    list.find(tag.sealed, fn(form) { form.tag == sealed_tag })
                  {
                    Error(_) -> []
                    Ok(form) -> {
                      let leaf_for = fn(field: types.SealedField) {
                        option.unwrap(
                          option.map(
                            option.from_result(
                              list.find(refinements, fn(refinement) {
                                refinement.key == field.key
                              }),
                            ),
                            fn(refinement) { refinement.leaf },
                          ),
                          field.leaf,
                        )
                      }
                      let field_sample = fn(leaf: types.SealedLeaf) -> Option(
                        kdl.JsonValue,
                      ) {
                        case leaf {
                          types.SealedString(spec) ->
                            option.map(
                              spec.const_value
                                |> option.lazy_or(fn() {
                                  option.then(spec.enum_values, fn(values) {
                                    option.from_result(list.first(values))
                                  })
                                })
                                |> option.lazy_or(fn() {
                                  option.from_result(list.first(spec.examples))
                                })
                                |> option.lazy_or(fn() {
                                  option.from_result(
                                    list.first(format_use_samples(
                                      profile,
                                      spec.format,
                                      1,
                                    )),
                                  )
                                }),
                              kdl.JsonValueStr,
                            )
                          types.SealedInteger(spec) ->
                            option.map(
                              spec.const_value
                                |> option.lazy_or(fn() {
                                  option.then(spec.enum_values, fn(values) {
                                    option.from_result(list.first(values))
                                  })
                                })
                                |> option.lazy_or(fn() {
                                  spec.minimum
                                  |> option.lazy_or(fn() { spec.maximum })
                                }),
                              kdl.JsonValueNum,
                            )
                        }
                      }
                      let fields =
                        list.try_map(
                          list.filter(form.fields, fn(field) { field.required }),
                          fn(field) {
                            option.to_result(
                              option.map(
                                field_sample(leaf_for(field)),
                                fn(value) { #(field.key, value) },
                              ),
                              Nil,
                            )
                          },
                        )
                      case fields {
                        Error(_) -> []
                        Ok(fields) -> [
                          kdl.JsonValueObj([
                            #(tag.key, kdl.JsonValueStr(form.tag)),
                            ..fields
                          ]),
                        ]
                      }
                    }
                  }
              }
            types.Never -> []
            types.RawBodyShape(_) -> bytes_sample_values(profile, [0, 1])
            types.UnitShape -> [kdl.JsonValueNull]
            types.UnknownShape(_) -> [
              kdl.JsonValueObj([]),
              kdl.JsonValueNull,
              kdl.JsonValueBool(False),
              kdl.JsonValueNum(0),
              kdl.JsonValueStr(""),
              kdl.JsonValueArr([]),
            ]
            types.AliasShape(target, _) -> recurse(target)
            types.ArrayShape(spec) ->
              list.flat_map(
                list.flatten([
                  option.values([spec.min_length]),
                  option.values([spec.max_length]),
                  [0, 1],
                ]),
                fn(length) {
                  case length == 0 {
                    True -> [kdl.JsonValueArr([])]
                    False -> {
                      let values =
                        list.append(
                          case spec.item.nullable {
                            True -> [kdl.JsonValueNull]
                            False -> []
                          },
                          recurse(spec.item.type_ref),
                        )
                      list.map(values, fn(value) {
                        kdl.JsonValueArr(list.repeat(value, length))
                      })
                    }
                  }
                },
              )
            types.ProductShape(spec) -> {
              let base =
                list.map(
                  construct(spec.fields, recurse, fuel),
                  kdl.JsonValueObj,
                )
              let extras = case spec.extras {
                types.RejectExtras -> []
                types.AllowExtras(key_format, contract) ->
                  list.flat_map(
                    format_use_samples(profile, key_format, 1),
                    fn(key) {
                      list.map(
                        list.take(recurse(contract.type_ref), 1),
                        fn(value) { kdl.JsonValueObj([#(key, value)]) },
                      )
                    },
                  )
              }
              list.append(base, extras)
            }
            types.TaggedUnionShape(spec) -> {
              let tag_key =
                option.unwrap(
                  option.map(profile.tag, fn(model) { model.key }),
                  "",
                )
              list.flat_map(spec.branches, fn(branch) {
                option.values(
                  list.map(recurse(branch.target), fn(value) {
                    case branch.selector, value {
                      types.InternalTag, kdl.JsonValueObj(members) ->
                        Some(
                          kdl.JsonValueObj([
                            #(tag_key, kdl.JsonValueStr(branch.wire_tag)),
                            ..list.filter(members, fn(member) {
                              member.0 != tag_key
                            })
                          ]),
                        )
                      types.MemberShape(tests), kdl.JsonValueObj(members) ->
                        Some(
                          kdl.JsonValueObj(
                            list.fold(tests, members, fn(current, member_test) {
                              case member_test.1 {
                                types.AbsentMember ->
                                  list.filter(current, fn(member) {
                                    member.0 != member_test.0
                                  })
                                types.FormatMember(name) ->
                                  case
                                    list.first(format_samples(
                                      profile,
                                      Some(name),
                                      1,
                                    ))
                                  {
                                    Error(_) -> current
                                    Ok(text) -> [
                                      #(member_test.0, kdl.JsonValueStr(text)),
                                      ..list.filter(current, fn(member) {
                                        member.0 != member_test.0
                                      })
                                    ]
                                  }
                              }
                            }),
                          ),
                        )
                      types.Kind(_), _ | types.Otherwise, _ -> Some(value)
                      _, _ -> None
                    }
                  }),
                )
              })
            }
            types.OpaqueShape(_) -> []
          }
      }
      case candidates {
        [] -> []
        _ -> {
          list.filter(candidates, fn(value) {
            validation.accepts_value(indexed, reference, value)
            == types.AcceptedValue
          })
        }
      }
    }
  }
}

fn sample_within_bound(maximum: Int, value: kdl.JsonValue) -> Bool {
  case value {
    kdl.JsonValueStr(text) | kdl.JsonValueDec(text) ->
      list.length(string.to_utf_codepoints(text)) <= maximum
    kdl.JsonValueArr(items) -> list.length(items) <= maximum
    kdl.JsonValueObj(members) -> list.length(members) <= maximum
    _ -> True
  }
}

fn sample_value_fuel(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
  bounds: SearchBounds,
  fuel: Int,
  seen: List(types.TypeRef),
  reference: types.TypeRef,
) -> SampleResult(kdl.JsonValue) {
  let candidates =
    sample_value_candidates_fuel(graph, indexed, fuel, seen, reference)
  let values =
    list.filter(candidates, sample_within_bound(bounds.max_sample_length, _))
  SampleResult(values, case list.length(values) == list.length(candidates) {
    True -> []
    False -> [SampleBound]
  })
}

fn inclusion_samples_bounded(
  graph: types.SemanticGraph,
  indexed: validation.PreparedGraph,
  source: types.TypeRef,
  destination: types.TypeRef,
  bounds: SearchBounds,
) -> SampleResult(kdl.JsonValue) {
  let generated =
    sample_value_fuel(
      graph,
      indexed,
      bounds,
      int.min(bounds.max_type_obligations, list.length(graph.nodes) + 1),
      [],
      source,
    )
  let values = generated.values
  let candidates = case
    resolved_shape(graph, source),
    resolved_shape(graph, destination)
  {
    Some(types.ProductShape(source)), Some(types.ProductShape(destination)) -> {
      let missing_fields =
        list.flat_map(destination.fields, fn(field) {
          case
            list.any(source.fields, fn(declared) {
              declared.wire_name == field.wire_name
            })
          {
            True -> []
            False ->
              case values {
                [kdl.JsonValueObj(members), ..] ->
                  list.map(
                    [
                      kdl.JsonValueNull,
                      kdl.JsonValueBool(True),
                      kdl.JsonValueStr("x"),
                      kdl.JsonValueStr("y"),
                      kdl.JsonValueNum(0),
                    ],
                    fn(value) {
                      kdl.JsonValueObj([#(field.wire_name, value), ..members])
                    },
                  )
                _ -> []
              }
          }
        })
      let extra_values = case source.extras {
        types.RejectExtras -> []
        types.AllowExtras(key_format, contract) ->
          list.flat_map(
            format_use_samples(graph.profile, key_format, 1),
            fn(key) {
              list.map(
                sample_value_fuel(
                  graph,
                  indexed,
                  bounds,
                  int.min(
                    bounds.max_type_obligations,
                    list.length(graph.nodes) + 1,
                  ),
                  [],
                  contract.type_ref,
                ).values,
                fn(value) { kdl.JsonValueObj([#(key, value)]) },
              )
            },
          )
      }
      list.append(missing_fields, extra_values)
    }
    _, _ -> []
  }
  let bounded =
    list.filter(candidates, sample_within_bound(bounds.max_sample_length, _))
  let additional = case bounded {
    [] -> []
    _ -> {
      list.filter(bounded, fn(value) {
        validation.accepts_value(indexed, source, value) == types.AcceptedValue
      })
    }
  }
  SampleResult(
    list.append(values, additional),
    list.append(
      generated.obligations,
      case list.length(additional) == list.length(candidates) {
        True -> []
        False -> [SampleBound]
      },
    ),
  )
}
