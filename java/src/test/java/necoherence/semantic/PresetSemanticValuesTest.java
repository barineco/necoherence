// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticGeneration.*;
import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.*;

import java.util.List;
import org.junit.jupiter.api.Test;

public final class PresetSemanticValuesTest {
    private static final WireValue TRUE = new BooleanValue(true);
    private static final WireValue FALSE = new BooleanValue(false);
    private static final WireValue NIL_VALUE = NIL;
    private static final WireValue REFERENCE = obj("identity", str("profile"), "revision", str("7"), "content_digest", str("a".repeat(64)));

    private static WireValue stringSpec() {
        return obj("format", variant("Named", str("cid-raw")), "lengths", arr(List.of()),
                "wrapper", str("reference"), "const_value", NIL_VALUE, "enum_values", NIL_VALUE,
                "examples", arr(List.of()), "default_value", NIL_VALUE);
    }

    private static WireValue profile() {
        WireValue format = obj("name", str("cid-raw"), "reference", REFERENCE,
                "rule", variant("Literal", str("cid-value")));
        WireValue tagFormat = obj("name", str("tag-format"), "reference", REFERENCE,
                "rule", variant("Literal", str("blob")));
        WireValue wrapper = obj("name", str("reference"), "key", str("$link"),
                "payload", variant("Text", str("cid-raw")));
        WireValue field = obj("key", str("ref"), "required", TRUE,
                "leaf", variant("String", stringSpec()));
        WireValue form = obj("tag", str("blob"), "fields", arr(List.of(field)), "extras", variant("Reject"));
        WireValue integerDomain = obj("name", str("integer"), "reference", REFERENCE,
                "range", variant("Unbounded"), "forms", arr(List.of(variant("Number"))));
        return obj("reference", REFERENCE, "source_refs", arr(List.of()),
                "integer_domains", arr(List.of(integerDomain)),
                "default_integer_domain", str("integer"), "numbers", obj("decimals", TRUE),
                "grapheme_rules", NIL_VALUE, "format_bindings", arr(List.of(format, tagFormat)),
                "bytes_policy", obj("reference", REFERENCE, "padding_optional", TRUE,
                        "alphabet", variant("Either"), "strict_pad_bits", TRUE, "wrapper", NIL_VALUE),
                "wrappers", arr(List.of(wrapper)),
                "tag", obj("key", str("$type"), "format", str("tag-format"), "sealed", arr(List.of(form))));
    }

    private static Context context() {
        WireValue bytes = obj("reference", TypeSignatures.typeReference("bytes"), "shape", variant("Bytes", obj("minimum", NIL_VALUE, "maximum", NIL_VALUE)));
        WireValue sealed = obj("reference", TypeSignatures.typeReference("blob"), "shape",
                fields("Sealed", obj("tag", str("blob"), "refinements", arr(List.of()))));
        WireValue product = obj("reference", TypeSignatures.typeReference("product"), "shape",
                variant("Product", obj("fields", arr(List.of()), "extras", variant("Reject"))));
        WireValue tagged = obj("reference", TypeSignatures.typeReference("tagged"), "shape",
                variant("TaggedUnion", obj("branches", arr(List.of(
                        obj("target", TypeSignatures.typeReference("product"), "wire_tag", str("blob"),
                                "selector", variant("InternalTag")))))));
        WireValue any = obj("reference", TypeSignatures.typeReference("any"), "shape", variant("Unknown", variant("Any")));
        WireValue ordinary = obj("reference", TypeSignatures.typeReference("ordinary"), "shape",
                variant("Unknown", variant("OrdinaryObject")));
        WireValue string = obj("reference", TypeSignatures.typeReference("string"), "shape", variant("String", stringSpec()));
        WireValue nullableStringArray = obj("reference", TypeSignatures.typeReference("nullable-string-array"), "shape",
                variant("Array", obj("item", obj("type_ref", TypeSignatures.typeReference("string"), "nullable", TRUE),
                        "min_length", NIL_VALUE, "max_length", NIL_VALUE)));
        WireValue stringArray = obj("reference", TypeSignatures.typeReference("string-array"), "shape",
                variant("Array", obj("item", obj("type_ref", TypeSignatures.typeReference("string"), "nullable", FALSE),
                        "min_length", NIL_VALUE, "max_length", NIL_VALUE)));
        WireValue anyArray = obj("reference", TypeSignatures.typeReference("any-array"), "shape",
                variant("Array", obj("item", obj("type_ref", TypeSignatures.typeReference("any"), "nullable", FALSE),
                        "min_length", NIL_VALUE, "max_length", NIL_VALUE)));
        WireValue anyMap = obj("reference", TypeSignatures.typeReference("any-map"), "shape",
                variant("Product", obj("fields", arr(List.of()), "extras",
                        fields("Allow", obj("key_format", NIL_VALUE,
                                "value", obj("type_ref", TypeSignatures.typeReference("any"), "nullable", FALSE))))));
        WireValue integer = obj("reference", TypeSignatures.typeReference("integer"), "shape",
                variant("Integer", obj("domain", str("integer"), "minimum", NIL_VALUE,
                        "maximum", NIL_VALUE, "const_value", NIL_VALUE,
                        "enum_values", NIL_VALUE, "default_value", NIL_VALUE)));
        WireValue integerMap = obj("reference", TypeSignatures.typeReference("integer-map"), "shape",
                variant("Product", obj("fields", arr(List.of()), "extras",
                        fields("Allow", obj("key_format", NIL_VALUE,
                                "value", obj("type_ref", TypeSignatures.typeReference("integer"), "nullable", FALSE))))));
        return new Context(obj("profile", profile(), "nodes", arr(List.of(
                bytes, sealed, product, tagged, any, ordinary, string, nullableStringArray,
                stringArray, anyArray, anyMap, integer, integerMap))));
    }

    private static ValueFailure rejected(Context context, int type, WireValue value) {
        return assertThrows(ValueFailure.class, () -> context.validate(context.reference(type), value));
    }
    @Test void nullableStringArrayAcceptsNullElement() {
        Context context = context();
        assertDoesNotThrow(() -> context.validate(TypeSignatures.typeReference("nullable-string-array"),
                arr(List.of(NIL_VALUE))));
    }

    @Test void nonNullableStringArrayRejectsNullElement() {
        Context context = context();
        assertThrows(ValueFailure.class, () -> context.validate(TypeSignatures.typeReference("string-array"),
                arr(List.of(NIL_VALUE))));
    }

    @Test void nonNullableUnknownAnyElementsAcceptNull() {
        Context context = context();
        assertDoesNotThrow(() -> context.validate(TypeSignatures.typeReference("any-array"),
                arr(List.of(NIL_VALUE))));
        assertDoesNotThrow(() -> context.validate(TypeSignatures.typeReference("any-map"),
                obj("value", NIL_VALUE)));
    }

    @Test void nonNullableIntegerMapRejectsNullValue() {
        Context context = context();
        ValueFailure failure = assertThrows(ValueFailure.class,
                () -> context.validate(TypeSignatures.typeReference("integer-map"), obj("value", NIL_VALUE)));
        assertEquals(List.of(variant("Field", str("value"))), failure.path());
    }


    @Test void sealedStringLeafAcceptsItsDeclaredWrapperAndFormat() {
        Context context = context();
        WireValue value = obj("$type", str("blob"), "ref", obj("$link", str("cid-value")));
        assertDoesNotThrow(() -> context.validate(context.reference(1), value));
    }

    @Test void eitherBytesAlphabetAcceptsUnpaddedUrlSafeText() throws Exception {
        Context context = context();
        assertArrayEquals(new byte[] {(byte) 0xfb, (byte) 0xff}, context.decodeBytes(context.reference(0), str("-_8")).value());
    }

    @Test void objectShapesApplyOneCommonTagValidation() {
        Context context = context();
        for (int type : List.of(1, 2, 3, 4, 5)) {
            ValueFailure empty = rejected(context, type, obj("$type", str("")));
            assertEquals("InvalidTag", empty.condition());
            assertEquals(List.of(variant("Field", str("$type"))), empty.path());
            ValueFailure nonString = rejected(context, type, obj("$type", TRUE));
            assertEquals("InvalidTag", nonString.condition());
            assertEquals(List.of(variant("Field", str("$type"))), nonString.path());
        }
    }

    @Test void malformedUnicodeTagIsInvalidDataModel() {
        ValueFailure failure = rejected(context(), 4, obj("$type", new StringValue("\ud800")));
        assertEquals("InvalidDataModel", failure.condition());
        assertEquals(List.of(variant("Field", str("$type"))), failure.path());
    }

    @Test void unknownAnyValidatesTagsInNestedObjects() {
        ValueFailure failure = rejected(context(), 4, obj("nested", obj("$type", str(""))));
        assertEquals("InvalidTag", failure.condition());
        assertEquals(List.of(variant("Field", str("nested")), variant("Field", str("$type"))), failure.path());
    }

    @Test void duplicateMembersPrecedeTagValidation() {
        WireValue duplicate = new ObjectValue(List.of(
                new Member("$type", str("")),
                new Member("$type", str("blob"))));
        ValueFailure failure = rejected(context(), 3, duplicate);
        assertEquals("DuplicateField: $type", failure.condition());
        assertEquals(List.of(), failure.path());
    }
}
