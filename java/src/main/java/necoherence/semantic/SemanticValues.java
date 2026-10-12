// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.time.DateTimeException;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import necoherence.network.JavaHttpAdapter;
import necoherence.network.NetworkEffect;

/** Exact wire values and the validators used by admitted generated classes. */
public final class SemanticValues {
    private SemanticValues() {}

    public sealed interface WireValue permits NullValue, BooleanValue, IntegerValue, DecimalValue,
            StringValue, ArrayValue, ObjectValue {}
    public record NullValue() implements WireValue {}
    public record BooleanValue(boolean value) implements WireValue {}
    public record IntegerValue(BigInteger value) implements WireValue {
        public IntegerValue { Objects.requireNonNull(value); }
    }
    public record DecimalValue(String text) implements WireValue {
        public DecimalValue {
            if (text == null || !text.matches("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?"))
                throw new IllegalArgumentException("exact decimal spelling required");
        }
    }
    public record StringValue(String value) implements WireValue {
        public StringValue { Objects.requireNonNull(value); }
    }
    public record ArrayValue(List<WireValue> items) implements WireValue {
        public ArrayValue { items = List.copyOf(items); }
    }
    public record Member(String key, WireValue value) {
        public Member { Objects.requireNonNull(key); Objects.requireNonNull(value); }
    }
    public record ObjectValue(List<Member> members) implements WireValue {
        public ObjectValue { members = List.copyOf(members); }
        public WireValue get(String key) {
            for (Member member : members) if (member.key().equals(key)) return member.value();
            return null;
        }
    }
    public sealed interface Nullable<T> permits Null, NonNull {}
    public record Null<T>() implements Nullable<T> {}
    public record NonNull<T>(T value) implements Nullable<T> {
        public NonNull { Objects.requireNonNull(value); }
    }
    public sealed interface Slot<T> permits Absent, NullSlot, Present {}
    public record Absent<T>() implements Slot<T> {}
    public record NullSlot<T>() implements Slot<T> {}
    public record Present<T>(T value) implements Slot<T> {
        public Present { Objects.requireNonNull(value); }
    }
    public enum Unit { VALUE }
    public static final class Bytes {
        private final byte[] value;
        private final String encoding;
        public Bytes(byte[] value) { this.value = Objects.requireNonNull(value).clone(); this.encoding = null; }
        private Bytes(byte[] value, String encoding) { this.value = value; this.encoding = encoding; }
        public byte[] value() { return value.clone(); }
        public String base64() { return encoding == null ? Base64.getEncoder().encodeToString(value) : encoding; }
        public int size() { return value.length; }
    }
    public record Wrapper(String name, String key, WireValue payload) {
        public Wrapper { Objects.requireNonNull(name); Objects.requireNonNull(key); Objects.requireNonNull(payload); }
    }
    public record SealedForm(String tag, List<WireValue> fields, WireValue extras) {
        public SealedForm { Objects.requireNonNull(tag); fields = List.copyOf(fields); Objects.requireNonNull(extras); }
    }
    public record TagModel(String key, Optional<String> format, List<SealedForm> sealed) {
        public TagModel { Objects.requireNonNull(key); format = Objects.requireNonNull(format); sealed = List.copyOf(sealed); }
    }
    public record RawBody(String encoding, Bytes bytes) {
        public RawBody { Objects.requireNonNull(encoding); Objects.requireNonNull(bytes); }
    }
    public static final class ValueFailure extends Exception {
        private final String definition;
        private final List<String> path;
        private final int typeIndex;
        private final WireValue typeRef;
        private final List<WireValue> referenceTrace;
        private final String condition;
        private final WireValue observed;
        public ValueFailure(String definition, List<String> path, String condition) {
            this(definition, path, condition, -1, signatureTypeRef(definition), List.of(), null);
        }
        private ValueFailure(String definition, List<String> path, String condition, int typeIndex,
                WireValue typeRef, List<WireValue> referenceTrace, WireValue observed) {
            super(definition + " " + path + ": " + condition);
            this.definition = definition; this.path = List.copyOf(path); this.condition = condition; this.typeIndex = typeIndex; this.typeRef = typeRef;
            this.referenceTrace = List.copyOf(referenceTrace); this.observed = observed;
        }
        public String definition() { return definition; }
        public List<String> path() { return path; }
        public String condition() { return condition; }
        public WireValue observed() { return observed; }
        public int typeIndex() { return typeIndex; }
        public WireValue typeRef() { return typeRef; }
        public List<WireValue> referenceTrace() { return referenceTrace; }
    }

    static boolean unicodeValid(String text) {
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (Character.isHighSurrogate(c)) {
                if (++i == text.length() || !Character.isLowSurrogate(text.charAt(i))) return false;
            } else if (Character.isLowSurrogate(c)) return false;
        }
        return true;
    }
    static void requireUnicode(String text) {
        if (!unicodeValid(text)) throw new IllegalArgumentException("unpaired Unicode surrogate");
    }
    public static final NullValue NIL = new NullValue();
    public static String s(WireValue value) { return ((StringValue) value).value(); }
    public static boolean b(WireValue value) { return ((BooleanValue) value).value(); }
    public static BigInteger n(WireValue value) {
        return value instanceof IntegerValue number ? number.value() : new BigInteger(s(value));
    }
    public static List<WireValue> a(WireValue value) { return ((ArrayValue) value).items(); }
    static ObjectValue o(WireValue value) { return (ObjectValue) value; }
    public static WireValue f(WireValue value, String key) {
        WireValue result = o(value).get(key);
        if (result == null) throw new IllegalArgumentException("missing member " + key);
        return result;
    }
    public static String tag(WireValue value) { return s(f(value, "tag")); }
    public static WireValue payload(WireValue value) {
        WireValue result = o(value).get("value");
        return result == null ? f(value, "fields") : result;
    }
    public static boolean nil(WireValue value) { return value instanceof NullValue; }
    public static WireValue str(String value) { return new StringValue(value); }
    public static WireValue num(BigInteger value) { return new IntegerValue(value); }
    public static WireValue arr(List<WireValue> value) { return new ArrayValue(value); }
    public static WireValue obj(Object... fields) {
        List<Member> result = new ArrayList<>(fields.length / 2);
        for (int i = 0; i < fields.length; i += 2) result.add(new Member((String) fields[i], (WireValue) fields[i + 1]));
        return new ObjectValue(result);
    }
    private static WireValue signatureTypeRef(String definition) {
        return obj(
                "source", obj(
                        "repository", str("ncoh-type-signatures"),
                        "revision", str("1"),
                        "path", str(""),
                        "content_digest", str(""),
                        "document_id", str(""),
                        "declared_revision", NIL),
                "definition_name", str(definition),
                "pointer", arr(List.of()));
    }
    public static WireValue variant(String name) { return obj("tag", str(name)); }
    public static WireValue variant(String name, WireValue value) { return obj("tag", str(name), "value", value); }
    public static WireValue fields(String name, WireValue value) { return obj("tag", str(name), "fields", value); }
    public static WireValue wrapEncode(WireValue profile, String wrapperName, String value) {
        WireValue wrapper = a(f(profile, "wrappers")).stream()
                .filter(candidate -> s(f(candidate, "name")).equals(wrapperName)).findFirst()
                .orElseThrow(() -> new IllegalArgumentException("unknown wrapper"));
        return obj(s(f(wrapper, "key")), str(value));
    }
    public static String wrapDecode(WireValue profile, String wrapperName, WireValue value) {
        WireValue wrapper = a(f(profile, "wrappers")).stream()
                .filter(candidate -> s(f(candidate, "name")).equals(wrapperName)).findFirst()
                .orElseThrow(() -> new IllegalArgumentException("unknown wrapper"));
        String key = s(f(wrapper, "key"));
        if (!(value instanceof ObjectValue object) || object.members().size() != 1
                || !(object.get(key) instanceof StringValue text))
            throw new IllegalArgumentException("validated wrapper shape");
        return text.value();
    }
    public static WireValue withMember(String key, String text, WireValue value) {
        if (!(value instanceof ObjectValue object)) return value;
        List<Member> members = new ArrayList<>();
        members.add(new Member(key, str(text)));
        for (Member member : object.members()) if (!member.key().equals(key)) members.add(member);
        return new ObjectValue(members);
    }
    public static int selectBranch(WireValue graph, WireValue reference, WireValue value) {
        Context context = new Context(graph);
        WireValue shape = context.resolve(reference);
        if (shape == null || !tag(shape).equals("TaggedUnion")) return -1;
        List<WireValue> branches = a(f(payload(shape), "branches"));
        for (int index = 0; index < branches.size(); index++)
            if (context.selectorAccepts(f(branches.get(index), "selector"), s(f(branches.get(index), "wire_tag")), value)) return index;
        return -1;
    }
    static Slot<WireValue> slot(WireValue value) {
        return value == null ? new Absent<>() : nil(value) ? new NullSlot<>() : new Present<>(value);
    }
    static Slot<WireValue> exchangeSlot(WireValue value) {
        return switch (tag(value)) {
            case "Absent" -> new Absent<>();
            case "Null" -> new NullSlot<>();
            case "Present" -> new Present<>(SemanticGeneration.exact(payload(value)));
            default -> throw new IllegalArgumentException("slot variant");
        };
    }
    public static WireValue member(ObjectValue value, String name) { return value.get(name); }
    public static String encodeWire(WireValue value) {
        StringBuilder result = new StringBuilder(); appendJson(value, result); return result.toString();
    }
    static void appendJson(WireValue value, StringBuilder out) {
        switch (value) {
            case NullValue unused -> out.append("null");
            case BooleanValue v -> out.append(v.value());
            case IntegerValue v -> out.append(v.value());
            case DecimalValue v -> out.append(v.text());
            case StringValue v -> appendString(v.value(), out);
            case ArrayValue v -> {
                out.append('[');
                for (int i = 0; i < v.items().size(); i++) { if (i != 0) out.append(','); appendJson(v.items().get(i), out); }
                out.append(']');
            }
            case ObjectValue v -> {
                out.append('{');
                for (int i = 0; i < v.members().size(); i++) {
                    if (i != 0) out.append(',');
                    Member member = v.members().get(i); appendString(member.key(), out); out.append(':'); appendJson(member.value(), out);
                }
                out.append('}');
            }
        }
    }
    public static void appendString(String text, StringBuilder out) {
        out.append('"');
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            switch (c) {
                case '"' -> out.append("\\\""); case '\\' -> out.append("\\\\");
                case '\n' -> out.append("\\n"); case '\r' -> out.append("\\r"); case '\t' -> out.append("\\t");
                case '\b' -> out.append("\\b"); case '\f' -> out.append("\\f");
                default -> {
                    if (c < 32) { out.append("\\u00").append(Character.forDigit(c >>> 4, 16)).append(Character.forDigit(c & 15, 16)); }
                    else out.append(c);
                }
            }
        }
        out.append('"');
    }
    public static Slot<WireValue> projectField(Slot<WireValue> source, String name) {
        if (!(source instanceof Present<WireValue> present)) return source;
        if (nil(present.value())) return new NullSlot<>();
        return present.value() instanceof ObjectValue object ? slot(object.get(name)) : new Absent<>();
    }
    public static Slot<WireValue> projectIndex(Slot<WireValue> source, BigInteger index) {
        if (!(source instanceof Present<WireValue> present)) return source;
        if (nil(present.value())) return new NullSlot<>();
        if (index.signum() < 0 || !(present.value() instanceof ArrayValue array) || index.compareTo(BigInteger.valueOf(array.items().size())) >= 0) return new Absent<>();
        return slot(((ArrayValue) present.value()).items().get(index.intValue()));
    }
    public static Slot<WireValue> projectVariant(Slot<WireValue> source, String tag, String key) {
        if (!(source instanceof Present<WireValue> present)) return source;
        if (nil(present.value())) return new NullSlot<>();
        return present.value() instanceof ObjectValue object && new StringValue(tag).equals(object.get(key)) ? source : new Absent<>();
    }

    /** An immutable context shared by every codec of one admitted generation. */
    public static final class Context {
        final WireValue graph;
        final WireValue profile;
        final List<WireValue> nodes;
        final Map<WireValue, Integer> indices;
        private final Map<String, WireValue> formats;
        private final Map<String, BigInteger> numbers;
        private final WireValue graphemeRules;
        private final GraphemeRules publicGraphemeRules;
        private final Map<String, WireValue> integerDomains;
        private final ThreadLocal<List<Active>> activeProof = new ThreadLocal<>();
        private final Set<Integer> meaningful = new HashSet<>();
        Context(WireValue graph) {
            this.graph = graph; this.profile = f(graph, "profile"); this.nodes = a(f(graph, "nodes"));
            Map<WireValue, Integer> indices = new LinkedHashMap<>();
            for (int i = 0; i < nodes.size(); i++) {
                if (indices.put(f(nodes.get(i), "reference"), i) != null) throw new IllegalArgumentException("duplicate type reference");
            }
            this.indices = Map.copyOf(indices);
            Map<String, WireValue> formats = new LinkedHashMap<>();
            for (WireValue binding : a(f(profile, "format_bindings"))) formats.put(s(f(binding, "name")), compileNumbers(f(binding, "rule")));
            this.formats = Map.copyOf(formats);
            Map<String, BigInteger> numbers = new HashMap<>(); collectNumbers(graph, numbers); this.numbers = Map.copyOf(numbers);
            Map<String, WireValue> domains = new LinkedHashMap<>();
            for (WireValue binding : a(f(profile, "integer_domains")))
                domains.put(s(f(binding, "name")), compileNumbers(binding));
            this.integerDomains = Map.copyOf(domains);
            this.graphemeRules = compileNumbers(f(profile, "grapheme_rules"));
            this.publicGraphemeRules = nil(graphemeRules) ? null : new GraphemeRules(graphemeRules);
        }
        private WireValue tagModel() { return f(profile, "tag"); }
        public String tagKey() { return nil(tagModel()) ? "" : s(f(tagModel(), "key")); }
        private WireValue namedWrapper(String name) {
            return a(f(profile, "wrappers")).stream().filter(value -> s(f(value, "name")).equals(name)).findFirst().orElse(null);
        }
        boolean ordinaryOnly() { return false; }
        boolean tagTextAccepted(String text) {
            if (nil(tagModel())) return false;
            WireValue format = f(tagModel(), "format");
            return nil(format) || recognize(formats.get(s(format)), text);
        }
        boolean ordinaryTagAccepted(WireValue value) {
            return value instanceof StringValue text && tagTextAccepted(text.value());
        }
        public boolean formatDefined(String name) {
            return formats.containsKey(Objects.requireNonNull(name, "name"));
        }
        /**
         * Recognizes a value using the admitted profile's format rule.
         * Unknown formats return false. This operation has no state changes or external effects.
         * @throws NullPointerException if name or value is null
         */
        public boolean recognizeFormat(String name, String value) {
            Objects.requireNonNull(name, "name");
            Objects.requireNonNull(value, "value");
            return recognize(formats.get(name), value);
        }
        /** Reads the verified Unicode component, table digest, and resolved sources. */
        public GraphemeRules graphemeRules() {
            if (nil(graphemeRules)) throw new IllegalStateException("MissingGraphemeRules");
            return publicGraphemeRules;
        }
        private BigInteger n(WireValue value) {
            if (value instanceof IntegerValue integer) return integer.value();
            BigInteger number = numbers.get(s(value)); return number == null ? SemanticValues.n(value) : number;
        }
        private boolean bounds(long count, WireValue minimum, WireValue maximum) {
            BigInteger size = BigInteger.valueOf(count);
            return (nil(minimum) || size.compareTo(n(minimum)) >= 0) && (nil(maximum) || size.compareTo(n(maximum)) <= 0);
        }
        public int index(WireValue reference) {
            Integer result = indices.get(reference);
            if (result == null) throw new IllegalArgumentException("unresolved source-qualified type");
            return result;
        }
        public WireValue shape(int index) { return f(nodes.get(index), "shape"); }
        public WireValue reference(int index) { return f(nodes.get(index), "reference"); }
        public WireValue resolve(WireValue reference) {
            Set<WireValue> seen = new HashSet<>();
            while (seen.add(reference)) {
                WireValue shape = shape(index(reference));
                if (!tag(shape).equals("Alias")) return shape;
                reference = f(payload(shape), "target");
            }
            return null;
        }
        synchronized void meaning(int index) throws ValueFailure {
            if (meaningful.contains(index)) return;
            Set<Integer> reached = new HashSet<>(); List<Integer> pending = new ArrayList<>(); pending.add(index);
            while (!pending.isEmpty()) {
                int at = pending.remove(pending.size() - 1);
                if (!reached.add(at)) continue;
                WireValue shape = shape(at); String kind = tag(shape);
                WireValue spec = o(shape).get("value"); if (spec == null) spec = o(shape).get("fields");
                if (kind.equals("Opaque")) fail(at, List.of(), "MO10");
                if (kind.equals("Decimal") && !b(f(f(profile, "numbers"), "decimals"))) fail(at, List.of(), "MO08");
                if ((kind.equals("Bytes") || kind.equals("RawBody")) && nil(f(profile, "bytes_policy"))) fail(at, List.of(), "MO03");
                if (kind.equals("Integer") && !nil(f(spec, "domain"))
                        && !integerDomains.containsKey(s(f(spec, "domain")))) fail(at, List.of(), "MO04");
                if (kind.equals("Integer") && !integerBoundsInsideDomain(spec)) fail(at, List.of(), "MO09");
                if (kind.equals("String")) {
                    WireValue use = f(spec, "format");
                    if (!nil(use) && tag(use).equals("Named") && !formats.containsKey(s(payload(use)))) fail(at, List.of(), "MO01");
                    for (WireValue bound : a(f(spec, "lengths")))
                        if (tag(f(bound, "unit")).equals("Graphemes") && nil(graphemeRules)) fail(at, List.of(), "MO02");
                    if (!nil(f(spec, "wrapper"))) {
                        WireValue wrapper = namedWrapper(s(f(spec, "wrapper")));
                        if (wrapper == null) fail(at, List.of(), "MO05");
                        if (!tag(f(wrapper, "payload")).equals("Text")) fail(at, List.of(), "MO06");
                    }
                }
                if (kind.equals("Sealed")) {
                    if (nil(tagModel())) fail(at, List.of(), "MO11");
                    String sealedTag = s(f(spec, "tag"));
                    if (a(f(tagModel(), "sealed")).stream().noneMatch(form -> s(f(form, "tag")).equals(sealedTag)))
                        fail(at, List.of(), "MO07");
                }
                if (kind.equals("TaggedUnion"))
                    for (WireValue branch : a(f(spec, "branches")))
                        if (tag(f(branch, "selector")).equals("InternalTag") && nil(tagModel())) fail(at, List.of(), "MO11");
                for (WireValue child : children(shape)) pending.add(index(child));
            }
            meaningful.addAll(reached);
        }
        static List<WireValue> children(WireValue shape) {
            String kind = tag(shape); List<WireValue> result = new ArrayList<>();
            switch (kind) {
                case "Alias" -> result.add(f(payload(shape), "target"));
                case "Array" -> result.add(f(f(payload(shape), "item"), "type_ref"));
                case "Product" -> {
                    WireValue spec = payload(shape);
                    for (WireValue field : a(f(spec, "fields"))) result.add(f(f(field, "slot"), "type_ref"));
                    if (tag(f(spec, "extras")).equals("Allow")) result.add(f(f(payload(f(spec, "extras")), "value"), "type_ref"));
                }
                case "TaggedUnion" -> { for (WireValue branch : a(f(payload(shape), "branches"))) result.add(f(branch, "target")); }
                default -> {}
            }
            return result;
        }
        public WireValue decode(int type, String text) throws ValueFailure {
            WireValue value;
            try { value = SemanticGeneration.readJson(text); }
            catch (RuntimeException error) { throw new ValueFailure(definition(type), List.of(), "InvalidJson: " + error.getMessage()); }
            validate(type, value); return value;
        }
        public WireValue decodeWithDefaults(int type, String text) throws ValueFailure {
            WireValue value;
            try { value = SemanticGeneration.readJson(text); }
            catch (RuntimeException error) { throw new ValueFailure(definition(type), List.of(), "InvalidJson: " + error.getMessage()); }
            meaning(type); value = defaults(type, value, new HashSet<>()); validate(type, value); return value;
        }
        public void validate(int type, WireValue value) throws ValueFailure {
            if (value == null) fail(type, List.of(), "NullNotAllowed");
            meaning(type); List<Active> active = new ArrayList<>(), previous = activeProof.get(); activeProof.set(active);
            try { evaluate(type, value, new ArrayList<>(), active); } finally { if (previous == null) activeProof.remove(); else activeProof.set(previous); }
        }
        void validateDeclaredDefault(int type, WireValue value) throws ValueFailure {
            List<Active> active = new ArrayList<>(), previous = activeProof.get(); activeProof.set(active);
            try { evaluate(type, value, new ArrayList<>(), active); } finally { if (previous == null) activeProof.remove(); else activeProof.set(previous); }
        }
        public Bytes decodeBytes(int type, WireValue value) throws ValueFailure {
            validate(type, value);
            String encoding = bytesText(value);
            String alphabet = tag(f(f(profile, "bytes_policy"), "alphabet"));
            return new Bytes(bytesDecoder(alphabet, encoding).decode(padBase64(encoding)), encoding);
        }
        public WireValue encodeBytes(Bytes value) {
            String text = value.base64();
            WireValue policy = f(profile, "bytes_policy");
            if (!nil(f(policy, "wrapper"))) return wrapEncode(profile, s(f(policy, "wrapper")), text);
            return str(text);
        }
        public String decodeText(int type, WireValue value) {
            WireValue spec = payload(shape(type));
            return nil(f(spec, "wrapper")) ? s(value) : wrapDecode(profile, s(f(spec, "wrapper")), value);
        }
        public WireValue encodeText(int type, String value) {
            WireValue spec = payload(shape(type));
            return nil(f(spec, "wrapper")) ? str(value) : wrapEncode(profile, s(f(spec, "wrapper")), value);
        }
        public int selectBranch(int type, WireValue value) {
            WireValue shape = resolve(reference(type));
            if (shape == null || !tag(shape).equals("TaggedUnion")) return -1;
            List<WireValue> branches = a(f(payload(shape), "branches"));
            for (int index = 0; index < branches.size(); index++)
                if (selectorAccepts(f(branches.get(index), "selector"), s(f(branches.get(index), "wire_tag")), value)) return index;
            return -1;
        }
        public void validateSlot(int type, boolean required, boolean nullable, Slot<WireValue> value) throws ValueFailure {
            if (value == null) fail(type, List.of(), "NullNotAllowed");
            List<Active> active = new ArrayList<>(), previous = activeProof.get(); activeProof.set(active);
            try { validateSlot(type, required, nullable, value, new ArrayList<>(), active); } finally { if (previous == null) activeProof.remove(); else activeProof.set(previous); }
        }
        public void validateContract(WireValue contract, Slot<WireValue> value) throws ValueFailure {
            validateSlot(index(f(contract, "type_ref")), b(f(contract, "required")), b(f(contract, "nullable")), value);
        }
        private void validateSlot(int type, boolean required, boolean nullable, Slot<WireValue> value,
                List<String> path, List<Active> active) throws ValueFailure {
            meaning(type);
            switch (value) {
                case Absent<WireValue> unused -> { if (required) fail(type, path, "MissingRequired"); }
                case NullSlot<WireValue> unused -> { if (!nullable) fail(type, path, "NullNotAllowed"); }
                case Present<WireValue> present -> evaluate(type, present.value(), path, active);
            }
        }
        private void validateElement(int type, boolean nullable, WireValue value,
                List<String> path, List<Active> active) throws ValueFailure {
            meaning(type);
            if (nil(value) && nullable) return;
            evaluate(type, value, path, active);
        }
        boolean elementAcceptsNull(int type, boolean nullable) {
            List<Active> active = new ArrayList<>(), previous = activeProof.get(); activeProof.set(active);
            try {
                validateElement(type, nullable, NIL, new ArrayList<>(), active);
                return true;
            } catch (ValueFailure failure) {
                return false;
            } finally {
                if (previous == null) activeProof.remove(); else activeProof.set(previous);
            }
        }
        private record Active(int type, WireValue value) {}
        private String definition(int type) {
            WireValue ref = reference(type); return s(ref);
        }
        private void fail(int type, List<String> path, String condition) throws ValueFailure {
            List<Active> active = activeProof.get();
            List<WireValue> trace = active == null ? List.of() : active.stream()
                    .limit(Math.max(0, active.size() - 1)).map(entry -> reference(entry.type())).toList();
            WireValue observed = active == null || active.isEmpty() ? shape(type) : active.getFirst().value();
            for (String step : path) {
                if (observed instanceof ObjectValue object) observed = object.get(step);
                else if (observed instanceof ArrayValue array) observed = array.items().get(Integer.parseInt(step));
                else { observed = null; break; }
            }
            throw new ValueFailure(definition(type), path, condition, type, signatureTypeRef(definition(type)), trace, observed);
        }
        private void evaluate(int type, WireValue value, List<String> path, List<Active> active) throws ValueFailure {
            for (Active previous : active) if (previous.type == type && previous.value == value) fail(type, path, "ReferenceCycle");
            active.add(new Active(type, value));
            try {
                WireValue shape = shape(type); String kind = tag(shape);
                WireValue spec = o(shape).get("value"); if (spec == null) spec = o(shape).get("fields");
                switch (kind) {
                    case "Boolean" -> {
                        if (!(value instanceof BooleanValue)) fail(type, path, "WrongValueKind: boolean");
                        if (!nil(f(spec, "const_value")) && !f(spec, "const_value").equals(value)) fail(type, path, "ConstMismatch");
                    }
                    case "Integer" -> {
                        BigInteger number = integerValue(spec, value);
                        if (number == null) fail(type, path, "WrongValueKind: integer");
                        if (!integerInDomain(spec, number)) fail(type, path, "IntegerDomain");
                        if (!nil(f(spec, "const_value")) && !n(f(spec, "const_value")).equals(number)) fail(type, path, "ConstMismatch");
                        if (!nil(f(spec, "enum_values")) && a(f(spec, "enum_values")).stream().noneMatch(v -> n(v).equals(number))) fail(type, path, "EnumMismatch");
                        if (!nil(f(spec, "minimum")) && number.compareTo(n(f(spec, "minimum"))) < 0) fail(type, path, "BelowMinimum");
                        if (!nil(f(spec, "maximum")) && number.compareTo(n(f(spec, "maximum"))) > 0) fail(type, path, "AboveMaximum");
                    }
                    case "Decimal" -> {
                        if (!(value instanceof DecimalValue)) fail(type, path, "WrongValueKind: decimal");
                        java.math.BigDecimal number = new java.math.BigDecimal(((DecimalValue) value).text());
                        checkDecimalBound(type, path, number, f(spec, "minimum"), true);
                        checkDecimalBound(type, path, number, f(spec, "maximum"), false);
                    }
                    case "String" -> {
                        WireValue actual = value;
                        if (!nil(f(spec, "wrapper"))) {
                            String name = s(f(spec, "wrapper"));
                            try { actual = str(wrapDecode(profile, name, value)); }
                            catch (IllegalArgumentException failure) { fail(type, path, "InvalidWrapper: " + name); }
                        }
                        if (!(actual instanceof StringValue)) fail(type, path, "WrongValueKind: string");
                        String text = s(actual);
                        if (!nil(f(spec, "const_value")) && !f(spec, "const_value").equals(actual)) fail(type, path, "ConstMismatch");
                        if (!nil(f(spec, "enum_values")) && !a(f(spec, "enum_values")).contains(actual)) fail(type, path, "EnumMismatch");
                        for (WireValue bound : a(f(spec, "lengths"))) {
                            long count = switch (tag(f(bound, "unit"))) {
                                case "Utf8Bytes" -> utf8Length(text);
                                case "Graphemes" -> graphemeCount(graphemeRules, text);
                                default -> text.codePointCount(0, text.length());
                            };
                            if (!bounds(count, f(bound, "minimum"), f(bound, "maximum"))) fail(type, path, "StringLength");
                        }
                        WireValue use = f(spec, "format");
                        if (!nil(use)) {
                            String name = tag(use).equals("Named") ? s(payload(use)) : "inline";
                            WireValue rule = tag(use).equals("Named") ? formats.get(name) : payload(use);
                            if (!recognize(rule, text)) fail(type, path, "Format: " + name);
                        }
                    }
                    case "Bytes", "RawBody" -> {
                        int count = decodedBytesLength(type, value, path);
                        if (kind.equals("Bytes") && !bounds(count, f(spec, "minimum"), f(spec, "maximum"))) fail(type, path, "BytesLength");
                    }
                    case "Product" -> product(type, value, spec, path, active);
                    case "Array" -> {
                        if (!(value instanceof ArrayValue)) fail(type, path, "WrongValueKind: array");
                        List<WireValue> values = a(value);
                        if (!bounds(values.size(), f(spec, "min_length"), f(spec, "max_length"))) fail(type, path, "ArrayLength");
                        WireValue item = f(spec, "item"); int itemType = index(f(item, "type_ref"));
                        for (int i = 0; i < values.size(); i++) {
                            path.add(Integer.toString(i));
                            validateElement(itemType, b(f(item, "nullable")), values.get(i), path, active);
                            path.remove(path.size() - 1);
                        }
                    }
                    case "Alias" -> evaluate(index(f(spec, "target")), value, path, active);
                    case "TaggedUnion" -> {
                        if (value instanceof ObjectValue object) objectMembers(type, object, path);
                        WireValue selected = null;
                        for (WireValue branch : a(f(spec, "branches")))
                            if (selectorAccepts(f(branch, "selector"), s(f(branch, "wire_tag")), value)) { selected = branch; break; }
                        if (selected == null) fail(type, path, "NoBranchSelected");
                        evaluate(index(f(selected, "target")), value, path, active);
                    }
                    case "Sealed" -> sealed(type, value, spec, path, active);
                    case "Never" -> fail(type, path, "InvalidDataModel");
                    case "Unknown" -> {
                        if (tag(payload(shape)).equals("OrdinaryObject")) {
                            if (!(value instanceof ObjectValue)) fail(type, path, "WrongValueKind: ordinary object");
                            ObjectValue object = (ObjectValue) value;
                            objectMembers(type, object, path);
                            if (!classOf(object).equals("Ordinary")) fail(type, path, "WrongValueKind: ordinary object");
                            dataMembers(type, object, path, active);
                        } else {
                            data(type, value, path, active);
                        }
                    }
                    case "Unit" -> { if (!nil(value)) fail(type, path, "WrongValueKind: unit"); }
                    default -> fail(type, path, "UndefinedMeaning: " + kind);
                }
            } finally { active.remove(active.size() - 1); }
        }
        private WireValue integerBinding(WireValue spec) {
            String name = nil(f(spec, "domain")) ? s(f(profile, "default_integer_domain")) : s(f(spec, "domain"));
            return integerDomains.get(name);
        }
        private boolean integerBoundsInsideDomain(WireValue spec) {
            WireValue binding = integerBinding(spec);
            if (binding == null || tag(f(binding, "range")).equals("Unbounded")) return binding != null;
            WireValue range = payload(f(binding, "range"));
            return (nil(f(spec, "minimum")) || n(f(spec, "minimum")).compareTo(n(f(range, "minimum"))) >= 0)
                    && (nil(f(spec, "maximum")) || n(f(spec, "maximum")).compareTo(n(f(range, "maximum"))) <= 0);
        }
        private boolean integerInDomain(WireValue spec, BigInteger value) {
            WireValue binding = integerBinding(spec);
            if (binding == null || tag(f(binding, "range")).equals("Unbounded")) return binding != null;
            WireValue range = payload(f(binding, "range"));
            return value.compareTo(n(f(range, "minimum"))) >= 0 && value.compareTo(n(f(range, "maximum"))) <= 0;
        }
        private BigInteger integerValue(WireValue spec, WireValue value) {
            WireValue binding = integerBinding(spec); if (binding == null) return null;
            Set<String> forms = new HashSet<>(a(f(binding, "forms")).stream().map(SemanticValues::tag).toList());
            try {
                if (value instanceof IntegerValue integer && forms.contains("Number")) return integer.value();
                if (value instanceof DecimalValue decimal && forms.contains("IntegralDecimal"))
                    return new java.math.BigDecimal(decimal.text()).toBigIntegerExact();
                if (value instanceof StringValue text && forms.contains("DecimalString")
                        && text.value().matches("0|-?[1-9][0-9]*")) return new BigInteger(text.value());
            } catch (ArithmeticException ignored) {}
            return null;
        }
        private void checkDecimalBound(int type, List<String> path, java.math.BigDecimal number,
                WireValue encoded, boolean minimum) throws ValueFailure {
            if (nil(encoded)) return;
            BigInteger mantissa = n(f(encoded, "mantissa")); int scale = n(f(encoded, "scale")).intValueExact();
            java.math.BigDecimal bound = new java.math.BigDecimal(mantissa, scale);
            int order = number.compareTo(bound); boolean exclusive = b(f(encoded, "exclusive"));
            if (minimum ? order < 0 || exclusive && order == 0 : order > 0 || exclusive && order == 0)
                fail(type, path, minimum ? "BelowMinimum" : "AboveMaximum");
        }
        private void objectMembers(int type, ObjectValue object, List<String> path) throws ValueFailure {
            Set<String> seen = new HashSet<>();
            for (Member member : object.members())
                if (!seen.add(member.key())) fail(type, path, "DuplicateField: " + member.key());
            if (nil(tagModel())) return;
            WireValue value = object.get(tagKey());
            if (value == null) return;
            path.add(tagKey());
            if (value instanceof StringValue text) {
                if (!unicodeValid(text.value())) fail(type, path, "InvalidDataModel");
                if (!tagTextAccepted(text.value())) fail(type, path, "InvalidTag");
            } else {
                fail(type, path, "InvalidTag");
            }
            path.remove(path.size() - 1);
        }
        private void product(int type, WireValue value, WireValue spec, List<String> path, List<Active> active) throws ValueFailure {
            if (!(value instanceof ObjectValue)) fail(type, path, "WrongValueKind: object");
            ObjectValue object = (ObjectValue) value;
            objectMembers(type, object, path);
            if(!classOf(object).equals("Ordinary"))fail(type,path,"ReservedForm");
            Set<String> known = new HashSet<>();
            for (WireValue field : a(f(spec, "fields"))) {
                String name = s(f(field, "wire_name")); known.add(name); WireValue contract = f(field, "slot");
                path.add(name); validateSlot(index(f(contract, "type_ref")), b(f(contract, "required")),
                        b(f(contract, "nullable")), slot(object.get(name)), path, active); path.remove(path.size() - 1);
            }
            WireValue extras = f(spec, "extras");
            for (Member member : object.members()) {
                if (known.contains(member.key()) || !nil(tagModel()) && member.key().equals(tagKey())) continue;
                path.add(member.key());
                if (tag(extras).equals("Reject")) fail(type, path, "UnexpectedField: " + member.key());
                WireValue fields = payload(extras), use = f(fields, "key_format");
                if (!nil(use)) {
                    WireValue rule = tag(use).equals("Named") ? formats.get(s(payload(use))) : payload(use);
                    if (!recognize(rule, member.key())) fail(type, path, "KeyFormat: " + member.key());
                }
                WireValue contract = f(fields, "value");
                validateElement(index(f(contract, "type_ref")), b(f(contract, "nullable")),
                        member.value(), path, active);
                path.remove(path.size() - 1);
            }
        }
        public String classOf(ObjectValue value) {
            if (!nil(tagModel())) {
                WireValue actual = value.get(tagKey());
                if (actual instanceof StringValue text
                        && a(f(tagModel(), "sealed")).stream().anyMatch(form -> s(f(form, "tag")).equals(text.value())))
                    return "Sealed";
            }
            for (WireValue wrapper : a(f(profile, "wrappers")))
                if (value.members().size() == 1 && value.get(s(f(wrapper, "key"))) != null) return "Wrapper";
            return "Ordinary";
        }
        private boolean selectorAccepts(WireValue selector, String wireTag, WireValue value) {
            return switch (tag(selector)) {
                case "InternalTag" -> value instanceof ObjectValue object
                        && object.get(tagKey()) instanceof StringValue text && text.value().equals(wireTag);
                case "MemberShape" -> {
                    if (!(value instanceof ObjectValue object)) yield false;
                    boolean accepted = true;
                    for (WireValue check : a(payload(selector))) {
                        WireValue member = object.get(s(f(check, "key"))), test = f(check, "test");
                        if (tag(test).equals("Absent")) accepted &= member == null;
                        else accepted &= member instanceof StringValue text
                                && recognize(formats.get(s(payload(test))), text.value());
                    }
                    yield accepted;
                }
                case "Kind" -> switch (tag(payload(selector))) {
                    case "Null" -> nil(value);
                    case "Boolean" -> value instanceof BooleanValue;
                    case "Number" -> value instanceof IntegerValue || value instanceof DecimalValue;
                    case "String" -> value instanceof StringValue;
                    case "Array" -> value instanceof ArrayValue;
                    default -> value instanceof ObjectValue;
                };
                case "Otherwise" -> true;
                default -> false;
            };
        }
        private void sealed(int type, WireValue value, WireValue spec, List<String> path, List<Active> active) throws ValueFailure {
            if (!(value instanceof ObjectValue)) fail(type, path, "WrongValueKind: sealed object");
            ObjectValue object = (ObjectValue) value;
            objectMembers(type, object, path);
            if (!classOf(object).equals("Sealed")) fail(type, path, "WrongValueKind: sealed object");
            String expected = s(f(spec, "tag"));
            String actual = s(object.get(tagKey()));
            if (!actual.equals(expected)) fail(type, path, "InvalidDataModel");
            WireValue form = a(f(tagModel(), "sealed")).stream()
                    .filter(candidate -> s(f(candidate, "tag")).equals(expected)).findFirst().orElse(null);
            if (form == null) fail(type, path, "InvalidDataModel");
            Set<String> known = new HashSet<>(List.of(tagKey()));
            for (WireValue field : a(f(form, "fields"))) {
                String key = s(f(field, "key")); known.add(key); WireValue member = object.get(key);
                path.add(key);
                if (member == null && b(f(field, "required"))) fail(type, path, "MissingRequired");
                if (member != null) sealedLeaf(type, member, f(field, "leaf"), path, active);
                path.remove(path.size() - 1);
            }
            for (WireValue refinement : a(f(spec, "refinements"))) {
                String key = s(f(refinement, "key")); WireValue member = object.get(key);
                if (member != null) { path.add(key); sealedLeaf(type, member, f(refinement, "leaf"), path, active); path.remove(path.size() - 1); }
            }
            for (Member member : object.members()) if (!known.contains(member.key())) {
                path.add(member.key());
                if (tag(f(form, "extras")).equals("Reject")) fail(type, path, "UnexpectedField: " + member.key());
                data(type, member.value(), path, active); path.remove(path.size() - 1);
            }
        }
        private void sealedLeaf(int type, WireValue value, WireValue leaf, List<String> path, List<Active> active) throws ValueFailure {
            WireValue synthetic = variant(tag(leaf), payload(leaf));
            WireValue old = nodes.get(type), replacement = obj("reference", f(old, "reference"), "shape", synthetic);
            List<WireValue> mutable = new ArrayList<>(nodes); mutable.set(type, replacement);
            evaluateLeaf(type, value, synthetic, path, active);
        }
        private void evaluateLeaf(int type, WireValue value, WireValue shape, List<String> path, List<Active> active) throws ValueFailure {
            String kind = tag(shape); WireValue spec = payload(shape);
            if (kind.equals("String")) {
                WireValue actual = value;
                if (!nil(f(spec, "wrapper"))) {
                    String name = s(f(spec, "wrapper"));
                    try { actual = str(wrapDecode(profile, name, value)); }
                    catch (IllegalArgumentException failure) { fail(type, path, "InvalidWrapper: " + name); }
                }
                if (!(actual instanceof StringValue)) fail(type, path, "WrongValueKind: string");
                String text = s(actual);
                if (!nil(f(spec, "const_value")) && !f(spec, "const_value").equals(actual)) fail(type, path, "ConstMismatch");
                if (!nil(f(spec, "enum_values")) && !a(f(spec, "enum_values")).contains(actual)) fail(type, path, "EnumMismatch");
                for (WireValue bound : a(f(spec, "lengths"))) {
                    long count = tag(f(bound, "unit")).equals("Utf8Bytes") ? utf8Length(text)
                            : tag(f(bound, "unit")).equals("Graphemes") ? graphemeCount(graphemeRules, text)
                            : text.codePointCount(0, text.length());
                    if (!bounds(count, f(bound, "minimum"), f(bound, "maximum"))) fail(type, path, "StringLength");
                }
                WireValue use = f(spec, "format");
                if (!nil(use)) {
                    String name = tag(use).equals("Named") ? s(payload(use)) : "inline";
                    WireValue rule = tag(use).equals("Named") ? formats.get(name) : payload(use);
                    if (!recognize(rule, text)) fail(type, path, "Format: " + name);
                }
            } else {
                BigInteger number = integerValue(spec, value);
                if (number == null) fail(type, path, "WrongValueKind: integer");
                if (!integerInDomain(spec, number)) fail(type, path, "IntegerDomain");
            }
        }
        private void data(int type, WireValue value, List<String> path, List<Active> active) throws ValueFailure {
            if (value instanceof DecimalValue && !b(f(f(profile, "numbers"), "decimals")))
                fail(type, path, "InvalidDataModel");
            if (value instanceof StringValue text && !unicodeValid(text.value()))
                fail(type, path, "InvalidDataModel");
            if (value instanceof ObjectValue object) {
                objectMembers(type, object, path);
                dataMembers(type, object, path, active);
            } else if (value instanceof ArrayValue array) {
                for (int i = 0; i < array.items().size(); i++) {
                    path.add(Integer.toString(i));
                    data(type, array.items().get(i), path, active);
                    path.remove(path.size() - 1);
                }
            }
        }
        private void dataMembers(int type, ObjectValue object, List<String> path, List<Active> active)
                throws ValueFailure {
            for (Member member : object.members()) {
                path.add(member.key());
                if (!unicodeValid(member.key())) fail(type, path, "InvalidDataModel");
                data(type, member.value(), path, active);
                path.remove(path.size() - 1);
            }
        }
        private String bytesText(WireValue value) {
            WireValue policy = f(profile, "bytes_policy");
            if (!nil(f(policy, "wrapper"))) return wrapDecode(profile, s(f(policy, "wrapper")), value);
            return s(value);
        }
        private String padBase64(String value) { return value + "=".repeat((4 - value.length() % 4) % 4); }
        private Base64.Decoder bytesDecoder(String alphabet, String value) {
            return alphabet.equals("UrlSafe") || alphabet.equals("Either") && (value.indexOf('-') >= 0 || value.indexOf('_') >= 0)
                    ? Base64.getUrlDecoder() : Base64.getDecoder();
        }
        private int decodedBytesLength(int type, WireValue value, List<String> path) throws ValueFailure {
            String text;
            try { text = bytesText(value); }
            catch (RuntimeException failure) { fail(type, path, "InvalidBytes"); return -1; }
            WireValue policy = f(profile, "bytes_policy"); String alphabet = tag(f(policy, "alphabet"));
            String digits = alphabet.equals("Standard") ? "[A-Za-z0-9+/]*={0,2}" :
                    alphabet.equals("UrlSafe") ? "[A-Za-z0-9_-]*={0,2}" : "[A-Za-z0-9+/_-]*={0,2}";
            if (!text.matches(digits) || !b(f(policy, "padding_optional")) && text.length() % 4 != 0)
                fail(type, path, "InvalidBytes");
            try {
                return bytesDecoder(alphabet, text).decode(padBase64(text)).length;
            } catch (IllegalArgumentException failure) { fail(type, path, "InvalidBytes"); return -1; }
        }
        private WireValue defaults(int type, WireValue value, Set<Active> active) throws ValueFailure {
            Active key = new Active(type, value);
            if (!active.add(key)) fail(type, List.of(), "ReferenceCycle");
            WireValue shape = shape(type); String kind = tag(shape);
            WireValue spec = o(shape).get("value"); if (spec == null) spec = o(shape).get("fields");
            WireValue result = value;
            if (kind.equals("Alias")) result = defaults(index(f(spec, "target")), value, active);
            else if (kind.equals("Array") && value instanceof ArrayValue) {
                List<WireValue> items = new ArrayList<>();
                for (WireValue item : a(value)) items.add(defaults(index(f(f(spec, "item"), "type_ref")), item, active));
                result = arr(items);
            } else if (kind.equals("Product") && value instanceof ObjectValue) {
                List<Member> members = new ArrayList<>(); Set<String> present = new HashSet<>();
                for (Member member : o(value).members()) {
                    WireValue field = a(f(spec, "fields")).stream().filter(candidate -> s(f(candidate, "wire_name")).equals(member.key())).findFirst().orElse(null);
                    members.add(field == null || nil(member.value()) ? member : new Member(member.key(), defaults(index(f(f(field, "slot"), "type_ref")), member.value(), active)));
                    present.add(member.key());
                }
                for (WireValue field : a(f(spec, "fields"))) {
                    String name = s(f(field, "wire_name")); if (present.contains(name)) continue;
                    WireValue resolved = resolve(f(f(field, "slot"), "type_ref"));
                    if (resolved != null && Set.of("Boolean", "Integer", "String").contains(tag(resolved))) {
                        WireValue defaultValue = f(payload(resolved), "default_value");
                        if (!nil(defaultValue)) members.add(new Member(name, defaultValue));
                    }
                }
                result = new ObjectValue(members);
            } else if (kind.equals("TaggedUnion")) {
                for (WireValue branch : a(f(spec, "branches")))
                    if (selectorAccepts(f(branch, "selector"), s(f(branch, "wire_tag")), value))
                        result = defaults(index(f(branch, "target")), value, active);
            }
            active.remove(key); return result;
        }
    }

    private static final Set<String> NUMERIC_FIELDS = Set.of("first", "last", "minimum", "maximum", "min_length", "max_length", "max_chars", "min_labels", "label_max", "total_max", "min_segments", "segment_max", "authority_max", "exact_length", "max_bytes", "minimum_year", "maximum_year", "raw_codec", "state_count", "initial_state", "from_state", "to_state");
    private static final Set<String> NUMERIC_ARRAYS = Set.of("versions", "codecs", "hashes", "digest_lengths", "accepting_states");
    private static WireValue compileNumbers(WireValue value) {
        if (value instanceof ObjectValue object) {
            List<Member> members = new ArrayList<>(object.members().size());
            for (Member member : object.members()) {
                WireValue compiled;
                if (NUMERIC_FIELDS.contains(member.key()) && member.value() instanceof StringValue) compiled = num(n(member.value()));
                else if (NUMERIC_ARRAYS.contains(member.key()) && member.value() instanceof ArrayValue) compiled = arr(a(member.value()).stream().map(entry -> num(n(entry))).toList());
                else compiled = compileNumbers(member.value());
                members.add(new Member(member.key(), compiled));
            }
            return new ObjectValue(members);
        }
        if (value instanceof ArrayValue array) return arr(array.items().stream().map(SemanticValues::compileNumbers).toList());
        return value;
    }
    private static void collectNumbers(WireValue value, Map<String, BigInteger> numbers) {
        if (value instanceof StringValue string && string.value().matches("0|-?[1-9][0-9]*")) numbers.computeIfAbsent(string.value(), BigInteger::new);
        else if (value instanceof ObjectValue object) for (Member member : object.members()) collectNumbers(member.value(), numbers);
        else if (value instanceof ArrayValue array) for (WireValue item : array.items()) collectNumbers(item, numbers);
    }
    private static long utf8Length(String text) {
        long count = 0;
        for (int i = 0; i < text.length(); i++) { char c = text.charAt(i); if (c < 0x80) count++; else if (c < 0x800) count += 2; else if (Character.isHighSurrogate(c)) { count += 4; i++; } else count += 3; }
        return count;
    }
    static boolean bounds(long count, WireValue minimum, WireValue maximum) {
        BigInteger size = BigInteger.valueOf(count);
        return (nil(minimum) || size.compareTo(n(minimum)) >= 0) && (nil(maximum) || size.compareTo(n(maximum)) <= 0);
    }
    static boolean ascii(String text) { return text.codePoints().allMatch(c -> c < 128); }
    private static int scalarLength(String text) { return text.codePointCount(0, text.length()); }
    private static List<Integer> scalarOffsets(String text) {
        List<Integer> offsets = new ArrayList<>();
        for (int i = 0; i < text.length();) { offsets.add(i); i += Character.charCount(text.codePointAt(i)); }
        offsets.add(text.length()); return offsets;
    }
    private static boolean sequenceAccepts(List<WireValue> rules, String text, int index) {
        if (index == rules.size()) return text.isEmpty();
        for (int cut : scalarOffsets(text)) if (recognize(rules.get(index), text.substring(0, cut)) && sequenceAccepts(rules, text.substring(cut), index + 1)) return true;
        return false;
    }
    static boolean labels(String text, WireValue separator, WireValue minimum, WireValue maximum, WireValue totalMaximum, WireValue rule) {
        String delimiter = s(separator);
        if (delimiter.isEmpty()) return false;
        List<String> values = new ArrayList<>(); int start = 0;
        for (int found = text.indexOf(delimiter); found >= 0; found = text.indexOf(delimiter, start)) { values.add(text.substring(start, found)); start = found + delimiter.length(); }
        values.add(text.substring(start));
        if (values.size() < n(minimum).intValue() || !nil(maximum) && values.size() > n(maximum).intValue() || !nil(totalMaximum) && scalarLength(text) > n(totalMaximum).intValue()) return false;
        for (String value : values) if (!recognize(rule, value)) return false;
        return true;
    }
    static boolean recognize(WireValue rule, String text) {
        if (rule == null) return false;
        WireValue spec = o(rule).get("value"); if (spec == null) spec = o(rule).get("fields");
        switch (tag(rule)) {
            case "Literal": return s(spec).equals(text);
            case "Sequence": return sequenceAccepts(a(spec), text, 0);
            case "Optional": return text.isEmpty() || recognize(spec, text);
            case "Labels": return labels(text, f(spec, "separator"), f(spec, "min_count"), f(spec, "max_count"), f(spec, "total_max"), f(spec, "rule"));
            case "Bounded": {
                String unit = tag(f(spec, "unit"));
                int length = unit.equals("Utf8Bytes") ? text.getBytes(StandardCharsets.UTF_8).length : scalarLength(text);
                return length <= n(f(spec, "maximum")).intValue() && recognize(f(spec, "rule"), text);
            }
            case "Identifier": {
                if (!ascii(text) || text.isEmpty() || !bounds(text.length(), f(spec, "min_length"), f(spec, "max_length")) || !nil(f(spec, "exact_length")) && !BigInteger.valueOf(text.length()).equals(n(f(spec, "exact_length"))) || a(f(spec, "forbidden")).contains(str(text)) || !s(f(spec, "first_alphabet")).contains(text.substring(0, 1))) return false;
                String alphabet = s(f(spec, "rest_alphabet")); for (int i = 1; i < text.length(); i++) if (alphabet.indexOf(text.charAt(i)) < 0) return false;
                return true;
            }
            case "Timestamp": return timestamp(spec, text);
            case "AbsoluteUri": return absoluteUri(text, nil(f(spec, "max_bytes")) ? BigInteger.valueOf(Integer.MAX_VALUE) : n(f(spec, "max_bytes")));
            case "LanguageTag": return language(text, a(f(spec, "grandfathered")));
            case "Choice": { for (WireValue choice : a(spec)) if (recognize(choice, text)) return true; return false; }
            case "Text": return true;
            case "Not": return !recognize(spec, text);
            case "AsciiDfa": {
                if (!ascii(text)) return false;
                WireValue state = f(spec, "initial_state");
                for (int i = 0; i < text.length(); i++) {
                    WireValue next = null;
                    for (WireValue transition : a(f(spec, "transitions"))) if (f(transition, "from_state").equals(state) && text.charAt(i) >= n(f(transition, "first")).intValue() && text.charAt(i) <= n(f(transition, "last")).intValue()) { next = f(transition, "to_state"); break; }
                    if (next == null) return false; state = next;
                }
                return a(f(spec, "accepting_states")).contains(state);
            }
            default: return false;
        }
    }
    private static boolean uriComponent(String text, String punctuation) {
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == '%') {
                if (i + 2 >= text.length() || Character.digit(text.charAt(i + 1), 16) < 0 || Character.digit(text.charAt(i + 2), 16) < 0) return false;
                i += 2;
            } else if (!(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || "-._~!$&'()*+,;=".indexOf(c) >= 0 || punctuation.indexOf(c) >= 0)) return false;
        }
        return true;
    }
    private static boolean ipv6(String text) {
        if (text.isEmpty() || text.contains("%")) return false;
        int doubleColon = text.indexOf("::");
        if (doubleColon >= 0 && text.indexOf("::", doubleColon + 2) >= 0) return false;
        String[] halves = doubleColon < 0 ? new String[]{text} : new String[]{text.substring(0, doubleColon), text.substring(doubleColon + 2)};
        int words = 0;
        for (int h = 0; h < halves.length; h++) {
            if (halves[h].isEmpty()) { if (doubleColon < 0) return false; continue; }
            String[] parts = halves[h].split(":", -1);
            for (int i = 0; i < parts.length; i++) {
                String part = parts[i];
                if (part.indexOf('.') >= 0) {
                    if (h != halves.length - 1 || i != parts.length - 1) return false;
                    String[] octets = part.split("\\.", -1); if (octets.length != 4) return false;
                    for (String octet : octets) if (!octet.matches("0|[1-9][0-9]{0,2}") || Integer.parseInt(octet) > 255) return false;
                    words += 2;
                } else { if (!part.matches("[0-9A-Fa-f]{1,4}")) return false; words++; }
            }
        }
        return doubleColon < 0 ? words == 8 : words < 8;
    }
    private static boolean uriAuthority(String text) {
        int user = text.lastIndexOf('@');
        if (user >= 0) { if (!uriComponent(text.substring(0, user), ":")) return false; text = text.substring(user + 1); }
        if (text.startsWith("[")) {
            int close = text.indexOf(']'); if (close < 0) return false;
            String address = text.substring(1, close), port = text.substring(close + 1);
            if (!port.isEmpty() && (!port.startsWith(":") || !port.substring(1).matches("[0-9]*"))) return false;
            if (ipv6(address)) return true;
            if (!address.startsWith("v") && !address.startsWith("V")) return false;
            int dot = address.indexOf('.');
            return dot > 1 && address.substring(1, dot).matches("[0-9A-Fa-f]+") && dot + 1 < address.length() && address.substring(dot + 1).indexOf('%') < 0 && uriComponent(address.substring(dot + 1), ":");
        }
        int colon = text.lastIndexOf(':');
        if (colon >= 0) { if (!text.substring(colon + 1).matches("[0-9]*")) return false; text = text.substring(0, colon); }
        return uriComponent(text, "");
    }
    private static boolean absoluteUri(String text, BigInteger maximum) {
        if (!ascii(text) || BigInteger.valueOf(text.length()).compareTo(maximum) > 0) return false;
        int colon = text.indexOf(':'); if (colon < 1 || !text.substring(0, colon).matches("[A-Za-z][A-Za-z0-9+.-]*")) return false;
        String rest = text.substring(colon + 1); int fragment = rest.indexOf('#');
        if (fragment >= 0) { if (!uriComponent(rest.substring(fragment + 1), ":@/?")) return false; rest = rest.substring(0, fragment); }
        int query = rest.indexOf('?');
        if (query >= 0) { if (!uriComponent(rest.substring(query + 1), ":@/?")) return false; rest = rest.substring(0, query); }
        if (rest.startsWith("//")) {
            int slash = rest.indexOf('/', 2); String authority = slash < 0 ? rest.substring(2) : rest.substring(2, slash);
            if (!uriAuthority(authority)) return false; rest = slash < 0 ? "" : rest.substring(slash);
        }
        return uriComponent(rest, ":@/");
    }
    static boolean timestamp(WireValue rule, String text) {
        if (!text.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})")) return false;
        int year = Integer.parseInt(text.substring(0, 4)), month = Integer.parseInt(text.substring(5, 7)), day = Integer.parseInt(text.substring(8, 10));
        int hour = Integer.parseInt(text.substring(11, 13)), minute = Integer.parseInt(text.substring(14, 16)), second = Integer.parseInt(text.substring(17, 19));
        if (!bounds(year, f(rule, "minimum_year"), f(rule, "maximum_year")) || hour > 23 || minute > 59 || second > (b(f(rule, "allow_second_60")) ? 60 : 59)) return false;
        try { LocalDate date = LocalDate.of(year, month, day); if (text.endsWith("Z")) return true;
            String zone = text.substring(text.length() - 6); int zh = Integer.parseInt(zone.substring(1, 3)), zm = Integer.parseInt(zone.substring(4, 6));
            if (zh > 23 || zm > 59 || zone.equals("-00:00")) return false;
            if (b(f(rule, "rejectUtcYearOutsideRange"))) {
                long utc = date.toEpochDay() * 1440L + hour * 60L + minute - (zone.startsWith("+") ? 1 : -1) * (zh * 60 + zm);
                return utc >= LocalDate.of(n(f(rule, "minimum_year")).intValueExact(), 1, 1).toEpochDay() * 1440L && utc < LocalDate.of(n(f(rule, "maximum_year")).intValueExact() + 1, 1, 1).toEpochDay() * 1440L;
            }
            return true;
        } catch (DateTimeException error) { return false; }
    }
    static boolean language(String text, List<WireValue> grandfathered) {
        if (!ascii(text) || text.isEmpty()) return false;
        for (WireValue value : grandfathered) if (s(value).equalsIgnoreCase(text)) return true;
        String[] parts = text.split("-", -1); int i = 0;
        if (parts[0].equalsIgnoreCase("x")) { if (parts.length < 2) return false; for (i = 1; i < parts.length; i++) if (!parts[i].matches("[A-Za-z0-9]{1,8}")) return false; return true; }
        if (!parts[0].matches("[A-Za-z]{2,8}")) return false;
        i = 1;
        if (parts[0].length() <= 3) for (int count = 0; count < 3 && i < parts.length && parts[i].matches("[A-Za-z]{3}"); count++) i++;
        if (i < parts.length && parts[i].matches("[A-Za-z]{4}")) i++;
        if (i < parts.length && parts[i].matches("[A-Za-z]{2}|[0-9]{3}")) i++;
        Set<String> variants = new HashSet<>(), extensions = new HashSet<>();
        while (i < parts.length && parts[i].matches("[A-Za-z0-9]{5,8}|[0-9][A-Za-z0-9]{3}")) if (!variants.add(parts[i++].toLowerCase(java.util.Locale.ROOT))) return false;
        while (i < parts.length && parts[i].matches("[A-WY-Za-wy-z0-9]")) {
            if (!extensions.add(parts[i++].toLowerCase(java.util.Locale.ROOT))) return false;
            int start = i; while (i < parts.length && parts[i].matches("[A-Za-z0-9]{2,8}")) i++; if (start == i) return false;
        }
        if (i < parts.length && parts[i].equalsIgnoreCase("x")) { int start = ++i; while (i < parts.length && parts[i].matches("[A-Za-z0-9]{1,8}")) i++; if (start == i) return false; }
        return i == parts.length;
    }
    private static WireValue range(List<WireValue> rows, int point) {
        int low = 0, high = rows.size();
        while (low < high) { int middle = (low + high) >>> 1; if (n(f(rows.get(middle), "first")).intValue() <= point) low = middle + 1; else high = middle; }
        return low > 0 && n(f(rows.get(low - 1), "last")).intValue() >= point ? rows.get(low - 1) : null;
    }
    public record GraphemeComponent(String unicodeVersion, String uax29Revision, String clusterProfile) {}
    public record SourceRef(String repository, String revision, String path, String sha256) {}
    public record GraphemeSource(String role, SourceRef source) {}
    public static final class GraphemeRules {
        private final WireValue value;
        private final GraphemeComponent component;
        private final String tableSha256;
        private final List<GraphemeSource> sources;
        private GraphemeRules(WireValue value) {
            this.value = value;
            WireValue component = f(value, "component");
            this.component = new GraphemeComponent(s(f(component, "unicode_version")), s(f(component, "uax29_revision")), s(f(component, "cluster_profile")));
            this.tableSha256 = s(f(value, "table_sha256"));
            this.sources = a(f(value, "sources")).stream().map(row -> {
                WireValue source = f(row, "source");
                return new GraphemeSource(s(f(row, "role")), new SourceRef(s(f(source, "repository")), s(f(source, "revision")), s(f(source, "path")), s(f(source, "content_digest"))));
            }).toList();
        }
        public GraphemeComponent component() { return component; }
        public String tableSha256() { return tableSha256; }
        public List<GraphemeSource> sources() { return sources; }
    }
    /** Counts default extended grapheme clusters under the verified rules. */
    public static int graphemeCount(GraphemeRules rules, String text) { return graphemeCount(rules.value, text); }
    private static int graphemeCount(WireValue rules, String text) { return segmentGraphemes(rules, text, null); }
    /** Returns code point offsets, including both ends for nonempty input. */
    public static List<Integer> graphemeBoundaries(GraphemeRules rules, String text) {
        List<Integer> boundaries = new ArrayList<>();
        segmentGraphemes(rules.value, text, boundaries);
        return List.copyOf(boundaries);
    }
    private static int segmentGraphemes(WireValue rules, String text, List<Integer> boundaries) {
        List<WireValue> properties = a(f(rules, "properties")), emoji = a(f(rules, "extended_pictographic")), indic = a(f(rules, "indic_conjunct"));
        String previous = null; int regionalRun = 0, points = 0, count = 0; boolean epExtend = false, zwjAfterEp = false, consonant = false, linker = false;
        for (int offset = 0; offset < text.length();) {
            int point = text.codePointAt(offset); offset += Character.charCount(point);
            WireValue gr = range(properties, point), ir = range(indic, point); String property = gr == null ? "Other" : tag(f(gr, "property")), incb = ir == null ? "Other" : tag(f(ir, "property")); boolean pictographic = range(emoji, point) != null;
            boolean breaks;
            if (previous == null) breaks = true;
            else if (previous.equals("Cr") && property.equals("Lf")) breaks = false;
            else if (Set.of("Cr", "Lf", "Control").contains(previous) || Set.of("Cr", "Lf", "Control").contains(property)) breaks = true;
            else if (previous.equals("L") && Set.of("L", "V", "Lv", "Lvt").contains(property) || Set.of("Lv", "V").contains(previous) && Set.of("V", "T").contains(property) || Set.of("Lvt", "T").contains(previous) && property.equals("T")) breaks = false;
            else if (Set.of("Extend", "Zwj", "SpacingMark").contains(property) || previous.equals("Prepend") || incb.equals("Consonant") && consonant && linker || previous.equals("Zwj") && pictographic && zwjAfterEp || previous.equals("RegionalIndicator") && property.equals("RegionalIndicator") && regionalRun % 2 == 1) breaks = false;
            else breaks = true;
            if (breaks) { count++; if (boundaries != null) boundaries.add(points); }
            points++;
            zwjAfterEp = property.equals("Zwj") && epExtend;
            epExtend = pictographic || property.equals("Extend") && epExtend;
            if (incb.equals("Consonant")) { consonant = true; linker = false; }
            else if (incb.equals("Linker") && consonant) linker = true;
            else if (incb.equals("Other")) { consonant = false; linker = false; }
            regionalRun = property.equals("RegionalIndicator") ? previous != null && previous.equals("RegionalIndicator") ? regionalRun + 1 : 1 : 0;
            previous = property;
        }
        if (points > 0 && boundaries != null) boundaries.add(points);
        return count;
    }

    public interface HostAdapter {
        JavaHttpAdapter.StartResult start(NetworkEffect.SendCommand command);
        JavaHttpAdapter.PollResult observe(NetworkEffect.StartedAttempt started);
        static HostAdapter javaHttp(JavaHttpAdapter adapter) {
            Objects.requireNonNull(adapter);
            return new HostAdapter() {
                public JavaHttpAdapter.StartResult start(NetworkEffect.SendCommand command) { return adapter.start(command); }
                public JavaHttpAdapter.PollResult observe(NetworkEffect.StartedAttempt started) { return adapter.observe(started); }
            };
        }
    }
    @FunctionalInterface public interface OwnerEncoder<I> { NetworkEffect.AttemptInput encode(I input) throws Exception; }
    @FunctionalInterface public interface OwnerDecoder<O> { O decode(NetworkEffect.SettledAttempt settled) throws Exception; }
    public sealed interface HttpFailure permits LedgerFailure, OwnerFailure, AdapterFailure, UnexpectedObservation, ClosedContinuation {}
    public record LedgerFailure(NetworkEffect.NetworkFailure failure) implements HttpFailure {}
    public record OwnerFailure(Exception cause) implements HttpFailure {}
    public record AdapterFailure(RuntimeException cause) implements HttpFailure {}
    public record UnexpectedObservation(NetworkEffect.NetworkStep observation) implements HttpFailure {}
    public record ClosedContinuation() implements HttpFailure {}
    public sealed interface HttpResult<O> permits HttpCompleted, HttpPending, HttpRejected {}
    public record HttpCompleted<O>(NetworkEffect.NetworkState state, NetworkEffect.SettledAttempt settled, O outcome) implements HttpResult<O> {}
    public record HttpPending<O>(HttpContinuation<O> continuation) implements HttpResult<O> {}
    public record HttpRejected<O>(NetworkEffect.NetworkState state, HttpFailure failure, boolean commandIssued) implements HttpResult<O> {}
    private static NetworkEffect.HostObservation hostObservation(JavaHttpAdapter.PollResult result) {
        return switch (result) {
            case JavaHttpAdapter.PollResult.Pending pending -> pending.observation();
            case JavaHttpAdapter.PollResult.Delivered delivered -> delivered.observation();
            case JavaHttpAdapter.PollResult.Closed closed -> closed.observation();
        };
    }
    public static final class HttpContinuation<O> {
        private NetworkEffect.NetworkState state;
        private final NetworkEffect.StartedAttempt started;
        private final HostAdapter adapter;
        private final OwnerDecoder<O> decoder;
        private boolean completed;
        private HttpContinuation(NetworkEffect.NetworkState state, NetworkEffect.StartedAttempt started, HostAdapter adapter, OwnerDecoder<O> decoder) {
            this.state = state; this.started = started; this.adapter = adapter; this.decoder = decoder;
        }
        public NetworkEffect.NetworkState state() { return state; }
        public NetworkEffect.StartedAttempt started() { return started; }
        public synchronized HttpResult<O> resume() {
            if (completed) return new HttpRejected<>(state, new ClosedContinuation(), true);
            NetworkEffect.NetworkStep step;
            try { step = NetworkEffect.observe(state, hostObservation(adapter.observe(started))); }
            catch (RuntimeException error) { return new HttpRejected<>(state, new AdapterFailure(error), true); }
            if (step instanceof NetworkEffect.NetworkStep.Pending pending) { state = pending.state(); return new HttpPending<>(this); }
            if (step instanceof NetworkEffect.NetworkStep.Terminal terminal) {
                state = terminal.state(); completed = true;
                try { return new HttpCompleted<>(state, terminal.settled(), decoder.decode(terminal.settled())); }
                catch (Exception error) { return new HttpRejected<>(state, new OwnerFailure(error), true); }
            }
            if (step instanceof NetworkEffect.NetworkStep.Rejected rejected) { state = rejected.state(); return new HttpRejected<>(state, new LedgerFailure(rejected.failure()), true); }
            if (step instanceof NetworkEffect.NetworkStep.Late late) state = late.state();
            if (step instanceof NetworkEffect.NetworkStep.Duplicate duplicate) state = duplicate.state();
            return new HttpRejected<>(state, new UnexpectedObservation(step), true);
        }
    }
    public static <I, O> HttpResult<O> startHttp(NetworkEffect.NetworkState state, I input,
            OwnerEncoder<I> encoder, OwnerDecoder<O> decoder, HostAdapter adapter) {
        NetworkEffect.AttemptInput instruction;
        try { instruction = encoder.encode(input); } catch (Exception error) { return new HttpRejected<>(state, new OwnerFailure(error), false); }
        NetworkEffect.PrepareStep preparedStep = NetworkEffect.prepare(state, instruction);
        if (preparedStep instanceof NetworkEffect.PrepareStep.Rejected rejected) return new HttpRejected<>(rejected.state(), new LedgerFailure(rejected.failure()), false);
        NetworkEffect.PrepareStep.Prepared prepared = (NetworkEffect.PrepareStep.Prepared) preparedStep;
        NetworkEffect.CommandStep<NetworkEffect.SendCommand> commandStep = NetworkEffect.sendCommand(prepared.state(), prepared.prepared());
        if (commandStep instanceof NetworkEffect.CommandStep.Rejected<NetworkEffect.SendCommand> rejected) return new HttpRejected<>(rejected.state(), new LedgerFailure(rejected.failure()), false);
        NetworkEffect.CommandStep.CommandReady<NetworkEffect.SendCommand> command = (NetworkEffect.CommandStep.CommandReady<NetworkEffect.SendCommand>) commandStep;
        JavaHttpAdapter.StartResult start;
        try { start = adapter.start(command.command()); } catch (RuntimeException error) { return new HttpRejected<>(command.state(), new AdapterFailure(error), true); }
        NetworkEffect.NetworkStep observed = NetworkEffect.observeStart(command.state(), prepared.prepared(), start.observation());
        if (observed instanceof NetworkEffect.NetworkStep.Rejected rejected) return new HttpRejected<>(rejected.state(), new LedgerFailure(rejected.failure()), true);
        if (observed instanceof NetworkEffect.NetworkStep.Terminal terminal) {
            try { return new HttpCompleted<>(terminal.state(), terminal.settled(), decoder.decode(terminal.settled())); }
            catch (Exception error) { return new HttpRejected<>(terminal.state(), new OwnerFailure(error), true); }
        }
        if (observed instanceof NetworkEffect.NetworkStep.Started started) return new HttpPending<>(new HttpContinuation<>(started.state(), started.started(), adapter, decoder));
        return new HttpRejected<>(command.state(), new UnexpectedObservation(observed), true);
    }
}
