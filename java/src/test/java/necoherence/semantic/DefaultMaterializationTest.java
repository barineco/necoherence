// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.*;

import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

public final class DefaultMaterializationTest {
    private static WireValue ref(String name) {
        return obj("source", obj("repository", str("external"), "revision", str("qualified"),
                "path", str("types.json"), "content_digest", str("a".repeat(64)),
                "document_id", str("document"), "declared_revision", NIL),
                "definition_name", str(name), "pointer", arr(List.of(str("definitions"), str(name))));
    }
    private static WireValue node(String name, WireValue shape) { return obj("reference", ref(name), "shape", shape); }
    private static WireValue field(String name, String target) {
        return obj("wire_name", str(name), "slot", obj("type_ref", ref(target), "required", new BooleanValue(true), "nullable", new BooleanValue(false)));
    }
    private static Context context(boolean invalid) {
        WireValue integer = variant("Integer", obj("domain", NIL, "minimum", invalid ? str("1") : NIL,
                "maximum", NIL, "const_value", NIL, "enum_values", NIL, "default_value", str("0")));
        WireValue text = variant("String", obj("format", NIL, "lengths", arr(List.of()), "wrapper", NIL,
                "const_value", NIL, "enum_values", NIL, "examples", arr(List.of()), "default_value", str("")));
        List<WireValue> nodes = List.of(
                node("flag", variant("Boolean", obj("const_value", NIL, "default_value", new BooleanValue(false)))),
                node("integer", integer), node("text", text),
                node("alias", fields("Alias", obj("target", ref("integer")))),
                node("product", variant("Product", obj("fields", arr(List.of(field("flag", "flag"), field("integer", "alias"), field("text", "text"))), "extras", variant("Reject")))),
                node("array", variant("Array", obj("item", obj("type_ref", ref("product"), "nullable", new BooleanValue(false)), "min_length", NIL, "max_length", NIL))));
        return new Context(obj("profile", f(SemanticLibraryFixture.library(), "profile"), "nodes", arr(nodes)));
    }
    @Test void qualifiedDefaultsPreserveOrderProvenanceAndIdempotence() throws Exception {
        Context context = context(false);
        WireValue before = arr(List.of(obj()));
        DefaultedValue result = context.materializeDefaults(ref("array"), before);
        assertEquals("[{\"flag\":false,\"integer\":0,\"text\":\"\"}]", encodeWire(result.value()));
        assertEquals("[{}]", encodeWire(before));
        assertEquals(ref("integer"), result.applications().get(1).typeRef());
        assertEquals(List.of(variant("Index", str("0")), variant("Field", str("integer"))), result.applications().get(1).valuePath());
        assertEquals(arr(List.of(str("definitions"), str("integer"), str("default"))), f(result.applications().get(1).origin(), "pointer"));
        assertThrows(UnsupportedOperationException.class, () -> result.applications().clear());
        DefaultedValue second = context.materializeDefaults(ref("array"), result.value());
        assertEquals(result.value(), second.value());
        assertEquals(List.of(), second.applications());
        DefaultApplication application = result.applications().getFirst();
        List<DefaultApplication> forged = new ArrayList<>(result.applications());
        forged.set(0, new DefaultApplication(application.valuePath(), application.typeRef(), application.origin(), new BooleanValue(true)));
        assertFalse(context.checkDefaultApplications(before, result.value(), forged));
    }
    @Test void invalidDefaultUsesResolvedPrimitiveRootBeforeProductValidation() {
        ValueFailure failure = assertThrows(ValueFailure.class, () -> context(true).materializeDefaults(ref("product"), obj("flag", str("invalid"))));
        assertEquals(ref("integer"), failure.typeRef());
        assertEquals(List.of(), failure.path());
        assertEquals("BelowMinimum", failure.condition());
        assertEquals(f(ref("integer"), "source"), f(failure.origin(), "source"));
    }
    @Test void textDefaultsRetainStrictDecodeAndTypedWireFailure() throws Exception {
        Context context = context(false);
        assertThrows(ValueFailure.class, () -> context.decode(ref("product"), "{}"));
        assertEquals("{\"flag\":false,\"integer\":0,\"text\":\"\"}", encodeWire(context.decodeWithDefaults(ref("product"), "{}").value()));
        ValueFailure failure = assertThrows(ValueFailure.class, () -> context.decodeWithDefaults(ref("product"), "{"));
        assertTrue(failure.condition().startsWith("InvalidJson:"));
        assertEquals(ref("product"), failure.typeRef());
    }
    @Test void checkedMaterializationAdmitsReachableMeaningAndCarriesEvidence() {
        WireValue profile = f(SemanticLibraryFixture.library(), "profile");
        WireValue optional = obj("wire_name", str("optional"), "slot", obj("type_ref", ref("gone"), "required", new BooleanValue(false), "nullable", new BooleanValue(false)));
        Context missing = new Context(obj("profile", profile, "nodes", arr(List.of(node("root", variant("Product", obj("fields", arr(List.of(optional)), "extras", variant("Reject"))))))));
        ValueFailure failure = assertThrows(ValueFailure.class, () -> missing.materializeDefaults(ref("root"), obj()));
        assertEquals("Unresolved", failure.condition());
        WireValue obligation = failure.obligations().getFirst();
        assertEquals(ref("gone"), f(obligation, "type_ref"));
        assertEquals(arr(List.of()), f(obligation, "value_path"));
        assertEquals(f(profile, "reference"), f(obligation, "profile"));
        assertEquals(variant("UnresolvedType"), f(obligation, "reason"));

        WireValue text = variant("String", obj("format", variant("Named", str("missing-format")), "lengths", arr(List.of()), "wrapper", NIL, "const_value", NIL, "enum_values", NIL, "examples", arr(List.of()), "default_value", str("")));
        Context formatted = new Context(obj("profile", profile, "nodes", arr(List.of(node("text", text), node("root", variant("Product", obj("fields", arr(List.of(field("label", "text"))), "extras", variant("Reject"))))))));
        for (WireValue reference : List.of(ref("root"), ref("text"))) {
            WireValue before = reference.equals(ref("root")) ? obj() : str("");
            ValueFailure unknown = assertThrows(ValueFailure.class, () -> formatted.materializeDefaults(reference, before));
            WireValue evidence = unknown.obligations().getFirst();
            assertEquals(ref("text"), f(evidence, "type_ref"));
            assertEquals(obj("source", f(ref("text"), "source"), "pointer", f(ref("text"), "pointer")), f(evidence, "origin"));
            assertEquals(arr(List.of()), f(evidence, "value_path"));
            assertEquals(f(profile, "reference"), f(evidence, "profile"));
            assertEquals(variant("UnknownFormat", str("missing-format")), f(evidence, "reason"));
        }
    }
    private static Context unitContext() {
        WireValue unitField = obj("wire_name", str("unit"), "slot",
                obj("type_ref", ref("unit"), "required", new BooleanValue(true), "nullable", new BooleanValue(true)));
        List<WireValue> nodes = List.of(
                node("unit", variant("Unit")),
                node("never", variant("Never")),
                node("flag", variant("Boolean", obj("const_value", NIL, "default_value", new BooleanValue(false)))),
                node("alias", fields("Alias", obj("target", ref("unit")))),
                node("array", variant("Array", obj("item", obj("type_ref", ref("unit"), "nullable", new BooleanValue(false)),
                        "min_length", NIL, "max_length", NIL))),
                node("product", variant("Product", obj("fields", arr(List.of(unitField, field("flag", "flag"))), "extras", variant("Reject")))));
        return new Context(obj("profile", f(SemanticLibraryFixture.library(), "profile"), "nodes", arr(nodes)));
    }
    @Test void unitAndItsAliasAndArrayDecodeWithDefaultsWithoutPayload() throws Exception {
        Context context = unitContext();
        for (String name : List.of("unit", "alias")) {
            DefaultedValue result = context.decodeWithDefaults(ref(name), "null");
            assertEquals(NIL, result.value());
            assertEquals(List.of(), result.applications());
        }
        DefaultedValue array = context.decodeWithDefaults(ref("array"), "[null]");
        assertEquals(arr(List.of(NIL)), array.value());
        assertEquals(List.of(), array.applications());
    }
    @Test void productWithUnitFieldPreservesNullAndAppliesDeclaredDefault() throws Exception {
        Context context = unitContext();
        DefaultedValue result = context.decodeWithDefaults(ref("product"), "{\"unit\":null}");
        assertEquals(obj("unit", NIL, "flag", new BooleanValue(false)), result.value());
        assertEquals(1, result.applications().size());
        DefaultApplication application = result.applications().getFirst();
        assertEquals(List.of(variant("Field", str("flag"))), application.valuePath());
        assertEquals(ref("flag"), application.typeRef());
        assertEquals(new BooleanValue(false), application.value());
        assertTrue(context.checkDefaultApplications(obj("unit", NIL), result.value(), result.applications()));
    }
    @Test void payloadlessShapesRetainTypedMembershipFailures() {
        Context context = unitContext();
        ValueFailure unit = assertThrows(ValueFailure.class, () -> context.decodeWithDefaults(ref("unit"), "false"));
        assertEquals(ref("unit"), unit.typeRef());
        assertEquals(List.of(), unit.path());
        assertEquals("WrongValueKind: unit", unit.condition());
        ValueFailure never = assertThrows(ValueFailure.class, () -> context.decodeWithDefaults(ref("never"), "null"));
        assertEquals(ref("never"), never.typeRef());
        assertEquals(List.of(), never.path());
        assertEquals("InvalidDataModel", never.condition());
    }
    @Test void unitParametersOfAdmittedOperationDecodeWithDefaults() throws Exception {
        WireValue library = SemanticLibraryFixture.library();
        List<WireValue> nodes = new ArrayList<>(a(f(library, "nodes")));
        nodes.add(obj("id", str("unit"), "shape", variant("Unit")));
        List<WireValue> definitions = new ArrayList<>();
        WireValue parameters = obj("id", str("parameters"), "contract", SemanticLibraryFixture.slot("unit"));
        for (WireValue definition : a(f(library, "definitions"))) {
            if (s(f(definition, "id")).equals("op")) {
                WireValue operation = TypeSignatures.replace(payload(f(definition, "shape")), "inputs", arr(List.of(parameters)));
                definition = TypeSignatures.replace(definition, "shape", variant("Operation", operation));
            }
            definitions.add(definition);
        }
        library = TypeSignatures.replace(TypeSignatures.replace(library, "nodes", arr(nodes)), "definitions", arr(definitions));
        WireValue entries = arr(List.of(obj("identity", str("operation"), "definition", str("op"))));
        var basis = TypeSignatures.basis(encodeWire(library), encodeWire(entries));
        var checked = TypeSignatures.admitGeneration(basis, encodeWire(obj("schema", str("ncoh-checked-generation@4"),
                "basis", TypeSignatures.parseWire(basis.encode()), "signatures", library, "composition", NIL, "entrypoints", entries)));
        WireValue reference = TypeSignatures.typeReference(s(f(f(parameters, "contract"), "type_id")));
        DefaultedValue result = checked.valueContext().decodeWithDefaults(reference, "null");
        assertEquals(NIL, result.value());
        assertEquals(List.of(), result.applications());
    }
}
