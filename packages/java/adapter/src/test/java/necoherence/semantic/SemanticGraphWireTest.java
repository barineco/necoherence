// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.assertEquals;

import java.math.BigInteger;
import java.util.List;
import java.util.Optional;
import necoherence.semantic.SemanticTypes.*;
import org.junit.jupiter.api.Test;

final class SemanticGraphWireTest {
    private static final WireValue SOURCE = obj("repository", str("r"), "revision", str("1"), "path", str("p"),
            "content_digest", str("0".repeat(64)), "document_id", str("d"), "declared_revision", NIL);

    private static WireValue ref(String name) { return obj("source", SOURCE, "definition_name", str(name), "pointer", arr(List.of())); }

    private static WireValue origin() { return obj("source", SOURCE, "pointer", arr(List.of())); }

    private static WireValue lengthSpec(String maximum) {
        return obj("format", variant("Named", str("f")), "lengths", arr(List.of(obj("unit", variant("Graphemes"),
                "minimum", NIL, "maximum", str(maximum)))), "wrapper", str("w"), "const_value", str("c"),
                "enum_values", arr(List.of(str("c"))), "examples", arr(List.of(str("e"))), "default_value", NIL);
    }

    @Test void everyShapeSurvivesDecodeAndEncode() {
        WireValue slot = obj("type_ref", ref("a"), "required", new BooleanValue(true), "nullable", new BooleanValue(false));
        WireValue element = obj("type_ref", ref("a"), "nullable", new BooleanValue(true));
        List<WireValue> shapes = List.of(
                variant("Boolean", obj("const_value", new BooleanValue(true), "default_value", NIL)),
                variant("Integer", obj("domain", str("d"), "minimum", str("-1"), "maximum", str("9"), "const_value", NIL,
                        "enum_values", arr(List.of(str("1"), str("2"))), "default_value", str("1"))),
                variant("Decimal", obj("minimum", obj("mantissa", str("-15"), "scale", str("1"), "exclusive", new BooleanValue(true)), "maximum", NIL)),
                variant("String", lengthSpec("3")),
                variant("Bytes", obj("minimum", str("1"), "maximum", NIL)),
                variant("Product", obj("fields", arr(List.of(obj("wire_name", str("f"), "slot", slot, "origin", origin()))),
                        "extras", fields("Allow", obj("key_format", variant("Named", str("k")), "value", element)))),
                variant("Array", obj("item", element, "min_length", str("1"), "max_length", NIL)),
                fields("Alias", obj("target", ref("b"), "reference_text", str("b"))),
                variant("TaggedUnion", obj("branches", arr(List.of(
                        obj("target", ref("a"), "wire_tag", str("x"), "selector", variant("InternalTag"), "origin", origin()),
                        obj("target", ref("a"), "wire_tag", str("y"), "selector", variant("MemberShape", arr(List.of(
                                obj("key", str("k"), "test", variant("Absent")), obj("key", str("m"), "test", variant("Format", str("f")))))), "origin", origin()),
                        obj("target", ref("a"), "wire_tag", str("z"), "selector", variant("Kind", variant("Object")), "origin", origin()),
                        obj("target", ref("a"), "wire_tag", str("o"), "selector", variant("Otherwise"), "origin", origin()))))),
                fields("Sealed", obj("tag", str("s"), "refinements", arr(List.of(obj("key", str("k"),
                        "leaf", variant("Integer", obj("domain", NIL, "minimum", NIL, "maximum", NIL, "const_value", NIL,
                                "enum_values", NIL, "default_value", NIL))))))),
                variant("Never"), variant("Unknown", variant("OrdinaryObject")), variant("Unit"),
                fields("RawBody", obj("encoding", str("base64"))), fields("Opaque", obj("type_name", str("t"))));
        for (WireValue shape : shapes) {
            TypeShape decoded = SemanticGraphWire.shape(shape);
            assertEquals(decoded, SemanticGraphWire.shape(SemanticGraphWire.shapeWire(decoded)), encodeWire(shape));
        }
    }

    @Test void everyFormatRuleSurvivesDecodeAndEncode() {
        WireValue dfa = obj("state_count", str("2"), "initial_state", str("0"), "accepting_states", arr(List.of(str("1"))),
                "transitions", arr(List.of(obj("from_state", str("0"), "first", str("97"), "last", str("97"), "to_state", str("1")))));
        List<WireValue> rules = List.of(variant("Literal", str("a")), variant("Sequence", arr(List.of(variant("Text")))),
                variant("Optional", variant("Text")),
                fields("Labels", obj("separator", str("."), "min_count", str("1"), "max_count", NIL, "total_max", str("9"), "rule", variant("Text"))),
                fields("Bounded", obj("unit", variant("Utf8Bytes"), "maximum", str("3"), "rule", variant("Text"))),
                variant("AsciiDfa", dfa),
                fields("Identifier", obj("first_alphabet", str("a"), "rest_alphabet", str("b"), "exact_length", NIL,
                        "min_length", str("1"), "max_length", str("4"), "forbidden", arr(List.of(str("x"))))),
                variant("Timestamp", obj("allow_second_60", new BooleanValue(false), "minimum_year", str("1"),
                        "maximum_year", str("9999"), "rejectUtcYearOutsideRange", new BooleanValue(true))),
                fields("AbsoluteUri", obj("max_bytes", str("9"))), fields("LanguageTag", obj("grandfathered", arr(List.of(str("i-klingon"))))),
                variant("Choice", arr(List.of(variant("Text")))), variant("Text"), variant("Not", variant("Text")));
        for (WireValue rule : rules) {
            FormatRule decoded = SemanticGraphWire.formatRule(rule);
            assertEquals(decoded, SemanticGraphWire.formatRule(SemanticGraphWire.formatRuleWire(decoded)), encodeWire(rule));
        }
    }

    @Test void obligationsSurviveEncodeAndDecode() {
        for (SemanticReason reason : List.<SemanticReason>of(new UnknownFormat("f"), new MissingGraphemeRules(),
                new MissingBytesPolicy(), new UnknownIntegerDomain("d"), new UnknownWrapper("w"), new WrapperPayloadReason("w"),
                new UnknownSealedTag("t"), new DecimalNotAdmitted(), new IntegerBound(), new OpaqueType("o"),
                new MissingTagModel(), new UnresolvedType(), new MembershipBound(), new CertificateMismatchReason("c"))) {
            SemanticObligation obligation = new SemanticObligation(SemanticGraphWire.typeRef(ref("a"), "$"),
                    new OccurrenceRef(SemanticGraphWire.sourceRef(SOURCE, "$"), List.of("p")), List.of(new necoherence.composition.SemanticComposition.Field("f"),
                            new necoherence.composition.SemanticComposition.Index(BigInteger.TWO)),
                    new ProfileRef("i", "r", "d"), reason);
            assertEquals(obligation, SemanticGraphWire.obligation(SemanticGraphWire.obligationWire(obligation), "$"));
        }
    }
}
