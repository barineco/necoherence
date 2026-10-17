// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

package necoherence.tools.renderer;

import static necoherence.semantic.SemanticValues.*;
import java.util.List;
import java.math.BigInteger;
import necoherence.semantic.SemanticValues.WireValue;
import necoherence.semantic.TypeSignatures;

public final class LeanRepresentativeInvariantTest {
    private static final WireValue TRUE = new BooleanValue(true);
    private static final WireValue FALSE = new BooleanValue(false);
    private static final WireValue REFERENCE = obj("identity", str("representative-declarations"), "revision", str("4"),
            "content_digest", str("a".repeat(64)));

    private static WireValue stringSpec(WireValue wrapper) {
        return obj("format", NIL, "lengths", arr(List.of()), "wrapper", wrapper, "const_value", NIL,
                "enum_values", NIL, "examples", arr(List.of()), "default_value", NIL);
    }

    private static WireValue library() {
        WireValue domain = obj("name", str("default"), "reference", REFERENCE, "range", variant("Unbounded"),
                "forms", arr(List.of(variant("Number"))));
        WireValue wrapper = obj("name", str("text-wrapper"), "key", str("text"),
                "payload", variant("Text", NIL));
        WireValue sealedField = obj("key", str("label"), "required", TRUE,
                "leaf", variant("String", stringSpec(NIL)));
        WireValue sealedForm = obj("tag", str("sealed"), "fields", arr(List.of(sealedField)),
                "extras", variant("Reject"));
        WireValue tagModel = obj("key", str("tag"), "format", str("text"),
                "sealed", arr(List.of(sealedForm)));
        WireValue profile = obj("reference", REFERENCE, "source_refs", arr(List.of()),
                "integer_domains", arr(List.of(domain)), "default_integer_domain", str("default"),
                "numbers", obj("decimals", TRUE), "grapheme_rules", NIL,
                "format_bindings", arr(List.of(obj("name", str("text"), "reference", REFERENCE,
                        "rule", variant("Text")))), "bytes_policy", NIL,
                "wrappers", arr(List.of(wrapper)), "tag", tagModel);
        WireValue nodes = arr(List.of(
                obj("id", str("wrapped-text"), "shape", variant("String", stringSpec(str("text-wrapper")))),
                obj("id", str("sealed"), "shape", fields("Sealed", obj("tag", str("sealed"),
                        "refinements", arr(List.of())))),
                obj("id", str("never"), "shape", variant("Never")),
                obj("id", str("decimal"), "shape", variant("Decimal", obj("minimum", NIL, "maximum", NIL))),
                obj("id", str("ordinary"), "shape", variant("Product", obj("fields", arr(List.of()),
                        "extras", variant("Reject"))))));
        WireValue definitions = arr(List.of(obj("id", str("root"), "wire_identity", str("Root"),
                "shape", variant("Value", str("ordinary")))));
        return obj("schema", str("ncoh-type-signatures@1"), "identity", str("representative-declarations"),
                "revision", str("4"), "profile", profile, "sources", arr(List.of()),
                "provenance", arr(List.of()), "groups", arr(List.of()), "annotations", arr(List.of()),
                "nodes", nodes, "definitions", definitions);
    }

    private static WireValue input(String id, String kind, WireValue library) {
        return obj("id", str(id), "kind", str(kind), "library", library);
    }

    private static WireValue valueInput(String id, WireValue library, String type, WireValue value) {
        return obj("id", str(id), "kind", str("value"), "library", library,
                "type_id", str(type), "value", value);
    }

    private static void expect(SemanticInvariantAdapter adapter, WireValue input, String status,
            String field, String expected) throws Exception {
        WireValue result = adapter.evaluate(input);
        if (!s(f(result, "status")).equals(status) || !s(f(result, field)).equals(expected))
            throw new AssertionError(encodeWire(result));
    }

    public static void main(String[] args) throws Exception {
        WireValue valid = library();
        WireValue invalidProfile = TypeSignatures.replace(valid, "profile",
                TypeSignatures.replace(f(valid, "profile"), "reference",
                        TypeSignatures.replace(REFERENCE, "identity", str(""))));
        WireValue duplicate = obj("wire_name", str("duplicate"), "slot",
                obj("type_id", str("wrapped-text"), "required", TRUE, "nullable", FALSE));
        List<WireValue> nodes = a(f(valid, "nodes"));
        WireValue invalidProduct = TypeSignatures.replace(nodes.get(4), "shape",
                variant("Product", obj("fields", arr(List.of(duplicate, duplicate)), "extras", variant("Reject"))));
        WireValue invalidLibrary = TypeSignatures.replace(valid, "nodes",
                arr(List.of(nodes.get(0), nodes.get(1), nodes.get(2), nodes.get(3), invalidProduct)));
        try (SemanticInvariantAdapter adapter = new SemanticInvariantAdapter()) {
            expect(adapter, input("profile-pr01", "profile_admission", invalidProfile), "Rejected", "predicate", "PR01");
            expect(adapter, input("library-lb02", "profile_admission", invalidLibrary), "Rejected", "predicate", "LB02");
            WireValue wrapper = adapter.evaluate(
                    valueInput("object-wrapper", valid, "wrapped-text", obj("text", str("x"))));
            if (!s(f(wrapper, "status")).equals("Accepted")) throw new AssertionError(encodeWire(wrapper));
            expect(adapter, valueInput("object-sealed-tag-format", valid, "sealed", obj("tag", num(BigInteger.ONE), "label", str("x"))),
                    "Rejected", "condition", "InvalidTag");
            expect(adapter, valueInput("never", valid, "never", NIL),
                    "Rejected", "condition", "InvalidDataModel");
            expect(adapter, valueInput("decimal-reject", valid, "decimal", str("1.5")),
                    "Rejected", "condition", "WrongValueKind:decimal");
            WireValue samples = adapter.evaluate(obj("id", str("samples-wrapped-text"), "kind", str("samples"),
                    "library", valid, "type_id", str("wrapped-text"), "max_type_obligations", str("64"),
                    "max_sample_length", str("32")));
            if (!s(f(samples, "status")).equals("Accepted") || n(f(samples, "sample_count")).signum() == 0)
                throw new AssertionError(encodeWire(samples));
        }
        System.out.println("Java representative inputs preserve canonical value conditions and samples entry");
    }
}
