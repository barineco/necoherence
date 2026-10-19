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
        private final List<WireValue> path;
        private final WireValue typeRef;
        private final WireValue origin;
        private final List<WireValue> referenceTrace;
        private final String condition;
        private final WireValue observed;
        private final List<WireValue> obligations;
        public ValueFailure(WireValue typeRef, List<WireValue> path, String condition) {
            this(typeRef, path, condition, List.of(), null, List.of());
        }
        private ValueFailure(WireValue typeRef, List<WireValue> path, String condition,
                List<WireValue> referenceTrace, WireValue observed) {
            this(typeRef, path, condition, referenceTrace, observed, List.of());
        }
        private ValueFailure(WireValue typeRef, List<WireValue> path, String condition,
                List<WireValue> referenceTrace, WireValue observed, List<WireValue> obligations) {
            super(encodeWire(typeRef) + " " + path + ": " + condition);
            this.path = List.copyOf(path); this.condition = condition; this.typeRef = typeRef;
            this.origin = obj("source", f(typeRef, "source"), "pointer", f(typeRef, "pointer"));
            this.referenceTrace = List.copyOf(referenceTrace); this.observed = observed;
            this.obligations = List.copyOf(obligations);
        }
        public String definition() { return s(f(typeRef, "definition_name")); }
        public List<WireValue> path() { return path; }
        public String condition() { return condition; }
        public WireValue observed() { return observed; }
        public WireValue typeRef() { return typeRef; }
        public WireValue origin() { return origin; }
        public List<WireValue> referenceTrace() { return referenceTrace; }
        public List<WireValue> obligations() { return obligations; }
        private static ValueFailure unresolved(List<WireValue> obligations) {
            WireValue first = obligations.getFirst();
            return new ValueFailure(f(first, "type_ref"), a(f(first, "value_path")), "Unresolved", List.of(), null, obligations);
        }
    }

    public record DefaultApplication(List<WireValue> valuePath, WireValue typeRef, WireValue origin, WireValue value) {
        public DefaultApplication { valuePath = List.copyOf(valuePath); }
    }
    public static final class DefaultedValue {
        private final WireValue value;
        private final List<DefaultApplication> applications;
        private DefaultedValue(WireValue value, List<DefaultApplication> applications) {
            this.value = value; this.applications = List.copyOf(applications);
        }
        public WireValue value() { return value; }
        public List<DefaultApplication> applications() { return applications; }
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
    public static ObjectValue orderedObject(List<Member> members, List<String> memberOrder) {
        List<Member> ordered = new ArrayList<>();
        memberOrder.stream().distinct().forEach(key -> members.stream().filter(member -> member.key().equals(key)).forEach(ordered::add));
        members.stream().filter(member -> !memberOrder.contains(member.key())).forEach(ordered::add);
        return new ObjectValue(ordered);
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
        public Context(WireValue graph) {
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
        private List<WireValue> nodeMeaningReasons(WireValue reference) {
            Integer type = indices.get(reference);
            if (type == null) return List.of(variant("UnresolvedType"));
            WireValue shape = shape(type);
            WireValue spec = o(shape).get("value") == null ? o(shape).get("fields") : o(shape).get("value");
            String kind = tag(shape);
            List<WireValue> reasons = new ArrayList<>();
            if (kind.equals("String")) {
                if (a(f(spec, "lengths")).stream().anyMatch(bound -> tag(f(bound, "unit")).equals("Graphemes")) && nil(graphemeRules)) reasons.add(variant("MissingGraphemeRules"));
                WireValue use = f(spec, "format");
                if (!nil(use) && tag(use).equals("Named") && !formats.containsKey(s(payload(use)))) reasons.add(variant("UnknownFormat", payload(use)));
                if (!nil(f(spec, "wrapper"))) {
                    WireValue name = f(spec, "wrapper"), wrapper = namedWrapper(s(name));
                    if (wrapper == null) reasons.add(variant("UnknownWrapper", name));
                    else if (!tag(f(wrapper, "payload")).equals("Text")) reasons.add(variant("WrapperPayload", name));
                }
            } else if (kind.equals("Integer")) {
                WireValue name = nil(f(spec, "domain")) ? f(profile, "default_integer_domain") : f(spec, "domain");
                if (integerBinding(spec) == null) reasons.add(variant("UnknownIntegerDomain", name));
                else if (!integerBoundsInsideDomain(spec)) reasons.add(variant("IntegerBound"));
            } else if (kind.equals("Decimal") && !b(f(f(profile, "numbers"), "decimals"))) reasons.add(variant("DecimalNotAdmitted"));
            else if ((kind.equals("Bytes") || kind.equals("RawBody")) && nil(f(profile, "bytes_policy"))) reasons.add(variant("MissingBytesPolicy"));
            else if (kind.equals("Sealed") && (nil(tagModel()) || a(f(tagModel(), "sealed")).stream().noneMatch(form -> f(form, "tag").equals(f(spec, "tag"))))) reasons.add(variant("UnknownSealedTag", f(spec, "tag")));
            else if (kind.equals("TaggedUnion") && nil(tagModel()) && a(f(spec, "branches")).stream().anyMatch(branch -> tag(f(branch, "selector")).equals("InternalTag"))) reasons.add(variant("MissingTagModel"));
            else if (kind.equals("Opaque")) reasons.add(variant("OpaqueType", f(spec, "type_name")));
            return reasons;
        }
        public List<WireValue> meaningObligations(WireValue reference) {
            List<WireValue> pending = new ArrayList<>(List.of(reference)), reachable = new ArrayList<>();
            Set<WireValue> seen = new HashSet<>();
            int edges = nodes.stream().mapToInt(node -> children(f(node, "shape")).size()).sum();
            for (int fuel = 1 + nodes.size() + edges + 1; fuel > 0 && !pending.isEmpty(); fuel--) {
                WireValue current = pending.removeFirst();
                if (!seen.add(current)) continue;
                reachable.addFirst(current);
                Integer type = indices.get(current);
                if (type != null) pending.addAll(0, children(shape(type)));
            }
            List<WireValue> obligations = new ArrayList<>();
            for (WireValue current : reachable) for (WireValue reason : nodeMeaningReasons(current)) obligations.add(obj(
                    "type_ref", current, "origin", obj("source", f(current, "source"), "pointer", f(current, "pointer")),
                    "value_path", arr(List.of()), "profile", f(profile, "reference"), "reason", reason));
            return List.copyOf(obligations);
        }
        synchronized void meaning(int index) throws ValueFailure {
            if (meaningful.contains(index)) return;
            for (WireValue obligation : meaningObligations(reference(index))) {
                String predicate = switch (tag(f(obligation, "reason"))) {
                    case "UnknownFormat" -> "MO01"; case "MissingGraphemeRules" -> "MO02";
                    case "MissingBytesPolicy" -> "MO03"; case "UnknownIntegerDomain" -> "MO04";
                    case "UnknownWrapper" -> "MO05"; case "WrapperPayload" -> "MO06";
                    case "UnknownSealedTag" -> "MO07"; case "DecimalNotAdmitted" -> "MO08";
                    case "IntegerBound" -> "MO09"; case "OpaqueType" -> "MO10"; case "MissingTagModel" -> "MO11";
                    default -> null;
                };
                if (predicate != null) fail(this.index(f(obligation, "type_ref")), List.of(), predicate);
            }
            meaningful.add(index);
        }
        private void checkedMaterializationValue(WireValue reference, WireValue value) throws ValueFailure {
            List<WireValue> obligations = meaningObligations(reference);
            if (!obligations.isEmpty()) throw ValueFailure.unresolved(obligations);
            validate(reference, value);
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
        public WireValue decode(WireValue reference, String text) throws ValueFailure {
            WireValue value;
            try { value = SemanticGeneration.readJson(text); }
            catch (RuntimeException error) { throw new ValueFailure(reference, List.of(), "InvalidJson: " + error.getMessage()); }
            validate(reference, value); return value;
        }
        public DefaultedValue decodeWithDefaults(WireValue reference, String text) throws ValueFailure {
            WireValue value;
            try { value = SemanticGeneration.readJson(text); }
            catch (RuntimeException error) { throw new ValueFailure(reference, List.of(), "InvalidJson: " + error.getMessage()); }
            String duplicate = duplicateWireMember(value);
            if (duplicate != null) throw new ValueFailure(reference, List.of(), "InvalidJson: DuplicateField:" + duplicate);
            return materializeDefaults(reference, value);
        }
        private String duplicateWireMember(WireValue value) {
            if (value instanceof ObjectValue object) {
                Set<String> keys = new HashSet<>();
                for (Member member : object.members()) if (!keys.add(member.key())) return member.key();
                for (Member member : object.members()) {
                    String duplicate = duplicateWireMember(member.value());
                    if (duplicate != null) return duplicate;
                }
            } else if (value instanceof ArrayValue array) {
                for (WireValue item : array.items()) {
                    String duplicate = duplicateWireMember(item);
                    if (duplicate != null) return duplicate;
                }
            }
            return null;
        }
        public void validate(WireValue reference, WireValue value) throws ValueFailure {
            Integer type = indices.get(reference);
            if (type == null) throw new ValueFailure(reference, List.of(), "UnresolvedType");
            validateIndex(type, value);
        }
        private void validateIndex(int type, WireValue value) throws ValueFailure {
            if (value == null) fail(type, List.of(), "NullNotAllowed");
            meaning(type); List<Active> active = new ArrayList<>(), previous = activeProof.get(); activeProof.set(active);
            try { evaluate(type, value, new ArrayList<>(), active); } finally { if (previous == null) activeProof.remove(); else activeProof.set(previous); }
        }
        void validateDeclaredDefault(int type, WireValue value) throws ValueFailure {
            validateIndex(type, value);
        }
        public Bytes decodeBytes(WireValue reference, WireValue value) throws ValueFailure {
            validate(reference, value);
            String encoding = bytesText(value);
            return new Bytes(decodeBase64(encoding), encoding);
        }
        public WireValue encodeBytes(Bytes value) {
            String text = value.base64();
            WireValue policy = f(profile, "bytes_policy");
            if (!nil(f(policy, "wrapper"))) return wrapEncode(profile, s(f(policy, "wrapper")), text);
            return str(text);
        }
        public String decodeText(WireValue reference, WireValue value) {
            WireValue spec = payload(shape(index(reference)));
            return nil(f(spec, "wrapper")) ? s(value) : wrapDecode(profile, s(f(spec, "wrapper")), value);
        }
        public WireValue encodeText(WireValue reference, String value) {
            WireValue spec = payload(shape(index(reference)));
            return nil(f(spec, "wrapper")) ? str(value) : wrapEncode(profile, s(f(spec, "wrapper")), value);
        }
        public int selectBranch(WireValue reference, WireValue value) {
            WireValue shape = resolve(reference);
            if (shape == null || !tag(shape).equals("TaggedUnion")) return -1;
            List<WireValue> branches = a(f(payload(shape), "branches"));
            for (int index = 0; index < branches.size(); index++)
                if (selectorAccepts(f(branches.get(index), "selector"), s(f(branches.get(index), "wire_tag")), value)) return index;
            return -1;
        }
        public void validateSlot(WireValue reference, boolean required, boolean nullable, Slot<WireValue> value) throws ValueFailure {
            Integer type = indices.get(reference);
            if (type == null) throw new ValueFailure(reference, List.of(), "UnresolvedType");
            if (value == null) fail(type, List.of(), "NullNotAllowed");
            List<Active> active = new ArrayList<>(), previous = activeProof.get(); activeProof.set(active);
            try { validateSlot(type, required, nullable, value, new ArrayList<>(), active); } finally { if (previous == null) activeProof.remove(); else activeProof.set(previous); }
        }
        public void validateContract(WireValue contract, Slot<WireValue> value) throws ValueFailure {
            validateSlot(f(contract, "type_ref"), b(f(contract, "required")), b(f(contract, "nullable")), value);
        }
        private void validateSlot(int type, boolean required, boolean nullable, Slot<WireValue> value,
                List<WireValue> path, List<Active> active) throws ValueFailure {
            meaning(type);
            switch (value) {
                case Absent<WireValue> unused -> { if (required) fail(type, path, "MissingRequired"); }
                case NullSlot<WireValue> unused -> { if (!nullable) fail(type, path, "NullNotAllowed"); }
                case Present<WireValue> present -> evaluate(type, present.value(), path, active);
            }
        }
        private void validateElement(int type, boolean nullable, WireValue value,
                List<WireValue> path, List<Active> active) throws ValueFailure {
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
            WireValue ref = reference(type); return s(f(ref, "definition_name"));
        }
        private void fail(int type, List<WireValue> path, String condition) throws ValueFailure {
            List<Active> active = activeProof.get();
            List<WireValue> trace = active == null ? List.of() : active.stream()
                    .limit(Math.max(0, active.size() - 1)).map(entry -> reference(entry.type())).toList();
            WireValue observed = active == null || active.isEmpty() ? shape(type) : active.getFirst().value();
            for (WireValue step : path) {
                if (tag(step).equals("Field") && observed instanceof ObjectValue object) observed = object.get(s(payload(step)));
                else if (tag(step).equals("Index") && observed instanceof ArrayValue array) observed = array.items().get(n(payload(step)).intValue());
                else { observed = null; break; }
            }
            throw new ValueFailure(reference(type), path, condition, trace, observed);
        }
        private void evaluate(int type, WireValue value, List<WireValue> path, List<Active> active) throws ValueFailure {
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
                        String text;
                        if (nil(f(spec, "wrapper"))) {
                            if (!(value instanceof StringValue)) fail(type, path, "WrongValueKind: string");
                            text = s(value);
                        } else {
                            WireValue wrapper = value instanceof ObjectValue object && classOf(object).equals("Wrapper")
                                    ? objectWrapper(object) : null;
                            if (wrapper == null || !f(wrapper, "name").equals(f(spec, "wrapper")))
                                fail(type, path, "WrongValueKind: string wrapper");
                            text = checkedWrapperText(type, wrapper, value, path);
                        }
                        validateString(type, spec, text, path);
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
                            path.add(variant("Index", str(Integer.toString(i))));
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
        private void checkDecimalBound(int type, List<WireValue> path, java.math.BigDecimal number,
                WireValue encoded, boolean minimum) throws ValueFailure {
            if (nil(encoded)) return;
            BigInteger mantissa = n(f(encoded, "mantissa")); int scale = n(f(encoded, "scale")).intValueExact();
            java.math.BigDecimal bound = new java.math.BigDecimal(mantissa, scale);
            int order = number.compareTo(bound); boolean exclusive = b(f(encoded, "exclusive"));
            if (minimum ? order < 0 || exclusive && order == 0 : order > 0 || exclusive && order == 0)
                fail(type, path, minimum ? "BelowMinimum" : "AboveMaximum");
        }
        private void objectMembers(int type, ObjectValue object, List<WireValue> path) throws ValueFailure {
            Set<String> seen = new HashSet<>();
            for (Member member : object.members())
                if (!seen.add(member.key())) fail(type, path, "DuplicateField: " + member.key());
            if (nil(tagModel())) return;
            WireValue value = object.get(tagKey());
            if (value == null) return;
            path.add(variant("Field", str(tagKey())));
            if (value instanceof StringValue text) {
                if (!unicodeValid(text.value())) fail(type, path, "InvalidDataModel");
                if (!tagTextAccepted(text.value())) fail(type, path, "InvalidTag");
            } else {
                fail(type, path, "InvalidTag");
            }
            path.remove(path.size() - 1);
        }
        private void product(int type, WireValue value, WireValue spec, List<WireValue> path, List<Active> active) throws ValueFailure {
            if (!(value instanceof ObjectValue)) fail(type, path, "WrongValueKind: object");
            ObjectValue object = (ObjectValue) value;
            objectMembers(type, object, path);
            if(!classOf(object).equals("Ordinary"))fail(type,path,"ReservedForm");
            Set<String> known = new HashSet<>();
            for (WireValue field : a(f(spec, "fields"))) {
                String name = s(f(field, "wire_name")); known.add(name); WireValue contract = f(field, "slot");
                path.add(variant("Field", str(name))); validateSlot(index(f(contract, "type_ref")), b(f(contract, "required")),
                        b(f(contract, "nullable")), slot(object.get(name)), path, active); path.remove(path.size() - 1);
            }
            WireValue extras = f(spec, "extras");
            for (Member member : object.members()) {
                if (known.contains(member.key()) || !nil(tagModel()) && member.key().equals(tagKey())) continue;
                path.add(variant("Field", str(member.key())));
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
            return objectWrapper(value) == null ? "Ordinary" : "Wrapper";
        }
        private WireValue objectWrapper(ObjectValue value) {
            return a(f(profile, "wrappers")).stream()
                    .filter(wrapper -> value.get(s(f(wrapper, "key"))) != null).findFirst().orElse(null);
        }
        private String wrapperPayloadText(WireValue wrapper, WireValue value) {
            if (!(value instanceof ObjectValue object) || object.members().size() != 1
                    || !(object.get(s(f(wrapper, "key"))) instanceof StringValue text)) return null;
            WireValue payload = f(wrapper, "payload");
            if (tag(payload).equals("Bytes"))
                return decodeBase64(text.value()) == null ? null : text.value();
            WireValue format = SemanticValues.payload(payload);
            return unicodeValid(text.value()) && (nil(format) || recognize(formats.get(s(format)), text.value()))
                    ? text.value() : null;
        }
        private String checkedWrapperText(int type, WireValue wrapper, WireValue value, List<WireValue> path)
                throws ValueFailure {
            String text = wrapperPayloadText(wrapper, value);
            if (text != null) return text;
            WireValue payload = f(wrapper, "payload");
            if (tag(payload).equals("Bytes")) fail(type, path, "InvalidBytes");
            WireValue format = SemanticValues.payload(payload);
            fail(type, path, nil(format) ? "WrongValueKind: wrapper text" : "Format: " + s(format));
            return null;
        }
        private void validateString(int type, WireValue spec, String text, List<WireValue> path) throws ValueFailure {
            if (!unicodeValid(text)) fail(type, path, "InvalidDataModel");
            WireValue actual = str(text);
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
        private void sealed(int type, WireValue value, WireValue spec, List<WireValue> path, List<Active> active) throws ValueFailure {
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
                path.add(variant("Field", str(key)));
                if (member == null && b(f(field, "required"))) fail(type, path, "MissingRequired");
                if (member != null) sealedLeaf(type, member, f(field, "leaf"), path, active);
                path.remove(path.size() - 1);
            }
            for (WireValue refinement : a(f(spec, "refinements"))) {
                String key = s(f(refinement, "key")); WireValue member = object.get(key);
                if (member != null) { path.add(variant("Field", str(key))); sealedLeaf(type, member, f(refinement, "leaf"), path, active); path.remove(path.size() - 1); }
            }
            for (Member member : object.members()) if (!known.contains(member.key())) {
                path.add(variant("Field", str(member.key())));
                if (tag(f(form, "extras")).equals("Reject")) fail(type, path, "UnexpectedField: " + member.key());
                data(type, member.value(), path, active); path.remove(path.size() - 1);
            }
        }
        private void sealedLeaf(int type, WireValue value, WireValue leaf, List<WireValue> path, List<Active> active) throws ValueFailure {
            String kind = tag(leaf); WireValue spec = payload(leaf);
            if (kind.equals("String")) {
                String text;
                if (value instanceof StringValue raw) {
                    text = raw.value();
                } else if (value instanceof ObjectValue object && classOf(object).equals("Wrapper")) {
                    text = checkedWrapperText(type, objectWrapper(object), value, path);
                } else {
                    fail(type, path, "WrongValueKind: string");
                    return;
                }
                validateString(type, spec, text, path);
            } else {
                BigInteger number = integerValue(spec, value);
                if (number == null) fail(type, path, "WrongValueKind: integer");
                if (!integerInDomain(spec, number)) fail(type, path, "IntegerDomain");
            }
        }
        private boolean decimalCoefficientIsZero(String text) {
            String coefficient = text.split("[eE]", 2)[0];
            for (int index = 0; index < coefficient.length(); index++) {
                char character = coefficient.charAt(index);
                if (character >= '1' && character <= '9') return false;
            }
            return true;
        }
        private boolean decimalExponentIsPositive(String text) {
            int separator = Math.max(text.indexOf('e'), text.indexOf('E'));
            return separator >= 0 && !text.substring(separator + 1).startsWith("-");
        }
        private void data(int type, WireValue value, List<WireValue> path, List<Active> active) throws ValueFailure {
            if (value instanceof DecimalValue decimal) {
                WireValue spec = obj("domain", NIL, "minimum", NIL, "maximum", NIL,
                        "const_value", NIL, "enum_values", NIL, "default_value", NIL);
                WireValue binding = integerBinding(spec);
                boolean integralForm = binding != null && a(f(binding, "forms")).stream()
                        .anyMatch(form -> tag(form).equals("IntegralDecimal"));
                if (integralForm) {
                    try {
                        java.math.BigDecimal number = new java.math.BigDecimal(decimal.text());
                        if (number.stripTrailingZeros().scale() <= 0) {
                            WireValue range = f(binding, "range");
                            if (tag(range).equals("Inclusive")) {
                                WireValue bounds = payload(range);
                                java.math.BigDecimal minimum = new java.math.BigDecimal(n(f(bounds, "minimum")));
                                java.math.BigDecimal maximum = new java.math.BigDecimal(n(f(bounds, "maximum")));
                                if (number.compareTo(minimum) < 0 || number.compareTo(maximum) > 0)
                                    fail(type, path, "IntegerDomain");
                            }
                            return;
                        }
                    } catch (NumberFormatException error) {
                        if (decimalCoefficientIsZero(decimal.text())) {
                            if (!integerInDomain(spec, BigInteger.ZERO)) fail(type, path, "IntegerDomain");
                            return;
                        }
                        if (decimalExponentIsPositive(decimal.text())) {
                            if (tag(f(binding, "range")).equals("Unbounded")) return;
                            fail(type, path, "IntegerDomain");
                        }
                    }
                }
                if (!b(f(f(profile, "numbers"), "decimals"))) fail(type, path, "InvalidDataModel");
            }
            if (value instanceof StringValue text && !unicodeValid(text.value()))
                fail(type, path, "InvalidDataModel");
            if (value instanceof ObjectValue object) {
                objectMembers(type, object, path);
                switch (classOf(object)) {
                    case "Wrapper" -> checkedWrapperText(type, objectWrapper(object), value, path);
                    case "Sealed" -> sealed(type, value, obj("tag", object.get(tagKey()), "refinements", arr(List.of())), path, active);
                    default -> dataMembers(type, object, path, active);
                }
            } else if (value instanceof ArrayValue array) {
                for (int i = 0; i < array.items().size(); i++) {
                    path.add(variant("Index", str(Integer.toString(i))));
                    data(type, array.items().get(i), path, active);
                    path.remove(path.size() - 1);
                }
            }
        }
        private void dataMembers(int type, ObjectValue object, List<WireValue> path, List<Active> active)
                throws ValueFailure {
            for (Member member : object.members()) {
                path.add(variant("Field", str(member.key())));
                if (!unicodeValid(member.key())) fail(type, path, "InvalidDataModel");
                data(type, member.value(), path, active);
                path.remove(path.size() - 1);
            }
        }
        private String bytesText(WireValue value) {
            WireValue policy = f(profile, "bytes_policy");
            if (!nil(f(policy, "wrapper")))
                return wrapperPayloadText(namedWrapper(s(f(policy, "wrapper"))), value);
            return value instanceof StringValue text ? text.value() : null;
        }
        private byte[] decodeBase64(String text) {
            WireValue policy = f(profile, "bytes_policy");
            if (text == null || nil(policy)) return null;
            int firstPadding = text.indexOf('=');
            String body = firstPadding < 0 ? text : text.substring(0, firstPadding);
            int padding = text.length() - body.length();
            if (padding > 2 || firstPadding >= 0 && !text.substring(firstPadding).equals("=".repeat(padding)))
                return null;
            String alphabet = tag(f(policy, "alphabet"));
            String digits = switch (alphabet) {
                case "Standard" -> "[A-Za-z0-9+/]*";
                case "UrlSafe" -> "[A-Za-z0-9_-]*";
                default -> "[A-Za-z0-9+/_-]*";
            };
            if (!body.matches(digits)) return null;
            int remainder = body.length() % 4;
            if (remainder == 1) return null;
            String normalized = body.replace('-', '+').replace('_', '/');
            if (b(f(policy, "strict_pad_bits")) && remainder != 0) {
                int last = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
                        .indexOf(normalized.charAt(normalized.length() - 1));
                if (last % (remainder == 2 ? 16 : 4) != 0) return null;
            }
            if (padding > 0 && (text.length() % 4 != 0 || padding != (4 - remainder) % 4)) return null;
            if (padding == 0 && !b(f(policy, "padding_optional")) && remainder != 0) return null;
            return Base64.getDecoder().decode(normalized);
        }
        private int decodedBytesLength(int type, WireValue value, List<WireValue> path) throws ValueFailure {
            byte[] decoded = decodeBase64(bytesText(value));
            if (decoded == null) {
                fail(type, path, "InvalidBytes");
                return -1;
            }
            return decoded.length;
        }
        private record DefaultDraft(WireValue value, List<DefaultApplication> applications) {}
        private record DeclaredDefault(WireValue reference, WireValue value) {}
        private WireValue typeDefault(WireValue shape) {
            String kind = tag(shape);
            if (!Set.of("Boolean", "Integer", "String").contains(kind)) return null;
            WireValue value = f(payload(shape), "default_value");
            if (nil(value)) return null;
            return kind.equals("Integer") ? new IntegerValue(n(value)) : value;
        }
        private DeclaredDefault declaredDefault(WireValue reference) {
            for (int fuel = nodes.size() + 1; fuel > 0; fuel--) {
                Integer index = indices.get(reference);
                if (index == null) return null;
                WireValue shape = shape(index);
                if (tag(shape).equals("Alias")) reference = f(payload(shape), "target");
                else { WireValue value = typeDefault(shape); return value == null ? null : new DeclaredDefault(reference, value); }
            }
            return null;
        }
        private WireValue defaultOrigin(WireValue reference) {
            List<WireValue> pointer = new ArrayList<>(a(f(reference, "pointer")));
            pointer.add(str("default"));
            return obj("source", f(reference, "source"), "pointer", arr(pointer));
        }
        private List<WireValue> childPath(List<WireValue> path, WireValue step) {
            List<WireValue> result = new ArrayList<>(path); result.add(step); return result;
        }
        private DefaultDraft defaultDraft(WireValue reference, WireValue value, List<WireValue> path, long fuel) throws ValueFailure {
            if (fuel == 0) throw new ValueFailure(reference, path, "MembershipBound");
            Integer type = indices.get(reference);
            if (type == null) throw new ValueFailure(reference, path, "UnresolvedType");
            WireValue shape = shape(type);
            String kind = tag(shape);
            if (kind.equals("Alias")) return defaultDraft(f(payload(shape), "target"), value, path, fuel - 1);
            if (kind.equals("TaggedUnion") && value instanceof ObjectValue object) {
                WireValue spec = payload(shape);
                WireValue tag = object.get(tagKey());
                if (tag instanceof StringValue) for (WireValue branch : a(f(spec, "branches")))
                    if (f(branch, "wire_tag").equals(tag)) return defaultDraft(f(branch, "target"), value, path, fuel - 1);
            }
            List<DefaultApplication> applications = new ArrayList<>();
            if (kind.equals("Array") && value instanceof ArrayValue array) {
                WireValue spec = payload(shape);
                List<WireValue> items = new ArrayList<>();
                for (int i = 0; i < array.items().size(); i++) {
                    DefaultDraft child = defaultDraft(f(f(spec, "item"), "type_ref"), array.items().get(i), childPath(path, variant("Index", str(Integer.toString(i)))), fuel - 1);
                    items.add(child.value()); applications.addAll(child.applications());
                }
                return new DefaultDraft(arr(items), applications);
            }
            if (kind.equals("Product") && value instanceof ObjectValue object) {
                WireValue spec = payload(shape);
                List<Member> members = new ArrayList<>();
                for (Member member : object.members()) {
                    WireValue field = a(f(spec, "fields")).stream().filter(candidate -> s(f(candidate, "wire_name")).equals(member.key())).findFirst().orElse(null);
                    if (field == null || nil(member.value())) members.add(member);
                    else {
                        DefaultDraft child = defaultDraft(f(f(field, "slot"), "type_ref"), member.value(), childPath(path, variant("Field", str(member.key()))), fuel - 1);
                        members.add(new Member(member.key(), child.value())); applications.addAll(child.applications());
                    }
                }
                for (WireValue field : a(f(spec, "fields"))) {
                    String name = s(f(field, "wire_name"));
                    if (object.get(name) != null) continue;
                    DeclaredDefault declared = declaredDefault(f(f(field, "slot"), "type_ref"));
                    if (declared == null) continue;
                    checkedMaterializationValue(declared.reference(), declared.value());
                    applications.add(new DefaultApplication(childPath(path, variant("Field", str(name))), declared.reference(), defaultOrigin(declared.reference()), declared.value()));
                    members.add(new Member(name, declared.value()));
                }
                return new DefaultDraft(new ObjectValue(members), applications);
            }
            return new DefaultDraft(value, applications);
        }
        private long jsonSize(WireValue value) {
            if (value instanceof ArrayValue array) return 1 + array.items().stream().mapToLong(this::jsonSize).sum();
            if (value instanceof ObjectValue object) return 1 + object.members().stream().mapToLong(member -> jsonSize(member.value())).sum();
            return 1;
        }
        private Slot<WireValue> valueAtPath(WireValue value, List<WireValue> path) {
            if (path.isEmpty()) return new Present<>(value);
            for (WireValue step : path) {
                if (nil(value)) return new NullSlot<>();
                if (tag(step).equals("Field") && value instanceof ObjectValue object) value = object.get(s(payload(step)));
                else if (tag(step).equals("Index") && value instanceof ArrayValue array) {
                    BigInteger index = n(payload(step));
                    if (index.signum() < 0 || index.compareTo(BigInteger.valueOf(array.items().size())) >= 0) return new Absent<>();
                    value = array.items().get(index.intValue());
                } else if (tag(step).equals("Variant") && value instanceof ObjectValue object) {
                    if (!payload(step).equals(object.get(tagKey()))) return new Absent<>();
                } else return new Absent<>();
                if (value == null) return new Absent<>();
                if (nil(value)) return new NullSlot<>();
            }
            return new Present<>(value);
        }
        public boolean checkDefaultApplications(WireValue before, WireValue after, List<DefaultApplication> applications) {
            return applications.stream().allMatch(application -> {
                Integer type = indices.get(application.typeRef());
                return valueAtPath(before, application.valuePath()) instanceof Absent<?>
                        && valueAtPath(after, application.valuePath()).equals(new Present<>(application.value()))
                        && application.origin().equals(defaultOrigin(application.typeRef()))
                        && type != null && application.value().equals(typeDefault(shape(type)));
            });
        }
        public DefaultedValue materializeDefaults(WireValue reference, WireValue value) throws ValueFailure {
            DefaultDraft draft = defaultDraft(reference, value, List.of(), (jsonSize(value) + 1) * (nodes.size() + 1L));
            checkedMaterializationValue(reference, draft.value());
            if (!checkDefaultApplications(value, draft.value(), draft.applications()))
                throw new ValueFailure(reference, List.of(), "CertificateMismatch: default source, absence, or result");
            return new DefaultedValue(draft.value(), draft.applications());
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
    private record FormatSpanNode(int id, String kind, WireValue spec, List<FormatSpanNode> children) {}
    private static FormatSpanNode binaryFormatSequence(List<FormatSpanNode> children, int start, int end, List<FormatSpanNode> nodes) {
        if (end - start == 1) return children.get(start);
        List<FormatSpanNode> pair = List.of();
        if (start < end) {
            int middle = start + (end - start) / 2;
            pair = List.of(binaryFormatSequence(children, start, middle, nodes), binaryFormatSequence(children, middle, end, nodes));
        }
        FormatSpanNode node = new FormatSpanNode(nodes.size(), "Sequence", null, pair);
        nodes.add(node);
        return node;
    }
    private static FormatSpanNode compileFormatSpan(WireValue rule, List<FormatSpanNode> nodes) {
        String kind = tag(rule);
        WireValue spec = o(rule).get("value"); if (spec == null) spec = o(rule).get("fields");
        List<FormatSpanNode> children = new ArrayList<>();
        if (kind.equals("Sequence") || kind.equals("Choice")) {
            for (WireValue child : a(spec)) children.add(compileFormatSpan(child, nodes));
        } else if (kind.equals("Optional") || kind.equals("Not")) {
            children.add(compileFormatSpan(spec, nodes));
        } else if (kind.equals("Bounded") || kind.equals("Labels")) {
            children.add(compileFormatSpan(f(spec, "rule"), nodes));
        }
        if (kind.equals("Sequence")) return binaryFormatSequence(children, 0, children.size(), nodes);
        FormatSpanNode node = new FormatSpanNode(nodes.size(), kind, spec, List.copyOf(children));
        nodes.add(node);
        return node;
    }
    private static final class FormatSpan {
        private record Key(int node, int start, int end) {}
        private final String source;
        private final List<Integer> offsets;
        private final Map<Key, Boolean> memo = new HashMap<>();
        private FormatSpan(String source) { this.source = source; offsets = scalarOffsets(source); }
        private boolean accepts(FormatSpanNode node, int start, int end) {
            Key key = new Key(node.id(), start, end);
            Boolean known = memo.get(key);
            if (known != null) return known;
            boolean accepted;
            WireValue spec = node.spec();
            List<FormatSpanNode> children = node.children();
            switch (node.kind()) {
                case "Sequence": {
                    accepted = children.isEmpty() && start == end;
                    if (children.size() == 2) for (int split = start; split <= end; split++) {
                        if (accepts(children.get(0), start, split) && accepts(children.get(1), split, end)) { accepted = true; break; }
                    }
                    break;
                }
                case "Choice": {
                    accepted = false;
                    for (FormatSpanNode child : children) if (accepts(child, start, end)) { accepted = true; break; }
                    break;
                }
                case "Optional": accepted = start == end || accepts(children.getFirst(), start, end); break;
                case "Not": accepted = !accepts(children.getFirst(), start, end); break;
                case "Bounded": {
                    int length = tag(f(spec, "unit")).equals("Utf8Bytes")
                            ? source.substring(offsets.get(start), offsets.get(end)).getBytes(StandardCharsets.UTF_8).length : end - start;
                    accepted = length <= n(f(spec, "maximum")).intValue() && accepts(children.getFirst(), start, end);
                    break;
                }
                case "Labels": {
                    String delimiter = s(f(spec, "separator"));
                    String text = source.substring(offsets.get(start), offsets.get(end));
                    List<Integer> cuts = new ArrayList<>();
                    if (!delimiter.isEmpty()) {
                        int cursor = 0;
                        for (int found = text.indexOf(delimiter); found >= 0; found = text.indexOf(delimiter, cursor)) {
                            cuts.add(found); cursor = found + delimiter.length();
                        }
                    }
                    cuts.add(text.length());
                    accepted = !delimiter.isEmpty() && cuts.size() >= n(f(spec, "min_count")).intValue()
                            && (nil(f(spec, "max_count")) || cuts.size() <= n(f(spec, "max_count")).intValue())
                            && (nil(f(spec, "total_max")) || end - start <= n(f(spec, "total_max")).intValue());
                    if (accepted) {
                        int cursor = start;
                        int charCursor = 0;
                        for (int cut : cuts) {
                            int length = scalarLength(text.substring(charCursor, cut));
                            if (!accepts(children.getFirst(), cursor, cursor + length)) { accepted = false; break; }
                            cursor += length + scalarLength(delimiter);
                            charCursor = cut + delimiter.length();
                        }
                    }
                    break;
                }
                default: accepted = recognizeFormatLeaf(node.kind(), spec, source.substring(offsets.get(start), offsets.get(end)));
            }
            memo.put(key, accepted);
            return accepted;
        }
    }
    static boolean recognize(WireValue rule, String text) {
        if (rule == null) return false;
        FormatSpan span = new FormatSpan(text);
        return span.accepts(compileFormatSpan(rule, new ArrayList<>()), 0, span.offsets.size() - 1);
    }
    private static boolean recognizeFormatLeaf(String kind, WireValue spec, String text) {
        switch (kind) {
            case "Literal": return s(spec).equals(text);
            case "Identifier": {
                if (!ascii(text) || text.isEmpty() || !bounds(text.length(), f(spec, "min_length"), f(spec, "max_length")) || !nil(f(spec, "exact_length")) && !BigInteger.valueOf(text.length()).equals(n(f(spec, "exact_length"))) || a(f(spec, "forbidden")).contains(str(text)) || !s(f(spec, "first_alphabet")).contains(text.substring(0, 1))) return false;
                String alphabet = s(f(spec, "rest_alphabet")); for (int i = 1; i < text.length(); i++) if (alphabet.indexOf(text.charAt(i)) < 0) return false;
                return true;
            }
            case "Timestamp": return timestamp(spec, text);
            case "AbsoluteUri": return absoluteUri(text, nil(f(spec, "max_bytes")) ? BigInteger.valueOf(Integer.MAX_VALUE) : n(f(spec, "max_bytes")));
            case "LanguageTag": return language(text, a(f(spec, "grandfathered")));
            case "Text": return true;
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
        NetworkEffect.StartObservation start(NetworkEffect.SendCommand command);
        NetworkEffect.HostObservation observe(NetworkEffect.StartedAttempt started);
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
            try { step = NetworkEffect.observe(state, adapter.observe(started)); }
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
        NetworkEffect.StartObservation start;
        try { start = adapter.start(command.command()); } catch (RuntimeException error) { return new HttpRejected<>(command.state(), new AdapterFailure(error), true); }
        NetworkEffect.NetworkStep observed = NetworkEffect.observeStart(command.state(), prepared.prepared(), start);
        if (observed instanceof NetworkEffect.NetworkStep.Rejected rejected) return new HttpRejected<>(rejected.state(), new LedgerFailure(rejected.failure()), true);
        if (observed instanceof NetworkEffect.NetworkStep.Terminal terminal) {
            try { return new HttpCompleted<>(terminal.state(), terminal.settled(), decoder.decode(terminal.settled())); }
            catch (Exception error) { return new HttpRejected<>(terminal.state(), new OwnerFailure(error), true); }
        }
        if (observed instanceof NetworkEffect.NetworkStep.Started started) return new HttpPending<>(new HttpContinuation<>(started.state(), started.started(), adapter, decoder));
        return new HttpRejected<>(command.state(), new UnexpectedObservation(observed), true);
    }
}
