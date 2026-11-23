// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import java.util.ArrayList;
import java.util.List;
import necoherence.semantic.ExactJson.JsonArr;
import necoherence.semantic.ExactJson.JsonBool;
import necoherence.semantic.ExactJson.JsonDec;
import necoherence.semantic.ExactJson.JsonMember;
import necoherence.semantic.ExactJson.JsonNull;
import necoherence.semantic.ExactJson.JsonNum;
import necoherence.semantic.ExactJson.JsonObj;
import necoherence.semantic.ExactJson.JsonStr;
import necoherence.semantic.ExactJson.JsonValue;
import necoherence.semantic.SemanticValues.ArrayValue;
import necoherence.semantic.SemanticValues.BooleanValue;
import necoherence.semantic.SemanticValues.DecimalValue;
import necoherence.semantic.SemanticValues.Absent;
import necoherence.semantic.SemanticValues.IntegerValue;
import necoherence.semantic.SemanticValues.Member;
import necoherence.semantic.SemanticValues.NullSlot;
import necoherence.semantic.SemanticValues.NullValue;
import necoherence.semantic.SemanticValues.ObjectValue;
import necoherence.semantic.SemanticValues.Present;
import necoherence.semantic.SemanticValues.Slot;
import necoherence.semantic.SemanticValues.StringValue;
import necoherence.semantic.SemanticValues.WireValue;

/**
 * Converts between the wire tree and the exact JSON value at the wire boundary. The conversion keeps every
 * variant and member order, so that {@code toWire(fromWire(v))} equals {@code v}.
 */
public final class WireJson {
    private WireJson() {}

    /** Reads the wire tree as the exact JSON value. */
    public static JsonValue fromWire(WireValue value) {
        return rebuild(value, WireJson::wireChildren, WireJson::fromWireLeaf, WireJson::fromWireNode);
    }

    private static List<WireValue> wireChildren(WireValue value) {
        if (value instanceof ArrayValue array) return array.items();
        if (value instanceof ObjectValue object) return object.members().stream().map(Member::value).toList();
        return null;
    }

    private static JsonValue fromWireLeaf(WireValue value) {
        return switch (value) {
            case NullValue unused -> new JsonNull();
            case BooleanValue v -> new JsonBool(v.value());
            case IntegerValue v -> new JsonNum(v.value());
            case DecimalValue v -> new JsonDec(v.text());
            case StringValue v -> new JsonStr(v.value());
            case ArrayValue v -> throw new IllegalStateException("array is not a leaf");
            case ObjectValue v -> throw new IllegalStateException("object is not a leaf");
        };
    }

    private static JsonValue fromWireNode(WireValue value, List<JsonValue> results) {
        if (value instanceof ArrayValue) return new JsonArr(results);
        List<Member> members = ((ObjectValue) value).members();
        List<JsonMember> result = new ArrayList<>(members.size());
        for (int index = 0; index < members.size(); index++) result.add(new JsonMember(members.get(index).key(), results.get(index)));
        return new JsonObj(result);
    }

    /** Writes the exact JSON value as the wire tree. */
    public static WireValue toWire(JsonValue value) {
        return rebuild(value, WireJson::jsonChildren, WireJson::toWireLeaf, WireJson::toWireNode);
    }

    private static List<JsonValue> jsonChildren(JsonValue value) {
        if (value instanceof JsonArr array) return array.items();
        if (value instanceof JsonObj object) return object.members().stream().map(JsonMember::value).toList();
        return null;
    }

    private static WireValue toWireLeaf(JsonValue value) {
        return switch (value) {
            case JsonNull unused -> new NullValue();
            case JsonBool v -> new BooleanValue(v.value());
            case JsonNum v -> new IntegerValue(v.value());
            case JsonDec v -> new DecimalValue(v.text());
            case JsonStr v -> new StringValue(v.value());
            case JsonArr v -> throw new IllegalStateException("array is not a leaf");
            case JsonObj v -> throw new IllegalStateException("object is not a leaf");
        };
    }

    private static WireValue toWireNode(JsonValue value, List<WireValue> results) {
        if (value instanceof JsonArr) return new ArrayValue(results);
        List<JsonMember> members = ((JsonObj) value).members();
        List<Member> result = new ArrayList<>(members.size());
        for (int index = 0; index < members.size(); index++) result.add(new Member(members.get(index).key(), results.get(index)));
        return new ObjectValue(result);
    }

    /** Rebuilds a tree bottom-up with an explicit stack, so that the depth of the tree is not bounded by the Java call stack. */
    private static <N, R> R rebuild(N root, java.util.function.Function<N, List<N>> children,
            java.util.function.Function<N, R> leaf, java.util.function.BiFunction<N, List<R>, R> build) {
        List<N> containers = new ArrayList<>();
        java.util.ArrayDeque<N> pending = new java.util.ArrayDeque<>();
        pending.push(root);
        while (!pending.isEmpty()) {
            N node = pending.pop();
            List<N> kids = children.apply(node);
            if (kids == null) continue;
            containers.add(node);
            for (N kid : kids) pending.push(kid);
        }
        java.util.IdentityHashMap<N, R> built = new java.util.IdentityHashMap<>();
        for (int i = containers.size() - 1; i >= 0; i--) {
            N node = containers.get(i);
            List<R> results = new ArrayList<>();
            for (N kid : children.apply(node)) results.add(built.containsKey(kid) ? built.get(kid) : leaf.apply(kid));
            built.put(node, build.apply(node, results));
        }
        return built.containsKey(root) ? built.get(root) : leaf.apply(root);
    }

    /** Reads the wire slot as the exact JSON slot. */
    public static Slot<JsonValue> fromWireSlot(Slot<WireValue> slot) {
        if (slot instanceof Absent<WireValue>) return new Absent<>();
        if (slot instanceof NullSlot<WireValue>) return new NullSlot<>();
        return new Present<>(fromWire(((Present<WireValue>) slot).value()));
    }

    /** Writes the exact JSON slot as the wire slot. */
    public static Slot<WireValue> toWireSlot(Slot<JsonValue> slot) {
        if (slot instanceof Absent<JsonValue>) return new Absent<>();
        if (slot instanceof NullSlot<JsonValue>) return new NullSlot<>();
        return new Present<>(toWire(((Present<JsonValue>) slot).value()));
    }
}
