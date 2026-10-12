# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

"""Generate Python carriers and codecs from checked semantic declarations."""
from __future__ import annotations

import hashlib
import keyword
import re
import json
from necoherence.signature_values import payload, sum_tag, variant

_RESERVED = {"extras", "decode", "encode", "examples", "__post_init__", "__dict__", "__class__", "__weakref__"}


def _identifier(text, prefix="value"):
    result = re.sub("[^A-Za-z0-9_]", "_", text)
    if not result or not (result[0].isalpha() or result[0] == "_"): result = prefix + "_" + result
    if keyword.iskeyword(result) or result in _RESERVED: result += "_field"
    return result


def _qualified(reference):
    return "T_" + _identifier(reference) + "_" + hashlib.sha256(reference.encode()).hexdigest()[:12]


def _fields(spec):
    return [(field["wire_name"], _identifier(field["wire_name"]), field["slot"]) for field in spec["fields"]]


class _Emitter:
    def __init__(self, checked):
        self.checked = checked
        self.input = checked.input
        self.graph = checked.graph
        self.lines = []
        self.names = {node["id"]: _qualified(node["id"]) for node in self.graph["nodes"]}
        self.sealed_fields = {}
        self.union_names = {}

    def emit(self, *lines): self.lines.extend(lines)

    def header(self):
        self.emit("# SPDX-FileCopyrightText: 2026 barineco", "# SPDX-License-Identifier: MIT", "import base64", "from dataclasses import dataclass", "from decimal import Decimal", "from typing import TypeAlias", "from necoherence.signature_values import DecimalLiteral, HttpBinding, Uninhabited, ValueContext, selectBranch, withMember, wrapDecode, wrapEncode", "", "_ctx = ValueContext(" + repr(self.graph) + ")", "")

    def types(self):
        for node in self.graph["nodes"]:
            reference, shape = node["id"], node["shape"]
            name, kind, spec = self.names[reference], sum_tag(shape), payload(shape)
            if kind == "Never":
                self.emit(f"class {name}(Uninhabited):", "    pass", "")
            elif kind == "Product":
                fields = _fields(spec)
                self.emit("@dataclass(frozen=True, slots=True, kw_only=True)", f"class {name}:")
                for _, attribute, contract in fields:
                    default = " = None" if not contract["required"] or contract["nullable"] else ""
                    self.emit(f"    {attribute}: object{default}")
                if sum_tag(spec["extras"]) == "Allow": self.emit("    extras: tuple[tuple[str, object], ...] = ()")
                self.emit("")
            elif kind == "Sealed":
                model = self.graph["profile"]["tag"]
                form = next(item for item in model["sealed"] if item["tag"] == spec["tag"])
                fields = [(field["key"], _identifier(field["key"]), {"required": field["required"], "nullable": False}) for field in form["fields"]]
                self.sealed_fields[reference] = (model["key"], spec["tag"], fields)
                self.emit("@dataclass(frozen=True, slots=True, kw_only=True)", f"class {name}:")
                for _, attribute, contract in fields:
                    self.emit(f"    {attribute}: object" + ("" if contract["required"] else " = None"))
                if not fields: self.emit("    pass")
                self.emit("")
            elif kind == "TaggedUnion":
                variants=[]
                for branch in spec["branches"]:
                    variant_name=name+"_"+_identifier(branch["wire_tag"]).title()
                    variants.append(variant_name)
                    self.emit("@dataclass(frozen=True, slots=True)", f"class {variant_name}:", "    value: object", "")
                self.union_names[reference]=variants
                self.emit(f"{name} = " + " | ".join(variants), "")
            elif kind == "Decimal": self.emit(f"{name} = DecimalLiteral", "")
            elif kind in ("Bytes", "RawBody"): self.emit(f"{name} = bytes", "")
            elif kind == "Boolean": self.emit(f"{name} = bool", "")
            elif kind == "Integer": self.emit(f"{name} = int", "")
            elif kind == "String": self.emit(f"{name} = str", "")
            elif kind == "Array": self.emit(f"{name} = list", "")
            elif kind == "Unit": self.emit(f"{name} = type(None)", "")
            else: self.emit(f"{name} = object", "")
            self._codec(reference, shape)

    def _codec(self, reference, shape):
        name, kind, spec = self.names[reference], sum_tag(shape), payload(shape)
        self.emit(f"def decode_{name}(value):", f"    _ctx.validate({reference!r}, value)")
        if kind == "Product":
            args = ", ".join(f"{attribute}=value.get({wire!r})" for wire, attribute, _ in _fields(spec))
            self.emit(f"    return {name}({args})")
        elif kind == "Sealed":
            _, _, fields = self.sealed_fields[reference]
            args=", ".join(f"{attribute}=value.get({wire!r})" for wire,attribute,_ in fields)
            self.emit(f"    return {name}({args})")
        elif kind == "TaggedUnion":
            variants=self.union_names[reference]
            self.emit(f"    branch = selectBranch(_ctx, {reference!r}, value)", f"    constructors = ({', '.join(variants)},)", "    return constructors[branch](value)")
        elif kind == "String" and spec["wrapper"] is not None: self.emit(f"    return wrapDecode(_ctx.profile, {spec['wrapper']!r}, value)")
        elif kind in ("Bytes", "RawBody"):
            wrapper=self.graph["profile"]["bytes_policy"]["wrapper"]
            if wrapper is None: self.emit("    text = value")
            else: self.emit(f"    text = wrapDecode(_ctx.profile, {wrapper!r}, value)")
            self.emit("    return base64.b64decode(text.replace('-', '+').replace('_', '/') + '=' * ((-len(text)) % 4))")
        else: self.emit("    return value")
        self.emit("", f"def encode_{name}(value):")
        if kind == "Product":
            self.emit("    result = {}")
            for wire, attribute, contract in _fields(spec):
                if contract["required"]:
                    self.emit(f"    result[{wire!r}] = value.{attribute}")
                else:
                    self.emit(f"    if value.{attribute} is not None: result[{wire!r}] = value.{attribute}")
            self.emit("    if hasattr(value, 'extras'): result.update(value.extras)", f"    _ctx.validate({reference!r}, result)", "    return result")
        elif kind == "Sealed":
            key,tag_value,fields=self.sealed_fields[reference]
            self.emit("    result = {}")
            for wire,attribute,contract in fields:
                if contract["required"]: self.emit(f"    result[{wire!r}] = value.{attribute}")
                else: self.emit(f"    if value.{attribute} is not None: result[{wire!r}] = value.{attribute}")
            self.emit(f"    result = withMember({key!r}, {tag_value!r}, result)", f"    _ctx.validate({reference!r}, result)", "    return result")
        elif kind == "TaggedUnion": self.emit("    result = value.value", f"    _ctx.validate({reference!r}, result)", "    return result")
        elif kind == "String" and spec["wrapper"] is not None: self.emit(f"    result = wrapEncode(_ctx.profile, {spec['wrapper']!r}, value)", f"    _ctx.validate({reference!r}, result)", "    return result")
        elif kind in ("Bytes","RawBody"):
            wrapper=self.graph["profile"]["bytes_policy"]["wrapper"]
            self.emit("    text = base64.b64encode(value).decode('ascii')")
            if wrapper is None: self.emit("    result = text")
            else: self.emit(f"    result = wrapEncode(_ctx.profile, {wrapper!r}, text)")
            self.emit(f"    _ctx.validate({reference!r}, result)", "    return result")
        else: self.emit(f"    _ctx.validate({reference!r}, value)", "    return value")
        examples = spec.get("examples", []) if isinstance(spec, dict) else []
        self.emit("", f"def examples_{name}():", f"    return {tuple(examples)!r}", "")

    def _port_class(self, name, ports):
        fields=[]
        self.emit("@dataclass(frozen=True, slots=True, kw_only=True)", f"class {name}:")
        for port in ports:
            attribute=_identifier(port["id"])
            fields.append((port,attribute))
            default=" = None" if not port["contract"]["required"] or port["contract"]["nullable"] else ""
            self.emit(f"    {attribute}: object{default}")
        if not fields: self.emit("    pass")
        self.emit("", "    def __post_init__(self):")
        if not fields: self.emit("        pass")
        for port,attribute in fields:
            contract=port["contract"]
            self.emit(
                f"        if self.{attribute} is None:",
                f"            {'pass' if contract['nullable'] or not contract['required'] else 'raise TypeError(\"required operation port\")'}",
                "        else:",
                f"            _ctx.validate({contract['type_id']!r}, self.{attribute})",
            )
        self.emit("")
        return {port["id"]:attribute for port,attribute in fields}

    def definitions(self):
        self.entrypoint_values={}
        self.entrypoint_shapes={}
        for definition in self.graph["definitions"]:
            identity=definition["id"]; shape=definition["shape"]; kind,spec=sum_tag(shape),payload(shape)
            if kind in ("Value","Message"):
                target=spec
                self.entrypoint_values[identity]=f"CODECS[{target!r}][0]"
            elif kind=="Symbol":
                name="D_"+_identifier(identity)+"_"+hashlib.sha256(identity.encode()).hexdigest()[:12]
                self.emit(f"{name} = {spec!r}", "")
                self.entrypoint_values[identity]=name
            elif kind=="Operation":
                name="D_"+_identifier(identity)+"_"+hashlib.sha256(identity.encode()).hexdigest()[:12]
                arguments=name+"Arguments"
                self._port_class(arguments,spec["inputs"])
                outcomes=[]
                external=[]
                for outcome in spec["outcomes"]:
                    outcome_name=name+"Outcome_"+_identifier(outcome["id"])+"_"+hashlib.sha256(outcome["id"].encode()).hexdigest()[:8]
                    self._port_class(outcome_name,outcome["value_ports"])
                    self.emit(f"{outcome_name}.outcome_id = {outcome['id']!r}", f"{outcome_name}.cause = {outcome['cause']!r}", "")
                    outcomes.append(outcome_name)
                    if sum_tag(outcome["cause"])=="ExternalCondition":
                        external.append((outcome_name,outcome["id"]))
                result=name+"Result"
                self.emit(f"{result}: TypeAlias = {' | '.join(outcomes)}", "")
                function="call_"+name
                self.emit(
                    f"def {function}(arguments, binding):",
                    f"    if type(arguments) is not {arguments}: raise TypeError('operation arguments have the wrong type')",
                )
                if sum_tag(spec["effect"])=="DataOnly":
                    self.emit("    result = binding(arguments)")
                else:
                    external_values=", ".join(f"({outcome_name}, {identity!r})" for outcome_name,identity in external)
                    self.emit(
                        "    if type(binding) is not HttpBinding: raise TypeError('external operations require HttpBinding')",
                        f"    result = binding.call(arguments, ({external_values}{',' if external_values else ''}))",
                    )
                self.emit(
                    f"    if type(result) not in ({', '.join(outcomes)},): raise TypeError('undeclared operation outcome')",
                    "    return result",
                    "",
                )
                self.entrypoint_values[identity]=function
                self.entrypoint_shapes[identity]=(arguments,result)


    def composition(self):
        composition=self.input.get("composition")
        if composition is None: return
        problem=composition["problem"]
        identity=problem["identity"]
        prefix="C_"+_identifier(identity)+"_"+hashlib.sha256(identity.encode()).hexdigest()[:10]
        initial=[item for item in problem["initial_inputs"] if sum_tag(item["source"])=="Argument"]
        arguments=self._port_class(prefix+"Arguments",[{"id":item["id"],"contract":item["contract"]} for item in initial])
        outputs=problem["goal"]["outputs"]
        result_fields=self._port_class(prefix+"Success",outputs)
        signatures=problem.get("signatures",[])
        provider_info={}
        for signature in signatures:
            key=json.dumps(signature["reference"],sort_keys=True,separators=(",",":"))
            name="P_"+_identifier(signature["reference"]["identity"])+"_"+hashlib.sha256(key.encode()).hexdigest()[:10]
            input_fields=self._port_class(name+"Arguments",signature["inputs"])
            outcomes={}
            external=[]
            for outcome in signature["outcomes"]:
                outcome_name=name+"Outcome_"+_identifier(outcome["id"])+"_"+hashlib.sha256(outcome["id"].encode()).hexdigest()[:8]
                outcome_fields=self._port_class(outcome_name,outcome["value_ports"])
                self.emit(f"{outcome_name}.outcome_id = {outcome['id']!r}", "")
                outcomes[outcome["id"]]=(outcome_name,outcome_fields)
                if sum_tag(outcome["cause"])=="ExternalCondition":
                    external.append((outcome_name,outcome["id"]))
            provider_info[key]=(name,input_fields,outcomes,external,_identifier(signature["reference"]["identity"]),sum_tag(signature["effect"])!="DataOnly")
        self.emit("@dataclass(frozen=True, slots=True, kw_only=True)", "class Providers:")
        if not provider_info: self.emit("    pass")
        for _,(_,_,_,_,attribute,_) in provider_info.items(): self.emit(f"    {attribute}: object")
        self.emit("")

        def producer_key(producer):
            return json.dumps(producer,sort_keys=True,separators=(",",":"))

        def binding_expression(binding):
            details=payload(binding)
            reference=details["value"]
            return f"values[{producer_key(reference['producer'])!r}]"

        counter=[0]
        def visit(tree):
            index=counter[0]; counter[0]+=1
            name=f"_{prefix}_node_{index}"
            kind=sum_tag(tree["node"]); details=payload(tree["node"])
            if kind=="Return":
                terminal_kind=sum_tag(details)
                if terminal_kind!="Success": raise ValueError("failure composition result is not supported")
                bindings={port:binding for port,binding in payload(details)}
                expressions=[result_fields[row["id"]]+"="+binding_expression(bindings[row["id"]]) for row in outputs]
                self.emit(f"def {name}(providers, values):",f"    return {prefix}Success({', '.join(expressions)})","")
                return name
            if kind!="Invoke": raise ValueError("guard composition node is not supported")
            invocation=details["invocation"]
            signature_key=json.dumps(invocation["function"],sort_keys=True,separators=(",",":"))
            _,input_fields,outcomes,external,attribute,external_effect=provider_info[signature_key]
            children={outcome:visit(child) for outcome,child in details["arms"]}
            arguments_by_id={port:binding for port,binding in invocation["bindings"]}
            args=[input_fields[port]+"="+binding_expression(arguments_by_id[port]) for port in input_fields]
            argument_type=provider_info[signature_key][0]+"Arguments"
            self.emit(f"def {name}(providers, values):",f"    arguments = {argument_type}({', '.join(args)})",f"    binding = providers.{attribute}")
            if external_effect:
                external_values=", ".join(f"({outcome_name}, {outcome_id!r})" for outcome_name,outcome_id in external)
                self.emit(
                    "    if type(binding) is not HttpBinding: raise TypeError('external operations require HttpBinding')",
                    f"    result = binding.call(arguments, ({external_values}{',' if external_values else ''}))",
                )
            else:
                self.emit("    result = binding(arguments)")
            for outcome_id,(outcome_name,outcome_fields) in outcomes.items():
                self.emit(f"    if type(result) is {outcome_name}:")
                if outcome_id not in children:
                    self.emit("        raise TypeError('provider returned an outcome outside the plan')")
                    continue
                self.emit("        next_values = dict(values)")
                site=invocation["site"]
                for port_id,attribute_name in outcome_fields.items():
                    producer=variant("InvocationOutcome",fields={"site":site,"outcome":outcome_id,"port":port_id})
                    self.emit(f"        next_values[{producer_key(producer)!r}] = result.{attribute_name}")
                self.emit(f"        return {children[outcome_id]}(providers, next_values)")
            self.emit("    raise TypeError('provider returned an undeclared outcome type')","")
            return name

        root=visit(composition["derivation"]["plan"]["root"])
        function="execute_"+prefix
        self.emit(f"def {function}(arguments, providers):",f"    if type(arguments) is not {prefix}Arguments: raise TypeError('composition arguments have the wrong type')","    values = {}")
        for item in initial:
            producer=variant("Initial",item["id"])
            self.emit(f"    values[{producer_key(producer)!r}] = arguments.{arguments[item['id']]}")
        self.emit(f"    return {root}(providers, values)","")
        self.entrypoint_values[identity]=function
        self.entrypoint_shapes[identity]=(prefix+"Arguments",prefix+"Success")


    def finish(self):
        codecs = ", ".join(repr(ref) + f": (decode_{name}, encode_{name})" for ref, name in self.names.items())
        self.emit("TYPE_NAMES = " + repr(self.names), "CODECS = {" + codecs + "}", "", "def examples(reference):", "    name = TYPE_NAMES[reference]", "    return globals()['examples_' + name]()", "")
        entries={entry["identity"]:self.entrypoint_values[entry["definition"]] for entry in self.input["entrypoints"]}
        if self.input.get("composition") is not None:
            identity=self.input["composition"]["problem"]["identity"]
            entries[identity]=self.entrypoint_values[identity]
        self.emit("ENTRYPOINTS = {" + ", ".join(repr(identity)+": "+value for identity,value in entries.items()) + "}")
        shapes={entry["identity"]:self.entrypoint_shapes[entry["definition"]] for entry in self.input["entrypoints"] if entry["definition"] in self.entrypoint_shapes}
        if self.input.get("composition") is not None:
            identity=self.input["composition"]["problem"]["identity"]
            shapes[identity]=self.entrypoint_shapes[identity]
        self.emit("ENTRYPOINT_SHAPES = " + repr(shapes))
        self.emit("ANNOTATIONS = " + repr(tuple(self.input["signatures"]["annotations"])), "GROUPS = " + repr(tuple(self.input["signatures"]["groups"])), "DECLARATIONS = " + repr(tuple(self.input["signatures"]["definitions"])), "")

    def render(self):
        self.header(); self.types(); self.definitions(); self.composition(); self.finish(); return "\n".join(self.lines)


def render_signatures(checked):
    return _Emitter(checked).render()
