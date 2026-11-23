// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.composition;

import static necoherence.semantic.SemanticValues.*;
import static necoherence.composition.SemanticComposition.*;
import static necoherence.composition.WireDecode.*;
import static necoherence.composition.WireDecode.keys;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import necoherence.semantic.ExactJson;
import necoherence.semantic.ExactJson.JsonMember;
import necoherence.semantic.ExactJson.JsonObj;
import necoherence.semantic.ExactJson.JsonValue;
import necoherence.semantic.SemanticGeneration.GenerationFailure;
import necoherence.semantic.WireJson;
import necoherence.semantic.SemanticGraphWire;
import necoherence.semantic.TypeSignatures;
import necoherence.semantic.SemanticValues.Context;
import necoherence.semantic.SemanticValidation;
import necoherence.semantic.SemanticValues;
import necoherence.semantic.SemanticValues.Slot;
import necoherence.semantic.SemanticValues.WireValue;
import necoherence.semantic.SemanticValues.ArrayValue;
import necoherence.semantic.SemanticValues.Member;
import necoherence.semantic.SemanticValues.ObjectValue;
import necoherence.semantic.SemanticValues.StringValue;
import necoherence.semantic.WireFailure;
import necoherence.semantic.WireFailure.Syntax;
import necoherence.typed.TypedMapping;
import necoherence.typed.TypedMapping.AcyclicWitness;
import necoherence.typed.TypedMapping.ClosureWitness;
import necoherence.typed.TypedMapping.ColoredToken;
import necoherence.typed.TypedMapping.DeclarationGraph;
import necoherence.typed.TypedMapping.DomainBound;
import necoherence.typed.TypedMapping.GoalAnd;
import necoherence.typed.TypedMapping.GoalNot;
import necoherence.typed.TypedMapping.GoalOr;
import necoherence.typed.TypedMapping.GoalPredicate;
import necoherence.typed.TypedMapping.InputBinding;
import necoherence.typed.TypedMapping.Marking;
import necoherence.typed.TypedMapping.PlaceHasAtLeast;
import necoherence.typed.TypedMapping.PlaceHasToken;
import necoherence.typed.TypedMapping.PlaceTokens;
import necoherence.typed.TypedMapping.ReachabilityWitness;
import necoherence.typed.TypedMapping.SolverInput;
import necoherence.typed.TypedMapping.TokenKind;
import necoherence.typed.TypedMapping.TypedPlace;
import necoherence.typed.TypedMapping.TypedTransition;

public final class CompositionPlanWire {
    private CompositionPlanWire() {}

        record Expected(WireValue library, WireValue basis, SemanticBasis typed,
            necoherence.semantic.SemanticTypes.SemanticGraph graph) {}
        static Expected expectedBasis(WireValue library, PreparedCompositionInput prepared, WireValue problem) {
        return new Expected(library, f(problem, "basis"), SemanticBasis.of(prepared.typedGraph()), prepared.typedGraph());
    }
        static WireValue declaredShape(WireValue library, TypeRef reference) {
        return a(f(library, "nodes")).stream()
                .filter(node -> s(f(node, "id")).equals(reference.definitionName()))
                .findFirst().map(node -> f(node, "shape"))
                .orElseThrow(() -> new DecodeRejection("undeclared type"));
    }
        static PlanTree decodePlanRoot(WireValue plan, Expected expected) {
        return planTree(prop(plan, "root"), expected);
    }
        static Slot<JsonValue> slotValue(WireValue value) {
        String tag = tagOf(value);
        if (tag.equals("Absent")) {
            keys(value, "tag");
            return new Absent<>();
        }
        if (tag.equals("Null")) {
            keys(value, "tag");
            return new NullSlot<>();
        }
        if (!tag.equals("Present")) throw unknownTag("$.tag", tag);
        keys(value, "tag", "value");
        return new Present<>(WireJson.fromWire(SignatureCompositionWire.exactWire(prop(value, "value"))));
    }
        static ProducerRef producerReference(WireValue producer) {
        String tag = tagOf(producer);
        return switch (tag) {
            case "Initial" -> new InitialProducer(new InputId(text(payloadOf(producer))));
            case "InvocationOutcome" -> {
                WireValue row = fieldsOf(producer);
                keys(row, "site", "outcome", "port");
                yield new InvocationOutcomeProducer(new SiteId(textAt(row, "site")),
                        new OutcomeId(textAt(row, "outcome")), new PortId(textAt(row, "port")));
            }
            default -> throw unknownTag("$.tag", tag);
        };
    }
        static ValueRef valueReference(WireValue value) {
        keys(value, "producer", "path");
        ProducerRef producer = get(value, "producer", CompositionPlanWire::producerReference);
        return new ValueRef(producer, getList(value, "path", CompositionPlanWire::pathStep));
    }
        private static PlanTree planTree(WireValue tree, Expected expected) {
        keys(tree, "rank", "node");
        BigInteger rank = natAt(tree, "rank");
        WireValue node = prop(tree, "node");
        String tag = tagOf(node);
        return switch (tag) {
            case "Return" -> new ReturnTree(rank, returnPlan(payloadOf(node), expected));
            case "Invoke" -> {
                WireValue row = fieldsOf(node);
                keys(row, "invocation", "arms", "empty_outcomes");
                List<OutcomeArm> arms = listProp(row, "arms", arm -> {
                    List<WireValue> items = pair(arm, "invocation arm pair size");
                    return new OutcomeArm(new OutcomeId(text(items.get(0))), planTree(items.get(1), expected));
                });
                InvocationPlan invocation = invocationPlan(prop(row, "invocation"), expected);
                List<OutcomeId> empty = getList(row, "empty_outcomes", value -> new OutcomeId(text(value)));
                yield new InvokeTree(rank, invocation, arms, empty);
            }
            case "Guard" -> {
                WireValue row = fieldsOf(node);
                keys(row, "guard", "inspected", "arms");
                List<GuardTreeArm> arms = listProp(row, "arms", arm -> {
                    List<WireValue> items = pair(arm, "guard arm pair size");
                    return new GuardTreeArm(guardArm(items.get(0)), planTree(items.get(1), expected));
                });
                GuardId guard = new GuardId(textAt(row, "guard"));
                ValueRef inspected = get(row, "inspected", CompositionPlanWire::valueReference);
                yield new GuardTree(rank, guard, inspected, arms);
            }
            default -> throw unknownTag("$.tag", tag);
        };
    }
        static ReturnPlan returnPlan(WireValue value, Expected expected) {
        String tag = tagOf(value);
        return switch (tag) {
            case "Success" -> {
                List<GoalBinding> outputs = array(payloadOf(value)).stream().map(item -> {
                    List<WireValue> items = pair(item, "output pair size");
                    return new GoalBinding(new GoalPortId(text(items.get(0))), bindingExpr(items.get(1), expected));
                }).toList();
                yield new SuccessReturn(outputs);
            }
            case "Failure" -> {
                WireValue row = fieldsOf(value);
                keys(row, "embedding", "value");
                yield new FailureReturn(new FailureEmbeddingId(textAt(row, "embedding")),
                        bindingExpr(prop(row, "value"), expected));
            }
            default -> throw unknownTag("$.tag", tag);
        };
    }
        static InvocationPlan invocationPlan(WireValue value, Expected expected) {
        keys(value, "site", "function", "bindings", "resources");
        List<ResourceBinding> resources = listProp(value, "resources", binding -> {
            keys(binding, "requirement", "lot", "inclusion");
            RequirementId requirement = new RequirementId(textAt(binding, "requirement"));
            ResourceLotRef lot = get(binding, "lot", CompositionPlanWire::resourceLotReference);
            InclusionCertificate inclusion = inclusion(prop(binding, "inclusion"), expected);
            return new ResourceBinding(requirement, lot, inclusion);
        });
        List<PortBinding> bindings = listProp(value, "bindings", pair -> {
            List<WireValue> items = pair(pair, "invocation binding pair size");
            return new PortBinding(new PortId(text(items.get(0))), bindingExpr(items.get(1), expected));
        });
        SiteId site = new SiteId(textAt(value, "site"));
        FunctionRef function = get(value, "function", CompositionPlanWire::functionReference);
        return new InvocationPlan(site, function, bindings, resources);
    }
        private static BindingExpr bindingExpr(WireValue value, Expected expected) {
        String tag = tagOf(value);
        return switch (tag) {
            case "Source" -> {
                WireValue row = fieldsOf(value);
                keys(row, "value", "projection", "compatibility");
                BindingCompatibility compatibility = compatibility(prop(row, "compatibility"), expected);
                ValueRef reference = get(row, "value", CompositionPlanWire::valueReference);
                ProjectionCertificate projection = get(row, "projection", CompositionPlanWire::projection);
                yield new SourceBinding(reference, projection, compatibility);
            }
            case "Product" -> {
                WireValue row = fieldsOf(value);
                keys(row, "construction", "type_id", "fields");
                List<NamedBinding> entries = listProp(row, "fields", item -> {
                    List<WireValue> items = pair(item, "construction field pair size");
                    return new NamedBinding(text(items.get(0)), bindingExpr(items.get(1), expected));
                });
                String construction = textAt(row, "construction");
                var typeRef = get(row, "type_id", WireDecode::typeReference);
                yield new ProductBinding(construction, typeRef, entries);
            }
            default -> throw unknownTag("$.tag", tag);
        };
    }
        private static ProjectionCertificate projection(WireValue value) {
        keys(value, "profile", "source_refs", "source", "path", "assumptions", "destination");
        var profile = get(value, "profile", item -> SemanticGraphWire.profileRef(item, "$.profile"));
        var sourceRefs = get(value, "source_refs", row -> {
            List<WireValue> items = array(row);
            return java.util.stream.IntStream.range(0, items.size())
                    .mapToObj(i -> SemanticGraphWire.sourceRef(items.get(i), "$.source_refs[" + i + "]")).toList();
        });
        var source = get(value, "source", WireDecode::slotContract);
        var path = getList(value, "path", CompositionPlanWire::pathStep);
        var assumptions = getList(value, "assumptions", CompositionPlanWire::projectionAssumption);
        var destination = get(value, "destination", WireDecode::slotContract);
        return new ProjectionCertificate(profile, sourceRefs, source, path, assumptions, destination);
    }
        static ProjectionAssumption projectionAssumption(WireValue value) {
        String tag = tagOf(value);
        return switch (tag) {
            case "Present" -> new PresentAssumption(pathSteps(payloadOf(value)));
            case "NonNull" -> new NonNullAssumption(pathSteps(payloadOf(value)));
            case "Variant" -> {
                WireValue row = fieldsOf(value);
                keys(row, "path", "tag");
                var path = getList(row, "path", CompositionPlanWire::pathStep);
                yield new VariantAssumption(path, textAt(row, "tag"));
            }
            case "IndexPresent" -> {
                WireValue row = fieldsOf(value);
                keys(row, "path", "index");
                var path = getList(row, "path", CompositionPlanWire::pathStep);
                yield new IndexPresentAssumption(path, natAt(row, "index"));
            }
            default -> throw unknownTag("$.tag", tag);
        };
    }
        private static List<PathStep> pathSteps(WireValue value) {
        return array(value).stream().map(CompositionPlanWire::pathStep).toList();
    }
        private static BindingCompatibility compatibility(WireValue value, Expected expected) {
        String tag = tagOf(value);
        return switch (tag) {
            case "SuppliedValue" -> {
                WireValue supplied = fieldsOf(value);
                keys(supplied, "value");
                yield new SuppliedValueCompatibility(get(supplied, "value", CompositionPlanWire::slotValue));
            }
            case "Inclusion" -> new InclusionCompatibility(inclusion(payloadOf(value), expected));
            default -> throw unknownTag("$.tag", tag);
        };
    }
        static final class DecodeRejection extends RuntimeException {
        private static final long serialVersionUID = 1L;
        private final transient WireFailure failure;

        DecodeRejection(String condition) { this(new Syntax("$", condition)); }

        DecodeRejection(WireFailure failure) {
            super(String.valueOf(failure));
            this.failure = Objects.requireNonNull(failure);
        }

        WireFailure failure() { return failure; }

        String condition() { return failure instanceof Syntax syntax ? syntax.message() : String.valueOf(failure); }

        /** Lean WireFailure.prepend: the failure is reported under the path segment that the enclosing get adds. */
        DecodeRejection prepend(String segment) { return new DecodeRejection(WireDecode.prefixed(segment, failure)); }
    }
        private static InclusionCertificate inclusion(WireValue value, Expected expected) {
        keys(value, "basis", "source", "destination", "empty_types", "pairs", "root");
        if (!sameJson(get(value, "basis", CompositionPlanWire::basisWire), expected.basis()))
            throw syntax("$", "inclusion basis mismatch");
        SemanticBasis basis = expected.typed();
        List<PairEntry> pairs = listProp(value, "pairs", entry -> pairEntry(entry, expected));
        var source = get(value, "source", WireDecode::slotContract);
        var destination = get(value, "destination", WireDecode::slotContract);
        var emptyTypes = getList(value, "empty_types", WireDecode::typeReference);
        return new InclusionCertificate(basis, source, destination, emptyTypes, pairs, natAt(value, "root"));
    }
        /** Lean {@code Wire Basis} decode: the nine members are read in order, and the profile is a profile reference. */
    private static WireValue basisWire(WireValue basis) {
        try { return TypeSignatures.decodeBasis(basis, "$"); }
        catch (GenerationFailure failure) { throw rejection(failure); }
    }
        /** Lean {@code Wire Shape} decode of a declared shape. */
    private static WireValue shapeWire(WireValue shape) {
        try { return TypeSignatures.decodeShape(shape, "$"); }
        catch (GenerationFailure failure) { throw rejection(failure); }
    }
        private static DecodeRejection rejection(GenerationFailure failure) {
        return new DecodeRejection(failure.wireFailure() != null ? failure.wireFailure() : new Syntax("$", failure.condition()));
    }
        private static PairEntry pairEntry(WireValue entry, Expected expected) {
        keys(entry, "pair", "source_shape", "destination_shape", "rule", "children");
        var typePair = get(entry, "pair", pair -> {
            keys(pair, "source", "destination", "source_tag");
            var source = get(pair, "source", WireDecode::slotContract);
            var destination = get(pair, "destination", WireDecode::slotContract);
            Optional<String> sourceTag = get(pair, "source_tag",
                    tag -> nil(tag) ? Optional.empty() : Optional.of(text(tag)));
            return new TypePair(source, destination, sourceTag);
        });
        WireValue sourceDeclared = declaredShape(expected.library(), typePair.source().typeRef());
        WireValue destinationDeclared = declaredShape(expected.library(), typePair.destination().typeRef());
        var sourceShape = get(entry, "source_shape", CompositionPlanWire::shapeWire);
        var destinationShape = get(entry, "destination_shape", CompositionPlanWire::shapeWire);
        if (!sameJson(sourceShape, sourceDeclared) || !sameJson(destinationShape, destinationDeclared))
            throw syntax("$", "inclusion shape mismatch");
        return new PairEntry(typePair, lift(() -> SemanticGraphWire.shape(TypeSignatures.internalShape(sourceDeclared))),
                lift(() -> SemanticGraphWire.shape(TypeSignatures.internalShape(destinationDeclared))),
                inclusionRule(prop(entry, "rule")),
                getList(entry, "children", WireDecode::nat));
    }
        private static InclusionRule inclusionRule(WireValue json) {
        String tag = tagOf(json);
        InclusionRule rule = switch (tag) {
            case "SameDefinedType" -> InclusionRule.SAME_DEFINED_TYPE;
            case "EmptySource" -> InclusionRule.EMPTY_SOURCE;
            case "Boolean" -> InclusionRule.BOOLEAN;
            case "IntegerIntersection" -> InclusionRule.INTEGER_INTERSECTION;
            case "FiniteStrings" -> InclusionRule.FINITE_STRINGS;
            case "StringConditions" -> InclusionRule.STRING_CONDITIONS;
            case "BytesLength" -> InclusionRule.BYTES_LENGTH;
            case "Unit" -> InclusionRule.UNIT;
            case "UnfoldSource" -> InclusionRule.UNFOLD_SOURCE;
            case "UnfoldDestination" -> InclusionRule.UNFOLD_DESTINATION;
            case "Array" -> InclusionRule.ARRAY;
            case "Product" -> InclusionRule.PRODUCT;
            case "SourceUnion" -> InclusionRule.SOURCE_UNION;
            case "DestinationUnion" -> InclusionRule.DESTINATION_UNION;
            default -> throw unknownTag("$.tag", tag);
        };
        keys(json, "tag");
        return rule;
    }
        static FunctionRef functionReference(WireValue value) {
        keys(value, "identity", "revision", "content_digest");
        return new FunctionRef(textAt(value, "identity"), textAt(value, "revision"), textAt(value, "content_digest"));
    }
        static ResourceLotRef resourceLotReference(WireValue value) {
        String tag = tagOf(value);
        return switch (tag) {
            case "Initial" -> new InitialLot(new LotId(text(payloadOf(value))));
            case "Produced" -> {
                WireValue row = fieldsOf(value);
                keys(row, "site", "outcome", "production");
                yield new ProducedLot(new SiteId(textAt(row, "site")), new OutcomeId(textAt(row, "outcome")),
                        new ProductionId(textAt(row, "production")));
            }
            default -> throw unknownTag("$.tag", tag);
        };
    }
        static GuardArm guardArm(WireValue value) {
        String tag = tagOf(value);
        return switch (tag) {
            case "Absent" -> { keys(value, "tag"); yield new AbsentArm(); }
            case "Null" -> { keys(value, "tag"); yield new NullArm(); }
            case "Present" -> { keys(value, "tag"); yield new PresentArm(); }
            case "Variant" -> new VariantArm(text(payloadOf(value)));
            case "UnknownVariant" -> { keys(value, "tag"); yield new UnknownVariantArm(); }
            case "Accepted" -> { keys(value, "tag"); yield new AcceptedArm(); }
            case "Rejected" -> { keys(value, "tag"); yield new RejectedArm(); }
            default -> throw unknownTag("$.tag", tag);
        };
    }
        static PathStep pathStep(WireValue value) {
        String tag = tagOf(value);
        return switch (tag) {
            case "Field" -> new Field(text(payloadOf(value)));
            case "Index" -> new Index(nat(payloadOf(value)));
            case "Variant" -> new Variant(text(payloadOf(value)));
            default -> throw unknownTag("$.tag", tag);
        };
    }

            record LotDeclaration(TypeRef tokenType, ResourceProducer producer, BigInteger revision, BigInteger quantity,
            String provenance) {}
            static Optional<FunctionSignature> siteSignature(CompositionInput input, SiteId site) {
        return input.invocationDomain().sites().stream().filter(candidate -> candidate.id().equals(site)).findFirst()
                .flatMap(declaration -> input.signatures().stream()
                        .filter(candidate -> candidate.reference().equals(declaration.function())).findFirst());
    }
            static Optional<LotDeclaration> declaredLot(CompositionInput input, ResourceLotRef lot) {
        if (lot instanceof InitialLot initial) {
            return input.initialResources().stream().filter(candidate -> candidate.id().equals(initial.id())).findFirst()
                    .map(candidate -> new LotDeclaration(candidate.tokenType(), candidate.producer(), candidate.revision(),
                            candidate.quantity(), candidate.provenance()));
        }
        ProducedLot produced = (ProducedLot) lot;
        return siteSignature(input, produced.site())
                .flatMap(function -> function.outcomes().stream()
                        .filter(candidate -> candidate.id().equals(produced.outcome())).findFirst())
                .flatMap(branch -> branch.producedResources().stream()
                        .filter(candidate -> candidate.id().equals(produced.production())).findFirst())
                .map(production -> new LotDeclaration(production.tokenType(),
                        new InvocationOutcomeResourceProducer(produced.site(), produced.outcome()),
                        production.revision(), production.quantity(), production.provenance()));
    }
}
