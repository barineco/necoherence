// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticGeneration.*;
import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;

import neco.quotient.Condition;
import neco.quotient.Status;
import java.math.BigInteger;
import java.util.List;
import java.util.Optional;
import necoherence.semantic.SemanticTypes.BytesAlphabet;
import necoherence.semantic.SemanticTypes.BytesPolicy;
import necoherence.semantic.SemanticTypes.NumberModel;
import necoherence.semantic.SemanticTypes.ProfileRef;
import necoherence.semantic.SemanticTypes.SemanticGraph;
import necoherence.semantic.SemanticTypes.VersionedSemanticProfile;
import necoherence.semantic.SemanticValues.Bytes;
import necoherence.semantic.SemanticValues.Context;
import necoherence.semantic.SemanticTypes.GraphemeComponent;
import necoherence.semantic.SemanticTypes.GraphemeProperty;
import necoherence.semantic.SemanticTypes.GraphemeRange;
import necoherence.semantic.SemanticTypes.GraphemeRules;
import necoherence.semantic.SemanticGeneration.CheckedGeneration;
import necoherence.semantic.SemanticGeneration.GenerationBasis;
import necoherence.semantic.SemanticGeneration.GenerationFailure;
import necoherence.semantic.SemanticTypes.FormatRule;
import necoherence.semantic.SemanticTypes.LabelsRule;
import necoherence.semantic.SemanticTypes.LiteralRule;
import necoherence.semantic.WireFailure.WireException;
import org.junit.jupiter.api.Test;

final class SemanticLeanAlignmentTest {
    private static String fixtureText() { return encodeWire(SemanticLibraryFixture.library()); }

    private static void admitWithBasisOf(String libraryText) throws GenerationFailure {
        WireValue entries = SemanticLibraryFixture.entries;
        GenerationBasis basis = TypeSignatures.basis(libraryText, encodeWire(entries));
        WireValue envelope = obj("schema", str("ncoh-checked-generation@5"), "basis", basis.value,
                "signatures", readJson(libraryText), "composition", NIL, "entrypoints", entries);
        CheckedGeneration checked = TypeSignatures.admitGeneration(basis, encodeWire(envelope));
        assertEquals(encodeWire(envelope), encodeWire(checked.input));
    }

    @Test void jsonControlCharactersUseUnicodeEscapes() {
        assertEquals("\"\\u0009\\u0008\\u000c\\n\\r\\u0001\\u001f\"", encodeWire(str("\t\b\f\n\r\u0001\u001f")));
        assertEquals("\"\\u0009\"", necoherence.semantic.ExactJson.encode(necoherence.semantic.ExactJson.str("\t")));
    }

    @Test void duplicateObjectKeysAreRejectedByTheReader() {
        Throwable thrown = assertThrows(RuntimeException.class, () -> readJson("{\"a\":1,\"a\":2}"));
        assertInstanceOf(WireException.class, thrown);
        assertInstanceOf(WireFailure.Syntax.class, ((WireException) thrown).failure());
    }

    @Test void jsonNumbersTakeTheCanonicalLeanForm() {
        assertEquals(num(BigInteger.valueOf(100000)), readJson("1e5"));
        assertEquals(new DecimalValue("1"), readJson("1.0"));
        assertEquals(new DecimalValue("15"), readJson("1.50e1"));
        assertEquals(new DecimalValue("1"), readJson("100e-2"));
        assertEquals(num(BigInteger.valueOf(-100)), readJson("-1e2"));
        assertEquals(new DecimalValue("0.01"), readJson("1e-2"));
        assertEquals(new DecimalValue("0.001"), readJson("0.001"));
    }

    @Test void objectKeysAreWrittenInTheLeanKeyOrder() {
        WireValue value = obj("b", num(BigInteger.ONE), "\uD83D\uDE00", str("x"), "a", num(BigInteger.TWO),
                "\uFF3E", str("y"));
        assertEquals("{\"a\":2,\"b\":1,\"\uFF3E\":\"y\",\"\uD83D\uDE00\":\"x\"}", encodeWire(value));
        assertEquals("{\"a\":2,\"b\":1,\"\uFF3E\":\"y\",\"\uD83D\uDE00\":\"x\"}",
                necoherence.semantic.ExactJson.encode(WireJson.fromWire(value)));
    }

    @Test void naturalNumbersAreWrittenAsDecimalStrings() {
        FormatRule rule = new LabelsRule(",", BigInteger.ONE, Optional.of(BigInteger.TWO), Optional.empty(),
                new LiteralRule("a"));
        WireValue wire = SemanticGraphWire.formatRuleWire(rule);
        assertEquals(str("1"), f(payload(wire), "min_count"));
        assertEquals(str("2"), f(payload(wire), "max_count"));
    }

    @Test void naturalDecodeAcceptsOnlyCanonicalNonnegativeDecimalStrings() {
        assertEquals(BigInteger.valueOf(12), n(str("12")));
        assertThrows(WireException.class, () -> n(str("-1")));
        assertThrows(WireException.class, () -> n(str("+5")));
        assertThrows(WireException.class, () -> n(str("007")));
        assertThrows(WireException.class, () -> n(str("-0")));
        assertThrows(WireException.class, () -> n(num(BigInteger.ONE)));
    }

    @Test void integerDecodeAcceptsOnlyCanonicalDecimalStrings() {
        assertEquals(BigInteger.valueOf(-1), i(str("-1")));
        assertThrows(WireException.class, () -> i(str("+5")));
        assertThrows(WireException.class, () -> i(str("-0")));
        assertThrows(WireException.class, () -> i(num(BigInteger.ONE)));
    }

    @Test void textPayloadOfFormatRuleRejectsExtraMembers() {
        WireValue text = obj("tag", str("Text"), "value", obj());
        assertThrows(GenerationFailure.class, () -> canonical(text, "FormatRule", "$"));
    }

    @Test void libraryWithDuplicateSourcesIsRejectedAsLb01() {
        WireValue library = SemanticLibraryFixture.library();
        WireValue source = a(f(library, "sources")).get(0);
        WireValue duplicated = TypeSignatures.replace(library, "sources", arr(List.of(source, source)));
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> TypeSignatures.TypeSignatureLibrary.decode(encodeWire(duplicated)));
        assertEquals("LB01", failure.condition());
    }

    @Test void libraryWithUnresolvedGroupMemberIsRejectedAsLb01() {
        WireValue library = SemanticLibraryFixture.library();
        WireValue groups = arr(List.of(obj("id", str("group"), "members", arr(List.of(str("missing"))))));
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> TypeSignatures.TypeSignatureLibrary.decode(encodeWire(TypeSignatures.replace(library, "groups", groups))));
        assertEquals("LB01", failure.condition());
    }

    @Test void libraryWithUnresolvedProvenanceTargetIsRejectedAsLb01() {
        WireValue library = SemanticLibraryFixture.library();
        WireValue provenance = arr(List.of(obj("target", variant("Type", str("missing")), "origins", arr(List.of()))));
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> TypeSignatures.TypeSignatureLibrary.decode(encodeWire(TypeSignatures.replace(library, "provenance", provenance))));
        assertEquals("LB01", failure.condition());
    }

    @Test void libraryWithUnresolvedAnnotationTargetIsRejectedAsLb01() {
        WireValue library = SemanticLibraryFixture.library();
        WireValue annotations = arr(List.of(obj("target", variant("Definition", str("missing")),
                "key", str("description"), "value", toExact(str("unused")))));
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> TypeSignatures.TypeSignatureLibrary.decode(encodeWire(TypeSignatures.replace(library, "annotations", annotations))));
        assertEquals("LB01", failure.condition());
    }

    @Test void libraryWithDuplicateOperationOutcomesIsRejectedAsLb01() {
        String text = fixtureText().replace("\"id\":\"denied\"", "\"id\":\"ok\"");
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> TypeSignatures.TypeSignatureLibrary.decode(text));
        assertEquals("LB01", failure.condition());
    }

    @Test void externalConditionOutcomeWithSuccessFormIsRejectedAsLb01() {
        String text = fixtureText().replace("{\"tag\":\"DeclaredFailure\"}", "{\"tag\":\"Success\"}");
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> TypeSignatures.TypeSignatureLibrary.decode(text));
        assertEquals("LB01", failure.condition());
    }

    @Test void operationWithoutSuccessOutcomeIsAccepted() throws GenerationFailure {
        admitWithBasisOf(fixtureText().replace("{\"tag\":\"Success\"}", "{\"tag\":\"DeclaredFailure\"}"));
    }

    @Test void sourceWithEmptyPathIsAccepted() throws GenerationFailure {
        admitWithBasisOf(fixtureText().replace("\"path\":\"spec\"", "\"path\":\"\""));
    }

    @Test void urlSafeBytesAreEncodedWithThePolicyAlphabet() {
        ProfileRef reference = new ProfileRef("profile", "1", "0".repeat(64));
        VersionedSemanticProfile profile = new VersionedSemanticProfile(reference, List.of(), List.of(), "numbers",
                new NumberModel(false), Optional.empty(), List.of(),
                Optional.of(new BytesPolicy(reference, true, BytesAlphabet.URL_SAFE, true, Optional.empty())),
                List.of(), Optional.empty());
        Context context = new Context(new SemanticGraph(profile, List.of(), List.of()));
        assertEquals(str("-_8="), context.encodeBytes(new Bytes(new byte[] {(byte) 0xfb, (byte) 0xff})));
    }

    @Test void integerDefaultOutsideTheEnumIsRejectedAsLb19() {
        WireValue library = SemanticLibraryFixture.library();
        WireValue number = obj("id", str("number"), "shape", variant("Integer", obj("domain", str("default"),
                "minimum", NIL, "maximum", NIL, "const_value", NIL, "enum_values", arr(List.of(str("1"), str("2"))),
                "default_value", str("3"))));
        List<WireValue> nodes = new java.util.ArrayList<>();
        for (WireValue node : a(f(library, "nodes"))) nodes.add(s(f(node, "id")).equals("number") ? number : node);
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> TypeSignatures.TypeSignatureLibrary.decode(encodeWire(TypeSignatures.replace(library, "nodes", arr(nodes)))));
        assertEquals("LB19", failure.condition());
    }

    @Test void graphemeLookupUsesTheFirstRowInTableOrder() {
        GraphemeRules rules = new GraphemeRules(new ProfileRef("profile", "1", "0".repeat(64)),
                List.of(new GraphemeRange(BigInteger.valueOf(0x41), BigInteger.valueOf(0x5A), GraphemeProperty.OTHER),
                        new GraphemeRange(BigInteger.valueOf(0x40), BigInteger.valueOf(0x60), GraphemeProperty.EXTEND)),
                List.of(), List.of(), new GraphemeComponent("16.0.0", "45", "default"), "0".repeat(64), List.of());
        assertEquals(List.of(0, 1, 2), SemanticGraphemeTest.graphemeBoundaries(rules, "AB"));
    }

    @Test void malformedBasisDigestIsACertificateMismatch() throws GenerationFailure {
        String libraryText = fixtureText();
        WireValue entries = SemanticLibraryFixture.entries;
        GenerationBasis basis = TypeSignatures.basis(libraryText, encodeWire(entries));
        GenerationBasis malformed = new GenerationBasis(TypeSignatures.replace(basis.value, "graph_sha256", str("xyz")), null);
        WireValue envelope = obj("schema", str("ncoh-checked-generation@5"), "basis", malformed.value,
                "signatures", readJson(libraryText), "composition", NIL, "entrypoints", entries);
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> TypeSignatures.admitGeneration(malformed, encodeWire(envelope)));
        assertEquals(SemanticGeneration.GenerationFailureKind.CERTIFICATE, failure.kind());
    }

    @Test void expectedSignatureSchemaOutsideTheVersionIsACoordinateMismatch() throws GenerationFailure {
        String libraryText = fixtureText();
        WireValue entries = SemanticLibraryFixture.entries;
        GenerationBasis basis = TypeSignatures.basis(libraryText, encodeWire(entries));
        GenerationBasis expected = GenerationBasis.decode(encodeWire(obj("basis",
                TypeSignatures.replace(basis.value, "signature_schema", str("ncoh-type-signatures@9")), "observations", NIL)));
        WireValue envelope = obj("schema", str("ncoh-checked-generation@5"), "basis", basis.value,
                "signatures", readJson(libraryText), "composition", NIL, "entrypoints", entries);
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> TypeSignatures.admitGeneration(expected, encodeWire(envelope)));
        assertEquals(SemanticGeneration.GenerationFailureKind.CERTIFICATE, failure.kind());
        assertInstanceOf(Status.Mismatched.class, failure.mismatch().statusAt(Condition.COORDINATE));
    }

    @Test void declaredSignatureSchemaOutsideTheVersionIsACoordinateMismatch() throws GenerationFailure {
        String libraryText = fixtureText();
        WireValue entries = SemanticLibraryFixture.entries;
        GenerationBasis basis = TypeSignatures.basis(libraryText, encodeWire(entries));
        WireValue declared = TypeSignatures.replace(basis.value, "signature_schema", str("ncoh-type-signatures@9"));
        WireValue envelope = obj("schema", str("ncoh-checked-generation@5"), "basis", declared,
                "signatures", readJson(libraryText), "composition", NIL, "entrypoints", entries);
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> TypeSignatures.admitGeneration(basis, encodeWire(envelope)));
        assertEquals(SemanticGeneration.GenerationFailureKind.CERTIFICATE, failure.kind());
        assertInstanceOf(Status.Mismatched.class, failure.mismatch().statusAt(Condition.COORDINATE));
    }

    @Test void librarySchemaOutsideTheVersionIsRejectedAsLb01() {
        WireValue library = SemanticLibraryFixture.library();
        WireValue foreign = TypeSignatures.replace(library, "schema", str("ncoh-type-signatures@9"));
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> TypeSignatures.TypeSignatureLibrary.decode(encodeWire(foreign)));
        assertEquals("LB01", failure.condition());
    }

    @Test void librarySchemaOutsideTheVersionIsALibraryFailureInAdmission() throws GenerationFailure {
        String libraryText = fixtureText();
        WireValue entries = SemanticLibraryFixture.entries;
        GenerationBasis basis = TypeSignatures.basis(libraryText, encodeWire(entries));
        WireValue foreign = TypeSignatures.replace(readJson(libraryText), "schema", str("ncoh-type-signatures@9"));
        WireValue envelope = obj("schema", str("ncoh-checked-generation@5"), "basis", basis.value,
                "signatures", foreign, "composition", NIL, "entrypoints", entries);
        GenerationFailure failure = assertThrows(GenerationFailure.class,
                () -> TypeSignatures.admitGeneration(basis, encodeWire(envelope)));
        assertEquals(SemanticGeneration.GenerationFailureKind.LIBRARY, failure.kind());
        assertEquals("LB01", failure.condition());
    }

    @Test void libraryWithoutTagModelAcceptsInternalTagBranches() {
        WireValue library = SemanticLibraryFixture.library();
        WireValue withoutTag = TypeSignatures.replace(library, "profile",
                TypeSignatures.replace(f(library, "profile"), "tag", NIL));
        TypeSignatures.TypeSignatureLibrary.decode(encodeWire(withoutTag));
    }

    @Test void leanNumbersKeepTheExactValueOfTheirExponent() {
        assertEquals(num(BigInteger.valueOf(1500)), leanNumber("1.5e3"));
        assertEquals(new SemanticValues.DecimalValue("0.125"), leanNumber("1.25e-1"));
        assertEquals(num(BigInteger.TEN.pow(9999)), leanNumber("1e9999"));
    }
}
