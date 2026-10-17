// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import necoherence/exact_json as json
import necoherence/network_effect as network
import necoherence/semantic_composition as composition
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
  Invalid(condition: String)
  Profile(failure: types.ProfileFailure)
  Meaning(obligations: List(types.SemanticObligation))
  CompositionInput(composition.CompositionInputFailure)
  Witness(composition.WitnessFailure)
}

pub type SourceIdentity =
  types.SourceIdentity

pub type Origin =
  types.Origin

pub type Target {
  Library
  Group(id: String)
  Definition(id: String)
  Type(id: String)
  Outcome(definition: String, outcome: String)
}

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
  OutcomeContract(contract: composition.OutcomeContract, cause: OutcomeCause)
}

pub type OperationContract {
  OperationContract(
    effect: types.EffectPoint,
    inputs: List(composition.InputPort),
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
    graph: types.SemanticGraph,
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
    composition: Option(composition.CheckedComposition),
    outcome_causes: List(#(composition.FunctionRef, List(OutcomeContract))),
  )
}

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
    entrypoints_sha256: String,
  )
}

pub type GenerationDifference {
  SignatureSchemaDifference(required: String, observed: String)
  LibraryIdentityDifference(required: String, observed: String)
  LibraryRevisionDifference(required: String, observed: String)
  ProfileDifference(required: types.ProfileRef, observed: types.ProfileRef)
  GraphSha256Difference(required: String, observed: String)
  ProvenanceSha256Difference(required: String, observed: String)
  MetadataSha256Difference(required: String, observed: String)
  ProblemSha256Difference(required: Option(String), observed: Option(String))
  EntrypointsSha256Difference(required: String, observed: String)
}

pub type GenerationMismatch {
  GenerationMismatch(differences: List(GenerationDifference))
}

pub type LibraryPredicate {
  Lb01
  Lb02
  Lb03
  Lb04
  Lb05
  Lb06
  Lb07
  Lb08
  Lb09
  Lb10
  Lb11
  Lb12
  Lb13
  Lb14
  Lb15
  Lb16
  Lb17
  Lb18
  Lb19
}

pub type LibraryFailure {
  LibraryFailure(
    reference: String,
    predicate: LibraryPredicate,
    location: List(String),
  )
}

pub type LibraryCheckFailure {
  ProfileCheck(failure: types.ProfileFailure)
  LibraryCheck(failure: LibraryFailure)
}

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
  CheckedLibrary(library: TypeSignatureLibrary, profile: types.CheckedProfile)
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
  predicate: LibraryPredicate,
) -> Result(CheckedLibrary, LibraryCheckFailure) {
  Error(LibraryCheck(LibraryFailure(library.identity, predicate, ["library"])))
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
    Library -> True
    Group(id) -> list.any(library.groups, fn(group) { group.id == id })
    Definition(id) ->
      list.any(library.definitions, fn(definition) { definition.id == id })
    Type(id) -> list.any(library.nodes, fn(node) { node.id == id })
    Outcome(id, outcome_name) ->
      list.any(library.definitions, fn(definition) {
        definition.id == id
        && case definition.shape {
          Operation(operation) ->
            list.any(operation.outcomes, fn(outcome) {
              let composition.OutcomeId(name) = outcome.contract.id
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
  let source_valid = case outcome.cause {
    ValueContract(origin) -> origin_valid(library, origin)
    ExternalCondition(specification) ->
      origin_valid(library, specification)
      && !list.is_empty(outcome.contract.value_ports)
      && outcome.contract.form == composition.DeclaredFailure
  }
  source_valid
  && list.all(outcome.contract.produced_resources, fn(production) {
    production.revision >= 0 && production.quantity >= 0
  })
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
        !list.is_empty(operation.outcomes)
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

fn integer_value_invalid(
  profile: types.SemanticProfile,
  spec: types.IntegerSpec,
  value: Int,
) -> Bool {
  let domain_name = option.unwrap(spec.domain, profile.default_integer_domain)
  case
    list.find(profile.integer_domains, fn(binding) {
      binding.name == domain_name
    })
  {
    Error(_) -> True
    Ok(binding) -> {
      let domain_accepts = case binding.range {
        types.Unbounded -> True
        types.IntegerInterval(minimum, maximum) ->
          value >= minimum && value <= maximum
      }
      !list.contains(binding.forms, types.Number)
      || !domain_accepts
      || option.unwrap(
        option.map(spec.const_value, fn(expected) { expected != value }),
        False,
      )
      || option.unwrap(
        option.map(spec.enum_values, fn(values) {
          !list.contains(values, value)
        }),
        False,
      )
      || option.unwrap(
        option.map(spec.minimum, fn(minimum) { value < minimum }),
        False,
      )
      || option.unwrap(
        option.map(spec.maximum, fn(maximum) { value > maximum }),
        False,
      )
    }
  }
}

fn length_in_unit(
  profile: types.SemanticProfile,
  unit: types.StringLengthUnit,
  value: String,
) -> Option(Int) {
  case unit {
    types.Utf8Bytes -> Some(string.byte_size(value))
    types.UnicodeScalars -> Some(list.length(string.to_utf_codepoints(value)))
    types.Graphemes ->
      option.map(profile.grapheme_rules, fn(rules) {
        validation.grapheme_count(rules, value)
      })
  }
}

fn string_value_invalid(
  profile: types.SemanticProfile,
  spec: types.StringSpec,
  value: String,
) -> Bool {
  option.unwrap(
    option.map(spec.const_value, fn(expected) { expected != value }),
    False,
  )
  || option.unwrap(
    option.map(spec.enum_values, fn(values) { !list.contains(values, value) }),
    False,
  )
  || list.any(spec.lengths, fn(bound) {
    case length_in_unit(profile, bound.unit, value) {
      None -> True
      Some(length) ->
        option.unwrap(
          option.map(bound.minimum, fn(minimum) { length < minimum }),
          False,
        )
        || option.unwrap(
          option.map(bound.maximum, fn(maximum) { length > maximum }),
          False,
        )
    }
  })
  || option.unwrap(
    option.map(spec.format, fn(format_use) {
      case format_rule(profile, format_use) {
        None -> False
        Some(rule) -> !validation.recognizes(rule, value)
      }
    }),
    False,
  )
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
                      string_value_invalid(
                        library.profile,
                        spec,
                        branch.wire_tag,
                      )
                    _ -> True
                  }
                None -> True
              }
          }
        _ -> False
      }
    None -> True
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
) -> Option(LibraryPredicate) {
  let wrapper_keys =
    list.map(library.profile.wrappers, fn(wrapper) { wrapper.key })
  let invalid_declaration = !library_declaration_valid(library)
  let checks = [
    #(invalid_declaration, Lb01),
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
      Lb02,
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
      Lb03,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape {
          TaggedUnionShape(spec) ->
            !unique_nonempty_ids(
              list.map(spec.branches, fn(branch) { branch.wire_tag }),
            )
          _ -> False
        }
      }),
      Lb04,
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
      Lb05,
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
      Lb06,
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
                      !validation.recognizes(binding.rule, branch.wire_tag)
                    Error(_) -> True
                  }
                }),
                False,
              )
            })
          _, _ -> False
        }
      }),
      Lb07,
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
      Lb08,
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
      Lb09,
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
                  })
                })
            }
          SealedShape(_, _), None -> True
          _, _ -> False
        }
      }),
      Lb10,
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
      Lb11,
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
      Lb12,
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
                option.is_none(format_rule(library.profile, format_use))
              }),
              False,
            )
            || list.any(spec.lengths, fn(bound) {
              !bounds_valid(bound.minimum, bound.maximum)
            })
          _ -> False
        }
      }),
      Lb13,
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
      Lb14,
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
      Lb15,
    ),
    #(
      list.any(library.nodes, fn(node) {
        case node.shape {
          ArrayShape(spec) -> !bounds_valid(spec.minimum, spec.maximum)
          BytesShape(spec) -> !bounds_valid(spec.minimum, spec.maximum)
          _ -> False
        }
      }),
      Lb16,
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
      Lb17,
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
      Lb18,
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
              string_value_invalid(library.profile, spec, value)
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
              integer_value_invalid(library.profile, spec, value)
            })
          }
          _ -> False
        }
      }),
      Lb19,
    ),
  ]
  case list.find(checks, fn(check) { check.0 }) {
    Ok(check) -> Some(check.1)
    Error(_) -> None
  }
}

pub fn check_library(
  library: TypeSignatureLibrary,
) -> Result(CheckedLibrary, LibraryCheckFailure) {
  use profile <- result.try(
    validation.check_profile(library.profile)
    |> result.map_error(ProfileCheck),
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
  checked.library.graph
}

pub fn library_graph(library: AdmittedLibrary) -> types.SemanticGraph {
  library.graph
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
) -> Option(composition.CheckedComposition) {
  checked.composition
}

pub fn encode_library(library: AdmittedLibrary) -> Result(String, Failure) {
  canonical(library.wire)
}

pub fn encode_checked(checked: CheckedGeneration) -> Result(String, Failure) {
  canonical(checked.wire)
}

pub fn encode_basis(checked: CheckedGeneration) -> Result(String, Failure) {
  canonical(generation_identity_wire(checked.basis))
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
    identity.entrypoints_sha256,
  )
}

pub fn require_generation(
  required: GenerationRequirement,
  checked: CheckedGeneration,
) -> Result(CheckedGeneration, GenerationMismatch) {
  let observed = generation_requirement(checked)
  let differences =
    list.flatten([
      case required.signature_schema == observed.signature_schema {
        True -> []
        False -> [
          SignatureSchemaDifference(
            required.signature_schema,
            observed.signature_schema,
          ),
        ]
      },
      case required.library_identity == observed.library_identity {
        True -> []
        False -> [
          LibraryIdentityDifference(
            required.library_identity,
            observed.library_identity,
          ),
        ]
      },
      case required.library_revision == observed.library_revision {
        True -> []
        False -> [
          LibraryRevisionDifference(
            required.library_revision,
            observed.library_revision,
          ),
        ]
      },
      case required.profile == observed.profile {
        True -> []
        False -> [ProfileDifference(required.profile, observed.profile)]
      },
      case required.graph_sha256 == observed.graph_sha256 {
        True -> []
        False -> [
          GraphSha256Difference(required.graph_sha256, observed.graph_sha256),
        ]
      },
      case required.provenance_sha256 == observed.provenance_sha256 {
        True -> []
        False -> [
          ProvenanceSha256Difference(
            required.provenance_sha256,
            observed.provenance_sha256,
          ),
        ]
      },
      case required.metadata_sha256 == observed.metadata_sha256 {
        True -> []
        False -> [
          MetadataSha256Difference(
            required.metadata_sha256,
            observed.metadata_sha256,
          ),
        ]
      },
      case required.problem_sha256 == observed.problem_sha256 {
        True -> []
        False -> [
          ProblemSha256Difference(
            required.problem_sha256,
            observed.problem_sha256,
          ),
        ]
      },
      case required.entrypoints_sha256 == observed.entrypoints_sha256 {
        True -> []
        False -> [
          EntrypointsSha256Difference(
            required.entrypoints_sha256,
            observed.entrypoints_sha256,
          ),
        ]
      },
    ])
  case differences {
    [] -> Ok(checked)
    differences -> Error(GenerationMismatch(differences))
  }
}

fn require(condition: Bool, message: String) -> Result(Nil, Failure) {
  case condition {
    True -> Ok(Nil)
    False -> Error(Invalid(message))
  }
}

fn fail(message: String) -> Result(a, Failure) {
  Error(Invalid(message))
}

pub fn object(
  value: json.JsonValue,
  keys: List(String),
) -> Result(List(#(String, json.JsonValue)), Failure) {
  case value {
    json.JsonValueObj(members) -> {
      let names = list.map(members, fn(member) { member.0 })
      case list.find(names, fn(name) { !list.contains(keys, name) }) {
        Ok(name) -> Error(Wire(decode.UnknownField([], name)))
        Error(_) ->
          case list.find(keys, fn(key) { !list.contains(names, key) }) {
            Ok(key) -> Error(Wire(decode.UnknownField([], key)))
            Error(_) -> Ok(members)
          }
      }
    }
    _ -> fail("object required")
  }
}

pub fn field(
  value: json.JsonValue,
  key: String,
) -> Result(json.JsonValue, Failure) {
  case value {
    json.JsonValueObj(members) ->
      result.map_error(list.key_find(members, key), fn(_) {
        Invalid("missing field: " <> key)
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
    json.JsonValueArr(items) -> list.try_map(items, f)
    _ -> fail("array required")
  }
}

fn get(
  value: json.JsonValue,
  key: String,
  f: fn(json.JsonValue) -> Result(a, Failure),
) -> Result(a, Failure) {
  use value <- result.try(field(value, key))
  f(value)
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
      Invalid("canonical integer required")
    }),
  )
  use _ <- result.try(require(
    int.to_string(parsed) == value,
    "canonical integer",
  ))
  Ok(parsed)
}

fn tag(value: json.JsonValue) -> Result(String, Failure) {
  get(value, "tag", text)
}

fn decode_decimal_bound(
  value: json.JsonValue,
) -> Result(types.DecimalBound, Failure) {
  use _ <- result.try(object(value, ["mantissa", "scale", "exclusive"]))
  use mantissa <- result.try(get(value, "mantissa", canonical_int))
  use scale <- result.try(get(value, "scale", canonical_int))
  use exclusive <- result.try(
    get(value, "exclusive", fn(value) {
      case value {
        json.JsonValueBool(value) -> Ok(value)
        _ -> fail("boolean required")
      }
    }),
  )
  Ok(types.DecimalBound(mantissa, scale, exclusive))
}

fn decode_decimal_spec(
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
  use _ <- result.try(object(value, ["tag"]))
  case tag(value) {
    Ok("Null") -> Ok(types.NullKind)
    Ok("Boolean") -> Ok(types.BooleanKind)
    Ok("Number") -> Ok(types.NumberKind)
    Ok("String") -> Ok(types.StringKind)
    Ok("Array") -> Ok(types.ArrayKind)
    Ok("Object") -> Ok(types.ObjectKind)
    Ok(_) -> fail("unknown ValueKind tag")
    Error(error) -> Error(error)
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
      result.map(get(value, "value", text), types.FormatMember)
    }
    _ -> fail("unknown MemberTest tag")
  }
}

fn decode_branch_selector(
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
      use tests <- result.try(
        get(value, "value", fn(value) {
          array(value, fn(value) {
            use _ <- result.try(object(value, ["key", "test"]))
            use key <- result.try(get(value, "key", text))
            use member_test <- result.try(get(value, "test", decode_member_test))
            Ok(#(key, member_test))
          })
        }),
      )
      Ok(types.MemberShape(tests))
    }
    "Kind" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      result.map(get(value, "value", decode_value_kind), types.Kind)
    }
    "Otherwise" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(types.Otherwise)
    }
    _ -> fail("unknown BranchSelector tag")
  }
}

fn decode_signature_slot(
  value: json.JsonValue,
) -> Result(SignatureSlot, Failure) {
  use _ <- result.try(object(value, ["type_id", "required", "nullable"]))
  use type_id <- result.try(get(value, "type_id", text))
  use required <- result.try(
    get(value, "required", fn(value) {
      case value {
        json.JsonValueBool(value) -> Ok(value)
        _ -> fail("boolean required")
      }
    }),
  )
  use nullable <- result.try(
    get(value, "nullable", fn(value) {
      case value {
        json.JsonValueBool(value) -> Ok(value)
        _ -> fail("boolean required")
      }
    }),
  )
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
  use nullable <- result.try(
    get(value, "nullable", fn(value) {
      case value {
        json.JsonValueBool(value) -> Ok(value)
        _ -> fail("boolean required")
      }
    }),
  )
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
      use _ <- result.try(object(value, ["tag", "fields"]))
      use fields <- result.try(
        get(value, "fields", fn(value) {
          use _ <- result.try(object(value, ["key_format", "value"]))
          Ok(value)
        }),
      )
      use key_format <- result.try(
        get(fields, "key_format", fn(value) {
          optional(value, fn(value) { old(value, decode.decode_format_use) })
        }),
      )
      use contract <- result.try(get(fields, "value", decode_library_element))
      Ok(LibraryAllowExtras(key_format, contract))
    }
    _ -> fail("unknown ExtraMembers tag")
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
    get(value, "min_length", fn(value) { optional(value, canonical_int) }),
  )
  use maximum <- result.try(
    get(value, "max_length", fn(value) { optional(value, canonical_int) }),
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
  use _ <- result.try(object(value, ["tag"]))
  case tag(value) {
    Ok("Any") -> Ok(types.AnyValue)
    Ok("OrdinaryObject") -> Ok(types.OrdinaryObject)
    Ok(_) -> fail("unknown UnknownKind tag")
    Error(error) -> Error(error)
  }
}

fn decode_payload(
  value: json.JsonValue,
  decoder: fn(json.JsonValue) -> Result(a, Failure),
) -> Result(a, Failure) {
  use _ <- result.try(object(value, ["tag", "value"]))
  get(value, "value", decoder)
}

pub fn decode_library_shape(
  value: json.JsonValue,
) -> Result(LibraryShape, Failure) {
  use tag <- result.try(tag(value))
  let fields = fn(keys) {
    use _ <- result.try(object(value, ["tag", "fields"]))
    use fields <- result.try(get(value, "fields", fn(value) { Ok(value) }))
    use _ <- result.try(object(fields, keys))
    Ok(fields)
  }
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
      use row <- result.try(fields(["tag", "refinements"]))
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
      use row <- result.try(fields(["target"]))
      result.map(get(row, "target", text), AliasShape)
    }
    "RawBody" -> {
      use row <- result.try(fields(["encoding"]))
      result.map(get(row, "encoding", text), RawBodyShape)
    }
    "Opaque" -> {
      use row <- result.try(fields(["type_name"]))
      result.map(get(row, "type_name", text), OpaqueShape)
    }
    _ -> fail("unknown Shape tag")
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

fn unique(values: List(String), kind: String) -> Result(Nil, Failure) {
  require(
    list.all(values, fn(value) { value != "" })
      && set.size(set.from_list(values)) == list.length(values),
    "duplicate or empty " <> kind,
  )
}

fn valid_source_digest(value: String) -> Bool {
  string.byte_size(value) == 64
  && list.all(string.to_graphemes(value), fn(char) {
    string.contains("0123456789abcdef", char)
  })
}

fn source(value: json.JsonValue) -> Result(SourceIdentity, Failure) {
  use _ <- result.try(
    object(value, ["repository", "revision", "path", "content_digest"]),
  )
  use repository <- result.try(get(value, "repository", identifier))
  use revision <- result.try(get(value, "revision", identifier))
  use path <- result.try(get(value, "path", identifier))
  use digest <- result.try(get(value, "content_digest", text))
  use _ <- result.try(require(valid_source_digest(digest), "source digest"))
  Ok(types.SourceIdentity(repository, revision, path, digest))
}

fn origin(
  value: json.JsonValue,
  sources: List(SourceIdentity),
) -> Result(Origin, Failure) {
  use _ <- result.try(object(value, ["source", "locator"]))
  use source <- result.try(get(value, "source", source))
  use _ <- result.try(require(
    list.contains(sources, source),
    "unresolved origin source",
  ))
  use locator <- result.try(
    get(value, "locator", fn(value) { array(value, text) }),
  )
  Ok(types.Origin(source, locator))
}

fn type_source() -> types.SourceRef {
  types.SourceRef("ncoh-type-signatures", "1", "", "", "", None)
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
  reference(type_source(), id)
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
      fn(_) { Invalid("unresolved definition") },
    ),
  )
  Ok(types.DefinitionRef(type_source(), id))
}

fn slot(
  value: json.JsonValue,
  source: types.SourceRef,
) -> Result(types.SlotContract, Failure) {
  use _ <- result.try(object(value, ["type_id", "required", "nullable"]))
  use id <- result.try(get(value, "type_id", identifier))
  use required <- result.try(
    get(value, "required", fn(value) {
      case value {
        json.JsonValueBool(value) -> Ok(value)
        _ -> fail("boolean required")
      }
    }),
  )
  use nullable <- result.try(
    get(value, "nullable", fn(value) {
      case value {
        json.JsonValueBool(value) -> Ok(value)
        _ -> fail("boolean required")
      }
    }),
  )
  Ok(types.SlotContract(reference(source, id), required, nullable))
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

fn old_reference_wire(
  reference: types.TypeRef,
) -> Result(json.JsonValue, Failure) {
  result.map_error(decode.encode_type_ref(reference), Wire)
}

fn input_port(
  value: json.JsonValue,
  source: types.SourceRef,
) -> Result(composition.InputPort, Failure) {
  use _ <- result.try(object(value, ["id", "contract"]))
  use id <- result.try(get(value, "id", identifier))
  use contract <- result.try(
    get(value, "contract", fn(value) { slot(value, source) }),
  )
  Ok(composition.InputPort(
    composition.PortId(id),
    contract,
    composition.AnyCompatible,
    None,
  ))
}

fn output_port(
  value: json.JsonValue,
  source: types.SourceRef,
) -> Result(composition.OutputPort, Failure) {
  use _ <- result.try(object(value, ["id", "contract"]))
  use id <- result.try(get(value, "id", identifier))
  use contract <- result.try(
    get(value, "contract", fn(value) { slot(value, source) }),
  )
  Ok(composition.OutputPort(composition.PortId(id), contract, None))
}

fn cause(
  value: json.JsonValue,
  sources: List(SourceIdentity),
) -> Result(OutcomeCause, Failure) {
  use _ <- result.try(object(value, ["tag", "fields"]))
  use tag <- result.try(get(value, "tag", text))
  use payload <- result.try(field(value, "fields"))
  case tag {
    "ValueContract" -> {
      use _ <- result.try(object(payload, ["origin"]))
      get(payload, "origin", fn(value) { origin(value, sources) })
      |> result.map(ValueContract)
    }
    "ExternalCondition" -> {
      use _ <- result.try(object(payload, ["specification"]))
      get(payload, "specification", fn(value) { origin(value, sources) })
      |> result.map(ExternalCondition)
    }
    _ -> fail("outcome cause")
  }
}

fn production_text(
  value: json.JsonValue,
  field: String,
) -> Result(String, Failure) {
  case value {
    json.JsonValueStr(text) -> Ok(text)
    _ -> Error(Wire(decode.DecodeFailure([field], "string required")))
  }
}

fn production_natural(
  value: json.JsonValue,
  field: String,
) -> Result(Int, Failure) {
  let fail = fn(reason) { Error(Wire(decode.DecodeFailure([field], reason))) }
  case value {
    json.JsonValueStr(text) ->
      case int.parse(text) {
        Ok(number) ->
          case int.to_string(number) == text && number >= 0 {
            True -> Ok(number)
            False -> fail("canonical decimal integer")
          }
        Error(_) -> fail("decimal integer required")
      }
    _ -> fail("integer must be a decimal string")
  }
}

fn production(
  value: json.JsonValue,
  source: types.SourceRef,
) -> Result(composition.ResourceProduction, Failure) {
  use _ <- result.try(
    object(value, ["id", "token_type", "revision", "quantity", "provenance"]),
  )
  use type_id <- result.try(get(value, "token_type", identifier))
  use id <- result.try(
    get(value, "id", fn(value) { production_text(value, "id") }),
  )
  use revision <- result.try(
    get(value, "revision", fn(value) { production_natural(value, "revision") }),
  )
  use quantity <- result.try(
    get(value, "quantity", fn(value) { production_natural(value, "quantity") }),
  )
  use provenance <- result.try(
    get(value, "provenance", fn(value) { production_text(value, "provenance") }),
  )
  Ok(composition.ResourceProduction(
    composition.ProductionId(id),
    reference(source, type_id),
    revision,
    quantity,
    provenance,
  ))
}

fn outcome(
  value: json.JsonValue,
  source: types.SourceRef,
  sources: List(SourceIdentity),
) -> Result(OutcomeContract, Failure) {
  use _ <- result.try(
    object(value, ["id", "form", "cause", "value_ports", "produced_resources"]),
  )
  use id <- result.try(get(value, "id", identifier))
  use form <- result.try(
    get(value, "form", fn(value) { old(value, decode.decode_outcome_form) }),
  )
  use cause <- result.try(
    get(value, "cause", fn(value) { cause(value, sources) }),
  )
  use ports <- result.try(
    get(value, "value_ports", fn(value) {
      array(value, fn(value) { output_port(value, source) })
    }),
  )
  use _ <- result.try(unique(
    list.map(ports, fn(port) { port.id.value }),
    "output port",
  ))
  use resources <- result.try(
    get(value, "produced_resources", fn(value) {
      array(value, fn(value) { production(value, source) })
    }),
  )
  use _ <- result.try(unique(
    list.map(resources, fn(resource) { resource.id.value }),
    "produced resource",
  ))
  use _ <- result.try(require(
    list.all(resources, fn(resource) {
      resource.revision >= 0
      && resource.quantity >= 0
      && resource.provenance != ""
    }),
    "resource revision/quantity/provenance",
  ))
  use _ <- result.try(require(
    case cause {
      ExternalCondition(_) -> form == composition.DeclaredFailure && ports != []
      ValueContract(_) -> True
    },
    "external condition requires a typed declared failure",
  ))
  Ok(OutcomeContract(
    composition.OutcomeContract(
      composition.OutcomeId(id),
      form,
      ports,
      resources,
    ),
    cause,
  ))
}

fn definition(
  value: json.JsonValue,
  source: types.SourceRef,
  sources: List(SourceIdentity),
) -> Result(SignatureDefinition, Failure) {
  use _ <- result.try(object(value, ["id", "wire_identity", "shape"]))
  use id <- result.try(get(value, "id", identifier))
  use wire_identity <- result.try(get(value, "wire_identity", identifier))
  use shape <- result.try(
    get(value, "shape", fn(value) {
      use tag <- result.try(get(value, "tag", text))
      use _ <- result.try(object(value, ["tag", "value"]))
      use payload <- result.try(field(value, "value"))
      case tag {
        "Value" -> result.map(identifier(payload), Value)
        "Symbol" -> result.map(identifier(payload), Symbol)
        "Message" -> result.map(identifier(payload), Message)
        "Operation" -> {
          use _ <- result.try(object(payload, ["effect", "inputs", "outcomes"]))
          use effect <- result.try(
            get(payload, "effect", fn(value) {
              old(value, decode.decode_effect_point)
            }),
          )
          use inputs <- result.try(
            get(payload, "inputs", fn(value) {
              array(value, fn(value) { input_port(value, source) })
            }),
          )
          use outcomes <- result.try(
            get(payload, "outcomes", fn(value) {
              array(value, fn(value) { outcome(value, source, sources) })
            }),
          )
          use _ <- result.try(unique(
            list.map(inputs, fn(port) { port.id.value }),
            "input port",
          ))
          use _ <- result.try(unique(
            list.map(outcomes, fn(outcome) { outcome.contract.id.value }),
            "outcome",
          ))
          use _ <- result.try(require(
            outcomes != []
              && list.any(outcomes, fn(outcome) {
              outcome.contract.form == composition.Success
            }),
            "operation success required",
          ))
          Ok(Operation(OperationContract(effect, inputs, outcomes)))
        }
        _ -> fail("definition shape")
      }
    }),
  )
  Ok(SignatureDefinition(id, wire_identity, shape))
}

fn target(
  value: json.JsonValue,
  definitions: List(SignatureDefinition),
  nodes: List(types.TypeNode),
  groups: List(DefinitionGroup),
) -> Result(Target, Failure) {
  use tag <- result.try(get(value, "tag", text))
  case tag {
    "Library" -> {
      use _ <- result.try(object(value, ["tag"]))
      Ok(Library)
    }
    "Group" | "Definition" | "Type" -> {
      use _ <- result.try(object(value, ["tag", "value"]))
      use id <- result.try(get(value, "value", identifier))
      case tag {
        "Group" -> {
          use _ <- result.try(require(
            list.any(groups, fn(group) { group.id == id }),
            "unresolved annotation group",
          ))
          Ok(Group(id))
        }
        "Definition" -> {
          use _ <- result.try(require(
            list.any(definitions, fn(definition) { definition.id == id }),
            "unresolved annotation definition",
          ))
          Ok(Definition(id))
        }
        _ -> {
          use _ <- result.try(require(
            list.any(nodes, fn(node) { node.reference.definition_name == id }),
            "unresolved annotation type",
          ))
          Ok(Type(id))
        }
      }
    }
    "Outcome" -> {
      use _ <- result.try(object(value, ["tag", "fields"]))
      use payload <- result.try(field(value, "fields"))
      use _ <- result.try(object(payload, ["definition", "outcome"]))
      use definition <- result.try(get(payload, "definition", identifier))
      use outcome <- result.try(get(payload, "outcome", identifier))
      use _ <- result.try(require(
        list.any(definitions, fn(value) {
          value.id == definition
          && case value.shape {
            Operation(contract) ->
              list.any(contract.outcomes, fn(value) {
                value.contract.id.value == outcome
              })
            _ -> False
          }
        }),
        "unresolved annotation outcome",
      ))
      Ok(Outcome(definition, outcome))
    }
    _ -> fail("annotation target")
  }
}

fn roots(
  definition: SignatureDefinition,
  source: types.SourceRef,
) -> List(types.TypeRef) {
  case definition.shape {
    Value(id) | Message(id) -> [reference(source, id)]
    Symbol(_) -> []
    Operation(contract) ->
      list.append(
        list.map(contract.inputs, fn(port) { port.contract.type_ref }),
        list.flat_map(contract.outcomes, fn(outcome) {
          list.append(
            list.map(outcome.contract.value_ports, fn(port) {
              port.contract.type_ref
            }),
            list.map(outcome.contract.produced_resources, fn(resource) {
              resource.token_type
            }),
          )
        }),
      )
  }
}

fn range(min: Option(Int), max: Option(Int)) -> Bool {
  case min, max {
    Some(a), Some(b) -> a >= 0 && b >= a
    Some(a), None -> a >= 0
    None, Some(b) -> b >= 0
    _, _ -> True
  }
}

fn integer_range(min: Option(Int), max: Option(Int)) -> Bool {
  case min, max {
    Some(a), Some(b) -> a <= b
    _, _ -> True
  }
}

fn shape_children(shape: types.TypeShape) -> List(types.TypeRef) {
  case shape {
    types.ProductShape(spec) -> {
      let fields = list.map(spec.fields, fn(field) { field.slot.type_ref })
      case spec.extras {
        types.RejectExtras -> fields
        types.AllowExtras(_, value) -> [value.type_ref, ..fields]
      }
    }
    types.ArrayShape(spec) -> [spec.item.type_ref]
    types.AliasShape(target, _) -> [target]
    types.TaggedUnionShape(spec) ->
      list.map(spec.branches, fn(branch) { branch.target })
    _ -> []
  }
}

fn shape_default(shape: types.TypeShape) -> Option(json.JsonValue) {
  case shape {
    types.BooleanShape(spec) ->
      option.map(spec.default_value, json.JsonValueBool)
    types.IntegerShape(spec) ->
      option.map(spec.default_value, json.JsonValueNum)
    types.StringShape(spec) -> option.map(spec.default_value, json.JsonValueStr)
    _ -> None
  }
}

fn check_node(
  graph: types.SemanticGraph,
  node: types.TypeNode,
) -> Result(Nil, Failure) {
  use _ <- result.try(require(
    list.all(shape_children(node.shape), fn(reference) {
      list.any(graph.nodes, fn(candidate) { candidate.reference == reference })
    }),
    "unresolved type reference",
  ))
  use _ <- result.try(require(
    case node.shape {
      types.IntegerShape(spec) -> integer_range(spec.minimum, spec.maximum)
      types.ArrayShape(spec) -> range(spec.min_length, spec.max_length)
      types.BytesShape(spec) -> range(spec.minimum, spec.maximum)
      _ -> True
    },
    "invalid value constraint",
  ))
  case shape_default(node.shape) {
    None -> Ok(Nil)
    Some(value) ->
      require(
        validation.accepts_value(graph, node.reference, value),
        "default outside value domain",
      )
  }
}

pub fn decode_library(wire: String) -> Result(AdmittedLibrary, Failure) {
  use value <- result.try(result.map_error(values.parse_wire(wire), Json))
  decode_library_value(value)
}

pub fn decode_library_value(
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
  use _ <- result.try(require(
    schema == "ncoh-type-signatures@1",
    "signature schema",
  ))
  use identity <- result.try(get(value, "identity", identifier))
  use revision <- result.try(get(value, "revision", identifier))
  use sources <- result.try(
    get(value, "sources", fn(value) { array(value, source) }),
  )
  use _ <- result.try(require(
    set.size(set.from_list(sources)) == list.length(sources),
    "duplicate source identity",
  ))
  use graph_digest <- result.try(graph_digest(value))
  let source = internal_source(identity, revision, graph_digest)
  let type_source = type_source()
  use profile <- result.try(
    get(value, "profile", fn(value) {
      old(value, decode.decode_semantic_profile)
    }),
  )
  use _ <- result.try(result.map_error(
    validation.check_profile(profile),
    Profile,
  ))
  use _ <- result.try(require(
    valid_source_digest(profile.reference.content_digest),
    "profile content digest",
  ))
  use nodes <- result.try(
    get(value, "nodes", fn(value) {
      array(value, fn(value) {
        use _ <- result.try(object(value, ["id", "shape"]))
        use id <- result.try(get(value, "id", identifier))
        use shape <- result.try(
          get(value, "shape", fn(value) { shape(value, type_source, id) }),
        )
        Ok(types.TypeNode(reference(type_source, id), shape, None, [], []))
      })
    }),
  )
  use _ <- result.try(unique(
    list.map(nodes, fn(node) { node.reference.definition_name }),
    "type identity",
  ))
  use definitions <- result.try(
    get(value, "definitions", fn(value) {
      array(value, fn(value) { definition(value, type_source, sources) })
    }),
  )
  use _ <- result.try(unique(
    list.map(definitions, fn(definition) { definition.id }),
    "definition identity",
  ))
  use _ <- result.try(unique(
    list.map(definitions, fn(definition) { definition.wire_identity }),
    "wire identity",
  ))
  let graph =
    types.SemanticGraph(
      profile,
      nodes,
      list.map(sources, fn(source_identity) {
        types.SourceRef(
          source_identity.repository,
          source_identity.revision,
          source_identity.path,
          source_identity.content_digest,
          source_identity.path,
          None,
        )
      }),
    )
  use _ <- result.try(list.try_map(nodes, fn(node) { check_node(graph, node) }))
  use _ <- result.try(require(
    list.all(
      list.flat_map(definitions, fn(definition) {
        roots(definition, type_source)
      }),
      fn(reference) {
        case list.find(graph.nodes, fn(node) { node.reference == reference }) {
          Ok(node) -> Some(node)
          Error(_) -> None
        }
        != None
      },
    ),
    "unresolved definition type",
  ))
  use groups <- result.try(
    get(value, "groups", fn(value) {
      array(value, fn(value) {
        use _ <- result.try(object(value, ["id", "members"]))
        use id <- result.try(get(value, "id", identifier))
        use members <- result.try(
          get(value, "members", fn(value) { array(value, identifier) }),
        )
        use _ <- result.try(unique(members, "group member"))
        use _ <- result.try(require(
          list.all(members, fn(id) {
            list.any(definitions, fn(definition) { definition.id == id })
          }),
          "unresolved group member",
        ))
        Ok(DefinitionGroup(id, members))
      })
    }),
  )
  use _ <- result.try(unique(
    list.map(groups, fn(group) { group.id }),
    "group identity",
  ))
  use annotations <- result.try(
    get(value, "annotations", fn(value) {
      array(value, fn(value) {
        use _ <- result.try(object(value, ["target", "key", "value"]))
        use target <- result.try(
          get(value, "target", fn(value) {
            target(value, definitions, nodes, groups)
          }),
        )
        use key <- result.try(get(value, "key", identifier))
        use exact <- result.try(
          get(value, "value", fn(value) {
            result.map_error(values.decode_exact(value), Json)
          }),
        )
        Ok(Annotation(target, key, exact))
      })
    }),
  )
  use _ <- result.try(require(
    set.size(
      set.from_list(
        list.map(annotations, fn(annotation) {
          #(annotation.target, annotation.key)
        }),
      ),
    )
      == list.length(annotations),
    "duplicate annotation identity",
  ))
  use provenance <- result.try(
    get(value, "provenance", fn(value) {
      array(value, fn(value) {
        use _ <- result.try(object(value, ["target", "origins"]))
        use target <- result.try(
          get(value, "target", fn(value) {
            target(value, definitions, nodes, groups)
          }),
        )
        use origins <- result.try(
          get(value, "origins", fn(value) {
            array(value, fn(value) { origin(value, sources) })
          }),
        )
        Ok(ProvenanceBinding(target, origins))
      })
    }),
  )
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
  use _ <- result.try(
    check_library(declaration)
    |> result.map_error(fn(failure) { Invalid(library_check_name(failure)) }),
  )
  Ok(AdmittedLibrary(
    value,
    identity,
    revision,
    graph,
    definitions,
    annotations,
    groups,
    sources,
    source,
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

fn library_check_name(failure: LibraryCheckFailure) -> String {
  case failure {
    ProfileCheck(_) -> "profile"
    LibraryCheck(LibraryFailure(_, predicate, _)) ->
      case predicate {
        Lb01 -> "LB01"
        Lb02 -> "LB02"
        Lb03 -> "LB03"
        Lb04 -> "LB04"
        Lb05 -> "LB05"
        Lb06 -> "LB06"
        Lb07 -> "LB07"
        Lb08 -> "LB08"
        Lb09 -> "LB09"
        Lb10 -> "LB10"
        Lb11 -> "LB11"
        Lb12 -> "LB12"
        Lb13 -> "LB13"
        Lb14 -> "LB14"
        Lb15 -> "LB15"
        Lb16 -> "LB16"
        Lb17 -> "LB17"
        Lb18 -> "LB18"
        Lb19 -> "LB19"
      }
  }
}

pub fn validate_value(
  library: AdmittedLibrary,
  id: String,
  value: json.JsonValue,
) -> Result(Nil, runtime.ValueFailure) {
  runtime.validate_value(library.graph, type_ref(library, id), value)
}

pub fn canonical(value: json.JsonValue) -> Result(String, Failure) {
  result.map_error(values.encode_wire(sort_keys(value)), Json)
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

pub fn signature_digests(
  library: AdmittedLibrary,
) -> Result(#(String, String, String), Failure) {
  let graph = library.source.content_digest
  use definitions <- result.try(
    items(library.wire, "definitions")
    |> result.try(fn(items) { sort_by(items, id_key) }),
  )
  use sources <- result.try(
    items(library.wire, "sources")
    |> result.try(fn(items) {
      sort_by(items, fn(value) {
        use repository <- result.try(get(value, "repository", text))
        use revision <- result.try(get(value, "revision", text))
        use path <- result.try(get(value, "path", text))
        use digest <- result.try(get(value, "content_digest", text))
        Ok(
          repository
          <> "\u{0}"
          <> revision
          <> "\u{0}"
          <> path
          <> "\u{0}"
          <> digest,
        )
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
    hash(
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
      sort_by(items, fn(value) {
        use target <- result.try(target_key(value))
        use key <- result.try(get(value, "key", text))
        use exact <- result.try(get(value, "value", canonical))
        Ok(target <> "\u{0}" <> key <> "\u{0}" <> exact)
      })
    }),
  )
  use metadata <- result.try(
    hash(
      json.JsonValueObj([
        #("groups", json.JsonValueArr(groups)),
        #("annotations", json.JsonValueArr(annotations)),
      ]),
    ),
  )
  Ok(#(graph, provenance, metadata))
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
    entrypoints_sha256,
  ))
}

fn calculate_generation_identity(
  library: AdmittedLibrary,
  composition: json.JsonValue,
  entrypoints: json.JsonValue,
) -> Result(GenerationIdentity, Failure) {
  use digests <- result.try(signature_digests(library))
  use profile <- result.try(
    get(library.wire, "profile", fn(value) {
      use reference <- result.try(field(value, "reference"))
      old(reference, decode.decode_profile_ref)
    }),
  )
  use problem <- result.try(case composition {
    json.JsonValueNull -> Ok(None)
    _ -> result.map(hash(composition), Some)
  })
  use sorted <- result.try(
    array(entrypoints, Ok)
    |> result.try(fn(items) {
      sort_by(items, fn(value) { get(value, "identity", identifier) })
    }),
  )
  use entrypoints_digest <- result.try(hash(json.JsonValueArr(sorted)))
  Ok(GenerationIdentity(
    "ncoh-type-signatures@1",
    library.identity,
    library.revision,
    profile,
    digests.0,
    digests.1,
    digests.2,
    problem,
    entrypoints_digest,
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
  use basis <- result.try(generation_basis(library, composition, entrypoints))
  let input =
    json.JsonValueObj([
      #("schema", json.JsonValueStr("ncoh-checked-generation@4")),
      #("basis", basis),
      #("signatures", library.wire),
      #("composition", composition),
      #("entrypoints", entrypoints),
    ])
  use expected <- result.try(canonical(basis))
  use exchange <- result.try(canonical(input))
  Ok(#(expected, exchange))
}

pub fn admit_generation(
  expected_json: String,
  input_json: String,
) -> Result(CheckedGeneration, Failure) {
  use expected <- result.try(result.map_error(
    values.parse_wire(expected_json),
    Json,
  ))
  use input <- result.try(result.map_error(values.parse_wire(input_json), Json))
  use _ <- result.try(
    object(input, [
      "schema",
      "basis",
      "signatures",
      "composition",
      "entrypoints",
    ]),
  )
  use schema <- result.try(get(input, "schema", text))
  use _ <- result.try(case schema == "ncoh-checked-generation@4" {
    True -> Ok(Nil)
    False -> Error(Wire(decode.UnsupportedSchema(schema)))
  })
  use basis <- result.try(field(input, "basis"))
  use library <- result.try(get(input, "signatures", decode_library_value))
  use composition_wire <- result.try(field(input, "composition"))
  use entrypoints <- result.try(field(input, "entrypoints"))
  use expected <- result.try(decode_generation_identity(expected))
  use supplied <- result.try(decode_generation_identity(basis))
  use observed <- result.try(calculate_generation_identity(
    library,
    composition_wire,
    entrypoints,
  ))
  use _ <- result.try(require(
    expected == supplied && supplied == observed,
    "caller basis/digest mismatch",
  ))
  use entries <- result.try(
    array(entrypoints, fn(value) {
      use _ <- result.try(object(value, ["identity", "definition"]))
      use identity <- result.try(get(value, "identity", identifier))
      use definition <- result.try(get(value, "definition", identifier))
      use _ <- result.try(require(
        list.any(library.definitions, fn(value) { value.id == definition }),
        "unresolved entrypoint definition",
      ))
      Ok(identity)
    }),
  )
  use _ <- result.try(unique(entries, "entrypoint"))
  use _ <- result.try(require(entries != [], "entrypoint required"))
  use _ <- result.try(
    case
      validation.meaning_obligations(
        library.graph,
        list.map(library.graph.nodes, fn(node) { node.reference }),
      )
    {
      [] -> Ok(Nil)
      obligations -> Error(Meaning(obligations))
    },
  )
  use causes <- result.try(case composition_wire {
    json.JsonValueNull -> Ok([])
    _ -> composition_causes(library, composition_wire)
  })
  use checked <- result.try(case composition_wire {
    json.JsonValueNull -> Ok(None)
    _ -> {
      use _ <- result.try(check_composition_snapshots(composition_wire))
      use translated <- result.try(translate_composition(
        library,
        composition_wire,
      ))
      use decoded <- result.try(old(
        translated,
        decode.decode_generation_composition,
      ))
      use prepared <- result.try(prepare_composition(
        library,
        decoded.problem,
        causes,
      ))
      composition.verify_composition(prepared, decoded.derivation)
      |> result.map(Some)
      |> result.map_error(Witness)
    }
  })
  Ok(CheckedGeneration(
    replace(input, "basis", generation_identity_wire(observed)),
    observed,
    library,
    checked,
    causes,
  ))
}

fn composition_causes(
  library: AdmittedLibrary,
  value: json.JsonValue,
) -> Result(List(#(composition.FunctionRef, List(OutcomeContract))), Failure) {
  use problem <- result.try(field(value, "problem"))
  get(problem, "signatures", fn(value) {
    array(value, fn(value) {
      use reference <- result.try(
        get(value, "reference", fn(value) {
          old(value, decode.decode_function_ref)
        }),
      )
      use outcomes <- result.try(
        get(value, "outcomes", fn(value) {
          array(value, fn(value) {
            use cause <- result.try(
              get(value, "cause", fn(value) { cause(value, library.sources) }),
            )
            use translated <- result.try(translate_composition(library, value))
            use contract <- result.try(old(
              translated,
              decode.decode_outcome_contract,
            ))
            use _ <- result.try(require(
              case cause {
                ExternalCondition(_) ->
                  contract.form == composition.DeclaredFailure
                  && contract.value_ports != []
                _ -> True
              },
              "external condition requires a typed failure",
            ))
            Ok(OutcomeContract(contract, cause))
          })
        }),
      )
      Ok(#(reference, outcomes))
    })
  })
}

pub fn translate_composition(
  library: AdmittedLibrary,
  value: json.JsonValue,
) -> Result(json.JsonValue, Failure) {
  case value {
    json.JsonValueArr(items) ->
      list.try_map(items, fn(value) { translate_composition(library, value) })
      |> result.map(json.JsonValueArr)
    json.JsonValueObj(members) -> {
      use _ <- result.try(case list.key_find(members, "cause") {
        Ok(value) -> result.map(cause(value, library.sources), fn(_) { Nil })
        Error(_) ->
          require(
            !list.any(members, fn(member) { member.0 == "value_ports" }),
            "outcome cause required",
          )
      })
      use translated <- result.try(
        list.try_map(
          list.filter(members, fn(member) { member.0 != "cause" }),
          fn(member) {
            case member.0 {
              "type_id" -> {
                use id <- result.try(identifier(member.1))
                use reference <- result.try(
                  old_reference_wire(type_ref(library, id)),
                )
                Ok(#("type_ref", reference))
              }
              "type_ref" -> fail("type_ref is not an @2 field")
              "empty_types" | "reference_trace" -> {
                use references <- result.try(
                  array(member.1, fn(value) {
                    use id <- result.try(identifier(value))
                    old_reference_wire(type_ref(library, id))
                  }),
                )
                Ok(#(member.0, json.JsonValueArr(references)))
              }
              "basis" -> {
                use expected <- result.try(generation_basis(
                  library,
                  json.JsonValueNull,
                  json.JsonValueArr([]),
                ))
                use expected <- result.try(canonical(expected))
                use observed <- result.try(canonical(member.1))
                use _ <- result.try(require(
                  expected == observed,
                  "composition signature basis mismatch",
                ))
                use basis <- result.try(result.map_error(
                  decode.encode_semantic_basis(composition.semantic_basis(
                    library.graph,
                  )),
                  Wire,
                ))
                Ok(#("basis", basis))
              }
              "token_type" -> {
                case list.key_find(members, "id") {
                  Error(_) -> Ok(member)
                  Ok(_) -> {
                    use id <- result.try(identifier(member.1))
                    use reference <- result.try(
                      old_reference_wire(type_ref(library, id)),
                    )
                    Ok(#(member.0, reference))
                  }
                }
              }
              "source_type" -> {
                use id <- result.try(identifier(member.1))
                use reference <- result.try(
                  old_reference_wire(type_ref(library, id)),
                )
                Ok(#(member.0, reference))
              }
              "source_shape" | "destination_shape" -> {
                use pair <- result.try(field(value, "pair"))
                use contract <- result.try(
                  field(pair, case member.0 {
                    "source_shape" -> "source"
                    _ -> "destination"
                  }),
                )
                use id <- result.try(get(contract, "type_id", identifier))
                use node <- result.try(
                  result.map_error(
                    option.to_result(
                      case
                        list.find(library.graph.nodes, fn(node) {
                          node.reference == type_ref(library, id)
                        })
                      {
                        Ok(node) -> Some(node)
                        Error(_) -> None
                      },
                      Nil,
                    ),
                    fn(_) { Invalid("unresolved pair type") },
                  ),
                )
                use supplied <- result.try(shape(
                  member.1,
                  node.reference.source,
                  id,
                ))
                use _ <- result.try(require(
                  supplied == node.shape,
                  "pair shape differs from declared type",
                ))
                Ok(#(member.0, member.1))
              }
              "value" -> {
                let operation =
                  list.key_find(members, "tag")
                  == Ok(json.JsonValueStr("Operation"))
                case operation {
                  True -> {
                    use id <- result.try(identifier(member.1))
                    use _ <- result.try(require(
                      list.any(library.definitions, fn(definition) {
                        definition.id == id
                      }),
                      "unresolved operation definition",
                    ))
                    use reference <- result.try(definition_ref(library, id))
                    use wire <- result.try(result.map_error(
                      decode.encode_definition_ref(reference),
                      Wire,
                    ))
                    Ok(#("value", wire))
                  }
                  False ->
                    result.map(
                      translate_composition(library, member.1),
                      fn(value) { #(member.0, value) },
                    )
                }
              }
              _ ->
                result.map(translate_composition(library, member.1), fn(value) {
                  #(member.0, value)
                })
            }
          },
        ),
      )
      Ok(json.JsonValueObj(translated))
    }
    _ -> Ok(value)
  }
}

pub fn prepare_composition(
  library: AdmittedLibrary,
  input: composition.CompositionInput,
  causes: List(#(composition.FunctionRef, List(OutcomeContract))),
) -> Result(composition.PreparedCompositionInput, Failure) {
  composition.prepare_composition(library.graph, input, fn(function) {
    let fail = fn(reason) {
      composition.InvalidSignature(function.reference, reason)
    }
    use _ <- result.try(case function.form {
      composition.Operation(reference) -> {
        case
          list.find(library.definitions, fn(definition) {
            definition.id == reference.name
          })
        {
          Ok(SignatureDefinition(_, wire, Operation(operation))) -> {
            use _ <- result.try(
              case
                function.reference.identity == wire
                && function.reference.revision == library.revision
                && function.reference.content_digest
                == library.source.content_digest
              {
                True -> Ok(Nil)
                False -> Error(fail("operation function basis"))
              },
            )
            let effect = case operation.effect {
              types.HttpRequestResponse -> composition.HttpRequestResponse
              types.DataOnly -> composition.DataOnly
            }
            use _ <- result.try(
              case
                function.effect == effect
                && same_inputs(function.inputs, operation.inputs)
              {
                True -> Ok(Nil)
                False -> Error(fail("operation effect/input replacement"))
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
            use _ <- result.try(
              case
                list.all(operation.outcomes, fn(outcome) {
                  list.contains(declared, outcome)
                })
              {
                True -> Ok(Nil)
                False -> Error(fail("basic outcome deletion or replacement"))
              },
            )
            case
              list.all(declared, fn(outcome) {
                list.contains(operation.outcomes, outcome)
                || case outcome.cause {
                  ExternalCondition(origin) ->
                    outcome.contract.form == composition.DeclaredFailure
                    && outcome.contract.value_ports != []
                    && list.contains(library.sources, origin.source)
                  _ -> False
                }
              })
            {
              True -> Ok(Nil)
              False ->
                Error(fail("supplement must be an external typed failure"))
            }
          }
          _ -> Error(fail("unresolved operation"))
        }
      }
      _ ->
        case
          list.any(library.definitions, fn(definition) {
            definition.wire_identity == function.reference.identity
            && function.reference.revision == library.revision
            && function.reference.content_digest
            == library.source.content_digest
            && case definition.shape {
              Operation(_) -> True
              _ -> False
            }
          })
        {
          True -> Error(fail("operation requires operation form"))
          False -> Ok(Nil)
        }
    })
    let neutral = case function.form {
      composition.Operation(_) ->
        composition.FunctionSignature(
          ..function,
          form: composition.Pure,
          effect: composition.PureFunction,
        )
      _ -> function
    }
    composition.check_function(library.graph, input, neutral)
  })
  |> result.map_error(CompositionInput)
}

fn graph_digest(wire: json.JsonValue) -> Result(String, Failure) {
  use profile <- result.try(field(wire, "profile"))
  use nodes <- result.try(
    items(wire, "nodes") |> result.try(fn(items) { sort_by(items, id_key) }),
  )
  use definitions <- result.try(
    items(wire, "definitions")
    |> result.try(fn(items) { sort_by(items, id_key) }),
  )
  use definitions <- result.try(list.try_map(definitions, graph_definition))
  hash(
    json.JsonValueObj([
      #("profile", profile),
      #("nodes", json.JsonValueArr(nodes)),
      #("definitions", json.JsonValueArr(definitions)),
    ]),
  )
}

pub fn start_generation(
  checked: CheckedGeneration,
  arguments: List(#(composition.InputId, types.SlotValue(json.JsonValue))),
  providers: List(runtime.Provider),
  state: network.NetworkState,
) -> Result(runtime.Progress, runtime.RunFailure) {
  case checked.composition {
    None -> Error(runtime.RunFailure(runtime.MissingComposition, state))
    Some(checked_composition) -> {
      let expected =
        composition.prepared_input(composition.checked_prepared(
          checked_composition,
        )).signatures
      runtime.start_composition(
        checked_composition,
        arguments,
        providers,
        expected,
        state,
        fn(function, outcome) {
          is_external_failure(checked, function, outcome)
        },
      )
    }
  }
}

pub fn checked_outcomes(
  checked: CheckedGeneration,
  function: composition.FunctionRef,
) -> List(OutcomeContract) {
  result.unwrap(list.key_find(checked.outcome_causes, function), [])
}

pub fn is_external_failure(
  checked: CheckedGeneration,
  function: composition.FunctionRef,
  outcome: composition.OutcomeId,
) -> Bool {
  list.any(checked_outcomes(checked, function), fn(value) {
    value.contract.id == outcome
    && case value.cause {
      ExternalCondition(_) -> True
      _ -> False
    }
  })
}

pub fn generated_definitions(
  checked: CheckedGeneration,
) -> List(SignatureDefinition) {
  list.map(checked.library.definitions, fn(definition) {
    case definition.shape, checked.composition {
      Operation(operation), Some(checked_composition) -> {
        let input =
          composition.prepared_input(composition.checked_prepared(
            checked_composition,
          ))
        case
          list.find(input.signatures, fn(function) {
            case function.form {
              composition.Operation(reference) ->
                reference.name == definition.id
              _ -> False
            }
          })
        {
          Ok(function) ->
            SignatureDefinition(
              ..definition,
              shape: Operation(
                OperationContract(
                  ..operation,
                  outcomes: checked_outcomes(checked, function.reference),
                ),
              ),
            )
          Error(_) -> definition
        }
      }
      _, _ -> definition
    }
  })
}

fn operation_outcomes(
  checked: CheckedGeneration,
  definition_id: String,
) -> Result(List(OutcomeContract), Failure) {
  use definition <- result.try(
    result.map_error(
      list.find(checked.library.definitions, fn(value) {
        value.id == definition_id
      }),
      fn(_) { Invalid("unresolved operation") },
    ),
  )
  case definition.shape {
    Operation(operation) -> {
      case
        list.find(checked.outcome_causes, fn(entry) {
          entry.0.identity == definition.wire_identity
        })
      {
        Ok(entry) -> Ok(entry.1)
        Error(_) -> Ok(operation.outcomes)
      }
    }
    _ -> fail("definition is not an operation")
  }
}

pub fn validate_outcome(
  checked: CheckedGeneration,
  definition: String,
  output: runtime.OutcomeValues,
) -> Result(Nil, Failure) {
  use outcomes <- result.try(operation_outcomes(checked, definition))
  use outcome <- result.try(
    result.map_error(
      list.find(outcomes, fn(value) { value.contract.id == output.outcome }),
      fn(_) { Invalid("undeclared outcome") },
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
          Invalid("missing outcome port")
        }),
      )
      result.map_error(
        runtime.validate_slot(checked.library.graph, port.contract, value),
        Codec,
      )
    }),
  )
  Ok(Nil)
}

pub fn encode_outcome(
  checked: CheckedGeneration,
  definition: String,
  output: runtime.OutcomeValues,
) -> Result(String, Failure) {
  use _ <- result.try(validate_outcome(checked, definition, output))
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

pub fn decode_outcome(
  checked: CheckedGeneration,
  definition: String,
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
        Ok(#(composition.PortId(id), value))
      })
    }),
  )
  let output = runtime.OutcomeValues(composition.OutcomeId(id), ports)
  use _ <- result.try(validate_outcome(checked, definition, output))
  Ok(output)
}

fn same_inputs(
  a: List(composition.InputPort),
  b: List(composition.InputPort),
) -> Bool {
  case a, b {
    [], [] -> True
    [a, ..rest_a], [b, ..rest_b] ->
      a.id == b.id && a.contract == b.contract && same_inputs(rest_a, rest_b)
    _, _ -> False
  }
}

fn check_composition_snapshots(value: json.JsonValue) -> Result(Nil, Failure) {
  use problem <- result.try(field(value, "problem"))
  use expected <- result.try(canonical(problem))
  use derivation <- result.try(field(value, "derivation"))
  use witness <- result.try(field(derivation, "witness"))
  use snapshot <- result.try(get(witness, "input_snapshot", canonical))
  use _ <- result.try(require(
    snapshot == expected,
    "cause-aware witness input snapshot mismatch",
  ))
  use selection <- result.try(field(derivation, "selection"))
  use tag <- result.try(get(selection, "tag", text))
  case tag {
    "Unique" -> {
      use fields <- result.try(field(selection, "fields"))
      use closure <- result.try(field(fields, "closure"))
      use snapshot <- result.try(get(closure, "input_snapshot", canonical))
      require(
        snapshot == expected,
        "cause-aware closure input snapshot mismatch",
      )
    }
    _ -> Ok(Nil)
  }
}
