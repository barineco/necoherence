// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticGeneration.*;
import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.util.ArrayList;
import java.util.List;
import necoherence.semantic.SemanticGeneration.GenerationFailureKind;
import necoherence.semantic.WireFailure.Syntax;
import necoherence.semantic.WireFailure.UnknownField;
import org.junit.jupiter.api.Test;

final class SignatureAdmissionStageTest {
    private static final WireValue ENTRIES = SemanticLibraryFixture.entries;

    private static WireValue library() { return SemanticLibraryFixture.library(); }

    private static WireValue withNodes(WireValue library, List<WireValue> added) {
        List<WireValue> nodes = new ArrayList<>(a(f(library, "nodes")));
        nodes.addAll(added);
        return SemanticLibraryFixture.replace(library, "nodes", arr(nodes));
    }

    private static WireValue aliasNode(String id, String target) {
        return obj("id", str(id), "shape", fields("Alias", obj("target", str(target))));
    }

    private static WireValue basisFor(WireValue library, WireValue composition) {
        return TypeSignatures.computeBasis(library, ENTRIES, composition);
    }

    private static List<Member> exchangeMembers(WireValue library, WireValue composition) {
        return new ArrayList<>(List.of(new Member("schema", str("ncoh-checked-generation@5")),
                new Member("basis", basisFor(library, composition)), new Member("signatures", library),
                new Member("composition", composition), new Member("entrypoints", ENTRIES)));
    }

    private static CheckedGeneration admit(WireValue library, WireValue composition) throws GenerationFailure {
        return TypeSignatures.admitGeneration(new GenerationBasis(basisFor(library, composition), nil(composition) ? null : GoalObservations.of(composition)),
                encodeWire(new ObjectValue(exchangeMembers(library, composition))));
    }

    private static GenerationFailure rejected(WireValue library, WireValue composition) {
        return assertThrows(GenerationFailure.class, () -> admit(library, composition));
    }

    private static GenerationFailure rejectedExchange(List<Member> members) {
        WireValue library = library();
        return assertThrows(GenerationFailure.class, () -> TypeSignatures.admitGeneration(
                new GenerationBasis(basisFor(library, NIL), null), encodeWire(new ObjectValue(members))));
    }

    private static List<Member> replaced(List<Member> members, String key, WireValue value) {
        return members.stream().map(member -> member.key().equals(key) ? new Member(key, value) : member).toList();
    }

    @Test void profileFailureOutranksDuplicateNodeIdentity() {
        WireValue library = library();
        WireValue reference = f(f(library, "profile"), "reference");
        WireValue profile = SemanticLibraryFixture.replace(f(library, "profile"), "reference",
                SemanticLibraryFixture.replace(reference, "identity", str("")));
        WireValue broken = SemanticLibraryFixture.replace(withNodes(library, List.of(a(f(library, "nodes")).get(0))),
                "profile", profile);
        GenerationFailure failure = rejected(broken, NIL);
        assertEquals(GenerationFailureKind.LIBRARY, failure.kind());
        assertEquals("PR01", failure.condition());
    }

    @Test void duplicateNodeIdentityIsTheLibraryPredicateLb01() {
        WireValue library = library();
        GenerationFailure failure = rejected(withNodes(library, List.of(a(f(library, "nodes")).get(0))), NIL);
        assertEquals(GenerationFailureKind.LIBRARY, failure.kind());
        assertEquals("LB01", failure.condition());
    }

    @Test void aliasCycleIsAdmittedAndLeavesNoResolvedShape() throws Exception {
        WireValue cyclic = withNodes(library(), List.of(aliasNode("loop-a", "loop-b"), aliasNode("loop-b", "loop-a")));
        assertNull(ResolvedShapeAccess.resolve(admit(cyclic, NIL).valueContext(), TypeSignatures.typeReference("loop-a")));
        WireValue selfLoop = withNodes(library(), List.of(aliasNode("loop-self", "loop-self")));
        assertNull(ResolvedShapeAccess.resolve(admit(selfLoop, NIL).valueContext(), TypeSignatures.typeReference("loop-self")));
    }

    @Test void compositionKeysAreCheckedBeforeTheProblemIsDecoded() {
        WireValue extra = obj("problem", obj(), "derivation", obj(), "extra", str("x"));
        GenerationFailure unknown = rejected(library(), extra);
        assertEquals(GenerationFailureKind.COMPOSITION_WIRE, unknown.kind());
        assertEquals(new UnknownField("$.extra", "extra"), unknown.wireFailure());
        GenerationFailure missing = rejected(library(), obj("problem", obj()));
        assertEquals(GenerationFailureKind.COMPOSITION_WIRE, missing.kind());
        assertEquals(new Syntax("$.derivation", "missing field"), missing.wireFailure());
    }

    @Test void schemaMismatchReportsTheClosedKeysBeforeTheSchema() {
        List<Member> mismatched = replaced(exchangeMembers(library(), NIL), "schema", str("ncoh-checked-generation@9"));
        GenerationFailure schema = rejectedExchange(mismatched);
        assertEquals(GenerationFailureKind.UNSUPPORTED_SCHEMA, schema.kind());
        List<Member> extra = new ArrayList<>(mismatched);
        extra.add(new Member("extra", num(java.math.BigInteger.ONE)));
        GenerationFailure unknown = rejectedExchange(extra);
        assertEquals(GenerationFailureKind.EXCHANGE_WIRE, unknown.kind());
        assertEquals(new UnknownField("$.extra", "extra"), unknown.wireFailure());
        List<Member> missing = mismatched.stream().filter(member -> !member.key().equals("entrypoints")).toList();
        GenerationFailure absent = rejectedExchange(missing);
        assertEquals(GenerationFailureKind.EXCHANGE_WIRE, absent.kind());
        assertInstanceOf(Syntax.class, absent.wireFailure());
        assertEquals("$.entrypoints", absent.wireFailure().path());
        List<Member> both = new ArrayList<>(missing);
        both.add(new Member("extra", num(java.math.BigInteger.ONE)));
        assertEquals(new UnknownField("$.extra", "extra"), rejectedExchange(both).wireFailure());
    }

    @Test void deepExactJsonInAnAnnotationIsReadWithoutAFixedNestingLimit() {
        WireValue library = library();
        List<WireValue> annotations = new ArrayList<>(a(f(library, "annotations")));
        annotations.add(obj("target", variant("Library"), "key", str("deep"), "value", str("@@DEEP@@")));
        WireValue annotated = SemanticLibraryFixture.replace(library, "annotations", arr(annotations));
        List<Member> members = replaced(exchangeMembers(library, NIL), "signatures", annotated);
        int depth = 5_000;
        String deep = "{\"tag\":\"Array\",\"items\":[".repeat(depth) + "{\"tag\":\"Null\"}" + "]}".repeat(depth);
        String text = encodeWire(new ObjectValue(members)).replace("\"@@DEEP@@\"", deep);
        GenerationFailure[] failure = new GenerationFailure[1];
        Throwable[] unexpected = new Throwable[1];
        Thread reader = new Thread(null, () -> {
            try { TypeSignatures.admitGeneration(new GenerationBasis(basisFor(library, NIL), null), text); }
            catch (GenerationFailure rejected) { failure[0] = rejected; }
            catch (Throwable thrown) { unexpected[0] = thrown; }
        }, "deep-annotation", 256L << 20);
        reader.start();
        try { reader.join(); } catch (InterruptedException interrupted) { throw new IllegalStateException(interrupted); }
        assertEquals(null, unexpected[0]);
        assertEquals(GenerationFailureKind.CERTIFICATE, failure[0].kind());
    }
}
