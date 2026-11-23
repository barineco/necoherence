// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/**
 * The exact JSON value used by the semantic core. The variants are the Java representation of the Lean
 * {@code ExactJson.JsonValue}: null, bool, num, dec, str, arr, and obj. The wire tree
 * {@code SemanticValues.WireValue} is converted to this type at the boundary by {@link WireJson}.
 */
public final class ExactJson {
    private ExactJson() {}

    /** An exact JSON value. */
    public sealed interface JsonValue permits JsonNull, JsonBool, JsonNum, JsonDec, JsonStr, JsonArr, JsonObj {}

    /** The JSON null value. */
    public record JsonNull() implements JsonValue {}

    /** The JSON boolean value. */
    public record JsonBool(boolean value) implements JsonValue {}

    /** The JSON integer value. */
    public record JsonNum(BigInteger value) implements JsonValue {
        public JsonNum { Objects.requireNonNull(value); }
    }

    /** The JSON decimal value, given by its decimal text. */
    public record JsonDec(String text) implements JsonValue {
        public JsonDec {
            if (text == null || !SemanticValues.isJsonNumberSpelling(text))
                throw new WireFailure.WireException(new WireFailure.Syntax("$", "exact decimal spelling required"));
        }
    }

    /** The JSON string value. */
    public record JsonStr(String value) implements JsonValue {
        public JsonStr { Objects.requireNonNull(value); }
    }

    /** The JSON array value. */
    public record JsonArr(List<JsonValue> items) implements JsonValue {
        public JsonArr { items = List.copyOf(items); }
    }

    /** A member of a JSON object. */
    public record JsonMember(String key, JsonValue value) {
        public JsonMember { Objects.requireNonNull(key); Objects.requireNonNull(value); }
    }

    /** The JSON object value, with its members in order. */
    public record JsonObj(List<JsonMember> members) implements JsonValue {
        public JsonObj { members = List.copyOf(members); }

    }

    public static final JsonNull NIL = new JsonNull();

    public static boolean nil(JsonValue value) { return value instanceof JsonNull; }

    public static JsonStr str(String value) { return new JsonStr(value); }

    public static JsonNum num(BigInteger value) { return new JsonNum(value); }

    public static JsonArr arr(List<JsonValue> items) { return new JsonArr(items); }

    /** Builds an object from alternating keys and values. */
    public static JsonObj obj(Object... fields) {
        List<JsonMember> result = new ArrayList<>(fields.length / 2);
        for (int i = 0; i < fields.length; i += 2) result.add(new JsonMember((String) fields[i], (JsonValue) fields[i + 1]));
        return new JsonObj(result);
    }

    public static String s(JsonValue value) { return ((JsonStr) value).value(); }

    public static boolean b(JsonValue value) { return ((JsonBool) value).value(); }

    public static List<JsonValue> a(JsonValue value) { return ((JsonArr) value).items(); }

    static JsonObj o(JsonValue value) { return (JsonObj) value; }

    /** @return the member value of the object, or throws when the key is absent */
    public static JsonValue f(JsonValue value, String key) {
        JsonValue result = SemanticValidation.memberValue(key, o(value).members()).orElse(null);
        if (result == null) throw new WireFailure.WireException(new WireFailure.Syntax("$." + key, "missing field " + key));
        return result;
    }

    public static String tag(JsonValue value) { return s(f(value, "tag")); }

    public static JsonValue payload(JsonValue value) {
        JsonValue result = SemanticValidation.memberValue("value", o(value).members()).orElse(null);
        return result == null ? f(value, "fields") : result;
    }

    public static JsonValue variant(String name) { return obj("tag", str(name)); }

    public static JsonValue variant(String name, JsonValue value) { return obj("tag", str(name), "value", value); }

    public static JsonValue fields(String name, JsonValue value) { return obj("tag", str(name), "fields", value); }


    /** Returns the object with the key set to the text, followed by the other members. */
    public static JsonValue withMember(String key, String text, JsonValue value) {
        if (!(value instanceof JsonObj object)) return value;
        List<JsonMember> members = new ArrayList<>();
        members.add(new JsonMember(key, str(text)));
        for (JsonMember member : object.members()) if (!member.key().equals(key)) members.add(member);
        return new JsonObj(members);
    }

    public static boolean unicodeValid(String text) {
        for (int index = 0; index < text.length(); index++) {
            char c = text.charAt(index);
            if (!Character.isSurrogate(c)) continue;
            if (!Character.isHighSurrogate(c) || index + 1 == text.length() || !Character.isLowSurrogate(text.charAt(index + 1))) return false;
            index++;
        }
        return true;
    }

    static boolean scalarValid(int c) {
        return c <= 1114111 && !(55296 <= c && c <= 57343);
    }

    /** Encodes the value as compact JSON text, preserving the member order. */
    public static String encode(JsonValue value) {
        StringBuilder result = new StringBuilder();
        append(value, result);
        return result.toString();
    }

    /** Orders object keys by Unicode code point, the order in which the Lean Json object is written. */
    public static int compareKeys(String left, String right) {
        int a = 0, b = 0;
        while (a < left.length() && b < right.length()) {
            int x = left.codePointAt(a), y = right.codePointAt(b);
            if (x != y) return Integer.compare(x, y);
            a += Character.charCount(x);
            b += Character.charCount(y);
        }
        return left.codePointCount(a, left.length()) - right.codePointCount(b, right.length());
    }

    /** A piece of the output still to be written: a literal text, or a value. */
    private record Literal(String text) {}

    private static void append(JsonValue value, StringBuilder out) {
        java.util.ArrayDeque<Object> pending = new java.util.ArrayDeque<>();
        pending.push(value);
        while (!pending.isEmpty()) {
            switch (pending.pop()) {
                case Literal literal -> out.append(literal.text());
                case JsonNull unused -> out.append("null");
                case JsonBool v -> out.append(v.value());
                case JsonNum v -> out.append(v.value());
                case JsonDec v -> out.append(v.text());
                case JsonStr v -> appendString(v.value(), out);
                case JsonArr v -> {
                    out.append('[');
                    pending.push(new Literal("]"));
                    for (int i = v.items().size() - 1; i >= 0; i--) {
                        pending.push(v.items().get(i));
                        if (i != 0) pending.push(new Literal(","));
                    }
                }
                case JsonObj v -> {
                    out.append('{');
                    pending.push(new Literal("}"));
                    List<JsonMember> members = v.members().stream().sorted((a, b) -> compareKeys(a.key(), b.key())).toList();
                    for (int i = members.size() - 1; i >= 0; i--) {
                        StringBuilder key = new StringBuilder();
                        appendString(members.get(i).key(), key);
                        key.append(':');
                        pending.push(members.get(i).value());
                        pending.push(new Literal(key.toString()));
                        if (i != 0) pending.push(new Literal(","));
                    }
                }
                default -> throw new IllegalStateException("unexpected output piece");
            }
        }
    }

    private static void appendString(String text, StringBuilder out) {
        out.append('"');
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            switch (c) {
                case '"' -> out.append("\\\""); case '\\' -> out.append("\\\\");
                case '\n' -> out.append("\\n"); case '\r' -> out.append("\\r");
                default -> {
                    if (c < 32) { out.append("\\u00").append(Character.forDigit(c >>> 4, 16)).append(Character.forDigit(c & 15, 16)); }
                    else out.append(c);
                }
            }
        }
        out.append('"');
    }
}
