// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import java.math.BigInteger;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import neco.quotient.RefinementOutcome;
import neco.quotient.ResidualSet;
import neco.quotient.Result;
import necoherence.composition.SemanticComposition.DefinitionRef;
import necoherence.composition.SemanticComposition.PathStep;
import necoherence.composition.SemanticComposition.SlotContract;
import necoherence.composition.SemanticComposition.TypeRef;
import necoherence.semantic.SemanticValues.Slot;
import necoherence.semantic.ExactJson.JsonValue;
import necoherence.semantic.SemanticValues.ValueCondition;

public final class SemanticTypes {
    private SemanticTypes() {}

    public record SourceRef(String repository, String revision, String path, String contentDigest, String documentId,
            Optional<BigInteger> declaredRevision) {}

    public record ProfileRef(String identity, String revision, String contentDigest) {}

    public record OccurrenceRef(SourceRef source, List<String> pointer) {
        public OccurrenceRef { Objects.requireNonNull(source); pointer = List.copyOf(pointer); }
    }

    public sealed interface IntegerDomain permits UnboundedDomain, InclusiveDomain {}
    public record UnboundedDomain() implements IntegerDomain {}
    public record InclusiveDomain(BigInteger minimum, BigInteger maximum) implements IntegerDomain {}

    public enum IntegerForm { NUMBER, INTEGRAL_DECIMAL, DECIMAL_STRING }

    public record IntegerDomainBinding(String name, ProfileRef reference, IntegerDomain range, List<IntegerForm> forms) {
        public IntegerDomainBinding { forms = List.copyOf(forms); }
    }

    public record NumberModel(boolean decimals) {}

    public enum BytesAlphabet { STANDARD, URL_SAFE, EITHER }

    public enum StringLengthUnit { UTF8_BYTES, UNICODE_SCALARS, GRAPHEMES }

    public record SourceIdentity(String repository, String revision, String path, String contentDigest) {}

    public record Origin(SourceIdentity source, List<String> locator) {
        public Origin { Objects.requireNonNull(source); locator = List.copyOf(locator); }
    }

    public record GraphemeComponent(String unicodeVersion, String uax29Revision, String clusterProfile) {}

    public enum GraphemeProperty { OTHER, CR, LF, CONTROL, EXTEND, ZWJ, REGIONAL_INDICATOR, PREPEND, SPACING_MARK, L, V, T, LV, LVT }

    public enum IndicProperty { OTHER, CONSONANT, EXTEND, LINKER }

    public record GraphemeRange(BigInteger first, BigInteger last, GraphemeProperty property) {}

    public record CodepointRange(BigInteger first, BigInteger last) {}

    public record IndicRange(BigInteger first, BigInteger last, IndicProperty property) {}

    public record GraphemeSource(String role, Origin origin) {
        public GraphemeSource { Objects.requireNonNull(role); Objects.requireNonNull(origin); }
    }

    public record GraphemeRules(ProfileRef reference, List<GraphemeRange> properties, List<CodepointRange> extendedPictographic,
            List<IndicRange> indicConjunct, GraphemeComponent component, String tableSha256, List<GraphemeSource> sources) {
        public GraphemeRules {
            Objects.requireNonNull(reference);
            properties = List.copyOf(properties);
            extendedPictographic = List.copyOf(extendedPictographic);
            indicConjunct = List.copyOf(indicConjunct);
            Objects.requireNonNull(component);
            Objects.requireNonNull(tableSha256);
            sources = List.copyOf(sources);
        }
    }

    public record BytesPolicy(ProfileRef reference, boolean paddingOptional, BytesAlphabet alphabet,
            boolean strictPadBits, Optional<String> wrapper) {}

    public record DfaTransition(BigInteger fromState, BigInteger first, BigInteger last, BigInteger toState) {}
    public record DfaSpec(BigInteger stateCount, BigInteger initialState, List<BigInteger> acceptingStates,
            List<DfaTransition> transitions) {
        public DfaSpec { acceptingStates = List.copyOf(acceptingStates); transitions = List.copyOf(transitions); }
    }
    public record CalendarRule(boolean allowSecond60, BigInteger minimumYear, BigInteger maximumYear,
            boolean rejectUtcYearOutsideRange) {}

    public sealed interface FormatRule permits LiteralRule, SequenceRule, OptionalRule, LabelsRule, BoundedRule,
            AsciiDfaRule, IdentifierRule, TimestampRule, AbsoluteUriRule, LanguageTagRule, ChoiceRule, TextRule, NotRule {}
    public record LiteralRule(String value) implements FormatRule {}
    public record SequenceRule(List<FormatRule> parts) implements FormatRule {
        public SequenceRule { parts = List.copyOf(parts); }
    }
    public record OptionalRule(FormatRule rule) implements FormatRule {}
    public record LabelsRule(String separator, BigInteger minCount, Optional<BigInteger> maxCount,
            Optional<BigInteger> totalMax, FormatRule rule) implements FormatRule {}
    public record BoundedRule(StringLengthUnit unit, BigInteger maximum, FormatRule rule) implements FormatRule {}
    public record AsciiDfaRule(DfaSpec spec) implements FormatRule {}
    public record IdentifierRule(String firstAlphabet, String restAlphabet, Optional<BigInteger> exactLength,
            BigInteger minLength, Optional<BigInteger> maxLength, List<String> forbidden) implements FormatRule {
        public IdentifierRule { forbidden = List.copyOf(forbidden); }
    }
    public record TimestampRule(CalendarRule rule) implements FormatRule {}
    public record AbsoluteUriRule(Optional<BigInteger> maxBytes) implements FormatRule {}
    public record LanguageTagRule(List<String> grandfathered) implements FormatRule {
        public LanguageTagRule { grandfathered = List.copyOf(grandfathered); }
    }
    public record ChoiceRule(List<FormatRule> rules) implements FormatRule {
        public ChoiceRule { rules = List.copyOf(rules); }
    }
    public record TextRule() implements FormatRule {}
    public record NotRule(FormatRule rule) implements FormatRule {}

    public record LengthBound(StringLengthUnit unit, Optional<BigInteger> minimum, Optional<BigInteger> maximum) {}

    public sealed interface FormatUse permits NamedFormat, InlineFormat {}
    public record NamedFormat(String name) implements FormatUse {}
    public record InlineFormat(FormatRule rule) implements FormatUse {}

    public record FormatBinding(String name, ProfileRef reference, FormatRule rule) {}

    public record LengthSpec(Optional<BigInteger> minimum, Optional<BigInteger> maximum) {}
    public record BooleanSpec(Optional<Boolean> constValue, Optional<Boolean> defaultValue) {}
    public record IntegerSpec(Optional<String> domain, Optional<BigInteger> minimum, Optional<BigInteger> maximum,
            Optional<BigInteger> constValue, Optional<List<BigInteger>> enumValues, Optional<BigInteger> defaultValue) {}
    public record DecimalBound(BigInteger mantissa, BigInteger scale, boolean exclusive) {}
    public record DecimalSpec(Optional<DecimalBound> minimum, Optional<DecimalBound> maximum) {}
    public record StringSpec(Optional<FormatUse> format, List<LengthBound> lengths, Optional<String> wrapper,
            Optional<String> constValue, Optional<List<String>> enumValues, List<String> examples,
            Optional<String> defaultValue) {}

    public sealed interface WrapperPayload permits BytesPayload, TextPayload {}
    public record BytesPayload() implements WrapperPayload {}
    public record TextPayload(Optional<String> format) implements WrapperPayload {}
    public record Wrapper(String name, String key, WrapperPayload payload) {}

    public sealed interface SealedLeaf permits StringLeaf, IntegerLeaf {}
    public record StringLeaf(StringSpec spec) implements SealedLeaf {}
    public record IntegerLeaf(IntegerSpec spec) implements SealedLeaf {}
    public record SealedField(String key, boolean required, SealedLeaf leaf) {}
    public enum SealedExtras { REJECT, ANY }
    public record SealedForm(String tag, List<SealedField> fields, SealedExtras extras) {}
    public record TagModel(String key, Optional<String> format, List<SealedForm> sealed) {}
    public record SealedRefinement(String key, SealedLeaf leaf) {}

    public sealed interface ObjectClass permits SealedClass, WrapperClass, OrdinaryClass {}
    public record SealedClass(SealedForm form) implements ObjectClass {}
    public record WrapperClass(Wrapper wrapper) implements ObjectClass {}
    public record OrdinaryClass() implements ObjectClass {}

    public record VersionedSemanticProfile(ProfileRef reference, List<SourceRef> sourceRefs,
            List<IntegerDomainBinding> integerDomains, String defaultIntegerDomain, NumberModel numbers,
            Optional<GraphemeRules> graphemeRules, List<FormatBinding> formatBindings,
            Optional<BytesPolicy> bytesPolicy, List<Wrapper> wrappers, Optional<TagModel> tag) {}

    public record FieldSpec(String wireName, SlotContract slot, OccurrenceRef origin) {}
    public record ElementContract(TypeRef typeRef, boolean nullable) {}

    public sealed interface ExtraMembers permits RejectExtras, AllowExtras {}
    public record RejectExtras() implements ExtraMembers {}
    public record AllowExtras(Optional<FormatUse> keyFormat, ElementContract value) implements ExtraMembers {}

    public record ProductSpec(List<FieldSpec> fields, ExtraMembers extras) {}
    public record ArraySpec(ElementContract item, Optional<BigInteger> minLength, Optional<BigInteger> maxLength) {}

    public enum ValueKind { NULL, BOOLEAN, NUMBER, STRING, ARRAY, OBJECT }

    public sealed interface MemberTest permits AbsentTest, FormatTest {}
    public record AbsentTest() implements MemberTest {}
    public record FormatTest(String name) implements MemberTest {}
    public record MemberCheck(String key, MemberTest test) {}

    public sealed interface BranchSelector permits InternalTagSelector, MemberShapeSelector, KindSelector, OtherwiseSelector {}
    public record InternalTagSelector() implements BranchSelector {}
    public record MemberShapeSelector(List<MemberCheck> tests) implements BranchSelector {}
    public record KindSelector(ValueKind kind) implements BranchSelector {}
    public record OtherwiseSelector() implements BranchSelector {}

    public record UnionBranch(TypeRef target, String wireTag, BranchSelector selector, OccurrenceRef origin) {}
    public record UnionSpec(List<UnionBranch> branches) {}

    public enum UnknownKind { ANY, ORDINARY_OBJECT }

    public sealed interface TypeShape permits BooleanShape, IntegerShape, DecimalShape, StringShape, BytesShape,
            ProductShape, ArrayShape, AliasShape, TaggedUnionShape, SealedShape, NeverShape, UnknownShape,
            UnitShape, RawBodyShape, OpaqueShape {}
    public record BooleanShape(BooleanSpec spec) implements TypeShape {}
    public record IntegerShape(IntegerSpec spec) implements TypeShape {}
    public record DecimalShape(DecimalSpec spec) implements TypeShape {}
    public record StringShape(StringSpec spec) implements TypeShape {}
    public record BytesShape(LengthSpec spec) implements TypeShape {}
    public record ProductShape(ProductSpec spec) implements TypeShape {}
    public record ArrayShape(ArraySpec spec) implements TypeShape {}
    public record AliasShape(TypeRef target, String referenceText) implements TypeShape {}
    public record TaggedUnionShape(UnionSpec spec) implements TypeShape {}
    public record SealedShape(String tag, List<SealedRefinement> refinements) implements TypeShape {}
    public record NeverShape() implements TypeShape {}
    public record UnknownShape(UnknownKind kind) implements TypeShape {}
    public record UnitShape() implements TypeShape {}
    public record RawBodyShape(String encoding) implements TypeShape {}
    public record OpaqueShape(String typeName) implements TypeShape {}

    public record TypeNode(TypeRef ref, TypeShape shape, Optional<String> description,
            List<OccurrenceRef> attributes, List<OccurrenceRef> extensions) {}

    public static final class SemanticGraph {
        private final VersionedSemanticProfile profile;
        private final List<TypeNode> nodes;
        private final List<SourceRef> sourceRefs;
        private final java.util.Map<TypeRef, TypeNode> index = new java.util.HashMap<>();
        private final long edges;

        public SemanticGraph(VersionedSemanticProfile profile, List<TypeNode> nodes, List<SourceRef> sourceRefs) {
            this.profile = Objects.requireNonNull(profile);
            this.nodes = List.copyOf(nodes);
            this.sourceRefs = List.copyOf(sourceRefs);
            long count = 0;
            for (TypeNode node : this.nodes) {
                index.putIfAbsent(node.ref(), node);
                count += typeChildren(node.shape()).size();
            }
            this.edges = count;
        }

        public VersionedSemanticProfile profile() { return profile; }

        public List<TypeNode> nodes() { return nodes; }

        public List<SourceRef> sourceRefs() { return sourceRefs; }

        public Optional<TypeNode> findType(TypeRef ref) { return Optional.ofNullable(index.get(ref)); }

        long edgeCount() { return edges; }

    }

    public sealed interface SemanticReason permits UnknownFormat, MissingGraphemeRules, MissingBytesPolicy,
            UnknownIntegerDomain, UnknownWrapper, WrapperPayloadReason, UnknownSealedTag, DecimalNotAdmitted,
            IntegerBound, OpaqueType, MissingTagModel, UninterpretedExtension, UnresolvedType, InvalidProfile,
            MembershipBound, CertificateMismatchReason, ProjectionUnavailable {
        default ReasonDisposition disposition() {
            return switch (this) {
                case UnknownFormat unused -> ReasonDisposition.RESIDUAL;
                case MissingGraphemeRules unused -> ReasonDisposition.RESIDUAL;
                case MissingBytesPolicy unused -> ReasonDisposition.RESIDUAL;
                case UnknownIntegerDomain unused -> ReasonDisposition.RESIDUAL;
                case UnknownWrapper unused -> ReasonDisposition.RESIDUAL;
                case WrapperPayloadReason unused -> ReasonDisposition.FAILED;
                case UnknownSealedTag unused -> ReasonDisposition.RESIDUAL;
                case DecimalNotAdmitted unused -> ReasonDisposition.FAILED;
                case IntegerBound unused -> ReasonDisposition.FAILED;
                case OpaqueType unused -> ReasonDisposition.RESIDUAL;
                case MissingTagModel unused -> ReasonDisposition.RESIDUAL;
                case UninterpretedExtension unused -> ReasonDisposition.RESIDUAL;
                case UnresolvedType unused -> ReasonDisposition.RESIDUAL;
                case InvalidProfile unused -> ReasonDisposition.FAILED;
                case MembershipBound unused -> ReasonDisposition.STOPPED;
                case CertificateMismatchReason unused -> ReasonDisposition.FAILED;
                case ProjectionUnavailable unused -> ReasonDisposition.RESIDUAL;
            };
        }
    }
    public record UnknownFormat(String name) implements SemanticReason {}
    public record MissingGraphemeRules() implements SemanticReason {}
    public record MissingBytesPolicy() implements SemanticReason {}
    public record UnknownIntegerDomain(String name) implements SemanticReason {}
    public record UnknownWrapper(String name) implements SemanticReason {}
    public record WrapperPayloadReason(String name) implements SemanticReason {}
    public record UnknownSealedTag(String tag) implements SemanticReason {}
    public record DecimalNotAdmitted() implements SemanticReason {}
    public record IntegerBound() implements SemanticReason {}
    public record OpaqueType(String name) implements SemanticReason {}
    public record MissingTagModel() implements SemanticReason {}
    public record UnresolvedType() implements SemanticReason {}
    public record MembershipBound() implements SemanticReason {}
    public record CertificateMismatchReason(String condition) implements SemanticReason {}
    public record UninterpretedExtension(String key) implements SemanticReason {}
    public record InvalidProfile(String condition) implements SemanticReason {}
    public record ProjectionUnavailable(String condition) implements SemanticReason {}

    public record SemanticObligation(TypeRef typeRef, OccurrenceRef origin, List<PathStep> valuePath,
            ProfileRef profile, SemanticReason reason) {
        public SemanticObligation { valuePath = List.copyOf(valuePath); }
    }

    public record ValueFailure(TypeRef typeRef, DefinitionRef definitionRef, OccurrenceRef origin,
            List<PathStep> valuePath, ValueCondition condition, Slot<JsonValue> observed,
            List<TypeRef> referenceTrace) {
        public ValueFailure { valuePath = List.copyOf(valuePath); referenceTrace = List.copyOf(referenceTrace); }
    }

    public sealed interface ValueDecision permits Accepted, Rejected, Unresolved {}
    public record Accepted() implements ValueDecision {}
    public record Rejected(ValueFailure failure) implements ValueDecision {}
    public record Unresolved(List<SemanticObligation> obligations) implements ValueDecision {
        public Unresolved { obligations = List.copyOf(obligations); }
    }

    public enum ReasonDisposition { RESIDUAL, STOPPED, FAILED }

    public static ReasonDisposition classifyDispositions(List<ReasonDisposition> classes) {
        if (classes.isEmpty() || classes.contains(ReasonDisposition.FAILED)) return ReasonDisposition.FAILED;
        return classes.contains(ReasonDisposition.STOPPED) ? ReasonDisposition.STOPPED : ReasonDisposition.RESIDUAL;
    }

    public record EvaluationProvenance(String operation, TypeRef typeRef, List<PathStep> valuePath) {
        public EvaluationProvenance {
            Objects.requireNonNull(operation);
            Objects.requireNonNull(typeRef);
            valuePath = List.copyOf(valuePath);
        }
    }

    public record SemanticJudgment(EvaluationProvenance provenance, ValueDecision decision) {}

    public enum SemanticDecisionCondition { VALUE_REJECTED, EMPTY_REASONS, INVALID_MEANING }

    public record SemanticDecisionFailure(EvaluationProvenance provenance, ValueDecision decision,
            ResidualSet<SemanticObligation> residuals, List<ReasonDisposition> classifications,
            SemanticDecisionCondition condition) {
        public SemanticDecisionFailure { classifications = List.copyOf(classifications); }
    }

    public static Result<RefinementOutcome<SemanticJudgment, SemanticObligation, List<SemanticObligation>>,
            SemanticDecisionFailure> classifyValueDecision(EvaluationProvenance provenance, ValueDecision decision) {
        if (decision instanceof Accepted) return new Result.Accepted<>(new RefinementOutcome.Resolved<>(
                new SemanticJudgment(provenance, decision)));
        if (decision instanceof Rejected) return new Result.Rejected<>(new SemanticDecisionFailure(provenance, decision,
                ResidualSet.of(List.of()), List.of(ReasonDisposition.FAILED), SemanticDecisionCondition.VALUE_REJECTED));
        List<SemanticObligation> reasons = ((Unresolved) decision).obligations();
        List<ReasonDisposition> classes = reasons.stream().map(reason -> reason.reason().disposition()).toList();
        ResidualSet<SemanticObligation> residuals = ResidualSet.of(reasons.stream()
                .filter(reason -> reason.reason().disposition() == ReasonDisposition.RESIDUAL).toList());
        List<SemanticObligation> stops = reasons.stream()
                .filter(reason -> reason.reason().disposition() == ReasonDisposition.STOPPED).toList();
        SemanticJudgment judgment = new SemanticJudgment(provenance, decision);
        if (reasons.isEmpty()) return new Result.Rejected<>(new SemanticDecisionFailure(provenance, decision, residuals,
                classes, SemanticDecisionCondition.EMPTY_REASONS));
        return switch (classifyDispositions(classes)) {
            case RESIDUAL -> new Result.Accepted<>(new RefinementOutcome.Residual<>(judgment, residuals));
            case STOPPED -> new Result.Accepted<>(new RefinementOutcome.Stopped<>(judgment, residuals, stops));
            case FAILED -> new Result.Rejected<>(new SemanticDecisionFailure(provenance, decision, residuals, classes,
                    SemanticDecisionCondition.INVALID_MEANING));
        };
    }

    public static List<TypeRef> typeChildren(TypeShape shape) {
        return switch (shape) {
            case ProductShape product -> java.util.stream.Stream.concat(product.spec().fields().stream().map(field -> field.slot().typeRef()),
                    extraChildren(product.spec().extras()).stream()).toList();
            case ArrayShape array -> List.of(array.spec().item().typeRef());
            case AliasShape alias -> List.of(alias.target());
            case TaggedUnionShape union -> union.spec().branches().stream().map(UnionBranch::target).toList();
            default -> List.of();
        };
    }

    private static List<TypeRef> extraChildren(ExtraMembers extras) {
        return switch (extras) {
            case RejectExtras reject -> List.of();
            case AllowExtras allow -> List.of(allow.value().typeRef());
        };
    }

    public static long formatRulesDepth(List<FormatRule> rules) { return rules.stream().mapToLong(SemanticTypes::formatRuleDepth).max().orElse(0); }

    /** The Lean formatRuleDepth: the nesting depth of one format rule. */
    public static long formatRuleDepth(FormatRule rule) {
        return switch (rule) {
            case SequenceRule value -> 1 + formatRulesDepth(value.parts());
            case OptionalRule value -> 1 + formatRuleDepth(value.rule());
            case LabelsRule value -> 1 + formatRuleDepth(value.rule());
            case BoundedRule value -> 1 + formatRuleDepth(value.rule());
            case ChoiceRule value -> 1 + formatRulesDepth(value.rules());
            case NotRule value -> 1 + formatRuleDepth(value.rule());
            default -> 1;
        };
    }
}
