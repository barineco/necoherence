// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.composition;

import static necoherence.composition.SemanticComposition.*;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import necoherence.semantic.SemanticTypes;
import necoherence.semantic.SemanticTypes.*;
import necoherence.semantic.ExactJson.*;
import necoherence.semantic.SemanticValidation;
import necoherence.semantic.ExactJson;
import necoherence.semantic.ExactJson.*;
import static necoherence.semantic.ExactJson.NIL;
import static necoherence.semantic.ExactJson.unicodeValid;
import necoherence.semantic.SemanticValues;
import necoherence.semantic.SemanticValues.Absent;
import necoherence.semantic.SemanticValues.NullSlot;
import necoherence.semantic.SemanticValues.Present;
import necoherence.semantic.SemanticValues.SimpleValueCondition;
import necoherence.semantic.SemanticValues.Slot;
import necoherence.semantic.SemanticValues.ValueCondition;

public final class EmptyTypeClosure {
    private EmptyTypeClosure() {}

            public sealed interface Verification<T> permits Verified, VerificationFailed {}
            public record Verified<T>(T value) implements Verification<T> {
        public Verified { value = Objects.requireNonNull(value); }
    }
            public record VerificationFailed<T>(InclusionFailure failure) implements Verification<T> {
        public VerificationFailed { failure = Objects.requireNonNull(failure); }
    }
            public static final class CheckedEmptyTypes {
        private final SemanticGraph graph;
        private final List<TypeRef> references;

        CheckedEmptyTypes(SemanticGraph graph, List<TypeRef> references) {
            this.graph = Objects.requireNonNull(graph);
            this.references = List.copyOf(references);
        }

        public SemanticGraph graph() { return graph; }

        public List<TypeRef> references() { return references; }
    }
            private static Optional<List<String>> stringFinite(StringSpec spec) {
        if (spec.constValue().isPresent()) return Optional.of(List.of(spec.constValue().get()));
        return spec.enumValues();
    }
            private static boolean natRangeEmpty(Optional<BigInteger> minimum, Optional<BigInteger> maximum) {
        return minimum.isPresent() && maximum.isPresent() && maximum.get().compareTo(minimum.get()) < 0;
    }
            private static final class InclusionRejection extends RuntimeException {
        private static final long serialVersionUID = 1L;
        private final transient InclusionFailure failure;

        InclusionRejection(InclusionFailure failure) {
            super(null, null, false, false);
            this.failure = Objects.requireNonNull(failure);
        }

        InclusionFailure failure() { return failure; }
    }
            private static InclusionRejection reject(InclusionFailure failure) { return new InclusionRejection(failure); }
            private static void checkEmptyRow(SemanticValues.Context context, Set<TypeRef> refs, TypeRef ref) {
        TypeNode found = resolveOption(context.typed().findType(ref), () -> reject(new ForgedEmptiness()));
        switch (found.shape()) {
            case AliasShape alias -> {
                if (!refs.contains(alias.target())) throw reject(new ForgedEmptiness());
            }
            case StringShape string -> {
                if (string.spec().wrapper().isPresent()) throw reject(new ForgedEmptiness());
                List<String> finite = stringFinite(string.spec()).orElseThrow(() -> reject(new ForgedEmptiness()));
                for (String value : finite)
                    if (SemanticValidation.stringCondition(context, string.spec(), value).isEmpty()) throw reject(new ForgedEmptiness());
            }
            case BytesShape bytes -> {
                if (!natRangeEmpty(bytes.spec().minimum(), bytes.spec().maximum())) throw reject(new ForgedEmptiness());
            }
            case ProductShape product -> resolveOption(product.spec().fields().stream()
                    .filter(field -> field.slot().required() && !field.slot().nullable() && refs.contains(field.slot().typeRef()))
                    .findFirst(), () -> reject(new ForgedEmptiness()));
            case ArrayShape array -> {
                if (natRangeEmpty(array.spec().minLength(), array.spec().maxLength())) return;
                boolean blocked = array.spec().minLength().orElse(BigInteger.ZERO).signum() > 0
                        && !array.spec().item().nullable() && refs.contains(array.spec().item().typeRef());
                if (!blocked) throw reject(new ForgedEmptiness());
            }
            case TaggedUnionShape union -> {
                if (!union.spec().branches().stream().allMatch(branch -> refs.contains(branch.target())))
                    throw reject(new ForgedEmptiness());
            }
            default -> throw reject(new ForgedEmptiness());
        }
    }
            private static Optional<InclusionFailure> emptyRowFailure(SemanticValues.Context context, Set<TypeRef> refs, TypeRef ref) {
        try {
            checkEmptyRow(context, refs, ref);
            return Optional.empty();
        } catch (InclusionRejection rejection) {
            return Optional.of(rejection.failure());
        }
    }
            static Verification<CheckedEmptyTypes> verifyEmptyTypes(SemanticValues.Context context, List<TypeRef> refs) {
        Set<TypeRef> members = new HashSet<>(refs);
        if (members.size() != refs.size()) return failed(new ForgedEmptiness());
        for (TypeRef ref : refs) {
            Optional<InclusionFailure> row = emptyRowFailure(context, members, ref);
            if (row.isPresent()) return failed(row.get());
        }
        return verified(new CheckedEmptyTypes(context.typed(), refs));
    }
            private static List<TypeRef> pruneEmptyTypes(SemanticValues.Context context, int fuel, List<TypeRef> refs) {
        SemanticTypes.SemanticGraph graph = context.typed();
        if (fuel <= refs.size()) return pruneEmptyTypesByPasses(context, fuel, refs);
        Set<TypeRef> members = new HashSet<>(refs);
        java.util.Map<TypeRef, List<TypeRef>> dependents = new java.util.HashMap<>();
        for (TypeRef ref : refs) {
            Optional<TypeNode> node = graph.findType(ref);
            if (node.isEmpty()) continue;
            for (TypeRef child : SemanticTypes.typeChildren(node.get().shape()))
                dependents.computeIfAbsent(child, unused -> new ArrayList<>()).add(ref);
        }
        java.util.ArrayDeque<TypeRef> pending = new java.util.ArrayDeque<>(refs);
        while (!pending.isEmpty()) {
            TypeRef ref = pending.removeFirst();
            if (!members.contains(ref) || emptyRowFailure(context, members, ref).isEmpty()) continue;
            members.remove(ref);
            for (TypeRef dependent : dependents.getOrDefault(ref, List.of())) if (members.contains(dependent)) pending.addLast(dependent);
        }
        return refs.stream().filter(members::contains).toList();
    }
            private static List<TypeRef> pruneEmptyTypesByPasses(SemanticValues.Context context, int fuel, List<TypeRef> refs) {
        while (fuel > 0) {
            Set<TypeRef> members = new HashSet<>(refs);
            List<TypeRef> retained = refs.stream()
                    .filter(ref -> emptyRowFailure(context, members, ref).isEmpty()).toList();
            if (retained.size() == refs.size()) return retained;
            fuel--;
            refs = retained;
        }
        return refs;
    }
            static List<TypeRef> emptyTypes(SemanticValues.Context context) {
        SemanticTypes.SemanticGraph graph = context.typed();
        Set<TypeRef> distinct = new LinkedHashSet<>();
        for (TypeNode node : graph.nodes()) distinct.add(node.ref());
        return pruneEmptyTypes(context, graph.nodes().size() + 1, List.copyOf(distinct));
    }
            private static <T> Verification<T> verified(T value) { return new Verified<>(value); }
            private static <T> Verification<T> failed(InclusionFailure failure) { return new VerificationFailed<>(failure); }

    static <T, X extends RuntimeException> T resolveOption(Optional<T> option, java.util.function.Supplier<X> failure) {
        return option.orElseThrow(failure);
    }
}
