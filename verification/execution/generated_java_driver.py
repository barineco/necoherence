#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "verification" / "declaration"))
import signature_admission_exhaustive as exhaustive  # noqa: E402
JAVA_LIBRARY = Path(os.environ.get("NCOH_JAVA_EXECUTION_CLASSPATH", ROOT / "packages/java/adapter/build/maven/io/github/barineco/necoherence/0.3.0/necoherence-0.3.0.jar"))


def command(argv, *, cwd=ROOT):
    result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True)
    if result.returncode: raise RuntimeError(result.stderr or result.stdout)
    return result.stdout


def pascal(value):
    return "".join(part[:1].upper() + part[1:] for part in re.split(r"[^A-Za-z0-9]+", value) if part)


def java_string(value): return json.dumps(value, ensure_ascii=False)


def node(exchange, type_id): return next(value for value in exchange["signatures"]["nodes"] if value["id"] == type_id)


def carrier(owner, exchange, type_id, value):
    shape = node(exchange, type_id)["shape"]["tag"]
    if shape == "Boolean": return "true" if value else "false"
    if shape == "String": return java_string(value)
    if shape == "Unit": return "Unit.VALUE"
    return f"{owner}.Type{pascal(type_id)}.decode({java_string(json.dumps(value, separators=(',', ':')))})"


def typed_slot(owner, exchange, contract, value):
    present = carrier(owner, exchange, contract["type_id"], value.get("value")) if value["tag"] == "present" else None
    if contract["required"] and not contract["nullable"]: return present
    if not contract["required"] and contract["nullable"]:
        return "new Absent<>()" if value["tag"] == "absent" else "new NullSlot<>()" if value["tag"] == "null" else f"new Present<>({present})"
    if contract["required"]: return "new Null<>()" if value["tag"] == "null" else f"new NonNull<>({present})"
    return "Optional.empty()" if value["tag"] == "absent" else f"Optional.of({present})"


def function_name(exchange, signature):
    declared = exchange["composition"]["problem"]["signatures"][signature]
    if declared["form"]["tag"] == "Operation":
        definition = declared["form"]["value"]
        return next(value["wire_identity"] for value in exchange["signatures"]["definitions"] if value["id"] == definition)
    return pascal(declared["reference"]["identity"])


def outcome(owner, exchange, signature, description, fallback=False):
    outcomes = exchange["composition"]["problem"]["signatures"][signature]["outcomes"]
    selected = next((value for value in outcomes if value["id"] == description["outcome"]), None)
    if selected is None and fallback: selected = outcomes[0]
    if selected is None: raise ValueError(f"unrepresentable outcome {description['outcome']}")
    supplied = {value["id"]: value["value"] for value in description["outputs"]}
    values = []
    for port in selected["value_ports"]:
        value = supplied.get(port["id"], {"tag":"present","value":False})
        values.append(typed_slot(owner, exchange, port["contract"], value))
    wire = function_name(exchange, signature)
    return f"made(() -> {owner}.{wire}Outcome{pascal(selected['id'])}.of({','.join(values)}))"


def attempt(value):
    return f'''new NetworkEffect.AttemptInput(new NetworkEffect.AttemptIdentity(new RequestIdentity("semantic",{java_string(value.get("provenance","comparison"))},Nat.one()),Nat.fromLong({value.get("ordinal",0)})),new NetworkEffect.HttpWireInstruction({java_string(value["method"])},{java_string(value["target"])},List.of(),ByteString.empty()),Optional.empty(),new NetworkEffect.HostConfiguration(Nat.fromLong(1024),Nat.fromLong(1024),Optional.empty(),Optional.empty()))'''


def providers(owner, exchange, case):
    values = []
    for description in case["providers"]:
        signature = description.get("signature", 0); wire = function_name(exchange, signature)
        if description["effect"] == "pure":
            values.append(f"input -> new SemanticExecution.ProviderSuccess<>({outcome(owner, exchange, signature, description)})")
            continue
        prepared = description["prepare"][0]
        if prepared["tag"] == "ready": preparation = f"new {owner}.{wire}Ready({attempt(prepared['request'])})"
        else: preparation = f"new {owner}.{wire}Completed({outcome(owner, exchange, signature, prepared, True)})"
        decode_rows = []
        for row in description["decode"]:
            if "failure" in row:
                returned = f"new SemanticExecution.ProviderRejected<>(new SemanticExecution.ProviderFailure(new SemanticComposition.SiteId(\"operation\"),{java_string(row['failure']['message'])}))"
            else: returned = f"new SemanticExecution.ProviderSuccess<>({outcome(owner, exchange, signature, row)})"
            decode_rows.append(f"if(response.status()=={row['status']})return {returned};")
        decode = "".join(decode_rows) + 'throw new IllegalStateException("missing decode behavior");'
        values.append(f"new {owner}.{wire}HttpBinding(input -> new SemanticExecution.ProviderSuccess<>({preparation}), response -> {{{decode}}})")
    return f"new {owner}.Providers({','.join(values)})"


def observation(case, value):
    ready = [row for provider in case["providers"] for row in provider.get("prepare", []) if row["tag"] == "ready"]
    request = attempt(ready[value.get("request",0)]["request"]); handle = java_string(value.get("handle","handle"))
    if value["tag"] == "start" and value.get("kind") == "started": return f"new SemanticExecution.Start(new NetworkEffect.StartObservation.Started(({request}).attempt(),new ExecutionHandle({handle})))"
    if value["tag"] == "start": return f"new SemanticExecution.Start(new NetworkEffect.StartObservation.StartFailed(new NetworkEffect.NetworkHostFailure(({request}).attempt(),NetworkEffect.HostStage.Start,({request}).configuration(),new NetworkEffect.HostFailure.ExecutionStartFailed()),new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.NoResponse)))"
    return f"new SemanticExecution.Host(new NetworkEffect.HostObservation.Delivered(Nat.fromLong({value.get('delivery',0)}),new NetworkEffect.AdapterObservation.ResponseObservation(({request}).attempt(),new ExecutionHandle({handle}),new NetworkEffect.SourceSequence.None(),new NetworkEffect.RawHttpResponse({value['status']},List.of(),ByteString.empty()),NetworkEffect.HeaderProvenance.LibraryNormalized,new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.NoResponse))))"


def json_value(expression, exchange, type_id):
    shape = node(exchange, type_id)["shape"]["tag"]
    if shape == "Boolean": return f"String.valueOf({expression})"
    if shape == "String": return f"quote({expression})"
    if shape == "Unit": return '"null"'
    return f"{expression}.encode()"


def slot_json(expression, exchange, contract):
    present = f"slotPresent({json_value(expression, exchange, contract['type_id'])})"
    if contract["required"] and not contract["nullable"]: return present
    if not contract["required"] and contract["nullable"]: return f"slot({expression},{java_string('null')})"
    if contract["required"]: return f"nullable({expression})"
    return f"optional({expression})"


def consumer(owner, case, exchange):
    problem = exchange["composition"]["problem"]
    supplied = {value["id"]: value["value"] for value in case["arguments"]}
    arguments = [typed_slot(owner, exchange, value["contract"], supplied[value["id"]]) for value in problem["initial_inputs"] if value["source"]["tag"] == "Argument"]
    observations = ",".join(observation(case, value) for value in case["observations"])
    goal = problem["goal"]["outputs"][0]
    result_arms = [f'''if(result instanceof {owner}.Success success)return "{{\\"tag\\":\\"success\\",\\"outcome\\":[[\\"{goal['id']}\\","+{slot_json('success.values().result()', exchange, goal['contract'])}+"]]}}";''']
    for failure in problem["goal"]["failures"]:
        name = pascal(failure["id"]) + "Failure"
        result_arms.append(f'''if(result instanceof {owner}.{name} failure)return "{{\\"tag\\":\\"failure\\",\\"embedding\\":\\"{failure['id']}\\",\\"value\\":"+{slot_json('failure.value()', exchange, failure['contract'])}+"}}";''')
    return f'''
import java.util.*;
import necoherence.composition.SemanticComposition;
import necoherence.core.Nat;
import necoherence.network.NetworkEffect;
import necoherence.network.ByteString;
import necoherence.progression.ExecutionHandle;
import necoherence.progression.RequestIdentity;
import necoherence.composition.SemanticExecution;
import necoherence.comparison.NetworkFailureJson;
import necoherence.comparison.ValueFailureJson;
import necoherence.semantic.SemanticValues;
import necoherence.semantic.SemanticValues.*;
public final class Consumer {{
 @FunctionalInterface interface Throwing<T>{{T get()throws Exception;}}
 static <T>T made(Throwing<T> value){{try{{return value.get();}}catch(Exception failure){{throw new RuntimeException(failure);}}}}
 static String quote(String value){{return "\\\""+value.replace("\\\\","\\\\\\\\").replace("\\\"","\\\\\\\"")+"\\\"";}}
 static String slotPresent(String value){{return "{{\\"tag\\":\\"present\\",\\"value\\":"+value+"}}";}}
 static String slot(Slot<?> value,String nullTag)throws Exception{{if(value instanceof Absent<?>)return "{{\\"tag\\":\\"absent\\"}}";if(value instanceof NullSlot<?>)return "{{\\"tag\\":"+quote(nullTag)+"}}";Object item=((Present<?>)value).value();return slotPresent(item instanceof Boolean?String.valueOf(item):item instanceof String?quote((String)item):item.getClass().getMethod("encode").invoke(item).toString());}}
 static String nullable(Nullable<?> value)throws Exception{{if(value instanceof Null<?>)return "{{\\"tag\\":\\"null\\"}}";Object item=((NonNull<?>)value).value();return slotPresent(item instanceof Boolean?String.valueOf(item):item instanceof String?quote((String)item):item.getClass().getMethod("encode").invoke(item).toString());}}
 static String optional(Optional<?> value)throws Exception{{if(value.isEmpty())return "{{\\"tag\\":\\"absent\\"}}";Object item=value.get();return slotPresent(item instanceof Boolean?String.valueOf(item):item instanceof String?quote((String)item):item.getClass().getMethod("encode").invoke(item).toString());}}
 static String array(List<?> values){{var rows=new ArrayList<String>();for(Object value:values)rows.add(structured(value));return "["+String.join(",",rows)+"]";}}
 static String nested(String tag,Object...args){{return "{{\\"tag\\":"+quote(tag)+",\\"args\\":"+array(List.of(args))+"}}";}}
 static String structured(Object value){{if(value==null)return "null";if(value instanceof String text)return quote(text);if(value instanceof Boolean flag)return String.valueOf(flag);if(value instanceof java.math.BigInteger number)return quote(number.toString());if(value instanceof List<?> list)return array(list);if(value instanceof WireValue wire)return SemanticValues.encodeWire(wire);if(value.getClass().isRecord()){{try{{var components=value.getClass().getRecordComponents();if(components.length==1&&components[0].getName().equals("value")&&value.getClass().getSimpleName().endsWith("Id"))return structured(components[0].getAccessor().invoke(value));var fields=new ArrayList<String>();for(var component:components)fields.add(quote(component.getName())+":"+structured(component.getAccessor().invoke(value)));return "{{"+String.join(",",fields)+"}}";}}catch(ReflectiveOperationException failure){{throw new RuntimeException(failure);}}}}return quote(value.toString());}}
 static String preparation(SemanticComposition.CompositionInputFailure value){{if(value instanceof SemanticComposition.BasisMismatch)return nested("basisMismatch");if(value instanceof SemanticComposition.DuplicateIdentity x)return nested("duplicateIdentity",x.kind(),x.identity());if(value instanceof SemanticComposition.UnresolvedType x)return nested("unresolvedType",x.reference());if(value instanceof SemanticComposition.UnresolvedFunction x)return nested("unresolvedFunction",x.reference());if(value instanceof SemanticComposition.InvalidSignature x)return nested("invalidSignature",x.reference(),x.reason());if(value instanceof SemanticComposition.InvalidInitialValue x)return nested("invalidInitialValue",x.id().value(),x.failure());if(value instanceof SemanticComposition.SiteEffectNotPermitted x)return nested("siteEffectNotPermitted",x.site(),x.effect());if(value instanceof SemanticComposition.TransformNotPermitted x)return nested("transformNotPermitted",x.function());if(value instanceof SemanticComposition.EmptyGoal)return nested("emptyGoal");if(value instanceof SemanticComposition.GoalSourceConstraintUndefined x)return nested("goalSourceConstraintUndefined",x.port(),x.constraint());if(value instanceof SemanticComposition.FailureEmbeddingOriginUndefined x)return nested("failureEmbeddingOriginUndefined",x.embedding(),x.origin());if(value instanceof SemanticComposition.ConstructionNotProduct x)return nested("constructionNotProduct",x.identity(),x.typeRef());if(value instanceof SemanticComposition.FieldConstraintUnknownField x)return nested("fieldConstraintUnknownField",x.identity(),x.field());if(value instanceof SemanticComposition.ConstrainedNestedField x)return nested("constrainedNestedField",x.identity(),x.field());if(value instanceof SemanticComposition.ConstructionFieldSourceUndefined x)return nested("constructionFieldSourceUndefined",x.identity(),x.constraint());if(value instanceof SemanticComposition.NestedFieldUndeclared x)return nested("nestedFieldUndeclared",x.identity(),x.field());if(value instanceof SemanticComposition.NestedConstructionMismatch x)return nested("nestedConstructionMismatch",x.identity(),x.field(),x.nested(),x.typeRef());if(value instanceof SemanticComposition.CyclicConstruction x)return nested("cyclicConstruction",x.identity());if(value instanceof SemanticComposition.ExplicitSiteOrderInvalid x)return nested("explicitSiteOrderInvalid",x.before(),x.after());if(value instanceof SemanticComposition.InvalidEmptyTypeClosure x)return nested("invalidEmptyTypeClosure",x.failure());if(value instanceof SemanticComposition.InvalidLibrary x)return nested("invalidLibrary",x.failure());return nested("invalidResourceDeclaration",((SemanticComposition.InvalidResourceDeclaration)value).reason());}}
 static String failure(SemanticExecution.ExecutionFailure f){{if(f instanceof SemanticExecution.InvalidPlan x)return "{{\\"tag\\":\\"invalidPlan\\",\\"condition\\":"+quote(x.condition())+"}}";if(f instanceof SemanticExecution.ProviderFailure x)return "{{\\"tag\\":\\"provider\\",\\"site\\":"+quote(x.site().value())+",\\"message\\":"+quote(x.message())+"}}";if(f instanceof SemanticExecution.NetworkTerminal x){{var t=x.terminal();var failed=t.outcome() instanceof NetworkEffect.NetworkOutcome.Failed y?y.failure():null;String stage=failed==null?"null":quote(failed.stage().name()),cause=failed==null?"null":quote(failed.cause().getClass().getSimpleName());String reason=t.effect() instanceof NetworkEffect.EffectStatus.Unknown y?quote(y.reason().name()):"null";return "{{\\"tag\\":\\"networkTerminal\\",\\"outcome\\":"+quote(t.outcome().getClass().getSimpleName())+",\\"stage\\":"+stage+",\\"cause\\":"+cause+",\\"effect\\":"+quote(t.effect().getClass().getSimpleName())+",\\"reason\\":"+reason+"}}";}}if(f instanceof SemanticExecution.Network x)return "{{\\"tag\\":\\"network\\",\\"detail\\":"+SemanticValues.encodeWire(NetworkFailureJson.render(x.failure()))+"}}";if(f instanceof SemanticExecution.Value x)return "{{\\"tag\\":\\"value\\",\\"detail\\":"+SemanticValues.encodeWire(ValueFailureJson.render(x.failure()))+"}}";return "{{\\"tag\\":\\"generatedFailure\\",\\"detail\\":"+quote(f.toString())+"}}";}}
 static String result({owner}.Result result)throws Exception{{{''.join(result_arms)}throw new IllegalStateException();}}
 public static void main(String[] args)throws Exception{{var providers={providers(owner, exchange, case)};var arguments={owner}.Arguments.of({','.join(arguments)});var initialized={owner}.initialize();if(initialized instanceof {owner}.InitializeRejected rejected){{if(rejected.failure().compositionInputFailure()==null)throw rejected.failure();System.out.println("{{\\"case\\":"+quote({java_string(case['case'])})+",\\"progress\\":[],\\"failure\\":{{\\"tag\\":\\"preparation\\",\\"detail\\":"+preparation(rejected.failure().compositionInputFailure())+"}}}}");return;}}Object current={owner}.run(({owner}.Initialized)initialized,providers,arguments,NetworkEffect.NetworkState.empty());var observations=List.<SemanticExecution.ExecutionObservation>of({observations});int index=0;var progress=new ArrayList<String>();while(current instanceof {owner}.Progressed progressed && progressed.progress() instanceof {owner}.Pending pending){{progress.add("{{\\"tag\\":\\"pending\\",\\"instruction\\":\\""+(pending.instruction() instanceof SemanticExecution.Send?"send":"observe")+"\\"}}");current={owner}.resume(pending.execution(),observations.get(index++));}}String prefix="{{\\"case\\":"+quote({java_string(case['case'])})+",\\"progress\\":["+String.join(",",progress)+"]";if(current instanceof {owner}.Rejected rejected)System.out.println(prefix+",\\"failure\\":"+failure(rejected.failure().cause())+"}}");else if(current instanceof {owner}.ResumeRejected rejected)System.out.println(prefix+",\\"failure\\":"+failure(rejected.failure().cause())+"}}");else{{var completed=({owner}.Completed)(({owner}.Progressed)current).progress();progress.add("{{\\"tag\\":\\"completed\\"}}");prefix="{{\\"case\\":"+quote({java_string(case['case'])})+",\\"progress\\":["+String.join(",",progress)+"]";System.out.println(prefix+",\\"result\\":"+result(completed.result())+"}}");}}}}
}}
'''


document = json.loads(Path(sys.argv[1]).read_text()); scratch = Path(sys.argv[2]); scratch.mkdir(parents=True, exist_ok=True)
helper_build = scratch / "helper"; helper_build.mkdir()
command(["javac", "--release", "21", "-cp", str(JAVA_LIBRARY), "-sourcepath", os.pathsep.join((os.environ["NCOH_NECO_QUOTIENT_JAVA"], os.environ["NCOH_NECO_QUOTIENT_APPLICATION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_RETENTION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_ENCODING_JAVA"])), "-d", str(helper_build),
         str(HERE / "java_driver/NetworkFailureJson.java"), str(HERE / "java_driver/ValueFailureJson.java"),
         *sorted(str(source) for root in (os.environ["NCOH_NECO_QUOTIENT_JAVA"], os.environ["NCOH_NECO_QUOTIENT_APPLICATION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_RETENTION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_ENCODING_JAVA"]) for source in Path(root).rglob("*.java"))])
classpath = os.pathsep.join((str(helper_build), str(JAVA_LIBRARY)))
rows = []
for number, case in enumerate(document["cases"]):
    try:
        exchange = json.loads(case["exchange"]); owner = f"GeneratedCase{number}"; project = scratch / f"case-{number}"; project.mkdir()
        exchange_path = project / "exchange.json"; exchange_path.write_text(case["exchange"])
        expected_path = project / "expected.json"; expected_path.write_text(json.dumps(exhaustive.expected_document(exchange["basis"], exchange["composition"])))
        command(["cargo", "run", "--quiet", "--locked", "--manifest-path", str(ROOT / "generator/rust/Cargo.toml"), "--bin", "necoherence-generate", "--",
                 "--target", "java", "--java-package", "", "--java-class", owner, "--expected", str(expected_path), "--input", str(exchange_path),
                 "--output", str(project / f"{owner}.java")])
        (project / "Consumer.java").write_text(consumer(owner, case, exchange))
        command(["javac", "--release", "21", "-cp", classpath, "-sourcepath", os.pathsep.join((os.environ["NCOH_NECO_QUOTIENT_JAVA"], os.environ["NCOH_NECO_QUOTIENT_APPLICATION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_RETENTION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_ENCODING_JAVA"])), "-d", str(project), str(project / f"{owner}.java"), str(project / "Consumer.java")])
        rows.append(json.loads(command(["java", "-cp", os.pathsep.join((str(project), classpath)), "Consumer"])))
    except Exception as failure: rows.append({"case":case["case"],"progress":[],"driverFailure":f"{failure.__class__.__name__}: {failure}"})
print(json.dumps(rows,separators=(",",":")))
