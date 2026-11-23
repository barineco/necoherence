// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.composition;

import java.util.List;
import java.util.Objects;
import java.util.Optional;
import static necoherence.semantic.SemanticValues.append;
import necoherence.composition.SemanticComposition.BranchAssumptionRequired;
import necoherence.composition.SemanticComposition.CertificateMismatch;
import necoherence.composition.SemanticComposition.MissingFieldFailure;
import necoherence.composition.SemanticComposition.MissingVariant;
import necoherence.composition.SemanticComposition.PathStep;
import necoherence.composition.SemanticComposition.ProjectionAssumption;
import necoherence.composition.SemanticComposition.ProjectionCertificate;
import necoherence.composition.SemanticComposition.ProjectionFailure;
import necoherence.composition.SemanticComposition.SlotContract;
import necoherence.composition.SemanticComposition.UnresolvedProjection;
import necoherence.composition.SemanticComposition.VariantSelectionUndetermined;
import necoherence.composition.SemanticComposition.WrongShape;
import necoherence.semantic.SemanticTypes.AliasShape;
import necoherence.semantic.SemanticTypes.ArrayShape;
import necoherence.semantic.SemanticTypes.FieldSpec;
import necoherence.semantic.SemanticTypes.InternalTagSelector;
import necoherence.semantic.SemanticTypes.KindSelector;
import necoherence.semantic.SemanticTypes.MembershipBound;
import necoherence.semantic.SemanticTypes.ProductShape;
import necoherence.semantic.SemanticTypes.SemanticGraph;
import necoherence.semantic.SemanticTypes.SemanticObligation;
import necoherence.semantic.SemanticTypes.TaggedUnionShape;
import necoherence.semantic.SemanticTypes.TypeNode;
import necoherence.semantic.SemanticTypes.UnionBranch;
import necoherence.semantic.SemanticTypes.ValueKind;
import necoherence.semantic.SemanticValidation;
import necoherence.semantic.SemanticValues;

public final class SemanticProjection {
    private SemanticProjection() {}

        public static final class ProjectionRejection extends RuntimeException {
        private static final long serialVersionUID = 1L;
        private final transient ProjectionFailure failure;

        public ProjectionRejection(ProjectionFailure failure) {
            super(null, null, false, false);
            this.failure = Objects.requireNonNull(failure);
        }

        public ProjectionFailure failure() { return failure; }
    }

        public static ProjectionCertificate projectSlot(SemanticValues.Context context, SlotContract source, List<PathStep> path,
            List<ProjectionAssumption> assumptions) {
        Objects.requireNonNull(context);
        SemanticGraph graph = context.typed(); Objects.requireNonNull(source); path = List.copyOf(path);
        assumptions = List.copyOf(assumptions);
        List<SemanticObligation> obligations = SemanticValidation.meaningObligations(context, List.of(source.typeRef()));
        if (!obligations.isEmpty()) throw new ProjectionRejection(new UnresolvedProjection(obligations));
        long fuel = (long) (path.size() + 1) * (graph.nodes().size() + 1);
        SlotContract destination = projectContract(graph, assumptions, fuel, source, List.of(), path);
        List<SemanticObligation> destinationObligations =
                SemanticValidation.meaningObligations(context, List.of(destination.typeRef()));
        if (!destinationObligations.isEmpty()) throw new ProjectionRejection(new UnresolvedProjection(destinationObligations));
        return new ProjectionCertificate(graph.profile().reference(), graph.sourceRefs(),
                source, path, assumptions, destination);
    }

        public static ProjectionCertificate checkProjectionCertificate(SemanticValues.Context context, ProjectionCertificate certificate) {
        SemanticGraph graph = context.typed();
        if (!certificate.profile().equals(graph.profile().reference())
                || !certificate.sourceRefs().equals(graph.sourceRefs()))
            throw new ProjectionRejection(new CertificateMismatch("profile or source revisions"));
        ProjectionCertificate computed = projectSlot(context, certificate.source(), certificate.path(),
                certificate.assumptions());
        if (computed.equals(certificate)) return computed;
        throw new ProjectionRejection(new CertificateMismatch("projection contract or guards"));
    }

    private static SlotContract projectContract(SemanticGraph graph, List<ProjectionAssumption> assumptions,
            long fuel, SlotContract slot, List<PathStep> traversed, List<PathStep> remaining) {
        if (fuel == 0)
            throw new ProjectionRejection(new UnresolvedProjection(List.of(SemanticValidation.obligationAt(graph,
                    slot.typeRef(), traversed, new MembershipBound()))));
        SlotContract current = strengthenProjection(slot, traversed, assumptions);
        if (remaining.isEmpty()) return current;
        PathStep step = remaining.getFirst();
        List<PathStep> rest = remaining.subList(1, remaining.size());
        TypeNode node = graph.findType(current.typeRef()).orElseThrow(() -> new ProjectionRejection(
                new UnresolvedProjection(List.of(SemanticValidation.obligationAt(graph, current.typeRef(),
                        traversed, new necoherence.semantic.SemanticTypes.UnresolvedType())))));
        List<PathStep> traversedNext = append(traversed, step);
        if (node.shape() instanceof AliasShape alias)
            return projectContract(graph, assumptions, fuel - 1, new SlotContract(alias.target(),
                    current.required(), current.nullable()), traversed, remaining);
        if (node.shape() instanceof ProductShape product) {
            if (!(step instanceof SemanticComposition.Field field)) throw wrongShape(current, traversed);
            FieldSpec declared = product.spec().fields().stream()
                    .filter(candidate -> candidate.wireName().equals(field.wireName())).findFirst()
                    .orElseThrow(() -> new ProjectionRejection(new MissingFieldFailure(current.typeRef(), field.wireName())));
            return projectContract(graph, assumptions, fuel - 1, new SlotContract(declared.slot().typeRef(),
                    current.required() && declared.slot().required(),
                    current.nullable() || declared.slot().nullable()), traversedNext, rest);
        }
        if (node.shape() instanceof ArrayShape array) {
            if (!(step instanceof SemanticComposition.Index index)) throw wrongShape(current, traversed);
            boolean present = index.index().compareTo(array.spec().minLength().orElse(java.math.BigInteger.ZERO)) < 0
                    || assumptions.contains(new SemanticComposition.IndexPresentAssumption(traversed, index.index()));
            return projectContract(graph, assumptions, fuel - 1, new SlotContract(array.spec().item().typeRef(),
                    current.required() && present, true), traversedNext, rest);
        }
        if (node.shape() instanceof TaggedUnionShape union) {
            if (!(step instanceof SemanticComposition.Variant variant)) throw wrongShape(current, traversed);
            String tag = variant.wireTag();
            if (!assumptions.contains(new SemanticComposition.VariantAssumption(traversed, tag)))
                throw new ProjectionRejection(new BranchAssumptionRequired(traversed, tag));
            UnionBranch branch = union.spec().branches().stream().filter(candidate -> candidate.wireTag().equals(tag))
                    .findFirst().orElseThrow(() -> new ProjectionRejection(new MissingVariant(current.typeRef(), tag)));
            if (graph.profile().tag().isEmpty())
                throw new ProjectionRejection(new VariantSelectionUndetermined(traversed, tag));
            UnionBranch selected = projectableTagBranch(union.spec().branches(), tag)
                    .orElseThrow(() -> new ProjectionRejection(new VariantSelectionUndetermined(traversed, tag)));
            if (!selected.equals(branch))
                throw new ProjectionRejection(new VariantSelectionUndetermined(traversed, tag));
            return projectContract(graph, assumptions, fuel - 1, new SlotContract(branch.target(),
                    current.required(), current.nullable()), traversedNext, rest);
        }
        throw wrongShape(current, traversed);
    }

    private static ProjectionRejection wrongShape(SlotContract slot, List<PathStep> traversed) {
        return new ProjectionRejection(new WrongShape(slot.typeRef(), traversed));
    }

    private static SlotContract strengthenProjection(SlotContract slot, List<PathStep> path,
            List<ProjectionAssumption> assumptions) {
        boolean observed = assumptions.stream().anyMatch(assumption ->
                (assumption instanceof SemanticComposition.PresentAssumption present && present.path().equals(path))
                || (assumption instanceof SemanticComposition.VariantAssumption variant && variant.path().equals(path))
                || (assumption instanceof SemanticComposition.IndexPresentAssumption index && index.path().equals(path)));
        if (observed) return new SlotContract(slot.typeRef(), true, false);
        if (assumptions.contains(new SemanticComposition.NonNullAssumption(path)))
            return new SlotContract(slot.typeRef(), slot.required(), false);
        return slot;
    }

    private static Optional<UnionBranch> projectableTagBranch(List<UnionBranch> branches, String tag) {
        for (UnionBranch branch : branches) {
            if (branch.wireTag().equals(tag)) {
                return branch.selector() instanceof InternalTagSelector ? Optional.of(branch) : Optional.empty();
            }
            if (!selectorPrecedesInternalTag(branch, tag)) return Optional.empty();
        }
        return Optional.empty();
    }

    private static boolean selectorPrecedesInternalTag(UnionBranch branch, String tag) {
        if (branch.selector() instanceof InternalTagSelector) return !branch.wireTag().equals(tag);
        if (branch.selector() instanceof KindSelector kind) return kind.kind() != ValueKind.OBJECT;
        return false;
    }
}
