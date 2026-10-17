// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import static necoherence.semantic.SemanticValues.*;
import static necoherence.semantic.SemanticGeneration.*;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.PrintWriter;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;

public final class DefaultMaterializationCompare {
    private static WireValue exactValue(WireValue value) {
        return switch (tag(value)) {
            case "Null" -> NIL;
            case "Bool", "String" -> f(value, "value");
            case "Integer" -> num(new BigInteger(s(f(value, "value"))));
            case "Decimal" -> new DecimalValue(s(f(value, "text")));
            case "Array" -> arr(a(f(value, "items")).stream().map(DefaultMaterializationCompare::exactValue).toList());
            case "Object" -> new ObjectValue(a(f(value, "members")).stream().map(item -> new Member(s(f(item, "key")), exactValue(f(item, "value")))).toList());
            default -> throw new IllegalArgumentException("exact JSON tag");
        };
    }
    private static WireValue applications(List<DefaultApplication> applications) {
        return arr(applications.stream().map(item -> obj("value_path", arr(item.valuePath()), "type_ref", item.typeRef(), "origin", item.origin(), "value", toExact(item.value()))).toList());
    }
    private static WireValue replace(WireValue value, String key, WireValue replacement) {
        return new ObjectValue(((ObjectValue)value).members().stream().map(member -> member.key().equals(key) ? new Member(key, replacement) : member).toList());
    }
    private static WireValue evaluate(WireValue input) throws Exception {
        WireValue graph = f(input, "graph"), reference = f(input, "reference"), before = exactValue(f(input, "before"));
        Context context = new Context(graph);
        try {
            WireValue wire = ((ObjectValue)input).get("wire");
            DefaultedValue result = wire == null ? context.materializeDefaults(reference, before) : context.decodeWithDefaults(reference, s(wire));
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
        } catch (ValueFailure failure) {
            String condition = failure.condition().replace(": ", ":");
            if (condition.startsWith("InvalidJson:")) return obj("id", f(input, "id"), "status", str("Wire"), "classification", str(condition.toLowerCase().contains("duplicate") ? "DuplicateField" : "Syntax"));
            if (!failure.obligations().isEmpty()) return obj("id", f(input, "id"), "status", str("Unresolved"), "obligations", arr(failure.obligations()));
            if (condition.equals("MembershipBound") || condition.equals("UnresolvedType")) return obj("id", f(input, "id"), "status", str("Unresolved"), "obligations", arr(List.of(obj("type_ref", failure.typeRef(), "origin", failure.origin(), "value_path", arr(failure.path()), "profile", f(f(graph, "profile"), "reference"), "reason", variant(condition)))));
            return obj("id", f(input, "id"), "status", str("Rejected"), "type_ref", failure.typeRef(), "origin", failure.origin(), "value_path", arr(failure.path()), "condition", str(condition), "reference_trace", arr(failure.referenceTrace()));
        }
    }
    public static void main(String[] args) throws Exception {
        try (BufferedReader input = new BufferedReader(new InputStreamReader(System.in)); PrintWriter output = new PrintWriter(System.out, true)) {
            for (String line; (line = input.readLine()) != null;) output.println(encodeWire(evaluate(readJson(line))));
        }
    }
}
