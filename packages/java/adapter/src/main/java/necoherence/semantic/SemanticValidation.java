// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.function.Function;
import necoherence.composition.SemanticComposition.DefinitionRef;
import necoherence.composition.SemanticComposition.Field;
import necoherence.composition.SemanticComposition.Index;
import necoherence.composition.SemanticComposition.Variant;
import necoherence.composition.SemanticComposition.PathStep;
import necoherence.composition.SemanticComposition.SlotContract;
import necoherence.composition.SemanticComposition.TypeRef;
import necoherence.semantic.SemanticTypes.*;
import necoherence.semantic.ExactJson.*;
import static necoherence.semantic.ExactJson.NIL;
import static necoherence.semantic.ExactJson.unicodeValid;
import necoherence.semantic.SemanticValues.Absent;
import necoherence.semantic.SemanticValues.DecimalNumber;
import necoherence.semantic.SemanticValues.FormatCondition;
import necoherence.semantic.SemanticValues.InvalidWrapper;
import necoherence.semantic.SemanticValues.KeyFormat;
import necoherence.semantic.SemanticValues.NormalizedDecimal;
import necoherence.semantic.SemanticValues.NullSlot;
import necoherence.semantic.SemanticValues.Present;
import necoherence.semantic.SemanticValues.SimpleValueCondition;
import necoherence.semantic.SemanticValues.Slot;
import necoherence.semantic.SemanticValues.UnexpectedField;
import necoherence.semantic.SemanticValues.DuplicateField;
import necoherence.semantic.SemanticValues.ValueCondition;
import necoherence.semantic.SemanticValues.WrongValueKind;

public final class SemanticValidation {
    private SemanticValidation() {}

    public sealed interface Except<T> permits Ok, Failed {}
    public record Ok<T>(T value) implements Except<T> {}
    public record Failed<T>(ValidationFailure failure) implements Except<T> {}

    public sealed interface ValidationFailure permits ValueRejected, ValidationUnresolved, CertificateMismatch {}
    public record ValueRejected(ValueFailure failure) implements ValidationFailure {}
    public record ValidationUnresolved(List<SemanticObligation> obligations) implements ValidationFailure {
        public ValidationUnresolved { obligations = List.copyOf(obligations); }
    }
    public record CertificateMismatch(String condition) implements ValidationFailure {}

    public record MemberProof(List<MemberProof> children) {
        public MemberProof { children = List.copyOf(children); }
    }

    public record MemberCertificate(ProfileRef profile, List<SemanticTypes.SourceRef> sourceRefs, SlotContract contract,
            Slot<JsonValue> value, Optional<MemberProof> proof) {}

    public sealed interface MembershipResult permits MemberAccepted, MemberRejected, MemberUnresolved, MemberInvalidCertificate {}
    public record MemberAccepted(MemberProof proof) implements MembershipResult {}
    public record MemberRejected(ValueFailure failure) implements MembershipResult {}
    public record MemberUnresolved(List<SemanticObligation> obligations) implements MembershipResult {
        public MemberUnresolved { obligations = List.copyOf(obligations); }
    }
    public record MemberInvalidCertificate(String condition) implements MembershipResult {}

    public static final class ValidatedValue {
        private final MemberProof proof;
        private ValidatedValue(MemberProof proof) { this.proof = Objects.requireNonNull(proof); }
        public MemberProof proof() { return proof; }
    }
    public static final class ValidatedSlot {
        private final MemberCertificate certificate;
        private ValidatedSlot(MemberCertificate certificate) { this.certificate = Objects.requireNonNull(certificate); }
        public MemberCertificate certificate() { return certificate; }
    }

    public record ValueRequirement(TypeRef typeRef, List<PathStep> valuePath, JsonValue value) {
        public ValueRequirement { valuePath = List.copyOf(valuePath); }
    }

    public sealed interface Expansion permits Requirements, Rejection, Unresolution {}
    public record Requirements(List<ValueRequirement> children) implements Expansion {
        public Requirements { children = List.copyOf(children); }
    }
    public record Rejection(ValueFailure failure) implements Expansion {}
    public record Unresolution(List<SemanticObligation> obligations) implements Expansion {
        public Unresolution { obligations = List.copyOf(obligations); }
    }

    public record DataFailure(List<PathStep> path, ValueCondition condition, JsonValue observed) {
        public DataFailure { path = List.copyOf(path); }
    }

    public record MemberFailure(String key, ValueCondition condition, JsonValue observed) {}

    private static final JsonValue NULL = NIL;

    public static Optional<JsonValue> memberValue(String key, List<JsonMember> members) {
        return memberValue(key, members, JsonMember::key, JsonMember::value);
    }

    public static <M, V> Optional<V> memberValue(String key, List<M> members, Function<M, String> keyOf, Function<M, V> valueOf) {
        for (M member : members) if (keyOf.apply(member).equals(key)) return Optional.of(valueOf.apply(member));
        return Optional.empty();
    }

    static Optional<String> firstRepeated(List<String> seen, List<String> keys) {
        Set<String> visited = new HashSet<>(seen);
        for (String key : keys) if (!visited.add(key)) return Optional.of(key);
        return Optional.empty();
    }

    static long utf8Length(String text) {
        long length = 0;
        for (int index = 0; index < text.length(); index++) {
            char c = text.charAt(index);
            if (c < 0x80) length++;
            else if (c < 0x800) length += 2;
            else if (Character.isHighSurrogate(c) && index + 1 < text.length() && Character.isLowSurrogate(text.charAt(index + 1))) {
                length += 4;
                index++;
            } else if (Character.isSurrogate(c)) length++;
            else length += 3;
        }
        return length;
    }

    public static BigInteger jsonSize(JsonValue value) {
        long size = 0;
        java.util.ArrayDeque<JsonValue> pending = new java.util.ArrayDeque<>();
        pending.push(value);
        while (!pending.isEmpty()) {
            JsonValue current = pending.pop();
            size++;
            if (current instanceof JsonArr array) for (JsonValue item : array.items()) pending.push(item);
            else if (current instanceof JsonObj object) for (JsonMember member : object.members()) pending.push(member.value());
        }
        return BigInteger.valueOf(size);
    }

    public static boolean formatAcceptsFast(Optional<SemanticTypes.GraphemeRules> graphemeRules, FormatRule rule, String text) {
        return SemanticFormats.accepts(graphemeRules, rule, text);
    }

    private static int base64Digit(BytesAlphabet alphabet, int c) {
        if ('A' <= c && c <= 'Z') return c - 'A';
        if ('a' <= c && c <= 'z') return c - 'a' + 26;
        if ('0' <= c && c <= '9') return c - '0' + 52;
        return switch (alphabet) {
            case STANDARD -> c == '+' ? 62 : c == '/' ? 63 : -1;
            case URL_SAFE -> c == '-' ? 62 : c == '_' ? 63 : -1;
            case EITHER -> c == '+' || c == '-' ? 62 : c == '/' || c == '_' ? 63 : -1;
        };
    }

    static Optional<Long> base64Length(BytesPolicy policy, String text) {
        int body = text.indexOf('=');
        if (body < 0) body = text.length();
        int padding = text.length() - body;
        for (int index = body; index < text.length(); index++) if (text.charAt(index) != '=') return Optional.empty();
        if (padding > 2) return Optional.empty();
        int last = -1;
        for (int index = 0; index < body; index++) if ((last = base64Digit(policy.alphabet(), text.charAt(index))) < 0) return Optional.empty();
        int remainder = body % 4;
        if (remainder == 1 || policy.strictPadBits() && body > 0
                && !(remainder == 2 ? last % 16 == 0 : remainder == 3 ? last % 4 == 0 : true))
            return Optional.empty();
        if (padding > 0 && ((body + padding) % 4 != 0 || padding != (4 - remainder) % 4)) return Optional.empty();
        if (padding == 0 && !policy.paddingOptional() && remainder != 0) return Optional.empty();
        return Optional.of((long) (body / 4 * 3 + (remainder == 0 ? 0 : remainder - 1)));
    }

    static Optional<NormalizedDecimal> decimalIntegerParts(String text) {
        if (!SemanticValues.isJsonNumberSpelling(text)) return Optional.empty();
        return SemanticValues.parseLeanNumber(text).map(SemanticValues::normalize)
                .filter(parts -> parts.digits().signum() == 0
                        || parts.power().compareTo(BigInteger.valueOf(parts.digits().toString().length())) >= 0);
    }

    static Optional<BigInteger> decimalInteger(String text) {
        return decimalIntegerParts(text).flatMap(SemanticValues::integralValue);
    }

    static String trimAscii(String text) {
        int start = 0, end = text.length();
        while (start < end && " \t\n\r\u000B\f".indexOf(text.charAt(start)) >= 0) start++;
        while (end > start && " \t\n\r\u000B\f".indexOf(text.charAt(end - 1)) >= 0) end--;
        return text.substring(start, end);
    }

    static Optional<BigInteger> integerValueForForm(IntegerForm form, JsonValue value) {
        if (form == IntegerForm.NUMBER && value instanceof JsonNum integer) return Optional.of(integer.value());
        if (form == IntegerForm.INTEGRAL_DECIMAL && value instanceof JsonDec decimal) return decimalInteger(decimal.text());
        if (form == IntegerForm.DECIMAL_STRING && value instanceof JsonStr text) return decimalInteger(text.value());
        return Optional.empty();
    }

    static Optional<IntegerDomainBinding> integerBinding(ValidationTables tables, Optional<String> domain) {
        return tables.integerBinding(domain);
    }

    static Optional<BigInteger> integerValueForBinding(IntegerDomainBinding binding, JsonValue value) {
        for (IntegerForm form : binding.forms()) {
            Optional<BigInteger> found = integerValueForForm(form, value);
            if (found.isPresent()) return found;
        }
        return Optional.empty();
    }

    static Optional<BigInteger> integerValueForDomain(ValidationTables tables, Optional<String> domain, JsonValue value) {
        return integerBinding(tables, domain).flatMap(binding -> integerValueForBinding(binding, value));
    }

    static boolean integerRangeAccepts(IntegerDomain range, BigInteger value) {
        if (range instanceof InclusiveDomain inclusive)
            return inclusive.minimum().compareTo(value) <= 0 && value.compareTo(inclusive.maximum()) <= 0;
        return true;
    }

    private static boolean jsonDigit(char character) { return '0' <= character && character <= '9'; }

    private static boolean jsonWholeNumber(String characters) {
        if (characters.isEmpty()) return false;
        if (characters.charAt(0) == '0') return characters.length() == 1;
        if (characters.charAt(0) < '1' || characters.charAt(0) > '9') return false;
        return characters.chars().skip(1).allMatch(c -> jsonDigit((char) c));
    }

    private static int significantDigits(String digits) {
        int start = 0;
        while (start < digits.length() && digits.charAt(start) == '0') start++;
        return digits.length() - start;
    }

    static boolean decimalMagnitudeExceedsRangeDigits(BigInteger minimum, BigInteger maximum, String text) {
        String unsigned = text.startsWith("-") ? text.substring(1) : text;
        if (unsigned.startsWith("+")) return false;
        String[] lowercase = unsigned.split("e", -1);
        String[] parts = lowercase.length == 2 ? lowercase : unsigned.split("E", -1);
        if (parts.length != 2) return false;
        String exponentText = parts[1];
        String exponentDigits = exponentText.startsWith("+") ? exponentText.substring(1) : exponentText;
        if (exponentDigits.startsWith("-") || exponentDigits.isEmpty()
                || !exponentDigits.chars().allMatch(c -> jsonDigit((char) c))) return false;
        BigInteger exponent = new BigInteger(exponentDigits);
        String[] number = parts[0].split("\\.", -1);
        BigInteger limit = minimum.abs().max(maximum.abs());
        BigInteger limitDigits = BigInteger.valueOf(limit.toString().length());
        if (number.length == 1) {
            if (!jsonWholeNumber(number[0])) return false;
            int significant = significantDigits(number[0]);
            if (significant == 0) return false;
            return BigInteger.valueOf(significant).add(exponent).compareTo(limitDigits) > 0;
        }
        if (number.length == 2) {
            String whole = number[0], fraction = number[1];
            if (!jsonWholeNumber(whole) || fraction.isEmpty() || !fraction.chars().allMatch(c -> jsonDigit((char) c))
                    || exponent.compareTo(BigInteger.valueOf(fraction.length())) < 0) return false;
            int significant = significantDigits(whole + fraction);
            if (significant == 0) return false;
            return BigInteger.valueOf(significant).add(exponent).subtract(BigInteger.valueOf(fraction.length()))
                    .compareTo(limitDigits) > 0;
        }
        return false;
    }

    private sealed interface InRange permits NotInteger, OutOfDomain, InDomain {}
    private record NotInteger() implements InRange {}
    private record OutOfDomain() implements InRange {}
    private record InDomain(BigInteger value) implements InRange {}

    private static InRange integerValueForBindingInRange(IntegerDomainBinding binding, JsonValue value) {
        if (binding.range() instanceof UnboundedDomain) {
            Optional<BigInteger> found = integerValueForBinding(binding, value);
            return found.isPresent() ? new InDomain(found.get()) : new NotInteger();
        }
        InclusiveDomain range = (InclusiveDomain) binding.range();
        boolean exceeds = false;
        if (value instanceof JsonDec decimal)
            exceeds = binding.forms().contains(IntegerForm.INTEGRAL_DECIMAL)
                    && decimalMagnitudeExceedsRangeDigits(range.minimum(), range.maximum(), decimal.text());
        else if (value instanceof JsonStr text)
            exceeds = binding.forms().contains(IntegerForm.DECIMAL_STRING)
                    && decimalMagnitudeExceedsRangeDigits(range.minimum(), range.maximum(), text.value());
        if (exceeds) return new OutOfDomain();
        Optional<BigInteger> found = integerValueForBinding(binding, value);
        if (found.isEmpty()) return new NotInteger();
        return integerRangeAccepts(range, found.get()) ? new InDomain(found.get()) : new OutOfDomain();
    }

    static boolean integerInDomain(ValidationTables tables, Optional<String> domain, JsonValue value) {
        Optional<IntegerDomainBinding> binding = integerBinding(tables, domain);
        return binding.isPresent() && integerValueForBindingInRange(binding.get(), value) instanceof InDomain;
    }

    static Optional<ValueCondition> integerCondition(ValidationTables tables, IntegerSpec spec, JsonValue value) {
        Optional<IntegerDomainBinding> binding = integerBinding(tables, spec.domain());
        if (binding.isEmpty()) return Optional.of(SimpleValueCondition.INTEGER_DOMAIN);
        InRange found = integerValueForBindingInRange(binding.get(), value);
        if (found instanceof NotInteger) return Optional.of(new WrongValueKind("integer"));
        if (found instanceof OutOfDomain) return Optional.of(SimpleValueCondition.INTEGER_DOMAIN);
        BigInteger integer = ((InDomain) found).value();
        if (spec.constValue().map(constant -> !constant.equals(integer)).orElse(false))
            return Optional.of(SimpleValueCondition.CONST_MISMATCH);
        if (spec.enumValues().map(values -> !enumContains(tables, values, integer)).orElse(false))
            return Optional.of(SimpleValueCondition.ENUM_MISMATCH);
        if (spec.minimum().map(minimum -> integer.compareTo(minimum) < 0).orElse(false))
            return Optional.of(SimpleValueCondition.BELOW_MINIMUM);
        if (spec.maximum().map(maximum -> maximum.compareTo(integer) < 0).orElse(false))
            return Optional.of(SimpleValueCondition.ABOVE_MAXIMUM);
        return Optional.empty();
    }

    static boolean lengthAccepts(Optional<BigInteger> minimum, Optional<BigInteger> maximum, long length) {
        BigInteger size = BigInteger.valueOf(length);
        return minimum.map(bound -> bound.compareTo(size) <= 0).orElse(true)
                && maximum.map(bound -> size.compareTo(bound) <= 0).orElse(true);
    }

    static Optional<Long> lengthInUnit(ValidationTables tables, StringLengthUnit unit, String value) {
        return tables.formatLength(unit, value);
    }

    /** The length of a value in a unit; a grapheme count needs the tables grapheme rules and is absent without them (Lean formatLength). */
    static Optional<Long> formatLength(Optional<SemanticGraphemes.Table> graphemeRules, StringLengthUnit unit, String value) {
        return switch (unit) {
            case UTF8_BYTES -> Optional.of(utf8Length(value));
            case UNICODE_SCALARS -> Optional.of((long) value.codePointCount(0, value.length()));
            case GRAPHEMES -> graphemeRules.map(table -> (long) SemanticGraphemes.graphemeLength(table, value));
        };
    }

    static Optional<ValueCondition> lengthBoundsFailure(ValidationTables tables, String value, List<LengthBound> bounds) {
        for (LengthBound bound : bounds) {
            Optional<Long> length = lengthInUnit(tables, bound.unit(), value);
            if (length.isEmpty()) return Optional.of(SimpleValueCondition.STRING_LENGTH);
            if (!lengthAccepts(bound.minimum(), bound.maximum(), length.get()))
                return Optional.of(SimpleValueCondition.STRING_LENGTH);
        }
        return Optional.empty();
    }

    static Optional<String> duplicateKey(List<JsonMember> members) {
        Set<String> visited = new HashSet<>();
        for (JsonMember member : members) if (!visited.add(member.key())) return Optional.of(member.key());
        return Optional.empty();
    }

    static final class Members {
        private final List<JsonMember> members;
        private Map<String, JsonValue> byKey;

        Members(List<JsonMember> members) { this.members = members; }

        List<JsonMember> list() { return members; }

        Optional<JsonValue> get(String key) {
            if (members.size() <= 8) return memberValue(key, members);
            if (byKey == null) {
                byKey = new HashMap<>();
                for (JsonMember member : members) byKey.putIfAbsent(member.key(), member.value());
            }
            return Optional.ofNullable(byKey.get(key));
        }
    }

    static Optional<FormatBinding> formatBinding(ValidationTables tables, String name) { return tables.formatBinding(name); }

    private static boolean enumContains(ValidationTables tables, List<?> values, Object value) { return tables.enumContains(values, value); }

    static ObjectClass classOf(ValidationTables tables, List<JsonMember> members) {
        return classOf(tables, new Members(members));
    }

    static ObjectClass classOf(ValidationTables tables, Members members) {
        if (tables.tag().isPresent()) {
            TagModel tag = tables.tag().get();
            Optional<JsonValue> value = members.get(tag.key());
            if (value.isPresent() && value.get() instanceof JsonStr text) {
                Optional<SealedForm> form = tag.sealed().stream().filter(candidate -> candidate.tag().equals(text.value())).findFirst();
                if (form.isPresent()) return new SealedClass(form.get());
            }
        }
        for (Wrapper candidate : tables.wrappers()) if (members.get(candidate.key()).isPresent()) return new WrapperClass(candidate);
        return new OrdinaryClass();
    }

    static boolean namedFormatAccepts(ValidationTables tables, String name, String value) {
        Optional<FormatBinding> binding = formatBinding(tables, name);
        return binding.isPresent() && tables.formatAccepts(binding.get().rule(), value);
    }

    static Optional<Wrapper> textWrapper(ValidationTables tables) {
        return tables.wrappers().stream().filter(wrapper -> wrapper.payload() instanceof TextPayload).findFirst();
    }

    static boolean wrapperTextAccepts(ValidationTables tables, JsonValue value) {
        return textWrapper(tables).map(wrapper -> wrapperPayloadText(tables, wrapper, value).isPresent()).orElse(false);
    }

    static Optional<String> wrapperPayloadText(ValidationTables tables, Wrapper wrapper, JsonValue value) {
        if (!(value instanceof JsonObj object) || object.members().size() != 1
                || !(object.members().getFirst().value() instanceof JsonStr text)) return Optional.empty();
        if (!object.members().getFirst().key().equals(wrapper.key())) return Optional.empty();
        if (wrapper.payload() instanceof BytesPayload) {
            if (tables.bytesPolicy().isEmpty()) return Optional.empty();
            return base64Length(tables.bytesPolicy().get(), text.value()).isPresent() ? Optional.of(text.value()) : Optional.empty();
        }
        Optional<String> format = ((TextPayload) wrapper.payload()).format();
        if (format.isEmpty()) return unicodeValid(text.value()) ? Optional.of(text.value()) : Optional.empty();
        return unicodeValid(text.value()) && namedFormatAccepts(tables, format.get(), text.value())
                ? Optional.of(text.value()) : Optional.empty();
    }

    static Optional<ValueCondition> wrapperPayloadFailure(ValidationTables tables, Wrapper wrapper, JsonValue value) {
        if (wrapperPayloadText(tables, wrapper, value).isPresent()) return Optional.empty();
        if (wrapper.payload() instanceof BytesPayload) return Optional.of(SimpleValueCondition.INVALID_BYTES);
        Optional<String> format = ((TextPayload) wrapper.payload()).format();
        return Optional.of(format.isEmpty() ? new WrongValueKind("wrapper text") : new FormatCondition(format.get()));
    }

    private static Optional<ValueCondition> sealedStringCondition(ValidationTables tables, StringSpec spec, String value) {
        if (!unicodeValid(value)) return Optional.of(SimpleValueCondition.INVALID_DATA_MODEL);
        if (spec.constValue().map(constant -> !constant.equals(value)).orElse(false))
            return Optional.of(SimpleValueCondition.CONST_MISMATCH);
        if (spec.enumValues().map(values -> !enumContains(tables, values, value)).orElse(false))
            return Optional.of(SimpleValueCondition.ENUM_MISMATCH);
        Optional<ValueCondition> length = lengthBoundsFailure(tables, value, spec.lengths());
        if (length.isPresent()) return length;
        if (spec.format().isEmpty()) return Optional.empty();
        if (spec.format().get() instanceof NamedFormat named)
            return namedFormatAccepts(tables, named.name(), value) ? Optional.empty() : Optional.of(new FormatCondition(named.name()));
        return tables.formatAccepts(((InlineFormat) spec.format().get()).rule(), value) ? Optional.empty()
                : Optional.of(new FormatCondition("inline"));
    }

    private static Optional<ValueCondition> sealedIntegerCondition(ValidationTables tables, IntegerSpec spec, JsonNum value) {
        return integerCondition(tables, spec, value);
    }

    static Optional<ValueCondition> sealedLeafFailure(ValidationTables tables, SealedLeaf leaf, JsonValue value) {
        if (leaf instanceof StringLeaf string) {
            if (value instanceof JsonStr text) return sealedStringCondition(tables, string.spec(), text.value());
            if (value instanceof JsonObj object) {
                if (classOf(tables, object.members()) instanceof WrapperClass wrapper) {
                    Optional<String> text = wrapperPayloadText(tables, wrapper.wrapper(), value);
                    if (text.isPresent()) return sealedStringCondition(tables, string.spec(), text.get());
                    return wrapperPayloadFailure(tables, wrapper.wrapper(), value);
                }
                return Optional.of(new WrongValueKind("string"));
            }
            return Optional.of(new WrongValueKind("string"));
        }
        IntegerLeaf integer = (IntegerLeaf) leaf;
        if (value instanceof JsonNum number) return sealedIntegerCondition(tables, integer.spec(), number);
        return Optional.of(new WrongValueKind("integer"));
    }

    static boolean tagValueAccepts(ValidationTables tables, List<JsonMember> members) {
        return tagMemberFailure(tables, members).isEmpty();
    }

    static Optional<MemberFailure> tagMemberFailure(ValidationTables tables, List<JsonMember> members) {
        return tagMemberFailure(tables, new Members(members));
    }

    private static Optional<MemberFailure> tagMemberFailure(ValidationTables tables, Members members) {
        if (tables.tag().isEmpty()) return Optional.empty();
        TagModel tag = tables.tag().get();
        Optional<JsonValue> value = members.get(tag.key());
        if (value.isEmpty()) return Optional.empty();
        if (value.get() instanceof JsonStr text) {
            if (!unicodeValid(text.value()))
                return Optional.of(new MemberFailure(tag.key(), SimpleValueCondition.INVALID_DATA_MODEL, value.get()));
            if (tag.format().isEmpty()) return Optional.empty();
            return namedFormatAccepts(tables, tag.format().get(), text.value()) ? Optional.empty()
                    : Optional.of(new MemberFailure(tag.key(), SimpleValueCondition.INVALID_TAG, value.get()));
        }
        return Optional.of(new MemberFailure(tag.key(), SimpleValueCondition.INVALID_TAG, value.get()));
    }

    static Optional<String> bytesText(ValidationTables tables, JsonValue value) {
        if (tables.bytesPolicy().isEmpty()) return Optional.empty();
        BytesPolicy policy = tables.bytesPolicy().get();
        if (policy.wrapper().isEmpty()) return value instanceof JsonStr string ? Optional.of(string.value()) : Optional.empty();
        Optional<Wrapper> wrapper = tables.wrappers().stream().filter(candidate -> candidate.name().equals(policy.wrapper().get())).findFirst();
        if (wrapper.isEmpty()) return Optional.empty();
        return wrapperPayloadText(tables, wrapper.get(), value);
    }

    static Optional<Long> bytesValueLength(ValidationTables tables, JsonValue value) {
        Optional<String> text = bytesText(tables, value);
        return text.isEmpty() ? Optional.empty() : base64Length(tables.bytesPolicy().get(), text.get());
    }

    static Optional<MemberFailure> sealedFieldFailure(ValidationTables tables, List<JsonMember> members, SealedField field) {
        return sealedFieldFailure(tables, new Members(members), field);
    }

    private static Optional<MemberFailure> sealedFieldFailure(ValidationTables tables, Members members, SealedField field) {
        Optional<JsonValue> value = members.get(field.key());
        if (value.isEmpty()) return field.required()
                ? Optional.of(new MemberFailure(field.key(), SimpleValueCondition.MISSING_REQUIRED, NULL)) : Optional.empty();
        return sealedLeafFailure(tables, field.leaf(), value.get())
                .map(condition -> new MemberFailure(field.key(), condition, value.get()));
    }

    static Optional<MemberFailure> sealedFieldsFailure(ValidationTables tables, SealedForm form, List<JsonMember> members) {
        return sealedFieldsFailure(tables, form, new Members(members));
    }

    private static Optional<MemberFailure> sealedFieldsFailure(ValidationTables tables, SealedForm form, Members members) {
        for (SealedField field : form.fields()) {
            Optional<MemberFailure> failure = sealedFieldFailure(tables, members, field);
            if (failure.isPresent()) return failure;
        }
        return Optional.empty();
    }

    private static boolean sealedKnownField(ValidationTables tables, TagModel tag, SealedForm form, String key) {
        return key.equals(tag.key()) || tables.sealedKnownKey(form, key);
    }

    static Optional<DataFailure> objectMemberFailure(ValidationTables tables, List<JsonMember> members) {
        return objectMemberFailure(tables, new Members(members));
    }

    private static Optional<DataFailure> objectMemberFailure(ValidationTables tables, Members members) {
        Optional<String> repeated = duplicateKey(members.list());
        if (repeated.isPresent())
            return Optional.of(new DataFailure(List.of(), new DuplicateField(repeated.get()), new JsonObj(members.list())));
        return tagMemberFailure(tables, members).map(failure ->
                new DataFailure(List.of(new Field(failure.key())), failure.condition(), failure.observed()));
    }

    static final class ValuePath {
        private final ValuePath parent;
        private final PathStep step;
        private final List<PathStep> base;
        final int depth;

        private ValuePath(ValuePath parent, PathStep step, List<PathStep> base, int depth) {
            this.parent = parent;
            this.step = step;
            this.base = base;
            this.depth = depth;
        }

        static ValuePath of(List<PathStep> base) { return new ValuePath(null, null, base, base.size()); }

        ValuePath then(PathStep next) { return new ValuePath(this, next, null, depth + 1); }

        List<PathStep> steps() {
            PathStep[] steps = new PathStep[depth];
            ValuePath at = this;
            for (; at.parent != null; at = at.parent) steps[at.depth - 1] = at.step;
            for (int index = 0; index < at.depth; index++) steps[index] = at.base.get(index);
            return List.of(steps);
        }
    }

    private static List<PathStep> concatenate(List<PathStep> left, List<PathStep> right) {
        List<PathStep> result = new ArrayList<>(left);
        result.addAll(right);
        return result;
    }

    static boolean dataValueAccepts(ValidationTables tables, JsonValue value) {
        return dataValueFailure(tables, List.of(), value).isEmpty();
    }

    static Optional<DataFailure> dataValueFailure(ValidationTables tables, List<PathStep> path, JsonValue value) {
        return dataValueFailure(tables, ValuePath.of(path), value);
    }

    private static Optional<DataFailure> dataValueFailure(ValidationTables tables, ValuePath path, JsonValue value) {
        java.util.ArrayDeque<DataTask> pending = new java.util.ArrayDeque<>();
        pending.push(new DataValueTask(path, value));
        return runDataTasks(tables, pending);
    }

    /** A pending data check: a value, or a member of an object that is checked for its key and then its value. */
    private sealed interface DataTask permits DataValueTask, DataMemberTask {}
    private record DataValueTask(ValuePath path, JsonValue value) implements DataTask {}
    private record DataMemberTask(ValuePath path, JsonMember member, Optional<SealedMembership> sealedContext) implements DataTask {}
    private record SealedMembership(TagModel tag, SealedForm form) {}

    /** Runs the pending checks in document order, returning the first failure. */
    private static Optional<DataFailure> runDataTasks(ValidationTables tables, java.util.ArrayDeque<DataTask> pending) {
        while (!pending.isEmpty()) {
            Optional<DataFailure> failure = switch (pending.pop()) {
                case DataValueTask task -> checkDataValue(tables, task.path(), task.value(), pending);
                case DataMemberTask task -> checkDataMember(tables, task, pending);
            };
            if (failure.isPresent()) return failure;
        }
        return Optional.empty();
    }

    private static Optional<DataFailure> checkDataValue(ValidationTables tables, ValuePath path, JsonValue value,
            java.util.ArrayDeque<DataTask> pending) {
        if (value instanceof JsonNum)
            return integerInDomain(tables, Optional.empty(), value) ? Optional.empty()
                    : Optional.of(new DataFailure(path.steps(), SimpleValueCondition.INTEGER_DOMAIN, value));
        if (value instanceof JsonDec decimal) {
            if (SemanticValues.parseLeanNumber(decimal.text()).isEmpty())
                return Optional.of(new DataFailure(path.steps(), SimpleValueCondition.INVALID_DATA_MODEL, value));
            Optional<IntegerDomainBinding> binding = integerBinding(tables, Optional.empty());
            boolean integralUnbounded = binding.isPresent() && binding.get().range() instanceof UnboundedDomain
                    && binding.get().forms().contains(IntegerForm.INTEGRAL_DECIMAL) && decimalIntegerParts(decimal.text()).isPresent();
            if (integralUnbounded) return Optional.empty();
            Optional<ValueCondition> condition = integerCondition(tables,
                    new IntegerSpec(Optional.empty(), Optional.empty(), Optional.empty(), Optional.empty(), Optional.empty(), Optional.empty()), value);
            if (condition.isEmpty()) return Optional.empty();
            if (condition.get() == SimpleValueCondition.INTEGER_DOMAIN)
                return Optional.of(new DataFailure(path.steps(), SimpleValueCondition.INTEGER_DOMAIN, value));
            return tables.numbers().decimals() ? Optional.empty()
                    : Optional.of(new DataFailure(path.steps(), SimpleValueCondition.INVALID_DATA_MODEL, value));
        }
        if (value instanceof JsonStr text)
            return unicodeValid(text.value()) ? Optional.empty()
                    : Optional.of(new DataFailure(path.steps(), SimpleValueCondition.INVALID_DATA_MODEL, value));
        if (value instanceof JsonArr array) {
            for (int index = array.items().size() - 1; index >= 0; index--)
                pending.push(new DataValueTask(path.then(new Index(BigInteger.valueOf(index))), array.items().get(index)));
            return Optional.empty();
        }
        if (value instanceof JsonObj object) {
            Members members = new Members(object.members());
            Optional<DataFailure> member = objectMemberFailure(tables, members);
            if (member.isPresent())
                return Optional.of(new DataFailure(concatenate(path.steps(), member.get().path()), member.get().condition(), member.get().observed()));
            ObjectClass objectClass = classOf(tables, members);
            if (objectClass instanceof WrapperClass wrapper)
                return wrapperPayloadFailure(tables, wrapper.wrapper(), value).map(condition -> new DataFailure(path.steps(), condition, value));
            if (objectClass instanceof SealedClass sealed) {
                Optional<MemberFailure> field = sealedFieldsFailure(tables, sealed.form(), members);
                if (field.isPresent())
                    return Optional.of(new DataFailure(path.then(new Field(field.get().key())).steps(), field.get().condition(), field.get().observed()));
                if (tables.tag().isEmpty()) return Optional.of(new DataFailure(path.steps(), SimpleValueCondition.INVALID_DATA_MODEL, value));
                pushMembers(path, object.members(), Optional.of(new SealedMembership(tables.tag().get(), sealed.form())), pending);
                return Optional.empty();
            }
            pushMembers(path, object.members(), Optional.empty(), pending);
        }
        return Optional.empty();
    }

    private static Optional<DataFailure> checkDataMember(ValidationTables tables, DataMemberTask task, java.util.ArrayDeque<DataTask> pending) {
        JsonMember member = task.member();
        String key = member.key();
        if (task.sealedContext().isPresent()) {
            SealedMembership context = task.sealedContext().get();
            if (sealedKnownField(tables, context.tag(), context.form(), key)) return Optional.empty();
            if (context.form().extras() == SealedExtras.REJECT)
                return Optional.of(new DataFailure(task.path().then(new Field(key)).steps(), new UnexpectedField(key), member.value()));
        }
        if (!unicodeValid(key))
            return Optional.of(new DataFailure(task.path().then(new Field(key)).steps(), SimpleValueCondition.INVALID_DATA_MODEL, member.value()));
        pending.push(new DataValueTask(task.path().then(new Field(key)), member.value()));
        return Optional.empty();
    }

    private static void pushMembers(ValuePath path, List<JsonMember> members, Optional<SealedMembership> sealedContext,
            java.util.ArrayDeque<DataTask> pending) {
        for (int index = members.size() - 1; index >= 0; index--) pending.push(new DataMemberTask(path, members.get(index), sealedContext));
    }

    private static Optional<DataFailure> dataSealedMembersFailure(ValidationTables tables, ValuePath path,
            TagModel tag, SealedForm form, List<JsonMember> members) {
        java.util.ArrayDeque<DataTask> pending = new java.util.ArrayDeque<>();
        pushMembers(path, members, Optional.of(new SealedMembership(tag, form)), pending);
        return runDataTasks(tables, pending);
    }

    private static ValueFailure failureAt(TypeRef ref, List<PathStep> path, Slot<JsonValue> value,
            ValueCondition condition, List<TypeRef> trace) {
        return new ValueFailure(ref, new DefinitionRef(ref.source(), ref.definitionName()),
                new OccurrenceRef(ref.source(), ref.pointer()), path, condition,
                condition == SimpleValueCondition.MISSING_REQUIRED ? new Absent<>() : value, trace);
    }

    private static ValueFailure failureAt(TypeRef ref, List<PathStep> path, Slot<JsonValue> value, ValueCondition condition) {
        return failureAt(ref, path, value, condition, List.of());
    }

    public static SemanticObligation obligationAt(SemanticGraph graph, TypeRef ref, List<PathStep> path, SemanticReason reason) {
        return new SemanticObligation(ref, new OccurrenceRef(ref.source(), ref.pointer()), path,
                graph.profile().reference(), reason);
    }

    static SemanticObligation obligationAt(ValidationTables tables, TypeRef ref, List<PathStep> path, SemanticReason reason) {
        return obligationAt(tables.graph, ref, path, reason);
    }

    static Optional<ValueCondition> stringCondition(ValidationTables tables, StringSpec spec, String value) {
        if (!unicodeValid(value)) return Optional.of(SimpleValueCondition.INVALID_DATA_MODEL);
        if (spec.constValue().map(constant -> !constant.equals(value)).orElse(false))
            return Optional.of(SimpleValueCondition.CONST_MISMATCH);
        if (spec.enumValues().map(values -> !enumContains(tables, values, value)).orElse(false))
            return Optional.of(SimpleValueCondition.ENUM_MISMATCH);
        Optional<ValueCondition> length = lengthBoundsFailure(tables, value, spec.lengths());
        if (length.isPresent()) return length;
        if (spec.format().isEmpty()) return Optional.empty();
        if (spec.format().get() instanceof NamedFormat named) {
            Optional<FormatBinding> binding = formatBinding(tables, named.name());
            if (binding.isEmpty()) return Optional.empty();
            return tables.formatAccepts(binding.get().rule(), value) ? Optional.empty() : Optional.of(new FormatCondition(named.name()));
        }
        return tables.formatAccepts(((InlineFormat) spec.format().get()).rule(), value) ? Optional.empty()
                : Optional.of(new FormatCondition("inline"));
    }

    static Optional<ValueCondition> stringValueCondition(ValidationTables tables, StringSpec spec, JsonValue value) {
        if (spec.wrapper().isEmpty()) {
            if (value instanceof JsonStr text) return stringCondition(tables, spec, text.value());
            return Optional.of(new WrongValueKind("string"));
        }
        if (value instanceof JsonObj object && classOf(tables, new Members(object.members())) instanceof WrapperClass wrapper) {
            if (!wrapper.wrapper().name().equals(spec.wrapper().get())) return Optional.of(new WrongValueKind("string wrapper"));
            Optional<String> text = wrapperPayloadText(tables, wrapper.wrapper(), value);
            if (text.isPresent()) return stringCondition(tables, spec, text.get());
            return wrapperPayloadFailure(tables, wrapper.wrapper(), value);
        }
        return Optional.of(new WrongValueKind("string wrapper"));
    }

    static List<SemanticObligation> nodeMeaningObligations(ValidationTables tables, TypeRef ref) {
        Optional<TypeNode> node = tables.findType(ref);
        if (node.isEmpty()) return List.of(obligationAt(tables, ref, List.of(), new UnresolvedType()));
        List<SemanticObligation> result = new ArrayList<>();
        TypeShape shape = node.get().shape();
        if (shape instanceof StringShape string) {
            StringSpec spec = string.spec();
            if ((spec.lengths().stream().anyMatch(bound -> bound.unit() == StringLengthUnit.GRAPHEMES)
                    || spec.format().map(format -> formatUseUsesGraphemes(tables, format)).orElse(false))
                    && tables.profile.graphemeRules().isEmpty())
                result.add(obligationAt(tables, ref, List.of(), new MissingGraphemeRules()));
            if (spec.format().isPresent() && spec.format().get() instanceof NamedFormat named
                    && tables.profile.formatBindings().stream().noneMatch(binding -> binding.name().equals(named.name())))
                result.add(obligationAt(tables, ref, List.of(), new UnknownFormat(named.name())));
            if (spec.wrapper().isPresent()) {
                Optional<Wrapper> wrapper = tables.profile.wrappers().stream()
                        .filter(candidate -> candidate.name().equals(spec.wrapper().get())).findFirst();
                if (wrapper.isEmpty()) result.add(obligationAt(tables, ref, List.of(), new UnknownWrapper(spec.wrapper().get())));
                else if (wrapper.get().payload() instanceof BytesPayload)
                    result.add(obligationAt(tables, ref, List.of(), new WrapperPayloadReason(spec.wrapper().get())));
            }
        } else if (shape instanceof IntegerShape integer) {
            IntegerSpec spec = integer.spec();
            Optional<IntegerDomainBinding> binding = integerBinding(tables, spec.domain());
            if (binding.isEmpty())
                result.add(obligationAt(tables, ref, List.of(), new UnknownIntegerDomain(spec.domain().orElse(tables.profile.defaultIntegerDomain()))));
            else if (binding.get().range() instanceof InclusiveDomain range
                    && (spec.minimum().map(minimum -> minimum.compareTo(range.minimum()) < 0).orElse(false)
                        || spec.maximum().map(maximum -> range.maximum().compareTo(maximum) < 0).orElse(false)))
                result.add(obligationAt(tables, ref, List.of(), new IntegerBound()));
        } else if (shape instanceof DecimalShape) {
            if (!tables.profile.numbers().decimals()) result.add(obligationAt(tables, ref, List.of(), new DecimalNotAdmitted()));
        } else if (shape instanceof BytesShape || shape instanceof RawBodyShape) {
            if (tables.profile.bytesPolicy().isEmpty()) result.add(obligationAt(tables, ref, List.of(), new MissingBytesPolicy()));
        } else if (shape instanceof SealedShape sealed) {
            if (tables.profile.tag().isEmpty() || tables.profile.tag().get().sealed().stream().noneMatch(form -> form.tag().equals(sealed.tag())))
                result.add(obligationAt(tables, ref, List.of(), new UnknownSealedTag(sealed.tag())));
        } else if (shape instanceof TaggedUnionShape union) {
            if (union.spec().branches().stream().anyMatch(branch -> branch.selector() instanceof InternalTagSelector)
                    && tables.profile.tag().isEmpty())
                result.add(obligationAt(tables, ref, List.of(), new MissingTagModel()));
        } else if (shape instanceof OpaqueShape opaque) {
            result.add(obligationAt(tables, ref, List.of(), new OpaqueType(opaque.typeName())));
        }
        return result;
    }

    private static List<TypeRef> reachableTypes(ValidationTables tables, long fuel, List<TypeRef> pending, List<TypeRef> seen) {
        java.util.LinkedList<TypeRef> queue = new java.util.LinkedList<>(pending);
        java.util.LinkedList<TypeRef> result = new java.util.LinkedList<>(seen);
        HashSet<TypeRef> visited = new HashSet<>(seen);
        while (fuel > 0 && !queue.isEmpty()) {
            TypeRef ref = queue.removeFirst();
            fuel--;
            if (!visited.add(ref)) continue;
            List<TypeRef> children = tables.findType(ref).map(node -> SemanticTypes.typeChildren(node.shape())).orElse(List.of());
            for (int index = children.size() - 1; index >= 0; index--) queue.addFirst(children.get(index));
            result.addFirst(ref);
        }
        return new ArrayList<>(result);
    }

    static List<SemanticObligation> meaningObligations(ValidationTables tables, List<TypeRef> refs) {
        return refs.stream().allMatch(tables::clean) ? List.of() : computeMeaning(tables, refs);
    }

    private static List<SemanticObligation> computeMeaning(ValidationTables tables, List<TypeRef> refs) {
        List<SemanticObligation> result = new ArrayList<>();
        for (TypeRef ref : reachableTypes(tables, refs.size() + tables.graph.nodes().size() + tables.graph.edgeCount() + 1, refs, List.of()))
            result.addAll(nodeMeaningObligations(tables, ref));
        return List.copyOf(result);
    }

    private record Child(TypeRef typeRef, ValuePath path, JsonValue value) {}

    private static Expansion slotRequirements(TypeRef parent, ValuePath path, Members members, List<FieldSpec> fields,
            List<Child> collected) {
        for (FieldSpec field : fields) {
            Optional<JsonValue> value = members.get(field.wireName());
            if (value.isEmpty() && field.slot().required())
                return new Rejection(failureAt(field.slot().typeRef(), path.then(new Field(field.wireName())).steps(), new Absent<>(),
                        SimpleValueCondition.MISSING_REQUIRED));
            if (value.isPresent() && value.get() instanceof JsonNull && !field.slot().nullable())
                return new Rejection(failureAt(field.slot().typeRef(), path.then(new Field(field.wireName())).steps(), new NullSlot<>(),
                        SimpleValueCondition.NULL_NOT_ALLOWED));
            if (value.isPresent() && !(value.get() instanceof JsonNull))
                collected.add(new Child(field.slot().typeRef(), path.then(new Field(field.wireName())), value.get()));
        }
        return null;
    }

    /** Whether a format rule counts graphemes in a bounded clause (Lean formatRuleUsesGraphemes). */
    static boolean formatRuleUsesGraphemes(FormatRule rule) {
        return switch (rule) {
            case BoundedRule bounded -> bounded.unit() == StringLengthUnit.GRAPHEMES || formatRuleUsesGraphemes(bounded.rule());
            case SequenceRule sequence -> formatRulesUseGraphemes(sequence.parts());
            case ChoiceRule choice -> formatRulesUseGraphemes(choice.rules());
            case OptionalRule optional -> formatRuleUsesGraphemes(optional.rule());
            case LabelsRule labels -> formatRuleUsesGraphemes(labels.rule());
            case NotRule not -> formatRuleUsesGraphemes(not.rule());
            default -> false;
        };
    }

    static boolean formatRulesUseGraphemes(List<FormatRule> rules) {
        return rules.stream().anyMatch(SemanticValidation::formatRuleUsesGraphemes);
    }

    static boolean formatUseUsesGraphemes(ValidationTables tables, FormatUse use) {
        if (use instanceof InlineFormat inline) return formatRuleUsesGraphemes(inline.rule());
        String name = ((NamedFormat) use).name();
        return tables.formatBindings().stream().filter(binding -> binding.name().equals(name))
                .anyMatch(binding -> formatRuleUsesGraphemes(binding.rule()));
    }

    static boolean formatUseAccepts(ValidationTables tables, FormatUse use, String text) {
        if (use instanceof NamedFormat named) return namedFormatAccepts(tables, named.name(), text);
        return tables.formatAccepts(((InlineFormat) use).rule(), text);
    }

    static Optional<DataFailure> extraMembersFailure(ValidationTables tables, ProductSpec spec, List<JsonMember> members) {
        Set<String> names = tables.fieldNames(spec);
        for (JsonMember member : members) {
            String key = member.key();
            if (names.contains(key) || tables.profile.tag().map(tag -> key.equals(tag.key())).orElse(false)) continue;
            if (spec.extras() instanceof RejectExtras)
                return Optional.of(new DataFailure(List.of(new Field(key)), new UnexpectedField(key), member.value()));
            AllowExtras allow = (AllowExtras) spec.extras();
            if (!unicodeValid(key))
                return Optional.of(new DataFailure(List.of(new Field(key)), SimpleValueCondition.INVALID_DATA_MODEL, member.value()));
            if (allow.keyFormat().map(use -> !formatUseAccepts(tables, use, key)).orElse(false))
                return Optional.of(new DataFailure(List.of(new Field(key)), new KeyFormat(key), member.value()));
        }
        return Optional.empty();
    }

    static List<ValueRequirement> elementRequirements(ElementContract contract, List<PathStep> path, JsonValue value) {
        ValueRequirement requirement = new ValueRequirement(contract.typeRef(), path, value);
        if (value instanceof JsonNull) return contract.nullable() ? List.of() : List.of(requirement);
        return List.of(requirement);
    }

    private static void extraFieldRequirements(ValidationTables tables, ValuePath path, ProductSpec spec, List<JsonMember> members,
            List<Child> result) {
        if (!(spec.extras() instanceof AllowExtras allow)) return;
        Set<String> names = tables.fieldNames(spec);
        for (JsonMember member : members) {
            String key = member.key();
            if (names.contains(key) || tables.profile.tag().map(tag -> key.equals(tag.key())).orElse(false)) continue;
            if (!(member.value() instanceof JsonNull) || !allow.value().nullable())
                result.add(new Child(allow.value().typeRef(), path.then(new Field(key)), member.value()));
        }
    }

    private static Expansion productRequirements(ValidationTables tables, TypeRef parent, ValuePath path, ProductSpec spec,
            Members members, List<Child> children) {
        Expansion fields = slotRequirements(parent, path, members, spec.fields(), children);
        if (fields != null) return fields;
        extraFieldRequirements(tables, path, spec, members.list(), children);
        return null;
    }

    private static boolean memberTestMatches(ValidationTables tables, Members members, MemberCheck test) {
        if (test.test() instanceof AbsentTest) return members.get(test.key()).isEmpty();
        Optional<JsonValue> value = members.get(test.key());
        return value.isPresent() && value.get() instanceof JsonStr text
                && namedFormatAccepts(tables, ((FormatTest) test.test()).name(), text.value());
    }

    static boolean valueKindMatches(ValueKind kind, JsonValue value) {
        if (value instanceof JsonNull) return kind == ValueKind.NULL;
        if (value instanceof JsonBool) return kind == ValueKind.BOOLEAN;
        if (value instanceof JsonNum || value instanceof JsonDec) return kind == ValueKind.NUMBER;
        if (value instanceof JsonStr) return kind == ValueKind.STRING;
        if (value instanceof JsonArr) return kind == ValueKind.ARRAY;
        return kind == ValueKind.OBJECT;
    }

    static boolean selectorMatches(ValidationTables tables, UnionBranch branch, JsonValue value) {
        return selectorMatches(tables, branch, value, value instanceof JsonObj object ? new Members(object.members()) : null);
    }

    private static boolean selectorMatches(ValidationTables tables, UnionBranch branch, JsonValue value, Members members) {
        BranchSelector selector = branch.selector();
        if (selector instanceof InternalTagSelector) {
            if (tables.tag().isEmpty() || members == null) return false;
            Optional<JsonValue> member = members.get(tables.tag().get().key());
            return member.isPresent() && member.get() instanceof JsonStr text && text.value().equals(branch.wireTag());
        }
        if (selector instanceof MemberShapeSelector shape) {
            if (members == null) return false;
            for (MemberCheck test : shape.tests()) if (!memberTestMatches(tables, members, test)) return false;
            return true;
        }
        if (selector instanceof KindSelector kind) return valueKindMatches(kind.kind(), value);
        return true;
    }

    static Optional<UnionBranch> selectUnionBranch(ValidationTables tables, UnionSpec spec, JsonValue value) {
        int index = selectUnionBranchIndex(tables, spec, value);
        return index < 0 ? Optional.empty() : Optional.of(spec.branches().get(index));
    }

    static int selectUnionBranchIndex(ValidationTables tables, UnionSpec spec, JsonValue value) {
        Members members = value instanceof JsonObj object ? new Members(object.members()) : null;
        List<UnionBranch> branches = spec.branches();
        for (int index = 0; index < branches.size(); index++) if (selectorMatches(tables, branches.get(index), value, members)) return index;
        return -1;
    }

    private static int compareDecimalBound(DecimalNumber number, DecimalBound bound) {
        return SemanticValues.compareDecimal(number, new DecimalNumber(bound.mantissa(), bound.scale()));
    }

    private static Optional<ValueCondition> decimalCondition(DecimalSpec spec, String text) {
        Optional<DecimalNumber> number = SemanticValues.parseLeanNumber(text);
        if (number.isEmpty()) return Optional.of(SimpleValueCondition.INVALID_DATA_MODEL);
        Optional<Integer> minimum = spec.minimum().map(bound -> compareDecimalBound(number.get(), bound));
        if (minimum.isPresent() && (minimum.get() < 0 || minimum.get() == 0 && spec.minimum().get().exclusive()))
            return Optional.of(SimpleValueCondition.BELOW_MINIMUM);
        Optional<Integer> maximum = spec.maximum().map(bound -> compareDecimalBound(number.get(), bound));
        if (maximum.isPresent() && (maximum.get() > 0 || maximum.get() == 0 && spec.maximum().get().exclusive()))
            return Optional.of(SimpleValueCondition.ABOVE_MAXIMUM);
        return Optional.empty();
    }

    private static Optional<DataFailure> sealedExtrasFailure(ValidationTables tables, ValuePath path,
            SealedForm form, List<JsonMember> members) {
        if (tables.tag().isPresent()) return dataSealedMembersFailure(tables, path, tables.tag().get(), form, members);
        return Optional.of(new DataFailure(path.steps(), SimpleValueCondition.INVALID_DATA_MODEL, new JsonObj(members)));
    }

    private static Optional<MemberFailure> sealedRefinementFailure(ValidationTables tables,
            Members members, List<SealedRefinement> refinements) {
        for (SealedRefinement refinement : refinements) {
            Optional<JsonValue> value = members.get(refinement.key());
            if (value.isEmpty()) continue;
            Optional<ValueCondition> condition = sealedLeafFailure(tables, refinement.leaf(), value.get());
            if (condition.isPresent()) return Optional.of(new MemberFailure(refinement.key(), condition.get(), value.get()));
        }
        return Optional.empty();
    }

    private static Expansion rejectData(TypeRef ref, DataFailure failure, ValuePath prefix) {
        return new Rejection(failureAt(ref, concatenate(prefix.steps(), failure.path()), new Present<>(failure.observed()), failure.condition()));
    }

    static Expansion expandNode(ValidationTables tables, TypeRef ref, List<PathStep> path, JsonValue value, Optional<TypeNode> node) {
        List<Child> children = new ArrayList<>();
        Expansion failed = expand(tables, ref, ValuePath.of(path), value, node, children);
        if (failed != null) return failed;
        List<ValueRequirement> requirements = new ArrayList<>(children.size());
        for (Child child : children) requirements.add(new ValueRequirement(child.typeRef(), child.path().steps(), child.value()));
        return new Requirements(requirements);
    }

    private static Expansion expand(ValidationTables tables, TypeRef ref, ValuePath path, JsonValue value, Optional<TypeNode> node,
            List<Child> children) {
        if (node.isEmpty()) return new Unresolution(List.of(obligationAt(tables, ref, path.steps(), new UnresolvedType())));
        java.util.function.Function<ValueCondition, Expansion> reject = condition ->
                new Rejection(failureAt(ref, path.steps(), new Present<>(value), condition));
        TypeShape shape = node.get().shape();
        if (shape instanceof BooleanShape boolean_ && value instanceof JsonBool actual)
            return boolean_.spec().constValue().map(constant -> constant != actual.value()).orElse(false)
                    ? reject.apply(SimpleValueCondition.CONST_MISMATCH) : null;
        if (shape instanceof IntegerShape integer) {
            Optional<ValueCondition> condition = integerCondition(tables, integer.spec(), value);
            return condition.isEmpty() ? null : reject.apply(condition.get());
        }
        if (shape instanceof DecimalShape decimal && value instanceof JsonDec text) {
            Optional<ValueCondition> condition = decimalCondition(decimal.spec(), text.text());
            return condition.isEmpty() ? null : reject.apply(condition.get());
        }
        if (shape instanceof StringShape string) {
            Optional<ValueCondition> condition = stringValueCondition(tables, string.spec(), value);
            return condition.isEmpty() ? null : reject.apply(condition.get());
        }
        if (shape instanceof BytesShape bytes) {
            Optional<Long> length = bytesValueLength(tables, value);
            if (length.isEmpty()) return reject.apply(SimpleValueCondition.INVALID_BYTES);
            return lengthAccepts(bytes.spec().minimum(), bytes.spec().maximum(), length.get())
                    ? null : reject.apply(SimpleValueCondition.BYTES_LENGTH);
        }
        if (shape instanceof ProductShape product && value instanceof JsonObj object) {
            Members members = new Members(object.members());
            Optional<DataFailure> member = objectMemberFailure(tables, members);
            if (member.isPresent()) return rejectData(ref, member.get(), path);
            if (classOf(tables, members) instanceof OrdinaryClass) {
                Optional<DataFailure> extra = extraMembersFailure(tables, product.spec(), object.members());
                if (extra.isPresent()) return rejectData(ref, extra.get(), path);
                return productRequirements(tables, ref, path, product.spec(), members, children);
            }
            return reject.apply(new WrongValueKind("plain data object"));
        }
        if (shape instanceof ArrayShape array && value instanceof JsonArr items) {
            if (!lengthAccepts(array.spec().minLength(), array.spec().maxLength(), items.items().size()))
                return reject.apply(SimpleValueCondition.ARRAY_LENGTH);
            ElementContract item = array.spec().item();
            for (int index = 0; index < items.items().size(); index++) {
                JsonValue element = items.items().get(index);
                if (!(element instanceof JsonNull) || !item.nullable())
                    children.add(new Child(item.typeRef(), path.then(new Index(BigInteger.valueOf(index))), element));
            }
            return null;
        }
        if (shape instanceof AliasShape alias) {
            children.add(new Child(alias.target(), path, value));
            return null;
        }
        if (shape instanceof TaggedUnionShape union) {
            if (value instanceof JsonObj object) {
                Optional<DataFailure> member = objectMemberFailure(tables, new Members(object.members()));
                if (member.isPresent()) return rejectData(ref, member.get(), path);
            }
            int branch = selectUnionBranchIndex(tables, union.spec(), value);
            if (branch < 0) return reject.apply(SimpleValueCondition.NO_BRANCH_SELECTED);
            children.add(new Child(union.spec().branches().get(branch).target(), path, value));
            return null;
        }
        if (shape instanceof SealedShape sealed && value instanceof JsonObj object) {
            Members members = new Members(object.members());
            Optional<DataFailure> member = objectMemberFailure(tables, members);
            if (member.isPresent()) return rejectData(ref, member.get(), path);
            if (classOf(tables, members) instanceof SealedClass sealedClass) {
                SealedForm form = sealedClass.form();
                if (!form.tag().equals(sealed.tag())) return reject.apply(SimpleValueCondition.INVALID_DATA_MODEL);
                Optional<MemberFailure> field = sealedFieldsFailure(tables, form, members);
                if (field.isPresent())
                    return new Rejection(failureAt(ref, path.then(new Field(field.get().key())).steps(), new Present<>(field.get().observed()), field.get().condition()));
                Optional<DataFailure> extras = sealedExtrasFailure(tables, path, form, object.members());
                if (extras.isPresent())
                    return new Rejection(failureAt(ref, extras.get().path(), new Present<>(extras.get().observed()), extras.get().condition()));
                Optional<MemberFailure> refinement = sealedRefinementFailure(tables, members, sealed.refinements());
                if (refinement.isPresent())
                    return new Rejection(failureAt(ref, path.then(new Field(refinement.get().key())).steps(), new Present<>(refinement.get().observed()), refinement.get().condition()));
                return null;
            }
            return reject.apply(new WrongValueKind("sealed object"));
        }
        if (shape instanceof NeverShape) return reject.apply(SimpleValueCondition.INVALID_DATA_MODEL);
        if (shape instanceof UnknownShape unknown) {
            if (unknown.kind() == UnknownKind.ORDINARY_OBJECT) {
                if (!(value instanceof JsonObj object)) return reject.apply(new WrongValueKind("ordinary object"));
                Members members = new Members(object.members());
                Optional<DataFailure> member = objectMemberFailure(tables, members);
                if (member.isPresent()) return rejectData(ref, member.get(), path);
                if (!(classOf(tables, members) instanceof OrdinaryClass))
                    return reject.apply(new WrongValueKind("ordinary object"));
                Optional<DataFailure> data = dataValueFailure(tables, path, value);
                return data.isEmpty() ? null
                        : new Rejection(failureAt(ref, data.get().path(), new Present<>(data.get().observed()), data.get().condition()));
            }
            Optional<DataFailure> data = dataValueFailure(tables, path, value);
            return data.isEmpty() ? null
                    : new Rejection(failureAt(ref, data.get().path(), new Present<>(data.get().observed()), data.get().condition()));
        }
        if (shape instanceof UnitShape && value instanceof JsonNull) return null;
        if (shape instanceof RawBodyShape)
            return bytesValueLength(tables, value).isPresent() ? null : reject.apply(SimpleValueCondition.INVALID_BYTES);
        if (shape instanceof OpaqueShape opaque)
            return new Unresolution(List.of(obligationAt(tables, ref, path.steps(), new OpaqueType(opaque.typeName()))));
        if (shape instanceof BooleanShape) return reject.apply(new WrongValueKind("boolean"));
        if (shape instanceof DecimalShape) return reject.apply(new WrongValueKind("decimal"));
        if (shape instanceof SealedShape) return reject.apply(new WrongValueKind("sealed object"));
        if (shape instanceof ProductShape) return reject.apply(new WrongValueKind("object"));
        if (shape instanceof ArrayShape) return reject.apply(new WrongValueKind("array"));
        return reject.apply(new WrongValueKind("unit"));
    }

    static Expansion expandValue(ValidationTables tables, TypeRef ref, List<PathStep> path, JsonValue value) {
        return expandNode(tables, ref, path, value, tables.findType(ref));
    }

    record RefPath(TypeRef ref, List<PathStep> path) {}

    /** The membership check as an explicit stack: each frame waits for the children of one reference at one path. */
    private static final class Membership {
        private final ValidationTables tables;
        private final List<RefPath> outer;
        private final java.util.ArrayDeque<Frame> frames = new java.util.ArrayDeque<>();

        Membership(ValidationTables tables, List<RefPath> outer) {
            this.tables = tables;
            this.outer = outer;
        }

        private static final class Frame {
            final TypeRef ref;
            final ValuePath path;
            final List<Child> children;
            final BigInteger childFuel;
            final Optional<List<MemberProof>> wanted;
            final List<MemberProof> proofs = new ArrayList<>();
            int next;
            int wantedNext;

            Frame(TypeRef ref, ValuePath path, List<Child> children, BigInteger childFuel, Optional<List<MemberProof>> wanted) {
                this.ref = ref;
                this.path = path;
                this.children = children;
                this.childFuel = childFuel;
                this.wanted = wanted;
            }
        }

        MembershipResult check(BigInteger fuel, TypeRef ref, List<PathStep> path, JsonValue value, Optional<MemberProof> expected) {
            MembershipResult outcome = open(fuel, ref, ValuePath.of(path), value, expected);
            while (!frames.isEmpty()) {
                Frame frame = frames.peek();
                if (outcome != null) {
                    if (!(outcome instanceof MemberAccepted accepted)) {
                        close();
                        continue;
                    }
                    frame.proofs.add(accepted.proof());
                    outcome = null;
                }
                if (frame.next < frame.children.size()) {
                    if (frame.wanted.isPresent() && frame.wantedNext == frame.wanted.get().size()) {
                        close();
                        outcome = new MemberInvalidCertificate("missing membership children");
                        continue;
                    }
                    Child child = frame.children.get(frame.next++);
                    Optional<MemberProof> head = frame.wanted.map(items -> items.get(frame.wantedNext++));
                    outcome = open(frame.childFuel, child.typeRef(), child.path(), child.value(), head);
                    continue;
                }
                boolean extra = frame.wanted.isPresent() && frame.wantedNext < frame.wanted.get().size();
                close();
                outcome = extra ? new MemberInvalidCertificate("extra membership children")
                        : new MemberAccepted(new MemberProof(frame.proofs));
            }
            return outcome;
        }

        /** Decides the check at once, or pushes its frame and returns null. */
        private MembershipResult open(BigInteger fuel, TypeRef ref, ValuePath path, JsonValue value, Optional<MemberProof> expected) {
            if (fuel.signum() == 0)
                return new MemberUnresolved(List.of(obligationAt(tables, ref, path.steps(), new MembershipBound())));
            if (revisits(ref, path))
                return new MemberRejected(failureAt(ref, path.steps(), new Present<>(value), SimpleValueCondition.REFERENCE_CYCLE, trace()));
            List<Child> children = new ArrayList<>();
            Expansion failed = expand(tables, ref, path, value, tables.findType(ref), children);
            if (failed instanceof Rejection rejected) {
                ValueFailure failure = rejected.failure();
                return new MemberRejected(new ValueFailure(failure.typeRef(), failure.definitionRef(), failure.origin(),
                        failure.valuePath(), failure.condition(), failure.observed(), trace()));
            }
            if (failed instanceof Unresolution unresolved) return new MemberUnresolved(unresolved.obligations());
            frames.push(new Frame(ref, path, children, fuel.subtract(BigInteger.ONE), expected.map(MemberProof::children)));
            return null;
        }

        private boolean revisits(TypeRef ref, ValuePath path) {
            for (Frame frame : frames) {
                if (frame.path.depth != path.depth) return outerContains(ref, path);
                if (frame.ref.equals(ref)) return true;
            }
            return outerContains(ref, path);
        }

        private boolean outerContains(TypeRef ref, ValuePath path) {
            return !outer.isEmpty() && outer.contains(new RefPath(ref, path.steps()));
        }

        private void close() {
            frames.pop();
        }

        /** The references of the enclosing checks, the nearest first. */
        private List<TypeRef> trace() {
            List<TypeRef> refs = new ArrayList<>();
            for (Frame frame : frames) refs.add(frame.ref);
            for (RefPath item : outer) refs.add(item.ref());
            return refs;
        }
    }

    static MembershipResult checkValueFuel(ValidationTables tables, java.math.BigInteger fuel, List<RefPath> seen,
            TypeRef ref, List<PathStep> path, JsonValue value, Optional<MemberProof> expected) {
        return new Membership(tables, seen).check(fuel, ref, path, value, expected);
    }

    static Except<ValidatedValue> validateValue(ValidationTables tables, TypeRef ref, JsonValue value,
            Optional<MemberProof> proof) {
        List<SemanticObligation> meaning = meaningOf(tables, ref);
        if (!meaning.isEmpty()) return new Failed<>(new ValidationUnresolved(meaning));
        BigInteger fuel = jsonSize(value).add(BigInteger.ONE).multiply(BigInteger.valueOf(tables.graph.nodes().size() + 1L));
        MembershipResult result = checkValueFuel(tables, fuel, List.of(), ref, List.of(), value, proof);
        if (result instanceof MemberAccepted accepted) return new Ok<>(new ValidatedValue(accepted.proof()));
        if (result instanceof MemberRejected rejected) return new Failed<>(new ValueRejected(rejected.failure()));
        if (result instanceof MemberUnresolved unresolved) return new Failed<>(new ValidationUnresolved(unresolved.obligations()));
        return new Failed<>(new CertificateMismatch(((MemberInvalidCertificate) result).condition()));
    }

    /** The meaning obligations of a reference, computed only when the table of the prepared value says that some remain. */
    private static List<SemanticObligation> meaningOf(ValidationTables tables, TypeRef ref) {
        return tables.clean(ref) ? List.of() : computeMeaning(tables, List.of(ref));
    }

    /** The decision of a slot: the proof of the value when it is present and accepted, or the failure. */
    private static Except<Optional<MemberProof>> checkSlot(ValidationTables tables, SlotContract slot, Slot<JsonValue> value) {
        List<SemanticObligation> meaning = meaningOf(tables, slot.typeRef());
        if (!meaning.isEmpty()) return new Failed<>(new ValidationUnresolved(meaning));
        if (value instanceof Absent<JsonValue>) {
            if (!slot.required()) return new Ok<>(Optional.empty());
            return new Failed<>(new ValueRejected(failureAt(slot.typeRef(), List.of(), value, SimpleValueCondition.MISSING_REQUIRED)));
        }
        if (value instanceof NullSlot<JsonValue>) {
            if (slot.nullable()) return new Ok<>(Optional.empty());
            return new Failed<>(new ValueRejected(failureAt(slot.typeRef(), List.of(), value, SimpleValueCondition.NULL_NOT_ALLOWED)));
        }
        Except<ValidatedValue> checked = validateValue(tables, slot.typeRef(), ((Present<JsonValue>) value).value(), Optional.empty());
        if (checked instanceof Failed<ValidatedValue> failed) return new Failed<>(failed.failure());
        return new Ok<>(Optional.of(((Ok<ValidatedValue>) checked).value().proof()));
    }

    static Except<ValidatedSlot> validateSlot(ValidationTables tables, SlotContract slot, Slot<JsonValue> value) {
        Except<Optional<MemberProof>> checked = checkSlot(tables, slot, value);
        if (checked instanceof Failed<Optional<MemberProof>> failed) return new Failed<>(failed.failure());
        return new Ok<>(new ValidatedSlot(new MemberCertificate(tables.profile.reference(), tables.graph.sourceRefs(), slot, value,
                ((Ok<Optional<MemberProof>>) checked).value())));
    }

    private static <T> ValueDecision decisionOf(ValidationTables tables, TypeRef ref, Except<T> result) {
        if (result instanceof Ok<T>) return new Accepted();
        ValidationFailure failure = ((Failed<T>) result).failure();
        if (failure instanceof ValueRejected rejected) return new Rejected(rejected.failure());
        if (failure instanceof ValidationUnresolved unresolved) return new Unresolved(unresolved.obligations());
        return new Unresolved(List.of(obligationAt(tables, ref, List.of(),
                new CertificateMismatchReason(((CertificateMismatch) failure).condition()))));
    }

    static ValueDecision acceptsValue(ValidationTables tables, TypeRef ref, JsonValue value) {
        return decisionOf(tables, ref, validateValue(tables, ref, value, Optional.empty()));
    }

    static ValueDecision acceptsSlot(ValidationTables tables, SlotContract slot, Slot<JsonValue> value) {
        return decisionOf(tables, slot.typeRef(), checkSlot(tables, slot, value));
    }

    public static Except<ValidatedValue> validateValue(SemanticValues.Context context, TypeRef ref, JsonValue value,
            Optional<MemberProof> proof) {
        return validateValue(context.tables(), ref, value, proof);
    }

    public static Except<ValidatedSlot> validateSlot(SemanticValues.Context context, SlotContract slot, Slot<JsonValue> value) {
        return validateSlot(context.tables(), slot, value);
    }

    public static ValueDecision acceptsValue(SemanticValues.Context context, TypeRef ref, JsonValue value) {
        return acceptsValue(context.tables(), ref, value);
    }

    public static ValueDecision acceptsSlot(SemanticValues.Context context, SlotContract slot, Slot<JsonValue> value) {
        return acceptsSlot(context.tables(), slot, value);
    }

    public static List<SemanticObligation> meaningObligations(SemanticValues.Context context, List<TypeRef> refs) {
        return meaningObligations(context.tables(), refs);
    }

    public static Expansion expandValue(SemanticValues.Context context, TypeRef ref, List<PathStep> path, JsonValue value) {
        return expandValue(context.tables(), ref, path, value);
    }

    public static Except<DefaultedValue> materializeDefaults(SemanticValues.Context context, TypeRef ref, JsonValue value) {
        return materializeDefaults(context.tables(), ref, value);
    }

    public static Optional<ValueCondition> stringCondition(SemanticValues.Context context, StringSpec spec, String value) {
        return stringCondition(context.tables(), spec, value);
    }

    public record DefaultApplication(List<PathStep> valuePath, TypeRef typeRef, OccurrenceRef origin, JsonValue value) {
        public DefaultApplication { valuePath = List.copyOf(valuePath); }
    }

    public record DefaultedValue(JsonValue value, List<DefaultApplication> applications, ValidatedValue checked) {
        public DefaultedValue { applications = List.copyOf(applications); }
    }

    private record DefaultDraft(JsonValue value, List<DefaultApplication> applications) {}

    private record DeclaredDefault(TypeRef typeRef, JsonValue value) {}

    static Optional<JsonValue> typeDefault(TypeShape shape) {
        if (shape instanceof BooleanShape boolean_) return boolean_.spec().defaultValue().map(value -> new JsonBool(value));
        if (shape instanceof IntegerShape integer) return integer.spec().defaultValue().map(value -> new JsonNum(value));
        if (shape instanceof StringShape string) return string.spec().defaultValue().map(value -> new JsonStr(value));
        return Optional.empty();
    }

    private static OccurrenceRef defaultOrigin(TypeRef ref) {
        List<String> pointer = new ArrayList<>(ref.pointer());
        pointer.add("default");
        return new OccurrenceRef(ref.source(), pointer);
    }

    private static Optional<DeclaredDefault> declaredDefault(ValidationTables tables, long fuel, TypeRef ref) {
        while (fuel > 0) {
            Optional<TypeNode> node = tables.findType(ref);
            if (node.isEmpty()) return Optional.empty();
            if (node.get().shape() instanceof AliasShape alias) { ref = alias.target(); fuel--; continue; }
            TypeRef declared = ref;
            return typeDefault(node.get().shape()).map(value -> new DeclaredDefault(declared, value));
        }
        return Optional.empty();
    }

    private static Except<DefaultDraft> defaultDraft(ValidationTables tables, long fuel, TypeRef ref, List<PathStep> path,
            JsonValue value) {
        java.util.ArrayDeque<DraftFrame> frames = new java.util.ArrayDeque<>();
        Map<DeclaredDefault, Except<ValidatedValue>> checked = new HashMap<>();
        Except<DefaultDraft> outcome = openDraft(tables, fuel, ref, ValuePath.of(path), value, frames);
        while (!frames.isEmpty()) {
            DraftFrame frame = frames.peek();
            if (outcome != null) {
                if (outcome instanceof Failed<DefaultDraft>) {
                    frames.pop();
                    continue;
                }
                frame.accept(((Ok<DefaultDraft>) outcome).value());
                outcome = null;
            }
            if (frame.hasNext()) {
                DraftChild child = frame.next();
                if (child != null) outcome = openDraft(tables, child.fuel(), child.ref(), child.path(), child.value(), frames);
                continue;
            }
            frames.pop();
            outcome = frame.finish(tables, checked);
        }
        return outcome;
    }

    private record DraftChild(long fuel, TypeRef ref, ValuePath path, JsonValue value) {}

    /** Decides the default draft at once, or pushes the frame of its children and returns null. */
    private static Except<DefaultDraft> openDraft(ValidationTables tables, long fuel, TypeRef ref, ValuePath path,
            JsonValue value, java.util.ArrayDeque<DraftFrame> frames) {
        TypeRef current = ref;
        long remaining = fuel;
        while (true) {
            if (remaining == 0)
                return new Failed<>(new ValidationUnresolved(List.of(obligationAt(tables, current, path.steps(), new MembershipBound()))));
            Optional<TypeNode> node = tables.findType(current);
            if (node.isEmpty())
                return new Failed<>(new ValidationUnresolved(List.of(obligationAt(tables, current, path.steps(), new UnresolvedType()))));
            TypeShape shape = node.get().shape();
            if (shape instanceof AliasShape alias) {
                current = alias.target();
                remaining--;
                continue;
            }
            if (shape instanceof TaggedUnionShape union && value instanceof JsonObj object) {
                Optional<JsonValue> tag = memberValue(tables.profile.tag().map(TagModel::key).orElse(""), object.members());
                if (tag.isPresent() && tag.get() instanceof JsonStr text) {
                    Optional<UnionBranch> branch = union.spec().branches().stream()
                            .filter(candidate -> candidate.wireTag().equals(text.value())).findFirst();
                    if (branch.isPresent()) {
                        current = branch.get().target();
                        remaining--;
                        continue;
                    }
                }
                return new Ok<>(new DefaultDraft(value, List.of()));
            }
            if (shape instanceof ArrayShape array && value instanceof JsonArr items) {
                frames.push(new ArrayDraft(remaining - 1, path, array, items.items()));
                return null;
            }
            if (shape instanceof ProductShape product && value instanceof JsonObj object) {
                frames.push(new ProductDraft(tables, remaining - 1, path, product, object.members()));
                return null;
            }
            return new Ok<>(new DefaultDraft(value, List.of()));
        }
    }

    /** The children of a default draft, checked in order; a frame finishes once all of them are drafted. */
    private sealed interface DraftFrame permits ArrayDraft, ProductDraft {
        boolean hasNext();

        /** The next child to draft, or null when the member is copied without a draft. */
        DraftChild next();

        void accept(DefaultDraft draft);

        Except<DefaultDraft> finish(ValidationTables tables, Map<DeclaredDefault, Except<ValidatedValue>> checked);
    }

    private static final class ArrayDraft implements DraftFrame {
        private final long childFuel;
        private final ValuePath path;
        private final ArrayShape shape;
        private final List<JsonValue> items;
        private final List<JsonValue> values = new ArrayList<>();
        private final List<DefaultApplication> applications = new ArrayList<>();
        private int position;

        ArrayDraft(long childFuel, ValuePath path, ArrayShape shape, List<JsonValue> items) {
            this.childFuel = childFuel;
            this.path = path;
            this.shape = shape;
            this.items = items;
        }

        @Override
        public boolean hasNext() { return position < items.size(); }

        @Override
        public DraftChild next() {
            int index = position++;
            return new DraftChild(childFuel, shape.spec().item().typeRef(), path.then(new Index(BigInteger.valueOf(index))), items.get(index));
        }

        @Override
        public void accept(DefaultDraft draft) {
            values.add(draft.value());
            applications.addAll(draft.applications());
        }

        @Override
        public Except<DefaultDraft> finish(ValidationTables tables, Map<DeclaredDefault, Except<ValidatedValue>> checked) {
            return new Ok<>(new DefaultDraft(new JsonArr(values), applications));
        }
    }

    private static final class ProductDraft implements DraftFrame {
        private final long childFuel;
        private final ValuePath path;
        private final ProductShape shape;
        private final List<JsonMember> members;
        private final Map<String, FieldSpec> fields;
        private final List<JsonMember> retained = new ArrayList<>();
        private final List<DefaultApplication> applications = new ArrayList<>();
        private int position;
        private String pendingKey;

        ProductDraft(ValidationTables tables, long childFuel, ValuePath path, ProductShape shape, List<JsonMember> members) {
            this.childFuel = childFuel;
            this.path = path;
            this.shape = shape;
            this.members = members;
            this.fields = tables.fieldsByName(shape.spec());
        }

        @Override
        public boolean hasNext() { return position < members.size(); }

        @Override
        public DraftChild next() {
            JsonMember member = members.get(position++);
            FieldSpec field = fields.get(member.key());
            if (field == null || member.value() instanceof JsonNull) {
                retained.add(member);
                return null;
            }
            pendingKey = member.key();
            return new DraftChild(childFuel, field.slot().typeRef(), path.then(new Field(member.key())), member.value());
        }

        @Override
        public void accept(DefaultDraft draft) {
            retained.add(new JsonMember(pendingKey, draft.value()));
            applications.addAll(draft.applications());
        }

        @Override
        public Except<DefaultDraft> finish(ValidationTables tables, Map<DeclaredDefault, Except<ValidatedValue>> checked) {
            List<JsonMember> inserted = new ArrayList<>();
            Set<String> present = new HashSet<>();
            for (JsonMember member : members) present.add(member.key());
            for (FieldSpec field : shape.spec().fields()) {
                if (present.contains(field.wireName())) continue;
                Optional<DeclaredDefault> declared = declaredDefault(tables, tables.graph.nodes().size() + 1L, field.slot().typeRef());
                if (declared.isEmpty()) continue;
                Except<ValidatedValue> result = checked.computeIfAbsent(declared.get(),
                        known -> validateValue(tables, known.typeRef(), known.value(), Optional.empty()));
                if (result instanceof Failed<ValidatedValue> failed) return new Failed<>(failed.failure());
                applications.add(new DefaultApplication(path.then(new Field(field.wireName())).steps(), declared.get().typeRef(),
                        defaultOrigin(declared.get().typeRef()), declared.get().value()));
                inserted.add(new JsonMember(field.wireName(), declared.get().value()));
            }
            List<JsonMember> all = new ArrayList<>(retained);
            all.addAll(inserted);
            return new Ok<>(new DefaultDraft(new JsonObj(all), applications));
        }
    }

    private static boolean tagMatches(VersionedSemanticProfile profile, List<JsonMember> members, String tag) {
        if (profile.tag().isEmpty()) return false;
        Optional<JsonValue> value = memberValue(profile.tag().get().key(), members);
        return value.isPresent() && value.get() instanceof JsonStr text && text.value().equals(tag);
    }

    public static Slot<JsonValue> valueAtPath(VersionedSemanticProfile profile, JsonValue value, List<PathStep> path) {
        for (PathStep step : path) {
            if (value instanceof JsonNull) return new NullSlot<>();
            if (step instanceof Field field && value instanceof JsonObj object) {
                Optional<JsonValue> next = memberValue(field.wireName(), object.members());
                if (next.isEmpty()) return new Absent<>();
                if (next.get() instanceof JsonNull) return new NullSlot<>();
                value = next.get();
            } else if (step instanceof Index index && value instanceof JsonArr array) {
                if (index.index().bitLength() > 31 || index.index().intValue() >= array.items().size()) return new Absent<>();
                JsonValue next = array.items().get(index.index().intValue());
                if (next instanceof JsonNull) return new NullSlot<>();
                value = next;
            } else if (step instanceof Variant variant && value instanceof JsonObj object) {
                if (!tagMatches(profile, object.members(), variant.wireTag())) return new Absent<>();
            } else return new Absent<>();
        }
        return new Present<>(value);
    }

    /** Projects a slot through a value path, as the Lean {@code projectedValue} does. */
    public static Slot<JsonValue> projectedValue(VersionedSemanticProfile profile, Slot<JsonValue> source,
            List<PathStep> path) {
        if (source instanceof Present<JsonValue> present) return valueAtPath(profile, present.value(), path);
        return source;
    }

    static boolean checkDefaultApplications(ValidationTables tables, JsonValue before, JsonValue after,
            List<DefaultApplication> applications) {
        for (DefaultApplication application : applications) {
            if (!(valueAtPath(tables.profile, before, application.valuePath()) instanceof Absent<JsonValue>)) return false;
            if (!valueAtPath(tables.profile, after, application.valuePath()).equals(new Present<>(application.value()))) return false;
            if (!application.origin().equals(defaultOrigin(application.typeRef()))) return false;
            if (!tables.findType(application.typeRef()).flatMap(node -> typeDefault(node.shape())).equals(Optional.of(application.value())))
                return false;
        }
        return true;
    }

    static Except<DefaultedValue> materializeDefaults(ValidationTables tables, TypeRef ref, JsonValue value) {
        BigInteger fuel = jsonSize(value).add(BigInteger.ONE).multiply(BigInteger.valueOf(tables.graph.nodes().size() + 1L));
        Except<DefaultDraft> draft = defaultDraft(tables, fuel.min(BigInteger.valueOf(Long.MAX_VALUE)).longValue(), ref, List.of(), value);
        if (draft instanceof Failed<DefaultDraft> failed) return new Failed<>(failed.failure());
        DefaultDraft drafted = ((Ok<DefaultDraft>) draft).value();
        Except<ValidatedValue> checked = validateValue(tables, ref, drafted.value(), Optional.empty());
        if (checked instanceof Failed<ValidatedValue> failed) return new Failed<>(failed.failure());
        if (!checkDefaultApplications(tables, value, drafted.value(), drafted.applications()))
            return new Failed<>(new CertificateMismatch("default source, absence, or result"));
        return new Ok<>(new DefaultedValue(drafted.value(), drafted.applications(), ((Ok<ValidatedValue>) checked).value()));
    }

    /** The Lean ProfilePredicate codes of the profile failures. */
    public enum ProfilePredicate { PR01, PR02, PR03, PR04, PR05, PR06, PR07, PR08, PR09, PR10, PR11, PR12, PR13, PR14, PR15, PR16 }

    /** The Lean ProfileFailure: the reference, the failed predicate, and the location of the failed field. */
    public record ProfileFailure(ProfileRef reference, ProfilePredicate predicate, List<String> location) {}

    /** The Lean CheckedProfile: a typed profile whose predicates hold. */
    public static final class CheckedProfile {
        private final VersionedSemanticProfile profile;
        private CheckedProfile(VersionedSemanticProfile profile) { this.profile = Objects.requireNonNull(profile); }
        public VersionedSemanticProfile profile() { return profile; }
    }

    /** The Lean Except ProfileFailure CheckedProfile of checkProfile. */
    public sealed interface ProfileCheck permits ProfileChecked, ProfileRejected {}
    public record ProfileChecked(CheckedProfile checked) implements ProfileCheck {}
    public record ProfileRejected(ProfileFailure failure) implements ProfileCheck {}

    /** The Lean checkProfile: checks a typed profile and returns the checked profile or the first failure. */
    public static ProfileCheck checkProfile(VersionedSemanticProfile profile) {
        Optional<ProfileFailure> failure = profileFailure(profile);
        return failure.isPresent() ? new ProfileRejected(failure.get()) : new ProfileChecked(new CheckedProfile(profile));
    }

    /** The Lean profileFailure: the first failed predicate of the profile, or none. */
    public static Optional<ProfileFailure> profileFailure(VersionedSemanticProfile profile) {
        List<String> formats = profile.formatBindings().stream().map(FormatBinding::name).toList();
        List<String> wrapperKeys = profile.wrappers().stream().map(Wrapper::key).toList();
        List<String> wrapperNames = profile.wrappers().stream().map(Wrapper::name).toList();
        if (!validProfileReference(profile.reference())
                || profile.integerDomains().stream().anyMatch(binding -> !validProfileReference(binding.reference()))
                || profile.formatBindings().stream().anyMatch(binding -> !validProfileReference(binding.reference()))
                || profile.bytesPolicy().filter(policy -> !validProfileReference(policy.reference())).isPresent()
                || profile.graphemeRules().filter(rules -> !validProfileReference(rules.reference())).isPresent())
            return fail(profile, ProfilePredicate.PR01, "profile");
        if (!profileNamesUnique(profile.integerDomains().stream().map(IntegerDomainBinding::name).toList()))
            return fail(profile, ProfilePredicate.PR02, "integer_domains");
        if (profile.integerDomains().stream().anyMatch(binding -> !profileRangeValid(binding.range())))
            return fail(profile, ProfilePredicate.PR03, "integer_domains");
        if (profile.integerDomains().stream().anyMatch(binding -> binding.forms().isEmpty()))
            return fail(profile, ProfilePredicate.PR04, "integer_domains");
        if (profile.integerDomains().stream().noneMatch(binding -> binding.name().equals(profile.defaultIntegerDomain())))
            return fail(profile, ProfilePredicate.PR05, "default_integer_domain");
        if (!profileNamesUnique(formats)) return fail(profile, ProfilePredicate.PR06, "format_bindings");
        if (profile.formatBindings().stream().anyMatch(binding ->
                !formatRuleWellFormed(SemanticTypes.formatRuleDepth(binding.rule()), binding.rule())))
            return fail(profile, ProfilePredicate.PR07, "format_bindings");
        if (!profileNamesUnique(wrapperNames) || !profileNamesUnique(wrapperKeys)) return fail(profile, ProfilePredicate.PR08, "wrappers");
        if (profile.wrappers().stream().anyMatch(wrapper -> wrapper.payload() instanceof TextPayload text
                && text.format().isPresent() && !formats.contains(text.format().get())))
            return fail(profile, ProfilePredicate.PR09, "wrappers");
        if (profile.bytesPolicy().stream().anyMatch(policy -> policy.wrapper().isPresent()
                && profile.wrappers().stream().noneMatch(wrapper -> wrapper.name().equals(policy.wrapper().get())
                        && wrapper.payload() instanceof BytesPayload)))
            return fail(profile, ProfilePredicate.PR10, "bytes_policy", "wrapper");
        if (profile.tag().isPresent()) {
            Optional<ProfileFailure> tagFailure = tagFailure(profile, formats, wrapperKeys);
            if (tagFailure.isPresent()) return tagFailure;
        }
        if (profile.graphemeRules().stream().anyMatch(rules ->
                rules.properties().stream().anyMatch(range -> range.last().compareTo(range.first()) < 0)
                || rules.extendedPictographic().stream().anyMatch(range -> range.last().compareTo(range.first()) < 0)
                || rules.indicConjunct().stream().anyMatch(range -> range.last().compareTo(range.first()) < 0)))
            return fail(profile, ProfilePredicate.PR16, "grapheme_rules");
        return Optional.empty();
    }

    private static Optional<ProfileFailure> tagFailure(VersionedSemanticProfile profile, List<String> formats,
            List<String> wrapperKeys) {
        TagModel tag = profile.tag().get();
        if (tag.key().isEmpty() || wrapperKeys.contains(tag.key())) return fail(profile, ProfilePredicate.PR11, "tag", "key");
        if (tag.format().isPresent() && !formats.contains(tag.format().get())) return fail(profile, ProfilePredicate.PR12, "tag", "format");
        List<String> sealedTags = tag.sealed().stream().map(SealedForm::tag).toList();
        if (!profileNamesUnique(sealedTags) || tag.sealed().stream().anyMatch(form -> tag.format().isPresent()
                && sealedTagFormatFails(profile, tag.format().get(), form.tag())))
            return fail(profile, ProfilePredicate.PR13, "tag", "sealed");
        if (tag.sealed().stream().anyMatch(form -> {
            List<String> keys = form.fields().stream().map(SealedField::key).toList();
            return !profileNamesUnique(keys) || keys.contains(tag.key()) || keys.stream().anyMatch(wrapperKeys::contains);
        })) return fail(profile, ProfilePredicate.PR14, "tag", "sealed", "fields");
        if (tag.sealed().stream().anyMatch(form -> form.fields().stream().anyMatch(field -> sealedLeafFails(profile, formats, field.leaf()))))
            return fail(profile, ProfilePredicate.PR15, "tag", "sealed", "fields");
        return Optional.empty();
    }

    private static boolean sealedTagFormatFails(VersionedSemanticProfile profile, String format, String tag) {
        return profile.formatBindings().stream().filter(binding -> binding.name().equals(format)).findFirst()
                .map(binding -> !formatAcceptsFast(profile.graphemeRules(), binding.rule(), tag)).orElse(true);
    }

    private static boolean sealedLeafFails(VersionedSemanticProfile profile, List<String> formats, SealedLeaf leaf) {
        return switch (leaf) {
            case StringLeaf stringLeaf -> {
                StringSpec spec = stringLeaf.spec();
                yield spec.wrapper().stream().anyMatch(name -> profile.wrappers().stream().noneMatch(wrapper ->
                        wrapper.name().equals(name) && wrapper.payload() instanceof TextPayload))
                        || spec.format().stream().anyMatch(use -> use instanceof NamedFormat named
                                ? !formats.contains(named.name())
                                : !formatRuleWellFormed(SemanticTypes.formatRuleDepth(((InlineFormat) use).rule()) + 1,
                                        ((InlineFormat) use).rule()))
                        || spec.lengths().stream().anyMatch(bound -> !profileLengthValid(bound));
            }
            case IntegerLeaf integerLeaf -> integerLeaf.spec().domain().stream().anyMatch(name ->
                    profile.integerDomains().stream().noneMatch(binding -> binding.name().equals(name)));
        };
    }

    private static Optional<ProfileFailure> fail(VersionedSemanticProfile profile, ProfilePredicate predicate, String... location) {
        return Optional.of(new ProfileFailure(profile.reference(), predicate, List.of(location)));
    }

    /** The Lean validProfileReference. */
    static boolean validProfileReference(ProfileRef reference) {
        return !reference.identity().isEmpty() && !reference.revision().isEmpty() && !reference.contentDigest().isEmpty();
    }

    /** The Lean profileNamesUnique: every name is nonempty and no name repeats. */
    static boolean profileNamesUnique(List<String> names) {
        return names.stream().allMatch(name -> !name.isEmpty()) && new HashSet<>(names).size() == names.size();
    }

    /** The Lean profileRangeValid. */
    static boolean profileRangeValid(IntegerDomain domain) {
        return switch (domain) {
            case UnboundedDomain unbounded -> true;
            case InclusiveDomain inclusive -> inclusive.minimum().compareTo(inclusive.maximum()) <= 0;
        };
    }

    /** The Lean profileLengthValid. */
    static boolean profileLengthValid(LengthBound bound) {
        return bound.minimum().isEmpty() || bound.maximum().isEmpty() || bound.minimum().get().compareTo(bound.maximum().get()) <= 0;
    }

    /** The Lean formatRuleWellFormed with the fuel of the nesting depth. */
    static boolean formatRuleWellFormed(long fuel, FormatRule rule) {
        if (fuel == 0) return false;
        return switch (rule) {
            case AsciiDfaRule dfa -> dfaWellFormed(dfa.spec());
            case TimestampRule timestamp -> timestamp.rule().minimumYear().compareTo(timestamp.rule().maximumYear()) <= 0
                    && timestamp.rule().maximumYear().compareTo(BigInteger.valueOf(9999)) <= 0;
            case IdentifierRule identifier -> identifierWellFormed(identifier);
            case SequenceRule sequence -> sequence.parts().stream().allMatch(part -> formatRuleWellFormed(fuel - 1, part));
            case OptionalRule optional -> formatRuleWellFormed(fuel - 1, optional.rule());
            case LabelsRule labels -> !labels.separator().isEmpty() && formatRuleWellFormed(fuel - 1, labels.rule());
            case BoundedRule bounded -> formatRuleWellFormed(fuel - 1, bounded.rule());
            case ChoiceRule choice -> choice.rules().stream().allMatch(branch -> formatRuleWellFormed(fuel - 1, branch));
            case NotRule not -> formatRuleWellFormed(fuel - 1, not.rule());
            default -> true;
        };
    }

    private static boolean identifierWellFormed(IdentifierRule rule) {
        return !rule.firstAlphabet().isEmpty() && !rule.restAlphabet().isEmpty()
                && rule.maxLength().map(bound -> rule.minLength().compareTo(bound) <= 0).orElse(true)
                && SemanticValues.ascii(rule.firstAlphabet()) && SemanticValues.ascii(rule.restAlphabet())
                && rule.forbidden().stream().allMatch(ExactJson::unicodeValid)
                && rule.exactLength().map(length -> rule.minLength().compareTo(length) <= 0
                        && rule.maxLength().map(bound -> length.compareTo(bound) <= 0).orElse(true)).orElse(true);
    }

    private static boolean dfaWellFormed(DfaSpec spec) {
        BigInteger states = spec.stateCount();
        if (states.signum() <= 0 || spec.initialState().compareTo(states) >= 0) return false;
        if (!spec.acceptingStates().stream().allMatch(state -> state.compareTo(states) < 0)) return false;
        List<DfaTransition> transitions = spec.transitions();
        if (!transitions.stream().allMatch(t -> t.fromState().compareTo(states) < 0 && t.toState().compareTo(states) < 0
                && t.first().compareTo(t.last()) <= 0 && t.last().compareTo(BigInteger.valueOf(128)) < 0)) return false;
        for (int i = 0; i < transitions.size(); i++) {
            DfaTransition t = transitions.get(i);
            for (DfaTransition other : transitions.subList(i + 1, transitions.size()))
                if (t.fromState().equals(other.fromState()) && t.last().compareTo(other.first()) >= 0
                        && other.last().compareTo(t.first()) >= 0) return false;
        }
        return true;
    }
}
