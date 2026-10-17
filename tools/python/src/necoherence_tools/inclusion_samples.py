# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

"""Bounded samples and assignability rules corresponding to the Lean semantics."""
from __future__ import annotations

from dataclasses import dataclass

from necoherence.signature_values import DecimalLiteral, MeaningFailure, ValueFailure, integer, payload, recognize_format, ref_key, sum_tag, variant, withMember, wrapEncode


@dataclass(frozen=True, slots=True)
class SampleResult:
    values: tuple[object, ...]
    obligations: tuple[str, ...] = ()

    @property
    def sampleBound(self): return "sampleBound" in self.obligations
    @property
    def possible(self): return bool(self.values or self.obligations)


def _accepted(context, reference, value):
    try: context.validate(reference, value)
    except (MeaningFailure, ValueFailure): return False
    return True

def _element_allows_null(context, contract):
    return contract["nullable"] or _accepted(context, contract["type_ref"], None)


def _unique(values):
    result=[]
    for value in values:
        if value not in result: result.append(value)
    return result


def _format_samples(rule, limit, fuel):
    if fuel<=0: return []
    kind,spec=sum_tag(rule),payload(rule)
    inner=lambda child:_format_samples(child,limit,fuel-1)
    if kind=="Literal": candidates=[spec]
    elif kind=="Sequence":
        parts=[inner(item) for item in spec]
        if any(not part for part in parts): candidates=[]
        else:
            heads=[part[0] for part in parts]
            candidates=["".join(heads)]
            for index,part in enumerate(parts):
                candidates.extend("".join(heads[:index]+[item]+heads[index+1:]) for item in part[1:])
    elif kind=="Optional": candidates=["",*inner(spec)]
    elif kind=="Choice": candidates=[item for child in spec for item in inner(child)]
    elif kind=="Labels": candidates=[spec["separator"].join([item]*max(integer(spec["min_count"]),1)) for item in inner(spec["rule"])]
    elif kind=="Bounded": candidates=inner(spec["rule"])
    elif kind=="Identifier":
        length=integer(spec["exact_length"] if spec["exact_length"] is not None else spec["min_length"])
        candidates=[] if not spec["first_alphabet"] or not spec["rest_alphabet"] or length<=0 else [spec["first_alphabet"][0]+spec["rest_alphabet"][0]*(length-1)]
    elif kind=="AbsoluteUri": candidates=["a:","a:b"]
    elif kind=="LanguageTag": candidates=["aa"]
    elif kind=="Timestamp": candidates=["2000-01-01T00:00:00Z"]
    elif kind=="Text": candidates=["","a"]
    elif kind=="Not":
        excluded=inner(spec); candidates=["","a","aa",*excluded,*[item+"x" for item in excluded]]
    else: candidates=[]
    return [item for item in _unique(candidates) if recognize_format(rule,item)][:limit]


def _format_use_samples(profile,use,limit,fuel):
    if use is None: return ["x"]
    if sum_tag(use)=="Inline": return _format_samples(payload(use),limit,fuel)
    binding=next((item for item in profile["format_bindings"] if item["name"]==payload(use)),None)
    return [] if binding is None else _format_samples(binding["rule"],limit,fuel)


def _integer_binding(profile,spec):
    name=spec.get("domain") or profile["default_integer_domain"]
    return next((item for item in profile["integer_domains"] if item["name"]==name),None)


def _integer_wire(form,value):
    kind=sum_tag(form)
    return value if kind=="Number" else DecimalLiteral(str(value)) if kind=="IntegralDecimal" else str(value)


def _qualified_reference(context, reference):
    if not isinstance(reference, str):
        return reference
    node = next((node for node in context.graph.get("nodes", ()) if node.get("id") == reference), None)
    return reference if node is None else node.get("reference", reference)


def _candidates(context,fuel,seen,reference):
    reference = _qualified_reference(context, reference)
    if fuel<=0 or ref_key(reference) in seen or ref_key(reference) not in context.nodes: return []
    shape=context.shape(reference); kind,spec=sum_tag(shape),payload(shape)
    recurse=lambda target:_candidates(context,fuel-1,(*seen,ref_key(reference)),target)
    def element_values(contract):
        return _unique([*([None] if contract["nullable"] else []), *recurse(contract["type_ref"])])

    if kind=="Boolean": return [spec["const_value"]] if spec["const_value"] is not None else [False,True]
    if kind=="Integer":
        binding=_integer_binding(context.profile,spec)
        if binding is None: return []
        domain=[] if sum_tag(binding["range"])=="Unbounded" else [integer(payload(binding["range"])["minimum"]),integer(payload(binding["range"])["maximum"])]
        values=[spec.get("const_value"),*(spec.get("enum_values") or ()),spec.get("minimum"),spec.get("maximum"),*domain,0,1,-1]
        return [_integer_wire(form,integer(value)) for form in binding["forms"] for value in values if value is not None]
    if kind=="Decimal":
        bounds=[item for item in (spec["minimum"],spec["maximum"]) if item is not None]
        return [*[DecimalLiteral(str(integer(item["mantissa"]))+"e-"+str(integer(item["scale"]))) for item in bounds],DecimalLiteral("0.0"),DecimalLiteral("1.0"),DecimalLiteral("-1.0")]
    if kind=="String":
        lengths=[integer(item) for bound in spec["lengths"] for item in (bound["minimum"],bound["maximum"]) if item is not None]
        values=[spec.get("const_value"),*(spec.get("enum_values") or ()),*spec.get("examples",()),*_format_use_samples(context.profile,spec["format"],fuel+1,fuel),"","a",*["a"*length for length in lengths]]
        values=[item for item in values if item is not None]
        return [wrapEncode(context.profile,spec["wrapper"],item) for item in values] if spec["wrapper"] is not None else values
    if kind=="Bytes":
        wrapper=next((item for item in context.profile["wrappers"] if sum_tag(item["payload"])=="Bytes"),None)
        if wrapper is None: return []
        result=[]
        for length in [*[integer(item) for item in (spec["minimum"],spec["maximum"]) if item is not None],0,1]:
            body="AAAA"*(length//3)+{1:"AA==",2:"AAA="}.get(length%3,"")
            result.append({wrapper["key"]:body})
        return result
    if kind=="Sealed":
        model=context.profile.get("tag")
        form=None if model is None else next((item for item in model["sealed"] if item["tag"]==spec["tag"]),None)
        if form is None: return []
        refinements={item["key"]:item["leaf"] for item in spec["refinements"]}; members={model["key"]:form["tag"]}
        for field in form["fields"]:
            if not field["required"]: continue
            leaf=refinements.get(field["key"],field["leaf"]); leaf_kind,leaf_spec=sum_tag(leaf),payload(leaf)
            if leaf_kind=="String":
                values=[leaf_spec.get("const_value"),*(leaf_spec.get("enum_values") or ()),*leaf_spec.get("examples",()),*_format_use_samples(context.profile,leaf_spec["format"],1,fuel)]
                value=next((item for item in values if item is not None),None)
                if value is None: return []
                members[field["key"]]=wrapEncode(context.profile,leaf_spec["wrapper"],value) if leaf_spec["wrapper"] is not None else value
            else:
                value=leaf_spec.get("const_value") or next(iter(leaf_spec.get("enum_values") or ()),None) or leaf_spec.get("minimum") or leaf_spec.get("maximum")
                if value is None: return []
                members[field["key"]]=integer(value)
        return [members]
    if kind=="Never" or kind in ("RawBody","Opaque"): return []
    if kind=="Unit": return [None]
    if kind=="Unknown": return [{},None,False,0,"",[]]
    if kind=="Alias": return recurse(spec["target"])
    if kind=="Array":
        result=[]
        for length in [*[integer(item) for item in (spec["min_length"],spec["max_length"]) if item is not None],0,1]:
            if length==0: result.append([])
            else: result.extend([[value]*length for value in element_values(spec["item"])])
        return result
    if kind=="Product":
        def construct(fields):
            if not fields: return [{}]
            field,*rest=fields; remaining=construct(rest); slot=field["slot"]
            choices=[*([] if slot["required"] else [_ABSENT]),*([None] if slot["nullable"] else []),*recurse(slot["type_ref"])]
            return [(dict(row) if item is _ABSENT else {field["wire_name"]:item,**row}) for item in choices for row in remaining][:fuel]
        base=construct(list(spec["fields"])); extras=[]
        if sum_tag(spec["extras"])=="Allow":
            details=payload(spec["extras"])
            for key in _format_use_samples(context.profile,details["key_format"],1,fuel):
                extras.extend([{key:value} for value in element_values(details["value"])[:1]])
        return base+extras
    if kind=="TaggedUnion":
        result=[]; model=context.profile.get("tag"); tag_key="" if model is None else model["key"]
        for branch in spec["branches"]:
            for value in recurse(branch["target"]):
                selector=sum_tag(branch["selector"])
                if selector=="InternalTag" and isinstance(value,dict): value=withMember(tag_key,branch["wire_tag"],value)
                elif selector=="MemberShape" and isinstance(value,dict):
                    value=dict(value)
                    for test in payload(branch["selector"]):
                        if sum_tag(test["test"])=="Absent": value.pop(test["key"],None)
                        else:
                            samples=_format_use_samples(context.profile,{"tag":"Named","value":payload(test["test"])},1,fuel)
                            if samples: value[test["key"]]=samples[0]
                elif selector not in ("Kind","Otherwise"): continue
                result.append(value)
        return result
    return []


_ABSENT=object()


def _within_bound(value,maximum):
    if isinstance(value,(str,DecimalLiteral)): return len(str(value))<=maximum
    if isinstance(value,(list,dict)): return len(value)<=maximum
    return True


def sample_values(context,fuel,seen,reference,max_sample_length=4096):
    candidates=[value for value in _unique(_candidates(context,fuel,seen,reference)) if _accepted(context,reference,value)]
    values=tuple(value for value in candidates if _within_bound(value,max_sample_length))
    return SampleResult(values,() if len(values)==len(candidates) else ("sampleBound",))


def slotSamples(context,contract,max_obligations=10000,max_sample_length=4096):
    generated=sample_values(context,min(max_obligations,len(context.nodes)+1),(),contract["type_id"],max_sample_length)
    values=[*([] if contract["required"] else [{"tag":"Absent"}]),*([{"tag":"Null"}] if contract["nullable"] else []),*[{"tag":"Present","value":item} for item in generated.values]]
    return SampleResult(tuple(values),generated.obligations)


def inclusion_samples(context,source,destination,max_obligations,max_sample_length=4096):
    generated=sample_values(context,min(max_obligations,len(context.nodes)+1),(),source,max_sample_length)
    candidates=[]
    source_shape,destination_shape=context.resolved(source)[1],context.resolved(destination)[1]
    if sum_tag(source_shape)==sum_tag(destination_shape)=="Product":
        source_spec,destination_spec=payload(source_shape),payload(destination_shape)
        source_names={field["wire_name"] for field in source_spec["fields"]}
        for field in destination_spec["fields"]:
            if field["wire_name"] not in source_names:
                for sample in generated.values[:1]:
                    if isinstance(sample,dict): candidates.extend([{field["wire_name"]:value,**sample} for value in (None,True,"x","y",0)])
        if sum_tag(source_spec["extras"])=="Allow":
            details=payload(source_spec["extras"])
            values=[*([None] if details["value"]["nullable"] else []), *sample_values(context,min(max_obligations,len(context.nodes)+1),(),details["value"]["type_ref"],max_sample_length).values]
            for key in _format_use_samples(context.profile,details["key_format"],1,max_obligations):
                candidates.extend([{key:value} for value in values])
    accepted=[value for value in candidates if _within_bound(value,max_sample_length) and _accepted(context,source,value)]
    obligations=generated.obligations+(() if len(accepted)==len(candidates) else ("sampleBound",))
    return SampleResult((*generated.values,*accepted),obligations)


def _lower(source,destination,natural=False):
    if destination is None: return True
    if source is None: return natural and integer(destination)==0
    return integer(destination)<=integer(source)


def _upper(source,destination):
    if destination is None: return True
    return source is not None and integer(source)<=integer(destination)


def formatRuleIncluded(source,destination):
    if source==destination or sum_tag(destination)=="Text": return True
    return sum_tag(destination)=="Choice" and any(formatRuleIncluded(source,item) for item in payload(destination))


def _format_use_included(profile,source,destination):
    if destination is None: return True
    if source is None: return False
    if sum_tag(source)=="Named": source=next((item["rule"] for item in profile["format_bindings"] if item["name"]==payload(source)),None)
    else: source=payload(source)
    if sum_tag(destination)=="Named": destination=next((item["rule"] for item in profile["format_bindings"] if item["name"]==payload(destination)),None)
    else: destination=payload(destination)
    return source is not None and destination is not None and formatRuleIncluded(source,destination)


def _presence(source,destination):
    return (destination["required"] is False or source["required"] is True) and (destination["nullable"] is True or source["nullable"] is False)


def _selector_equal(source,destination):
    left,right=sum_tag(source["selector"]),sum_tag(destination["selector"])
    if left!=right: return False
    if left=="InternalTag": return source["wire_tag"]==destination["wire_tag"]
    return source["selector"]==destination["selector"]


def _selector_disjoint(left,right):
    lk,rk=sum_tag(left["selector"]),sum_tag(right["selector"])
    if lk==rk=="InternalTag": return left["wire_tag"]!=right["wire_tag"]
    if lk==rk=="Kind": return payload(left["selector"])!=payload(right["selector"])
    if {lk,rk}=={"InternalTag","Kind"}:
        kind=payload(right["selector"] if rk=="Kind" else left["selector"])
        return sum_tag(kind)!="Object"
    return False


def _union_pairs(source,destination):
    sources=list(source["branches"]); result=[]
    for target in destination["branches"]:
        if sources and _selector_equal(sources[0],target): result.append((sources.pop(0)["target"],target["target"]))
        elif all(_selector_disjoint(target,item) for item in sources): continue
        else: return None
    return result if not sources else None


def _structural(context,source,destination,remaining,seen):
    pair=(source,destination)
    if pair in seen: return True
    if remaining<=0: return None
    seen=(*seen,pair)
    left,right=context.shape(source),context.shape(destination)
    if left==right: return True
    lk,rk=sum_tag(left),sum_tag(right); ls,rs=payload(left),payload(right)
    if lk=="Never": return True
    if lk=="Alias": return _structural(context,ls["target"],destination,remaining-1,seen)
    if rk=="Alias": return _structural(context,source,rs["target"],remaining-1,seen)
    if lk!=rk: return None
    if lk=="Boolean": return rs["const_value"] is None or ls["const_value"]==rs["const_value"]
    if lk=="Integer":
        binding_left=_integer_binding(context.profile,ls); binding_right=_integer_binding(context.profile,rs)
        if binding_left is None or binding_right is None or [sum_tag(item) for item in binding_left["forms"]]!=["Number"] or [sum_tag(item) for item in binding_right["forms"]]!=["Number"] or ls["domain"]!=rs["domain"]: return None
        finite=[ls["const_value"]] if ls["const_value"] is not None else ls["enum_values"]
        if finite is not None: return all(_accepted(context,destination,integer(value)) for value in finite if _accepted(context,source,integer(value)))
        return rs["const_value"] is None and rs["enum_values"] is None and _lower(ls["minimum"],rs["minimum"]) and _upper(ls["maximum"],rs["maximum"])
    if lk=="String":
        left_base={**ls,"lengths":[]}; right_base={**rs,"lengths":[]}
        if left_base!=right_base: return None
        return all(any(candidate["unit"]==target["unit"] and _lower(candidate["minimum"],target["minimum"],True) and _upper(candidate["maximum"],target["maximum"]) for candidate in ls["lengths"]) for target in rs["lengths"])
    if lk=="Array":
        if not _lower(ls["min_length"],rs["min_length"],True) or not _upper(ls["max_length"],rs["max_length"]): return None
        if _element_allows_null(context,ls["item"]) and not _element_allows_null(context,rs["item"]): return None
        return _structural(context,ls["item"]["type_ref"],rs["item"]["type_ref"],remaining-1,seen)
    if lk=="Product":
        left_fields={item["wire_name"]:item for item in ls["fields"]}
        right_fields={item["wire_name"]:item for item in rs["fields"]}
        tag_key=None if context.profile.get("tag") is None else context.profile["tag"]["key"]
        pairs=[]
        for name,target in right_fields.items():
            candidate=left_fields.get(name)
            if candidate is not None:
                if not _presence(candidate["slot"],target["slot"]): return None
                pairs.append((candidate["slot"]["type_ref"],target["slot"]["type_ref"]))
                continue
            if target["slot"]["required"] or name==tag_key or sum_tag(ls["extras"])!="Allow": return None
            source_extra=payload(ls["extras"])["value"]
            if _element_allows_null(context,source_extra) and not target["slot"]["nullable"]: return None
            pairs.append((source_extra["type_ref"],target["slot"]["type_ref"]))
        for name,candidate in left_fields.items():
            if name in right_fields or name==tag_key: continue
            if sum_tag(rs["extras"])!="Allow": return None
            destination_extra=payload(rs["extras"])
            if not _format_use_included(context.profile,variant("Inline",variant("Literal",name)),destination_extra["key_format"]): return None
            if candidate["slot"]["nullable"] and not _element_allows_null(context,destination_extra["value"]): return None
            pairs.append((candidate["slot"]["type_ref"],destination_extra["value"]["type_ref"]))
        left_extra,right_extra=sum_tag(ls["extras"]),sum_tag(rs["extras"])
        if left_extra=="Allow" and right_extra=="Reject": return None
        if left_extra=="Allow" and right_extra=="Allow":
            source_extra,destination_extra=payload(ls["extras"]),payload(rs["extras"])
            if not _format_use_included(context.profile,source_extra["key_format"],destination_extra["key_format"]): return None
            if _element_allows_null(context,source_extra["value"]) and not _element_allows_null(context,destination_extra["value"]): return None
            pairs.append((source_extra["value"]["type_ref"],destination_extra["value"]["type_ref"]))
        return all(_structural(context,a,b,remaining-1,seen) is True for a,b in pairs)
    if lk=="TaggedUnion":
        if any(sum_tag(item["selector"])=="Otherwise" for item in ls["branches"]): return True if ls==rs else None
        pairs=_union_pairs(ls,rs)
        if pairs is None: return None
        return all(_structural(context,a,b,remaining-1,seen) is True for a,b in pairs)
    return None


def checkAssignable(context,source,destination,max_obligations=10000,max_sample_length=4096):
    if not _presence(source,destination):
        return {"classification":"incompatible","counterexample":{"tag":"Absent"} if not source["required"] else {"tag":"Null"}}
    structural=_structural(context,source["type_id"],destination["type_id"],max_obligations,())
    if structural is True: return {"classification":"compatible","counterexample":None,"obligations":[]}
    samples=inclusion_samples(context,source["type_id"],destination["type_id"],max_obligations,max_sample_length)
    for value in samples.values:
        if _accepted(context,source["type_id"],value) and not _accepted(context,destination["type_id"],value):
            return {"classification":"incompatible","counterexample":value,"obligations":list(samples.obligations)}
    return {"classification":"unknown","counterexample":None,"obligations":list(samples.obligations) or ["constraintImplication"]}


def compatible(context,source,destination,max_obligations=64):
    source_contract={"type_id":source,"required":True,"nullable":False}
    destination_contract={"type_id":destination,"required":True,"nullable":False}
    return checkAssignable(context,source_contract,destination_contract,max_obligations)
