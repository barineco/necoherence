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
import neco.quotient.RefinementOutcome;
import neco.quotient.Result;
import necoherence.composition.SemanticComposition.SlotContract;
import necoherence.composition.SemanticComposition;
import necoherence.composition.SemanticComposition.TypeRef;
import necoherence.network.NetworkEffect;
import necoherence.semantic.ExactJson.JsonValue;
import necoherence.semantic.WireFailure.WireException;

/** Exact wire values and the validators used by admitted generated classes. */
public final class SemanticValues {
    private SemanticValues() {}

    private static final java.util.regex.Pattern JSON_NUMBER =
            java.util.regex.Pattern.compile("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?");
    private static final java.util.regex.Pattern LEAN_NUMBER =
            java.util.regex.Pattern.compile("[ \\t\\r\\n]*(-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?)[ \\t\\r\\n]*");

    /** The end of the JSON number that starts at {@code from}, or -1 when no JSON number starts there. */
    static int jsonNumberEnd(String text, int from) {
        java.util.regex.Matcher number = JSON_NUMBER.matcher(text).region(from, text.length());
        return number.lookingAt() ? number.end() : -1;
    }

    /** Lean {@code exponentLimit}: the exponent magnitude from which a JSON number is rejected. */
    private static BigInteger exponentLimit() { return BigInteger.valueOf(10_000); }

    /** Lean {@code exponentMagnitudeAtLimit}: the exponent of the spelling is 10000 or more in magnitude, by value. */
    static boolean exponentTooLarge(String spelling) {
        int exponentAt = Math.max(spelling.indexOf('e'), spelling.indexOf('E'));
        return exponentAt >= 0 && new BigInteger(spelling.substring(exponentAt + 1)).abs().compareTo(exponentLimit()) >= 0;
    }

    /** Lean {@code exponentDigits}: the position after one optional sign at {@code from}. */
    private static int exponentDigits(String text, int from) {
        return from < text.length() && (text.charAt(from) == '+' || text.charAt(from) == '-') ? from + 1 : from;
    }

    /** The value of a digit run, saturated at {@code exponentLimit}, with the number of digits read. */
    private record ExponentValue(BigInteger value, int count) {}

    /** Lean {@code exponentValue}: reads the digits from {@code at}, after the accumulated value {@code acc} and the digit count {@code count}. */
    private static ExponentValue exponentValue(String text, int at, BigInteger acc, int count) {
        BigInteger value = acc;
        int digits = count;
        for (; at < text.length() && text.charAt(at) >= '0' && text.charAt(at) <= '9'; at++, digits++)
            value = exponentLimit().min(value.multiply(BigInteger.TEN).add(BigInteger.valueOf(text.charAt(at) - '0')));
        return new ExponentValue(value, digits);
    }

    /** Lean {@code exponentMagnitudeAtLimit} on the text after an exponent marker: after one optional sign, the digits reach the limit by value. */
    static boolean exponentMagnitudeAtLimit(String text, int from) {
        ExponentValue exponent = exponentValue(text, exponentDigits(text, from), BigInteger.ZERO, 0);
        return 0 < exponent.count() && exponentLimit().compareTo(exponent.value()) <= 0;
    }

    /** Lean {@code SignatureJson.parse} accepts the text as a JSON number, with the surrounding whitespace of the reader. */
    public static boolean isJsonNumber(String text) {
        int start = 0, end = text.length();
        while (start < end && " \t\r\n".indexOf(text.charAt(start)) >= 0) start++;
        while (end > start && " \t\r\n".indexOf(text.charAt(end - 1)) >= 0) end--;
        String spelling = text.substring(start, end);
        return isJsonNumberSpelling(spelling) && !exponentTooLarge(spelling);
    }

    /** The grammar of a JSON number spelling, without whitespace and without the exponent limit. */
    public static boolean isJsonNumberSpelling(String text) { return JSON_NUMBER.matcher(text).matches(); }

    /** Lean {@code decodeExact} of a decimal: no surrounding whitespace, and the text is a JSON number. */
    public static boolean isExactDecimal(String text) {
        return text.equals(SemanticValidation.trimAscii(text)) && isJsonNumber(text);
    }

    public record DecimalNumber(BigInteger mantissa, BigInteger scale) {
        public DecimalNumber { Objects.requireNonNull(mantissa); Objects.requireNonNull(scale); }
    }

    static Optional<DecimalNumber> parseLeanNumber(String text) {
        java.util.regex.Matcher matcher = LEAN_NUMBER.matcher(text);
        if (!matcher.matches()) return Optional.empty();
        String spelling = matcher.group(1);
        int exponentAt = Math.max(spelling.indexOf('e'), spelling.indexOf('E'));
        String mantissaText = exponentAt < 0 ? spelling : spelling.substring(0, exponentAt);
        BigInteger exponent = exponentAt < 0 ? BigInteger.ZERO : new BigInteger(spelling.substring(exponentAt + 1));
        if (exponentTooLarge(spelling)) return Optional.empty();
        int dot = mantissaText.indexOf('.');
        String digits = dot < 0 ? mantissaText : mantissaText.substring(0, dot) + mantissaText.substring(dot + 1);
        BigInteger fraction = BigInteger.valueOf(dot < 0 ? 0 : mantissaText.length() - dot - 1);
        return Optional.of(new DecimalNumber(new BigInteger(digits), fraction.subtract(exponent)));
    }

    record NormalizedDecimal(int sign, BigInteger digits, BigInteger power) {}

    static NormalizedDecimal normalize(DecimalNumber number) {
        if (number.mantissa().signum() == 0) return new NormalizedDecimal(0, BigInteger.ZERO, BigInteger.ZERO);
        Magnitude magnitude = Magnitude.of(number.mantissa().abs(), number.scale());
        return new NormalizedDecimal(number.mantissa().signum(), new BigInteger(magnitude.digits()),
                magnitude.exponent().add(BigInteger.valueOf(magnitude.digits().length())));
    }

    static Optional<BigInteger> integralValue(NormalizedDecimal parts) {
        return scaleByTenPower(parts.digits(), parts.power().subtract(BigInteger.valueOf(parts.digits().toString().length())))
                .map(value -> parts.sign() < 0 ? value.negate() : value);
    }

    static Optional<BigInteger> scaleByTenPower(BigInteger magnitude, BigInteger power) {
        if (magnitude.signum() == 0) return Optional.of(BigInteger.ZERO);
        if (power.signum() < 0 || power.bitLength() > 31) return Optional.empty();
        int exponent = power.intValue();
        if (magnitude.bitLength() + 4L * exponent > Integer.MAX_VALUE) return Optional.empty();
        return Optional.of(magnitude.multiply(BigInteger.TEN.pow(exponent)));
    }

    static int compareDecimal(DecimalNumber left, DecimalNumber right) {
        int leftSign = left.mantissa().signum(), rightSign = right.mantissa().signum();
        if (leftSign != rightSign) return Integer.compare(leftSign, rightSign);
        if (leftSign == 0) return 0;
        int magnitude = compareMagnitude(left.mantissa().abs(), left.scale(), right.mantissa().abs(), right.scale());
        return leftSign > 0 ? magnitude : -magnitude;
    }

    private static int compareMagnitude(BigInteger left, BigInteger leftScale, BigInteger right, BigInteger rightScale) {
        Magnitude first = Magnitude.of(left, leftScale), second = Magnitude.of(right, rightScale);
        int order = first.order().compareTo(second.order());
        if (order != 0) return order;
        int length = Math.max(first.digits().length(), second.digits().length());
        return (first.digits() + "0".repeat(length - first.digits().length()))
                .compareTo(second.digits() + "0".repeat(length - second.digits().length()));
    }

    static String withoutTrailingZeros(String digits) {
        int end = digits.length();
        while (end > 0 && digits.charAt(end - 1) == '0') end--;
        return digits.substring(0, end);
    }

    private record Magnitude(String digits, BigInteger exponent) {
        static Magnitude of(BigInteger magnitude, BigInteger scale) {
            String text = magnitude.toString();
            String significant = withoutTrailingZeros(text);
            return new Magnitude(significant, BigInteger.valueOf(text.length() - significant.length()).subtract(scale));
        }

        BigInteger order() { return exponent.add(BigInteger.valueOf(digits.length() - 1)); }
    }

    public sealed interface WireValue permits NullValue, BooleanValue, IntegerValue, DecimalValue,
            StringValue, ArrayValue, ObjectValue {}
    public record NullValue() implements WireValue {}
    public record BooleanValue(boolean value) implements WireValue {}
    public record IntegerValue(BigInteger value) implements WireValue {
        public IntegerValue { Objects.requireNonNull(value); }
    }
    public record DecimalValue(String text) implements WireValue {
        public DecimalValue {
            if (text == null || !isJsonNumberSpelling(text))
                throw new WireException(new WireFailure.Syntax("$", "exact decimal spelling required"));
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
            return SemanticValidation.memberValue(key, members, Member::key, Member::value).orElse(null);
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
        Optional<String> wire() { return Optional.ofNullable(encoding); }
        public int size() { return value.length; }
    }

    public sealed interface ValueCondition permits SimpleValueCondition, WrongValueKind,
            FormatCondition, InvalidWrapper, KeyFormat, DuplicateField, UnexpectedField {}
    public enum SimpleValueCondition implements ValueCondition {
        MISSING_REQUIRED,
        NULL_NOT_ALLOWED,
        CONST_MISMATCH,
        ENUM_MISMATCH,
        BELOW_MINIMUM,
        ABOVE_MAXIMUM,
        INTEGER_DOMAIN,
        STRING_LENGTH,
        ARRAY_LENGTH,
        BYTES_LENGTH,
        INVALID_BYTES,
        INVALID_TAG,
        RESERVED_FORM,
        NO_BRANCH_SELECTED,
        UNINHABITED,
        INVALID_DATA_MODEL,
        REFERENCE_CYCLE
    }
    public record WrongValueKind(String expected) implements ValueCondition {
        public WrongValueKind { Objects.requireNonNull(expected); }
    }
    public record FormatCondition(String name) implements ValueCondition {
        public FormatCondition { Objects.requireNonNull(name); }
    }
    public record InvalidWrapper(String name) implements ValueCondition {
        public InvalidWrapper { Objects.requireNonNull(name); }
    }
    public record KeyFormat(String name) implements ValueCondition {
        public KeyFormat { Objects.requireNonNull(name); }
    }
    public record DuplicateField(String name) implements ValueCondition {
        public DuplicateField { Objects.requireNonNull(name); }
    }
    public record UnexpectedField(String name) implements ValueCondition {
        public UnexpectedField { Objects.requireNonNull(name); }
    }

    public static String valueConditionTag(ValueCondition condition) {
        if (condition instanceof WrongValueKind) return "WrongValueKind";
        if (condition instanceof FormatCondition) return "Format";
        if (condition instanceof InvalidWrapper) return "InvalidWrapper";
        if (condition instanceof KeyFormat) return "KeyFormat";
        if (condition instanceof DuplicateField) return "DuplicateField";
        if (condition instanceof UnexpectedField) return "UnexpectedField";
        return switch ((SimpleValueCondition) condition) {
            case MISSING_REQUIRED -> "MissingRequired";
            case NULL_NOT_ALLOWED -> "NullNotAllowed";
            case CONST_MISMATCH -> "ConstMismatch";
            case ENUM_MISMATCH -> "EnumMismatch";
            case BELOW_MINIMUM -> "BelowMinimum";
            case ABOVE_MAXIMUM -> "AboveMaximum";
            case INTEGER_DOMAIN -> "IntegerDomain";
            case STRING_LENGTH -> "StringLength";
            case ARRAY_LENGTH -> "ArrayLength";
            case BYTES_LENGTH -> "BytesLength";
            case INVALID_BYTES -> "InvalidBytes";
            case INVALID_TAG -> "InvalidTag";
            case RESERVED_FORM -> "ReservedForm";
            case NO_BRANCH_SELECTED -> "NoBranchSelected";
            case UNINHABITED -> "Uninhabited";
            case INVALID_DATA_MODEL -> "InvalidDataModel";
            case REFERENCE_CYCLE -> "ReferenceCycle";
        };
    }
    public static Optional<String> valueConditionArgument(ValueCondition condition) {
        if (condition instanceof WrongValueKind value) return Optional.of(value.expected());
        if (condition instanceof FormatCondition value) return Optional.of(value.name());
        if (condition instanceof InvalidWrapper value) return Optional.of(value.name());
        if (condition instanceof KeyFormat value) return Optional.of(value.name());
        if (condition instanceof DuplicateField value) return Optional.of(value.name());
        if (condition instanceof UnexpectedField value) return Optional.of(value.name());
        return Optional.empty();
    }

    public enum ValueProcessingFailureKind {
        UNRESOLVED, CERTIFICATE_MISMATCH
    }
    public static final class ValueProcessingFailure extends RuntimeException {
        private static final long serialVersionUID = 1L;
        private final transient SemanticComposition.TypeRef typeRef;
        private final transient List<SemanticComposition.PathStep> path;
        private final ValueProcessingFailureKind kind;
        private final String condition;
        private final transient List<SemanticTypes.SemanticObligation> obligations;
        public ValueProcessingFailure(SemanticComposition.TypeRef typeRef, List<SemanticComposition.PathStep> path,
                ValueProcessingFailureKind kind, String condition) {
            this(typeRef, path, kind, condition, List.of());
        }
        public ValueProcessingFailure(SemanticComposition.TypeRef typeRef, List<SemanticComposition.PathStep> path,
                ValueProcessingFailureKind kind, String condition, List<SemanticTypes.SemanticObligation> obligations) {
            super(encodeWire(SemanticGraphWire.typeRefWire(typeRef)) + " "
                    + path.stream().map(SemanticGraphWire::pathStepWire).toList() + ": " + condition);
            this.typeRef = Objects.requireNonNull(typeRef);
            this.path = List.copyOf(path);
            this.kind = Objects.requireNonNull(kind);
            this.condition = Objects.requireNonNull(condition);
            this.obligations = List.copyOf(obligations);
        }
        public SemanticComposition.TypeRef typeRef() { return typeRef; }
        public List<SemanticComposition.PathStep> path() { return path; }
        public ValueProcessingFailureKind kind() { return kind; }
        public String condition() { return condition; }
        public List<SemanticTypes.SemanticObligation> obligations() { return obligations; }
        public Optional<Result<RefinementOutcome<SemanticTypes.SemanticJudgment, SemanticTypes.SemanticObligation, List<SemanticTypes.SemanticObligation>>, SemanticTypes.SemanticDecisionFailure>> evaluation() {
            if (obligations.isEmpty()) return Optional.empty();
            return Optional.of(SemanticTypes.classifyValueDecision(
                    new SemanticTypes.EvaluationProvenance("validate", typeRef, path),
                    new SemanticTypes.Unresolved(obligations)));
        }
    }

    public static final class ValueRejection extends RuntimeException {
        private static final long serialVersionUID = 1L;
        private final transient SemanticTypes.ValueFailure failure;
        public ValueRejection(SemanticTypes.ValueFailure failure) {
            super(encodeWire(SemanticGraphWire.typeRefWire(failure.typeRef())) + " "
                    + failure.valuePath().stream().map(SemanticGraphWire::pathStepWire).toList() + ": " + failure.condition());
            this.failure = Objects.requireNonNull(failure);
        }
        public ValueRejection(WireValue typeRef, List<WireValue> path, ValueCondition condition,
                List<WireValue> referenceTrace, Slot<JsonValue> observed) {
            this(new SemanticTypes.ValueFailure(SemanticGraphWire.typeRef(typeRef, "$"),
                    new necoherence.composition.SemanticComposition.DefinitionRef(SemanticGraphWire.typeRef(typeRef, "$").source(), s(f(typeRef, "definition_name"))),
                    new SemanticTypes.OccurrenceRef(SemanticGraphWire.typeRef(typeRef, "$").source(), a(f(typeRef, "pointer")).stream().map(SemanticValues::s).toList()),
                    path.stream().map(SemanticGraphWire::pathStep).toList(), condition, observed,
                    referenceTrace.stream().map(trace -> SemanticGraphWire.typeRef(trace, "$")).toList()));
        }
        public SemanticTypes.ValueFailure failure() { return failure; }
        public String definition() { return failure.definitionRef().name(); }
        public List<WireValue> path() { return failure.valuePath().stream().map(SemanticGraphWire::pathStepWire).toList(); }
        public ValueCondition condition() { return failure.condition(); }
        public Slot<JsonValue> observed() { return failure.observed(); }
        public WireValue typeRef() { return SemanticGraphWire.typeRefWire(failure.typeRef()); }
        public WireValue origin() { return obj("source", SemanticGraphWire.sourceRefWire(failure.origin().source()), "pointer", arr(failure.origin().pointer().stream().map(SemanticValues::str).toList())); }
        public List<WireValue> referenceTrace() { return failure.referenceTrace().stream().map(SemanticGraphWire::typeRefWire).toList(); }
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

    /** @return the first object key that repeats within one object, or null when every object key is unique */
    public static String firstDuplicateKey(WireValue value) {
        if (value instanceof ObjectValue object) {
            Set<String> keys = new HashSet<>();
            for (Member member : object.members()) if (!keys.add(member.key())) return member.key();
            for (Member member : object.members()) {
                String duplicate = firstDuplicateKey(member.value());
                if (duplicate != null) return duplicate;
            }
        } else if (value instanceof ArrayValue array) {
            for (WireValue item : array.items()) {
                String duplicate = firstDuplicateKey(item);
                if (duplicate != null) return duplicate;
            }
        }
        return null;
    }

    static void requireUnicode(String text) {
        if (!ExactJson.unicodeValid(text)) throw new WireException(new WireFailure.Syntax("$", "unpaired Unicode surrogate"));
    }
    public static final NullValue NIL = new NullValue();
    static WireException shape(String expected) { return new WireException(new WireFailure.Syntax("$", "expected " + expected)); }
    public static String s(WireValue value) {
        if (value instanceof StringValue text) return text.value();
        throw shape("string");
    }
    public static boolean b(WireValue value) {
        if (value instanceof BooleanValue flag) return flag.value();
        throw shape("boolean");
    }
    static boolean canonicalDigits(String text, boolean signed) {
        int start = signed && text.startsWith("-") ? 1 : 0;
        if (text.length() == start) return false;
        if (text.charAt(start) == '0') return start == 0 && text.length() == 1;
        for (int index = start; index < text.length(); index++) if (text.charAt(index) < '0' || text.charAt(index) > '9') return false;
        return true;
    }
    private static BigInteger exactInteger(WireValue value, boolean signed, String expected) {
        if (value instanceof StringValue text && canonicalDigits(text.value(), signed)) return new BigInteger(text.value());
        throw shape(expected);
    }
    public static BigInteger n(WireValue value) { return exactInteger(value, false, "decimal natural"); }
    public static BigInteger i(WireValue value) { return exactInteger(value, true, "decimal integer"); }
    public static List<WireValue> a(WireValue value) {
        if (value instanceof ArrayValue array) return array.items();
        throw shape("array");
    }
    static ObjectValue o(WireValue value) {
        if (value instanceof ObjectValue object) return object;
        throw shape("object");
    }
    /** @return the member value of the object, or the typed missing-field failure when the key is absent */
    public static WireValue f(WireValue value, String key) {
        WireValue result = o(value).get(key);
        if (result == null) throw new WireException(new WireFailure.Syntax("$." + key, "missing field " + key));
        return result;
    }
    public static String tag(WireValue value) { return s(f(value, "tag")); }
    public static WireValue payload(WireValue value) {
        WireValue result = o(value).get("value");
        return result == null ? f(value, "fields") : result;
    }
    /**
     * Lean {@code keys}: the unknown members are reported first, the first in key order, and then the first expected
     * member that is missing, in the order of the expected list. The failure path is the path of the member.
     */
    public static void keys(WireValue value, String path, List<String> expected) {
        if (!(value instanceof ObjectValue object)) throw new WireException(new WireFailure.Syntax(path, "object expected"));
        String unknown = null;
        for (Member member : object.members())
            if (!expected.contains(member.key()) && (unknown == null || compareCodePoints(member.key(), unknown) < 0)) unknown = member.key();
        if (unknown != null) throw new WireException(new WireFailure.UnknownField(path + "." + unknown, unknown));
        for (String key : expected)
            if (object.get(key) == null) throw new WireException(new WireFailure.Syntax(path + "." + key, "missing field"));
    }
    /** {@link #keys(WireValue, String, List)} for an expected list written as arguments. */
    public static void keys(WireValue value, String path, String... expected) { keys(value, path, List.of(expected)); }
    /** A decoder of one wire value, which reports the failure paths of the value relative to {@code $}. */
    @FunctionalInterface
    public interface WireReader<T> { T read(WireValue value); }

    /** Lean {@code get json key}: a missing member or a non-object row fails at {@code $.key}, and the reader's failure is prefixed with {@code $.key}. */
    public static <T> T readField(WireValue row, String key, WireReader<T> reader) {
        WireValue value = memberOf(row, key);
        try { return reader.read(value); }
        catch (WireException failure) { throw prefixed("$." + key, failure); }
    }

    /** The reader of the value, with the failure prefixed with the path of the value. */
    public static <T> T readWithin(String path, WireReader<T> reader, WireValue value) {
        try { return reader.read(value); }
        catch (WireException failure) { throw prefixed(path, failure); }
    }

    /** Lean {@code decodeListWith}: an element failure is prefixed with {@code [index]}. */
    public static <T> List<T> readList(WireValue value, WireReader<T> reader) {
        List<WireValue> items = a(value);
        List<T> result = new ArrayList<>(items.size());
        for (int index = 0; index < items.size(); index++) {
            try { result.add(reader.read(items.get(index))); }
            catch (WireException failure) { throw prefixed("$[" + index + "]", failure); }
        }
        return result;
    }

    /** Lean {@code mapM} over a list: the element failure keeps the path relative to the element. */
    public static <T> List<T> readPlainList(WireValue value, WireReader<T> reader) {
        List<T> result = new ArrayList<>();
        for (WireValue item : a(value)) result.add(reader.read(item));
        return result;
    }

    /** Lean {@code Wire (Option α)}: null is none, and any other value is read by the reader. */
    public static <T> Optional<T> readOption(WireValue value, WireReader<T> reader) {
        return nil(value) ? Optional.empty() : Optional.of(reader.read(value));
    }

    private static WireValue memberOf(WireValue row, String key) {
        if (!(row instanceof ObjectValue object)) throw new WireException(new WireFailure.Syntax("$." + key, "object expected"));
        WireValue value = object.get(key);
        if (value == null) throw new WireException(new WireFailure.Syntax("$." + key, "missing field " + key));
        return value;
    }

    /** Lean {@code WireFailure.prepend}: the failure path continues after the segment instead of the root. */
    private static WireException prefixed(String segment, WireException failure) {
        WireFailure original = failure.failure();
        String rest = original.path().startsWith("$") ? original.path().substring(1) : original.path();
        String path = segment + rest;
        WireFailure prefixed = switch (original) {
            case WireFailure.UnsupportedSchema unsupported -> new WireFailure.UnsupportedSchema(path, unsupported.schema());
            case WireFailure.UnknownField unknown -> new WireFailure.UnknownField(path, unknown.field());
            case WireFailure.UnknownTag tag -> new WireFailure.UnknownTag(path, tag.tag());
            case WireFailure.Syntax syntax -> new WireFailure.Syntax(path, syntax.message());
        };
        return new WireException(prefixed);
    }
    /** The order of the Lean {@code String} comparison: the code points in sequence, and a prefix before its extensions. */
    public static int compareCodePoints(String left, String right) {
        int a = 0, b = 0;
        while (a < left.length() && b < right.length()) {
            int x = left.codePointAt(a), y = right.codePointAt(b);
            if (x != y) return Integer.compare(x, y);
            a += Character.charCount(x);
            b += Character.charCount(y);
        }
        return Integer.compare(left.length() - a, right.length() - b);
    }
    /** Lean {@code payload json}: the object has the tag and value members, and no other member. */
    public static WireValue closedPayload(WireValue value, String path) {
        keys(value, path, List.of("tag", "value"));
        return ((ObjectValue) value).get("value");
    }
    /** Lean {@code fields json}: the object has the tag and fields members, and no other member. */
    public static WireValue closedFields(WireValue value, String path) {
        keys(value, path, List.of("tag", "fields"));
        return ((ObjectValue) value).get("fields");
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
    public static WireValue withMember(String key, String text, WireValue value) {
        if (!(value instanceof ObjectValue object)) return value;
        List<Member> members = new ArrayList<>();
        members.add(new Member(key, str(text)));
        for (Member member : object.members()) if (!member.key().equals(key)) members.add(member);
        return new ObjectValue(members);
    }
    public static WireValue member(ObjectValue value, String name) { return value.get(name); }
    /** Writes the wire tree as compact JSON text, with each decimal spelled as the Lean numberText of its exact value. */
    public static String encodeWire(WireValue value) {
        StringBuilder result = new StringBuilder(); appendJson(value, result); return result.toString();
    }
    public static boolean sameJson(WireValue left, WireValue right) {
        return encodeWire(TypeSignatures.ordered(left)).equals(encodeWire(TypeSignatures.ordered(right)));
    }
    static void appendJson(WireValue value, StringBuilder out) {
        switch (value) {
            case NullValue unused -> out.append("null");
            case BooleanValue v -> out.append(v.value());
            case IntegerValue v -> out.append(v.value());
            case DecimalValue v -> out.append(SemanticGeneration.leanNumberText(v.text()));
            case StringValue v -> appendString(v.value(), out);
            case ArrayValue v -> {
                out.append('[');
                for (int i = 0; i < v.items().size(); i++) { if (i != 0) out.append(','); appendJson(v.items().get(i), out); }
                out.append(']');
            }
            case ObjectValue v -> {
                out.append('{');
                List<Member> members = v.members().stream().sorted((a, b) -> ExactJson.compareKeys(a.key(), b.key())).toList();
                for (int i = 0; i < members.size(); i++) {
                    if (i != 0) out.append(',');
                    Member member = members.get(i); appendString(member.key(), out); out.append(':'); appendJson(member.value(), out);
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
                case '\n' -> out.append("\\n"); case '\r' -> out.append("\\r");
                default -> {
                    if (c < 32) { out.append("\\u00").append(Character.forDigit(c >>> 4, 16)).append(Character.forDigit(c & 15, 16)); }
                    else out.append(c);
                }
            }
        }
        out.append('"');
    }

    /** An immutable context shared by every codec of one admitted generation. */
    public static final class Context {
        private final SemanticTypes.SemanticGraph typed;
        private final ValidationTables tables;
        final Map<WireValue, Integer> indices;
        public Context(WireValue graph) { this(SemanticGraphWire.decodeGraph(graph)); }
        public Context(SemanticTypes.SemanticGraph typed) {
            this.typed = Objects.requireNonNull(typed);
            this.tables = ValidationTables.of(typed);
            Map<WireValue, Integer> indices = new LinkedHashMap<>();
            for (int i = 0; i < typed.nodes().size(); i++)
                indices.putIfAbsent(SemanticGraphWire.typeRefWire(typed.nodes().get(i).ref()), i);
            this.indices = Map.copyOf(indices);
        }
        public SemanticTypes.SemanticGraph typed() { return typed; }
        ValidationTables tables() { return tables; }
        public String tagKey() { return typed.profile().tag().map(SemanticTypes.TagModel::key).orElse(""); }
        public boolean formatDefined(String name) {
            Objects.requireNonNull(name, "name");
            return typed.profile().formatBindings().stream().anyMatch(binding -> binding.name().equals(name));
        }
        /**
         * Recognizes a value using the admitted profile's format rule.
         * Unknown formats return false. This operation has no state changes or external effects.
         * @throws NullPointerException if name or value is null
         */
        public boolean recognizeFormat(String name, String value) {
            Objects.requireNonNull(name, "name");
            Objects.requireNonNull(value, "value");
            return SemanticValidation.namedFormatAccepts(tables, name, value);
        }
        /** Reads the verified Unicode component, table digest, and resolved sources. */
        public SemanticTypes.GraphemeRules graphemeRules() {
            return typed.profile().graphemeRules().orElseThrow(() -> new IllegalStateException("MissingGraphemeRules"));
        }
        public int index(WireValue reference) {
            Integer result = indices.get(reference);
            if (result == null) throw new WireException(new WireFailure.Syntax("$", "unresolved source-qualified type"));
            return result;
        }
        public WireValue reference(int index) { return SemanticGraphWire.typeRefWire(typed.nodes().get(index).ref()); }
        public List<WireValue> meaningObligations(WireValue reference) {
            return SemanticValidation.meaningObligations(tables, List.of(SemanticGraphWire.typeRef(reference, "$"))).stream()
                    .map(SemanticGraphWire::obligationWire).toList();
        }
        private static String meaningPredicate(SemanticTypes.SemanticReason reason) {
            return switch (reason) {
                case SemanticTypes.UnknownFormat unused -> "MO01";
                case SemanticTypes.MissingGraphemeRules unused -> "MO02";
                case SemanticTypes.MissingBytesPolicy unused -> "MO03";
                case SemanticTypes.UnknownIntegerDomain unused -> "MO04";
                case SemanticTypes.UnknownWrapper unused -> "MO05";
                case SemanticTypes.WrapperPayloadReason unused -> "MO06";
                case SemanticTypes.UnknownSealedTag unused -> "MO07";
                case SemanticTypes.DecimalNotAdmitted unused -> "MO08";
                case SemanticTypes.IntegerBound unused -> "MO09";
                case SemanticTypes.OpaqueType unused -> "MO10";
                case SemanticTypes.MissingTagModel unused -> "MO11";
                case SemanticTypes.UnresolvedType unused -> "MO12";
                default -> null;
            };
        }
        private void unresolved(WireValue reference, List<SemanticTypes.SemanticObligation> obligations) {
            throw new ValueProcessingFailure(SemanticGraphWire.typeRef(reference, "$"), List.of(),
                    ValueProcessingFailureKind.UNRESOLVED, "Unresolved", obligations);
        }
        private void raise(SemanticTypes.ValueDecision decision, WireValue reference) {
            if (decision instanceof SemanticTypes.Rejected rejected) throw new ValueRejection(rejected.failure());
            if (decision instanceof SemanticTypes.Unresolved unresolved) unresolved(reference, unresolved.obligations());
        }
        private void raise(SemanticValidation.ValidationFailure failure, WireValue reference) {
            if (failure instanceof SemanticValidation.ValueRejected rejected) throw new ValueRejection(rejected.failure());
            if (failure instanceof SemanticValidation.ValidationUnresolved unresolved) unresolved(reference, unresolved.obligations());
            throw new ValueProcessingFailure(SemanticGraphWire.typeRef(reference, "$"), List.of(),
                    ValueProcessingFailureKind.CERTIFICATE_MISMATCH, ((SemanticValidation.CertificateMismatch) failure).condition());
        }
        synchronized void meaning(int index) {
            WireValue reference = reference(index);
            List<SemanticTypes.SemanticObligation> obligations =
                    SemanticValidation.meaningObligations(tables, List.of(SemanticGraphWire.typeRef(reference, "$")));
            Optional<SemanticTypes.SemanticObligation> first = obligations.stream()
                    .filter(obligation -> meaningPredicate(obligation.reason()) != null).findFirst();
            if (first.isPresent()) throw new ValueProcessingFailure(first.get().typeRef(), List.of(),
                    ValueProcessingFailureKind.UNRESOLVED, meaningPredicate(first.get().reason()), List.of(first.get()));
        }
        /** Reads the text as the wire value; a text that is not JSON or repeats an object key fails with a WireException. */
        public WireValue decode(WireValue reference, String text) throws ValueRejection {
            WireValue value = SemanticGeneration.readJson(text);
            validate(reference, value); return value;
        }
        public DefaultedValue decodeWithDefaults(WireValue reference, String text) throws ValueRejection {
            return materializeDefaults(reference, SemanticGeneration.readJson(text));
        }
        public void validate(WireValue reference, WireValue value) throws ValueRejection {
            raise(SemanticValidation.acceptsValue(tables, SemanticGraphWire.typeRef(reference, "$"), WireJson.fromWire(value)), reference);
        }
        /** Validates the value once and returns it as a checked value. */
        public Checked check(WireValue reference, WireValue value) throws ValueRejection {
            validate(reference, value);
            return new Checked(this, reference, new Present<>(value));
        }
        /** Reads the text and validates the value once. */
        public Checked decodeChecked(WireValue reference, String text) throws ValueRejection {
            return check(reference, SemanticGeneration.readJson(text));
        }
        /** Reads the text, materializes its defaults, and returns the validated result as a checked value. */
        public Checked decodeCheckedWithDefaults(WireValue reference, String text) throws ValueRejection {
            return new Checked(this, reference, new Present<>(materializeDefaults(reference, SemanticGeneration.readJson(text)).value()));
        }
        /** Validates the slot once and returns it as a checked slot. */
        public Checked checkSlot(WireValue reference, boolean required, boolean nullable, Slot<WireValue> value) throws ValueRejection {
            validateSlot(reference, required, nullable, value);
            return new Checked(this, reference, value);
        }
        /**
         * Reads the bytes of a leaf of a checked value without validating again.
         * The leaf must be the checked value or lie inside it, and the checked value must come from this context.
         * @throws IllegalArgumentException if either does not hold
         */
        public Bytes bytes(Checked parent, WireValue leaf) {
            Objects.requireNonNull(parent, "parent");
            Objects.requireNonNull(leaf, "leaf");
            if (parent.context() != this) throw new IllegalArgumentException("The checked value belongs to another context");
            if (!parent.contains(leaf)) throw new IllegalArgumentException("The leaf is not inside the checked value");
            String encoding = bytesText(leaf);
            return new Bytes(decodeBase64(encoding), encoding);
        }
        public Bytes decodeBytes(WireValue reference, WireValue value) throws ValueRejection {
            validate(reference, value);
            String encoding = bytesText(value);
            return new Bytes(decodeBase64(encoding), encoding);
        }
        public WireValue encodeBytes(Bytes value) {
            SemanticTypes.BytesPolicy policy = typed.profile().bytesPolicy().orElseGet(() -> new SemanticTypes.BytesPolicy(
                    typed.profile().reference(), false, SemanticTypes.BytesAlphabet.STANDARD, true, Optional.empty()));
            String text = value.wire().filter(wire -> SemanticValidation.base64Length(policy, wire).isPresent()
                    && java.util.Arrays.equals(base64Bytes(wire), value.value()))
                    .orElseGet(() -> base64Text(policy.alphabet(), value.value()));
            return policy.wrapper().isPresent() ? wrapText(policy.wrapper().get(), text) : str(text);
        }
        private static String base64Text(SemanticTypes.BytesAlphabet alphabet, byte[] data) {
            return (alphabet == SemanticTypes.BytesAlphabet.URL_SAFE ? Base64.getUrlEncoder() : Base64.getEncoder()).encodeToString(data);
        }
        private static byte[] base64Bytes(String text) {
            int padding = text.indexOf('=');
            String body = padding < 0 ? text : text.substring(0, padding);
            return Base64.getDecoder().decode(body.replace('-', '+').replace('_', '/'));
        }
        private WireValue wrapText(String name, String text) {
            return typed.profile().wrappers().stream().filter(candidate -> candidate.name().equals(name)).findFirst()
                    .<WireValue>map(wrapper -> obj(wrapper.key(), str(text))).orElseGet(() -> str(text));
        }
        private Optional<String> stringWrapper(WireValue reference) {
            Optional<SemanticTypes.TypeNode> node = typed.findType(SemanticGraphWire.typeRef(reference, "$"));
            if (node.isEmpty() || !(node.get().shape() instanceof SemanticTypes.StringShape string))
                throw new ValueProcessingFailure(SemanticGraphWire.typeRef(reference, "$"), List.of(), ValueProcessingFailureKind.UNRESOLVED,
                        "Unresolved", List.of(SemanticValidation.obligationAt(typed, SemanticGraphWire.typeRef(reference, "$"), List.of(),
                                new SemanticTypes.UnresolvedType())));
            return string.spec().wrapper();
        }
        public String decodeText(WireValue reference, WireValue value) {
            Optional<String> wrapper = stringWrapper(reference);
            if (wrapper.isEmpty()) return s(value);
            SemanticTypes.Wrapper found = typed.profile().wrappers().stream().filter(candidate -> candidate.name().equals(wrapper.get()))
                    .findFirst().orElseThrow(() -> new ValueProcessingFailure(SemanticGraphWire.typeRef(reference, "$"), List.of(),
                            ValueProcessingFailureKind.UNRESOLVED, "Unresolved", List.of(SemanticValidation.obligationAt(typed,
                                    SemanticGraphWire.typeRef(reference, "$"), List.of(), new SemanticTypes.UnknownWrapper(wrapper.get())))));
            return s(f(value, found.key()));
        }
        public BigInteger integerValue(WireValue reference, WireValue value) {
            TypeRef ref = SemanticGraphWire.typeRef(reference, "$");
            Optional<SemanticTypes.TypeNode> node = typed.findType(ref);
            if (node.isEmpty() || !(node.get().shape() instanceof SemanticTypes.IntegerShape integer))
                throw new ValueProcessingFailure(ref, List.of(), ValueProcessingFailureKind.UNRESOLVED, "Unresolved",
                        List.of(SemanticValidation.obligationAt(typed, ref, List.of(), new SemanticTypes.UnresolvedType())));
            return SemanticValidation.integerValueForDomain(tables, integer.spec().domain(), WireJson.fromWire(value))
                    .orElseThrow(() -> new ValueProcessingFailure(ref, List.of(), ValueProcessingFailureKind.CERTIFICATE_MISMATCH, "validated integer"));
        }
        public WireValue encodeText(WireValue reference, String value) {
            Optional<String> wrapper = stringWrapper(reference);
            return wrapper.isPresent() ? wrapText(wrapper.get(), value) : str(value);
        }
        public int selectBranch(WireValue reference, WireValue value) {
            return selectBranch(SemanticGraphWire.typeRef(reference, "$"), WireJson.fromWire(value));
        }
        public int selectBranch(TypeRef reference, JsonValue value) {
            TypeRef ref = reference;
            Set<TypeRef> visited = new HashSet<>();
            while (visited.add(ref)) {
                java.util.Optional<SemanticTypes.TypeNode> node = typed.findType(ref);
                if (node.isEmpty()) return -1;
                if (node.get().shape() instanceof SemanticTypes.AliasShape alias) { ref = alias.target(); continue; }
                if (!(node.get().shape() instanceof SemanticTypes.TaggedUnionShape union)) return -1;
                return SemanticValidation.selectUnionBranchIndex(tables, union.spec(), value);
            }
            return -1;
        }
        public void validateSlot(WireValue reference, boolean required, boolean nullable, Slot<WireValue> value) throws ValueRejection {
            validateSlot(new SlotContract(SemanticGraphWire.typeRef(reference, "$"), required, nullable), WireJson.fromWireSlot(value));
        }
        public void validateSlot(SlotContract contract, Slot<JsonValue> value) throws ValueRejection {
            raise(SemanticValidation.acceptsSlot(tables, contract, value), SemanticGraphWire.typeRefWire(contract.typeRef()));
        }
        public SemanticValidation.ValidationFailure slotFailure(SlotContract contract, Slot<JsonValue> value) {
            SemanticTypes.ValueDecision decision = SemanticValidation.acceptsSlot(tables, contract, value);
            if (decision instanceof SemanticTypes.Rejected rejected) return new SemanticValidation.ValueRejected(rejected.failure());
            if (decision instanceof SemanticTypes.Unresolved unresolved) return new SemanticValidation.ValidationUnresolved(unresolved.obligations());
            return null;
        }
        private String bytesText(WireValue value) {
            return SemanticValidation.bytesText(tables, WireJson.fromWire(value)).orElse(null);
        }
        private byte[] decodeBase64(String text) {
            if (text == null || typed.profile().bytesPolicy().isEmpty()
                    || SemanticValidation.base64Length(typed.profile().bytesPolicy().get(), text).isEmpty()) return null;
            int padding = text.indexOf('=');
            String body = padding < 0 ? text : text.substring(0, padding);
            return Base64.getDecoder().decode(body.replace('-', '+').replace('_', '/'));
        }
        private static DefaultApplication wireApplication(SemanticValidation.DefaultApplication application) {
            return new DefaultApplication(application.valuePath().stream().map(SemanticGraphWire::pathStepWire).toList(),
                    SemanticGraphWire.typeRefWire(application.typeRef()),
                    obj("source", SemanticGraphWire.sourceRefWire(application.origin().source()), "pointer", arr(application.origin().pointer().stream().map(SemanticValues::str).toList())),
                    WireJson.toWire(application.value()));
        }
        private static SemanticValidation.DefaultApplication typedApplication(DefaultApplication application) {
            return new SemanticValidation.DefaultApplication(application.valuePath().stream().map(SemanticGraphWire::pathStep).toList(),
                    SemanticGraphWire.typeRef(application.typeRef(), "$"),
                    new SemanticTypes.OccurrenceRef(SemanticGraphWire.sourceRef(f(application.origin(), "source"), "$.source"),
                    a(f(application.origin(), "pointer")).stream().map(SemanticValues::s).toList()), WireJson.fromWire(application.value()));
        }
        public boolean checkDefaultApplications(WireValue before, WireValue after, List<DefaultApplication> applications) {
            return SemanticValidation.checkDefaultApplications(tables, WireJson.fromWire(before), WireJson.fromWire(after),
                    applications.stream().map(Context::typedApplication).toList());
        }
        public DefaultedValue materializeDefaults(WireValue reference, WireValue value) throws ValueRejection {
            SemanticValidation.Except<SemanticValidation.DefaultedValue> result =
                    SemanticValidation.materializeDefaults(tables, SemanticGraphWire.typeRef(reference, "$"), WireJson.fromWire(value));
            if (result instanceof SemanticValidation.Failed<SemanticValidation.DefaultedValue> failed) {
                if (failed.failure() instanceof SemanticValidation.ValidationUnresolved unresolved
                        && unresolved.obligations().stream().noneMatch(obligation -> obligation.reason() instanceof SemanticTypes.MembershipBound))
                    throw new ValueProcessingFailure(SemanticGraphWire.typeRef(reference, "$"), List.of(),
                            ValueProcessingFailureKind.UNRESOLVED, "Unresolved", unresolved.obligations());
                raise(failed.failure(), reference);
            }
            SemanticValidation.DefaultedValue defaulted = ((SemanticValidation.Ok<SemanticValidation.DefaultedValue>) result).value();
            return new DefaultedValue(WireJson.toWire(defaulted.value()), defaulted.applications().stream().map(Context::wireApplication).toList());
        }
    }

    static boolean ascii(String text) { return text.codePoints().allMatch(c -> c < 128); }

    /** The Lean list append of one element, as an immutable copy. */
    public static <T> List<T> append(List<T> items, T item) {
        List<T> result = new ArrayList<>(items);
        result.add(item);
        return List.copyOf(result);
    }
}
