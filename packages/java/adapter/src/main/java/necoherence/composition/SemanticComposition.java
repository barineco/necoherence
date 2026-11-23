// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.composition;

import necoherence.semantic.ExactJson.JsonValue;
import static necoherence.semantic.SemanticValues.*;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;

import necoherence.semantic.SemanticValues.Slot;
import necoherence.semantic.SemanticValues.ValueRejection;
import necoherence.semantic.SemanticValues.WireValue;
import necoherence.typed.TypedMapping;
import necoherence.semantic.SemanticTypes;
import necoherence.semantic.SemanticTypes.AliasShape;
import necoherence.semantic.SemanticTypes.TypeNode;
import necoherence.semantic.SemanticTypes.TypeShape;

/**
 * Typed composition declarations and preparation of composition inputs.
 */
public final class SemanticComposition {
    private static final BigInteger DEFAULT_MAX_EXPANDED_STATES = BigInteger.valueOf(10_000);
    private static final BigInteger DEFAULT_MAX_BINDING_CANDIDATES = BigInteger.valueOf(100_000);
    private static final BigInteger DEFAULT_MAX_TYPE_OBLIGATIONS = BigInteger.valueOf(10_000);
    private static final BigInteger DEFAULT_MAX_BRANCH_NODES = BigInteger.valueOf(100_000);
    private static final BigInteger DEFAULT_MAX_SAMPLE_LENGTH = BigInteger.valueOf(32);

    private SemanticComposition() {}

            /**
     * The semantic profile and sources against which a composition is interpreted.
     * @param profile corresponding Lean field
     * @param sources corresponding Lean field
     */
    public record SemanticBasis(necoherence.semantic.SemanticTypes.VersionedSemanticProfile profile,
            List<necoherence.semantic.SemanticTypes.SourceRef> sources) {
        public SemanticBasis {
            profile = Objects.requireNonNull(profile);
            sources = copy(sources);
        }

        public static SemanticBasis of(WireValue graph) {
            return of(necoherence.semantic.SemanticGraphWire.decodeGraph(graph));
        }

        public static SemanticBasis of(necoherence.semantic.SemanticTypes.SemanticGraph graph) {
            return new SemanticBasis(graph.profile(), graph.sourceRefs());
        }
    }

            /**
     * A revision-qualified function identity.
     * @param identity corresponding Lean field
     * @param revision corresponding Lean field
     * @param contentDigest corresponding Lean field
     */
    public record FunctionRef(String identity, String revision, String contentDigest) {
        public FunctionRef {
            identity = Objects.requireNonNull(identity);
            revision = Objects.requireNonNull(revision);
            contentDigest = Objects.requireNonNull(contentDigest);
        }
    }

            /**
     * Java representation of the Lean InputId definition.
     * @param value corresponding Lean field
     */
    public record InputId(String value) { public InputId { value = Objects.requireNonNull(value); } }
    /**
     * Java representation of the Lean PortId definition.
     * @param value corresponding Lean field
     */
    public record PortId(String value) { public PortId { value = Objects.requireNonNull(value); } }
    /**
     * Java representation of the Lean SiteId definition.
     * @param value corresponding Lean field
     */
    public record SiteId(String value) { public SiteId { value = Objects.requireNonNull(value); } }
            /**
     * Java representation of the Lean OutcomeId definition.
     * @param value corresponding Lean field
     */
    public record OutcomeId(String value) { public OutcomeId { value = Objects.requireNonNull(value); } }
    /**
     * Java representation of the Lean GoalPortId definition.
     * @param value corresponding Lean field
     */
    public record GoalPortId(String value) { public GoalPortId { value = Objects.requireNonNull(value); } }
    /**
     * Java representation of the Lean LotId definition.
     * @param value corresponding Lean field
     */
    public record LotId(String value) { public LotId { value = Objects.requireNonNull(value); } }
            /**
     * Java representation of the Lean RequirementId definition.
     * @param value corresponding Lean field
     */
    public record RequirementId(String value) { public RequirementId { value = Objects.requireNonNull(value); } }
    /**
     * Java representation of the Lean ProductionId definition.
     * @param value corresponding Lean field
     */
    public record ProductionId(String value) { public ProductionId { value = Objects.requireNonNull(value); } }
    /**
     * Java representation of the Lean GuardId definition.
     * @param value corresponding Lean field
     */
    public record GuardId(String value) { public GuardId { value = Objects.requireNonNull(value); } }
            /**
     * Java representation of the Lean FailureEmbeddingId definition.
     * @param value corresponding Lean field
     */
    public record FailureEmbeddingId(String value) { public FailureEmbeddingId { value = Objects.requireNonNull(value); } }

            /**
     * A source-qualified semantic type reference.
     * @param source corresponding Lean field
     * @param definitionName corresponding Lean field
     * @param pointer corresponding Lean field
     */
    public record TypeRef(necoherence.semantic.SemanticTypes.SourceRef source, String definitionName, List<String> pointer) {
        public TypeRef {
            source = Objects.requireNonNull(source);
            definitionName = Objects.requireNonNull(definitionName);
            pointer = copy(pointer);
        }
    }

            /**
     * A source-qualified semantic definition reference.
     * @param source corresponding Lean field
     * @param name corresponding Lean field
     */
    public record DefinitionRef(necoherence.semantic.SemanticTypes.SourceRef source, String name) {
        public DefinitionRef {
            source = Objects.requireNonNull(source);
            name = Objects.requireNonNull(name);
        }
    }

            /**
     * A required and nullable contract for one semantic type.
     * @param typeRef corresponding Lean field
     * @param required corresponding Lean field
     * @param nullable corresponding Lean field
     */
    public record SlotContract(TypeRef typeRef, boolean required, boolean nullable) {
        public SlotContract { typeRef = Objects.requireNonNull(typeRef); }
    }

        /**
     * One projection path step.
     */
    public sealed interface PathStep permits Field, Index, Variant {}
    /**
     * Java representation of the Lean Field definition.
     * @param wireName corresponding Lean field
     */
    public record Field(String wireName) implements PathStep { public Field { wireName = Objects.requireNonNull(wireName); } }
    /**
     * Java representation of the Lean Index definition.
     * @param index corresponding Lean field
     */
    public record Index(BigInteger index) implements PathStep { public Index { index = natural(index); } }
            /**
     * Java representation of the Lean Variant definition.
     * @param wireTag corresponding Lean field
     */
    public record Variant(String wireTag) implements PathStep { public Variant { wireTag = Objects.requireNonNull(wireTag); } }

    /**

     * Java representation of the Lean TypePair definition.

     * @param source corresponding Lean field

     * @param destination corresponding Lean field

     * @param sourceTag corresponding Lean field

     */

    public record TypePair(SlotContract source, SlotContract destination, Optional<String> sourceTag) {
        public TypePair {
            source = Objects.requireNonNull(source);
            destination = Objects.requireNonNull(destination);
            sourceTag = optional(sourceTag);
        }
    }

        /**
     * Java representation of the Lean InclusionRule definition.
     */
    public enum InclusionRule {
        SAME_DEFINED_TYPE, EMPTY_SOURCE, BOOLEAN, INTEGER_INTERSECTION, FINITE_STRINGS,
        STRING_CONDITIONS, BYTES_LENGTH, UNIT, UNFOLD_SOURCE, UNFOLD_DESTINATION,
        ARRAY, PRODUCT, SOURCE_UNION, DESTINATION_UNION
    }

            /**
     * Java representation of the Lean PairEntry definition.
     * @param pair corresponding Lean field
     * @param sourceShape corresponding Lean field
     * @param destinationShape corresponding Lean field
     * @param rule corresponding Lean field
     * @param children corresponding Lean field
     */
    public record PairEntry(TypePair pair, necoherence.semantic.SemanticTypes.TypeShape sourceShape,
            necoherence.semantic.SemanticTypes.TypeShape destinationShape,
            InclusionRule rule, List<BigInteger> children) {
        public PairEntry {
            pair = Objects.requireNonNull(pair);
            sourceShape = Objects.requireNonNull(sourceShape);
            destinationShape = Objects.requireNonNull(destinationShape);
            rule = Objects.requireNonNull(rule);
            children = copyNaturals(children);
        }
    }

            /**
     * Java representation of the Lean InclusionCertificate definition.
     * @param basis corresponding Lean field
     * @param source corresponding Lean field
     * @param destination corresponding Lean field
     * @param emptyTypes corresponding Lean field
     * @param pairs corresponding Lean field
     * @param root corresponding Lean field
     */
    public record InclusionCertificate(SemanticBasis basis, SlotContract source,
            SlotContract destination, List<TypeRef> emptyTypes, List<PairEntry> pairs, BigInteger root) {
        public InclusionCertificate {
            basis = Objects.requireNonNull(basis);
            source = Objects.requireNonNull(source);
            destination = Objects.requireNonNull(destination);
            emptyTypes = copy(emptyTypes);
            pairs = copy(pairs);
            root = natural(root);
        }
    }

        /**
     * Java representation of the Lean TypeObligationReason definition.
     */
    public sealed interface TypeObligationReason permits Meaning, ConstraintImplication, Presence,
            UnionRemainder, ExtraField, Inhabitation, ObligationBoundExhausted {}
    /**
     * Java representation of the Lean Meaning definition.
     * @param obligations corresponding Lean field
     */
    public record Meaning(List<necoherence.semantic.SemanticTypes.SemanticObligation> obligations) implements TypeObligationReason {
        public Meaning { obligations = copy(obligations); }
    }
            /**
     * Java representation of the Lean ConstraintImplication definition.
     */
    public record ConstraintImplication() implements TypeObligationReason {}
    /**
     * Java representation of the Lean Presence definition.
     */
    public record Presence() implements TypeObligationReason {}
    /**
     * Java representation of the Lean UnionRemainder definition.
     */
    public record UnionRemainder() implements TypeObligationReason {}
            /**
     * Java representation of the Lean ExtraField definition.
     * @param name corresponding Lean field
     */
    public record ExtraField(String name) implements TypeObligationReason { public ExtraField { name = Objects.requireNonNull(name); } }
    /**
     * Java representation of the Lean Inhabitation definition.
     */
    public record Inhabitation() implements TypeObligationReason {}
    /**
     * Java representation of the Lean ObligationBoundExhausted definition.
     */
    public record ObligationBoundExhausted() implements TypeObligationReason {}

            /**
     * Java representation of the Lean TypeObligation definition.
     * @param pair corresponding Lean field
     * @param path corresponding Lean field
     * @param reason corresponding Lean field
     */
    public record TypeObligation(TypePair pair, List<PathStep> path, TypeObligationReason reason) {
        public TypeObligation {
            pair = Objects.requireNonNull(pair);
            path = copy(path);
            reason = Objects.requireNonNull(reason);
        }
    }

        /**
     * Java representation of the Lean InclusionFailure definition.
     */
    public sealed interface InclusionFailure permits InclusionBasisMismatch, ContractMismatch,
            UndefinedMeaning, MissingPair, PairMismatch, RuleMismatch, ChildCoverage,
            ForgedEmptiness, CounterexampleMismatch, UnresolvedInclusion {}
            /**
     * Java representation of the Lean InclusionBasisMismatch definition.
     */
    public record InclusionBasisMismatch() implements InclusionFailure {}
    /**
     * Java representation of the Lean ContractMismatch definition.
     */
    public record ContractMismatch() implements InclusionFailure {}
    /**
     * Java representation of the Lean UndefinedMeaning definition.
     * @param obligations corresponding Lean field
     */
    public record UndefinedMeaning(List<necoherence.semantic.SemanticTypes.SemanticObligation> obligations) implements InclusionFailure { public UndefinedMeaning { obligations = copy(obligations); } }
            /**
     * Java representation of the Lean MissingPair definition.
     */
    public record MissingPair() implements InclusionFailure {}
    /**
     * Java representation of the Lean PairMismatch definition.
     * @param index corresponding Lean field
     */
    public record PairMismatch(BigInteger index) implements InclusionFailure { public PairMismatch { index = natural(index); } }
    /**
     * Java representation of the Lean RuleMismatch definition.
     * @param index corresponding Lean field
     */
    public record RuleMismatch(BigInteger index) implements InclusionFailure { public RuleMismatch { index = natural(index); } }
            /**
     * Java representation of the Lean ChildCoverage definition.
     * @param index corresponding Lean field
     */
    public record ChildCoverage(BigInteger index) implements InclusionFailure { public ChildCoverage { index = natural(index); } }
    /**
     * Java representation of the Lean ForgedEmptiness definition.
     */
    public record ForgedEmptiness() implements InclusionFailure {}
    /**
     * Java representation of the Lean CounterexampleMismatch definition.
     */
    public record CounterexampleMismatch() implements InclusionFailure {}
            /**
     * Java representation of the Lean UnresolvedInclusion definition.
     * @param obligation corresponding Lean field
     */
    public record UnresolvedInclusion(TypeObligation obligation) implements InclusionFailure { public UnresolvedInclusion { obligation = Objects.requireNonNull(obligation); } }

    /**

     * Java representation of the Lean ProducerRef definition.

     */

    public sealed interface ProducerRef permits InitialProducer, InvocationOutcomeProducer {}
            /**
     * Java representation of the Lean InitialProducer definition.
     * @param id corresponding Lean field
     */
    public record InitialProducer(InputId id) implements ProducerRef { public InitialProducer { id = Objects.requireNonNull(id); } }
    /**
     * Java representation of the Lean InvocationOutcomeProducer definition.
     * @param site corresponding Lean field
     * @param outcome corresponding Lean field
     * @param port corresponding Lean field
     */
    public record InvocationOutcomeProducer(SiteId site, OutcomeId outcome, PortId port) implements ProducerRef {
        public InvocationOutcomeProducer {
            site = Objects.requireNonNull(site); outcome = Objects.requireNonNull(outcome); port = Objects.requireNonNull(port);
        }
    }
            /**
     * Java representation of the Lean ValueRef definition.
     * @param producer corresponding Lean field
     * @param path corresponding Lean field
     */
    public record ValueRef(ProducerRef producer, List<PathStep> path) {
        public ValueRef { producer = Objects.requireNonNull(producer); path = copy(path); }
    }

        /**
     * Java representation of the Lean SourceConstraint definition.
     */
    public sealed interface SourceConstraint permits AnyCompatible, InitialOnly, ProducedBy {}
    /**
     * Java representation of the Lean AnyCompatible definition.
     */
    public record AnyCompatible() implements SourceConstraint {}
    /**
     * Java representation of the Lean InitialOnly definition.
     * @param id corresponding Lean field
     * @param path corresponding Lean field
     */
    public record InitialOnly(InputId id, List<PathStep> path) implements SourceConstraint {
        public InitialOnly { id = Objects.requireNonNull(id); path = copy(path); }
    }
            /**
     * Java representation of the Lean ProducedBy definition.
     * @param site corresponding Lean field
     * @param outcome corresponding Lean field
     * @param port corresponding Lean field
     * @param path corresponding Lean field
     */
    public record ProducedBy(SiteId site, OutcomeId outcome, PortId port, List<PathStep> path)
            implements SourceConstraint {
        public ProducedBy {
            site = Objects.requireNonNull(site); outcome = Objects.requireNonNull(outcome);
            port = Objects.requireNonNull(port); path = copy(path);
        }
    }

        /**
     * Java representation of the Lean ResourceLotRef definition.
     */
    public sealed interface ResourceLotRef permits InitialLot, ProducedLot {}
    /**
     * Java representation of the Lean InitialLot definition.
     * @param id corresponding Lean field
     */
    public record InitialLot(LotId id) implements ResourceLotRef { public InitialLot { id = Objects.requireNonNull(id); } }
    /**
     * Java representation of the Lean ProducedLot definition.
     * @param site corresponding Lean field
     * @param outcome corresponding Lean field
     * @param production corresponding Lean field
     */
    public record ProducedLot(SiteId site, OutcomeId outcome, ProductionId production) implements ResourceLotRef {
        public ProducedLot {
            site = Objects.requireNonNull(site); outcome = Objects.requireNonNull(outcome);
            production = Objects.requireNonNull(production);
        }
    }

        /**
     * Java representation of the Lean ResourceProducer definition.
     */
    public sealed interface ResourceProducer permits InitialResourceProducer, InvocationOutcomeResourceProducer {}
    /**
     * Java representation of the Lean InitialResourceProducer definition.
     * @param identity corresponding Lean field
     * @param revision corresponding Lean field
     */
    public record InitialResourceProducer(String identity, String revision) implements ResourceProducer {
        public InitialResourceProducer { identity = Objects.requireNonNull(identity); revision = Objects.requireNonNull(revision); }
    }
            /**
     * Java representation of the Lean InvocationOutcomeResourceProducer definition.
     * @param site corresponding Lean field
     * @param outcome corresponding Lean field
     */
    public record InvocationOutcomeResourceProducer(SiteId site, OutcomeId outcome) implements ResourceProducer {
        public InvocationOutcomeResourceProducer { site = Objects.requireNonNull(site); outcome = Objects.requireNonNull(outcome); }
    }

        /**
     * Java representation of the Lean ResourceIdentityConstraint definition.
     */
    public sealed interface ResourceIdentityConstraint permits AnyResourceIdentity, ExactlyResourceIdentity {}
    /**
     * Java representation of the Lean AnyResourceIdentity definition.
     */
    public record AnyResourceIdentity() implements ResourceIdentityConstraint {}
    /**
     * Java representation of the Lean ExactlyResourceIdentity definition.
     * @param producer corresponding Lean field
     */
    public record ExactlyResourceIdentity(ResourceProducer producer) implements ResourceIdentityConstraint {
        public ExactlyResourceIdentity { producer = Objects.requireNonNull(producer); }
    }

            /**
     * Java representation of the Lean ResourceLot definition.
     * @param id corresponding Lean field
     * @param tokenType corresponding Lean field
     * @param producer corresponding Lean field
     * @param revision corresponding Lean field
     * @param quantity corresponding Lean field
     * @param provenance corresponding Lean field
     */
    public record ResourceLot(LotId id, TypeRef tokenType, ResourceProducer producer,
            BigInteger revision, BigInteger quantity, String provenance) {
        public ResourceLot {
            id = Objects.requireNonNull(id); tokenType = Objects.requireNonNull(tokenType);
            producer = Objects.requireNonNull(producer); revision = natural(revision);
            quantity = natural(quantity); provenance = Objects.requireNonNull(provenance);
        }
    }
            /**
     * Java representation of the Lean ResourceRequirement definition.
     * @param id corresponding Lean field
     * @param tokenType corresponding Lean field
     * @param mode corresponding Lean field
     * @param multiplicity corresponding Lean field
     * @param requiredRevision corresponding Lean field
     * @param identity corresponding Lean field
     */
    public record ResourceRequirement(RequirementId id, TypeRef tokenType, TypedMapping.BindingMode mode,
            BigInteger multiplicity, BigInteger requiredRevision, ResourceIdentityConstraint identity) {
        public ResourceRequirement {
            id = Objects.requireNonNull(id); tokenType = Objects.requireNonNull(tokenType);
            mode = Objects.requireNonNull(mode); multiplicity = natural(multiplicity);
            requiredRevision = natural(requiredRevision); identity = Objects.requireNonNull(identity);
        }
    }
            /**
     * Java representation of the Lean ResourceProduction definition.
     * @param id corresponding Lean field
     * @param tokenType corresponding Lean field
     * @param revision corresponding Lean field
     * @param quantity corresponding Lean field
     * @param provenance corresponding Lean field
     */
    public record ResourceProduction(ProductionId id, TypeRef tokenType, BigInteger revision,
            BigInteger quantity, String provenance) {
        public ResourceProduction {
            id = Objects.requireNonNull(id); tokenType = Objects.requireNonNull(tokenType);
            revision = natural(revision); quantity = natural(quantity); provenance = Objects.requireNonNull(provenance);
        }
    }

        /**
     * Java representation of the Lean InitialSource definition.
     */
    public sealed interface InitialSource permits Argument, SuppliedValue {}
    /**
     * Java representation of the Lean Argument definition.
     */
    public record Argument() implements InitialSource {}
    /**
     * Java representation of the Lean SuppliedValue definition.
     * @param value corresponding Lean field
     */
    public record SuppliedValue(Slot<JsonValue> value) implements InitialSource { public SuppliedValue { value = Objects.requireNonNull(value); } }
            /**
     * Java representation of the Lean InitialInput definition.
     * @param id corresponding Lean field
     * @param contract corresponding Lean field
     * @param source corresponding Lean field
     * @param resource corresponding Lean field
     */
    public record InitialInput(InputId id, SlotContract contract, InitialSource source, Optional<LotId> resource) {
        public InitialInput {
            id = Objects.requireNonNull(id); contract = Objects.requireNonNull(contract);
            source = Objects.requireNonNull(source); resource = optional(resource);
        }
    }
            /**
     * Java representation of the Lean InputPort definition.
     * @param id corresponding Lean field
     * @param contract corresponding Lean field
     * @param sourceConstraint corresponding Lean field
     * @param resourceRequirement corresponding Lean field
     */
    public record InputPort(PortId id, SlotContract contract, SourceConstraint sourceConstraint,
            Optional<RequirementId> resourceRequirement) {
        public InputPort {
            id = Objects.requireNonNull(id); contract = Objects.requireNonNull(contract);
            sourceConstraint = Objects.requireNonNull(sourceConstraint); resourceRequirement = optional(resourceRequirement);
        }
    }
            /**
     * Java representation of the Lean OutputPort definition.
     * @param id corresponding Lean field
     * @param contract corresponding Lean field
     * @param resourceProduction corresponding Lean field
     */
    public record OutputPort(PortId id, SlotContract contract, Optional<ProductionId> resourceProduction) {
        public OutputPort {
            id = Objects.requireNonNull(id); contract = Objects.requireNonNull(contract);
            resourceProduction = optional(resourceProduction);
        }
    }
        /**
     * Java representation of the Lean OutcomeForm definition.
     */
    public enum OutcomeForm { SUCCESS, DECLARED_FAILURE }
    /**
     * Java representation of the Lean OutcomeContract definition.
     * @param id corresponding Lean field
     * @param form corresponding Lean field
     * @param valuePorts corresponding Lean field
     * @param producedResources corresponding Lean field
     */
    public record OutcomeContract(OutcomeId id, OutcomeForm form, List<OutputPort> valuePorts,
            List<ResourceProduction> producedResources) {
        public OutcomeContract {
            id = Objects.requireNonNull(id); form = Objects.requireNonNull(form);
            valuePorts = copy(valuePorts); producedResources = copy(producedResources);
        }
    }

        /**
     * Java representation of the Lean FunctionForm definition.
     */
    public sealed interface FunctionForm permits Pure, Operation, DeclaredTransform {}
    /**
     * Java representation of the Lean Pure definition.
     */
    public record Pure() implements FunctionForm {}
    /**
     * Java representation of the Lean Operation definition.
     * @param definition corresponding Lean field
     */
    public record Operation(DefinitionRef definition) implements FunctionForm { public Operation { definition = Objects.requireNonNull(definition); } }
            /**
     * Java representation of the Lean DeclaredTransform definition.
     */
    public record DeclaredTransform() implements FunctionForm {}
    /**
     * Java representation of the Lean CompositionEffect definition.
     */
    public enum CompositionEffect { PURE_FUNCTION, HTTP_REQUEST_RESPONSE, DATA_ONLY }
    /**
     * Java representation of the Lean GuardArm definition.
     */
    public sealed interface GuardArm permits PresentArm, AbsentArm, NullArm, VariantArm,
            UnknownVariantArm, AcceptedArm, RejectedArm {}
            /**
     * Java representation of the Lean PresentArm definition.
     */
    public record PresentArm() implements GuardArm {}
    /**
     * Java representation of the Lean AbsentArm definition.
     */
    public record AbsentArm() implements GuardArm {}
    /**
     * Java representation of the Lean NullArm definition.
     */
    public record NullArm() implements GuardArm {}
            /**
     * Java representation of the Lean VariantArm definition.
     * @param tag corresponding Lean field
     */
    public record VariantArm(String tag) implements GuardArm { public VariantArm { tag = Objects.requireNonNull(tag); } }
    /**
     * Java representation of the Lean UnknownVariantArm definition.
     */
    public record UnknownVariantArm() implements GuardArm {}
    /**
     * Java representation of the Lean AcceptedArm definition.
     */
    public record AcceptedArm() implements GuardArm {}
            /**
     * Java representation of the Lean RejectedArm definition.
     */
    public record RejectedArm() implements GuardArm {}

    /**

     * Java representation of the Lean FailureOrigin definition.

     */

    public sealed interface FailureOrigin permits FunctionFailureOrigin, GuardFailureOrigin {}
            /**
     * Java representation of the Lean FunctionFailureOrigin definition.
     * @param function corresponding Lean field
     * @param outcome corresponding Lean field
     */
    public record FunctionFailureOrigin(FunctionRef function, OutcomeId outcome) implements FailureOrigin {
        public FunctionFailureOrigin { function = Objects.requireNonNull(function); outcome = Objects.requireNonNull(outcome); }
    }
            /**
     * Java representation of the Lean GuardFailureOrigin definition.
     * @param guard corresponding Lean field
     * @param arm corresponding Lean field
     */
    public record GuardFailureOrigin(GuardId guard, GuardArm arm) implements FailureOrigin {
        public GuardFailureOrigin { guard = Objects.requireNonNull(guard); arm = Objects.requireNonNull(arm); }
    }

            /**
     * Java representation of the Lean FunctionSignature definition.
     * @param reference corresponding Lean field
     * @param form corresponding Lean field
     * @param effect corresponding Lean field
     * @param inputs corresponding Lean field
     * @param outcomes corresponding Lean field
     * @param resourceInputs corresponding Lean field
     * @param assumptionRef corresponding Lean field
     * @param handlesFailure corresponding Lean field
     */
    public record FunctionSignature(FunctionRef reference, FunctionForm form, CompositionEffect effect,
            List<InputPort> inputs, List<OutcomeContract> outcomes, List<ResourceRequirement> resourceInputs,
            String assumptionRef, Optional<FailureOrigin> handlesFailure) {
        public FunctionSignature {
            reference = Objects.requireNonNull(reference); form = Objects.requireNonNull(form);
            effect = Objects.requireNonNull(effect); inputs = copy(inputs); outcomes = copy(outcomes);
            resourceInputs = copy(resourceInputs); assumptionRef = Objects.requireNonNull(assumptionRef);
            handlesFailure = optional(handlesFailure);
        }
    }
            /**
     * Java representation of the Lean InvocationSite definition.
     * @param id corresponding Lean field
     * @param function corresponding Lean field
     */
    public record InvocationSite(SiteId id, FunctionRef function) {
        public InvocationSite { id = Objects.requireNonNull(id); function = Objects.requireNonNull(function); }
    }
            /**
     * Java representation of the Lean PermittedProjection definition.
     * @param sourceType corresponding Lean field
     * @param path corresponding Lean field
     */
    public record PermittedProjection(TypeRef sourceType, List<PathStep> path) {
        public PermittedProjection { sourceType = Objects.requireNonNull(sourceType); path = copy(path); }
    }
        /**
     * Java representation of the Lean GuardKind definition.
     */
    public sealed interface GuardKind permits PresenceGuard, VariantsGuard, ValidateGuard {}
    /**
     * Java representation of the Lean PresenceGuard definition.
     */
    public record PresenceGuard() implements GuardKind {}
    /**
     * Java representation of the Lean VariantsGuard definition.
     */
    public record VariantsGuard() implements GuardKind {}
            /**
     * Java representation of the Lean ValidateGuard definition.
     * @param contract corresponding Lean field
     */
    public record ValidateGuard(SlotContract contract) implements GuardKind { public ValidateGuard { contract = Objects.requireNonNull(contract); } }
    /**
     * Java representation of the Lean DeclaredGuard definition.
     * @param id corresponding Lean field
     * @param sourceType corresponding Lean field
     * @param path corresponding Lean field
     * @param kind corresponding Lean field
     */
    public record DeclaredGuard(GuardId id, TypeRef sourceType, List<PathStep> path, GuardKind kind) {
        public DeclaredGuard {
            id = Objects.requireNonNull(id); sourceType = Objects.requireNonNull(sourceType);
            path = copy(path); kind = Objects.requireNonNull(kind);
        }
    }
        /**
     * Java representation of the Lean FieldPresence definition.
     */
    public enum FieldPresence { REQUIRED, OPTIONAL }
    /**
     * Java representation of the Lean FieldConstraint definition.
     * @param field corresponding Lean field
     * @param source corresponding Lean field
     * @param presence corresponding Lean field
     */
    public record FieldConstraint(String field, SourceConstraint source, FieldPresence presence) {
        public FieldConstraint {
            field = Objects.requireNonNull(field); source = Objects.requireNonNull(source); presence = Objects.requireNonNull(presence);
        }
    }
            /**
     * Java representation of the Lean NamedConstruction definition.
     * @param field corresponding Lean field
     * @param construction corresponding Lean field
     */
    public record NamedConstruction(String field, String construction) {
        public NamedConstruction { field = Objects.requireNonNull(field); construction = Objects.requireNonNull(construction); }
    }
            /**
     * Java representation of the Lean ConstructionRule definition.
     * @param identity corresponding Lean field
     * @param typeRef corresponding Lean field
     * @param nestedFields corresponding Lean field
     * @param fieldConstraints corresponding Lean field
     */
    public record ConstructionRule(String identity, TypeRef typeRef, List<NamedConstruction> nestedFields,
            List<FieldConstraint> fieldConstraints) {
        public ConstructionRule {
            identity = Objects.requireNonNull(identity); typeRef = Objects.requireNonNull(typeRef);
            nestedFields = copy(nestedFields); fieldConstraints = copy(fieldConstraints);
        }
        /** @param name field name @return the declared constraint or any-compatible */
        public SourceConstraint fieldConstraint(String name) {
            return fieldConstraints.stream().filter(item -> item.field().equals(name)).findFirst()
                    .<SourceConstraint>map(FieldConstraint::source).orElseGet(AnyCompatible::new);
        }
        /** @param name field name @return whether the field is required */
        public boolean fieldRequired(String name) {
            return fieldConstraints.stream().anyMatch(item -> item.field().equals(name) && item.presence() == FieldPresence.REQUIRED);
        }
    }
            /**
     * Java representation of the Lean InvocationDomain definition.
     * @param identity corresponding Lean field
     * @param revision corresponding Lean field
     * @param sites corresponding Lean field
     * @param permittedProjections corresponding Lean field
     * @param permittedConstructions corresponding Lean field
     * @param permittedTransforms corresponding Lean field
     * @param guards corresponding Lean field
     */
    public record InvocationDomain(String identity, String revision, List<InvocationSite> sites,
            List<PermittedProjection> permittedProjections, List<ConstructionRule> permittedConstructions,
            List<FunctionRef> permittedTransforms, List<DeclaredGuard> guards) {
        public InvocationDomain {
            identity = Objects.requireNonNull(identity); revision = Objects.requireNonNull(revision);
            sites = copy(sites); permittedProjections = copy(permittedProjections);
            permittedConstructions = copy(permittedConstructions); permittedTransforms = copy(permittedTransforms);
            guards = copy(guards);
        }
    }
            /**
     * Java representation of the Lean ResourceGoal definition.
     * @param lot corresponding Lean field
     * @param multiplicity corresponding Lean field
     * @param revision corresponding Lean field
     */
    public record ResourceGoal(ResourceLotRef lot, BigInteger multiplicity, BigInteger revision) {
        public ResourceGoal { lot = Objects.requireNonNull(lot); multiplicity = natural(multiplicity); revision = natural(revision); }
    }
            /**
     * Java representation of the Lean GoalPort definition.
     * @param id corresponding Lean field
     * @param contract corresponding Lean field
     * @param sourceConstraint corresponding Lean field
     */
    public record GoalPort(GoalPortId id, SlotContract contract, SourceConstraint sourceConstraint) {
        public GoalPort { id = Objects.requireNonNull(id); contract = Objects.requireNonNull(contract); sourceConstraint = Objects.requireNonNull(sourceConstraint); }
    }
            /**
     * Java representation of the Lean FailureEmbedding definition.
     * @param id corresponding Lean field
     * @param origin corresponding Lean field
     * @param contract corresponding Lean field
     * @param finalResources corresponding Lean field
     */
    public record FailureEmbedding(FailureEmbeddingId id, FailureOrigin origin, SlotContract contract,
            List<ResourceGoal> finalResources) {
        public FailureEmbedding {
            id = Objects.requireNonNull(id); origin = Objects.requireNonNull(origin);
            contract = Objects.requireNonNull(contract); finalResources = copy(finalResources);
        }
    }
            /**
     * Java representation of the Lean GoalSpec definition.
     * @param outputs corresponding Lean field
     * @param failures corresponding Lean field
     * @param finalResources corresponding Lean field
     */
    public record GoalSpec(List<GoalPort> outputs, List<FailureEmbedding> failures, List<ResourceGoal> finalResources) {
        public GoalSpec { outputs = copy(outputs); failures = copy(failures); finalResources = copy(finalResources); }
    }
        /**
     * Java representation of the Lean SelectionPolicy definition.
     */
    public enum SelectionPolicy { REQUIRE_UNIQUE, ANY_FEASIBLE }
    /**
     * Java representation of the Lean ResourceBounds definition.
     * @param maxBindings corresponding Lean field
     * @param maxSearchSteps corresponding Lean field
     * @param maxTokens corresponding Lean field
     */
    public record ResourceBounds(BigInteger maxBindings, BigInteger maxSearchSteps, BigInteger maxTokens) {
        public ResourceBounds { maxBindings = natural(maxBindings); maxSearchSteps = natural(maxSearchSteps); maxTokens = natural(maxTokens); }
    }
            /**
     * Java representation of the Lean SearchBounds definition.
     * @param maxExpandedStates corresponding Lean field
     * @param maxBindingCandidates corresponding Lean field
     * @param maxTypeObligations corresponding Lean field
     * @param maxBranchNodes corresponding Lean field
     * @param maxSampleLength corresponding Lean field
     * @param resourceBounds corresponding Lean field
     */
    public record SearchBounds(BigInteger maxExpandedStates, BigInteger maxBindingCandidates,
            BigInteger maxTypeObligations, BigInteger maxBranchNodes, BigInteger maxSampleLength,
            Optional<ResourceBounds> resourceBounds) {
        public SearchBounds {
            maxExpandedStates = natural(maxExpandedStates); maxBindingCandidates = natural(maxBindingCandidates);
            maxTypeObligations = natural(maxTypeObligations); maxBranchNodes = natural(maxBranchNodes);
            maxSampleLength = natural(maxSampleLength); resourceBounds = optional(resourceBounds);
        }
        /** @return the Lean default search bounds */
        public static SearchBounds defaults() {
            return new SearchBounds(DEFAULT_MAX_EXPANDED_STATES, DEFAULT_MAX_BINDING_CANDIDATES,
                    DEFAULT_MAX_TYPE_OBLIGATIONS, DEFAULT_MAX_BRANCH_NODES, DEFAULT_MAX_SAMPLE_LENGTH, Optional.empty());
        }
    }
    /**
     * Java representation of the Lean CompositionInput definition.
     * @param identity corresponding Lean field
     * @param revision corresponding Lean field
     * @param basis corresponding Lean field
     * @param signatures corresponding Lean field
     * @param initialInputs corresponding Lean field
     * @param initialResources corresponding Lean field
     * @param goal corresponding Lean field
     * @param invocationDomain corresponding Lean field
     * @param allowedEffects corresponding Lean field
     * @param explicitOrder corresponding Lean field
     * @param selectionPolicy corresponding Lean field
     * @param bounds corresponding Lean field
     */
    public record CompositionInput(String identity, String revision, SemanticBasis basis,
            List<FunctionSignature> signatures, List<InitialInput> initialInputs,
            List<ResourceLot> initialResources, GoalSpec goal, InvocationDomain invocationDomain,
            List<CompositionEffect> allowedEffects, List<SiteOrder> explicitOrder,
            Optional<SelectionPolicy> selectionPolicy, SearchBounds bounds) {
        public CompositionInput {
            identity = Objects.requireNonNull(identity); revision = Objects.requireNonNull(revision);
            basis = Objects.requireNonNull(basis); signatures = copy(signatures); initialInputs = copy(initialInputs);
            initialResources = copy(initialResources); goal = Objects.requireNonNull(goal);
            invocationDomain = Objects.requireNonNull(invocationDomain); allowedEffects = copy(allowedEffects);
            explicitOrder = copy(explicitOrder); selectionPolicy = optional(selectionPolicy); bounds = Objects.requireNonNull(bounds);
        }
    }
            /**
     * Java representation of the Lean SiteOrder definition.
     * @param before corresponding Lean field
     * @param after corresponding Lean field
     */
    public record SiteOrder(SiteId before, SiteId after) {
        public SiteOrder { before = Objects.requireNonNull(before); after = Objects.requireNonNull(after); }
    }

        /**
     * Java representation of the Lean CompositionInputFailure definition.
     */
    public sealed interface CompositionInputFailure permits BasisMismatch, DuplicateIdentity,
            UnresolvedType, UnresolvedFunction, InvalidSignature, InvalidInitialValue,
            SiteEffectNotPermitted, TransformNotPermitted, EmptyGoal, GoalSourceConstraintUndefined,
            FailureEmbeddingOriginUndefined, ConstructionNotProduct, FieldConstraintUnknownField,
            ConstrainedNestedField, ConstructionFieldSourceUndefined, NestedFieldUndeclared,
            NestedConstructionMismatch, CyclicConstruction, ExplicitSiteOrderInvalid,
            InvalidEmptyTypeClosure, InvalidResourceDeclaration, InvalidLibrary {}
            /**
     * Java representation of the Lean BasisMismatch definition.
     */
    public record BasisMismatch() implements CompositionInputFailure {}
    /**
     * Java representation of the Lean DuplicateIdentity definition.
     * @param kind corresponding Lean field
     * @param identity corresponding Lean field
     */
    public record DuplicateIdentity(String kind, String identity) implements CompositionInputFailure {
        public DuplicateIdentity { kind = Objects.requireNonNull(kind); identity = Objects.requireNonNull(identity); }
    }
            /**
     * Java representation of the Lean UnresolvedType definition.
     * @param reference corresponding Lean field
     */
    public record UnresolvedType(TypeRef reference) implements CompositionInputFailure { public UnresolvedType { reference = Objects.requireNonNull(reference); } }
    /**
     * Java representation of the Lean UnresolvedFunction definition.
     * @param reference corresponding Lean field
     */
    public record UnresolvedFunction(FunctionRef reference) implements CompositionInputFailure { public UnresolvedFunction { reference = Objects.requireNonNull(reference); } }
    /**
     * Java representation of the Lean InvalidSignature definition.
     * @param reference corresponding Lean field
     * @param reason corresponding Lean field
     */
    public record InvalidSignature(FunctionRef reference, String reason) implements CompositionInputFailure {
        public InvalidSignature { reference = Objects.requireNonNull(reference); reason = Objects.requireNonNull(reason); }
    }
            /**
     * Java representation of the Lean InvalidInitialValue definition.
     * @param id corresponding Lean field
     * @param failure corresponding Lean field
     */
    public record InvalidInitialValue(InputId id, ValueRejection failure) implements CompositionInputFailure {
        public InvalidInitialValue { id = Objects.requireNonNull(id); failure = Objects.requireNonNull(failure); }
    }
    /**
     * Java representation of the Lean SiteEffectNotPermitted definition.
     * @param site corresponding Lean field
     * @param effect corresponding Lean field
     */
    public record SiteEffectNotPermitted(SiteId site, CompositionEffect effect) implements CompositionInputFailure {
        public SiteEffectNotPermitted { site = Objects.requireNonNull(site); effect = Objects.requireNonNull(effect); }
    }
    /**
     * Java representation of the Lean TransformNotPermitted definition.
     * @param function corresponding Lean field
     */
    public record TransformNotPermitted(FunctionRef function) implements CompositionInputFailure {
        public TransformNotPermitted { function = Objects.requireNonNull(function); }
    }
    /** Java representation of the Lean EmptyGoal definition. */
    public record EmptyGoal() implements CompositionInputFailure {}
    /**
     * Java representation of the Lean GoalSourceConstraintUndefined definition.
     * @param port corresponding Lean field
     * @param constraint corresponding Lean field
     */
    public record GoalSourceConstraintUndefined(GoalPortId port, SourceConstraint constraint) implements CompositionInputFailure {
        public GoalSourceConstraintUndefined { port = Objects.requireNonNull(port); constraint = Objects.requireNonNull(constraint); }
    }
    /**
     * Java representation of the Lean FailureEmbeddingOriginUndefined definition.
     * @param embedding corresponding Lean field
     * @param origin corresponding Lean field
     */
    public record FailureEmbeddingOriginUndefined(FailureEmbeddingId embedding, FailureOrigin origin) implements CompositionInputFailure {
        public FailureEmbeddingOriginUndefined { embedding = Objects.requireNonNull(embedding); origin = Objects.requireNonNull(origin); }
    }
    /**
     * Java representation of the Lean ConstructionNotProduct definition.
     * @param identity corresponding Lean field
     * @param typeRef corresponding Lean field
     */
    public record ConstructionNotProduct(String identity, TypeRef typeRef) implements CompositionInputFailure {
        public ConstructionNotProduct { identity = Objects.requireNonNull(identity); typeRef = Objects.requireNonNull(typeRef); }
    }
    /**
     * Java representation of the Lean FieldConstraintUnknownField definition.
     * @param identity corresponding Lean field
     * @param field corresponding Lean field
     */
    public record FieldConstraintUnknownField(String identity, String field) implements CompositionInputFailure {
        public FieldConstraintUnknownField { identity = Objects.requireNonNull(identity); field = Objects.requireNonNull(field); }
    }
    /**
     * Java representation of the Lean ConstrainedNestedField definition.
     * @param identity corresponding Lean field
     * @param field corresponding Lean field
     */
    public record ConstrainedNestedField(String identity, String field) implements CompositionInputFailure {
        public ConstrainedNestedField { identity = Objects.requireNonNull(identity); field = Objects.requireNonNull(field); }
    }
    /**
     * Java representation of the Lean ConstructionFieldSourceUndefined definition.
     * @param identity corresponding Lean field
     * @param constraint corresponding Lean field
     */
    public record ConstructionFieldSourceUndefined(String identity, FieldConstraint constraint) implements CompositionInputFailure {
        public ConstructionFieldSourceUndefined { identity = Objects.requireNonNull(identity); constraint = Objects.requireNonNull(constraint); }
    }
    /**
     * Java representation of the Lean NestedFieldUndeclared definition.
     * @param identity corresponding Lean field
     * @param field corresponding Lean field
     */
    public record NestedFieldUndeclared(String identity, String field) implements CompositionInputFailure {
        public NestedFieldUndeclared { identity = Objects.requireNonNull(identity); field = Objects.requireNonNull(field); }
    }
    /**
     * Java representation of the Lean NestedConstructionMismatch definition.
     * @param identity corresponding Lean field
     * @param field corresponding Lean field
     * @param nested corresponding Lean field
     * @param typeRef corresponding Lean field
     */
    public record NestedConstructionMismatch(String identity, String field, String nested, TypeRef typeRef) implements CompositionInputFailure {
        public NestedConstructionMismatch {
            identity = Objects.requireNonNull(identity); field = Objects.requireNonNull(field);
            nested = Objects.requireNonNull(nested); typeRef = Objects.requireNonNull(typeRef);
        }
    }
    /**
     * Java representation of the Lean CyclicConstruction definition.
     * @param identity corresponding Lean field
     */
    public record CyclicConstruction(String identity) implements CompositionInputFailure {
        public CyclicConstruction { identity = Objects.requireNonNull(identity); }
    }
    /**
     * Java representation of the Lean ExplicitSiteOrderInvalid definition.
     * @param before corresponding Lean field
     * @param after corresponding Lean field
     */
    public record ExplicitSiteOrderInvalid(SiteId before, SiteId after) implements CompositionInputFailure {
        public ExplicitSiteOrderInvalid { before = Objects.requireNonNull(before); after = Objects.requireNonNull(after); }
    }
    /**
     * Java representation of the Lean InvalidEmptyTypeClosure definition.
     * @param failure corresponding Lean field
     */
    public record InvalidEmptyTypeClosure(InclusionFailure failure) implements CompositionInputFailure {
        public InvalidEmptyTypeClosure { failure = Objects.requireNonNull(failure); }
    }
    /**
     * Java representation of the Lean InvalidLibrary definition.
     * @param failure corresponding Lean field
     */
    public record InvalidLibrary(necoherence.semantic.TypeSignatures.LibraryCheckFailure failure) implements CompositionInputFailure {
        public InvalidLibrary { failure = Objects.requireNonNull(failure); }
    }
    /**
     * Java representation of the Lean InvalidResourceDeclaration definition.
     * @param reason corresponding Lean field
     */
    public record InvalidResourceDeclaration(String reason) implements CompositionInputFailure { public InvalidResourceDeclaration { reason = Objects.requireNonNull(reason); } }

        /**
     * Java representation of the Lean BindingCompatibility definition.
     */
    public sealed interface BindingCompatibility permits InclusionCompatibility, SuppliedValueCompatibility {}
    /**
     * Java representation of the Lean InclusionCompatibility definition.
     * @param certificate corresponding Lean field
     */
    public record InclusionCompatibility(InclusionCertificate certificate) implements BindingCompatibility { public InclusionCompatibility { certificate = Objects.requireNonNull(certificate); } }
    /**
     * Java representation of the Lean SuppliedValueCompatibility definition.
     * @param value corresponding Lean field
     */
    public record SuppliedValueCompatibility(Slot<JsonValue> value) implements BindingCompatibility { public SuppliedValueCompatibility { value = Objects.requireNonNull(value); } }
        /**
     * Java representation of the Lean BindingExpr definition.
     */
    public sealed interface BindingExpr permits SourceBinding, ProductBinding {}
    /**
     * Java representation of the Lean SourceBinding definition.
     * @param value corresponding Lean field
     * @param projection corresponding Lean field
     * @param compatibility corresponding Lean field
     */
    public record SourceBinding(ValueRef value, ProjectionCertificate projection,
            BindingCompatibility compatibility) implements BindingExpr {
        public SourceBinding { value = Objects.requireNonNull(value); projection = Objects.requireNonNull(projection); compatibility = Objects.requireNonNull(compatibility); }
    }
            /**
     * Java representation of the Lean NamedBinding definition.
     * @param name corresponding Lean field
     * @param binding corresponding Lean field
     */
    public record NamedBinding(String name, BindingExpr binding) {
        public NamedBinding { name = Objects.requireNonNull(name); binding = Objects.requireNonNull(binding); }
    }
            /**
     * Java representation of the Lean ProductBinding definition.
     * @param construction corresponding Lean field
     * @param typeRef corresponding Lean field
     * @param fields corresponding Lean field
     */
    public record ProductBinding(String construction, TypeRef typeRef, List<NamedBinding> fields) implements BindingExpr {
        public ProductBinding { construction = Objects.requireNonNull(construction); typeRef = Objects.requireNonNull(typeRef); fields = copy(fields); }
    }
        /**
     * Java representation of the Lean ProjectionAssumption definition.
     */
    public sealed interface ProjectionAssumption permits PresentAssumption, NonNullAssumption,
            VariantAssumption, IndexPresentAssumption {}
    /**
     * Java representation of the Lean PresentAssumption definition.
     * @param path corresponding Lean field
     */
    public record PresentAssumption(List<PathStep> path) implements ProjectionAssumption { public PresentAssumption { path = copy(path); } }
            /**
     * Java representation of the Lean NonNullAssumption definition.
     * @param path corresponding Lean field
     */
    public record NonNullAssumption(List<PathStep> path) implements ProjectionAssumption { public NonNullAssumption { path = copy(path); } }
    /**
     * Java representation of the Lean VariantAssumption definition.
     * @param path corresponding Lean field
     * @param tag corresponding Lean field
     */
    public record VariantAssumption(List<PathStep> path, String tag) implements ProjectionAssumption {
        public VariantAssumption { path = copy(path); tag = Objects.requireNonNull(tag); }
    }
            /**
     * Java representation of the Lean IndexPresentAssumption definition.
     * @param path corresponding Lean field
     * @param index corresponding Lean field
     */
    public record IndexPresentAssumption(List<PathStep> path, BigInteger index) implements ProjectionAssumption {
        public IndexPresentAssumption { path = copy(path); index = natural(index); }
    }
            /**
     * Java representation of the Lean ProjectionCertificate definition.
     * @param profile corresponding Lean field
     * @param sourceRefs corresponding Lean field
     * @param source corresponding Lean field
     * @param path corresponding Lean field
     * @param assumptions corresponding Lean field
     * @param destination corresponding Lean field
     */
    public record ProjectionCertificate(necoherence.semantic.SemanticTypes.ProfileRef profile,
            List<necoherence.semantic.SemanticTypes.SourceRef> sourceRefs,
            SlotContract source, List<PathStep> path, List<ProjectionAssumption> assumptions,
            SlotContract destination) {
        public ProjectionCertificate {
            profile = Objects.requireNonNull(profile); sourceRefs = copy(sourceRefs); source = Objects.requireNonNull(source);
            path = copy(path); assumptions = copy(assumptions); destination = Objects.requireNonNull(destination);
        }
    }

    /** A failure produced while projecting a slot contract through a value path. */
    public sealed interface ProjectionFailure permits WrongShape, MissingFieldFailure,
            MissingVariant, BranchAssumptionRequired, VariantSelectionUndetermined,
            UnresolvedProjection, CertificateMismatch {}

    public record WrongShape(TypeRef reference, List<PathStep> path) implements ProjectionFailure {
        public WrongShape { reference = Objects.requireNonNull(reference); path = copy(path); }
    }

    public record MissingFieldFailure(TypeRef reference, String name) implements ProjectionFailure {
        public MissingFieldFailure { reference = Objects.requireNonNull(reference); name = Objects.requireNonNull(name); }
    }

    public record MissingVariant(TypeRef reference, String tag) implements ProjectionFailure {
        public MissingVariant { reference = Objects.requireNonNull(reference); tag = Objects.requireNonNull(tag); }
    }

    public record BranchAssumptionRequired(List<PathStep> path, String tag) implements ProjectionFailure {
        public BranchAssumptionRequired { path = copy(path); tag = Objects.requireNonNull(tag); }
    }

    public record VariantSelectionUndetermined(List<PathStep> path, String tag) implements ProjectionFailure {
        public VariantSelectionUndetermined { path = copy(path); tag = Objects.requireNonNull(tag); }
    }

    public record UnresolvedProjection(List<necoherence.semantic.SemanticTypes.SemanticObligation> obligations) implements ProjectionFailure {
        public UnresolvedProjection { obligations = copy(obligations); }
    }

    public record CertificateMismatch(String condition) implements ProjectionFailure {
        public CertificateMismatch { condition = Objects.requireNonNull(condition); }
    }
            /**
     * Java representation of the Lean ResourceBinding definition.
     * @param requirement corresponding Lean field
     * @param lot corresponding Lean field
     * @param inclusion corresponding Lean field
     */
    public record ResourceBinding(RequirementId requirement, ResourceLotRef lot, InclusionCertificate inclusion) {
        public ResourceBinding { requirement = Objects.requireNonNull(requirement); lot = Objects.requireNonNull(lot); inclusion = Objects.requireNonNull(inclusion); }
    }
            /**
     * Java representation of the Lean PortBinding definition.
     * @param port corresponding Lean field
     * @param binding corresponding Lean field
     */
    public record PortBinding(PortId port, BindingExpr binding) {
        public PortBinding { port = Objects.requireNonNull(port); binding = Objects.requireNonNull(binding); }
    }
            /**
     * Java representation of the Lean InvocationPlan definition.
     * @param site corresponding Lean field
     * @param function corresponding Lean field
     * @param bindings corresponding Lean field
     * @param resources corresponding Lean field
     */
    public record InvocationPlan(SiteId site, FunctionRef function, List<PortBinding> bindings,
            List<ResourceBinding> resources) {
        public InvocationPlan { site = Objects.requireNonNull(site); function = Objects.requireNonNull(function); bindings = copy(bindings); resources = copy(resources); }
    }
        /**
     * Java representation of the Lean ReturnPlan definition.
     */
    public sealed interface ReturnPlan permits SuccessReturn, FailureReturn {}
    /**
     * Java representation of the Lean GoalBinding definition.
     * @param port corresponding Lean field
     * @param binding corresponding Lean field
     */
    public record GoalBinding(GoalPortId port, BindingExpr binding) {
        public GoalBinding { port = Objects.requireNonNull(port); binding = Objects.requireNonNull(binding); }
    }
            /**
     * Java representation of the Lean SuccessReturn definition.
     * @param outputs corresponding Lean field
     */
    public record SuccessReturn(List<GoalBinding> outputs) implements ReturnPlan { public SuccessReturn { outputs = copy(outputs); } }
    /**
     * Java representation of the Lean FailureReturn definition.
     * @param embedding corresponding Lean field
     * @param value corresponding Lean field
     */
    public record FailureReturn(FailureEmbeddingId embedding, BindingExpr value) implements ReturnPlan {
        public FailureReturn { embedding = Objects.requireNonNull(embedding); value = Objects.requireNonNull(value); }
    }
        /**
     * Java representation of the Lean PlanTree definition.
     */
    public sealed interface PlanTree permits InvokeTree, GuardTree, ReturnTree { BigInteger rank(); }
    /**
     * Java representation of the Lean OutcomeArm definition.
     * @param outcome corresponding Lean field
     * @param child corresponding Lean field
     */
    public record OutcomeArm(OutcomeId outcome, PlanTree child) {
        public OutcomeArm { outcome = Objects.requireNonNull(outcome); child = Objects.requireNonNull(child); }
    }
            /**
     * Java representation of the Lean GuardTreeArm definition.
     * @param arm corresponding Lean field
     * @param child corresponding Lean field
     */
    public record GuardTreeArm(GuardArm arm, PlanTree child) {
        public GuardTreeArm { arm = Objects.requireNonNull(arm); child = Objects.requireNonNull(child); }
    }
            /**
     * Java representation of the Lean InvokeTree definition.
     * @param rank corresponding Lean field
     * @param invocation corresponding Lean field
     * @param arms corresponding Lean field
     * @param emptyOutcomes corresponding Lean field
     */
    public record InvokeTree(BigInteger rank, InvocationPlan invocation, List<OutcomeArm> arms,
            List<OutcomeId> emptyOutcomes) implements PlanTree {
        public InvokeTree { rank = natural(rank); invocation = Objects.requireNonNull(invocation); arms = copy(arms); emptyOutcomes = copy(emptyOutcomes); }
    }
            /**
     * Java representation of the Lean GuardTree definition.
     * @param rank corresponding Lean field
     * @param guard corresponding Lean field
     * @param inspected corresponding Lean field
     * @param arms corresponding Lean field
     */
    public record GuardTree(BigInteger rank, GuardId guard, ValueRef inspected,
            List<GuardTreeArm> arms) implements PlanTree {
        public GuardTree { rank = natural(rank); guard = Objects.requireNonNull(guard); inspected = Objects.requireNonNull(inspected); arms = copy(arms); }
    }
            /**
     * Java representation of the Lean ReturnTree definition.
     * @param rank corresponding Lean field
     * @param terminal corresponding Lean field
     */
    public record ReturnTree(BigInteger rank, ReturnPlan terminal) implements PlanTree {
        public ReturnTree { rank = natural(rank); terminal = Objects.requireNonNull(terminal); }
    }
            /**
     * Java representation of the Lean CompositionPlan definition.
     * @param inputIdentity corresponding Lean field
     * @param inputRevision corresponding Lean field
     * @param root corresponding Lean field
     */
    public record CompositionPlan(String inputIdentity, String inputRevision, PlanTree root) {
        public CompositionPlan { inputIdentity = Objects.requireNonNull(inputIdentity); inputRevision = Objects.requireNonNull(inputRevision); root = Objects.requireNonNull(root); }
    }
        /**
     * Java representation of the Lean WitnessFailure definition.
     */
    public sealed interface WitnessFailure permits InputRevisionMismatch, InitialMembershipFailure,
            ProducerMismatch, ProjectionMismatch, SourceConstraintMismatch, InclusionWitnessFailure,
            SuppliedValueMismatch, ConstructionMismatch, MissingBinding, SignatureMismatch,
            GuardNotDominating, IncompleteBranchCoverage, FailureEmbeddingMismatch, GoalMismatch,
            RankViolation, ResourceLoweringMismatch, ResourceReplayMismatch, ForgedClosure,
            ForgedAcyclicity, MissingEvidence {}
            /**
     * Java representation of the Lean InputRevisionMismatch definition.
     */
    public record InputRevisionMismatch() implements WitnessFailure {}
    /**
     * Java representation of the Lean InitialMembershipFailure definition.
     * @param id corresponding Lean field
     */
    public record InitialMembershipFailure(InputId id) implements WitnessFailure {}
    /**
     * Java representation of the Lean ProducerMismatch definition.
     * @param reference corresponding Lean field
     */
    public record ProducerMismatch(ValueRef reference) implements WitnessFailure {}
            /**
     * Java representation of the Lean ProjectionMismatch definition.
     * @param failure corresponding Lean field
     */
    public record ProjectionMismatch(ProjectionFailure failure) implements WitnessFailure {
        public ProjectionMismatch { failure = Objects.requireNonNull(failure); }
    }
    /**
     * Java representation of the Lean SourceConstraintMismatch definition.
     * @param reference corresponding Lean field
     */
    public record SourceConstraintMismatch(ValueRef reference) implements WitnessFailure {}
    /**
     * Java representation of the Lean InclusionWitnessFailure definition.
     * @param failure corresponding Lean field
     */
    public record InclusionWitnessFailure(InclusionFailure failure) implements WitnessFailure {}
            /**
     * Java representation of the Lean SuppliedValueMismatch definition.
     * @param reference corresponding Lean field
     */
    public record SuppliedValueMismatch(ValueRef reference) implements WitnessFailure {}
    /**
     * Java representation of the Lean ConstructionMismatch definition.
     * @param reference corresponding Lean field
     */
    public record ConstructionMismatch(TypeRef reference) implements WitnessFailure {}
    /**
     * Java representation of the Lean MissingBinding definition.
     * @param identity corresponding Lean field
     */
    public record MissingBinding(String identity) implements WitnessFailure {}
            /**
     * Java representation of the Lean SignatureMismatch definition.
     * @param site corresponding Lean field
     */
    public record SignatureMismatch(SiteId site) implements WitnessFailure {}
    /**
     * Java representation of the Lean GuardNotDominating definition.
     * @param reference corresponding Lean field
     */
    public record GuardNotDominating(ValueRef reference) implements WitnessFailure {}
    /**
     * Java representation of the Lean IncompleteBranchCoverage definition.
     * @param identity corresponding Lean field
     */
    public record IncompleteBranchCoverage(String identity) implements WitnessFailure {}
            /**
     * Java representation of the Lean FailureEmbeddingMismatch definition.
     * @param id corresponding Lean field
     */
    public record FailureEmbeddingMismatch(FailureEmbeddingId id) implements WitnessFailure {}
    /**
     * Java representation of the Lean GoalMismatch definition.
     */
    public record GoalMismatch() implements WitnessFailure {}
    /**
     * Java representation of the Lean RankViolation definition.
     */
    public record RankViolation() implements WitnessFailure {}
            /**
     * Java representation of the Lean ResourceLoweringMismatch definition.
     * @param reason corresponding Lean field
     */
    public record ResourceLoweringMismatch(String reason) implements WitnessFailure {}
    /**
     * Java representation of the Lean ResourceReplayMismatch definition.
     * @param reason corresponding Lean field
     */
    public record ResourceReplayMismatch(String reason) implements WitnessFailure {}
    /**
     * Java representation of the Lean ForgedClosure definition.
     * @param reason corresponding Lean field
     */
    public record ForgedClosure(String reason) implements WitnessFailure {}
            /**
     * Java representation of the Lean ForgedAcyclicity definition.
     * @param reason corresponding Lean field
     */
    public record ForgedAcyclicity(String reason) implements WitnessFailure {}
    /**
     * Java representation of the Lean MissingEvidence definition.
     * @param reason corresponding Lean field
     */
    public record MissingEvidence(String reason) implements WitnessFailure {}

        /**
     * Java representation of the Lean UnresolvedObligation definition.
     */
    public sealed interface UnresolvedObligation permits TypeUnresolved, MeaningUnresolved,
            InhabitationUnresolved, BranchInhabitation, StateBoundExhausted, BindingBoundExhausted,
            BranchBoundExhausted, ResourceSolverUnknown, ResourceCapacityBound, UnresolvedUniqueness {}
            /**
     * Java representation of the Lean TypeUnresolved definition.
     * @param value corresponding Lean field
     * @param obligations corresponding Lean field
     */
    public record TypeUnresolved(Optional<ValueRef> value, List<TypeObligation> obligations) implements UnresolvedObligation { public TypeUnresolved { value = optional(value); obligations = copy(obligations); } }
    /**
     * Java representation of the Lean MeaningUnresolved definition.
     * @param obligations corresponding Lean field
     */
    public record MeaningUnresolved(List<necoherence.semantic.SemanticTypes.SemanticObligation> obligations) implements UnresolvedObligation { public MeaningUnresolved { obligations = copy(obligations); } }
    /**
     * Java representation of the Lean InhabitationUnresolved definition.
     * @param producer corresponding Lean field
     * @param contract corresponding Lean field
     */
    public record InhabitationUnresolved(ProducerRef producer, SlotContract contract) implements UnresolvedObligation {}
    /**
     * Java representation of the Lean branchInhabitation constructor, which has no fields.
     */
    public record BranchInhabitation() implements UnresolvedObligation {}
            /**
     * Java representation of the Lean StateBoundExhausted definition.
     */
    public record StateBoundExhausted() implements UnresolvedObligation {}
    /**
     * Java representation of the Lean BindingBoundExhausted definition.
     */
    public record BindingBoundExhausted() implements UnresolvedObligation {}
    /**
     * Java representation of the Lean BranchBoundExhausted definition.
     */
    public record BranchBoundExhausted() implements UnresolvedObligation {}
            /**
     * Java representation of the Lean ResourceSolverUnknown definition.
     * @param reason corresponding Lean field
     */
    public record ResourceSolverUnknown(TypedMapping.UnknownReason reason) implements UnresolvedObligation {}
    /**
     * Java representation of the Lean ResourceCapacityBound definition.
     * @param required corresponding Lean field
     * @param limit corresponding Lean field
     */
    public record ResourceCapacityBound(BigInteger required, BigInteger limit) implements UnresolvedObligation { public ResourceCapacityBound { required = natural(required); limit = natural(limit); } }
    /**
     * Java representation of the Lean UnresolvedUniqueness definition.
     */
    public record UnresolvedUniqueness() implements UnresolvedObligation {}
        /**
     * Java representation of the Lean LoweringFailure definition.
     */
    public sealed interface LoweringFailure permits InvalidLowering, UnknownLowering {}
    /**
     * Java representation of the Lean InvalidLowering definition.
     * @param reason corresponding Lean field
     */
    public record InvalidLowering(String reason) implements LoweringFailure {}
    /**
     * Java representation of the Lean UnknownLowering definition.
     * @param obligation corresponding Lean field
     */
    public record UnknownLowering(UnresolvedObligation obligation) implements LoweringFailure {}
        /**
     * Java representation of the Lean CompositionEngineFailure definition.
     */
    public sealed interface CompositionEngineFailure permits ContractViolation, ResourceFailure, WitnessEngineFailure {}
    /**
     * Java representation of the Lean ContractViolation definition.
     * @param reason corresponding Lean field
     */
    public record ContractViolation(String reason) implements CompositionEngineFailure {}
    /**
     * Java representation of the Lean ResourceFailure definition.
     * @param failure corresponding Lean field
     */
    public record ResourceFailure(TypedMapping.SolverFailure failure) implements CompositionEngineFailure {}
            /**
     * Java representation of the Lean WitnessEngineFailure definition.
     * @param failure corresponding Lean field
     */
    public record WitnessEngineFailure(WitnessFailure failure) implements CompositionEngineFailure {}

    /** Checks operation-specific constraints during preparation. */
    @FunctionalInterface
    /**
     * Java representation of the Lean OperationChecker definition.
     */
    public interface OperationChecker {
        Optional<CompositionInputFailure> check(FunctionSignature function, DefinitionRef definition);
    }

    /** Returns the meaning obligations contributed by an operation. */
    @FunctionalInterface
    /**
     * Java representation of the Lean OperationMeaning definition.
     */
    public interface OperationMeaning {
        List<WireValue> obligations(FunctionSignature function, DefinitionRef definition);
    }

        /**
     * The result of preparing an input.
     */
    public sealed interface PreparationResult permits Prepared, PreparationFailed {}
    /**
     * Java representation of the Lean Prepared definition.
     * @param value corresponding Lean field
     */
    public record Prepared(PreparedCompositionInput value) implements PreparationResult {}
    /**
     * Java representation of the Lean PreparationFailed definition.
     * @param failure corresponding Lean field
     */
    public record PreparationFailed(CompositionInputFailure failure) implements PreparationResult {}

        /**
     * A composition input whose complete declaration checks have succeeded.
     */
    public static final class PreparedCompositionInput {
        private final necoherence.semantic.SemanticTypes.SemanticGraph typedGraph;
        private final necoherence.semantic.SemanticValues.Context valueContext;
        private final CompositionInput input;
        private final OperationMeaning operationMeaning;
        private final List<TypeRef> emptyRefs;

        private PreparedCompositionInput(necoherence.semantic.SemanticValues.Context valueContext,
                CompositionInput input,
                OperationMeaning operationMeaning, List<TypeRef> emptyRefs) {
            this.valueContext = Objects.requireNonNull(valueContext);
            this.typedGraph = valueContext.typed();
            this.input = Objects.requireNonNull(input);
            this.operationMeaning = Objects.requireNonNull(operationMeaning);
            this.emptyRefs = copy(emptyRefs);
        }

        /** @return the validated semantic graph as typed values */
        public necoherence.semantic.SemanticTypes.SemanticGraph typedGraph() { return typedGraph; }
        /** @return the value context of the validated semantic graph */
        public necoherence.semantic.SemanticValues.Context valueContext() { return valueContext; }
        /** @return the validated composition input */
        public CompositionInput input() { return input; }
        /** @return the operation checker used during validation */
        /** @return the operation meaning provider */
        public OperationMeaning operationMeaning() { return operationMeaning; }
        /** @return the checked empty-type closure */
        public List<TypeRef> emptyRefs() { return emptyRefs; }

        @Override public boolean equals(Object other) {
            return other instanceof PreparedCompositionInput prepared
                    && typedGraph.profile().equals(prepared.typedGraph.profile())
                    && typedGraph.nodes().equals(prepared.typedGraph.nodes())
                    && input.equals(prepared.input) && emptyRefs.equals(prepared.emptyRefs);
        }

        @Override public int hashCode() { return Objects.hash(typedGraph.profile(), typedGraph.nodes(), input, emptyRefs); }
    }

    /**
     * Returns the first failure in the order defined by Lean validateCompositionInput.
     * @param context value context prepared from the semantic graph
     * @param input composition input
     * @param operationChecker operation validator
     * @return the first failure, or an empty value
     */
    public static Optional<CompositionInputFailure> validateCompositionInput(necoherence.semantic.SemanticValues.Context context,
            CompositionInput input, OperationChecker operationChecker) {
        Objects.requireNonNull(context); Objects.requireNonNull(input); Objects.requireNonNull(operationChecker);
        Validator validator = new Validator(context, input, operationChecker);
        return validator.validate();
    }

    /**
     * Validates an input and creates the only public representation of a prepared input.
     * @param graph semantic graph
     * @param input composition input
     * @param operationChecker operation validator
     * @param operationMeaning operation meaning provider
     * @return the preparation result
     */
    public static PreparationResult prepareDirectComposition(WireValue graph, CompositionInput input,
            OperationChecker operationChecker, OperationMeaning operationMeaning) {
        return prepareDirectComposition(new necoherence.semantic.SemanticValues.Context(
                necoherence.semantic.SemanticGraphWire.decodeGraph(graph)), input, operationChecker, operationMeaning);
    }

    /**
     * Validates an input over a value context that is already prepared and creates the only public representation of a prepared input.
     * @param context value context prepared from the semantic graph
     * @param input composition input
     * @param operationChecker operation validator
     * @param operationMeaning operation meaning provider
     * @return the preparation result
     */
    public static PreparationResult prepareDirectComposition(necoherence.semantic.SemanticValues.Context context,
            CompositionInput input, OperationChecker operationChecker, OperationMeaning operationMeaning) {
        necoherence.semantic.SemanticTypes.SemanticGraph typed = context.typed();
        Optional<CompositionInputFailure> failure = validateCompositionInput(context, input, operationChecker);
        if (failure.isPresent()) return new PreparationFailed(failure.get());
        List<TypeRef> emptyRefs = EmptyTypeClosure.emptyTypes(context);
        Optional<CompositionInputFailure> closureFailure = verifyEmptyClosureInput(context, emptyRefs);
        if (closureFailure.isPresent()) return new PreparationFailed(closureFailure.get());
        return new Prepared(new PreparedCompositionInput(context, input, operationMeaning, emptyRefs));
    }

    /** The Lean verifyEmptyClosureInput: checks the empty closure and maps its failure to the input failure. */
    static Optional<CompositionInputFailure> verifyEmptyClosureInput(necoherence.semantic.SemanticValues.Context context,
            List<TypeRef> refs) {
        EmptyTypeClosure.Verification<?> closure = EmptyTypeClosure.verifyEmptyTypes(context, refs);
        if (closure instanceof EmptyTypeClosure.VerificationFailed<?> failed)
            return Optional.of(new InvalidEmptyTypeClosure(failed.failure()));
        return Optional.empty();
    }

    /**
     * Builds the canonical source-qualified reference used by signature-composition wire values.
     * @param identity definition identity
     * @return the source-qualified reference
     */
    static TypeRef typeRef(String identity) {
        return new TypeRef(TypeSignaturesSource.VALUE, identity, List.of());
    }


    private static final class TypeSignaturesSource {
        static final necoherence.semantic.SemanticTypes.SourceRef VALUE = new necoherence.semantic.SemanticTypes.SourceRef(
                "ncoh-type-signatures", "1", "", "", "", Optional.empty());
    }

    private static final class Validator {
        private final necoherence.semantic.SemanticTypes.SemanticGraph graph;
        private final CompositionInput input;
        private final OperationChecker operationChecker;
        private final necoherence.semantic.SemanticValues.Context context;

        Validator(necoherence.semantic.SemanticValues.Context context, CompositionInput input, OperationChecker operationChecker) {
            this.graph = context.typed(); this.input = input; this.operationChecker = operationChecker;
            this.context = context;
        }

        Optional<CompositionInputFailure> validate() {
            CompositionInputFailure failure;
            if (!input.basis().equals(SemanticBasis.of(graph))) return fail(new BasisMismatch());
            if ((failure = uniqueIds("input", input.initialInputs().stream().map(v -> v.id().value()).toList())) != null) return fail(failure);
            if ((failure = uniqueIds("site", input.invocationDomain().sites().stream().map(v -> v.id().value()).toList())) != null) return fail(failure);
            if ((failure = uniqueIds("lot", input.initialResources().stream().map(v -> v.id().value()).toList())) != null) return fail(failure);
            if ((failure = uniqueIds("goal", input.goal().outputs().stream().map(v -> v.id().value()).toList())) != null) return fail(failure);
            if ((failure = uniqueIds("failure embedding", input.goal().failures().stream().map(v -> v.id().value()).toList())) != null) return fail(failure);
            if ((failure = uniqueIds("function", input.signatures().stream()
                    .map(function -> functionIdentity(function.reference())).toList())) != null) return fail(failure);
            if ((failure = uniqueIds("guard", input.invocationDomain().guards().stream().map(v -> v.id().value()).toList())) != null) return fail(failure);
            for (FunctionSignature function : input.signatures()) {
                InvalidSignature invalid;
                if (function.reference().identity().isEmpty() || function.reference().revision().isEmpty()
                        || function.reference().contentDigest().isEmpty() || function.assumptionRef().isEmpty()
                        || function.outcomes().isEmpty())
                    return fail(new InvalidSignature(function.reference(), "identity, revision, digest, assumptions, or outcomes"));
                if ((failure = uniqueIds("input port", function.inputs().stream().map(v -> v.id().value()).toList())) != null) return fail(failure);
                if ((failure = uniqueIds("outcome", function.outcomes().stream().map(v -> v.id().value()).toList())) != null) return fail(failure);
                if ((failure = uniqueIds("resource requirement", function.resourceInputs().stream().map(v -> v.id().value()).toList())) != null) return fail(failure);
                if (function.form() instanceof Pure || function.form() instanceof DeclaredTransform) {
                    if (function.effect() != CompositionEffect.PURE_FUNCTION)
                        return fail(new InvalidSignature(function.reference(), "pure function effect"));
                } else if (function.form() instanceof Operation operation) {
                    Optional<CompositionInputFailure> checked = operationChecker.check(function, operation.definition());
                    if (checked.isPresent()) return checked;
                }
                for (InputPort port : function.inputs()) {
                    if ((failure = checkType(port.contract().typeRef())) != null) return fail(failure);
                    if (!sourceConstraintDefined(port.sourceConstraint())) return fail(new InvalidSignature(function.reference(), "input source constraint"));
                    if (port.resourceRequirement().isPresent() && function.resourceInputs().stream().noneMatch(r -> r.id().equals(port.resourceRequirement().get())))
                        return fail(new InvalidSignature(function.reference(), "input resource requirement"));
                }
                for (ResourceRequirement requirement : function.resourceInputs()) {
                    if ((failure = checkType(requirement.tokenType())) != null) return fail(failure);
                    if (requirement.multiplicity().signum() == 0) return fail(new InvalidSignature(function.reference(), "zero resource multiplicity"));
                }
                for (OutcomeContract outcome : function.outcomes()) {
                    if ((failure = uniqueIds("output port", outcome.valuePorts().stream().map(v -> v.id().value()).toList())) != null) return fail(failure);
                    if ((failure = uniqueIds("resource production", outcome.producedResources().stream().map(v -> v.id().value()).toList())) != null) return fail(failure);
                    for (OutputPort port : outcome.valuePorts()) {
                        if ((failure = checkType(port.contract().typeRef())) != null) return fail(failure);
                        if (port.resourceProduction().isPresent() && outcome.producedResources().stream().noneMatch(p -> p.id().equals(port.resourceProduction().get())))
                            return fail(new InvalidSignature(function.reference(), "output resource production"));
                    }
                    for (ResourceProduction production : outcome.producedResources())
                        if ((failure = checkType(production.tokenType())) != null) return fail(failure);
                }
                if (function.handlesFailure().isPresent() && !failureOriginDefined(function.handlesFailure().get()))
                    return fail(new InvalidSignature(function.reference(), "failure handler origin"));
            }
            for (InvocationSite site : input.invocationDomain().sites()) {
                FunctionSignature function = signature(site.function());
                if (function == null) return fail(new UnresolvedFunction(site.function()));
                if (!input.allowedEffects().contains(function.effect())) return fail(new SiteEffectNotPermitted(site.id(), function.effect()));
                if (function.form() instanceof DeclaredTransform && !input.invocationDomain().permittedTransforms().contains(function.reference()))
                    return fail(new TransformNotPermitted(function.reference()));
            }
            for (InitialInput initial : input.initialInputs()) {
                if ((failure = checkType(initial.contract().typeRef())) != null) return fail(failure);
                if (initial.source() instanceof SuppliedValue supplied) {
                    try { context.validateSlot(initial.contract(), supplied.value()); }
                    catch (ValueRejection rejected) { return fail(new InvalidInitialValue(initial.id(), rejected)); }
                    catch (necoherence.semantic.SemanticValues.ValueProcessingFailure unresolved) { }
                }
                if (initial.resource().isPresent() && input.initialResources().stream().noneMatch(lot -> lot.id().equals(initial.resource().get())))
                    return fail(new InvalidResourceDeclaration("initial backing lot"));
            }
            for (ResourceLot lot : input.initialResources()) {
                if ((failure = checkType(lot.tokenType())) != null) return fail(failure);
                if (lot.producer() instanceof InitialResourceProducer producer) {
                    if (producer.identity().isEmpty() || producer.revision().isEmpty() || lot.provenance().isEmpty())
                        return fail(new InvalidResourceDeclaration("initial producer or provenance"));
                } else return fail(new InvalidResourceDeclaration("initial lot has an invocation producer"));
            }
            if (input.goal().outputs().isEmpty()) return fail(new EmptyGoal());
            for (GoalPort goal : input.goal().outputs()) {
                if ((failure = checkType(goal.contract().typeRef())) != null) return fail(failure);
                if (!sourceConstraintDefined(goal.sourceConstraint())) return fail(new GoalSourceConstraintUndefined(goal.id(), goal.sourceConstraint()));
            }
            for (FailureEmbedding embedding : input.goal().failures()) {
                if ((failure = checkType(embedding.contract().typeRef())) != null) return fail(failure);
                if (!failureOriginDefined(embedding.origin())) return fail(new FailureEmbeddingOriginUndefined(embedding.id(), embedding.origin()));
            }
            for (PermittedProjection projection : input.invocationDomain().permittedProjections())
                if ((failure = checkType(projection.sourceType())) != null) return fail(failure);
            if ((failure = uniqueIds("construction", input.invocationDomain().permittedConstructions().stream().map(ConstructionRule::identity).toList())) != null) return fail(failure);
            int constructionEdges = input.invocationDomain().permittedConstructions().stream().mapToInt(r -> r.nestedFields().size()).sum();
            for (ConstructionRule construction : input.invocationDomain().permittedConstructions()) {
                if ((failure = checkType(construction.typeRef())) != null) return fail(failure);
                if (!(resolvedShape(graph, construction.typeRef()).orElse(null)
                        instanceof necoherence.semantic.SemanticTypes.ProductShape product))
                    return fail(new ConstructionNotProduct(construction.identity(), construction.typeRef()));
                List<necoherence.semantic.SemanticTypes.FieldSpec> fields = product.spec().fields();
                if ((failure = uniqueIds("nested field", construction.nestedFields().stream().map(NamedConstruction::field).toList())) != null) return fail(failure);
                if ((failure = uniqueIds("field constraint", construction.fieldConstraints().stream().map(FieldConstraint::field).toList())) != null) return fail(failure);
                for (FieldConstraint constraint : construction.fieldConstraints()) {
                    if (fields.stream().noneMatch(field -> field.wireName().equals(constraint.field()))) return fail(new FieldConstraintUnknownField(construction.identity(), constraint.field()));
                    if (construction.nestedFields().stream().anyMatch(nested -> nested.field().equals(constraint.field()))) return fail(new ConstrainedNestedField(construction.identity(), constraint.field()));
                    if (!sourceConstraintDefined(constraint.source())) return fail(new ConstructionFieldSourceUndefined(construction.identity(), constraint));
                }
                for (NamedConstruction nested : construction.nestedFields()) {
                    necoherence.semantic.SemanticTypes.FieldSpec field = fields.stream().filter(candidate -> candidate.wireName().equals(nested.field())).findFirst().orElse(null);
                    if (field == null) return fail(new NestedFieldUndeclared(construction.identity(), nested.field()));
                    TypeRef fieldType = field.slot().typeRef();
                    if (input.invocationDomain().permittedConstructions().stream().noneMatch(rule -> rule.identity().equals(nested.construction()) && rule.typeRef().equals(fieldType)))
                        return fail(new NestedConstructionMismatch(construction.identity(), nested.field(), nested.construction(), fieldType));
                    if (constructionReachable(nested.construction(), constructionEdges).contains(construction.identity()))
                        return fail(new CyclicConstruction(construction.identity()));
                }
            }
            for (DeclaredGuard guard : input.invocationDomain().guards()) {
                if ((failure = checkType(guard.sourceType())) != null) return fail(failure);
                if (guard.kind() instanceof ValidateGuard validate && (failure = checkType(validate.contract().typeRef())) != null) return fail(failure);
            }
            for (SiteOrder order : input.explicitOrder()) {
                if (order.before().equals(order.after()) || CompositionPlanWire.siteSignature(input, order.before()).isEmpty() || CompositionPlanWire.siteSignature(input, order.after()).isEmpty())
                    return fail(new ExplicitSiteOrderInvalid(order.before(), order.after()));
            }
            List<ResourceGoal> goals = new ArrayList<>(input.goal().finalResources());
            input.goal().failures().forEach(embedding -> goals.addAll(embedding.finalResources()));
            for (ResourceGoal goal : goals) if (!CompositionPlanWire.declaredLot(input, goal.lot()).isPresent()) return fail(new InvalidResourceDeclaration("terminal resource lot"));
            return Optional.empty();
        }

        private CompositionInputFailure checkType(TypeRef reference) { return graph.findType(reference).isPresent() ? null : new UnresolvedType(reference); }
        private FunctionSignature signature(FunctionRef reference) { return input.signatures().stream().filter(v -> v.reference().equals(reference)).findFirst().orElse(null); }
        private boolean sourceConstraintDefined(SourceConstraint constraint) {
            SlotContract contract; List<PathStep> path;
            if (constraint instanceof AnyCompatible) return true;
            if (constraint instanceof InitialOnly initial) {
                InitialInput source = input.initialInputs().stream().filter(v -> v.id().equals(initial.id())).findFirst().orElse(null);
                if (source == null) return false; contract = source.contract(); path = initial.path();
            } else {
                ProducedBy produced = (ProducedBy) constraint; FunctionSignature function = CompositionPlanWire.siteSignature(input, produced.site()).orElse(null);
                if (function == null) return false;
                OutcomeContract outcome = function.outcomes().stream().filter(v -> v.id().equals(produced.outcome())).findFirst().orElse(null);
                if (outcome == null) return false;
                OutputPort port = outcome.valuePorts().stream().filter(v -> v.id().equals(produced.port())).findFirst().orElse(null);
                if (port == null) return false; contract = port.contract(); path = produced.path();
            }
            return constraintPathDefined(context, contract, path);
        }
        private boolean failureOriginDefined(FailureOrigin origin) {
            if (origin instanceof FunctionFailureOrigin functionOrigin) {
                FunctionSignature function = signature(functionOrigin.function());
                return function != null && function.outcomes().stream().anyMatch(outcome -> outcome.id().equals(functionOrigin.outcome()) && outcome.form() == OutcomeForm.DECLARED_FAILURE);
            }
            GuardFailureOrigin guard = (GuardFailureOrigin) origin;
            return input.invocationDomain().guards().stream().anyMatch(declaration -> declaration.id().equals(guard.guard()));
        }
        private java.util.Map<String, ConstructionRule> constructionRules;
        private List<String> constructionReachable(String initial, int edges) {
            if (constructionRules == null) {
                constructionRules = new java.util.HashMap<>();
                for (ConstructionRule rule : input.invocationDomain().permittedConstructions()) constructionRules.putIfAbsent(rule.identity(), rule);
            }
            List<String> seen = new ArrayList<>(); Set<String> visited = new HashSet<>(); ArrayDeque<String> pending = new ArrayDeque<>(); pending.add(initial);
            int fuel = input.invocationDomain().permittedConstructions().size() + edges + 1;
            while (fuel-- > 0 && !pending.isEmpty()) {
                String identity = pending.removeFirst(); if (!visited.add(identity)) continue; seen.add(identity);
                ConstructionRule rule = constructionRules.get(identity);
                if (rule != null) rule.nestedFields().forEach(field -> pending.addLast(field.construction()));
            }
            return seen;
        }
    }

    private static CompositionInputFailure uniqueIds(String kind, List<String> identities) {
        Set<String> seen = new HashSet<>();
        for (String identity : identities) if (identity.isEmpty() || !seen.add(identity)) return new DuplicateIdentity(kind, identity);
        return null;
    }
    private static Optional<CompositionInputFailure> fail(CompositionInputFailure failure) { return Optional.of(failure); }
    static TypeRef typeRefFromWire(WireValue reference) { return necoherence.semantic.SemanticGraphWire.typeRef(reference, "$"); }
    /** The Lean constraintPathDefined: the path of the contract projects with the variant assumptions of the path. */
    static boolean constraintPathDefined(necoherence.semantic.SemanticValues.Context context, SlotContract contract,
            List<PathStep> path) {
        try {
            SemanticProjection.projectSlot(context, contract, path, variantAssumptions(path));
            return true;
        } catch (SemanticProjection.ProjectionRejection rejected) {
            return false;
        }
    }

    private static List<ProjectionAssumption> variantAssumptions(List<PathStep> path) {
        List<ProjectionAssumption> result = new ArrayList<>();
        for (int index = 0; index < path.size(); index++) if (path.get(index) instanceof Variant variant)
            result.add(new VariantAssumption(path.subList(0, index), variant.wireTag()));
        return result;
    }
    private static BigInteger natural(BigInteger value) {
        Objects.requireNonNull(value); if (value.signum() < 0) throw new IllegalArgumentException("natural"); return value;
    }
    private static <T> List<T> copy(List<T> values) {
        List<T> result = List.copyOf(Objects.requireNonNull(values)); result.forEach(Objects::requireNonNull); return result;
    }
    private static List<BigInteger> copyNaturals(List<BigInteger> values) { return copy(values).stream().map(SemanticComposition::natural).toList(); }
    private static <T> Optional<T> optional(Optional<T> value) { return Objects.requireNonNull(value).map(Objects::requireNonNull); }

        static String encodeTuple(List<String> parts) {
        StringBuilder result = new StringBuilder();
        for (String part : parts)
            result.append(part.getBytes(StandardCharsets.UTF_8).length).append(':').append(part);
        return result.toString();
    }
        static String functionIdentity(FunctionRef reference) {
        return encodeTuple(List.of(reference.identity(), reference.revision(), reference.contentDigest()));
    }
        private static Optional<TypeShape> resolvedShapeFuel(SemanticTypes.SemanticGraph graph, int fuel, TypeRef reference) {
        if (fuel == 0) return Optional.empty();
        Optional<TypeNode> node = graph.findType(reference);
        if (node.isEmpty()) return Optional.empty();
        if (node.get().shape() instanceof AliasShape alias) return resolvedShapeFuel(graph, fuel - 1, alias.target());
        return Optional.of(node.get().shape());
    }
        public static Optional<TypeShape> resolvedShape(SemanticTypes.SemanticGraph graph, TypeRef reference) {
        return resolvedShapeFuel(graph, graph.nodes().size() + 1, reference);
    }
}
