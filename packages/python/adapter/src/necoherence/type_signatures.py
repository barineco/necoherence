# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Wire decoding and checked admission for semantic signature libraries."""
from __future__ import annotations

import copy
import hashlib
import json
from dataclasses import dataclass
from collections.abc import Mapping
from decimal import Decimal
from typing import Any, TypeAlias

import neco_quotient_certificate as nqc

from .signature_values import DecimalLiteral, ValueContext, integer_from_digits, WireFailure, canonical_json, canonical_wire, integer, integer_condition, named_format_accepts, payload, prepare_profile, string_condition, sum_tag, unicode_valid
from .declaration_wire import ENTRYPOINT, EXPECTED_SIGNATURE_BASIS, GOAL_OBSERVATIONS, LIBRARY, SIGNATURE_BASIS, exact_json
from .composition_wire_base import encode_path_step
from .profile_wire import PROFILE_REF, VALUE_PROFILE
from .wire_schema import UNIT, closed, int_text, json_number_grammar, listed, nat_text, optional, record, string, tuple_case, variant, wire_document

TypeSignatureLibrary: TypeAlias = dict[str, Any]


class DeclarationFailure(ValueError):
    def __init__(self, reference, predicate, location):
        self.reference = reference
        self.predicate = predicate
        self.location = tuple(location)
        super().__init__(f"{predicate} at {'/'.join(location)}")


class AdmissionFailure(ValueError):
    kind: str

    def __init__(self, cause=None):
        self.cause = cause
        super().__init__(self.kind if cause is None else f"{self.kind}: {cause}")


class UnsupportedSchema(AdmissionFailure):
    kind = "UnsupportedSchema"


class EntrypointsEmpty(AdmissionFailure):
    kind = "EntrypointsEmpty"


class EntrypointIdentityEmpty(AdmissionFailure):
    kind = "EntrypointIdentityEmpty"


class EntrypointDuplicate(AdmissionFailure):
    kind = "EntrypointDuplicate"


class UnresolvedEntrypoint(AdmissionFailure):
    kind = "UnresolvedEntrypoint"


class Library(AdmissionFailure):
    kind = "Library"


class Certificate(AdmissionFailure):
    kind = "Certificate"


class ProfileBasisMismatch(AdmissionFailure):
    kind = "BasisMismatch"


class ProfileDigestMismatch(AdmissionFailure):
    kind = "DigestMismatch"


class Wire(AdmissionFailure):
    kind = "Wire"


class CompositionInput(AdmissionFailure):
    kind = "CompositionInput"


class Composition(AdmissionFailure):
    kind = "Composition"


class Generation(AdmissionFailure):
    kind = "Generation"


_checked_value_token = object()


@dataclass(frozen=True, slots=True)
class CheckedProfile:
    value: dict

    def __init__(self, token, value):
        if token is not _checked_value_token: raise RuntimeError("CheckedValueAdmissionRequired")
        object.__setattr__(self, "value", value)


@dataclass(frozen=True, slots=True)
class CheckedLibrary:
    value: dict
    profile: CheckedProfile

    def __init__(self, token, value, profile):
        if token is not _checked_value_token: raise RuntimeError("CheckedValueAdmissionRequired")
        object.__setattr__(self, "value", value)
        object.__setattr__(self, "profile", profile)


_EXECUTION_FAILURES=("argumentCoverage","invalidOutcome","invalidPlan","missingArgument","missingProvider","missingValue","network","networkTerminal","provider","providerCoverage","providerEffect","resource","value")


def _goal_rows(value,keys):
    if type(value) is not list: return []
    return [{key:copy.deepcopy(item.get(key)) if isinstance(item,dict) else None for key in keys} for item in value]


def _member(value,key):
    return value.get(key) if isinstance(value,dict) else None


def _plan_returns(tree):
    node=_member(tree,"node")
    tag=_member(node,"tag")
    if tag=="Return": return [_member(node,"value")]
    if tag not in ("Invoke","Guard"): return []
    arms=_member(_member(node,"fields"),"arms")
    if type(arms) is not list: return []
    return [value for arm in arms if type(arm) is list and len(arm)==2 for value in _plan_returns(arm[1])]


def _returned_ports(value):
    pairs=_member(value,"value")
    if type(pairs) is not list: return []
    return [pair[0] for pair in pairs if type(pair) is list and pair and type(pair[0]) is str]


def _row_ids(rows):
    return [item["id"] for item in rows if isinstance(item,dict) and type(item.get("id")) is str] if type(rows) is list else []


def _first_occurrences(values):
    seen=[]
    for value in values:
        if value not in seen: seen.append(value)
    return seen


def _kept_rows(rows,keys,kept,extra):
    declared=[item for item in rows if kept(item.get("id") if isinstance(item,dict) and type(item.get("id")) is str else "")] if type(rows) is list else []
    return _goal_rows(declared,keys)+[{key:(identifier if key=="id" else None) for key in keys} for identifier in extra]


class GoalObservations:
    """合成の goal が実行結果として観測させる量の族の宣言。成功時の出力、失敗の埋め込み、最終的な資源の要求、中断とネットワーク指示の列、残余 ( residual ) の集合、型付き実行失敗の種類、結果の来歴を定める。"""
    def __init__(self, value):
        GOAL_OBSERVATIONS(value,"$")
        self._value = copy.deepcopy(value)

    @classmethod
    def of_composition(cls, composition):
        problem=composition.get("problem") if isinstance(composition,dict) else None
        goal=problem.get("goal") if isinstance(problem,dict) else None
        goal=goal if isinstance(goal,dict) else {}
        return cls({
            "outputs":_goal_rows(goal.get("outputs"),("id","contract")),
            "failures":_goal_rows(goal.get("failures"),("id","contract","final_resources")),
            "final_resources":copy.deepcopy(goal.get("final_resources")),
            "effects":["network_instruction","pending"],
            "residuals":"residual_set",
            "execution_failures":list(_EXECUTION_FAILURES),
            "provenance":"certificate_basis",
        })

    @classmethod
    def of_plan(cls, composition):
        """合成の導出の Return 節点が出力する値と失敗の埋め込みから作る観測関数族。Return 節点の集まりが goal の宣言と一致する時に、goal から作る観測関数族と等しい。"""
        goal=_member(_member(composition,"problem"),"goal")
        goal=goal if isinstance(goal,dict) else {}
        returns=_plan_returns(_member(_member(_member(composition,"derivation"),"plan"),"root"))
        successes=[_returned_ports(value) for value in returns if _member(value,"tag")=="Success"]
        embeddings=[embedding for value in returns if _member(value,"tag")!="Success"
                    for embedding in [_member(_member(value,"fields"),"embedding")] if type(embedding) is str]
        output_ids=_row_ids(goal.get("outputs")); failure_ids=_row_ids(goal.get("failures"))
        returned_output=lambda identifier: bool(successes) and all(identifier in ports for ports in successes)
        return cls({
            "outputs":_kept_rows(goal.get("outputs"),("id","contract"),returned_output,
                                 _first_occurrences(port for ports in successes for port in ports if port not in output_ids)),
            "failures":_kept_rows(goal.get("failures"),("id","contract","final_resources"),lambda identifier: identifier in embeddings,
                                  _first_occurrences(embedding for embedding in embeddings if embedding not in failure_ids)),
            "final_resources":copy.deepcopy(goal.get("final_resources")),
            "effects":["network_instruction","pending"],
            "residuals":"residual_set",
            "execution_failures":list(_EXECUTION_FAILURES),
            "provenance":"certificate_basis",
        })

    @property
    def value(self): return copy.deepcopy(self._value)

    def __eq__(self, other): return type(other) is GoalObservations and _canonical(self._value)==_canonical(other._value)
    def __hash__(self): return hash(_canonical(self._value))


class ExpectedSignatureBasis:
    def __init__(self, basis, observations):
        SIGNATURE_BASIS(basis,"$.basis")
        if observations is not None and type(observations) is not GoalObservations: raise TypeError("goal observations required")
        self._basis = copy.deepcopy(basis)
        self._observations = observations

    @classmethod
    def of_exchange(cls, exchange):
        composition=exchange["composition"]
        return cls(exchange["basis"], None if composition is None else GoalObservations.of_composition(composition))

    @property
    def basis(self): return copy.deepcopy(self._basis)
    @property
    def observations(self): return self._observations


class CheckedSignatureGeneration:
    def __init__(self, token, input_value, checked_library, admitted_composition, admission):
        if token is not _checked_value_token: raise RuntimeError("CheckedValueAdmissionRequired")
        self._input = input_value
        self.checked_library = checked_library
        self._admitted_composition = admitted_composition
        self._admission = admission
        self._graph = _graph(input_value["signatures"])
        self._values = ValueContext(self._graph) if admitted_composition is None else admitted_composition.prepared.values

    @property
    def admitted_composition(self): return self._admitted_composition
    @property
    def admission(self): return self._admission
    @property
    def input(self): return copy.deepcopy(self._input)
    @property
    def graph(self): return copy.deepcopy(self._graph)
    @property
    def values(self): return self._values
    @property
    def types(self): return tuple(self._graph["nodes"])
    @property
    def definitions(self): return tuple(self._graph["definitions"])
    @property
    def entrypoints(self): return tuple(self._input["entrypoints"])
    @property
    def composition(self): return self._input["composition"]
    @property
    def annotations(self): return tuple(self._input["signatures"]["annotations"])


_GENERATION_KEYS=("schema","basis","signatures","composition","entrypoints")
SOURCE_REF=record(("repository",string),("revision",string),("path",string),("content_digest",string),("document_id",string),("declared_revision",optional(int_text)))
TYPE_REF=record(("source",SOURCE_REF),("definition_name",string),("pointer",listed(string)))
DEFINITION_REF=record(("source",SOURCE_REF),("name",string))
OCCURRENCE_REF=record(("source",SOURCE_REF),("pointer",listed(string)))
VALUE_STEP=variant({"Field":tuple_case(string),"Index":tuple_case(nat_text),"Variant":tuple_case(string)})
VALUE_CONDITION=variant({
    "MissingRequired":UNIT,"NullNotAllowed":UNIT,"WrongValueKind":tuple_case(string),
    "ConstMismatch":UNIT,"EnumMismatch":UNIT,"BelowMinimum":UNIT,"AboveMaximum":UNIT,
    "IntegerDomain":UNIT,"StringLength":UNIT,"ArrayLength":UNIT,"BytesLength":UNIT,
    "Format":tuple_case(string),"InvalidBytes":UNIT,"InvalidWrapper":tuple_case(string),"InvalidTag":UNIT,
    "ReservedForm":UNIT,"NoBranchSelected":UNIT,"KeyFormat":tuple_case(string),"Uninhabited":UNIT,
    "DuplicateField":tuple_case(string),"UnexpectedField":tuple_case(string),"InvalidDataModel":UNIT,
    "ReferenceCycle":UNIT,
})
OBSERVED=variant({"Absent":UNIT,"Null":UNIT,"Present":tuple_case(exact_json)})
DIAGNOSTIC=record(("type_ref",TYPE_REF),("definition_ref",DEFINITION_REF),("origin",OCCURRENCE_REF),("value_path",listed(VALUE_STEP)),("condition",VALUE_CONDITION),("observed",OBSERVED),("reference_trace",listed(TYPE_REF)))

SEMANTIC_REASON=variant({
    "MissingGraphemeRules":UNIT,"MissingBytesPolicy":UNIT,"DecimalNotAdmitted":UNIT,"IntegerBound":UNIT,
    "MissingTagModel":UNIT,"UnresolvedType":UNIT,"MembershipBound":UNIT,
    "UnknownFormat":tuple_case(string),"UnknownIntegerDomain":tuple_case(string),"UnknownWrapper":tuple_case(string),
    "WrapperPayload":tuple_case(string),"UnknownSealedTag":tuple_case(string),"OpaqueType":tuple_case(string),
    "UninterpretedExtension":tuple_case(string),"InvalidProfile":tuple_case(string),"CertificateMismatch":tuple_case(string),
    "ProjectionUnavailable":tuple_case(string),
})
SEMANTIC_OBLIGATION=record(("type_ref",TYPE_REF),("origin",OCCURRENCE_REF),("value_path",listed(VALUE_STEP)),("profile",PROFILE_REF),("reason",SEMANTIC_REASON))


def decode_profile(value):
    decoded=wire_document(value)
    VALUE_PROFILE(decoded,"$")
    return decoded


def encode_profile(value):
    return canonical_wire(decode_profile(value))


def decode_library(value):
    decoded=wire_document(value)
    LIBRARY(decoded,"$")
    return decoded


def encode_library(value):
    return canonical_wire(decode_library(value))


def decode_diagnostic(value):
    decoded=wire_document(value)
    DIAGNOSTIC(decoded,"$")
    return decoded


def encode_diagnostic(value):
    return canonical_wire(decode_diagnostic(value))


def _plain_wire(value):
    if isinstance(value, Mapping):
        return {key: _plain_wire(child) for key, child in value.items()}
    if isinstance(value, (list, tuple)):
        return [_plain_wire(child) for child in value]
    return value


def encode_type_ref(value):
    wire=_plain_wire(value)
    TYPE_REF(wire,"$")
    return wire


def encode_semantic_obligation(value):
    row=_plain_wire(value)
    wire={**row,"value_path":[encode_path_step(step) for step in value["value_path"]]}
    SEMANTIC_OBLIGATION(wire,"$")
    return wire


def encode_semantic_obligations(values):
    return [encode_semantic_obligation(value) for value in values]


def decode_signature_basis(value):
    decoded=wire_document(value)
    SIGNATURE_BASIS(decoded,"$")
    return decoded


def encode_signature_basis(value):
    return canonical_wire(decode_signature_basis(value))


def decode_expected_signature_basis(value):
    decoded=wire_document(value)
    EXPECTED_SIGNATURE_BASIS(decoded,"$")
    observations=decoded["observations"]
    return ExpectedSignatureBasis(decoded["basis"], None if observations is None else GoalObservations(observations))


def encode_expected_signature_basis(value):
    if type(value) is not ExpectedSignatureBasis: raise TypeError("expected basis required")
    observations=value.observations
    return canonical_wire({"basis":value.basis,"observations":None if observations is None else observations.value})


def decode_value_condition(value):
    decoded=wire_document(value)
    VALUE_CONDITION(decoded,"$")
    return decoded


def encode_value_condition(value):
    return canonical_wire(decode_value_condition(value))


def decode_generation(exchange):
    value=wire_document(exchange)
    closed(value,_GENERATION_KEYS,"$")
    string(value["schema"],"$.schema")
    if value["schema"]!="ncoh-checked-generation@5": raise WireFailure("UnsupportedSchema","$.schema",value["schema"])
    SIGNATURE_BASIS(value["basis"],"$.basis")
    LIBRARY(value["signatures"],"$.signatures")
    listed(ENTRYPOINT)(value["entrypoints"],"$.entrypoints")
    return value


def encode_generation(value):
    return canonical_wire(decode_generation(value))


def _valid_reference(reference): return bool(reference.get("identity")) and bool(reference.get("revision")) and bool(reference.get("content_digest"))
def _unique(values): return all(values) and len(values)==len(set(values))
def _fail(reference,predicate,location): raise DeclarationFailure(reference,predicate,location)


def _dfa_well_formed(spec):
    count=integer(spec["state_count"])
    transitions=[{key:integer(row[key]) for key in ("from_state","first","last","to_state")} for row in spec["transitions"]]
    return (count>0 and integer(spec["initial_state"])<count and all(integer(state)<count for state in spec["accepting_states"])
        and all(row["from_state"]<count and row["to_state"]<count and row["first"]<=row["last"] and row["last"]<128 for row in transitions)
        and all(row["from_state"]!=other["from_state"] or row["last"]<other["first"] or other["last"]<row["first"] for index,row in enumerate(transitions) for other in transitions[index+1:]))


def _identifier_well_formed(spec):
    minimum=integer(spec["min_length"]); maximum=None if spec["max_length"] is None else integer(spec["max_length"])
    exact=None if spec["exact_length"] is None else integer(spec["exact_length"])
    return (bool(spec["first_alphabet"]) and bool(spec["rest_alphabet"]) and (maximum is None or minimum<=maximum)
        and spec["first_alphabet"].isascii() and spec["rest_alphabet"].isascii() and all(unicode_valid(item) for item in spec["forbidden"])
        and (exact is None or minimum<=exact and (maximum is None or exact<=maximum)))


def _format_well_formed(rule):
    kind,spec=sum_tag(rule),payload(rule)
    if kind=="AsciiDfa": return _dfa_well_formed(spec)
    if kind=="Timestamp": return integer(spec["minimum_year"])<=integer(spec["maximum_year"])<=9999
    if kind=="Identifier": return _identifier_well_formed(spec)
    if kind in ("Sequence","Choice"): return all(_format_well_formed(item) for item in spec)
    if kind in ("Optional","Not"): return _format_well_formed(spec)
    if kind=="Labels": return bool(spec["separator"]) and _format_well_formed(spec["rule"])
    if kind=="Bounded": return _format_well_formed(spec["rule"])
    return True


def _text_wrapper_declared(profile,name):
    return any(row["name"]==name and sum_tag(row["payload"])=="Text" for row in profile["wrappers"])


def _format_use_malformed(profile,use):
    if sum_tag(use)=="Inline": return not _format_well_formed(payload(use))
    return _format_rule(profile,use) is None


def _length_bounds_invalid(bounds):
    return any(not _bound_valid(bound["minimum"],bound["maximum"]) for bound in bounds)


def _sealed_leaf_invalid(profile,leaf):
    kind,spec=sum_tag(leaf),payload(leaf)
    if kind=="String":
        return ((spec["wrapper"] is not None and not _text_wrapper_declared(profile,spec["wrapper"]))
            or (spec["format"] is not None and _format_use_malformed(profile,spec["format"]))
            or _length_bounds_invalid(spec["lengths"]))
    return spec["domain"] is not None and not any(row["name"]==spec["domain"] for row in profile["integer_domains"])


def _tag_failure(profile,model):
    wrapper_keys=[item["key"] for item in profile["wrappers"]]
    if not model["key"] or model["key"] in wrapper_keys: return "PR11",["tag","key"]
    if model["format"] is not None and not any(item["name"]==model["format"] for item in profile["format_bindings"]): return "PR12",["tag","format"]
    forms=model["sealed"]
    profile=prepare_profile(profile)
    if not _unique([form["tag"] for form in forms]) or (model["format"] is not None and any(not named_format_accepts(profile,model["format"],form["tag"]) for form in forms)): return "PR13",["tag","sealed"]
    def keys_invalid(form):
        keys=[field["key"] for field in form["fields"]]
        return not _unique(keys) or model["key"] in keys or any(key in wrapper_keys for key in keys)
    if any(keys_invalid(form) for form in forms): return "PR14",["tag","sealed","fields"]
    if any(_sealed_leaf_invalid(profile,field["leaf"]) for form in forms for field in form["fields"]): return "PR15",["tag","sealed","fields"]
    return None


def _profile_range_valid(range_value):
    return sum_tag(range_value)!="Inclusive" or integer(payload(range_value)["minimum"])<=integer(payload(range_value)["maximum"])


def _profile_failure(profile):
    wrappers=profile["wrappers"]
    domains=profile["integer_domains"]
    formats=profile["format_bindings"]
    rules=profile.get("grapheme_rules")
    policy=profile["bytes_policy"]
    if (not _valid_reference(profile["reference"]) or any(not _valid_reference(item["reference"]) for item in domains)
        or any(not _valid_reference(item["reference"]) for item in formats)
        or (policy is not None and not _valid_reference(policy["reference"]))
        or (rules is not None and not _valid_reference(rules["reference"]))): return "PR01",["profile"]
    if not _unique([item["name"] for item in domains]): return "PR02",["integer_domains"]
    if any(not _profile_range_valid(item["range"]) for item in domains): return "PR03",["integer_domains"]
    if any(not item["forms"] for item in domains): return "PR04",["integer_domains"]
    if profile["default_integer_domain"] not in [item["name"] for item in domains]: return "PR05",["default_integer_domain"]
    if not _unique([item["name"] for item in formats]): return "PR06",["format_bindings"]
    if any(not _format_well_formed(item["rule"]) for item in formats): return "PR07",["format_bindings"]
    if not _unique([item["name"] for item in wrappers]) or not _unique([item["key"] for item in wrappers]): return "PR08",["wrappers"]
    format_names={item["name"] for item in formats}
    if any(sum_tag(item["payload"])=="Text" and payload(item["payload"]) is not None and payload(item["payload"]) not in format_names for item in wrappers): return "PR09",["wrappers"]
    if policy is not None and policy["wrapper"] is not None and not any(item["name"]==policy["wrapper"] and sum_tag(item["payload"])=="Bytes" for item in wrappers): return "PR10",["bytes_policy","wrapper"]
    if profile["tag"] is not None:
        failure=_tag_failure(profile,profile["tag"])
        if failure is not None: return failure
    if rules is not None and any(integer(row["last"])<integer(row["first"]) for key in ("properties","extended_pictographic","indic_conjunct") for row in rules[key]): return "PR16",["grapheme_rules"]
    return None


def checkProfile(profile):
    failure=_profile_failure(profile)
    if failure is not None: _fail(profile["reference"],*failure)
    return CheckedProfile(_checked_value_token, copy.deepcopy(profile))


def shape_references(shape):
    kind,spec=sum_tag(shape),payload(shape)
    if kind=="Product":
        result=[field["slot"]["type_id"] for field in spec["fields"]]
        if sum_tag(spec["extras"])=="Allow": result.append(payload(spec["extras"])["value"]["type_id"])
        return result
    if kind=="Array": return [spec["item"]["type_id"]]
    if kind=="Alias": return [spec["target"]]
    if kind=="TaggedUnion": return [branch["target"] for branch in spec["branches"]]
    return []


def _definition_references(shape):
    kind, spec = sum_tag(shape), payload(shape)
    if kind in ("Value", "Message"):
        return [spec]
    if kind == "Operation":
        return [
            *[port["contract"]["type_id"] for port in spec["inputs"]],
            *[port["contract"]["type_id"] for outcome in spec["outcomes"] for port in outcome["value_ports"]],
            *[production["token_type"] for outcome in spec["outcomes"] for production in outcome["produced_resources"]],
        ]
    return []


def _valid_digest(digest):
    return len(digest)==64 and all("0"<=character<="9" or "a"<=character<="f" for character in digest)


def _origin_valid(library,origin):
    return origin["source"] in library["sources"]


def outcomeValid(library,outcome):
    if not _unique([port["id"] for port in outcome["value_ports"]]) or not _unique([item["id"] for item in outcome["produced_resources"]]): return False
    cause=outcome["cause"]
    if sum_tag(cause)=="ValueContract": return _origin_valid(library,payload(cause)["origin"])
    return _origin_valid(library,payload(cause)["specification"]) and bool(outcome["value_ports"]) and sum_tag(outcome["form"])=="DeclaredFailure"


def _target_valid(library,target):
    kind=sum_tag(target)
    if kind=="Library": return True
    if kind=="Group": return any(group["id"]==payload(target) for group in library["groups"])
    if kind=="Definition": return any(definition["id"]==payload(target) for definition in library["definitions"])
    if kind=="Type": return any(node["id"]==payload(target) for node in library["nodes"])
    fields=payload(target)
    return any(definition["id"]==fields["definition"] and sum_tag(definition["shape"])=="Operation" and any(outcome["id"]==fields["outcome"] for outcome in payload(definition["shape"])["outcomes"]) for definition in library["definitions"])


def _definition_valid(library,node_ids,definition):
    if not all(child in node_ids for child in _definition_references(definition["shape"])): return False
    if sum_tag(definition["shape"])!="Operation": return True
    operation=payload(definition["shape"])
    return _unique([port["id"] for port in operation["inputs"]]) and _unique([outcome["id"] for outcome in operation["outcomes"]]) and bool(operation["outcomes"]) and all(outcomeValid(library,outcome) for outcome in operation["outcomes"])


def _library_declaration_valid(library):
    sources=library["sources"]
    node_ids=[node["id"] for node in library["nodes"]]
    definition_ids=[definition["id"] for definition in library["definitions"]]
    return (library["schema"]=="ncoh-type-signatures@1" and bool(library["identity"]) and bool(library["revision"])
        and _valid_digest(library["profile"]["reference"]["content_digest"])
        and all(_valid_digest(source["content_digest"]) for source in sources)
        and all(source not in sources[:index] for index,source in enumerate(sources))
        and _unique(node_ids) and _unique(definition_ids) and _unique([group["id"] for group in library["groups"]])
        and all(child in node_ids for node in library["nodes"] for child in shape_references(node["shape"]))
        and all(_definition_valid(library,node_ids,definition) for definition in library["definitions"])
        and all(member in definition_ids for group in library["groups"] for member in group["members"])
        and all(_target_valid(library,binding["target"]) and all(_origin_valid(library,origin) for origin in binding["origins"]) for binding in library["provenance"])
        and all(_target_valid(library,annotation["target"]) for annotation in library["annotations"]))


def _specs(library,kind):
    return [payload(node["shape"]) for node in library["nodes"] if sum_tag(node["shape"])==kind]


def _branches(library):
    return [branch for spec in _specs(library,"TaggedUnion") for branch in spec["branches"]]


def _internal_tag(branch):
    return sum_tag(branch["selector"])=="InternalTag"


def _bound_valid(minimum,maximum):
    return minimum is None or maximum is None or integer(minimum)<=integer(maximum)


def _duplicate_selection(left,right):
    if _internal_tag(left) and _internal_tag(right): return left["wire_tag"]==right["wire_tag"]
    return left["selector"]==right["selector"]


def _lb02(library): return any(not _unique([field["wire_name"] for field in spec["fields"]]) for spec in _specs(library,"Product"))
def _lb03(library): return any(wrapper["key"]==field["wire_name"] for spec in _specs(library,"Product") for field in spec["fields"] for wrapper in library["profile"]["wrappers"])
def _lb04(library): return any(len({branch["wire_tag"] for branch in spec["branches"]})!=len(spec["branches"]) for spec in _specs(library,"TaggedUnion"))
def _lb05(library): return any(sum_tag(branch["selector"])=="Otherwise" and index+1!=len(spec["branches"]) for spec in _specs(library,"TaggedUnion") for index,branch in enumerate(spec["branches"]))
def _lb06(library): return any(branch["wire_tag"]=="" or (sum_tag(branch["selector"])=="MemberShape" and any(test["key"]=="" for test in payload(branch["selector"]))) for branch in _branches(library))


def _lb07(library):
    profile=prepare_profile(library["profile"]); model=profile["tag"]
    return model is not None and model["format"] is not None and any(_internal_tag(branch) and not named_format_accepts(profile,model["format"],branch["wire_tag"]) for branch in _branches(library))


def _lb08(library):
    model=library["profile"]["tag"]
    if model is None: return False
    nodes={node["id"]:node for node in library["nodes"]}
    def sealed_as(branch):
        shape=nodes[branch["target"]]["shape"]
        return sum_tag(shape)=="Sealed" and payload(shape)["tag"]==branch["wire_tag"]
    return any(_internal_tag(branch) and any(form["tag"]==branch["wire_tag"] for form in model["sealed"])!=sealed_as(branch) for branch in _branches(library))


def _lb09(library):
    formats={binding["name"] for binding in library["profile"]["format_bindings"]}
    def invalid(tests): return not _unique([test["key"] for test in tests]) or any(sum_tag(test["test"])=="Format" and payload(test["test"]) not in formats for test in tests)
    return any(sum_tag(branch["selector"])=="MemberShape" and invalid(payload(branch["selector"])) for branch in _branches(library))


def _lb10(library):
    model=library["profile"]["tag"]
    def refinement_invalid(spec):
        form=next((row for row in model["sealed"] if row["tag"]==spec["tag"]),None)
        if form is None: return True
        refinements=spec["refinements"]
        return not _unique([row["key"] for row in refinements]) or any(not any(field["key"]==row["key"] and sum_tag(field["leaf"])==sum_tag(row["leaf"]) for field in form["fields"]) for row in refinements)
    return any(model is None or refinement_invalid(spec) for spec in _specs(library,"Sealed"))


def _lb11(library):
    nodes={node["id"]:node for node in library["nodes"]}
    return any(_internal_tag(branch) and sum_tag(nodes[branch["target"]]["shape"]) not in ("Product","Sealed") for branch in _branches(library))


def _format_rule(profile,use):
    if sum_tag(use)=="Inline": return payload(use)
    binding=next((row for row in profile["format_bindings"] if row["name"]==payload(use)),None)
    return None if binding is None else binding["rule"]


def _lb12(library):
    profile=library["profile"]
    def unbound(spec):
        extras=spec["extras"]
        if sum_tag(extras)!="Allow" or payload(extras)["key_format"] is None: return False
        return _format_rule(profile,payload(extras)["key_format"]) is None
    return any(unbound(spec) for spec in _specs(library,"Product"))


def _lb13(library):
    profile=library["profile"]
    return any((spec["wrapper"] is not None and not _text_wrapper_declared(profile,spec["wrapper"]))
        or (spec["format"] is not None and _format_use_malformed(profile,spec["format"]))
        or any(not _bound_valid(bound["minimum"],bound["maximum"]) for bound in spec["lengths"])
        for spec in _specs(library,"String"))


def _lb14(library):
    domains={binding["name"] for binding in library["profile"]["integer_domains"]}
    return any(not _bound_valid(spec["minimum"],spec["maximum"]) or (spec["domain"] is not None and spec["domain"] not in domains) for spec in _specs(library,"Integer"))


def _lb15(library):
    def invalid(spec):
        minimum,maximum=spec["minimum"],spec["maximum"]
        return minimum is not None and maximum is not None and (integer(minimum["scale"])!=integer(maximum["scale"]) or integer(maximum["mantissa"])<integer(minimum["mantissa"]))
    return any(invalid(spec) for spec in _specs(library,"Decimal"))


def _lb16(library):
    return any(not _bound_valid(spec["min_length"],spec["max_length"]) for spec in _specs(library,"Array")) or any(not _bound_valid(spec["minimum"],spec["maximum"]) for spec in _specs(library,"Bytes"))


def _lb17(library):
    profile=prepare_profile(library["profile"]); model=profile["tag"]
    if model is None: return False
    nodes={node["id"]:node for node in library["nodes"]}
    def invalid(branch):
        target=nodes[branch["target"]]["shape"]
        if sum_tag(target)!="Product": return False
        field=next((row for row in payload(target)["fields"] if row["wire_name"]==model["key"]),None)
        if field is None: return True
        field_shape=nodes[field["slot"]["type_id"]]["shape"]
        return sum_tag(field_shape)!="String" or string_condition(profile,payload(field_shape),branch["wire_tag"]) is not None
    return any(_internal_tag(branch) and invalid(branch) for branch in _branches(library))


def _lb18(library):
    return any(_duplicate_selection(branch,other) for spec in _specs(library,"TaggedUnion") for index,branch in enumerate(spec["branches"]) for other in spec["branches"][index+1:])


def _lb19(library):
    profile=prepare_profile(library["profile"])
    def values(spec): return [*([spec["const_value"]] if spec["const_value"] is not None else []),*(spec["enum_values"] or []),*([spec["default_value"]] if spec["default_value"] is not None else [])]
    return (any(string_condition(profile,spec,value) is not None for spec in _specs(library,"String") for value in values(spec))
        or any(integer_condition(profile,spec,integer(value)) is not None for spec in _specs(library,"Integer") for value in values(spec)))


_LIBRARY_PREDICATES=(("LB02",_lb02),("LB03",_lb03),("LB04",_lb04),("LB05",_lb05),("LB06",_lb06),("LB07",_lb07),("LB08",_lb08),("LB09",_lb09),("LB10",_lb10),("LB11",_lb11),("LB12",_lb12),("LB13",_lb13),("LB14",_lb14),("LB15",_lb15),("LB16",_lb16),("LB17",_lb17),("LB18",_lb18),("LB19",_lb19))


def _library_predicate(library):
    if not _library_declaration_valid(library): return "LB01"
    return next((predicate for predicate,violated in _LIBRARY_PREDICATES if violated(library)),None)


def checkLibrary(library):
    checked_profile=checkProfile(library["profile"])
    predicate=_library_predicate(library)
    if predicate is not None: _fail(library["identity"],predicate,["library"])
    return CheckedLibrary(_checked_value_token, copy.deepcopy(library),checked_profile)


def _signature_ref(type_id):
    return {
        "source": {
            "repository": "ncoh-type-signatures", "revision": "1", "path": "",
            "content_digest": "", "document_id": "", "declared_revision": None,
        },
        "definition_name": type_id,
        "pointer": [],
    }



def _semantic_shape(shape):
    shape = copy.deepcopy(shape)
    kind, spec = sum_tag(shape), payload(shape)
    def slot(contract):
        return {**{key: item for key, item in contract.items() if key != "type_id"},
                "type_ref": _signature_ref(contract["type_id"])}
    if kind == "Product":
        spec["fields"] = [{**field, "slot": slot(field["slot"])} for field in spec["fields"]]
        if sum_tag(spec["extras"]) == "Allow":
            extras = payload(spec["extras"])
            extras["value"] = slot(extras["value"])
    elif kind == "Array":
        spec["item"] = slot(spec["item"])
    elif kind == "Alias":
        spec["target"] = _signature_ref(spec["target"])
    elif kind == "TaggedUnion":
        spec["branches"] = [{**branch, "target": _signature_ref(branch["target"])} for branch in spec["branches"]]
    return shape


def _graph(library):
    return {
        "profile": copy.deepcopy(library["profile"]),
        "nodes": [
            {"id": node["id"], "reference": _signature_ref(node["id"]), "shape": _semantic_shape(node["shape"])}
            for node in library["nodes"]
        ],
        "definitions": copy.deepcopy(library["definitions"]),
    }


def _lean_number_parts(spelling):
    sign,whole,fraction,marker,exponent_sign,exponent=json_number_grammar(spelling)
    digits=(whole+fraction).lstrip("0") or "0"; places=len(fraction)
    if marker:
        count=integer_from_digits(exponent)
        if exponent_sign=="-": places+=count
        elif count>places:
            if digits!="0": digits+="0"*(count-places)
            places=0
        else: places-=count
    return ("-" if sign and digits!="0" else "")+digits,places


def _lean_number_text(mantissa,places):
    if places==0: return mantissa
    sign="-" if mantissa.startswith("-") else ""
    magnitude=mantissa.lstrip("-")
    exponent=min(9+len(magnitude)-places,0)
    width=places-abs(exponent)
    padded=magnitude.zfill(width)
    left=padded[:len(padded)-width] or "0"
    remainder=padded[len(padded)-width:]
    if exponent==0 and not remainder.strip("0"): return sign+left
    return sign+left+"."+remainder.rstrip("0")+("e"+str(exponent) if exponent else "")


def _canonical_number(spelling):
    return _lean_number_text(*_lean_number_parts(spelling))


def _canonical_number_value(value):
    if isinstance(value,DecimalLiteral): return _canonical_number(value.spelling)
    if isinstance(value,Decimal): return _canonical_number(str(value))
    if type(value) is float: return _canonical_number(json.dumps(value,allow_nan=False))
    raise TypeError("JSON value required")


def _canonical(value): return canonical_json(value,_canonical_number_value)
def _sha(value): return hashlib.sha256(_canonical(value).encode()).hexdigest()


@dataclass(frozen=True)
class _GenerationEvidence:
    graph: Any
    provenance: Any
    metadata: Any
    entrypoints: Any
    composition: Any


@dataclass(frozen=True)
class _LibraryMetadata:
    signature_schema: str
    library_identity: str
    library_revision: str
    profile: Any


@dataclass(frozen=True)
class _GenerationCoordinate:
    signature_schema: str
    profile: Any
    graph_sha256: str
    provenance_sha256: str
    metadata_sha256: str
    problem_sha256: str | None
    observations_sha256: str | None
    entrypoints_sha256: str
    actual_library_metadata: _LibraryMetadata


def _generation_evidence(library,entrypoints,composition):
    definitions=[]
    outcome_origins=[]
    for definition in sorted(library["definitions"],key=lambda row:row["id"]):
        projected=copy.deepcopy(definition)
        shape=projected["shape"]
        if sum_tag(shape)=="Operation":
            operation=payload(shape)
            for outcome in sorted(operation["outcomes"],key=lambda row:row["id"]):
                cause=outcome["cause"]
                outcome_origins.append({"definition":definition["id"],"outcome":outcome["id"],"cause":copy.deepcopy(cause)})
                outcome["cause"]={"tag":sum_tag(cause)}
        definitions.append(projected)
    graph={"profile":library["profile"],"nodes":sorted(library["nodes"],key=lambda row:row["id"]),"definitions":definitions}
    provenance_rows=[]
    for binding in sorted(library["provenance"],key=lambda row:_canonical(row["target"])):
        projected=copy.deepcopy(binding)
        projected["origins"]=sorted(projected["origins"],key=_canonical)
        provenance_rows.append(projected)
    provenance={"sources":sorted(library["sources"],key=lambda row:(row["repository"],row["revision"],row["path"],row["content_digest"])),
                "provenance":provenance_rows,"outcome_origins":outcome_origins}
    groups=[]
    for group in sorted(library["groups"],key=lambda row:row["id"]):
        projected=copy.deepcopy(group); projected["members"]=sorted(projected["members"]); groups.append(projected)
    metadata={"groups":groups,"annotations":sorted(library["annotations"],key=lambda row:(_canonical(row["target"]),row["key"],_canonical(row["value"])))}
    return _GenerationEvidence(graph,provenance,metadata,sorted(entrypoints,key=lambda row:row["identity"]),composition)


def _observations_of(composition):
    return None if composition is None else GoalObservations.of_composition(composition)


def _composition_outcome(library,graph_sha256,composition,library_basis):
    from .signature_composition_wire import CompositionInputRejected, _admit_composition
    try: return _admit_composition(library,graph_sha256,composition,library_basis)
    except (CompositionInputRejected,WireFailure) as error: return error


def _certificate_observations(outcome,composition):
    if composition is None: return None
    if isinstance(outcome,Exception): return GoalObservations.of_composition(composition)
    return GoalObservations.of_plan(composition)


def _observations_digest(composition):
    observations=_observations_of(composition)
    return None if observations is None else _sha(observations._value)


def _basis_of(library,evidence):
    return {"signature_schema":library["schema"],"library_identity":library["identity"],"library_revision":library["revision"],"profile":library["profile"]["reference"],"graph_sha256":_sha(evidence.graph),"provenance_sha256":_sha(evidence.provenance),"metadata_sha256":_sha(evidence.metadata),"problem_sha256":None if evidence.composition is None else _sha(evidence.composition),"observations_sha256":_observations_digest(evidence.composition),"entrypoints_sha256":_sha(evidence.entrypoints)}


def signature_basis(library,entrypoints,composition=None):
    return _basis_of(library,_generation_evidence(library,entrypoints,composition))


GENERATION_RULE="ncoh-checked-generation@5"
CERTIFICATE_OPERATION="admit_signature_generation"
_SCOPE=nqc.CrossLanguage("sha256")


def _metadata_of_basis(basis):
    return _LibraryMetadata(basis["signature_schema"],basis["library_identity"],basis["library_revision"],basis["profile"])


def _coordinate(basis,metadata):
    return _GenerationCoordinate(basis["signature_schema"],basis["profile"],basis["graph_sha256"],basis["provenance_sha256"],basis["metadata_sha256"],basis["problem_sha256"],basis["observations_sha256"],basis["entrypoints_sha256"],metadata)


def _projection_digests(entrypoints,graph,metadata,problem,observations,provenance):
    digests={"entrypoints":nqc.ProjectionDigest(entrypoints,_SCOPE),"graph":nqc.ProjectionDigest(graph,_SCOPE),"metadata":nqc.ProjectionDigest(metadata,_SCOPE),"provenance":nqc.ProjectionDigest(provenance,_SCOPE)}
    if problem is not None: digests["problem"]=nqc.ProjectionDigest(problem,_SCOPE)
    if observations is not None: digests["observations"]=nqc.ProjectionDigest(observations,_SCOPE)
    return digests


class _GenerationRule:
    def __call__(self,source,coordinate,observations,evidence):
        return _projection_digests(_sha(evidence.entrypoints),_sha(evidence.graph),_sha(evidence.metadata),None if evidence.composition is None else _sha(evidence.composition),_observations_digest(evidence.composition),_sha(evidence.provenance))


def _generation_table():
    table=nqc.RuleTable.of([(GENERATION_RULE,_GenerationRule())])
    if not isinstance(table,nqc.RuleTable): raise RuntimeError("duplicate generation rule")
    return table


def admit_signature_generation(expected_basis,exchange):
    if type(expected_basis) is not ExpectedSignatureBasis: raise TypeError("expected basis required")
    try:
        value=decode_generation(exchange)
    except WireFailure as error:
        if error.kind == "UnsupportedSchema": raise UnsupportedSchema(error.observed) from None
        raise Generation(error) from None
    identities=[entry["identity"] for entry in value["entrypoints"]]
    if not identities and value["composition"] is None: raise EntrypointsEmpty()
    if any(identity=="" for identity in identities): raise EntrypointIdentityEmpty()
    seen=set()
    for identity in identities:
        if identity in seen: raise EntrypointDuplicate(identity)
        seen.add(identity)
    definitions={row["id"] for row in value["signatures"]["definitions"]}
    for entry in value["entrypoints"]:
        if entry["definition"] not in definitions: raise UnresolvedEntrypoint((entry["identity"],entry["definition"]))
    try: checked=checkLibrary(value["signatures"])
    except DeclarationFailure as error: raise Library(error) from None
    declared=value["basis"]; expected=expected_basis._basis; library=value["signatures"]
    composition=value["composition"]
    outcome=None if composition is None else _composition_outcome(library,expected["graph_sha256"],composition,signature_basis(library,[]))
    certificate=nqc.Certificate(
        rule_revision=value["schema"],
        source=nqc.SourceRef(declared["library_identity"],declared["library_revision"]),
        coordinate=_coordinate(declared,_LibraryMetadata(library["schema"],library["identity"],library["revision"],library["profile"]["reference"])),
        digests=_projection_digests(declared["entrypoints_sha256"],declared["graph_sha256"],declared["metadata_sha256"],declared["problem_sha256"],declared["observations_sha256"],declared["provenance_sha256"]),
        residuals=nqc.ResidualSet(()),
        observations=_certificate_observations(outcome,composition),
        evidence=_generation_evidence(library,value["entrypoints"],value["composition"]),
    )
    expectation=nqc.Expected(
        rule_revision=GENERATION_RULE,
        source=nqc.SourceRef(expected["library_identity"],expected["library_revision"]),
        coordinate=_coordinate(expected,_metadata_of_basis(declared)),
        observations=expected_basis.observations,
        residuals=nqc.ResidualSet(()),
    )
    admission=nqc.admit(_generation_table(),certificate,expectation,CERTIFICATE_OPERATION)
    if not isinstance(admission,nqc.Checked): raise Certificate(admission)
    admitted_composition=None
    if composition is not None:
        from .signature_composition_wire import CompositionInputRejected
        if isinstance(outcome,CompositionInputRejected): raise CompositionInput(outcome.failure) from None
        if isinstance(outcome,WireFailure): raise Wire(outcome) from None
        admitted_composition=outcome
    return CheckedSignatureGeneration(_checked_value_token,value,checked,admitted_composition,admission)


def decode_profile_artifact(expected,expected_sources,trusted_bytes,artifact_bytes):
    if not expected.get("content_digest") or artifact_bytes!=trusted_bytes:
        raise ProfileDigestMismatch()
    value=wire_document(artifact_bytes)
    VALUE_PROFILE(value,"$")
    if value["reference"]!=expected or value["source_refs"]!=expected_sources:
        raise ProfileBasisMismatch()
    return checkProfile(value).value


def value_semantic_profile(profile,reference):
    value=copy.deepcopy(profile); value["reference"]=copy.deepcopy(reference); return checkProfile(value).value
