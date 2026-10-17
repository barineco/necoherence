# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Wire decoding and checked admission for semantic signature libraries."""
from __future__ import annotations

import copy
import hashlib
import json
import re
from dataclasses import dataclass
from typing import Any, TypeAlias

from .signature_values import ValueContext, WireFailure, integer, payload, recognize_format, sum_tag, wrapEncode

TypeSignatureLibrary: TypeAlias = dict[str, Any]


class DeclarationFailure(ValueError):
    def __init__(self, reference, predicate, location, observed=None):
        self.reference = reference
        self.predicate = predicate
        self.location = tuple(location)
        self.observed = observed
        super().__init__(f"{predicate} at {'/'.join(location)}")


class AdmissionFailure(ValueError):
    def __init__(self, kind, cause=None):
        self.kind = kind
        self.cause = cause
        super().__init__(kind if cause is None else f"{kind}: {cause}")


GenerationFailure = AdmissionFailure


@dataclass(frozen=True, slots=True)
class CheckedProfile:
    value: dict


@dataclass(frozen=True, slots=True)
class CheckedLibrary:
    value: dict
    profile: CheckedProfile


class ExpectedSignatureBasis:
    def __init__(self, basis):
        self._basis = copy.deepcopy(basis)


class CheckedSignatureGeneration:
    def __init__(self, input_value, checked_library):
        self._input = input_value
        self.checked_library = checked_library
        self._graph = _graph(input_value["signatures"])
        self._values = ValueContext(self._graph)

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


_RECORD_KEYS = {
    "input": {"schema", "basis", "signatures", "composition", "entrypoints"},
    "basis": {"signature_schema", "library_identity", "library_revision", "profile", "graph_sha256", "provenance_sha256", "metadata_sha256", "problem_sha256", "entrypoints_sha256"},
    "profile_ref": {"identity", "revision", "content_digest"},
    "source": {"repository", "revision", "path", "content_digest"},
    "profile": {"reference", "source_refs", "integer_domains", "default_integer_domain", "numbers", "grapheme_rules", "format_bindings", "bytes_policy", "wrappers", "tag"},
    "library": {"schema", "identity", "revision", "profile", "sources", "provenance", "groups", "annotations", "nodes", "definitions"},
    "entrypoint": {"identity", "definition"},
}


def _closed(value, expected, path):
    if type(value) is not dict: raise WireFailure("Syntax", path, value)
    actual = set(value)
    if actual != set(expected):
        extra = sorted(actual - set(expected)); missing = sorted(set(expected) - actual)
        raise WireFailure("UnknownField" if extra else "MissingField", path, extra or missing)


def _string(value, path):
    if type(value) is not str: raise WireFailure("Syntax", path, value)


def _canonical_integer(value, path, natural=False):
    _string(value, path)
    try: result = integer(value)
    except ValueError: raise WireFailure("Syntax", path, value) from None
    if natural and result < 0: raise WireFailure("Syntax", path, value)


def _sum(value, tags, path):
    if type(value) is not dict or type(value.get("tag")) is not str: raise WireFailure("Syntax", path, value)
    name = value["tag"]
    if name not in tags: raise WireFailure("UnknownTag", path, name)
    form = tags[name]
    expected = {"tag"} if form is None else {"tag", "value"} if form == "value" else {"tag", "fields"}
    _closed(value, expected, path)
    return name, None if form is None else value[form]


def _profile_ref(value, path):
    _closed(value, _RECORD_KEYS["profile_ref"], path)
    for key in _RECORD_KEYS["profile_ref"]: _string(value[key], f"{path}.{key}")


def _source(value, path):
    _closed(value, _RECORD_KEYS["source"], path)
    for key in _RECORD_KEYS["source"]: _string(value[key], f"{path}.{key}")


def _format_rule(rule, path):
    forms = {"Literal":"value", "Sequence":"value", "Optional":"value", "Labels":"fields", "Bounded":"fields", "AsciiDfa":"value", "Identifier":"fields", "Timestamp":"value", "AbsoluteUri":"fields", "LanguageTag":"fields", "Choice":"value", "Text":None, "Not":"value"}
    kind, value = _sum(rule, forms, path)
    if kind in ("Literal",): _string(value, path + ".value")
    elif kind in ("Sequence", "Choice"):
        if type(value) is not list: raise WireFailure("Syntax", path + ".value", value)
        for index, item in enumerate(value): _format_rule(item, f"{path}.value[{index}]")
    elif kind in ("Optional", "Not"): _format_rule(value, path + ".value")
    elif kind == "Labels":
        _closed(value, {"separator","min_count","max_count","total_max","rule"}, path + ".fields")
        _canonical_integer(value["min_count"], path + ".fields.min_count", True)
        for key in ("max_count","total_max"):
            if value[key] is not None: _canonical_integer(value[key], f"{path}.fields.{key}", True)
        _format_rule(value["rule"], path + ".fields.rule")
    elif kind == "Bounded":
        _closed(value, {"unit","maximum","rule"}, path + ".fields"); _sum(value["unit"], {"Utf8Bytes":None,"UnicodeScalars":None,"Graphemes":None}, path + ".fields.unit"); _canonical_integer(value["maximum"], path + ".fields.maximum", True); _format_rule(value["rule"], path + ".fields.rule")
    elif kind == "Identifier":
        _closed(value, {"first_alphabet","rest_alphabet","exact_length","min_length","max_length","forbidden"}, path + ".fields")
    elif kind in ("AbsoluteUri", "LanguageTag"):
        _closed(value, {"max_bytes"} if kind == "AbsoluteUri" else {"grandfathered"}, path + ".fields")


def _format_use(value, path):
    kind, item = _sum(value, {"Named":"value","Inline":"value"}, path)
    _string(item, path + ".value") if kind == "Named" else _format_rule(item, path + ".value")


def _integer_spec(value, path):
    _closed(value, {"domain","minimum","maximum","const_value","enum_values","default_value"}, path)
    for key in ("minimum","maximum","const_value","default_value"):
        if value[key] is not None: _canonical_integer(value[key], f"{path}.{key}")
    if value["enum_values"] is not None:
        for index, item in enumerate(value["enum_values"]): _canonical_integer(item, f"{path}.enum_values[{index}]")


def _string_spec(value, path):
    _closed(value, {"format","lengths","wrapper","const_value","enum_values","examples","default_value"}, path)
    if value["format"] is not None: _format_use(value["format"], path + ".format")
    for index, bound in enumerate(value["lengths"]):
        _closed(bound, {"unit","minimum","maximum"}, f"{path}.lengths[{index}]")
        _sum(bound["unit"], {"Utf8Bytes":None,"UnicodeScalars":None,"Graphemes":None}, f"{path}.lengths[{index}].unit")
        for key in ("minimum","maximum"):
            if bound[key] is not None: _canonical_integer(bound[key], f"{path}.lengths[{index}].{key}", True)


def _leaf(value, path):
    kind, spec = _sum(value, {"String":"value","Integer":"value"}, path)
    _string_spec(spec, path + ".value") if kind == "String" else _integer_spec(spec, path + ".value")


def _profile(profile, path):
    _closed(profile, _RECORD_KEYS["profile"], path); _profile_ref(profile["reference"], path + ".reference")
    for index, source in enumerate(profile["source_refs"]): _source(source, f"{path}.source_refs[{index}]")
    for index, binding in enumerate(profile["integer_domains"]):
        here=f"{path}.integer_domains[{index}]"; _closed(binding,{"name","reference","range","forms"},here); _profile_ref(binding["reference"],here+".reference"); kind, fields=_sum(binding["range"],{"Unbounded":None,"Inclusive":"fields"},here+".range")
        if fields is not None:
            _closed(fields,{"minimum","maximum"},here+".range.fields"); _canonical_integer(fields["minimum"],here+".range.fields.minimum"); _canonical_integer(fields["maximum"],here+".range.fields.maximum")
        for j, form in enumerate(binding["forms"]): _sum(form,{"Number":None,"IntegralDecimal":None,"DecimalString":None},f"{here}.forms[{j}]")
    _closed(profile["numbers"], {"decimals"}, path + ".numbers")
    for index, binding in enumerate(profile["format_bindings"]):
        here=f"{path}.format_bindings[{index}]"; _closed(binding,{"name","reference","rule"},here); _profile_ref(binding["reference"],here+".reference"); _format_rule(binding["rule"],here+".rule")
    if profile["bytes_policy"] is not None:
        policy=profile["bytes_policy"]; _closed(policy,{"reference","padding_optional","alphabet","strict_pad_bits","wrapper"},path+".bytes_policy"); _profile_ref(policy["reference"],path+".bytes_policy.reference"); _sum(policy["alphabet"],{"Standard":None,"UrlSafe":None,"Either":None},path+".bytes_policy.alphabet")
    for index, wrapper in enumerate(profile["wrappers"]):
        here=f"{path}.wrappers[{index}]"; _closed(wrapper,{"name","key","payload"},here); kind,item=_sum(wrapper["payload"],{"Bytes":None,"Text":"value"},here+".payload")
    if profile["tag"] is not None:
        model=profile["tag"]; _closed(model,{"key","format","sealed"},path+".tag")
        for index, form in enumerate(model["sealed"]):
            here=f"{path}.tag.sealed[{index}]"; _closed(form,{"tag","fields","extras"},here); _sum(form["extras"],{"Reject":None,"Any":None},here+".extras")
            for j, field in enumerate(form["fields"]): _closed(field,{"key","required","leaf"},f"{here}.fields[{j}]"); _leaf(field["leaf"],f"{here}.fields[{j}].leaf")


def _shape(value, path):
    forms={"Unknown":"value","Unit":None,"Boolean":"value","Integer":"value","Decimal":"value","String":"value","Bytes":"value","Product":"value","Array":"value","TaggedUnion":"value","Sealed":"fields","Never":None,"Alias":"fields","RawBody":"fields","Opaque":"fields"}
    kind,spec=_sum(value,forms,path)
    if kind=="Unknown": _sum(spec,{"Any":None,"OrdinaryObject":None},path+".value")
    elif kind=="Boolean": _closed(spec,{"const_value","default_value"},path+".value")
    elif kind=="Integer": _integer_spec(spec,path+".value")
    elif kind=="Decimal":
        _closed(spec,{"minimum","maximum"},path+".value")
        for name in ("minimum","maximum"):
            if spec[name] is not None: _closed(spec[name],{"mantissa","scale","exclusive"},f"{path}.value.{name}")
    elif kind=="String": _string_spec(spec,path+".value")
    elif kind=="Bytes": _closed(spec,{"minimum","maximum"},path+".value")
    elif kind=="Product":
        _closed(spec,{"fields","extras"},path+".value")
        for index, field in enumerate(spec["fields"]): _closed(field,{"wire_name","slot"},f"{path}.value.fields[{index}]"); _closed(field["slot"],{"type_id","required","nullable"},f"{path}.value.fields[{index}].slot")
        ek,ev=_sum(spec["extras"],{"Reject":None,"Allow":"fields"},path+".value.extras")
        if ev is not None: _closed(ev,{"key_format","value"},path+".value.extras.fields"); _closed(ev["value"],{"type_id","nullable"},path+".value.extras.fields.value")
    elif kind=="Array": _closed(spec,{"item","min_length","max_length"},path+".value"); _closed(spec["item"],{"type_id","nullable"},path+".value.item")
    elif kind=="TaggedUnion":
        _closed(spec,{"branches"},path+".value")
        for index, branch in enumerate(spec["branches"]): _closed(branch,{"target","wire_tag","selector"},f"{path}.value.branches[{index}]"); _sum(branch["selector"],{"InternalTag":None,"MemberShape":"value","Kind":"value","Otherwise":None},f"{path}.value.branches[{index}].selector")
    elif kind=="Sealed":
        _closed(spec,{"tag","refinements"},path+".fields")
        for index,row in enumerate(spec["refinements"]): _closed(row,{"key","leaf"},f"{path}.fields.refinements[{index}]"); _leaf(row["leaf"],f"{path}.fields.refinements[{index}].leaf")
    elif kind in ("Alias","RawBody","Opaque"): _closed(spec,{"target"} if kind=="Alias" else {"encoding"} if kind=="RawBody" else {"type_name"},path+".fields")


def _definition(value,path):
    _closed(value,{"id","wire_identity","shape"},path)
    kind,spec=_sum(value["shape"],{"Value":"value","Symbol":"value","Operation":"value","Message":"value"},path+".shape")
    if kind=="Operation":
        _closed(spec,{"effect","inputs","outcomes"},path+".shape.value")
        _sum(spec["effect"],{"HttpRequestResponse":None,"DataOnly":None},path+".shape.value.effect")
        for index,port in enumerate(spec["inputs"]):
            _closed(port,{"id","contract"},f"{path}.shape.value.inputs[{index}]")
            _closed(port["contract"],{"type_id","required","nullable"},f"{path}.shape.value.inputs[{index}].contract")
        for index,outcome in enumerate(spec["outcomes"]):
            here=f"{path}.shape.value.outcomes[{index}]"
            _closed(outcome,{"id","form","cause","value_ports","produced_resources"},here)
            _sum(outcome["form"],{"Success":None,"DeclaredFailure":None},here+".form")
            _sum(outcome["cause"],{"ValueContract":"fields","ExternalCondition":"fields"},here+".cause")


def _library(library,path):
    _closed(library,_RECORD_KEYS["library"],path); _profile(library["profile"],path+".profile")
    for index,source in enumerate(library["sources"]): _source(source,f"{path}.sources[{index}]")
    for index,node in enumerate(library["nodes"]): _closed(node,{"id","shape"},f"{path}.nodes[{index}]"); _shape(node["shape"],f"{path}.nodes[{index}].shape")
    for index,definition in enumerate(library["definitions"]): _definition(definition,f"{path}.definitions[{index}]")


def _wire_document(value):
    from .signature_values import decode_wire_json
    if isinstance(value,(bytes,bytearray)):
        try: value=bytes(value).decode("utf-8")
        except UnicodeDecodeError as error: raise WireFailure("Syntax","$",str(error)) from None
    return decode_wire_json(value) if type(value) is str else copy.deepcopy(value)


def _canonical_wire(value):
    return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(",",":"))


def _string_list(value,path):
    if type(value) is not list: raise WireFailure("Syntax",path,value)
    for index,item in enumerate(value): _string(item,f"{path}[{index}]")


def _source_ref(value,path):
    _closed(value,{"repository","revision","path","content_digest","document_id","declared_revision"},path)
    for key in ("repository","revision","path","content_digest","document_id"): _string(value[key],f"{path}.{key}")
    if value["declared_revision"] is not None: _canonical_integer(value["declared_revision"],path+".declared_revision")


def _type_ref(value,path):
    _closed(value,{"source","definition_name","pointer"},path)
    _source_ref(value["source"],path+".source")
    _string(value["definition_name"],path+".definition_name")
    _string_list(value["pointer"],path+".pointer")


def _definition_ref(value,path):
    _closed(value,{"source","name"},path)
    _source_ref(value["source"],path+".source")
    _string(value["name"],path+".name")


def _occurrence_ref(value,path):
    _closed(value,{"source","pointer"},path)
    _source_ref(value["source"],path+".source")
    _string_list(value["pointer"],path+".pointer")


def _exact_json(value,path):
    if type(value) is not dict or type(value.get("tag")) is not str:
        raise WireFailure("Syntax",path,value)
    kind=value["tag"]
    if kind=="Null":
        _closed(value,{"tag"},path)
    elif kind=="Bool":
        _closed(value,{"tag","value"},path)
        if type(value["value"]) is not bool: raise WireFailure("Syntax",path+".value",value["value"])
    elif kind=="Integer":
        _closed(value,{"tag","value"},path); _canonical_integer(value["value"],path+".value")
    elif kind=="String":
        _closed(value,{"tag","value"},path); _string(value["value"],path+".value")
    elif kind=="Decimal":
        _closed(value,{"tag","text"},path); _string(value["text"],path+".text")
        if re.fullmatch(r"-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?",value["text"]) is None:
            raise WireFailure("Syntax",path+".text",value["text"])
    elif kind=="Array":
        _closed(value,{"tag","items"},path)
        if type(value["items"]) is not list: raise WireFailure("Syntax",path+".items",value["items"])
        for index,member in enumerate(value["items"]): _exact_json(member,f"{path}.items[{index}]")
    elif kind=="Object":
        _closed(value,{"tag","members"},path)
        if type(value["members"]) is not list: raise WireFailure("Syntax",path+".members",value["members"])
        for index,member in enumerate(value["members"]):
            here=f"{path}.members[{index}]"; _closed(member,{"key","value"},here); _string(member["key"],here+".key"); _exact_json(member["value"],here+".value")
    else:
        raise WireFailure("UnknownTag",path+".tag",kind)


def _signature_basis(value,path="$"):
    _closed(value,_RECORD_KEYS["basis"],path)
    for key in ("signature_schema","library_identity","library_revision","graph_sha256","provenance_sha256","metadata_sha256","entrypoints_sha256"):
        _string(value[key],f"{path}.{key}")
    _profile_ref(value["profile"],path+".profile")
    if value["problem_sha256"] is not None: _string(value["problem_sha256"],path+".problem_sha256")


def decode_profile(value):
    decoded=_wire_document(value)
    _profile(decoded,"$")
    return checkProfile(decoded).value


def encode_profile(value):
    return _canonical_wire(decode_profile(value))


def decode_library(value):
    decoded=_wire_document(value)
    _library(decoded,"$")
    return checkLibrary(decoded).value


def encode_library(value):
    return _canonical_wire(decode_library(value))


def decode_diagnostic(value):
    decoded=_wire_document(value)
    _closed(decoded,{"type_ref","definition_ref","origin","value_path","condition","observed","reference_trace"},"$")
    _type_ref(decoded["type_ref"],"$.type_ref")
    _definition_ref(decoded["definition_ref"],"$.definition_ref")
    _occurrence_ref(decoded["origin"],"$.origin")
    if type(decoded["value_path"]) is not list: raise WireFailure("Syntax","$.value_path",decoded["value_path"])
    for index,step in enumerate(decoded["value_path"]):
        here=f"$.value_path[{index}]"; kind,item=_sum(step,{"Field":"value","Index":"value","Variant":"value"},here)
        _canonical_integer(item,here+".value",True) if kind=="Index" else _string(item,here+".value")
    decode_value_condition(decoded["condition"])
    kind,item=_sum(decoded["observed"],{"Absent":None,"Null":None,"Present":"value"},"$.observed")
    if kind=="Present": _exact_json(item,"$.observed.value")
    if type(decoded["reference_trace"]) is not list: raise WireFailure("Syntax","$.reference_trace",decoded["reference_trace"])
    for index,reference in enumerate(decoded["reference_trace"]): _type_ref(reference,f"$.reference_trace[{index}]")
    return decoded


def encode_diagnostic(value):
    return _canonical_wire(decode_diagnostic(value))


def decode_signature_basis(value):
    decoded=_wire_document(value)
    _signature_basis(decoded)
    return decoded


def encode_signature_basis(value):
    return _canonical_wire(decode_signature_basis(value))


def decode_value_condition(value):
    decoded=_wire_document(value)
    kind,item=_sum(decoded,{
        "MissingRequired":None,"NullNotAllowed":None,"WrongValueKind":"value",
        "ConstMismatch":None,"EnumMismatch":None,"BelowMinimum":None,"AboveMaximum":None,
        "IntegerDomain":None,"StringLength":None,"ArrayLength":None,"BytesLength":None,
        "Format":"value","InvalidBytes":None,"InvalidWrapper":"value","InvalidTag":None,
        "ReservedForm":None,"NoBranchSelected":None,"KeyFormat":"value","Uninhabited":None,
        "DuplicateField":"value","UnexpectedField":"value","InvalidDataModel":None,
        "ReferenceCycle":None,
    },"$")
    if kind in {"WrongValueKind","Format","InvalidWrapper","KeyFormat","DuplicateField","UnexpectedField"}:
        _string(item,"$.value")
    return decoded


def encode_value_condition(value):
    return _canonical_wire(decode_value_condition(value))


def decode_generation(exchange):
    value=_wire_document(exchange)
    _closed(value,_RECORD_KEYS["input"],"$")
    _string(value["schema"],"$.schema")
    if value["schema"]!="ncoh-checked-generation@4": raise WireFailure("UnsupportedSchema","$.schema",value["schema"])
    _signature_basis(value["basis"],"$.basis")
    _library(value["signatures"],"$.signatures")
    for index,entry in enumerate(value["entrypoints"]): _closed(entry,_RECORD_KEYS["entrypoint"],f"$.entrypoints[{index}]")
    checkLibrary(value["signatures"])
    return value


def encode_generation(value):
    return _canonical_wire(decode_generation(value))


def _valid_reference(reference): return bool(reference.get("identity")) and bool(reference.get("revision")) and bool(reference.get("content_digest"))
def _unique(values): return all(values) and len(values)==len(set(values))
def _fail(reference,predicate,location,observed=None): raise DeclarationFailure(reference,predicate,location,observed)


def _format_well_formed(rule):
    kind,spec=sum_tag(rule),payload(rule)
    if kind in ("Sequence","Choice"):
        return all(_format_well_formed(item) for item in spec)
    if kind in ("Optional","Not"):
        return _format_well_formed(spec)
    if kind=="Labels":
        return bool(spec["separator"]) and _format_well_formed(spec["rule"])
    if kind=="Bounded":
        return _format_well_formed(spec["rule"])
    if kind=="Identifier":
        minimum=integer(spec["min_length"]); maximum=None if spec["max_length"] is None else integer(spec["max_length"])
        exact=None if spec["exact_length"] is None else integer(spec["exact_length"])
        return bool(spec["first_alphabet"]) and bool(spec["rest_alphabet"]) and (maximum is None or minimum<=maximum) and (exact is None or minimum<=exact and (maximum is None or exact<=maximum))
    if kind=="AsciiDfa":
        count=integer(spec["state_count"])
        return count>0 and integer(spec["initial_state"])<count and all(integer(item)<count for item in spec["accepting_states"])
    return True


def checkProfile(profile):
    reference=profile["reference"]
    if not _valid_reference(reference) or any(not _valid_reference(item["reference"]) for key in ("integer_domains","format_bindings") for item in profile[key]) or profile["bytes_policy"] is not None and not _valid_reference(profile["bytes_policy"]["reference"]): _fail(reference,"PR01",["profile"])
    domains=profile["integer_domains"]
    if not _unique([item["name"] for item in domains]): _fail(reference,"PR02",["integer_domains"])
    if any(sum_tag(item["range"])=="Inclusive" and integer(payload(item["range"])["minimum"])>integer(payload(item["range"])["maximum"]) for item in domains): _fail(reference,"PR03",["integer_domains"])
    if any(not item["forms"] for item in domains): _fail(reference,"PR04",["integer_domains"])
    if profile["default_integer_domain"] not in [item["name"] for item in domains]: _fail(reference,"PR05",["default_integer_domain"])
    formats=profile["format_bindings"]
    if not _unique([item["name"] for item in formats]): _fail(reference,"PR06",["format_bindings"])
    if any(not _format_well_formed(item["rule"]) for item in formats): _fail(reference,"PR07",["format_bindings"])
    wrappers=profile["wrappers"]
    if not _unique([item["name"] for item in wrappers]) or not _unique([item["key"] for item in wrappers]): _fail(reference,"PR08",["wrappers"])
    format_names={item["name"] for item in formats}
    if any(sum_tag(item["payload"])=="Text" and payload(item["payload"]) is not None and payload(item["payload"]) not in format_names for item in wrappers): _fail(reference,"PR09",["wrappers"])
    policy=profile["bytes_policy"]
    if policy is not None and policy["wrapper"] is not None and not any(item["name"]==policy["wrapper"] and sum_tag(item["payload"])=="Bytes" for item in wrappers): _fail(reference,"PR10",["bytes_policy","wrapper"])
    model=profile["tag"]
    if model is not None:
        if not model["key"] or model["key"] in [item["key"] for item in wrappers]: _fail(reference,"PR11",["tag","key"])
        if model["format"] is not None and model["format"] not in format_names: _fail(reference,"PR12",["tag","format"])
        format_binding=next((item for item in formats if item["name"]==model["format"]),None) if model["format"] is not None else None
        if not _unique([item["tag"] for item in model["sealed"]]) or format_binding is not None and any(not recognize_format(format_binding["rule"],item["tag"]) for item in model["sealed"]): _fail(reference,"PR13",["tag","sealed"])
        for form in model["sealed"]:
            keys=[field["key"] for field in form["fields"]]
            if not _unique(keys) or model["key"] in keys or any(item["key"] in keys for item in wrappers): _fail(reference,"PR14",["tag","sealed","fields"])
            for field in form["fields"]:
                kind,spec=sum_tag(field["leaf"]),payload(field["leaf"])
                if kind=="String":
                    if spec["wrapper"] is not None and not any(item["name"]==spec["wrapper"] and sum_tag(item["payload"])=="Text" for item in wrappers): _fail(reference,"PR15",["tag","sealed","fields"])
                    if spec["format"] is not None and sum_tag(spec["format"])=="Named" and payload(spec["format"]) not in format_names: _fail(reference,"PR15",["tag","sealed","fields"])
                    if any(bound["minimum"] is not None and bound["maximum"] is not None and integer(bound["minimum"])>integer(bound["maximum"]) for bound in spec["lengths"]): _fail(reference,"PR15",["tag","sealed","fields"])
                elif spec["domain"] is not None and spec["domain"] not in [item["name"] for item in domains]: _fail(reference,"PR15",["tag","sealed","fields"])
    rules=profile.get("grapheme_rules")
    if rules is not None and any(integer(row["last"])<integer(row["first"]) for key in ("properties","extended_pictographic","indic_conjunct") for row in rules[key]): _fail(reference,"PR16",["grapheme_rules"])
    return CheckedProfile(copy.deepcopy(profile))


def _references(shape):
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


def checkLibrary(library):
    checked_profile=checkProfile(library["profile"]); reference=library["identity"]
    node_ids=[node["id"] for node in library["nodes"]]; definition_ids=[row["id"] for row in library["definitions"]]
    if library["schema"]!="ncoh-type-signatures@1" or not reference or not library["revision"] or not _unique(node_ids) or not _unique(definition_ids) or any(child not in node_ids for node in library["nodes"] for child in _references(node["shape"])): _fail(reference,"LB01",["library"])
    if any(child not in node_ids for definition in library["definitions"] for child in _definition_references(definition["shape"])):
        _fail(reference, "LB01", ["library"])
    wrappers=library["profile"]["wrappers"]; model=library["profile"]["tag"]
    nodes={node["id"]:node for node in library["nodes"]}
    context=ValueContext(_graph(library))
    for node in library["nodes"]:
        kind,spec=sum_tag(node["shape"]),payload(node["shape"])
        if kind=="Product":
            names=[field["wire_name"] for field in spec["fields"]]
            if not _unique(names): _fail(reference,"LB02",["library"])
            if any(wrapper["key"] in names for wrapper in wrappers): _fail(reference,"LB03",["library"])
            if sum_tag(spec["extras"])=="Allow":
                key_format=payload(spec["extras"])["key_format"]
                if key_format is not None and sum_tag(key_format)=="Named" and payload(key_format) not in {row["name"] for row in library["profile"]["format_bindings"]}: _fail(reference,"LB12",["library"])
        if kind=="TaggedUnion":
            branches=spec["branches"]
            if len({item["wire_tag"] for item in branches})!=len(branches): _fail(reference,"LB04",["library"])
            if any(sum_tag(item["selector"])=="Otherwise" and i+1!=len(branches) for i,item in enumerate(branches)): _fail(reference,"LB05",["library"])
            if any(not item["wire_tag"] for item in branches): _fail(reference,"LB06",["library"])
            if model is not None and any(sum_tag(item["selector"])=="InternalTag" and model["format"] is not None and not recognize_format(next(row["rule"] for row in library["profile"]["format_bindings"] if row["name"]==model["format"]),item["wire_tag"]) for item in branches): _fail(reference,"LB07",["library"])
            for branch in branches:
                if sum_tag(branch["selector"])=="InternalTag" and model is not None:
                    target=nodes[branch["target"]]
                    declared=any(form["tag"]==branch["wire_tag"] for form in model["sealed"])
                    shaped=sum_tag(target["shape"])=="Sealed" and payload(target["shape"])["tag"]==branch["wire_tag"]
                    if declared!=shaped: _fail(reference,"LB08",["library"])
                if sum_tag(branch["selector"])=="MemberShape":
                    tests=payload(branch["selector"]); keys=[test["key"] for test in tests]
                    if not _unique(keys) or any(sum_tag(test["test"])=="Format" and payload(test["test"]) not in {row["name"] for row in library["profile"]["format_bindings"]} for test in tests): _fail(reference,"LB09",["library"])
            if any(sum_tag(item["selector"])=="InternalTag" and sum_tag(nodes[item["target"]]["shape"]) not in ("Product","Sealed") for item in branches): _fail(reference,"LB11",["library"])
            selectors=[json.dumps([item["selector"], item["wire_tag"]] if sum_tag(item["selector"])=="InternalTag" else item["selector"],sort_keys=True) for item in branches]
            if len(set(selectors))!=len(selectors): _fail(reference,"LB18",["library"])
        if kind=="Sealed":
            form=None if model is None else next((row for row in model["sealed"] if row["tag"]==spec["tag"]),None)
            refinements=spec["refinements"]
            if form is None or not _unique([row["key"] for row in refinements]): _fail(reference,"LB10",["library"])
            declared={row["key"]:sum_tag(row["leaf"]) for row in form["fields"]}
            if any(declared.get(row["key"])!=sum_tag(row["leaf"]) for row in refinements): _fail(reference,"LB10",["library"])
        if kind=="String":
            if spec["wrapper"] is not None and not any(row["name"]==spec["wrapper"] and sum_tag(row["payload"])=="Text" for row in wrappers): _fail(reference,"LB13",["library"])
            if spec["format"] is not None and sum_tag(spec["format"])=="Named" and payload(spec["format"]) not in {row["name"] for row in library["profile"]["format_bindings"]}: _fail(reference,"LB13",["library"])
            if any(bound["minimum"] is not None and bound["maximum"] is not None and integer(bound["minimum"])>integer(bound["maximum"]) for bound in spec["lengths"]): _fail(reference,"LB13",["library"])
        if kind in ("Array","Bytes") and spec.get("min_length",spec.get("minimum")) is not None and spec.get("max_length",spec.get("maximum")) is not None and integer(spec.get("min_length",spec.get("minimum")))>integer(spec.get("max_length",spec.get("maximum"))): _fail(reference,"LB16",["library"])
        if kind=="Integer":
            if spec["minimum"] is not None and spec["maximum"] is not None and integer(spec["minimum"])>integer(spec["maximum"]): _fail(reference,"LB14",["library"])
            if spec["domain"] is not None and spec["domain"] not in {row["name"] for row in library["profile"]["integer_domains"]}: _fail(reference,"LB14",["library"])
        if kind=="Decimal" and spec["minimum"] is not None and spec["maximum"] is not None:
            if integer(spec["minimum"]["scale"])!=integer(spec["maximum"]["scale"]) or integer(spec["maximum"]["mantissa"])<integer(spec["minimum"]["mantissa"]): _fail(reference,"LB15",["library"])
        if kind=="TaggedUnion" and model is not None:
            for branch in spec["branches"]:
                if sum_tag(branch["selector"])=="InternalTag":
                    target=nodes[branch["target"]]
                    if sum_tag(target["shape"])=="Product":
                        tag_field=next((item for item in payload(target["shape"])["fields"] if item["wire_name"]==model["key"]),None)
                        if tag_field is None or sum_tag(nodes[tag_field["slot"]["type_id"]]["shape"])!="String": _fail(reference,"LB17",["library"])
                        try: context.validate(tag_field["slot"]["type_id"],branch["wire_tag"])
                        except Exception as error: _fail(reference,"LB17",["library"],str(error))
    for node in library["nodes"]:
        kind,spec=sum_tag(node["shape"]),payload(node["shape"])
        values=[]
        if kind in ("String","Integer"):
            values=[*([spec["const_value"]] if spec["const_value"] is not None else []),*(spec["enum_values"] or []),*([spec["default_value"]] if spec["default_value"] is not None else [])]
        for value in values:
            try:
                wire=wrapEncode(library["profile"],spec["wrapper"],value) if kind=="String" and spec["wrapper"] is not None else integer(value) if kind=="Integer" else value
                context.validate(node["id"],wire)
            except Exception as error: _fail(reference,"LB19",["library"],str(error))
    return CheckedLibrary(copy.deepcopy(library),checked_profile)


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


def _canonical(value): return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(",",":"))
def _sha(value): return hashlib.sha256(_canonical(value).encode()).hexdigest()
def signature_basis(library,entrypoints,composition=None):
    definitions=[]
    outcome_origins=[]
    for definition in sorted(library["definitions"],key=lambda row:row["id"]):
        projected=copy.deepcopy(definition)
        shape=projected["shape"]
        if sum_tag(shape)=="Operation":
            operation=payload(shape)
            for outcome in operation["outcomes"]:
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
    return {"signature_schema":library["schema"],"library_identity":library["identity"],"library_revision":library["revision"],"profile":library["profile"]["reference"],"graph_sha256":_sha(graph),"provenance_sha256":_sha(provenance),"metadata_sha256":_sha(metadata),"problem_sha256":None if composition is None else _sha(composition),"entrypoints_sha256":_sha(sorted(entrypoints,key=lambda row:row["identity"]))}


def _check_composition(composition):
    if composition is None: return
    problem=composition["problem"]
    signatures={_canonical(row["reference"]):row for row in problem.get("signatures",[])}
    def visit(tree):
        kind=sum_tag(tree["node"])
        if kind=="Return": return
        if kind=="Guard":
            for _,child in payload(tree["node"])["arms"]: visit(child)
            return
        if kind!="Invoke": raise AdmissionFailure("InvalidCompositionNode")
        details=payload(tree["node"])
        signature=signatures.get(_canonical(details["invocation"]["function"]))
        if signature is None: raise AdmissionFailure("UnresolvedCompositionFunction")
        declared={row["id"] for row in signature["outcomes"]}
        arms={outcome for outcome,_ in details["arms"]}
        empty=set(details.get("empty_outcomes",[]))
        if arms | empty != declared or arms & empty: raise AdmissionFailure("IncompleteBranchCoverage")
        for _,child in details["arms"]: visit(child)
    visit(composition["derivation"]["plan"]["root"])


def admit_signature_generation(expected_basis,exchange):
    if type(expected_basis) is not ExpectedSignatureBasis: raise TypeError("expected basis required")
    try:
        value=decode_generation(exchange)
    except WireFailure as error:
        raise AdmissionFailure(error.kind,error) from None
    except DeclarationFailure as error:
        raise AdmissionFailure("DeclarationFailure",error) from None
    if value["basis"]!=expected_basis._basis: raise AdmissionFailure("BasisMismatch")
    identities=[entry["identity"] for entry in value["entrypoints"]]
    if not _unique(identities) or not identities and value["composition"] is None: raise AdmissionFailure("InvalidEntrypoints")
    definitions={row["id"] for row in value["signatures"]["definitions"]}
    if any(entry["definition"] not in definitions for entry in value["entrypoints"]): raise AdmissionFailure("UnresolvedEntrypoint")
    try: checked=checkLibrary(value["signatures"])
    except DeclarationFailure as error: raise AdmissionFailure("DeclarationFailure",error) from None
    if signature_basis(value["signatures"],value["entrypoints"],value["composition"])!=value["basis"]: raise AdmissionFailure("DigestMismatch")
    _check_composition(value["composition"])
    return CheckedSignatureGeneration(value,checked)


def check_operation_signature(library,signature):
    return checkLibrary(library)


def decode_profile_artifact(expected,expected_sources,trusted_bytes,artifact_bytes):
    if not expected.get("content_digest") or artifact_bytes!=trusted_bytes:
        raise AdmissionFailure("DigestMismatch")
    value=_wire_document(artifact_bytes)
    _profile(value,"$")
    if value["reference"]!=expected or value["source_refs"]!=expected_sources:
        raise AdmissionFailure("BasisMismatch")
    return checkProfile(value).value


def value_semantic_profile(profile,reference):
    value=copy.deepcopy(profile); value["reference"]=copy.deepcopy(reference); return checkProfile(value).value


def internal_form(value): return copy.deepcopy(value)
