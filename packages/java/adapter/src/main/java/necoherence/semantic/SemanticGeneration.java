// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import necoherence.semantic.ExactJson.JsonArr;
import necoherence.semantic.ExactJson.JsonMember;
import necoherence.semantic.ExactJson.JsonNull;
import necoherence.semantic.ExactJson.JsonObj;
import necoherence.semantic.ExactJson.JsonStr;
import necoherence.semantic.ExactJson.JsonValue;
import static necoherence.semantic.SemanticValues.*;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.OptionalInt;
import java.util.Set;
import necoherence.composition.SemanticComposition;
import necoherence.composition.SemanticComposition.CompositionInputFailure;
import necoherence.composition.SemanticExecution;
import necoherence.composition.SignatureCompositionWire;
import necoherence.composition.SemanticComposition.WitnessFailure;
import neco.quotient.Mismatch;
import necoherence.semantic.WireFailure.UnknownField;
import necoherence.semantic.WireFailure.UnknownTag;
import necoherence.semantic.WireFailure.WireException;

/** Shared value inclusion, composition certificates, and execution. */
public final class SemanticGeneration {
    private SemanticGeneration() {}

    public enum GenerationFailureKind {
        UNSUPPORTED_SCHEMA, ENTRYPOINTS_EMPTY, ENTRYPOINT_IDENTITY_EMPTY, ENTRYPOINT_DUPLICATE, ENTRYPOINT_UNRESOLVED,
        LIBRARY, CERTIFICATE, WIRE, EXCHANGE_JSON, EXCHANGE_WIRE, COMPOSITION_WIRE, COMPOSITION_INPUT, COMPOSITION,
        GENERATION
    }
    public static final class GenerationFailure extends RuntimeException {
        private static final long serialVersionUID = 1L;
        private final String path, condition;
        private final transient WireFailure wireFailure;
        private final transient CompositionInputFailure compositionInputFailure;
        private final transient WitnessFailure witnessFailure;
        private final transient WireValue observed;
        private final GenerationFailureKind kind;
        private final transient Mismatch<String> mismatch;
        public GenerationFailure(String path, String condition) {
            this(path, condition, null, null, null, NIL, GenerationFailureKind.GENERATION);
        }
        GenerationFailure(String path, String condition, WireFailure wireFailure) {
            this(path, condition, wireFailure, null, null, NIL,
                    wireFailure == null ? GenerationFailureKind.GENERATION : GenerationFailureKind.WIRE);
        }
        GenerationFailure(String path, String condition, WireFailure wireFailure, WireValue observed) {
            this(path, condition, wireFailure, null, null, observed,
                    wireFailure == null ? GenerationFailureKind.GENERATION : GenerationFailureKind.WIRE);
        }
        GenerationFailure(String path, String condition, GenerationFailureKind kind) {
            this(path, condition, null, null, null, NIL, kind);
        }
        GenerationFailure(String path, CompositionInputFailure compositionInputFailure) {
            this(path, compositionInputFailure.toString(), null, compositionInputFailure, null, NIL,
                    GenerationFailureKind.COMPOSITION_INPUT);
        }
        GenerationFailure(String path, WitnessFailure witnessFailure) {
            this(path, witnessFailure.toString(), null, null, witnessFailure, NIL, GenerationFailureKind.COMPOSITION);
        }
        GenerationFailure(String path, String condition, WireFailure wireFailure, WireValue observed,
                GenerationFailureKind kind) {
            this(path, condition, wireFailure, null, null, observed, kind);
        }
        GenerationFailure(String path, String condition, WireFailure wireFailure,
                WitnessFailure witnessFailure, WireValue observed, GenerationFailureKind kind) {
            this(path, condition, wireFailure, null, witnessFailure, observed, kind);
        }
        GenerationFailure(String path, String condition, WireFailure wireFailure,
                CompositionInputFailure compositionInputFailure, WitnessFailure witnessFailure,
                WireValue observed, GenerationFailureKind kind) {
            this(path, condition, wireFailure, compositionInputFailure, witnessFailure, observed, kind, null);
        }
        GenerationFailure(String path, Mismatch<String> mismatch) {
            this(path, mismatch.describe(), null, null, null, NIL, GenerationFailureKind.CERTIFICATE, mismatch);
        }
        GenerationFailure(String path, WireValue element, GenerationFailureKind kind) {
            this(path, kind.name(), null, null, null, element, kind, null);
        }
        private GenerationFailure(String path, String condition, WireFailure wireFailure,
                CompositionInputFailure compositionInputFailure, WitnessFailure witnessFailure,
                WireValue observed, GenerationFailureKind kind, Mismatch<String> mismatch) {
            super(path + ": " + condition);
            this.path = path; this.condition = condition; this.wireFailure = wireFailure;
            this.compositionInputFailure = compositionInputFailure; this.witnessFailure = witnessFailure;
            this.observed = Objects.requireNonNull(observed);
            this.kind = Objects.requireNonNull(kind);
            this.mismatch = mismatch;
        }
        public String path() { return path; }
        public String condition() { return condition; }
        public WireFailure wireFailure() { return wireFailure; }
        public CompositionInputFailure compositionInputFailure() { return compositionInputFailure; }
        public WitnessFailure witnessFailure() { return witnessFailure; }
        public WireValue observed() { return observed; }
        public GenerationFailureKind kind() { return kind; }
        public Mismatch<String> mismatch() { return mismatch; }
    }
    /** The expected generation basis and the expected goal observations, obtained through the caller's trusted source. */
    public static final class GenerationBasis {
        public final WireValue value;
        /** The expected goal observations, or {@code null} when the input has no composition. */
        public final GoalObservations observations;
        GenerationBasis(WireValue value, GoalObservations observations) { this.value = value; this.observations = observations; }
        /** Reads the expected document of the fields {@code basis} and {@code observations}, independently of the envelope. */
        public static GenerationBasis decode(String text) throws GenerationFailure {
            try {
                WireValue value = canonical(readJson(text), "ExpectedSignatureBasis", "$expected");
                WireValue observations = f(value, "observations");
                return new GenerationBasis(f(value, "basis"), nil(observations) ? null : new GoalObservations(observations));
            }
            catch (GenerationFailure failure) { throw failure; }
            catch (WireException error) { throw new GenerationFailure(error.failure().path(), error.failure().toString(), error.failure()); }
        }
        /** Builds the expected document from the basis and the composition of a generation input. */
        public static GenerationBasis ofInput(WireValue input) throws GenerationFailure {
            try {
                WireValue composition = f(input, "composition");
                return new GenerationBasis(canonical(f(input, "basis"), "SignatureGenerationBasis", "$basis"),
                        nil(composition) ? null : GoalObservations.of(composition));
            }
            catch (WireException error) { throw new GenerationFailure(error.failure().path(), error.failure().toString(), error.failure()); }
        }
        public String encode() { return encodeWire(obj("basis", value, "observations", observations == null ? NIL : observations.value())); }
    }
    public static final class CheckedGeneration {
        public final GenerationBasis basis;
        public final WireValue input;
        public final Context context;
        public final List<Integer> types;
        public final List<WireValue> definitions, providers;
        private final SemanticExecution.AdmittedComposition composition;
        private final neco.quotient.Checked<String, String, WireValue, GoalObservations, Void, TypeSignatures.Projections> admission;
        CheckedGeneration(GenerationBasis basis, WireValue input, Context context,
                List<Integer> types, List<WireValue> definitions, List<WireValue> providers,
                SemanticExecution.AdmittedComposition composition,
                neco.quotient.Checked<String, String, WireValue, GoalObservations, Void, TypeSignatures.Projections> admission) {
            this.basis = basis; this.input = input; this.context = context;
            this.types = List.copyOf(types); this.definitions = List.copyOf(definitions); this.providers = List.copyOf(providers);
            this.composition = composition;
            this.admission = admission;
        }
        /** @return the neco-quotient admission of the generation certificate */
        public neco.quotient.Checked<String, String, WireValue, GoalObservations, Void, TypeSignatures.Projections> admission() { return admission; }
        public GenerationBasis basis() { return basis; }
        public Context valueContext() { return context; }
        /** @return the admitted composition, or {@code null} when absent */
        public SemanticExecution.AdmittedComposition composition() { return composition; }
    }
    static void require(boolean condition, String path, String reason) throws GenerationFailure { if (!condition) throw new GenerationFailure(path, reason); }
    static String sha(String text) {
        try { return java.util.HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8))); }
        catch (NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
    }
    /** Reads a JSON number as the Lean fromJson does: an integer when the normalized exponent is zero or below, otherwise a decimal whose zero mantissa is written as 0. */
    static WireValue leanNumber(String spelling) {
        int exponentAt = Math.max(spelling.indexOf('e'), spelling.indexOf('E'));
        String mantissaText = exponentAt < 0 ? spelling : spelling.substring(0, exponentAt);
        BigInteger exponentPart = exponentAt < 0 ? BigInteger.ZERO : new BigInteger(spelling.substring(exponentAt + 1));
        if (exponentTooLarge(spelling))
            throw new WireException(new WireFailure.Syntax("$", "exponent too large"));
        int dot = mantissaText.indexOf('.');
        String digits = dot < 0 ? mantissaText : mantissaText.substring(0, dot) + mantissaText.substring(dot + 1);
        BigInteger mantissa = new BigInteger(digits);
        BigInteger exponent = BigInteger.valueOf(dot < 0 ? 0 : mantissaText.length() - dot - 1).subtract(exponentPart);
        if (mantissa.signum() == 0) return exponent.signum() <= 0 ? num(BigInteger.ZERO) : new DecimalValue("0");
        if (exponent.signum() <= 0) return num(scaledNumber(mantissa, exponent.negate()));
        String text = leanJsonNumberText(mantissa, exponent);
        return new DecimalValue(text);
    }

    /** The Lean JsonNumber.toString of a mantissa with a positive exponent: the exponent is written in scientific form when the value is below 10 to the minus nine. */
    static String leanJsonNumberText(BigInteger mantissa, BigInteger exponent) {
        String sign = mantissa.signum() < 0 ? "-" : "";
        BigInteger magnitude = mantissa.abs();
        BigInteger digitCount = BigInteger.valueOf(magnitude.toString().length());
        BigInteger scientific = BigInteger.valueOf(9).add(digitCount).subtract(exponent);
        BigInteger shift = scientific.signum() < 0 ? scientific : BigInteger.ZERO;
        BigInteger divisor = tenPower(exponent.subtract(shift.abs()));
        BigInteger left = magnitude.divide(divisor);
        if (magnitude.mod(divisor).signum() == 0 && shift.signum() == 0) return sign + left;
        String right = SemanticValues.withoutTrailingZeros(divisor.add(magnitude.mod(divisor)).toString().substring(1));
        return sign + left + "." + right + (shift.signum() == 0 ? "" : "e" + shift);
    }

    /** The text that the Lean compressJson writes for a decimal: the decimal read as the Lean parser and decimalNumber read it, with an integer value written as .0 and other values in the core spelling. A spelling outside the Lean exponent limit has no Lean text and is written as given, since validation rejects it. */
    static String leanNumberText(String text) {
        Optional<SemanticValues.DecimalNumber> parsed = SemanticValues.parseLeanNumber(text);
        if (parsed.isEmpty()) return text;
        BigInteger mantissa = parsed.get().mantissa(), exponent = parsed.get().scale().max(BigInteger.ZERO);
        if (parsed.get().scale().signum() < 0) mantissa = mantissa.multiply(tenPower(parsed.get().scale().negate()));
        BigInteger divisor = tenPower(exponent);
        if (mantissa.mod(divisor).signum() == 0) return mantissa.divide(divisor).toString() + ".0";
        return leanJsonNumberText(mantissa, exponent);
    }

    private static BigInteger scaledNumber(BigInteger mantissa, BigInteger power) {
        BigInteger magnitude = SemanticValues.scaleByTenPower(mantissa.abs(), power).orElseThrow(SemanticGeneration::unrepresentableNumber);
        return mantissa.signum() < 0 ? magnitude.negate() : magnitude;
    }

    private static BigInteger tenPower(BigInteger power) {
        return SemanticValues.scaleByTenPower(BigInteger.ONE, power).orElseThrow(SemanticGeneration::unrepresentableNumber);
    }

    private static WireException unrepresentableNumber() {
        return new WireException(new WireFailure.Syntax("$", "number outside the representable range"));
    }
    public static WireValue toExact(WireValue value) {
        return switch (value) {
            case NullValue unused -> variant("Null"); case BooleanValue v -> variant("Bool", v);
            case IntegerValue v -> variant("Integer", str(v.value().toString()));
            case DecimalValue v -> obj("tag", str("Decimal"), "text", str(v.text())); case StringValue v -> variant("String", v);
            case ArrayValue v -> obj("tag", str("Array"), "items", arr(v.items().stream().map(SemanticGeneration::toExact).toList()));
            case ObjectValue v -> obj("tag", str("Object"), "members", arr(v.members().stream().map(row -> obj("key", str(row.key()), "value", toExact(row.value()))).toList()));
        };
    }
    static WireValue contract(WireValue reference, boolean required, boolean nullable) { return obj("type_ref", reference, "required", new BooleanValue(required), "nullable", new BooleanValue(nullable)); }
    private sealed interface Descriptor permits Atom, Vector, Maybe, Tuple, RecordDesc, EnumDesc {}
    private record Atom(String name) implements Descriptor {}
    private record Vector(Descriptor item) implements Descriptor {}
    private record Maybe(Descriptor item) implements Descriptor {}
    private record Tuple(List<Descriptor> items) implements Descriptor {}
    private record NamedField(String name, Descriptor type) {}
    private record RecordDesc(List<NamedField> fields) implements Descriptor {}
    private record EnumDesc(Map<String, Descriptor> variants) implements Descriptor {}
    private static final String WIRE_RECORDS = """
ProfileRef identity:s;revision:s;content_digest:s
CodepointRange first:n;last:n
GraphemeRange first:n;last:n;property:GraphemeProperty
IndicRange first:n;last:n;property:IndicProperty
GraphemeComponent unicode_version:s;uax29_revision:s;cluster_profile:s
GraphemeSource role:s;source:SourceRef
GraphemeRules reference:ProfileRef;component:GraphemeComponent;table_sha256:s;sources:[GraphemeSource];properties:[GraphemeRange];extended_pictographic:[CodepointRange];indic_conjunct:[IndicRange]
IntegerDomainBinding name:s;reference:ProfileRef;range:IntegerDomain;forms:[IntegerForm]
NumberModel decimals:b
BytesPolicy reference:ProfileRef;padding_optional:b;alphabet:BytesAlphabet;strict_pad_bits:b;wrapper:?s
CalendarRule allow_second_60:b;minimum_year:n;maximum_year:n;rejectUtcYearOutsideRange:b
DfaTransition from_state:n;first:n;last:n;to_state:n
DfaSpec state_count:n;initial_state:n;accepting_states:[n];transitions:[DfaTransition]
LengthBound unit:StringLengthUnit;minimum:?n;maximum:?n
FormatBinding name:s;reference:ProfileRef;rule:FormatRule
Wrapper name:s;key:s;payload:WrapperPayload
SealedField key:s;required:b;leaf:SealedLeaf
SealedForm tag:s;fields:[SealedField];extras:SealedExtras
TagModel key:s;format:?s;sealed:[SealedForm]
SlotContract type_ref:TypeRef;required:b;nullable:b
LengthSpec minimum:?n;maximum:?n
BooleanSpec const_value:?b;default_value:?b
IntegerSpec domain:?s;minimum:?i;maximum:?i;const_value:?i;enum_values:?[i];default_value:?i
DecimalBound mantissa:i;scale:n;exclusive:b
DecimalSpec minimum:?DecimalBound;maximum:?DecimalBound
StringSpec format:?FormatUse;lengths:[LengthBound];wrapper:?s;const_value:?s;enum_values:?[s];examples:[s];default_value:?s
SemanticObligation type_ref:TypeRef;origin:OccurrenceRef;value_path:[PathStep];profile:ProfileRef;reason:SemanticReason
ValueFailure type_ref:TypeRef;definition_ref:DefinitionRef;origin:OccurrenceRef;value_path:[PathStep];condition:ValueCondition;observed:SlotValue;reference_trace:[TypeRef]
ProjectionCertificate profile:ProfileRef;source_refs:[SourceRef];source:SlotContract;path:[PathStep];assumptions:[ProjectionAssumption];destination:SlotContract
TypePair source:SlotContract;destination:SlotContract;source_tag:?s
PairEntry pair:TypePair;source_shape:SignatureShape;destination_shape:SignatureShape;rule:InclusionRule;children:[n]
InclusionCertificate basis:SemanticBasis;source:SlotContract;destination:SlotContract;root:n;empty_types:[TypeRef];pairs:[PairEntry]
TypeObligation pair:TypePair;path:[PathStep];reason:TypeObligationReason
CounterexampleCertificate basis:SemanticBasis;source:SlotContract;destination:SlotContract;value:SlotValue;destination_failure:ValueFailure
""";
    private static final Map<String, Descriptor> DESCRIPTORS = descriptors();
    private static Map<String, Descriptor> descriptors() {
        Map<String, Descriptor> result = new LinkedHashMap<>();
        for (String line : WIRE_RECORDS.lines().toList()) { int space = line.indexOf(' '); if (space > 0) result.put(line.substring(0, space), recordDesc(line.substring(space + 1))); }
        enums(result, "IntegerDomain", "Unbounded|Inclusive{minimum:i;maximum:i}");
        enums(result, "IntegerForm", "Number|IntegralDecimal|DecimalString");
        enums(result, "BytesAlphabet", "Standard|UrlSafe|Either");
        enums(result, "StringLengthUnit", "Utf8Bytes|UnicodeScalars|Graphemes");
        enums(result, "GraphemeProperty", "Other|Cr|Lf|Control|Extend|Zwj|RegionalIndicator|Prepend|SpacingMark|L|V|T|Lv|Lvt"); enums(result, "IndicProperty", "Other|Consonant|Extend|Linker");
        enums(result, "FormatRule", "Literal:s|Sequence:[FormatRule]|Optional:FormatRule|Labels{separator:s;min_count:n;max_count:?n;total_max:?n;rule:FormatRule}|Bounded{unit:StringLengthUnit;maximum:n;rule:FormatRule}|AsciiDfa:DfaSpec|Identifier{first_alphabet:s;rest_alphabet:s;exact_length:?n;min_length:n;max_length:?n;forbidden:[s]}|Timestamp:CalendarRule|AbsoluteUri{max_bytes:?n}|LanguageTag{grandfathered:[s]}|Choice:[FormatRule]|Text|Not:FormatRule");
        enums(result, "FormatUse", "Named:s|Inline:FormatRule");
        enums(result, "WrapperPayload", "Bytes|Text:?s");
        enums(result, "SealedLeaf", "String:StringSpec|Integer:IntegerSpec");
        enums(result, "SealedExtras", "Reject|Any");
        enums(result, "UnknownKind", "Any|OrdinaryObject");
        enums(result, "ExtraMembers", "Reject|Allow{key_format:?FormatUse;value:ElementContract}");
        enums(result, "ValueKind", "Null|Boolean|Number|String|Array|Object");
        enums(result, "MemberTest", "Absent|Format:s");
        enums(result, "BranchSelector", "InternalTag|MemberShape:[MemberCheck]|Kind:ValueKind|Otherwise");
        result.put("MemberCheck", recordDesc("key:s;test:MemberTest"));
        enums(result, "SlotValue", "Absent|Null|Present:ExactJson"); enums(result, "PathStep", "Field:s|Index:n|Variant:s");
        enums(result, "EffectPoint", "HttpRequestResponse|DataOnly");
        enums(result, "OutcomeForm", "Success|DeclaredFailure");
        enums(result, "SemanticReason", "MissingGraphemeRules|MissingBytesPolicy|UnknownIntegerDomain:s|UnknownWrapper:s|WrapperPayload:s|UnknownSealedTag:s|DecimalNotAdmitted|IntegerBound|OpaqueType:s|MissingTagModel|UninterpretedExtension:s|UnresolvedType|InvalidProfile:s|MembershipBound|CertificateMismatch:s|ProjectionUnavailable:s|UnknownFormat:s");
        enums(result, "ValueCondition", "MissingRequired|NullNotAllowed|WrongValueKind:s|ConstMismatch|EnumMismatch|BelowMinimum|AboveMaximum|IntegerDomain|StringLength|ArrayLength|BytesLength|Format:s|InvalidBytes|InvalidWrapper:s|InvalidTag|ReservedForm|NoBranchSelected|KeyFormat:s|Uninhabited|DuplicateField:s|UnexpectedField:s|InvalidDataModel|ReferenceCycle");
        enums(result, "ProjectionAssumption", "Present:[PathStep]|NonNull:[PathStep]|Variant{path:[PathStep];tag:s}|IndexPresent{path:[PathStep];index:n}");
        enums(result, "InclusionRule", "SameDefinedType|EmptySource|Boolean|IntegerIntersection|FiniteStrings|StringConditions|BytesLength|Unit|UnfoldSource|UnfoldDestination|Array|Product|SourceUnion|DestinationUnion");
        enums(result, "TypeObligationReason", "ConstraintImplication|Presence|UnionRemainder|Inhabitation|ObligationBoundExhausted|Meaning:[SemanticObligation]|ExtraField:s");
        enums(result, "ExactJson", "Null|Bool:b|Integer:i|Decimal{text:d}|String:s|Array{items:[ExactJson]}|Object{members:[ExactMember]}"); result.put("ExactMember", recordDesc("key:s;value:ExactJson"));
        result.put("TypeRef", recordDesc("source:SourceRef;definition_name:s;pointer:[s]"));
        result.put("DefinitionRef", recordDesc("source:SourceRef;name:s"));
        result.put("SemanticBasis", new Atom("SignatureGenerationBasis"));
        result.put("SourceRef", recordDesc("repository:s;revision:s;path:s;content_digest:s;document_id:s;declared_revision:?i"));
        result.put("OccurrenceRef", recordDesc("source:SourceRef;pointer:[s]"));
        TypeSignatures.descriptors(result, SemanticGeneration::recordDesc, (name, variants) -> enums(result, name, variants));
        Map<String, Descriptor> original = new LinkedHashMap<>(result);
        for (var entry : original.entrySet()) result.put("Sig" + entry.getKey(), signatureDescriptor(entry.getValue(), original));
        result.put("SigSourceRef", recordDesc("repository:s;revision:s;path:s;content_digest:h"));
        return Map.copyOf(result);
    }
    private static Descriptor signatureDescriptor(Descriptor descriptor, Map<String, Descriptor> original) {
        if (descriptor == null) return null;
        if (descriptor instanceof Atom atom) {
            if (Set.of("TypeRef", "DefinitionRef").contains(atom.name())) return new Atom("s");
            if (atom.name().equals("SemanticBasis")) return new Atom("SignatureGenerationBasis");
            if (atom.name().equals("ExactJson")) return atom;
            return new Atom(original.containsKey(atom.name()) ? "Sig" + atom.name() : atom.name());
        }
        if (descriptor instanceof Vector vector) return new Vector(signatureDescriptor(vector.item(), original));
        if (descriptor instanceof Maybe maybe) return new Maybe(signatureDescriptor(maybe.item(), original));
        if (descriptor instanceof Tuple tuple) return new Tuple(tuple.items().stream().map(v -> signatureDescriptor(v, original)).toList());
        if (descriptor instanceof RecordDesc record) return new RecordDesc(record.fields().stream().map(v -> new NamedField(v.name().equals("type_ref") ? "type_id" : v.name(), signatureDescriptor(v.type(), original))).toList());
        Map<String, Descriptor> variants = new LinkedHashMap<>();
        ((EnumDesc) descriptor).variants().forEach((key, value) -> variants.put(key, signatureDescriptor(value, original)));
        return new EnumDesc(variants);
    }
    private static Descriptor typeDesc(String text) {
        if (text.startsWith("?")) return new Maybe(typeDesc(text.substring(1)));
        if (text.startsWith("[")) return new Vector(typeDesc(text.substring(1, text.length() - 1)));
        if (text.startsWith("(")) return new Tuple(splitTop(text.substring(1, text.length() - 1), ',').stream().map(SemanticGeneration::typeDesc).toList());
        return new Atom(text);
    }
    private static RecordDesc recordDesc(String text) {
        List<NamedField> result = new ArrayList<>(); if (!text.isEmpty()) for (String field : splitTop(text, ';')) { int split = field.indexOf(':'); result.add(new NamedField(field.substring(0, split), typeDesc(field.substring(split + 1)))); }
        return new RecordDesc(List.copyOf(result));
    }
    private static List<String> splitTop(String text, char separator) {
        List<String> result = new ArrayList<>(); int depth = 0, start = 0;
        for (int i = 0; i < text.length(); i++) { char c = text.charAt(i); if (c == '[' || c == '(' || c == '{') depth++; if (c == ']' || c == ')' || c == '}') depth--; if (c == separator && depth == 0) { result.add(text.substring(start, i)); start = i + 1; } }
        result.add(text.substring(start)); return result;
    }
    private static void enums(Map<String, Descriptor> schemas, String name, String variants) {
        Map<String, Descriptor> result = new LinkedHashMap<>(); for (String variant : splitTop(variants, '|')) {
            int brace = variant.indexOf('{'), colon = variant.indexOf(':');
            if (brace >= 0 && (colon < 0 || brace < colon)) result.put(variant.substring(0, brace), recordDesc(variant.substring(brace + 1, variant.length() - 1)));
            else if (colon >= 0) result.put(variant.substring(0, colon), typeDesc(variant.substring(colon + 1))); else result.put(variant, null);
        }
        schemas.put(name, new EnumDesc(Collections.unmodifiableMap(result)));
    }
    static WireValue canonical(WireValue value, String descriptor, String path) throws GenerationFailure { return canonical(value, typeDesc(descriptor), path); }
    private static WireValue canonical(WireValue value, Descriptor descriptor, String path) throws GenerationFailure {
        if (descriptor instanceof Atom atom) {
            String name = atom.name();
            if (Set.of("s", "i", "n", "h", "d").contains(name) || name.startsWith("=")) {
                require(value instanceof StringValue, path, "string"); String text = s(value);
                if (name.equals("i")) require(SemanticValues.canonicalDigits(text, true), path, "canonical exact integer");
                if (name.equals("n")) require(SemanticValues.canonicalDigits(text, false), path, "canonical exact natural");
                if (name.equals("d")) require(isExactDecimal(text), path, "decimal spelling");
                if (name.startsWith("=")) require(text.equals(name.substring(1)), path, "version"); return value;
            }
            if (name.equals("b")) { require(value instanceof BooleanValue, path, "boolean"); return value; }
            if (name.equals("j")) return value;
            Descriptor resolved = DESCRIPTORS.get(name); require(resolved != null, path, "declared exchange type " + name); return canonical(value, resolved, path);
        }
        if (descriptor instanceof Maybe maybe) return nil(value) ? NIL : canonical(value, maybe.item(), path);
        if (descriptor instanceof Vector vector) {
            require(value instanceof ArrayValue, path, "array"); List<WireValue> result = new ArrayList<>(); for (int i = 0; i < a(value).size(); i++) result.add(canonical(a(value).get(i), vector.item(), path + "[" + i + "]")); return arr(result);
        }
        if (descriptor instanceof Tuple tuple) {
            require(value instanceof ArrayValue && a(value).size() == tuple.items().size(), path, "exact tuple"); List<WireValue> result = new ArrayList<>(); for (int i = 0; i < tuple.items().size(); i++) result.add(canonical(a(value).get(i), tuple.items().get(i), path + "[" + i + "]")); return arr(result);
        }
        if (descriptor instanceof RecordDesc record) {
            require(value instanceof ObjectValue, path, "object");
            closedKeys(value, path, record.fields().stream().map(NamedField::name).toList());
            List<Member> result = new ArrayList<>();
            for (NamedField field : record.fields()) result.add(new Member(field.name(), canonical(o(value).get(field.name()), field.type(), path + "." + field.name())));
            return new ObjectValue(result);
        }
        EnumDesc enumeration = (EnumDesc) descriptor;
        require(value instanceof ObjectValue && o(value).get("tag") instanceof StringValue, path, "tagged variant"); String name = tag(value);
        if(!enumeration.variants().containsKey(name))throw new GenerationFailure(path,"UnknownTag",new UnknownTag(path,name));
        Descriptor content = enumeration.variants().get(name);
        if (enumeration == DESCRIPTORS.get("ExactJson") && Set.of("Decimal", "Array", "Object").contains(name)) {
            String key = name.equals("Decimal") ? "text" : name.equals("Array") ? "items" : "members";
            closedKeys(value, path, List.of("tag", key));
            return obj("tag", str(name), key, canonical(o(value).get(key), ((RecordDesc) content).fields().get(0).type(), path + "." + key));
        }
        if (content == null) { closedKeys(value, path, List.of("tag")); return variant(name); }
        String field = content instanceof RecordDesc ? "fields" : "value";
        closedKeys(value, path, List.of("tag", field));
        return obj("tag", str(name), field, canonical(o(value).get(field), content, path + "." + field));
    }
    /** Lean {@code keys} of the canonical reader, with the wire failure carried as the generation failure. */
    static void closedKeys(WireValue value, String path, List<String> expected) throws GenerationFailure {
        try { keys(value, path, expected); }
        catch (WireException failure) {
            WireFailure wire = failure.failure();
            throw new GenerationFailure(wire.path(), wire instanceof WireFailure.UnknownField ? "UnknownField" : ((WireFailure.Syntax) wire).message(), wire);
        }
    }
    /** Lean {@code SignatureJson.parse}: the whole text is admitted before the parse, so the first unpaired surrogate escape or exponent in text order fails. */
    public static WireValue readJson(String text) { admit(text); return new Reader(text).document(); }
    /** Lean {@code ExactJson.boundedJsonParse}: the text is admitted by the signature rule before the parse. */
    static WireValue boundedJsonParse(String text) { admit(text); return new Reader(text).document(); }
    /** Lean {@code ExactJson.admissionFailure}: the first failure of the text in text order, or empty. */
    static Optional<String> admissionFailure(String text) { return admissionFailureChars(text, 0, false); }
    /** Throws the first admission failure of the text. */
    static void admit(String text) {
        Optional<String> failure = admissionFailure(text);
        if (failure.isPresent()) throw admission(failure.get());
    }
    private static final String UNPAIRED_SURROGATE = "unpaired Unicode surrogate";
    /** Lean {@code ExactJson.admissionFailureChars}: the first failure from {@code at} in text order; {@code inString} tells whether {@code at} is inside a string. */
    static Optional<String> admissionFailureChars(String text, int at, boolean inString) {
        boolean in = inString;
        int i = at;
        while (i < text.length()) {
            char c = text.charAt(i);
            if (c == '"') { in = !in; i++; }
            else if (in && c == '\\' && i + 1 < text.length() && text.charAt(i + 1) == 'u') {
                OptionalInt code = hexCode(text, i + 2);
                if (code.isEmpty()) { i += 2; continue; }
                if (isLowSurrogate(code.getAsInt())) return Optional.of(UNPAIRED_SURROGATE);
                if (!isHighSurrogate(code.getAsInt())) { i += 6; continue; }
                OptionalInt low = i + 7 < text.length() && text.charAt(i + 6) == '\\' && text.charAt(i + 7) == 'u' ? hexCode(text, i + 8) : OptionalInt.empty();
                if (low.isEmpty() || !isLowSurrogate(low.getAsInt())) return Optional.of(UNPAIRED_SURROGATE);
                i += 12;
            }
            else if (in && c == '\\' && i + 1 < text.length()) i += 2;
            else {
                if (!in && (c == 'e' || c == 'E') && SemanticValues.exponentMagnitudeAtLimit(text, i + 1)) return Optional.of("exponent too large");
                i++;
            }
        }
        return Optional.empty();
    }
    /** Lean {@code ExactJson.isHighSurrogate}. */
    private static boolean isHighSurrogate(int code) { return 0xD800 <= code && code <= 0xDBFF; }
    /** Lean {@code ExactJson.isLowSurrogate}. */
    private static boolean isLowSurrogate(int code) { return 0xDC00 <= code && code <= 0xDFFF; }
    private static OptionalInt hexCode(String text, int from) {
        if (from + 4 > text.length()) return OptionalInt.empty();
        int code = 0;
        for (int i = from; i < from + 4; i++) {
            OptionalInt digit = hexDigit(text.charAt(i));
            if (digit.isEmpty()) return OptionalInt.empty();
            code = code * 16 + digit.getAsInt();
        }
        return OptionalInt.of(code);
    }
    private static OptionalInt hexDigit(char c) {
        return '0' <= c && c <= '9' ? OptionalInt.of(c - '0') : 'a' <= c && c <= 'f' ? OptionalInt.of(c - 'a' + 10) : 'A' <= c && c <= 'F' ? OptionalInt.of(c - 'A' + 10) : OptionalInt.empty();
    }
    private static WireException admission(String message) { return new WireException(new WireFailure.Syntax("$", message)); }
    private static final class Reader {
        private final String text; private int position;
        Reader(String text) { this.text = Objects.requireNonNull(text); }
        WireException fail(String condition) { return new WireException(new WireFailure.Syntax("$", "JSON " + condition + " at " + position)); }
        void whitespace() { while (position < text.length() && " \t\r\n".indexOf(text.charAt(position)) >= 0) position++; }
        char peek() { return position == text.length() ? '\0' : text.charAt(position); }
        boolean take(char c) { if (peek() == c) { position++; return true; } return false; }
        void need(char c) { whitespace(); if (!take(c)) throw fail("expected " + c); }
        WireValue document() { whitespace(); WireValue value = readValue(); whitespace(); if (position != text.length()) throw fail("trailing input"); return value; }
        /** One enclosing object or array whose members are being read. */
        private static final class Open {
            final List<Member> members; final List<WireValue> items; final Set<String> keys = new HashSet<>(); String key;
            Open(boolean object) { members = object ? new ArrayList<>() : null; items = object ? null : new ArrayList<>(); }
            boolean isObject() { return members != null; }
        }
        /** The iterative form of the mutual recursion of Lean {@code strictValue}, {@code strictObject}, and {@code strictArray}: a frame is pushed for each open object or array, and each completed value is delivered to the top frame. */
        WireValue readValue() {
            ArrayDeque<Open> open = new ArrayDeque<>();
            for (;;) {
                whitespace();
                WireValue done = strictValue(open);
                while (done != null) {
                    if (open.isEmpty()) return done;
                    Open frame = open.peek();
                    Optional<WireValue> closed = frame.isObject() ? strictObject(frame, done) : strictArray(frame, done);
                    if (closed.isEmpty()) break;
                    open.pop();
                    done = closed.get();
                }
            }
        }
        /** Lean {@code strictValue} for one value start: a completed scalar or empty container, or null after the frame of a non-empty object or array is pushed. */
        WireValue strictValue(ArrayDeque<Open> open) {
            if (take('{')) {
                whitespace();
                if (take('}')) return new ObjectValue(new ArrayList<>());
                Open frame = new Open(true); open.push(frame); key(frame); return null;
            }
            if (take('[')) {
                whitespace();
                if (take(']')) return arr(new ArrayList<>());
                open.push(new Open(false)); return null;
            }
            return scalar();
        }
        /** Lean {@code strictObject} after a member value: adds the member, then the closing brace or the next key. */
        Optional<WireValue> strictObject(Open frame, WireValue member) {
            frame.members.add(new Member(frame.key, member));
            whitespace();
            if (take('}')) return Optional.of(new ObjectValue(frame.members.stream()
                    .sorted(java.util.Comparator.comparing(Member::key, SemanticValues::compareCodePoints)).toList()));
            if (!take(',')) throw fail("object separator");
            whitespace(); key(frame);
            return Optional.empty();
        }
        /** Lean {@code strictArray} after an item: adds the item, then the closing bracket or the next item. */
        Optional<WireValue> strictArray(Open frame, WireValue item) {
            frame.items.add(item);
            whitespace();
            if (take(']')) return Optional.of(arr(frame.items));
            if (!take(',')) throw fail("array separator");
            return Optional.empty();
        }
        void key(Open frame) {
            String key = string(); if (!frame.keys.add(key)) throw fail("duplicate object key"); need(':'); frame.key = key;
        }
        WireValue scalar() {
            if (peek() == '"') return str(string());
            for (String token : List.of("true", "false", "null")) if (text.startsWith(token, position)) { position += token.length(); return token.equals("null") ? NIL : new BooleanValue(token.equals("true")); }
            int end = jsonNumberEnd(text, position); if (end < 0) throw fail("number");
            String spelling = text.substring(position, end); position = end;
            return leanNumber(spelling);
        }
        String string() {
            if (!take('"')) throw fail("string"); StringBuilder result = new StringBuilder(); while (position < text.length()) {
                char c = text.charAt(position++); if (c == '"') { requireUnicode(result.toString()); return result.toString(); } if (c < 32) throw fail("control character"); if (c != '\\') { result.append(c); continue; } if (position == text.length()) throw fail("escape");
                switch (text.charAt(position++)) {
                    case '"' -> result.append('"'); case '\\' -> result.append('\\'); case '/' -> result.append('/'); case 'b' -> result.append('\b'); case 'f' -> result.append('\f'); case 'n' -> result.append('\n'); case 'r' -> result.append('\r'); case 't' -> result.append('\t');
                    case 'u' -> { int code = 0; for (int i = 0; i < 4; i++) { int digit = peek() < 128 ? Character.digit(peek(), 16) : -1; if (digit < 0) throw fail("Unicode escape"); code = code * 16 + digit; position++; } result.append((char) code); }
                    default -> throw fail("escape");
                }
            }
            throw fail("unterminated string");
        }
    }

    public static WireValue encodeSlot(Slot<JsonValue> slot) {
        return switch (slot) { case Absent<JsonValue> unused -> variant("Absent"); case NullSlot<JsonValue> unused -> variant("Null"); case Present<JsonValue> present -> variant("Present", toExact(WireJson.toWire(present.value()))); };
    }

    static Slot<JsonValue> evaluateBinding(Context context, WireValue expression, Map<WireValue, Slot<JsonValue>> values) throws GenerationFailure {
        WireValue p = payload(expression);
        if (tag(expression).equals("Source")) { WireValue value = f(p, "value"); require(values.containsKey(f(value, "producer")), "$execution", "bound producer"); return SemanticValidation.projectedValue(context.typed().profile(), values.get(f(value, "producer")), a(f(value, "path")).stream().map(SemanticGraphWire::pathStep).toList()); }
        List<JsonMember> fields = new ArrayList<>();
        for (WireValue tuple : a(f(p, "fields"))) {
            Slot<JsonValue> value = evaluateBinding(context, a(tuple).get(1), values);
            if (value instanceof Present<JsonValue> present) fields.add(new JsonMember(s(a(tuple).get(0)), present.value()));
            else if (value instanceof NullSlot<JsonValue>) fields.add(new JsonMember(s(a(tuple).get(0)), ExactJson.NIL));
        }
        return new Present<>(new JsonObj(fields));
    }
}
