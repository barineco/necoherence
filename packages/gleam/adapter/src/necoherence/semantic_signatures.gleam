// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import neco_quotient_certificate/admission as quotient
import neco_quotient_certificate/certificate as quotient_certificate
import neco_quotient_certificate/digest as quotient_digest
import neco_quotient_certificate/rule_table as quotient_rule_table
import neco_quotient_certificate/source as quotient_source
import necoherence/admission_failure as admission
import necoherence/composition_input
import necoherence/composition_plan
import necoherence/exact_json as json
import necoherence/network_effect as network
import necoherence/resource_witness
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_native as native
import necoherence/semantic_generation_runtime as runtime
import necoherence/semantic_generation_values as values
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation

pub type Failure {
  Codec(runtime.ValueFailure)
  Wire(decode.DecodeFailure)
  Json(values.ValueCodecFailure)
  LibraryRejected(failure: types.LibraryCheckFailure)
}

pub type SourceIdentity =
  types.SourceIdentity

pub type Origin =
  types.Origin

pub type Target =
  types.AnnotationTarget

pub type Annotation {
  Annotation(target: Target, key: String, value: json.JsonValue)
}

pub type DefinitionGroup {
  DefinitionGroup(id: String, members: List(String))
}

pub type OutcomeCause {
  ValueContract(origin: Origin)
  ExternalCondition(specification: Origin)
}

pub type OutcomeContract {
  OutcomeContract(
    contract: composition_plan.OutcomeContract,
    cause: OutcomeCause,
  )
}

pub type OperationContract {
  OperationContract(
    effect: types.EffectPoint,
    inputs: List(composition_plan.InputPort),
    outcomes: List(OutcomeContract),
  )
}

pub type DefinitionShape {
  Value(type_id: String)
  Symbol(wire_symbol: String)
  Operation(contract: OperationContract)
  Message(type_id: String)
}

pub type SignatureDefinition {
  SignatureDefinition(id: String, wire_identity: String, shape: DefinitionShape)
}

pub opaque type AdmittedLibrary {
  AdmittedLibrary(
    wire: json.JsonValue,
    identity: String,
    revision: String,
    prepared: validation.PreparedGraph,
    declaration: TypeSignatureLibrary,
    definitions: List(SignatureDefinition),
    annotations: List(Annotation),
    groups: List(DefinitionGroup),
    sources: List(SourceIdentity),
    source: types.SourceRef,
  )
}

pub opaque type CheckedGeneration {
  CheckedGeneration(
    wire: json.JsonValue,
    basis: GenerationIdentity,
    library: AdmittedLibrary,
    composition: Option(composition_plan.CheckedComposition),
    outcome_causes: List(#(composition_plan.FunctionRef, List(OutcomeContract))),
    admission: GenerationAdmission,
  )
}

pub opaque type GenerationContext {
  GenerationContext(
    wire: json.JsonValue,
    identity: GenerationIdentity,
    library: AdmittedLibrary,
    composition: json.JsonValue,
    checked: GeneratedComposition,
    admission: GenerationAdmission,
  )
}

type GeneratedComposition =
  Result(
    #(
      Option(composition_plan.CheckedComposition),
      List(#(composition_plan.FunctionRef, List(OutcomeContract))),
    ),
    AdmissionFailure,
  )

type GenerationAdmission =
  quotient.Checked(
    String,
    String,
    GenerationCoordinate,
    Option(GoalObservations),
    Nil,
    GenerationProjections,
  )

type GenerationIdentity {
  GenerationIdentity(
    signature_schema: String,
    library_identity: String,
    library_revision: String,
    profile: types.ProfileRef,
    graph_sha256: String,
    provenance_sha256: String,
    metadata_sha256: String,
    problem_sha256: Option(String),
    observations_sha256: Option(String),
    entrypoints_sha256: String,
  )
}

pub type GenerationRequirement {
  GenerationRequirement(
    signature_schema: String,
    library_identity: String,
    library_revision: String,
    profile: types.ProfileRef,
    graph_sha256: String,
    provenance_sha256: String,
    metadata_sha256: String,
    problem_sha256: Option(String),
    observations_sha256: Option(String),
    entrypoints_sha256: String,
  )
}

type LibraryMetadata {
  LibraryMetadata(
    signature_schema: String,
    library_identity: String,
    library_revision: String,
    profile: types.ProfileRef,
  )
}

type GenerationCoordinate {
  GenerationCoordinate(
    signature_schema: String,
    profile: types.ProfileRef,
    graph_sha256: String,
    provenance_sha256: String,
    metadata_sha256: String,
    problem_sha256: Option(String),
    observations_sha256: Option(String),
    entrypoints_sha256: String,
    library: LibraryMetadata,
  )
}

type GenerationProjections {
  GenerationProjections(
    graph: String,
    provenance: String,
    metadata: String,
    entrypoints: String,
    composition: Option(String),
    observations: Option(GoalObservations),
  )
}

/// 合成の goal が実行結果として観測させる量の族の宣言。成功時の出力、失敗の埋め込み、最終的な資源の要求、中断とネットワーク指示の列、残余 ( residual ) の集合、型付き実行失敗の種類、結果の来歴を定める。値はキーを整列した JSON 文字列で保持する。
pub opaque type GoalObservations {
  GoalObservations(canonical: String)
}

type ExpectedGeneration {
  ExpectedGeneration(
    basis: GenerationIdentity,
    observations: Option(GoalObservations),
  )
}

pub type GenerationBasisMismatch {
  GenerationBasisMismatch(
    held: GenerationRequirement,
    required: GenerationRequirement,
  )
}

pub type AdmissionFailure =
  admission.AdmissionFailure(
    types.LibraryCheckFailure,
    decode.DecodeFailure,
    composition_plan.CompositionInputFailure,
    resource_witness.WitnessFailure,
    Failure,
  )

pub type SignatureSlot {
  SignatureSlot(type_id: String, required: Bool, nullable: Bool)
}

pub type SignatureField {
  SignatureField(wire_name: String, slot: SignatureSlot)
}

pub type LibraryElementContract {
  LibraryElementContract(type_id: String, nullable: Bool)
}

pub type LibraryExtraMembers {
  LibraryRejectExtras
  LibraryAllowExtras(
    key_format: Option(types.FormatUse),
    value: LibraryElementContract,
  )
}

pub type LibraryProductSpec {
  LibraryProductSpec(fields: List(SignatureField), extras: LibraryExtraMembers)
}

pub type LibraryArraySpec {
  LibraryArraySpec(
    item: LibraryElementContract,
    minimum: Option(Int),
    maximum: Option(Int),
  )
}

pub type LibraryUnionBranch {
  LibraryUnionBranch(
    target: String,
    wire_tag: String,
    selector: types.BranchSelector,
  )
}

pub type LibraryUnionSpec {
  LibraryUnionSpec(branches: List(LibraryUnionBranch))
}

pub type LibraryShape {
  UnknownShape(kind: types.UnknownKind)
  UnitShape
  BooleanShape(spec: types.BooleanSpec)
  IntegerShape(spec: types.IntegerSpec)
  DecimalShape(spec: types.DecimalSpec)
  StringShape(spec: types.StringSpec)
  BytesShape(spec: types.LengthSpec)
  ProductShape(spec: LibraryProductSpec)
  ArrayShape(spec: LibraryArraySpec)
  TaggedUnionShape(spec: LibraryUnionSpec)
  SealedShape(tag: String, refinements: List(types.SealedRefinement))
  NeverShape
  AliasShape(target: String)
  RawBodyShape(encoding: String)
  OpaqueShape(name: String)
}

pub type ProvenanceBinding {
  ProvenanceBinding(target: Target, origins: List(Origin))
}

pub type LibraryNode {
  LibraryNode(id: String, shape: LibraryShape)
}

pub type TypeSignatureLibrary {
  TypeSignatureLibrary(
    schema: String,
    identity: String,
    revision: String,
    profile: types.SemanticProfile,
    sources: List(SourceIdentity),
    provenance: List(ProvenanceBinding),
    groups: List(DefinitionGroup),
    annotations: List(Annotation),
    nodes: List(LibraryNode),
    definitions: List(SignatureDefinition),
  )
}

pub opaque type CheckedLibrary {
  CheckedLibrary(
    library: TypeSignatureLibrary,
    profile: validation.CheckedProfile,
  )
}

pub fn checked_library_value(checked: CheckedLibrary) -> TypeSignatureLibrary {
  checked.library
}

fn unique_nonempty_ids(ids: List(String)) -> Bool {
  list.all(ids, fn(id) { id != "" })
  && list.length(ids) == list.length(list.unique(ids))
}

fn library_failure(
  library: TypeSignatureLibrary,
  predicate: types.LibraryPredicate,
) -> Result(CheckedLibrary, types.LibraryCheckFailure) {
  Error(
    types.LibraryCheck(
      types.LibraryFailure(library.identity, predicate, ["library"]),
    ),
  )
}

fn type_reference_ids(shape: LibraryShape) -> List(String) {
  case shape {
    ProductShape(spec) ->
      list.map(spec.fields, fn(field) { field.slot.type_id })
      |> list.append(case spec.extras {
        LibraryRejectExtras -> []
        LibraryAllowExtras(_, value) -> [value.type_id]
      })
    ArrayShape(spec) -> [spec.item.type_id]
    AliasShape(target) -> [target]
    TaggedUnionShape(spec) ->
      list.map(spec.branches, fn(branch) { branch.target })
    _ -> []
  }
}

fn valid_digest(digest: String) -> Bool {
  string.length(digest) == 64
  && list.all(string.to_graphemes(digest), fn(character) {
    string.contains("0123456789abcdef", character)
  })
}

fn origin_valid(library: TypeSignatureLibrary, origin: Origin) -> Bool {
  list.contains(library.sources, origin.source)
}

fn definition_reference_ids(definition: SignatureDefinition) -> List(String) {
  case definition.shape {
    Value(type_id) | Message(type_id) -> [type_id]
    Symbol(_) -> []
    Operation(operation) -> {
      let inputs =
        list.map(operation.inputs, fn(port) {
          port.contract.type_ref.definition_name
        })
      let outcomes =
        list.flat_map(operation.outcomes, fn(outcome) {
          let ports =
            list.map(outcome.contract.value_ports, fn(port) {
              port.contract.type_ref.definition_name
            })
          let resources =
            list.map(outcome.contract.produced_resources, fn(production) {
              production.token_type.definition_name
            })
          list.append(ports, resources)
        })
      list.append(inputs, outcomes)
    }
  }
}

fn target_valid(library: TypeSignatureLibrary, target: Target) -> Bool {
  case target {
    types.Library -> True
    types.Group(id) -> list.any(library.groups, fn(group) { group.id == id })
    types.Definition(id) ->
      list.any(library.definitions, fn(definition) { definition.id == id })
    types.Type(id) -> list.any(library.nodes, fn(node) { node.id == id })
    types.Outcome(id, outcome_name) ->
      list.any(library.definitions, fn(definition) {
        definition.id == id
        && case definition.shape {
          Operation(operation) ->
            list.any(operation.outcomes, fn(outcome) {
              let composition_plan.OutcomeId(name) = outcome.contract.id
              name == outcome_name
            })
          _ -> False
        }
      })
  }
}

fn outcome_valid(
  library: TypeSignatureLibrary,
  outcome: OutcomeContract,
) -> Bool {
  unique_nonempty_ids(
    list.map(outcome.contract.value_ports, fn(port) { port.id.value }),
  )
  && unique_nonempty_ids(
    list.map(outcome.contract.produced_resources, fn(production) {
      production.id.value
    }),
  )
  && case outcome.cause {
    ValueContract(origin) -> origin_valid(library, origin)
    ExternalCondition(specification) ->
      origin_valid(library, specification)
      && !list.is_empty(outcome.contract.value_ports)
      && outcome.contract.form == composition_plan.DeclaredFailure
  }
}

fn library_declaration_valid(library: TypeSignatureLibrary) -> Bool {
  let node_ids = list.map(library.nodes, fn(node) { node.id })
  let definition_ids =
    list.map(library.definitions, fn(definition) { definition.id })
  let group_ids = list.map(library.groups, fn(group) { group.id })
  library.schema == "ncoh-type-signatures@1"
  && library.identity != ""
  && library.revision != ""
  && valid_digest(library.profile.reference.content_digest)
  && list.all(library.sources, fn(source) {
    valid_digest(source.content_digest)
  })
  && list.length(library.sources) == list.length(list.unique(library.sources))
  && unique_nonempty_ids(node_ids)
  && unique_nonempty_ids(definition_ids)
  && unique_nonempty_ids(group_ids)
  && list.all(library.nodes, fn(node) {
    list.all(type_reference_ids(node.shape), fn(id) {
      list.contains(node_ids, id)
    })
  })
  && list.all(library.definitions, fn(definition) {
    list.all(definition_reference_ids(definition), fn(id) {
      list.contains(node_ids, id)
    })
    && case definition.shape {
      Operation(operation) ->
        unique_nonempty_ids(
          list.map(operation.inputs, fn(port) { port.id.value }),
        )
        && unique_nonempty_ids(
          list.map(operation.outcomes, fn(outcome) { outcome.contract.id.value }),
        )
        && !list.is_empty(operation.outcomes)
        && list.all(operation.outcomes, fn(outcome) {
          outcome_valid(library, outcome)
        })
      _ -> True
    }
  })
  && list.all(library.groups, fn(group) {
    list.all(group.members, fn(id) { list.contains(definition_ids, id) })
  })
  && list.all(library.provenance, fn(binding) {
    target_valid(library, binding.target)
    && list.all(binding.origins, fn(origin) { origin_valid(library, origin) })
  })
  && list.all(library.annotations, fn(annotation) {
    target_valid(library, annotation.target)
  })
}

fn format_rule(
  profile: types.SemanticProfile,
  format_use: types.FormatUse,
) -> Option(types.FormatRule) {
  case format_use {
    types.NamedFormat(name) ->
      case
        list.find(profile.format_bindings, fn(binding) { binding.name == name })
      {
        Ok(binding) -> Some(binding.rule)
        Error(_) -> None
      }
    types.InlineFormat(rule) -> Some(rule)
  }
}

fn bounds_valid(minimum: Option(Int), maximum: Option(Int)) -> Bool {
  case minimum, maximum {
    Some(minimum), Some(maximum) -> minimum <= maximum
    _, _ -> True
  }
}

fn node_by_id(
  library: TypeSignatureLibrary,
  id: String,
) -> Option(LibraryNode) {
  case list.find(library.nodes, fn(node) { node.id == id }) {
    Ok(node) -> Some(node)
    Error(_) -> None
  }
}

fn option_list(value: Option(a)) -> List(a) {
  case value {
    Some(value) -> [value]
    None -> []
  }
}

fn internal_tag_field_invalid(
  library: TypeSignatureLibrary,
  branch: LibraryUnionBranch,
  tag: types.TagModel,
) -> Bool {
  case node_by_id(library, branch.target) {
    Some(target) ->
      case target.shape {
        ProductShape(product) ->
          case
            list.find(product.fields, fn(field) { field.wire_name == tag.key })
          {
            Error(_) -> True
            Ok(field) ->
              case node_by_id(library, field.slot.type_id) {
                Some(field_type) ->
                  case field_type.shape {
                    StringShape(spec) ->
                      option.is_some(validation.string_condition(
                        library.profile,
                        spec,
                        branch.wire_tag,
                      ))
                    _ -> True
                  }
                None -> True
              }
          }
        _ -> False
      }
    None -> False
  }
}

fn duplicate_selection(
  left: LibraryUnionBranch,
  right: LibraryUnionBranch,
) -> Bool {
  case left.selector, right.selector {
    types.InternalTag, types.InternalTag -> left.wire_tag == right.wire_tag
    _, _ -> left.selector == right.selector
  }
}

fn library_predicate(
  library: TypeSignatureLibrary,
) -> Option(types.LibraryPredicate) {
  let wrapper_keys =
    list.map(library.profile.wrappers, fn(wrapper) { wrapper.key })
  let invalid_declaration = !library_declaration_valid(library)
  let checks = [
    #(invalid_declaration, types.Lb01),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape {
          ProductShape(spec) ->
            !unique_nonempty_ids(
              list.map(spec.fields, fn(field) { field.wire_name }),
            )
          _ -> False
        }
      }),
      types.Lb02,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape {
          ProductShape(spec) ->
            list.any(spec.fields, fn(field) {
              list.contains(wrapper_keys, field.wire_name)
            })
          _ -> False
        }
      }),
      types.Lb03,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape {
          TaggedUnionShape(spec) -> {
            let wire_tags =
              list.map(spec.branches, fn(branch) { branch.wire_tag })
            list.length(wire_tags) != list.length(list.unique(wire_tags))
          }
          _ -> False
        }
      }),
      types.Lb04,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape {
          TaggedUnionShape(spec) ->
            list.any(
              list.index_map(spec.branches, fn(branch, index) {
                #(branch, index)
              }),
              fn(indexed) {
                indexed.0.selector == types.Otherwise
                && indexed.1 + 1 != list.length(spec.branches)
              },
            )
          _ -> False
        }
      }),
      types.Lb05,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape {
          TaggedUnionShape(spec) ->
            list.any(spec.branches, fn(branch) {
              branch.wire_tag == ""
              || case branch.selector {
                types.MemberShape(tests) ->
                  list.any(tests, fn(member_test) { member_test.0 == "" })
                _ -> False
              }
            })
          _ -> False
        }
      }),
      types.Lb06,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape, library.profile.tag {
          TaggedUnionShape(spec), Some(tag) ->
            list.any(spec.branches, fn(branch) {
              branch.selector == types.InternalTag
              && option.unwrap(
                option.map(tag.format, fn(name) {
                  case
                    list.find(library.profile.format_bindings, fn(binding) {
                      binding.name == name
                    })
                  {
                    Ok(binding) ->
                      !validation.recognizes(
                        library.profile.grapheme_rules,
                        binding.rule,
                        branch.wire_tag,
                      )
                    Error(_) -> True
                  }
                }),
                False,
              )
            })
          _, _ -> False
        }
      }),
      types.Lb07,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape, library.profile.tag {
          TaggedUnionShape(spec), Some(tag) ->
            list.any(spec.branches, fn(branch) {
              branch.selector == types.InternalTag
              && {
                let declared =
                  list.any(tag.sealed, fn(form) { form.tag == branch.wire_tag })
                let target = case node_by_id(library, branch.target) {
                  Some(target) ->
                    case target.shape {
                      SealedShape(sealed_tag, _) ->
                        sealed_tag == branch.wire_tag
                      _ -> False
                    }
                  None -> False
                }
                declared != target
              }
            })
          _, _ -> False
        }
      }),
      types.Lb08,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape {
          TaggedUnionShape(spec) ->
            list.any(spec.branches, fn(branch) {
              case branch.selector {
                types.MemberShape(tests) ->
                  !unique_nonempty_ids(list.map(tests, fn(item) { item.0 }))
                  || list.any(tests, fn(item) {
                    case item.1 {
                      types.FormatMember(name) ->
                        !list.any(library.profile.format_bindings, fn(binding) {
                          binding.name == name
                        })
                      _ -> False
                    }
                  })
                _ -> False
              }
            })
          _ -> False
        }
      }),
      types.Lb09,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape, library.profile.tag {
          SealedShape(sealed_tag, refinements), Some(tag) ->
            case list.find(tag.sealed, fn(form) { form.tag == sealed_tag }) {
              Error(_) -> True
              Ok(form) ->
                !unique_nonempty_ids(
                  list.map(refinements, fn(value) { value.key }),
                )
                || list.any(refinements, fn(refinement) {
                  !list.any(form.fields, fn(field) {
                    field.key == refinement.key
                    && case field.leaf, refinement.leaf {
                      types.SealedString(_), types.SealedString(_)
                      | types.SealedInteger(_), types.SealedInteger(_)
                      -> True
                      _, _ -> False
                    }
                  })
                })
            }
          SealedShape(_, _), None -> True
          _, _ -> False
        }
      }),
      types.Lb10,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape {
          TaggedUnionShape(spec) ->
            list.any(spec.branches, fn(branch) {
              branch.selector == types.InternalTag
              && case node_by_id(library, branch.target) {
                Some(target) ->
                  case target.shape {
                    ProductShape(_) | SealedShape(_, _) -> False
                    _ -> True
                  }
                None -> True
              }
            })
          _ -> False
        }
      }),
      types.Lb11,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape {
          ProductShape(spec) ->
            case spec.extras {
              LibraryAllowExtras(Some(format_use), _) ->
                option.is_none(format_rule(library.profile, format_use))
              _ -> False
            }
          _ -> False
        }
      }),
      types.Lb12,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape {
          StringShape(spec) ->
            option.unwrap(
              option.map(spec.wrapper, fn(name) {
                !list.any(library.profile.wrappers, fn(wrapper) {
                  wrapper.name == name
                  && case wrapper.payload {
                    types.WrapperText(_) -> True
                    _ -> False
                  }
                })
              }),
              False,
            )
            || option.unwrap(
              option.map(spec.format, fn(format_use) {
                case format_rule(library.profile, format_use) {
                  None -> True
                  Some(rule) -> !validation.format_rule_well_formed(rule)
                }
              }),
              False,
            )
            || list.any(spec.lengths, fn(bound) {
              !bounds_valid(bound.minimum, bound.maximum)
            })
          _ -> False
        }
      }),
      types.Lb13,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape {
          IntegerShape(spec) ->
            !bounds_valid(spec.minimum, spec.maximum)
            || option.unwrap(
              option.map(spec.domain, fn(name) {
                !list.any(library.profile.integer_domains, fn(binding) {
                  binding.name == name
                })
              }),
              False,
            )
          _ -> False
        }
      }),
      types.Lb14,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape {
          DecimalShape(spec) ->
            case spec.minimum, spec.maximum {
              Some(minimum), Some(maximum) ->
                minimum.scale != maximum.scale
                || maximum.mantissa < minimum.mantissa
              _, _ -> False
            }
          _ -> False
        }
      }),
      types.Lb15,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape {
          ArrayShape(spec) -> !bounds_valid(spec.minimum, spec.maximum)
          BytesShape(spec) -> !bounds_valid(spec.minimum, spec.maximum)
          _ -> False
        }
      }),
      types.Lb16,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape, library.profile.tag {
          TaggedUnionShape(spec), Some(tag) ->
            list.any(spec.branches, fn(branch) {
              branch.selector == types.InternalTag
              && internal_tag_field_invalid(library, branch, tag)
            })
          _, _ -> False
        }
      }),
      types.Lb17,
    ),

    #(
      list.any(library.nodes, fn(node) {
        case node.shape {
          TaggedUnionShape(spec) -> {
            list.any(
              list.index_map(spec.branches, fn(branch, index) {
                #(branch, index)
              }),
              fn(indexed) {
                list.any(list.drop(spec.branches, indexed.1 + 1), fn(branch) {
                  duplicate_selection(indexed.0, branch)
                })
              },
            )
          }
          _ -> False
        }
      }),
      types.Lb18,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape {
          StringShape(spec) -> {
            let values =
              list.append(
                option_list(spec.const_value),
                list.append(
                  option.unwrap(spec.enum_values, []),
                  option_list(spec.default_value),
                ),
              )
            list.any(values, fn(value) {
              option.is_some(validation.string_condition(
                library.profile,
                spec,
                value,
              ))
            })
          }
          IntegerShape(spec) -> {
            let values =
              list.append(
                option_list(spec.const_value),
                list.append(
                  option.unwrap(spec.enum_values, []),
                  option_list(spec.default_value),
                ),
              )
            list.any(values, fn(value) {
              option.is_some(validation.integer_condition(
                library.profile,
                spec,
                json.JsonValueNum(value),
              ))
            })
          }
          _ -> False
        }
      }),
      types.Lb19,
    ),
  ]
  case list.find(checks, fn(check) { check.0 }) {
    Ok(check) -> Some(check.1)
    Error(_) -> None
  }
}

pub fn check_library(
  library: TypeSignatureLibrary,
) -> Result(CheckedLibrary, types.LibraryCheckFailure) {
  use profile <- result.try(
    validation.check_profile(library.profile)
    |> result.map_error(types.ProfileCheck),
  )
  case library_predicate(library) {
    Some(predicate) -> library_failure(library, predicate)
    None -> Ok(CheckedLibrary(library, profile))
  }
}

pub fn checked_library(checked: CheckedGeneration) -> AdmittedLibrary {
  checked.library
}

pub fn checked_graph(checked: CheckedGeneration) -> types.SemanticGraph {
  library_graph(checked.library)
}

pub fn checked_prepared(
  checked: CheckedGeneration,
) -> validation.PreparedGraph {
  checked.library.prepared
}

pub fn library_graph(library: AdmittedLibrary) -> types.SemanticGraph {
  validation.prepared_graph(library.prepared)
}

pub fn library_prepared(library: AdmittedLibrary) -> validation.PreparedGraph {
  library.prepared
}

pub fn definitions(library: AdmittedLibrary) -> List(SignatureDefinition) {
  library.definitions
}

pub fn groups(library: AdmittedLibrary) -> List(DefinitionGroup) {
  library.groups
}

pub fn annotations(
  library: AdmittedLibrary,
  target: Target,
) -> List(Annotation) {
  list.filter(library.annotations, fn(annotation) {
    annotation.target == target
  })
}

pub fn all_annotations(library: AdmittedLibrary) -> List(Annotation) {
  library.annotations
}

pub fn checked_composition(
  checked: CheckedGeneration,
) -> Option(composition_plan.CheckedComposition) {
  checked.composition
}

pub fn encode_library(library: AdmittedLibrary) -> Result(String, Failure) {
  canonical(library.wire)
}

pub fn encode_basis(checked: CheckedGeneration) -> Result(String, Failure) {
  canonical(generation_identity_wire(checked.basis))
}

pub fn encode_requirement_wire(
  requirement: GenerationRequirement,
) -> json.JsonValue {
  generation_identity_wire(GenerationIdentity(
    requirement.signature_schema,
    requirement.library_identity,
    requirement.library_revision,
    requirement.profile,
    requirement.graph_sha256,
    requirement.provenance_sha256,
    requirement.metadata_sha256,
    requirement.problem_sha256,
    requirement.observations_sha256,
    requirement.entrypoints_sha256,
  ))
}

pub fn generation_requirement(
  checked: CheckedGeneration,
) -> GenerationRequirement {
  requirement_from_identity(checked.basis)
}

fn requirement_from_identity(
  identity: GenerationIdentity,
) -> GenerationRequirement {
  GenerationRequirement(
    identity.signature_schema,
    identity.library_identity,
    identity.library_revision,
    identity.profile,
    identity.graph_sha256,
    identity.provenance_sha256,
    identity.metadata_sha256,
    identity.problem_sha256,
    identity.observations_sha256,
    identity.entrypoints_sha256,
  )
}

pub fn syntax(message: String) -> Failure {
  Wire(decode.SyntaxFailure([], message))
}

fn fail(message: String) -> Result(a, Failure) {
  Error(syntax(message))
}

fn require(condition: Bool, message: String) -> Result(Nil, Failure) {
  case condition {
    True -> Ok(Nil)
    False -> fail(message)
  }
}

fn unknown_tag(tag: String) -> Result(a, Failure) {
  Error(Wire(decode.unknown_tag_failure(tag)))
}

pub fn object(
  value: json.JsonValue,
  keys: List(String),
) -> Result(List(#(String, json.JsonValue)), Failure) {
  old(value, decode.object(_, keys))
}

pub fn field(
  value: json.JsonValue,
  key: String,
) -> Result(json.JsonValue, Failure) {
  case value {
    json.JsonValueObj(members) ->
      result.map_error(list.key_find(members, key), fn(_) {
        Wire(decode.SyntaxFailure([key], "missing field"))
      })
    _ -> fail("object required")
  }
}

fn text(value: json.JsonValue) -> Result(String, Failure) {
  case value {
    json.JsonValueStr(value) -> Ok(value)
    _ -> fail("string required")
  }
}

fn boolean(value: json.JsonValue) -> Result(Bool, Failure) {
  case value {
    json.JsonValueBool(value) -> Ok(value)
    _ -> fail("boolean required")
  }
}

fn identifier(value: json.JsonValue) -> Result(String, Failure) {
  use value <- result.try(text(value))
  use _ <- result.try(require(value != "", "empty identity"))
  Ok(value)
}

fn array(
  value: json.JsonValue,
  f: fn(json.JsonValue) -> Result(a, Failure),
) -> Result(List(a), Failure) {
  case value {
    json.JsonValueArr(items) ->
      list.index_map(items, fn(item, index) { #(item, index) })
      |> list.try_map(fn(entry) {
        result.map_error(f(entry.0), prepend_wire_path(
          "[" <> int.to_string(entry.1) <> "]",
          _,
        ))
      })
    _ -> fail("array required")
  }
}

fn prepend_wire_path(name: String, failure: Failure) -> Failure {
  case failure {
    Wire(decode_failure) -> Wire(decode.prepend_path(name, decode_failure))
    _ -> failure
  }
}

fn get(
  value: json.JsonValue,
  key: String,
  f: fn(json.JsonValue) -> Result(a, Failure),
) -> Result(a, Failure) {
  use value <- result.try(field(value, key))
  result.map_error(f(value), prepend_wire_path(key, _))
}

fn old(
  value: json.JsonValue,
  f: fn(json.JsonValue) -> Result(a, decode.DecodeFailure),
) -> Result(a, Failure) {
  result.map_error(f(value), Wire)
}

fn optional(
  value: json.JsonValue,
  decoder: fn(json.JsonValue) -> Result(a, Failure),
) -> Result(Option(a), Failure) {
  case value {
    json.JsonValueNull -> Ok(None)
    value -> result.map(decoder(value), Some)
  }
}

fn canonical_int(value: json.JsonValue) -> Result(Int, Failure) {
  use value <- result.try(text(value))
  use parsed <- result.try(
    result.map_error(int.parse(value), fn(_) {
      syntax("expected canonical integer")
    }),
  )
  case int.to_string(parsed) == value {
    True -> Ok(parsed)
    False -> fail("noncanonical integer")
  }
}

fn natural(value: json.JsonValue) -> Result(Int, Failure) {
  use value <- result.try(canonical_int(value))
  case value >= 0 {
    True -> Ok(value)
    False -> fail("negative natural")
  }
}

fn tag(value: json.JsonValue) -> Result(String, Failure) {
  get(value, "tag", text)
}

fn unit_variant(value: json.JsonValue, variant: a) -> Result(a, Failure) {
  use _ <- result.try(object(value, ["tag"]))
  Ok(variant)
}

fn decode_decimal_bound(
  value: json.JsonValue,
) -> Result(types.DecimalBound, Failure) {
  use _ <- result.try(object(value, ["mantissa", "scale", "exclusive"]))
  use mantissa <- result.try(get(value, "mantissa", canonical_int))
  use scale <- result.try(get(value, "scale", natural))
  use exclusive <- result.try(get(value, "exclusive", boolean))
  Ok(types.DecimalBound(mantissa, scale, exclusive))
}

pub fn decode_decimal_spec(
  value: json.JsonValue,
) -> Result(types.DecimalSpec, Failure) {
  use _ <- result.try(object(value, ["minimum", "maximum"]))
  use minimum <- result.try(
    get(value, "minimum", fn(value) { optional(value, decode_decimal_bound) }),
  )
  use maximum <- result.try(
    get(value, "maximum", fn(value) { optional(value, decode_decimal_bound) }),
  )
  Ok(types.DecimalSpec(minimum, maximum))
}

fn decode_value_kind(
  value: json.JsonValue,
) -> Result(types.ValueKind, Failure) {
  use tag <- result.try(tag(value))
  case tag {
    "Null" -> unit_variant(value, types.NullKind)
    "Boolean" -> unit_variant(value, types.BooleanKind)
    "Number" -> unit_variant(value, types.NumberKind)
    "String" -> unit_variant(value, types.StringKind)
    "Array" -> unit_variant(value, types.ArrayKind)
    "Object" -> unit_variant(value, types.ObjectKind)
    other -> unknown_tag(other)
  }
}

fn decode_member_test(
  value: json.JsonValue,
) -> Result(types.MemberTest, Failure) {
  use tag <- result.try(tag(value))
  case tag {
    "Absent" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.AbsentMember)
    }
    "Format" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(value, "value"))
      result.map(text(payload), types.FormatMember)
    }
    other -> unknown_tag(other)
  }
}

fn array_items(
  value: json.JsonValue,
  decoder: fn(json.JsonValue) -> Result(a, Failure),
) -> Result(List(a), Failure) {
  case value {
    json.JsonValueArr(items) -> list.try_map(items, decoder)
    _ -> fail("array required")
  }
}

pub fn decode_branch_selector(
  value: json.JsonValue,
) -> Result(types.BranchSelector, Failure) {
  use tag <- result.try(tag(value))
  case tag {
    "InternalTag" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.InternalTag)
    }
    "MemberShape" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(value, "value"))
      use tests <- result.try(
        array_items(payload, fn(value) {
          use _ <- result.try(object(value, ["key", "test"]))
          use key <- result.try(get(value, "key", text))
          use member_test <- result.try(get(value, "test", decode_member_test))
          Ok(#(key, member_test))
        }),
      )
      Ok(types.MemberShape(tests))
    }
    "Kind" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(value, "value"))
      result.map(decode_value_kind(payload), types.Kind)
    }
    "Otherwise" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Otherwise)
    }
    other -> unknown_tag(other)
  }
}

fn decode_signature_slot(
  value: json.JsonValue,
) -> Result(SignatureSlot, Failure) {
  use _ <- result.try(object(value, ["type_id", "required", "nullable"]))
  use type_id <- result.try(get(value, "type_id", text))
  use required <- result.try(get(value, "required", boolean))
  use nullable <- result.try(get(value, "nullable", boolean))
  Ok(SignatureSlot(type_id, required, nullable))
}

fn decode_signature_field(
  value: json.JsonValue,
) -> Result(SignatureField, Failure) {
  use _ <- result.try(object(value, ["wire_name", "slot"]))
  use wire_name <- result.try(get(value, "wire_name", text))
  use slot <- result.try(get(value, "slot", decode_signature_slot))
  Ok(SignatureField(wire_name, slot))
}

fn decode_library_element(
  value: json.JsonValue,
) -> Result(LibraryElementContract, Failure) {
  use _ <- result.try(object(value, ["type_id", "nullable"]))
  use type_id <- result.try(get(value, "type_id", text))
  use nullable <- result.try(get(value, "nullable", boolean))
  Ok(LibraryElementContract(type_id, nullable))
}

fn decode_library_extras(
  value: json.JsonValue,
) -> Result(LibraryExtraMembers, Failure) {
  use tag <- result.try(tag(value))
  case tag {
    "Reject" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(LibraryRejectExtras)
    }
    "Allow" -> {
      use fields <- result.try(decode_fields(value, ["key_format", "value"]))
      use key_format <- result.try(
        get(fields, "key_format", fn(value) {
          optional(value, fn(value) { old(value, decode.decode_format_use) })
        }),
      )
      use contract <- result.try(get(fields, "value", decode_library_element))
      Ok(LibraryAllowExtras(key_format, contract))
    }
    other -> unknown_tag(other)
  }
}

fn decode_library_product(
  value: json.JsonValue,
) -> Result(LibraryProductSpec, Failure) {
  use _ <- result.try(object(value, ["fields", "extras"]))
  use fields <- result.try(
    get(value, "fields", fn(value) { array(value, decode_signature_field) }),
  )
  use extras <- result.try(get(value, "extras", decode_library_extras))
  Ok(LibraryProductSpec(fields, extras))
}

fn decode_library_array(
  value: json.JsonValue,
) -> Result(LibraryArraySpec, Failure) {
  use _ <- result.try(object(value, ["item", "min_length", "max_length"]))
  use item <- result.try(get(value, "item", decode_library_element))
  use minimum <- result.try(
    get(value, "min_length", fn(value) { optional(value, natural) }),
  )
  use maximum <- result.try(
    get(value, "max_length", fn(value) { optional(value, natural) }),
  )
  Ok(LibraryArraySpec(item, minimum, maximum))
}

fn decode_library_branch(
  value: json.JsonValue,
) -> Result(LibraryUnionBranch, Failure) {
  use _ <- result.try(object(value, ["target", "wire_tag", "selector"]))
  use target <- result.try(get(value, "target", text))
  use wire_tag <- result.try(get(value, "wire_tag", text))
  use selector <- result.try(get(value, "selector", decode_branch_selector))
  Ok(LibraryUnionBranch(target, wire_tag, selector))
}

fn decode_library_union(
  value: json.JsonValue,
) -> Result(LibraryUnionSpec, Failure) {
  use _ <- result.try(object(value, ["branches"]))
  use branches <- result.try(
    get(value, "branches", fn(value) { array(value, decode_library_branch) }),
  )
  Ok(LibraryUnionSpec(branches))
}

fn decode_sealed_refinement(
  value: json.JsonValue,
) -> Result(types.SealedRefinement, Failure) {
  use _ <- result.try(object(value, ["key", "leaf"]))
  use key <- result.try(get(value, "key", text))
  use leaf <- result.try(
    get(value, "leaf", fn(value) { old(value, decode.decode_sealed_leaf) }),
  )
  Ok(types.SealedRefinement(key, leaf))
}

fn decode_unknown_kind(
  value: json.JsonValue,
) -> Result(types.UnknownKind, Failure) {
  use tag <- result.try(tag(value))
  case tag {
    "Any" -> unit_variant(value, types.AnyValue)
    "OrdinaryObject" -> unit_variant(value, types.OrdinaryObject)
    other -> unknown_tag(other)
  }
}

fn decode_fields(
  value: json.JsonValue,
  keys: List(String),
) -> Result(json.JsonValue, Failure) {
  use _ <- result.try(object(value, ["tag", "fields"]))
  use fields <- result.try(field(value, "fields"))
  use _ <- result.try(object(fields, keys))
  Ok(fields)
}

fn decode_payload(
  value: json.JsonValue,
  decoder: fn(json.JsonValue) -> Result(a, Failure),
) -> Result(a, Failure) {
  use _ <- result.try(object(value, ["tag", "value"]))
  use payload <- result.try(field(value, "value"))
  decoder(payload)
}

pub fn decode_library_shape(
  value: json.JsonValue,
) -> Result(LibraryShape, Failure) {
  use tag <- result.try(tag(value))
  case tag {
    "Unknown" ->
      result.map(decode_payload(value, decode_unknown_kind), UnknownShape)
    "Unit" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(UnitShape)
    }
    "Boolean" ->
      result.map(
        decode_payload(value, fn(value) {
          old(value, decode.decode_boolean_spec)
        }),
        BooleanShape,
      )
    "Integer" ->
      result.map(
        decode_payload(value, fn(value) {
          old(value, decode.decode_integer_spec)
        }),
        IntegerShape,
      )
    "Decimal" ->
      result.map(decode_payload(value, decode_decimal_spec), DecimalShape)
    "String" ->
      result.map(
        decode_payload(value, fn(value) {
          old(value, decode.decode_string_spec)
        }),
        StringShape,
      )
    "Bytes" ->
      result.map(
        decode_payload(value, fn(value) {
          old(value, decode.decode_length_spec)
        }),
        BytesShape,
      )
    "Product" ->
      result.map(decode_payload(value, decode_library_product), ProductShape)
    "Array" ->
      result.map(decode_payload(value, decode_library_array), ArrayShape)
    "TaggedUnion" ->
      result.map(decode_payload(value, decode_library_union), TaggedUnionShape)
    "Sealed" -> {
      use row <- result.try(decode_fields(value, ["tag", "refinements"]))
      use sealed_tag <- result.try(get(row, "tag", text))
      use refinements <- result.try(
        get(row, "refinements", fn(value) {
          array(value, decode_sealed_refinement)
        }),
      )
      Ok(SealedShape(sealed_tag, refinements))
    }
    "Never" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(NeverShape)
    }
    "Alias" -> {
      use row <- result.try(decode_fields(value, ["target"]))
      result.map(get(row, "target", text), AliasShape)
    }
    "RawBody" -> {
      use row <- result.try(decode_fields(value, ["encoding"]))
      result.map(get(row, "encoding", text), RawBodyShape)
    }
    "Opaque" -> {
      use row <- result.try(decode_fields(value, ["type_name"]))
      result.map(get(row, "type_name", text), OpaqueShape)
    }
    other -> unknown_tag(other)
  }
}

fn encoded_optional(
  value: Option(a),
  encoder: fn(a) -> Result(json.JsonValue, Failure),
) -> Result(json.JsonValue, Failure) {
  case value {
    None -> Ok(json.JsonValueNull)
    Some(value) -> encoder(value)
  }
}

fn encoded_array(
  values: List(a),
  encoder: fn(a) -> Result(json.JsonValue, Failure),
) -> Result(json.JsonValue, Failure) {
  result.map(list.try_map(values, encoder), json.JsonValueArr)
}

fn old_encode(
  value: a,
  encoder: fn(a) -> Result(json.JsonValue, decode.DecodeFailure),
) -> Result(json.JsonValue, Failure) {
  result.map_error(encoder(value), Wire)
}

fn encode_decimal_bound(value: types.DecimalBound) -> json.JsonValue {
  json.JsonValueObj([
    #("mantissa", json.JsonValueStr(int.to_string(value.mantissa))),
    #("scale", json.JsonValueStr(int.to_string(value.scale))),
    #("exclusive", json.JsonValueBool(value.exclusive)),
  ])
}

fn encode_decimal_spec(
  value: types.DecimalSpec,
) -> Result(json.JsonValue, Failure) {
  use minimum <- result.try(
    encoded_optional(value.minimum, fn(value) {
      Ok(encode_decimal_bound(value))
    }),
  )
  use maximum <- result.try(
    encoded_optional(value.maximum, fn(value) {
      Ok(encode_decimal_bound(value))
    }),
  )
  Ok(
    json.JsonValueObj([
      #("minimum", minimum),
      #("maximum", maximum),
    ]),
  )
}

fn encode_value_kind(value: types.ValueKind) -> json.JsonValue {
  json.JsonValueObj([
    #(
      "tag",
      json.JsonValueStr(case value {
        types.NullKind -> "Null"
        types.BooleanKind -> "Boolean"
        types.NumberKind -> "Number"
        types.StringKind -> "String"
        types.ArrayKind -> "Array"
        types.ObjectKind -> "Object"
      }),
    ),
  ])
}

fn encode_member_test(value: types.MemberTest) -> json.JsonValue {
  case value {
    types.AbsentMember ->
      json.JsonValueObj([#("tag", json.JsonValueStr("Absent"))])
    types.FormatMember(name) ->
      json.JsonValueObj([
        #("tag", json.JsonValueStr("Format")),
        #("value", json.JsonValueStr(name)),
      ])
  }
}

fn encode_branch_selector(
  value: types.BranchSelector,
) -> Result(json.JsonValue, Failure) {
  case value {
    types.InternalTag ->
      Ok(json.JsonValueObj([#("tag", json.JsonValueStr("InternalTag"))]))
    types.MemberShape(tests) -> {
      let encoded =
        json.JsonValueArr(
          list.map(tests, fn(member_test) {
            json.JsonValueObj([
              #("key", json.JsonValueStr(member_test.0)),
              #("test", encode_member_test(member_test.1)),
            ])
          }),
        )
      Ok(
        json.JsonValueObj([
          #("tag", json.JsonValueStr("MemberShape")),
          #("value", encoded),
        ]),
      )
    }
    types.Kind(kind) ->
      Ok(
        json.JsonValueObj([
          #("tag", json.JsonValueStr("Kind")),
          #("value", encode_value_kind(kind)),
        ]),
      )
    types.Otherwise ->
      Ok(json.JsonValueObj([#("tag", json.JsonValueStr("Otherwise"))]))
  }
}

fn encode_signature_slot(value: SignatureSlot) -> json.JsonValue {
  json.JsonValueObj([
    #("type_id", json.JsonValueStr(value.type_id)),
    #("required", json.JsonValueBool(value.required)),
    #("nullable", json.JsonValueBool(value.nullable)),
  ])
}

fn encode_signature_field(value: SignatureField) -> json.JsonValue {
  json.JsonValueObj([
    #("wire_name", json.JsonValueStr(value.wire_name)),
    #("slot", encode_signature_slot(value.slot)),
  ])
}

fn encode_library_element(value: LibraryElementContract) -> json.JsonValue {
  json.JsonValueObj([
    #("type_id", json.JsonValueStr(value.type_id)),
    #("nullable", json.JsonValueBool(value.nullable)),
  ])
}

fn encode_library_extras(
  value: LibraryExtraMembers,
) -> Result(json.JsonValue, Failure) {
  case value {
    LibraryRejectExtras ->
      Ok(json.JsonValueObj([#("tag", json.JsonValueStr("Reject"))]))
    LibraryAllowExtras(key_format, contract) -> {
      use key_format <- result.try(
        encoded_optional(key_format, fn(value) {
          old_encode(value, decode.encode_format_use)
        }),
      )
      Ok(
        json.JsonValueObj([
          #("tag", json.JsonValueStr("Allow")),
          #(
            "fields",
            json.JsonValueObj([
              #("key_format", key_format),
              #("value", encode_library_element(contract)),
            ]),
          ),
        ]),
      )
    }
  }
}

fn encode_library_product(
  value: LibraryProductSpec,
) -> Result(json.JsonValue, Failure) {
  use extras <- result.try(encode_library_extras(value.extras))
  Ok(
    json.JsonValueObj([
      #(
        "fields",
        json.JsonValueArr(list.map(value.fields, encode_signature_field)),
      ),
      #("extras", extras),
    ]),
  )
}

fn encode_library_array(value: LibraryArraySpec) -> json.JsonValue {
  json.JsonValueObj([
    #("item", encode_library_element(value.item)),
    #(
      "min_length",
      option.unwrap(
        option.map(value.minimum, fn(value) {
          json.JsonValueStr(int.to_string(value))
        }),
        json.JsonValueNull,
      ),
    ),
    #(
      "max_length",
      option.unwrap(
        option.map(value.maximum, fn(value) {
          json.JsonValueStr(int.to_string(value))
        }),
        json.JsonValueNull,
      ),
    ),
  ])
}

fn encode_library_branch(
  value: LibraryUnionBranch,
) -> Result(json.JsonValue, Failure) {
  use selector <- result.try(encode_branch_selector(value.selector))
  Ok(
    json.JsonValueObj([
      #("target", json.JsonValueStr(value.target)),
      #("wire_tag", json.JsonValueStr(value.wire_tag)),
      #("selector", selector),
    ]),
  )
}

fn encode_library_union(
  value: LibraryUnionSpec,
) -> Result(json.JsonValue, Failure) {
  use branches <- result.try(encoded_array(
    value.branches,
    encode_library_branch,
  ))
  Ok(json.JsonValueObj([#("branches", branches)]))
}

fn encode_sealed_refinement(
  value: types.SealedRefinement,
) -> Result(json.JsonValue, Failure) {
  use leaf <- result.try(old_encode(value.leaf, decode.encode_sealed_leaf))
  Ok(
    json.JsonValueObj([
      #("key", json.JsonValueStr(value.key)),
      #("leaf", leaf),
    ]),
  )
}

fn encode_unknown_kind(value: types.UnknownKind) -> json.JsonValue {
  json.JsonValueObj([
    #(
      "tag",
      json.JsonValueStr(case value {
        types.AnyValue -> "Any"
        types.OrdinaryObject -> "OrdinaryObject"
      }),
    ),
  ])
}

pub fn encode_library_shape(
  value: LibraryShape,
) -> Result(json.JsonValue, Failure) {
  let unit = fn(tag) {
    Ok(json.JsonValueObj([#("tag", json.JsonValueStr(tag))]))
  }
  let tuple = fn(tag, payload) {
    Ok(
      json.JsonValueObj([
        #("tag", json.JsonValueStr(tag)),
        #("value", payload),
      ]),
    )
  }
  case value {
    UnknownShape(kind) -> tuple("Unknown", encode_unknown_kind(kind))
    UnitShape -> unit("Unit")
    BooleanShape(spec) -> {
      use payload <- result.try(old_encode(spec, decode.encode_boolean_spec))
      tuple("Boolean", payload)
    }
    IntegerShape(spec) -> {
      use payload <- result.try(old_encode(spec, decode.encode_integer_spec))
      tuple("Integer", payload)
    }
    DecimalShape(spec) -> {
      use payload <- result.try(encode_decimal_spec(spec))
      tuple("Decimal", payload)
    }
    StringShape(spec) -> {
      use payload <- result.try(old_encode(spec, decode.encode_string_spec))
      tuple("String", payload)
    }
    BytesShape(spec) -> {
      use payload <- result.try(old_encode(spec, decode.encode_length_spec))
      tuple("Bytes", payload)
    }
    ProductShape(spec) -> {
      use payload <- result.try(encode_library_product(spec))
      tuple("Product", payload)
    }
    ArrayShape(spec) -> tuple("Array", encode_library_array(spec))
    TaggedUnionShape(spec) -> {
      use payload <- result.try(encode_library_union(spec))
      tuple("TaggedUnion", payload)
    }
    SealedShape(tag, refinements) -> {
      use refinements <- result.try(encoded_array(
        refinements,
        encode_sealed_refinement,
      ))
      Ok(
        json.JsonValueObj([
          #("tag", json.JsonValueStr("Sealed")),
          #(
            "fields",
            json.JsonValueObj([
              #("tag", json.JsonValueStr(tag)),
              #("refinements", refinements),
            ]),
          ),
        ]),
      )
    }
    NeverShape -> unit("Never")
    AliasShape(target) ->
      Ok(
        json.JsonValueObj([
          #("tag", json.JsonValueStr("Alias")),
          #(
            "fields",
            json.JsonValueObj([#("target", json.JsonValueStr(target))]),
          ),
        ]),
      )
    RawBodyShape(encoding) ->
      Ok(
        json.JsonValueObj([
          #("tag", json.JsonValueStr("RawBody")),
          #(
            "fields",
            json.JsonValueObj([#("encoding", json.JsonValueStr(encoding))]),
          ),
        ]),
      )
    OpaqueShape(name) ->
      Ok(
        json.JsonValueObj([
          #("tag", json.JsonValueStr("Opaque")),
          #(
            "fields",
            json.JsonValueObj([#("type_name", json.JsonValueStr(name))]),
          ),
        ]),
      )
  }
}

fn source(value: json.JsonValue) -> Result(SourceIdentity, Failure) {
  use _ <- result.try(
    object(value, ["repository", "revision", "path", "content_digest"]),
  )
  use repository <- result.try(get(value, "repository", text))
  use revision <- result.try(get(value, "revision", text))
  use path <- result.try(get(value, "path", text))
  use digest <- result.try(get(value, "content_digest", text))
  Ok(types.SourceIdentity(repository, revision, path, digest))
}

fn origin(value: json.JsonValue) -> Result(Origin, Failure) {
  use _ <- result.try(object(value, ["source", "locator"]))
  use source <- result.try(get(value, "source", source))
  use locator <- result.try(
    get(value, "locator", fn(value) { array(value, text) }),
  )
  Ok(types.Origin(source, locator))
}

fn internal_source(
  identity: String,
  revision: String,
  digest: String,
) -> types.SourceRef {
  types.SourceRef(
    "ncoh-type-signatures@1",
    revision,
    identity,
    digest,
    identity,
    None,
  )
}

pub fn type_ref(_library: AdmittedLibrary, id: String) -> types.TypeRef {
  reference(types.type_source(), id)
}

fn reference(source: types.SourceRef, id: String) -> types.TypeRef {
  types.TypeRef(source, id, [])
}

pub fn definition_ref(
  library: AdmittedLibrary,
  id: String,
) -> Result(types.DefinitionRef, Failure) {
  use _ <- result.try(
    result.map_error(
      list.find(library.definitions, fn(definition) { definition.id == id }),
      fn(_) { syntax("unresolved definition") },
    ),
  )
  Ok(types.DefinitionRef(types.type_source(), id))
}

fn slot(
  value: json.JsonValue,
  source: types.SourceRef,
) -> Result(types.SlotContract, Failure) {
  use slot <- result.map(decode_signature_slot(value))
  types.SlotContract(
    reference(source, slot.type_id),
    slot.required,
    slot.nullable,
  )
}

fn shape(
  value: json.JsonValue,
  source: types.SourceRef,
  id: String,
) -> Result(types.TypeShape, Failure) {
  use decoded <- result.try(decode_library_shape(value))
  Ok(type_shape(decoded, source, id))
}

fn type_shape(
  shape: LibraryShape,
  source: types.SourceRef,
  id: String,
) -> types.TypeShape {
  let reference = fn(target) { reference(source, target) }
  let origin = types.OccurrenceRef(source, [id])
  case shape {
    UnknownShape(kind) -> types.UnknownShape(kind)
    UnitShape -> types.UnitShape
    BooleanShape(spec) -> types.BooleanShape(spec)
    IntegerShape(spec) -> types.IntegerShape(spec)
    DecimalShape(spec) -> types.DecimalShape(spec)
    StringShape(spec) -> types.StringShape(spec)
    BytesShape(spec) -> types.BytesShape(spec)
    ProductShape(spec) ->
      types.ProductShape(
        types.ProductSpec(
          list.map(spec.fields, fn(field) {
            types.FieldSpec(
              field.wire_name,
              types.SlotContract(
                reference(field.slot.type_id),
                field.slot.required,
                field.slot.nullable,
              ),
              origin,
            )
          }),
          case spec.extras {
            LibraryRejectExtras -> types.RejectExtras
            LibraryAllowExtras(key, value) ->
              types.AllowExtras(
                key,
                types.ElementContract(reference(value.type_id), value.nullable),
              )
          },
        ),
      )
    ArrayShape(spec) ->
      types.ArrayShape(types.ArraySpec(
        types.ElementContract(reference(spec.item.type_id), spec.item.nullable),
        spec.minimum,
        spec.maximum,
      ))
    TaggedUnionShape(spec) ->
      types.TaggedUnionShape(
        types.UnionSpec(
          list.map(spec.branches, fn(branch) {
            types.UnionBranch(
              reference(branch.target),
              branch.wire_tag,
              branch.selector,
              origin,
            )
          }),
        ),
      )
    SealedShape(tag, refinements) -> types.SealedShape(tag, refinements)
    NeverShape -> types.Never
    AliasShape(target) -> types.AliasShape(reference(target), target)
    RawBodyShape(encoding) -> types.RawBodyShape(encoding)
    OpaqueShape(name) -> types.OpaqueShape(name)
  }
}

fn input_port(
  value: json.JsonValue,
  source: types.SourceRef,
) -> Result(composition_plan.InputPort, Failure) {
  use _ <- result.try(object(value, ["id", "contract"]))
  use id <- result.try(get(value, "id", text))
  use contract <- result.try(
    get(value, "contract", fn(value) { slot(value, source) }),
  )
  Ok(composition_plan.InputPort(
    composition_plan.PortId(id),
    contract,
    composition_plan.AnyCompatible,
    None,
  ))
}

fn output_port(
  value: json.JsonValue,
  source: types.SourceRef,
) -> Result(composition_plan.OutputPort, Failure) {
  use _ <- result.try(object(value, ["id", "contract"]))
  use id <- result.try(get(value, "id", text))
  use contract <- result.try(
    get(value, "contract", fn(value) { slot(value, source) }),
  )
  Ok(composition_plan.OutputPort(composition_plan.PortId(id), contract, None))
}

fn cause(value: json.JsonValue) -> Result(OutcomeCause, Failure) {
  use tag <- result.try(tag(value))
  case tag {
    "ValueContract" -> {
      use payload <- result.try(decode_fields(value, ["origin"]))
      get(payload, "origin", origin)
      |> result.map(ValueContract)
    }
    "ExternalCondition" -> {
      use payload <- result.try(decode_fields(value, ["specification"]))
      get(payload, "specification", origin)
      |> result.map(ExternalCondition)
    }
    other -> unknown_tag(other)
  }
}

fn production(
  value: json.JsonValue,
  source: types.SourceRef,
) -> Result(composition_plan.ResourceProduction, Failure) {
  use _ <- result.try(
    object(value, ["id", "token_type", "revision", "quantity", "provenance"]),
  )
  use type_id <- result.try(get(value, "token_type", text))
  use id <- result.try(get(value, "id", text))
  use revision <- result.try(get(value, "revision", natural))
  use quantity <- result.try(get(value, "quantity", natural))
  use provenance <- result.try(get(value, "provenance", text))
  Ok(composition_plan.ResourceProduction(
    composition_plan.ProductionId(id),
    reference(source, type_id),
    revision,
    quantity,
    provenance,
  ))
}

fn outcome(
  value: json.JsonValue,
  source: types.SourceRef,
) -> Result(OutcomeContract, Failure) {
  use _ <- result.try(
    object(value, ["id", "form", "cause", "value_ports", "produced_resources"]),
  )
  use id <- result.try(get(value, "id", text))
  use form <- result.try(
    get(value, "form", fn(value) { old(value, decode.decode_outcome_form) }),
  )
  use cause <- result.try(get(value, "cause", cause))
  use ports <- result.try(
    get(value, "value_ports", fn(value) {
      array(value, fn(value) { output_port(value, source) })
    }),
  )
  use resources <- result.try(
    get(value, "produced_resources", fn(value) {
      array(value, fn(value) { production(value, source) })
    }),
  )
  Ok(OutcomeContract(
    composition_plan.OutcomeContract(
      composition_plan.OutcomeId(id),
      form,
      ports,
      resources,
    ),
    cause,
  ))
}

fn operation(
  payload: json.JsonValue,
  source: types.SourceRef,
) -> Result(OperationContract, Failure) {
  use _ <- result.try(object(payload, ["effect", "inputs", "outcomes"]))
  use effect <- result.try(
    get(payload, "effect", fn(value) { old(value, decode.decode_effect_point) }),
  )
  use inputs <- result.try(
    get(payload, "inputs", fn(value) {
      array(value, fn(value) { input_port(value, source) })
    }),
  )
  use outcomes <- result.try(
    get(payload, "outcomes", fn(value) {
      array(value, fn(value) { outcome(value, source) })
    }),
  )
  Ok(OperationContract(effect, inputs, outcomes))
}

fn definition(
  value: json.JsonValue,
  source: types.SourceRef,
) -> Result(SignatureDefinition, Failure) {
  use _ <- result.try(object(value, ["id", "wire_identity", "shape"]))
  use id <- result.try(get(value, "id", text))
  use wire_identity <- result.try(get(value, "wire_identity", text))
  use shape <- result.try(
    get(value, "shape", fn(value) {
      use tag <- result.try(tag(value))
      case tag {
        "Value" -> result.map(decode_payload(value, text), Value)
        "Symbol" -> result.map(decode_payload(value, text), Symbol)
        "Message" -> result.map(decode_payload(value, text), Message)
        "Operation" ->
          result.map(
            decode_payload(value, fn(payload) { operation(payload, source) }),
            Operation,
          )
        other -> unknown_tag(other)
      }
    }),
  )
  Ok(SignatureDefinition(id, wire_identity, shape))
}

fn target(value: json.JsonValue) -> Result(Target, Failure) {
  use tag <- result.try(get(value, "tag", text))
  case tag {
    "Library" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Library)
    }
    "Group" -> decode_target_id(value, types.Group)
    "Definition" -> decode_target_id(value, types.Definition)
    "Type" -> decode_target_id(value, types.Type)
    "Outcome" -> {
      use payload <- result.try(decode_fields(value, ["definition", "outcome"]))
      use definition <- result.try(get(payload, "definition", text))
      use outcome <- result.try(get(payload, "outcome", text))
      Ok(types.Outcome(definition, outcome))
    }
    other -> unknown_tag(other)
  }
}

fn decode_target_id(
  value: json.JsonValue,
  construct: fn(String) -> Target,
) -> Result(Target, Failure) {
  use payload <- result.try(decode_payload(value, text))
  Ok(construct(payload))
}

pub fn decode_library(wire: String) -> Result(AdmittedLibrary, Failure) {
  use value <- result.try(result.map_error(values.parse_wire(wire), Json))
  decode_library_value(value)
}

pub fn decode_library_value(
  value: json.JsonValue,
) -> Result(AdmittedLibrary, Failure) {
  use library <- result.try(decode_library_value_unchecked(value))
  use _ <- result.try(
    check_library(library.declaration)
    |> result.map_error(LibraryRejected),
  )
  Ok(library)
}

fn decode_library_value_unchecked(
  value: json.JsonValue,
) -> Result(AdmittedLibrary, Failure) {
  use _ <- result.try(
    object(value, [
      "schema",
      "identity",
      "revision",
      "profile",
      "sources",
      "provenance",
      "groups",
      "annotations",
      "nodes",
      "definitions",
    ]),
  )
  use schema <- result.try(get(value, "schema", text))
  use identity <- result.try(get(value, "identity", text))
  use revision <- result.try(get(value, "revision", text))
  use profile <- result.try(
    get(value, "profile", fn(value) {
      old(value, decode.decode_semantic_profile)
    }),
  )
  use sources <- result.try(
    get(value, "sources", fn(value) { array(value, source) }),
  )
  use provenance <- result.try(
    get(value, "provenance", fn(value) {
      array(value, fn(value) {
        use _ <- result.try(object(value, ["target", "origins"]))
        use target <- result.try(get(value, "target", target))
        use origins <- result.try(
          get(value, "origins", fn(value) { array(value, origin) }),
        )
        Ok(ProvenanceBinding(target, origins))
      })
    }),
  )
  use groups <- result.try(
    get(value, "groups", fn(value) {
      array(value, fn(value) {
        use _ <- result.try(object(value, ["id", "members"]))
        use id <- result.try(get(value, "id", text))
        use members <- result.try(
          get(value, "members", fn(value) { array(value, text) }),
        )
        Ok(DefinitionGroup(id, members))
      })
    }),
  )
  use annotations <- result.try(
    get(value, "annotations", fn(value) {
      array(value, fn(value) {
        use _ <- result.try(object(value, ["target", "key", "value"]))
        use target <- result.try(get(value, "target", target))
        use key <- result.try(get(value, "key", text))
        use exact <- result.try(
          get(value, "value", fn(value) { old(value, decode.decode_exact) }),
        )
        Ok(Annotation(target, key, exact))
      })
    }),
  )
  let type_source = types.type_source()
  use nodes <- result.try(
    get(value, "nodes", fn(value) {
      array(value, fn(value) {
        use _ <- result.try(object(value, ["id", "shape"]))
        use id <- result.try(get(value, "id", text))
        use shape <- result.try(
          get(value, "shape", fn(value) { shape(value, type_source, id) }),
        )
        Ok(types.TypeNode(reference(type_source, id), shape, None, [], []))
      })
    }),
  )
  use definitions <- result.try(
    get(value, "definitions", fn(value) {
      array(value, fn(value) { definition(value, type_source) })
    }),
  )
  use graph_digest <- result.try(graph_digest(value))
  let declaration =
    TypeSignatureLibrary(
      schema,
      identity,
      revision,
      profile,
      sources,
      provenance,
      groups,
      annotations,
      list.map(nodes, fn(node) {
        LibraryNode(
          node.reference.definition_name,
          declared_library_shape(node.shape),
        )
      }),
      definitions,
    )
  Ok(AdmittedLibrary(
    value,
    identity,
    revision,
    validation.prepare(types.SemanticGraph(profile, nodes, [])),
    declaration,
    definitions,
    annotations,
    groups,
    sources,
    internal_source(identity, revision, graph_digest),
  ))
}

fn declared_library_shape(shape: types.TypeShape) -> LibraryShape {
  let id = fn(reference: types.TypeRef) { reference.definition_name }
  case shape {
    types.UnknownShape(kind) -> UnknownShape(kind)
    types.UnitShape -> UnitShape
    types.BooleanShape(spec) -> BooleanShape(spec)
    types.IntegerShape(spec) -> IntegerShape(spec)
    types.DecimalShape(spec) -> DecimalShape(spec)
    types.StringShape(spec) -> StringShape(spec)
    types.BytesShape(spec) -> BytesShape(spec)
    types.ProductShape(spec) ->
      ProductShape(
        LibraryProductSpec(
          list.map(spec.fields, fn(field) {
            SignatureField(
              field.wire_name,
              SignatureSlot(
                id(field.slot.type_ref),
                field.slot.required,
                field.slot.nullable,
              ),
            )
          }),
          case spec.extras {
            types.RejectExtras -> LibraryRejectExtras
            types.AllowExtras(key, value) ->
              LibraryAllowExtras(
                key,
                LibraryElementContract(id(value.type_ref), value.nullable),
              )
          },
        ),
      )
    types.ArrayShape(spec) ->
      ArrayShape(LibraryArraySpec(
        LibraryElementContract(id(spec.item.type_ref), spec.item.nullable),
        spec.min_length,
        spec.max_length,
      ))
    types.TaggedUnionShape(spec) ->
      TaggedUnionShape(
        LibraryUnionSpec(
          list.map(spec.branches, fn(branch) {
            LibraryUnionBranch(
              id(branch.target),
              branch.wire_tag,
              branch.selector,
            )
          }),
        ),
      )
    types.SealedShape(tag, refinements) -> SealedShape(tag, refinements)
    types.Never -> NeverShape
    types.AliasShape(target, _) -> AliasShape(id(target))
    types.RawBodyShape(encoding) -> RawBodyShape(encoding)
    types.OpaqueShape(name) -> OpaqueShape(name)
  }
}

fn inclusion_decode_failure(failure: Failure) -> decode.DecodeFailure {
  case failure {
    Wire(failure) -> failure
    _ -> decode.SyntaxFailure([], "declared type shape failure")
  }
}

fn inclusion_declared_shape(
  library: AdmittedLibrary,
  reference: types.TypeRef,
) -> Result(LibraryShape, decode.DecodeFailure) {
  option.to_result(
    node_by_id(library.declaration, reference.definition_name),
    Nil,
  )
  |> result.map(fn(node) { node.shape })
  |> result.map_error(fn(_) { decode.SyntaxFailure([], "undeclared type") })
}

fn inclusion_semantic_shape(
  library: AdmittedLibrary,
  reference: types.TypeRef,
) -> Result(types.TypeShape, decode.DecodeFailure) {
  list.find(library_graph(library).nodes, fn(node) {
    node.reference == reference
  })
  |> result.map(fn(node) { node.shape })
  |> result.map_error(fn(_) { decode.SyntaxFailure([], "undeclared type") })
}

pub fn inclusion_shapes(
  library: AdmittedLibrary,
  pair: composition_plan.TypePair,
  source: json.JsonValue,
  destination: json.JsonValue,
) -> Result(#(types.TypeShape, types.TypeShape), decode.DecodeFailure) {
  use source_expected <- result.try(inclusion_declared_shape(
    library,
    pair.source.type_ref,
  ))
  use destination_expected <- result.try(inclusion_declared_shape(
    library,
    pair.destination.type_ref,
  ))
  use source_declared <- result.try(
    decode_library_shape(source)
    |> result.map_error(inclusion_decode_failure)
    |> result.map_error(decode.prepend_path("source_shape", _)),
  )
  use destination_declared <- result.try(
    decode_library_shape(destination)
    |> result.map_error(inclusion_decode_failure)
    |> result.map_error(decode.prepend_path("destination_shape", _)),
  )
  use _ <- result.try(
    case
      source_declared == source_expected
      && destination_declared == destination_expected
    {
      True -> Ok(Nil)
      False -> Error(decode.SyntaxFailure([], "inclusion shape mismatch"))
    },
  )
  use source <- result.try(inclusion_semantic_shape(
    library,
    pair.source.type_ref,
  ))
  use destination <- result.try(inclusion_semantic_shape(
    library,
    pair.destination.type_ref,
  ))
  Ok(#(source, destination))
}

pub fn validate_value(
  library: AdmittedLibrary,
  id: String,
  value: json.JsonValue,
) -> Result(Nil, runtime.ValueFailure) {
  runtime.validate_value(library.prepared, type_ref(library, id), value)
}

pub fn canonical(value: json.JsonValue) -> Result(String, Failure) {
  use _ <- result.try(result.map_error(values.encode_wire(value), Json))
  result.map_error(values.encode_wire(sort_keys(value)), Json)
}

pub fn expected_basis_text(value: json.JsonValue) -> Result(String, Failure) {
  use _ <- result.try(decode_expected_generation(value))
  canonical(value)
}

const execution_failure_kinds = [
  "argumentCoverage", "invalidOutcome", "invalidPlan", "missingArgument",
  "missingProvider", "missingValue", "network", "networkTerminal", "provider",
  "providerCoverage", "providerEffect", "resource", "value",
]

const goal_observation_keys = [
  "outputs", "failures", "final_resources", "effects", "residuals",
  "execution_failures", "provenance",
]

fn goal_member(value: json.JsonValue, key: String) -> json.JsonValue {
  case value {
    json.JsonValueObj(members) ->
      case list.key_find(members, key) {
        Ok(found) -> found
        Error(_) -> json.JsonValueNull
      }
    _ -> json.JsonValueNull
  }
}

fn goal_rows(value: json.JsonValue, keys: List(String)) -> json.JsonValue {
  case value {
    json.JsonValueArr(items) ->
      json.JsonValueArr(
        list.map(items, fn(item) {
          json.JsonValueObj(
            list.map(keys, fn(key) { #(key, goal_member(item, key)) }),
          )
        }),
      )
    _ -> json.JsonValueArr([])
  }
}

fn goal_observations_wire(composition: json.JsonValue) -> json.JsonValue {
  let goal = goal_member(goal_member(composition, "problem"), "goal")
  json.JsonValueObj([
    #("outputs", goal_rows(goal_member(goal, "outputs"), ["id", "contract"])),
    #(
      "failures",
      goal_rows(goal_member(goal, "failures"), [
        "id", "contract", "final_resources",
      ]),
    ),
    #("final_resources", goal_member(goal, "final_resources")),
    #(
      "effects",
      json.JsonValueArr([
        json.JsonValueStr("network_instruction"),
        json.JsonValueStr("pending"),
      ]),
    ),
    #("residuals", json.JsonValueStr("residual_set")),
    #(
      "execution_failures",
      json.JsonValueArr(list.map(execution_failure_kinds, json.JsonValueStr)),
    ),
    #("provenance", json.JsonValueStr("certificate_basis")),
  ])
}

fn plan_returns(tree: json.JsonValue) -> List(json.JsonValue) {
  let node = goal_member(tree, "node")
  case goal_member(node, "tag") {
    json.JsonValueStr("Return") -> [goal_member(node, "value")]
    json.JsonValueStr("Invoke") | json.JsonValueStr("Guard") ->
      case goal_member(goal_member(node, "fields"), "arms") {
        json.JsonValueArr(arms) ->
          list.flat_map(arms, fn(arm) {
            case arm {
              json.JsonValueArr([_, child]) -> plan_returns(child)
              _ -> []
            }
          })
        _ -> []
      }
    _ -> []
  }
}

fn is_success_return(value: json.JsonValue) -> Bool {
  goal_member(value, "tag") == json.JsonValueStr("Success")
}

fn returned_ports(value: json.JsonValue) -> List(String) {
  case goal_member(value, "value") {
    json.JsonValueArr(pairs) ->
      list.filter_map(pairs, fn(pair) {
        case pair {
          json.JsonValueArr([json.JsonValueStr(port), ..]) -> Ok(port)
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
}

fn row_id(item: json.JsonValue) -> String {
  case goal_member(item, "id") {
    json.JsonValueStr(id) -> id
    _ -> ""
  }
}

fn row_ids(rows: json.JsonValue) -> List(String) {
  case rows {
    json.JsonValueArr(items) ->
      list.filter_map(items, fn(item) {
        case goal_member(item, "id") {
          json.JsonValueStr(id) -> Ok(id)
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
}

fn first_occurrences(values: List(String)) -> List(String) {
  list.fold(values, [], fn(seen, value) {
    case list.contains(seen, value) {
      True -> seen
      False -> list.append(seen, [value])
    }
  })
}

fn kept_rows(
  value: json.JsonValue,
  keys: List(String),
  kept: fn(String) -> Bool,
  extra: List(String),
) -> json.JsonValue {
  let declared = case value {
    json.JsonValueArr(items) ->
      list.filter(items, fn(item) { kept(row_id(item)) })
    _ -> []
  }
  let assert json.JsonValueArr(projected) =
    goal_rows(json.JsonValueArr(declared), keys)
  json.JsonValueArr(list.append(
    projected,
    list.map(extra, fn(id) {
      json.JsonValueObj(
        list.map(keys, fn(key) {
          case key == "id" {
            True -> #(key, json.JsonValueStr(id))
            False -> #(key, json.JsonValueNull)
          }
        }),
      )
    }),
  ))
}

fn plan_observations_wire(composition: json.JsonValue) -> json.JsonValue {
  let goal = goal_member(goal_member(composition, "problem"), "goal")
  let returns =
    plan_returns(goal_member(
      goal_member(goal_member(composition, "derivation"), "plan"),
      "root",
    ))
  let successes =
    returns |> list.filter(is_success_return) |> list.map(returned_ports)
  let embeddings =
    returns
    |> list.filter(fn(value) { !is_success_return(value) })
    |> list.filter_map(fn(value) {
      case goal_member(goal_member(value, "fields"), "embedding") {
        json.JsonValueStr(embedding) -> Ok(embedding)
        _ -> Error(Nil)
      }
    })
  let outputs = goal_member(goal, "outputs")
  let failures = goal_member(goal, "failures")
  let output_ids = row_ids(outputs)
  let failure_ids = row_ids(failures)
  json.JsonValueObj([
    #(
      "outputs",
      kept_rows(
        outputs,
        ["id", "contract"],
        fn(id) {
          successes != []
          && list.all(successes, fn(ports) { list.contains(ports, id) })
        },
        first_occurrences(
          list.filter(list.flatten(successes), fn(port) {
            !list.contains(output_ids, port)
          }),
        ),
      ),
    ),
    #(
      "failures",
      kept_rows(
        failures,
        ["id", "contract", "final_resources"],
        fn(id) { list.contains(embeddings, id) },
        first_occurrences(
          list.filter(embeddings, fn(embedding) {
            !list.contains(failure_ids, embedding)
          }),
        ),
      ),
    ),
    #("final_resources", goal_member(goal, "final_resources")),
    #(
      "effects",
      json.JsonValueArr([
        json.JsonValueStr("network_instruction"),
        json.JsonValueStr("pending"),
      ]),
    ),
    #("residuals", json.JsonValueStr("residual_set")),
    #(
      "execution_failures",
      json.JsonValueArr(list.map(execution_failure_kinds, json.JsonValueStr)),
    ),
    #("provenance", json.JsonValueStr("certificate_basis")),
  ])
}

pub fn goal_observations(
  composition: json.JsonValue,
) -> Result(GoalObservations, Failure) {
  result.map(canonical(goal_observations_wire(composition)), GoalObservations)
}

pub fn goal_observations_text(observations: GoalObservations) -> String {
  observations.canonical
}

fn composition_observations(
  composition: json.JsonValue,
) -> Result(Option(GoalObservations), Failure) {
  case composition {
    json.JsonValueNull -> Ok(None)
    _ -> result.map(goal_observations(composition), Some)
  }
}

fn decode_expected_generation(
  value: json.JsonValue,
) -> Result(ExpectedGeneration, Failure) {
  use _ <- result.try(object(value, ["basis", "observations"]))
  use basis <- result.try(get(value, "basis", decode_generation_identity))
  use observations <- result.try(
    get(value, "observations", fn(value) {
      case value {
        json.JsonValueNull -> Ok(None)
        _ -> {
          use _ <- result.try(object(value, goal_observation_keys))
          result.map(canonical(value), fn(text) { Some(GoalObservations(text)) })
        }
      }
    }),
  )
  Ok(ExpectedGeneration(basis, observations))
}

pub fn expected_generation_text(
  input: json.JsonValue,
) -> Result(String, Failure) {
  canonical(
    json.JsonValueObj([
      #("basis", goal_member(input, "basis")),
      #("observations", case goal_member(input, "composition") {
        json.JsonValueNull -> json.JsonValueNull
        composition -> goal_observations_wire(composition)
      }),
    ]),
  )
}

fn expected_generation_wire(
  basis: GenerationIdentity,
  composition: json.JsonValue,
) -> json.JsonValue {
  json.JsonValueObj([
    #("basis", generation_identity_wire(basis)),
    #("observations", case composition {
      json.JsonValueNull -> json.JsonValueNull
      _ -> goal_observations_wire(composition)
    }),
  ])
}

fn canonical_number(value: String) -> String {
  let sign = case string.starts_with(value, "-") {
    True -> "-"
    False -> ""
  }
  let unsigned = string.remove_prefix(value, "-")
  let #(mantissa, exponent_text) = case string.split_once(unsigned, "e") {
    Ok(parts) -> parts
    Error(_) ->
      case string.split_once(unsigned, "E") {
        Ok(parts) -> parts
        Error(_) -> #(unsigned, "0")
      }
  }
  let exponent_text = string.remove_prefix(exponent_text, "+")
  let exponent = int.parse(exponent_text) |> result.unwrap(0)
  let #(whole, fraction) = case string.split_once(mantissa, ".") {
    Ok(parts) -> parts
    Error(_) -> #(mantissa, "")
  }
  let digits =
    { whole <> fraction }
    |> string.to_graphemes
    |> list.drop_while(fn(digit) { digit == "0" })
  case digits {
    [] -> "0"
    _ -> {
      let digits = string.concat(digits)
      let scale = string.length(fraction) - exponent
      case scale <= 0 {
        True -> sign <> digits <> string.repeat("0", 0 - scale)
        False -> {
          let scientific = int.min(9 + string.length(digits) - scale, 0)
          let decimal_places = scale + scientific
          let split = string.length(digits) - decimal_places
          let left = case split > 0 {
            True -> string.slice(digits, 0, split)
            False -> "0"
          }
          let right =
            {
              string.repeat("0", int.max(0 - split, 0))
              <> string.slice(
                digits,
                int.max(split, 0),
                int.min(decimal_places, string.length(digits)),
              )
            }
            |> string.to_graphemes
            |> list.reverse
            |> list.drop_while(fn(digit) { digit == "0" })
            |> list.reverse
            |> string.concat
          case scientific, right {
            0, "" -> sign <> left
            _, _ ->
              sign
              <> left
              <> "."
              <> right
              <> case scientific {
                0 -> ""
                _ -> "e" <> int.to_string(scientific)
              }
          }
        }
      }
    }
  }
}

fn sort_keys(value: json.JsonValue) -> json.JsonValue {
  case value {
    json.JsonValueObj(members) ->
      json.JsonValueObj(
        list.map(
          list.sort(members, fn(a, b) { string.compare(a.0, b.0) }),
          fn(member) { #(member.0, sort_keys(member.1)) },
        ),
      )
    json.JsonValueArr(items) -> json.JsonValueArr(list.map(items, sort_keys))
    json.JsonValueDec(value) -> json.JsonValueDec(canonical_number(value))
    _ -> value
  }
}

fn hash(value: json.JsonValue) -> Result(String, Failure) {
  result.map(canonical(value), native.sha256_utf8)
}

fn replace(
  value: json.JsonValue,
  key: String,
  replacement: json.JsonValue,
) -> json.JsonValue {
  case value {
    json.JsonValueObj(members) ->
      json.JsonValueObj(
        list.map(members, fn(member) {
          case member.0 == key {
            True -> #(key, replacement)
            False -> member
          }
        }),
      )
    _ -> value
  }
}

fn sort_by(
  values: List(json.JsonValue),
  key: fn(json.JsonValue) -> Result(String, Failure),
) -> Result(List(json.JsonValue), Failure) {
  use keyed <- result.try(
    list.try_map(values, fn(value) {
      use key <- result.try(key(value))
      Ok(#(key, value))
    }),
  )
  Ok(
    list.map(list.sort(keyed, fn(a, b) { string.compare(a.0, b.0) }), fn(entry) {
      entry.1
    }),
  )
}

fn compare_keys(left: List(String), right: List(String)) -> order.Order {
  case left, right {
    [], [] -> order.Eq
    [], _ -> order.Lt
    _, [] -> order.Gt
    [left, ..left_rest], [right, ..right_rest] ->
      case string.compare(left, right) {
        order.Eq -> compare_keys(left_rest, right_rest)
        compared -> compared
      }
  }
}

fn sort_by_keys(
  values: List(json.JsonValue),
  key: fn(json.JsonValue) -> Result(List(String), Failure),
) -> Result(List(json.JsonValue), Failure) {
  use keyed <- result.try(
    list.try_map(values, fn(value) {
      use key <- result.try(key(value))
      Ok(#(key, value))
    }),
  )
  Ok(
    list.map(list.sort(keyed, fn(a, b) { compare_keys(a.0, b.0) }), fn(entry) {
      entry.1
    }),
  )
}

fn items(
  value: json.JsonValue,
  name: String,
) -> Result(List(json.JsonValue), Failure) {
  get(value, name, fn(value) { array(value, Ok) })
}

fn id_key(value: json.JsonValue) -> Result(String, Failure) {
  get(value, "id", text)
}

fn target_key(value: json.JsonValue) -> Result(String, Failure) {
  get(value, "target", canonical)
}

fn graph_definition(value: json.JsonValue) -> Result(json.JsonValue, Failure) {
  use shape <- result.try(field(value, "shape"))
  use tag <- result.try(get(shape, "tag", text))
  case tag {
    "Operation" -> {
      use operation <- result.try(field(shape, "value"))
      use outcomes <- result.try(items(operation, "outcomes"))
      use outcomes <- result.try(
        list.try_map(outcomes, fn(outcome) {
          use cause <- result.try(field(outcome, "cause"))
          use tag <- result.try(field(cause, "tag"))
          Ok(replace(outcome, "cause", json.JsonValueObj([#("tag", tag)])))
        }),
      )
      Ok(replace(
        value,
        "shape",
        replace(
          shape,
          "value",
          replace(operation, "outcomes", json.JsonValueArr(outcomes)),
        ),
      ))
    }
    _ -> Ok(value)
  }
}

fn signature_projections(
  library: AdmittedLibrary,
) -> Result(#(String, String, String), Failure) {
  use graph <- result.try(
    graph_projection(library.wire) |> result.try(canonical),
  )
  use definitions <- result.try(
    items(library.wire, "definitions")
    |> result.try(fn(items) { sort_by(items, id_key) }),
  )
  use sources <- result.try(
    items(library.wire, "sources")
    |> result.try(fn(items) {
      sort_by_keys(items, fn(value) {
        use repository <- result.try(get(value, "repository", text))
        use revision <- result.try(get(value, "revision", text))
        use path <- result.try(get(value, "path", text))
        use digest <- result.try(get(value, "content_digest", text))
        Ok([repository, revision, path, digest])
      })
    }),
  )
  use provenance <- result.try(
    items(library.wire, "provenance")
    |> result.try(fn(items) { sort_by(items, target_key) }),
  )
  use provenance <- result.try(
    list.try_map(provenance, fn(value) {
      use origins <- result.try(
        items(value, "origins")
        |> result.try(fn(items) { sort_by(items, canonical) }),
      )
      Ok(replace(value, "origins", json.JsonValueArr(origins)))
    }),
  )
  use origins <- result.try(
    list.try_map(definitions, fn(definition) {
      use id <- result.try(field(definition, "id"))
      use shape <- result.try(field(definition, "shape"))
      use tag <- result.try(get(shape, "tag", text))
      case tag {
        "Operation" -> {
          use operation <- result.try(field(shape, "value"))
          use outcomes <- result.try(
            items(operation, "outcomes")
            |> result.try(fn(items) { sort_by(items, id_key) }),
          )
          list.try_map(outcomes, fn(outcome) {
            use outcome_id <- result.try(field(outcome, "id"))
            use cause <- result.try(field(outcome, "cause"))
            Ok(
              json.JsonValueObj([
                #("definition", id),
                #("outcome", outcome_id),
                #("cause", cause),
              ]),
            )
          })
        }
        _ -> Ok([])
      }
    }),
  )
  use provenance <- result.try(
    canonical(
      json.JsonValueObj([
        #("sources", json.JsonValueArr(sources)),
        #("provenance", json.JsonValueArr(provenance)),
        #("outcome_origins", json.JsonValueArr(list.flatten(origins))),
      ]),
    ),
  )
  use groups <- result.try(
    items(library.wire, "groups")
    |> result.try(fn(items) { sort_by(items, id_key) }),
  )
  use groups <- result.try(
    list.try_map(groups, fn(value) {
      use members <- result.try(
        items(value, "members")
        |> result.try(fn(items) { sort_by(items, text) }),
      )
      Ok(replace(value, "members", json.JsonValueArr(members)))
    }),
  )
  use annotations <- result.try(
    items(library.wire, "annotations")
    |> result.try(fn(items) {
      sort_by_keys(items, fn(value) {
        use target <- result.try(target_key(value))
        use key <- result.try(get(value, "key", text))
        use exact <- result.try(get(value, "value", canonical))
        Ok([target, key, exact])
      })
    }),
  )
  use metadata <- result.try(
    canonical(
      json.JsonValueObj([
        #("groups", json.JsonValueArr(groups)),
        #("annotations", json.JsonValueArr(annotations)),
      ]),
    ),
  )
  Ok(#(graph, provenance, metadata))
}

pub fn signature_digests(
  library: AdmittedLibrary,
) -> Result(#(String, String, String), Failure) {
  result.map(signature_projections(library), fn(texts) {
    #(
      native.sha256_utf8(texts.0),
      native.sha256_utf8(texts.1),
      native.sha256_utf8(texts.2),
    )
  })
}

fn generation_identity_wire(identity: GenerationIdentity) -> json.JsonValue {
  let types.ProfileRef(profile_identity, profile_revision, profile_digest) =
    identity.profile
  json.JsonValueObj([
    #("signature_schema", json.JsonValueStr(identity.signature_schema)),
    #("library_identity", json.JsonValueStr(identity.library_identity)),
    #("library_revision", json.JsonValueStr(identity.library_revision)),
    #(
      "profile",
      json.JsonValueObj([
        #("identity", json.JsonValueStr(profile_identity)),
        #("revision", json.JsonValueStr(profile_revision)),
        #("content_digest", json.JsonValueStr(profile_digest)),
      ]),
    ),
    #("graph_sha256", json.JsonValueStr(identity.graph_sha256)),
    #("provenance_sha256", json.JsonValueStr(identity.provenance_sha256)),
    #("metadata_sha256", json.JsonValueStr(identity.metadata_sha256)),
    #("problem_sha256", case identity.problem_sha256 {
      None -> json.JsonValueNull
      Some(value) -> json.JsonValueStr(value)
    }),
    #("observations_sha256", case identity.observations_sha256 {
      None -> json.JsonValueNull
      Some(value) -> json.JsonValueStr(value)
    }),
    #("entrypoints_sha256", json.JsonValueStr(identity.entrypoints_sha256)),
  ])
}

fn decode_generation_identity(
  value: json.JsonValue,
) -> Result(GenerationIdentity, Failure) {
  use _ <- result.try(
    object(value, [
      "signature_schema",
      "library_identity",
      "library_revision",
      "profile",
      "graph_sha256",
      "provenance_sha256",
      "metadata_sha256",
      "problem_sha256",
      "observations_sha256",
      "entrypoints_sha256",
    ]),
  )
  use signature_schema <- result.try(get(value, "signature_schema", text))
  use library_identity <- result.try(get(value, "library_identity", text))
  use library_revision <- result.try(get(value, "library_revision", text))
  use profile <- result.try(
    get(value, "profile", fn(value) { old(value, decode.decode_profile_ref) }),
  )
  use graph_sha256 <- result.try(get(value, "graph_sha256", text))
  use provenance_sha256 <- result.try(get(value, "provenance_sha256", text))
  use metadata_sha256 <- result.try(get(value, "metadata_sha256", text))
  use problem_sha256 <- result.try(
    get(value, "problem_sha256", fn(value) {
      case value {
        json.JsonValueNull -> Ok(None)
        json.JsonValueStr(value) -> Ok(Some(value))
        _ -> fail("problem digest")
      }
    }),
  )
  use observations_sha256 <- result.try(
    get(value, "observations_sha256", fn(value) {
      case value {
        json.JsonValueNull -> Ok(None)
        json.JsonValueStr(value) -> Ok(Some(value))
        _ -> fail("observations digest")
      }
    }),
  )
  use entrypoints_sha256 <- result.try(get(value, "entrypoints_sha256", text))
  Ok(GenerationIdentity(
    signature_schema,
    library_identity,
    library_revision,
    profile,
    graph_sha256,
    provenance_sha256,
    metadata_sha256,
    problem_sha256,
    observations_sha256,
    entrypoints_sha256,
  ))
}

fn generation_projections(
  library: AdmittedLibrary,
  composition: json.JsonValue,
  entrypoints: json.JsonValue,
) -> Result(GenerationProjections, Failure) {
  use #(graph, provenance, metadata) <- result.try(signature_projections(
    library,
  ))
  use sorted <- result.try(
    array(entrypoints, Ok)
    |> result.try(fn(items) {
      sort_by(items, fn(value) { get(value, "identity", identifier) })
    }),
  )
  use entrypoints <- result.try(canonical(json.JsonValueArr(sorted)))
  use observations <- result.try(composition_observations(composition))
  use composition <- result.try(case composition {
    json.JsonValueNull -> Ok(None)
    _ -> result.map(canonical(composition), Some)
  })
  Ok(GenerationProjections(
    graph,
    provenance,
    metadata,
    entrypoints,
    composition,
    observations,
  ))
}

fn calculate_generation_identity(
  library: AdmittedLibrary,
  composition: json.JsonValue,
  entrypoints: json.JsonValue,
) -> Result(GenerationIdentity, Failure) {
  use projections <- result.try(generation_projections(
    library,
    composition,
    entrypoints,
  ))
  use profile <- result.try(library_profile(library))
  Ok(GenerationIdentity(
    library_signature_schema,
    library.identity,
    library.revision,
    profile,
    native.sha256_utf8(projections.graph),
    native.sha256_utf8(projections.provenance),
    native.sha256_utf8(projections.metadata),
    option.map(projections.composition, native.sha256_utf8),
    option.map(projections.observations, observations_digest),
    native.sha256_utf8(projections.entrypoints),
  ))
}

pub fn generation_basis(
  library: AdmittedLibrary,
  composition: json.JsonValue,
  entrypoints: json.JsonValue,
) -> Result(json.JsonValue, Failure) {
  result.map(
    calculate_generation_identity(library, composition, entrypoints),
    generation_identity_wire,
  )
}

pub fn assemble_generation(
  library_json: String,
  composition: json.JsonValue,
  entrypoints: json.JsonValue,
) -> Result(#(String, String), Failure) {
  use library <- result.try(decode_library(library_json))
  use identity <- result.try(calculate_generation_identity(
    library,
    composition,
    entrypoints,
  ))
  let basis = generation_identity_wire(identity)
  let input =
    json.JsonValueObj([
      #("schema", json.JsonValueStr("ncoh-checked-generation@5")),
      #("basis", basis),
      #("signatures", library.wire),
      #("composition", composition),
      #("entrypoints", entrypoints),
    ])
  use expected <- result.try(
    canonical(expected_generation_wire(identity, composition)),
  )
  use exchange <- result.try(canonical(input))
  Ok(#(expected, exchange))
}

const generation_rule_revision = "ncoh-checked-generation@5"

const certificate_operation = "admit_signature_generation"

const library_signature_schema = "ncoh-type-signatures@1"

fn generation_rule(
  _source: quotient_source.SourceRef(String, String),
  _coordinate: GenerationCoordinate,
  _observations: Option(GoalObservations),
  projections: GenerationProjections,
) -> quotient_digest.ProjectionDigests {
  projection_digests(
    native.sha256_utf8(projections.entrypoints),
    native.sha256_utf8(projections.graph),
    native.sha256_utf8(projections.metadata),
    option.map(projections.composition, native.sha256_utf8),
    option.map(projections.observations, observations_digest),
    native.sha256_utf8(projections.provenance),
  )
}

fn observations_digest(observations: GoalObservations) -> String {
  native.sha256_utf8(observations.canonical)
}

fn projection_digests(
  entrypoints: String,
  graph: String,
  metadata: String,
  problem: Option(String),
  observations: Option(String),
  provenance: String,
) -> quotient_digest.ProjectionDigests {
  let scoped = fn(digest) {
    quotient_digest.ProjectionDigest(
      digest,
      quotient_digest.CrossLanguage("sha256"),
    )
  }
  dict.from_list(
    list.flatten([
      [
        #("entrypoints", scoped(entrypoints)),
        #("graph", scoped(graph)),
        #("metadata", scoped(metadata)),
      ],
      option.values([
        option.map(problem, fn(digest) { #("problem", scoped(digest)) }),
        option.map(observations, fn(digest) {
          #("observations", scoped(digest))
        }),
      ]),
      [#("provenance", scoped(provenance))],
    ]),
  )
}

fn generation_table() -> Result(
  quotient_rule_table.RuleTable(
    String,
    String,
    GenerationCoordinate,
    Option(GoalObservations),
    GenerationProjections,
  ),
  quotient_rule_table.DuplicateRule,
) {
  quotient_rule_table.new([#(generation_rule_revision, generation_rule)])
}

fn library_metadata_of(identity: GenerationIdentity) -> LibraryMetadata {
  LibraryMetadata(
    identity.signature_schema,
    identity.library_identity,
    identity.library_revision,
    identity.profile,
  )
}

fn generation_coordinate(
  identity: GenerationIdentity,
  library: LibraryMetadata,
) -> GenerationCoordinate {
  GenerationCoordinate(
    identity.signature_schema,
    identity.profile,
    identity.graph_sha256,
    identity.provenance_sha256,
    identity.metadata_sha256,
    identity.problem_sha256,
    identity.observations_sha256,
    identity.entrypoints_sha256,
    library,
  )
}

fn actual_library_metadata(
  library: AdmittedLibrary,
) -> Result(LibraryMetadata, Failure) {
  use profile <- result.try(library_profile(library))
  Ok(LibraryMetadata(
    library_signature_schema,
    library.identity,
    library.revision,
    profile,
  ))
}

fn library_profile(
  library: AdmittedLibrary,
) -> Result(types.ProfileRef, Failure) {
  get(library.wire, "profile", fn(value) {
    use reference <- result.try(field(value, "reference"))
    old(reference, decode.decode_profile_ref)
  })
}

fn admit_declared(
  expected_generation: ExpectedGeneration,
  declared: GenerationIdentity,
  library: AdmittedLibrary,
  projections: GenerationProjections,
  certificate_observations: Option(GoalObservations),
) -> Result(GenerationAdmission, AdmissionFailure) {
  let expected = expected_generation.basis
  use actual <- result.try(
    actual_library_metadata(library) |> result.map_error(admission.Generation),
  )
  let assert Ok(table) = generation_table()
  let certificate =
    quotient_certificate.Certificate(
      rule_revision: generation_rule_revision,
      source: quotient_source.SourceRef(
        declared.library_identity,
        declared.library_revision,
      ),
      coordinate: generation_coordinate(declared, actual),
      digests: projection_digests(
        declared.entrypoints_sha256,
        declared.graph_sha256,
        declared.metadata_sha256,
        declared.problem_sha256,
        declared.observations_sha256,
        declared.provenance_sha256,
      ),
      residuals: quotient_certificate.residual_set([]),
      observations: certificate_observations,
      evidence: projections,
    )
  let expectation =
    quotient_certificate.Expected(
      rule_revision: generation_rule_revision,
      source: quotient_source.SourceRef(
        expected.library_identity,
        expected.library_revision,
      ),
      coordinate: generation_coordinate(expected, library_metadata_of(declared)),
      observations: expected_generation.observations,
      residuals: quotient_certificate.residual_set([]),
    )
  quotient.admit(
    table,
    certificate,
    expectation,
    certificate_operation,
    fn(identity) { identity },
    fn(revision) { revision },
  )
  |> result.map_error(admission.Certificate)
}

fn first_duplicate(identities: List(String)) -> Option(String) {
  case identities {
    [] -> None
    [identity, ..rest] ->
      case list.contains(rest, identity) {
        True -> Some(identity)
        False -> first_duplicate(rest)
      }
  }
}

fn admit_declared_generation(
  expected_json: String,
  input_json: String,
) -> Result(GenerationContext, AdmissionFailure) {
  use expected <- result.try(
    values.parse_wire(expected_json)
    |> result.map_error(fn(failure) { admission.Generation(Json(failure)) })
    |> result.try(fn(value) {
      decode_expected_generation(value)
      |> result.map_error(admission.Generation)
    }),
  )
  use input <- result.try(
    values.parse_wire(input_json)
    |> result.map_error(fn(failure) { admission.Generation(Json(failure)) }),
  )
  use _ <- result.try(
    object(input, [
      "schema",
      "basis",
      "signatures",
      "composition",
      "entrypoints",
    ])
    |> result.map_error(admission.Generation),
  )
  use schema <- result.try(
    get(input, "schema", text) |> result.map_error(admission.Generation),
  )
  use _ <- result.try(case schema == generation_rule_revision {
    True -> Ok(Nil)
    False -> Error(admission.UnsupportedSchema(schema))
  })
  use supplied <- result.try(
    get(input, "basis", decode_generation_identity)
    |> result.map_error(admission.Generation),
  )
  use library <- result.try(
    get(input, "signatures", decode_library_value_unchecked)
    |> result.map_error(admission.Generation),
  )
  use composition_wire <- result.try(
    field(input, "composition") |> result.map_error(admission.Generation),
  )
  use entrypoints <- result.try(
    field(input, "entrypoints") |> result.map_error(admission.Generation),
  )
  use entries <- result.try(
    get(input, "entrypoints", fn(value) {
      array(value, fn(value) {
        use _ <- result.try(object(value, ["identity", "definition"]))
        use identity <- result.try(get(value, "identity", text))
        use definition <- result.try(get(value, "definition", text))
        Ok(#(identity, definition))
      })
    })
    |> result.map_error(admission.Generation),
  )
  use _ <- result.try(
    case entries == [] && composition_wire == json.JsonValueNull {
      True -> Error(admission.EntrypointsEmpty)
      False -> Ok(Nil)
    },
  )
  use _ <- result.try(case list.any(entries, fn(entry) { entry.0 == "" }) {
    True -> Error(admission.EntrypointIdentityEmpty)
    False -> Ok(Nil)
  })
  use _ <- result.try(
    case first_duplicate(list.map(entries, fn(entry) { entry.0 })) {
      Some(identity) -> Error(admission.EntrypointDuplicate(identity))
      None -> Ok(Nil)
    },
  )
  use _ <- result.try(
    case
      list.find(entries, fn(entry) {
        !list.any(library.definitions, fn(value) { value.id == entry.1 })
      })
    {
      Ok(entry) -> Error(admission.EntrypointUnresolved(entry.0, entry.1))
      Error(_) -> Ok(Nil)
    },
  )
  use _ <- result.try(
    check_library(library.declaration)
    |> result.map_error(admission.Library),
  )
  use projections <- result.try(
    generation_projections(library, composition_wire, entrypoints)
    |> result.map_error(admission.Generation),
  )
  let checked = decode_generation_composition(library, composition_wire)
  use certificate_observations <- result.try(case composition_wire {
    json.JsonValueNull -> Ok(None)
    _ ->
      case checked {
        Ok(_) ->
          canonical(plan_observations_wire(composition_wire))
          |> result.map(fn(text) { Some(GoalObservations(text)) })
          |> result.map_error(admission.Generation)
        Error(_) -> Ok(projections.observations)
      }
  })
  use admitted <- result.try(admit_declared(
    expected,
    supplied,
    library,
    projections,
    certificate_observations,
  ))
  Ok(GenerationContext(
    input,
    expected.basis,
    library,
    composition_wire,
    checked,
    admitted,
  ))
}

pub fn check_generation_context(
  context: GenerationContext,
) -> Result(CheckedGeneration, AdmissionFailure) {
  use checked <- result.try(context.checked)
  Ok(CheckedGeneration(
    context.wire,
    context.identity,
    context.library,
    checked.0,
    checked.1,
    context.admission,
  ))
}

fn decode_generation_composition(
  library: AdmittedLibrary,
  composition: json.JsonValue,
) -> GeneratedComposition {
  let basis =
    calculate_generation_identity(
      library,
      json.JsonValueNull,
      json.JsonValueArr([]),
    )
  case composition {
    json.JsonValueNull -> Ok(#(None, []))
    composition_wire -> {
      use _ <- result.try(
        object(composition_wire, ["problem", "derivation"])
        |> result.map_error(composition_wire_failure)
        |> result.map_error(admission_wire_or_composition),
      )
      use problem_wire <- result.try(
        field(composition_wire, "problem")
        |> result.map_error(admission_wire_or_composition),
      )
      use #(problem, causes) <- result.try(
        decode_problem_with(library, basis, problem_wire)
        |> result.map_error(admission_wire_or_composition),
      )
      use prepared <- result.try(
        prepare_composition(library, problem, causes)
        |> result.map_error(admission.CompositionInput),
      )
      use plan <- result.try(
        old(composition_wire, fn(value) {
          decode.decode_generation_plan(
            value,
            composition_wire,
            derivation_decoder_with(library, basis),
            fn(snapshot, problem) { canonical(snapshot) == canonical(problem) },
          )
        })
        |> result.map_error(admission_wire_or_composition),
      )
      Ok(#(Some(composition_plan.admitted_composition(prepared, plan)), causes))
    }
  }
}

pub fn admit_generation_context(
  expected_json: String,
  input_json: String,
) -> Result(GenerationContext, AdmissionFailure) {
  use context <- result.try(admit_declared_generation(expected_json, input_json))
  use _ <- result.try(check_generation_context(context))
  Ok(context)
}

pub fn admit_generation(
  expected_json: String,
  input_json: String,
) -> Result(CheckedGeneration, AdmissionFailure) {
  use context <- result.try(admit_declared_generation(expected_json, input_json))
  check_generation_context(context)
}

fn composition_wire_failure(failure: Failure) -> Failure {
  case failure {
    Wire(decode.SyntaxFailure([], condition)) ->
      Wire(decode.SyntaxFailure(["$"], condition))
    other -> other
  }
}

fn admission_wire_or_composition(failure: Failure) -> AdmissionFailure {
  case failure {
    Wire(decode.CompositionFailure(value)) -> admission.Composition(value)
    Wire(value) -> admission.Wire(value)
    _ -> admission.Generation(failure)
  }
}

fn decode_failure(failure: Failure) -> decode.DecodeFailure {
  case failure {
    Wire(value) -> value
    _ -> decode.SyntaxFailure([], "generation identity")
  }
}

fn generation_basis_decoder(
  library: AdmittedLibrary,
  basis: Result(GenerationIdentity, Failure),
  mismatch: String,
) -> fn(json.JsonValue) ->
  Result(composition_plan.SemanticBasis, decode.DecodeFailure) {
  fn(value) {
    result.map_error(
      {
        use supplied <- result.try(decode_generation_identity(value))
        use expected <- result.try(basis)
        use _ <- result.try(require(supplied == expected, mismatch))
        Ok(composition_plan.semantic_basis_of(library_graph(library)))
      },
      decode_failure,
    )
  }
}

pub fn derivation_decoder(
  library: AdmittedLibrary,
) -> decode.DerivationDecoder {
  derivation_decoder_with(
    library,
    calculate_generation_identity(
      library,
      json.JsonValueNull,
      json.JsonValueArr([]),
    ),
  )
}

fn derivation_decoder_with(
  library: AdmittedLibrary,
  basis: Result(GenerationIdentity, Failure),
) -> decode.DerivationDecoder {
  decode.DerivationDecoder(
    shapes: fn(pair, source, destination) {
      inclusion_shapes(library, pair, source, destination)
    },
    basis: generation_basis_decoder(library, basis, "inclusion basis mismatch"),
    token_identity: definition_token_type(library),
  )
}

fn problem_decoder(
  library: AdmittedLibrary,
  basis: Result(GenerationIdentity, Failure),
) -> decode.ProblemDecoder(OutcomeCause) {
  decode.ProblemDecoder(
    basis: generation_basis_decoder(
      library,
      basis,
      "composition signature basis mismatch",
    ),
    cause: fn(value) { result.map_error(cause(value), decode_failure) },
  )
}

pub fn decode_problem(
  library: AdmittedLibrary,
  problem: json.JsonValue,
) -> Result(
  #(
    composition_plan.CompositionInput,
    List(#(composition_plan.FunctionRef, List(OutcomeContract))),
  ),
  Failure,
) {
  decode_problem_with(
    library,
    calculate_generation_identity(
      library,
      json.JsonValueNull,
      json.JsonValueArr([]),
    ),
    problem,
  )
}

fn decode_problem_with(
  library: AdmittedLibrary,
  basis: Result(GenerationIdentity, Failure),
  problem: json.JsonValue,
) -> Result(
  #(
    composition_plan.CompositionInput,
    List(#(composition_plan.FunctionRef, List(OutcomeContract))),
  ),
  Failure,
) {
  use decoded <- result.try(
    old(problem, fn(value) {
      decode.decode_composition_input(value, problem_decoder(library, basis))
    }),
  )
  Ok(#(
    decoded.input,
    list.map(decoded.causes, fn(entry) {
      #(
        entry.0,
        list.map(entry.1, fn(outcome) { OutcomeContract(outcome.0, outcome.1) }),
      )
    }),
  ))
}

fn operation_extension_valid(
  base: OperationContract,
  extended: List(OutcomeContract),
  effect: types.EffectPoint,
  inputs: List(composition_plan.InputPort),
  library: TypeSignatureLibrary,
) -> Bool {
  base.effect == effect
  && same_inputs(inputs, base.inputs)
  && unique_nonempty_ids(
    list.map(extended, fn(outcome) { outcome.contract.id.value }),
  )
  && list.all(base.outcomes, fn(outcome) { list.contains(extended, outcome) })
  && list.all(extended, fn(outcome) {
    list.contains(base.outcomes, outcome)
    || case outcome.cause {
      ExternalCondition(_) -> outcome_valid(library, outcome)
      ValueContract(_) -> False
    }
  })
}

pub fn prepare_composition(
  library: AdmittedLibrary,
  input: composition_plan.CompositionInput,
  causes: List(#(composition_plan.FunctionRef, List(OutcomeContract))),
) -> Result(
  composition_plan.PreparedCompositionInput,
  composition_plan.CompositionInputFailure,
) {
  use _ <- result.try(
    check_library(library.declaration)
    |> result.map_error(composition_plan.InvalidLibrary),
  )
  use _ <- result.try(
    list.try_map(input.signatures, fn(function) {
      let failure = fn(reason) {
        composition_plan.InvalidSignature(function.reference, reason)
      }
      use declared <- result.try(
        result.map_error(list.key_find(causes, function.reference), fn(_) {
          failure("missing outcome cause")
        }),
      )
      use _ <- result.try(
        case
          list.map(declared, fn(outcome) { outcome.contract })
          == function.outcomes
        {
          True -> Ok(Nil)
          False -> Error(failure("outcome cause coverage"))
        },
      )
      case
        list.all(declared, fn(outcome) {
          outcome_valid(library.declaration, outcome)
        })
      {
        True -> Ok(Nil)
        False -> Error(failure("outcome cause or external failure value"))
      }
    }),
  )
  composition_input.prepare_direct_composition(
    library.prepared,
    input,
    fn(function, reference) {
      let fail = fn(reason) {
        composition_plan.InvalidSignature(function.reference, reason)
      }
      use definition <- result.try(
        result.map_error(
          list.find(library.definitions, fn(definition) {
            definition.id == reference.name
          }),
          fn(_) { fail("unresolved operation identity") },
        ),
      )
      use operation <- result.try(case definition.shape {
        Operation(operation) -> Ok(operation)
        _ -> Error(fail("definition is not an operation"))
      })
      use _ <- result.try(
        case
          function.reference.identity == definition.wire_identity
          && function.reference.revision == library.revision
          && function.reference.content_digest == library.source.content_digest
        {
          True -> Ok(Nil)
          False -> Error(fail("operation identity basis"))
        },
      )
      use declared <- result.try(
        result.map_error(list.key_find(causes, function.reference), fn(_) {
          fail("outcome causes absent")
        }),
      )
      use _ <- result.try(
        case
          list.map(declared, fn(outcome) { outcome.contract })
          == function.outcomes
        {
          True -> Ok(Nil)
          False -> Error(fail("outcome cause coverage"))
        },
      )
      let expected_effect = case operation.effect {
        types.HttpRequestResponse -> composition_plan.HttpRequestResponse
        types.DataOnly -> composition_plan.DataOnly
      }
      use _ <- result.try(case function.effect == expected_effect {
        True -> Ok(Nil)
        False -> Error(fail("operation effect"))
      })
      let effect = case function.effect {
        composition_plan.HttpRequestResponse -> types.HttpRequestResponse
        _ -> types.DataOnly
      }
      case
        operation_extension_valid(
          operation,
          declared,
          effect,
          function.inputs,
          library.declaration,
        )
      {
        True -> Ok(Nil)
        False -> Error(fail("base outcome preservation or external supplement"))
      }
    },
    fn(function, _) {
      validation.meaning_obligations(
        library_prepared(library),
        list.append(
          list.map(function.inputs, fn(port) { port.contract.type_ref }),
          list.append(
            list.map(function.resource_inputs, fn(requirement) {
              requirement.token_type
            }),
            list.flat_map(function.outcomes, fn(outcome) {
              list.append(
                list.map(outcome.value_ports, fn(port) {
                  port.contract.type_ref
                }),
                list.map(outcome.produced_resources, fn(production) {
                  production.token_type
                }),
              )
            }),
          ),
        ),
      )
    },
  )
}

fn graph_projection(wire: json.JsonValue) -> Result(json.JsonValue, Failure) {
  use profile <- result.try(field(wire, "profile"))
  use nodes <- result.try(
    items(wire, "nodes") |> result.try(fn(items) { sort_by(items, id_key) }),
  )
  use definitions <- result.try(
    items(wire, "definitions")
    |> result.try(fn(items) { sort_by(items, id_key) }),
  )
  use definitions <- result.try(list.try_map(definitions, graph_definition))
  Ok(
    json.JsonValueObj([
      #("profile", profile),
      #("nodes", json.JsonValueArr(nodes)),
      #("definitions", json.JsonValueArr(definitions)),
    ]),
  )
}

fn graph_digest(wire: json.JsonValue) -> Result(String, Failure) {
  result.try(graph_projection(wire), hash)
}

pub fn start_generation(
  checked: CheckedGeneration,
  arguments: List(#(composition_plan.InputId, types.SlotValue(json.JsonValue))),
  providers: List(runtime.Provider),
  state: network.NetworkState,
) -> Option(Result(runtime.Progress, runtime.RunFailure)) {
  case checked.composition {
    None -> None
    Some(checked_composition) ->
      Some(runtime.start_composition(
        checked_composition,
        providers,
        arguments,
        state,
      ))
  }
}

pub fn checked_outcomes(
  checked: CheckedGeneration,
  function: composition_plan.FunctionRef,
) -> List(OutcomeContract) {
  result.unwrap(list.key_find(checked.outcome_causes, function), [])
}

pub fn is_external_failure(
  checked: CheckedGeneration,
  function: composition_plan.FunctionRef,
  outcome: composition_plan.OutcomeId,
) -> Bool {
  list.any(checked_outcomes(checked, function), fn(value) {
    value.contract.id == outcome
    && case value.cause {
      ExternalCondition(_) -> True
      _ -> False
    }
  })
}

pub fn completed_valid(
  outcomes: List(#(composition_plan.FunctionRef, List(OutcomeContract))),
  function: composition_plan.FunctionRef,
  outcome: OutcomeContract,
) -> Bool {
  list.contains(result.unwrap(list.key_find(outcomes, function), []), outcome)
  && outcome.contract.form == composition_plan.DeclaredFailure
  && case outcome.cause {
    ExternalCondition(_) -> True
    _ -> False
  }
}

fn operation_outcomes(
  library: AdmittedLibrary,
  definition_id: String,
) -> Result(List(OutcomeContract), Failure) {
  use definition <- result.try(
    result.map_error(
      list.find(library.definitions, fn(value) { value.id == definition_id }),
      fn(_) { syntax("unresolved operation") },
    ),
  )
  case definition.shape {
    Operation(operation) -> Ok(operation.outcomes)
    _ -> fail("definition is not an operation")
  }
}

fn unique(values: List(String), kind: String) -> Result(Nil, Failure) {
  require(
    list.all(values, fn(value) { value != "" })
      && list.length(values) == list.length(list.unique(values)),
    "duplicate or empty " <> kind,
  )
}

fn validate_declared_outcome(
  library: AdmittedLibrary,
  outcomes: List(OutcomeContract),
  output: runtime.OutcomeValues,
) -> Result(Nil, Failure) {
  use outcome <- result.try(
    result.map_error(
      list.find(outcomes, fn(value) { value.contract.id == output.outcome }),
      fn(_) { syntax("undeclared outcome") },
    ),
  )
  use _ <- result.try(unique(
    list.map(output.values, fn(port) { port.0.value }),
    "outcome value",
  ))
  use _ <- result.try(require(
    list.length(output.values) == list.length(outcome.contract.value_ports),
    "exact outcome port coverage",
  ))
  use _ <- result.try(
    list.try_map(outcome.contract.value_ports, fn(port) {
      use value <- result.try(
        result.map_error(list.key_find(output.values, port.id), fn(_) {
          syntax("missing outcome port")
        }),
      )
      result.map_error(
        runtime.validate_slot(library.prepared, port.contract, value),
        Codec,
      )
    }),
  )
  Ok(Nil)
}

pub fn validate_outcome(
  library: AdmittedLibrary,
  definition: String,
  output: runtime.OutcomeValues,
) -> Result(Nil, Failure) {
  use outcomes <- result.try(operation_outcomes(library, definition))
  validate_declared_outcome(library, outcomes, output)
}

fn encode_outcome_value(
  output: runtime.OutcomeValues,
) -> Result(String, Failure) {
  use ports <- result.try(
    list.try_map(output.values, fn(port) {
      use value <- result.try(result.map_error(
        decode.encode_slot_value(port.1),
        Wire,
      ))
      Ok(
        json.JsonValueObj([
          #("id", json.JsonValueStr(port.0.value)),
          #("value", value),
        ]),
      )
    }),
  )
  canonical(
    json.JsonValueObj([
      #("id", json.JsonValueStr(output.outcome.value)),
      #("values", json.JsonValueArr(ports)),
    ]),
  )
}

pub fn encode_outcome(
  library: AdmittedLibrary,
  definition: String,
  output: runtime.OutcomeValues,
) -> Result(String, Failure) {
  use _ <- result.try(validate_outcome(library, definition, output))
  encode_outcome_value(output)
}

fn decode_outcome_value(
  wire: String,
) -> Result(runtime.OutcomeValues, Failure) {
  use value <- result.try(result.map_error(values.parse_wire(wire), Json))
  use _ <- result.try(object(value, ["id", "values"]))
  use id <- result.try(get(value, "id", identifier))
  use ports <- result.try(
    get(value, "values", fn(value) {
      array(value, fn(value) {
        use _ <- result.try(object(value, ["id", "value"]))
        use id <- result.try(get(value, "id", identifier))
        use value <- result.try(
          get(value, "value", fn(value) { old(value, decode.decode_slot_value) }),
        )
        Ok(#(composition_plan.PortId(id), value))
      })
    }),
  )
  Ok(runtime.OutcomeValues(composition_plan.OutcomeId(id), ports))
}

pub fn decode_outcome(
  library: AdmittedLibrary,
  definition: String,
  wire: String,
) -> Result(runtime.OutcomeValues, Failure) {
  use output <- result.try(decode_outcome_value(wire))
  use _ <- result.try(validate_outcome(library, definition, output))
  Ok(output)
}

fn same_inputs(
  a: List(composition_plan.InputPort),
  b: List(composition_plan.InputPort),
) -> Bool {
  case a, b {
    [], [] -> True
    [a, ..rest_a], [b, ..rest_b] ->
      a.id == b.id && a.contract == b.contract && same_inputs(rest_a, rest_b)
    _, _ -> False
  }
}

fn definition_token_type(library: AdmittedLibrary) -> fn(String) -> String {
  let graph_nodes = library_graph(library).nodes
  fn(value) {
    case
      list.find(graph_nodes, fn(node) {
        node.reference.definition_name == value
      })
    {
      Ok(node) -> composition_plan.type_identity(node.reference)
      Error(Nil) -> value
    }
  }
}
