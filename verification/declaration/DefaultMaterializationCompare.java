// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import static necoherence.semantic.SemanticValues.*;
import static necoherence.semantic.SemanticGeneration.*;
import necoherence.semantic.ExactJson.JsonValue;
import necoherence.semantic.SemanticGraphWire;
import necoherence.semantic.WireJson;
import necoherence.semantic.SemanticTypes;
import necoherence.semantic.SemanticValues;
import necoherence.semantic.WireFailure;
import necoherence.semantic.WireFailure.WireException;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.PrintWriter;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;

public final class DefaultMaterializationCompare {
    private static WireValue exactValue(WireValue value) {
        String tag = readField(value, "tag", SemanticValues::s);
        return switch (tag) {
            case "Null" -> { keys(value, "$", "tag"); yield NIL; }
            case "Bool" -> { keys(value, "$", "tag", "value"); yield new BooleanValue(b(((ObjectValue) value).get("value"))); }
            case "Integer" -> { keys(value, "$", "tag", "value"); yield num(canonicalInteger(((ObjectValue) value).get("value"))); }
            case "String" -> { keys(value, "$", "tag", "value"); yield str(s(((ObjectValue) value).get("value"))); }
            case "Decimal" -> { keys(value, "$", "tag", "text"); yield exactDecimal(readField(value, "text", SemanticValues::s)); }
            case "Array" -> { keys(value, "$", "tag", "items"); yield arr(readPlainList(((ObjectValue) value).get("items"), DefaultMaterializationCompare::exactValue)); }
            case "Object" -> { keys(value, "$", "tag", "members"); yield new ObjectValue(readPlainList(((ObjectValue) value).get("members"), DefaultMaterializationCompare::exactMember)); }
            default -> throw new WireException(new WireFailure.UnknownTag("$.tag", tag));
        };
    }
    private static Member exactMember(WireValue entry) {
        keys(entry, "$", "key", "value");
        String key = readField(entry, "key", SemanticValues::s);
        return new Member(key, exactValue(((ObjectValue) entry).get("value")));
    }
    private static BigInteger canonicalInteger(WireValue value) {
        String text = s(value);
        if (!text.matches("-?(0|[1-9][0-9]*)")) throw new WireException(new WireFailure.Syntax("$", "noncanonical integer"));
        return new BigInteger(text);
    }
    private static WireValue exactDecimal(String text) {
        if (!isExactDecimal(text)) throw new WireException(new WireFailure.Syntax("$.text", "invalid exact decimal"));
        return new DecimalValue(text);
    }
    private static WireValue applications(List<DefaultApplication> applications) {
        return arr(applications.stream().map(item -> obj("value_path", arr(item.valuePath()), "type_ref", item.typeRef(), "origin", item.origin(), "value", toExact(item.value()))).toList());
    }
    private static WireValue replace(WireValue value, String key, WireValue replacement) {
        return new ObjectValue(((ObjectValue)value).members().stream().map(member -> member.key().equals(key) ? new Member(key, replacement) : member).toList());
    }
    private static WireValue condition(ValueCondition condition) {
        String tag = valueConditionTag(condition);
        return valueConditionArgument(condition).map(argument -> variant(tag, str(argument))).orElseGet(() -> variant(tag));
    }
    private static WireValue observed(Slot<JsonValue> observed) {
        if (observed instanceof Absent<JsonValue>) return variant("Absent");
        if (observed instanceof NullSlot<JsonValue>) return variant("Null");
        return variant("Present", toExact(WireJson.toWire(((Present<JsonValue>)observed).value())));
    }
    private static WireValue evaluate(WireValue input) throws Exception {
        Context context;
        WireValue reference, before;
        try {
            SemanticTypes.SemanticGraph graph = readField(input, "graph", value -> SemanticGraphWire.decodeGraph(value, "$", SemanticGraphWire.GraphReading.DEFAULT_MATERIALIZATION));
            context = new Context(graph);
            reference = readField(input, "reference", value -> { SemanticGraphWire.typeRef(value, "$"); return value; });
            before = readField(input, "before", DefaultMaterializationCompare::exactValue);
            readField(input, "tamper", SemanticValues::b);
        } catch (WireException failure) {
            return obj("id", f(input, "id"), "status", str("Wire"), "classification", str(switch (failure.failure()) {
                case WireFailure.UnsupportedSchema unused -> "UnsupportedSchema";
                case WireFailure.UnknownField unused -> "UnknownField";
                case WireFailure.UnknownTag unused -> "UnknownTag";
                case WireFailure.Syntax unused -> "Syntax";
            }), "path", str(failure.failure().path()));
        }
        WireValue wire = ((ObjectValue)input).get("wire");
        if (wire != null && firstDuplicateKey(before) != null) return obj("id", f(input, "id"), "status", str("Wire"), "classification", str("DuplicateField"), "path", str("$"));
        try {
            DefaultedValue result;
            try {
                if (wire != null && !encodeWire(readJson(s(wire))).equals(encodeWire(before))) throw new IllegalStateException("wire and exact input differ");
                result = wire == null ? context.materializeDefaults(reference, before) : context.decodeWithDefaults(reference, s(wire));
            }
            catch (WireException failure) { return obj("id", f(input, "id"), "status", str("Wire"), "classification", str("Syntax"), "path", str("$")); }
            DefaultedValue second = context.materializeDefaults(reference, result.value());
            List<Member> row = new ArrayList<>(((ObjectValue)obj("id", f(input, "id"), "status", str("Accepted"), "value", toExact(result.value()), "applications", applications(result.applications()), "second_value", toExact(second.value()), "second_applications", applications(second.applications()), "input", toExact(before))).members());
            if (b(f(input, "tamper"))) {
                DefaultApplication first = result.applications().getFirst();
                WireValue source = f(first.typeRef(), "source");
                WireValue wrongRef = replace(first.typeRef(), "source", replace(source, "document_id", str(s(f(source, "document_id"))+"-forged")));
                List<WireValue> pointer = new ArrayList<>(a(f(first.origin(), "pointer"))); pointer.add(str("forged"));
                List<WireValue> path = new ArrayList<>(first.valuePath()); path.add(variant("Field", str("forged")));
                List<DefaultApplication> forged = List.of(new DefaultApplication(first.valuePath(), wrongRef, first.origin(), first.value()), new DefaultApplication(first.valuePath(), first.typeRef(), replace(first.origin(), "pointer", arr(pointer)), first.value()), new DefaultApplication(path, first.typeRef(), first.origin(), first.value()), new DefaultApplication(first.valuePath(), first.typeRef(), first.origin(), new BooleanValue(true)));
                List<WireValue> checks = new ArrayList<>();
                for (DefaultApplication item : forged) { List<DefaultApplication> all = new ArrayList<>(result.applications()); all.set(0, item); checks.add(new BooleanValue(context.checkDefaultApplications(before, result.value(), all))); }
                row.add(new Member("certificates", arr(checks)));
            }
            return new ObjectValue(row);
        } catch (ValueRejection failure) {
            WireValue typeRef = failure.typeRef();
            WireValue definitionRef = obj("source", f(typeRef, "source"), "name", f(typeRef, "definition_name"));
            return obj("id", f(input, "id"), "status", str("Rejected"), "type_ref", typeRef, "definition_ref", definitionRef, "origin", failure.origin(), "value_path", arr(failure.path()), "condition", condition(failure.condition()), "observed", observed(failure.observed()), "reference_trace", arr(failure.referenceTrace()));
        } catch (ValueProcessingFailure failure) {
            if (failure.kind() == ValueProcessingFailureKind.CERTIFICATE_MISMATCH) return obj("id", f(input, "id"), "status", str("CertificateMismatch"), "condition", str(failure.condition()));
            return obj("id", f(input, "id"), "status", str("Unresolved"), "obligations", arr(failure.obligations().stream().map(SemanticGraphWire::obligationWire).toList()));
        }
    }
    public static void main(String[] args) throws Exception {
        try (BufferedReader input = new BufferedReader(new InputStreamReader(System.in)); PrintWriter output = new PrintWriter(System.out, true)) {
            for (String line; (line = input.readLine()) != null;) {
                WireValue json = readJson(line);
                WireValue row;
                try { row = evaluate(json); }
                catch (Exception failure) { row = obj("id", f(json, "id"), "status", str("AdapterFailure"), "message", str(failure.toString())); }
                output.println(encodeWire(row));
            }
        }
    }
}
