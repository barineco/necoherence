// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import necoherence.composition.SemanticComposition.TypeRef;
import necoherence.semantic.SemanticTypes.SourceRef;
import necoherence.semantic.SemanticValues.Member;
import necoherence.semantic.SemanticValues.ObjectValue;
import necoherence.semantic.WireFailure.UnknownField;
import necoherence.semantic.WireFailure.WireException;
import org.junit.jupiter.api.Test;

/** Lean {@code keys} at the direct decoders of the semantic graph and the canonical profile records. */
final class SemanticGraphWireKeysTest {
    private static final SourceRef SOURCE = new SourceRef("owner", "1", "spec", "a".repeat(64), "", Optional.empty());

    @Test void profileWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue profile = withExtra(f(SemanticLibraryFixture.library(), "profile"), "note");
        WireException failure = assertThrows(WireException.class,
                () -> SemanticGraphWire.profile(profile, "$.profile"));
        assertEquals(new UnknownField("$.profile.note", "note"), failure.failure());
    }

    @Test void formatAbsoluteUriWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue rule = fields("AbsoluteUri", withExtra(obj("max_bytes", NIL), "note"));
        WireException failure = assertThrows(WireException.class, () -> SemanticGraphWire.formatRule(rule));
        assertEquals(new UnknownField("$.note", "note"), failure.failure());
    }

    @Test void formatAsciiDfaWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue rule = variant("AsciiDfa", withExtra(obj("state_count", str("1"), "initial_state", str("0"),
                "accepting_states", arr(List.of(str("0"))), "transitions", arr(List.of())), "alpha"));
        WireException failure = assertThrows(WireException.class, () -> SemanticGraphWire.formatRule(rule));
        assertEquals(new UnknownField("$.alpha", "alpha"), failure.failure());
    }

    @Test void sourceRefWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue graph = obj("profile", f(SemanticLibraryFixture.library(), "profile"), "nodes", arr(List.of()),
                "source_refs", arr(List.of(withExtra(SemanticGraphWire.sourceRefWire(SOURCE), "note"))));
        WireException failure = assertThrows(WireException.class, () -> SemanticGraphWire.decodeGraph(graph));
        assertEquals(new UnknownField("$.source_refs[0].note", "note"), failure.failure());
    }

    @Test void sourceIdentityWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue profile = withMember(f(SemanticLibraryFixture.library(), "profile"), "source_refs",
                arr(List.of(withExtra(SemanticLibraryFixture.source, "note"))));
        WireException failure = assertThrows(WireException.class,
                () -> SemanticGraphWire.profile(profile, "$.profile"));
        assertEquals(new UnknownField("$.profile.source_refs[0].note", "note"), failure.failure());
    }

    @Test void profileRefWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue profile = f(SemanticLibraryFixture.library(), "profile");
        WireValue reference = withExtra(f(profile, "reference"), "note");
        WireException failure = assertThrows(WireException.class,
                () -> SemanticGraphWire.profile(withMember(profile, "reference", reference), "$.profile"));
        assertEquals(new UnknownField("$.profile.reference.note", "note"), failure.failure());
    }

    @Test void typeRefWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue alias = fields("Alias", obj("target", withExtra(SemanticGraphWire.typeRefWire(typeRef()), "note"),
                "reference_text", str("Name")));
        WireException failure = assertThrows(WireException.class, () -> SemanticGraphWire.shape(alias));
        assertEquals(new UnknownField("$.target.note", "note"), failure.failure());
    }

    @Test void occurrenceWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue origin = withExtra(obj("source", SemanticGraphWire.sourceRefWire(SOURCE), "pointer", arr(List.of())), "note");
        WireValue field = obj("wire_name", str("n"), "slot", slot(), "origin", origin);
        WireValue product = variant("Product", obj("fields", arr(List.of(field)), "extras", variant("Reject")));
        WireException failure = assertThrows(WireException.class, () -> SemanticGraphWire.shape(product));
        assertEquals(new UnknownField("$.fields[0].origin.note", "note"), failure.failure());
    }

    @Test void productFieldWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue field = withExtra(obj("wire_name", str("n"), "slot", slot(), "origin", origin()), "note");
        WireValue product = variant("Product", obj("fields", arr(List.of(field)), "extras", variant("Reject")));
        WireException failure = assertThrows(WireException.class, () -> SemanticGraphWire.shape(product));
        assertEquals(new UnknownField("$.fields[0].note", "note"), failure.failure());
    }

    @Test void taggedUnionBranchWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue branch = withExtra(obj("target", SemanticGraphWire.typeRefWire(typeRef()), "wire_tag", str("x"),
                "selector", variant("InternalTag"), "origin", origin()), "note");
        WireValue union = variant("TaggedUnion", obj("branches", arr(List.of(branch))));
        WireException failure = assertThrows(WireException.class, () -> SemanticGraphWire.shape(union));
        assertEquals(new UnknownField("$.branches[0].note", "note"), failure.failure());
    }

    @Test void allowExtrasWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue allow = fields("Allow", withExtra(obj("key_format", NIL, "value", element()), "note"));
        WireValue product = variant("Product", obj("fields", arr(List.of()), "extras", allow));
        WireException failure = assertThrows(WireException.class, () -> SemanticGraphWire.shape(product));
        assertEquals(new UnknownField("$.extras.note", "note"), failure.failure());
    }

    @Test void sealedRefinementWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue refinement = withExtra(obj("key", str("k"), "leaf", variant("Integer", integerSpec())), "note");
        WireValue sealed = fields("Sealed", obj("tag", str("$type"), "refinements", arr(List.of(refinement))));
        WireException failure = assertThrows(WireException.class, () -> SemanticGraphWire.shape(sealed));
        assertEquals(new UnknownField("$.refinements[0].note", "note"), failure.failure());
    }

    @Test void aliasWithAnExtraOuterMemberIsAnUnknownFieldAtItsPath() {
        WireValue alias = withExtra(fields("Alias", obj("target", SemanticGraphWire.typeRefWire(typeRef()),
                "reference_text", str("Name"))), "note");
        WireException failure = assertThrows(WireException.class, () -> SemanticGraphWire.shape(alias));
        assertEquals(new UnknownField("$.note", "note"), failure.failure());
    }

    @Test void decimalBoundWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue bound = withExtra(obj("mantissa", str("1"), "scale", str("0"), "exclusive", new BooleanValue(false)), "note");
        WireValue decimal = variant("Decimal", obj("minimum", bound, "maximum", NIL));
        WireException failure = assertThrows(WireException.class, () -> SemanticGraphWire.shape(decimal));
        assertEquals(new UnknownField("$.minimum.note", "note"), failure.failure());
    }

    @Test void integerSpecWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue spec = withExtra(integerSpec(), "note");
        WireException failure = assertThrows(WireException.class, () -> SemanticGraphWire.shape(variant("Integer", spec)));
        assertEquals(new UnknownField("$.note", "note"), failure.failure());
    }

    @Test void stringSpecWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue spec = withExtra(obj("format", NIL, "lengths", arr(List.of()), "wrapper", NIL, "const_value", NIL,
                "enum_values", NIL, "examples", arr(List.of()), "default_value", NIL), "note");
        WireException failure = assertThrows(WireException.class, () -> SemanticGraphWire.shape(variant("String", spec)));
        assertEquals(new UnknownField("$.note", "note"), failure.failure());
    }

    @Test void booleanBodyWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue spec = withExtra(obj("const_value", NIL, "default_value", NIL), "note");
        WireException failure = assertThrows(WireException.class, () -> SemanticGraphWire.shape(variant("Boolean", spec)));
        assertEquals(new UnknownField("$.note", "note"), failure.failure());
    }

    @Test void sealedBodyWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue sealed = fields("Sealed", withExtra(obj("tag", str("$type"), "refinements", arr(List.of())), "note"));
        WireException failure = assertThrows(WireException.class, () -> SemanticGraphWire.shape(sealed));
        assertEquals(new UnknownField("$.note", "note"), failure.failure());
    }

    private static WireValue obligation() {
        return obj("type_ref", SemanticGraphWire.typeRefWire(typeRef()), "origin", origin(), "value_path", arr(List.of()),
                "profile", f(f(SemanticLibraryFixture.library(), "profile"), "reference"), "reason", variant("MembershipBound"));
    }

    @Test void obligationWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        assertEquals(1, SemanticGraphWire.obligation(obligation(), "$").valuePath().size() + 1);
        WireException failure = assertThrows(WireException.class,
                () -> SemanticGraphWire.obligation(withExtra(obligation(), "note"), "$"));
        assertEquals(new UnknownField("$.note", "note"), failure.failure());
        WireException origin = assertThrows(WireException.class,
                () -> SemanticGraphWire.obligation(withMember(obligation(), "origin", withExtra(origin(), "note")), "$"));
        assertEquals(new UnknownField("$.origin.note", "note"), origin.failure());
    }

    @Test void reasonWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireException unit = assertThrows(WireException.class,
                () -> SemanticGraphWire.reason(withExtra(variant("MembershipBound"), "note"), "$.reason"));
        assertEquals(new UnknownField("$.reason.note", "note"), unit.failure());
        WireException tuple = assertThrows(WireException.class,
                () -> SemanticGraphWire.reason(withExtra(variant("UnknownFormat", str("format")), "note"), "$.reason"));
        assertEquals(new UnknownField("$.reason.note", "note"), tuple.failure());
    }

    @Test void evaluationProvenanceWithAnExtraMemberIsAnUnknownFieldAtItsPath() {
        WireValue provenance = obj("operation", str("validate"), "type_ref", SemanticGraphWire.typeRefWire(typeRef()),
                "value_path", arr(List.of()));
        assertEquals("validate", SemanticGraphWire.evaluationProvenance(provenance, "$").operation());
        WireException failure = assertThrows(WireException.class,
                () -> SemanticGraphWire.evaluationProvenance(withExtra(provenance, "note"), "$"));
        assertEquals(new UnknownField("$.note", "note"), failure.failure());
    }

    @Test void graphRejectsAnExtraMemberOfTheGraphAndOfANode() {
        WireValue profile = f(SemanticLibraryFixture.library(), "profile");
        WireValue node = obj("reference", SemanticGraphWire.typeRefWire(typeRef()),
                "shape", variant("Unit"), "description", NIL, "attributes", arr(List.of()), "extensions", arr(List.of()));
        WireValue graph = obj("profile", profile, "nodes", arr(List.of(node)), "source_refs", arr(List.of()));
        assertEquals(1, decode(graph, SemanticGraphWire.GraphReading.CANONICAL).nodes().size());
        assertEquals(new UnknownField("$.note", "note"), assertThrows(WireException.class,
                () -> decode(withExtra(graph, "note"), SemanticGraphWire.GraphReading.CANONICAL)).failure());
        WireValue extraNode = withMember(graph, "nodes", arr(List.of(withExtra(node, "note"))));
        assertEquals(new UnknownField("$.nodes[0].note", "note"), assertThrows(WireException.class,
                () -> decode(extraNode, SemanticGraphWire.GraphReading.CANONICAL)).failure());
        WireValue attribute = withMember(graph, "nodes", arr(List.of(withMember(node, "attributes", arr(List.of(withExtra(origin(), "note")))))));
        assertEquals(new UnknownField("$.nodes[0].attributes[0].note", "note"), assertThrows(WireException.class,
                () -> decode(attribute, SemanticGraphWire.GraphReading.CANONICAL)).failure());
        WireValue sourceRefs = withMember(graph, "source_refs", arr(List.of(withExtra(SemanticGraphWire.sourceRefWire(SOURCE), "note"))));
        assertEquals(new UnknownField("$.source_refs[0].note", "note"), assertThrows(WireException.class,
                () -> decode(sourceRefs, SemanticGraphWire.GraphReading.CANONICAL)).failure());
    }

    @Test void graphDecidesTheShapeTagWhenTheShapeIsReadAfterTheReference() {
        WireValue profile = f(SemanticLibraryFixture.library(), "profile");
        WireValue bytes = variant("Bytes", obj("minimum", NIL, "maximum", NIL));
        WireValue node = obj("reference", SemanticGraphWire.typeRefWire(typeRef()),
                "shape", bytes, "description", NIL, "attributes", arr(List.of()), "extensions", arr(List.of()));
        WireValue graph = obj("profile", profile, "nodes", arr(List.of(node)), "source_refs", arr(List.of()));
        assertEquals(new WireFailure.UnknownTag("$.nodes[0].shape.tag", "Bytes"), assertThrows(WireException.class,
                () -> decode(graph, SemanticGraphWire.GraphReading.DEFAULT_MATERIALIZATION)).failure());
        WireValue later = withMember(graph, "nodes", arr(List.of(withMember(node, "attributes", arr(List.of(withExtra(origin(), "note")))))));
        assertEquals(new WireFailure.UnknownTag("$.nodes[0].shape.tag", "Bytes"), assertThrows(WireException.class,
                () -> decode(later, SemanticGraphWire.GraphReading.DEFAULT_MATERIALIZATION)).failure());
        WireValue earlier = withMember(graph, "nodes", arr(List.of(withMember(node, "reference",
                withExtra(SemanticGraphWire.typeRefWire(typeRef()), "note")))));
        assertEquals(new UnknownField("$.nodes[0].reference.note", "note"), assertThrows(WireException.class,
                () -> decode(earlier, SemanticGraphWire.GraphReading.DEFAULT_MATERIALIZATION)).failure());
        assertEquals(1, decode(graph, SemanticGraphWire.GraphReading.CANONICAL).nodes().size());
    }

    @Test void publicValidationGraphReadsTheShapeBeforeTheReferenceAndIgnoresTheMembersLeanDoesNotRead() {
        WireValue profile = f(SemanticLibraryFixture.library(), "profile");
        WireValue flag = variant("Boolean", obj("const_value", NIL, "default_value", NIL));
        WireValue node = obj("reference", withExtra(SemanticGraphWire.typeRefWire(typeRef()), "note"),
                "shape", flag, "description", NIL, "attributes", arr(List.of()), "extensions", arr(List.of()));
        WireValue graph = obj("profile", profile, "nodes", arr(List.of(node)), "source_refs", arr(List.of()));
        assertEquals(new WireFailure.UnknownTag("$.nodes[0].shape.tag", "Boolean"), assertThrows(WireException.class,
                () -> decode(graph, SemanticGraphWire.GraphReading.PUBLIC_VALIDATION)).failure());
        WireValue text = variant("String", obj("format", NIL, "lengths", arr(List.of()), "wrapper", NIL, "const_value", NIL,
                "enum_values", NIL, "examples", arr(List.of()), "default_value", NIL));
        WireValue valid = obj("reference", SemanticGraphWire.typeRefWire(typeRef()), "shape", text, "description", NIL,
                "attributes", arr(List.of(withExtra(origin(), "note"))), "extensions", arr(List.of()));
        WireValue ignored = obj("profile", profile, "nodes", arr(List.of(valid)), "source_refs", arr(List.of(str("not a source"))));
        assertEquals(1, decode(ignored, SemanticGraphWire.GraphReading.PUBLIC_VALIDATION).nodes().size());
    }

    private static SemanticTypes.SemanticGraph decode(WireValue graph, SemanticGraphWire.GraphReading reading) {
        return SemanticGraphWire.decodeGraph(graph, "$", reading);
    }

    private static TypeRef typeRef() {
        return new TypeRef(SOURCE, "Name", List.of());
    }

    private static WireValue origin() {
        return obj("source", SemanticGraphWire.sourceRefWire(SOURCE), "pointer", arr(List.of()));
    }

    private static WireValue slot() {
        return obj("type_ref", SemanticGraphWire.typeRefWire(typeRef()), "required", new BooleanValue(true),
                "nullable", new BooleanValue(false));
    }

    private static WireValue element() {
        return obj("type_ref", SemanticGraphWire.typeRefWire(typeRef()), "nullable", new BooleanValue(false));
    }

    private static WireValue integerSpec() {
        return obj("domain", NIL, "minimum", NIL, "maximum", NIL, "const_value", NIL,
                "enum_values", NIL, "default_value", NIL);
    }

    private static WireValue withExtra(WireValue value, String key) {
        List<Member> members = new ArrayList<>(((ObjectValue) value).members());
        members.add(new Member(key, str("x")));
        return new ObjectValue(members);
    }

    private static WireValue withMember(WireValue value, String key, WireValue member) {
        List<Member> members = new ArrayList<>(((ObjectValue) value).members());
        members.replaceAll(existing -> existing.key().equals(key) ? new Member(key, member) : existing);
        return new ObjectValue(members);
    }
}
