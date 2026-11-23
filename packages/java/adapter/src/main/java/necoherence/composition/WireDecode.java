// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.composition;

import java.math.BigInteger;
import java.util.List;
import necoherence.composition.CompositionPlanWire.DecodeRejection;
import necoherence.semantic.SemanticValues;
import necoherence.semantic.SemanticValues.ArrayValue;
import necoherence.semantic.SemanticValues.Member;
import necoherence.semantic.SemanticValues.ObjectValue;
import necoherence.semantic.SemanticValues.StringValue;
import necoherence.semantic.SemanticValues.WireValue;
import necoherence.semantic.WireFailure;
import necoherence.semantic.WireFailure.Syntax;
import necoherence.semantic.WireFailure.UnknownField;
import necoherence.semantic.WireFailure.UnknownTag;
import necoherence.semantic.WireFailure.UnsupportedSchema;

/**
 * Reads wire values with the failure paths of the Lean wire decoders.
 *
 * <p>A failure path starts at {@code $} for the value being read. {@link #get} is the Lean {@code get}: a member that
 * is missing, or a row that is not an object, fails at {@code $.key}, and a failure inside the decoder of the member is
 * prefixed with {@code $.key}. {@link #prop}, {@link #listProp}, {@link #payloadOf}, and {@link #fieldsOf} are the Lean
 * {@code liftJson} reads: their failures stay at {@code $} of the value being read.
 */
final class WireDecode {
    private WireDecode() {}

    /** Decodes one wire value and reports its failures relative to that value. */
    @FunctionalInterface interface Decoder<T> { T decode(WireValue value); }

    /** Lean {@code get json key} with the decoder of the member. */
    static <T> T get(WireValue row, String key, Decoder<T> decoder) {
        WireValue value = member(row, key);
        try {
            return decoder.decode(value);
        } catch (DecodeRejection rejection) {
            throw rejection.prepend("$." + key);
        }
    }

    /** Lean {@code get json key} with a list decoder: each element failure is prefixed with its index and the member path. */
    static <T> List<T> getList(WireValue row, String key, Decoder<T> decoder) {
        return get(row, key, value -> elements(value, decoder));
    }

    /** Lean {@code Wire (List α)} decode: an element failure is prefixed with {@code [index]}. */
    private static <T> List<T> elements(WireValue value, Decoder<T> decoder) {
        List<WireValue> items = array(value);
        List<T> result = new java.util.ArrayList<>(items.size());
        for (int index = 0; index < items.size(); index++) {
            try {
                result.add(decoder.decode(items.get(index)));
            } catch (DecodeRejection rejection) {
                throw rejection.prepend("[" + index + "]");
            }
        }
        return List.copyOf(result);
    }

    /** Lean {@code get json key} for a string member. */
    static String textAt(WireValue row, String key) { return get(row, key, WireDecode::text); }

    /** Lean {@code get json key} for a natural member. */
    static BigInteger natAt(WireValue row, String key) { return get(row, key, WireDecode::nat); }

    /** Lean {@code liftJson (json.getObjVal? key).getArr?} then the element decoder, with failures at {@code $}. */
    static <T> List<T> listProp(WireValue row, String key, Decoder<T> decoder) {
        return array(prop(row, key)).stream().map(decoder::decode).toList();
    }

    /** Lean {@code liftJson (json.getObjVal? key)}: a missing member or a non-object row fails at {@code $}. */
    static WireValue prop(WireValue row, String key) {
        WireValue value = object(row, "$").get(key);
        if (value == null) throw syntax("$", "property not found: " + key);
        return value;
    }

    /** Lean {@code get json key} without a decoder: a missing member or a non-object row fails at {@code $.key}. */
    static WireValue member(WireValue row, String key) {
        WireValue value = object(row, "$." + key).get(key);
        if (value == null) throw syntax("$." + key, "property not found: " + key);
        return value;
    }

    /** Lean {@code payload json}: the object has exactly the tag and value members. */
    static WireValue payloadOf(WireValue json) {
        keys(json, "tag", "value");
        return prop(json, "value");
    }

    /** Lean {@code fields json}: the object has exactly the tag and fields members. */
    static WireValue fieldsOf(WireValue json) {
        keys(json, "tag", "fields");
        return prop(json, "fields");
    }

    /** Lean {@code get (α := String) json "tag"}. */
    static String tagOf(WireValue json) { return get(json, "tag", WireDecode::text); }

    /** Lean {@code String} decode, with the failure at {@code $}. */
    static String text(WireValue value) {
        if (!(value instanceof StringValue text)) throw syntax("$", "String expected");
        return text.value();
    }

    private static final java.util.regex.Pattern INTEGER = java.util.regex.Pattern.compile("-?[0-9]+");

    /** Lean {@code Nat} decode: a decimal string in canonical form, with the failure at {@code $}. */
    static BigInteger nat(WireValue value) {
        String text = text(value);
        if (!INTEGER.matcher(text).matches()) throw syntax("$", "expected canonical integer");
        BigInteger number = new BigInteger(text);
        if (!number.toString().equals(text)) throw syntax("$", "noncanonical integer");
        if (number.signum() < 0) throw syntax("$", "negative natural");
        return number;
    }

    /** Lean {@code liftJson json.getArr?}, with the failure at {@code $}. */
    static List<WireValue> array(WireValue value) {
        if (!(value instanceof ArrayValue array)) throw syntax("$", "array expected");
        return array.items();
    }

    /** Lean pair decode: an array of two members, with the size failure carrying the given message. */
    static List<WireValue> pair(WireValue value, String message) {
        List<WireValue> items = array(value);
        if (items.size() != 2) throw syntax("$", message);
        return items;
    }

    /** Lean {@code keys json expected}: the object has exactly the expected members. */
    static void keys(WireValue value, String... expected) {
        lift(() -> { SemanticValues.keys(value, "$", expected); return null; });
    }

    /** Runs a decoder of the semantic package and reports its wire failure as a decode rejection at the same path. */
    static <T> T lift(java.util.function.Supplier<T> read) {
        try { return read.get(); }
        catch (WireFailure.WireException failure) { throw new DecodeRejection(failure.failure()); }
    }

    /** Lean {@code Wire TypeRef} decode: a type identity string. */
    static SemanticComposition.TypeRef typeReference(WireValue value) {
        return SemanticComposition.typeRefFromWire(necoherence.semantic.TypeSignatures.typeReference(text(value)));
    }

    /** Lean {@code Wire Bool} decode, with the failure at {@code $}. */
    static boolean bool(WireValue value) {
        if (!(value instanceof SemanticValues.BooleanValue flag)) throw syntax("$", "Bool expected");
        return flag.value();
    }

    /** Lean {@code Wire SlotContract} decode: the type_id, required, and nullable members are the only members. */
    static SemanticComposition.SlotContract slotContract(WireValue value) {
        keys(value, "type_id", "required", "nullable");
        return new SemanticComposition.SlotContract(get(value, "type_id", WireDecode::typeReference),
                get(value, "required", WireDecode::bool), get(value, "nullable", WireDecode::bool));
    }

    /** Lean {@code WireFailure.prepend}: the failure path continues after the segment instead of the root. */
    static WireFailure prefixed(String segment, WireFailure failure) {
        String rest = failure.path().startsWith("$") ? failure.path().substring(1) : failure.path();
        String path = segment + rest;
        return switch (failure) {
            case UnsupportedSchema unsupported -> new UnsupportedSchema(path, unsupported.schema());
            case UnknownField unknown -> new UnknownField(path, unknown.field());
            case UnknownTag tag -> new UnknownTag(path, tag.tag());
            case Syntax syntax -> new Syntax(path, syntax.message());
        };
    }

    static DecodeRejection syntax(String path, String message) {
        return new DecodeRejection(new Syntax(path, message));
    }

    static DecodeRejection unknownTag(String path, String tag) {
        return new DecodeRejection(new UnknownTag(path, tag));
    }

    private static ObjectValue object(WireValue value, String path) {
        if (!(value instanceof ObjectValue object)) throw syntax(path, "object expected");
        return object;
    }
}
