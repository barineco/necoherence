// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import neco.quotient.Certificate;
import neco.quotient.Checked;
import neco.quotient.DigestScope;
import neco.quotient.DuplicateRule;
import neco.quotient.Expected;
import neco.quotient.Mismatch;
import neco.quotient.ProjectionDigest;
import neco.quotient.ResidualSet;
import neco.quotient.Result;
import neco.quotient.Rule;
import neco.quotient.RuleEntry;
import neco.quotient.RuleTable;
import neco.quotient.SourceRef;
import necoherence.semantic.SemanticGeneration.GenerationBasis;
import necoherence.semantic.SemanticGeneration.GenerationFailure;
import necoherence.semantic.TypeSignatures.Projections;

/** Admits a declared generation basis and its projections through the neco-quotient certificate check. */
final class GenerationAdmission {
    private GenerationAdmission() {}

    static final String RULE = "ncoh-checked-generation@5";
    static final String PROVENANCE = "admit_signature_generation";
    private static final String DIGEST_SCOPE = "sha256";

    private static final RuleTable<String, String, WireValue, GoalObservations, Projections> TABLE = table();

    /** Builds the certificate from the declared basis and the projections, and the expectation from the caller's basis. */
    static Checked<String, String, WireValue, GoalObservations, Void, Projections> admit(GenerationBasis expected, WireValue declared, WireValue library, Projections projections,
            boolean planDecoded) throws GenerationFailure {
        Certificate<String, String, WireValue, GoalObservations, Void, Projections> certificate = new Certificate<>(RULE,
                new SourceRef<>(s(f(declared, "library_identity")), s(f(declared, "library_revision"))),
                coordinate(declared, actualLibrary(library)), declaredDigests(declared),
                ResidualSet.<Void>of(List.of()), nil(projections.problem()) ? null
                        : planDecoded ? GoalObservations.ofPlan(projections.problem()) : GoalObservations.of(projections.problem()), projections);
        Expected<String, String, WireValue, GoalObservations, Void> expectation = new Expected<>(RULE,
                new SourceRef<>(s(f(expected.value, "library_identity")), s(f(expected.value, "library_revision"))),
                coordinate(expected.value, declaredLibrary(declared)), expected.observations, ResidualSet.<Void>of(List.of()));
        Result<Checked<String, String, WireValue, GoalObservations, Void, Projections>, Mismatch<String>> result =
                Checked.admit(TABLE, certificate, expectation, PROVENANCE);
        if (result instanceof Result.Rejected<Checked<String, String, WireValue, GoalObservations, Void, Projections>, Mismatch<String>>(
                var mismatch)) throw new GenerationFailure("$.basis", mismatch);
        return ((Result.Accepted<Checked<String, String, WireValue, GoalObservations, Void, Projections>, Mismatch<String>>) result).value();
    }

    private static RuleTable<String, String, WireValue, GoalObservations, Projections> table() {
        Rule<String, String, WireValue, GoalObservations, Projections> rule =
                (source, coordinate, observations, evidence) -> recomputedDigests(evidence);
        Result<RuleTable<String, String, WireValue, GoalObservations, Projections>, DuplicateRule> built =
                RuleTable.of(List.of(new RuleEntry<>(RULE, rule)));
        if (built instanceof Result.Accepted<RuleTable<String, String, WireValue, GoalObservations, Projections>, DuplicateRule>(
                var table)) return table;
        throw new IllegalStateException("the generation rule revision is registered once");
    }

    private static Map<String, ProjectionDigest> recomputedDigests(Projections projections) {
        return digests(TypeSignatures.hash(projections.entrypoints()), TypeSignatures.hash(projections.graph()),
                TypeSignatures.hash(projections.metadata()),
                nil(projections.problem()) ? Optional.empty() : Optional.of(TypeSignatures.hash(projections.problem())),
                nil(projections.problem()) ? Optional.empty() : Optional.of(TypeSignatures.hash(observationsOf(projections).value())),
                TypeSignatures.hash(projections.provenance()));
    }

    private static Map<String, ProjectionDigest> declaredDigests(WireValue basis) {
        return digests(s(f(basis, "entrypoints_sha256")), s(f(basis, "graph_sha256")), s(f(basis, "metadata_sha256")),
                nil(f(basis, "problem_sha256")) ? Optional.empty() : Optional.of(s(f(basis, "problem_sha256"))),
                nil(f(basis, "observations_sha256")) ? Optional.empty() : Optional.of(s(f(basis, "observations_sha256"))),
                s(f(basis, "provenance_sha256")));
    }

    private static Map<String, ProjectionDigest> digests(String entrypoints, String graph, String metadata,
            Optional<String> problem, Optional<String> observations, String provenance) {
        Map<String, ProjectionDigest> result = new LinkedHashMap<>();
        result.put("entrypoints", scoped(entrypoints));
        result.put("graph", scoped(graph));
        result.put("metadata", scoped(metadata));
        problem.ifPresent(digest -> result.put("problem", scoped(digest)));
        observations.ifPresent(digest -> result.put("observations", scoped(digest)));
        result.put("provenance", scoped(provenance));
        return result;
    }

    private static GoalObservations observationsOf(Projections projections) {
        return nil(projections.problem()) ? null : GoalObservations.of(projections.problem());
    }

    private static ProjectionDigest scoped(String digest) {
        return new ProjectionDigest(digest, new DigestScope.CrossLanguage(DIGEST_SCOPE));
    }

    private static WireValue coordinate(WireValue basis, WireValue library) {
        return obj("basis", obj("signature_schema", f(basis, "signature_schema"), "profile", f(basis, "profile"),
                "graph_sha256", f(basis, "graph_sha256"), "provenance_sha256", f(basis, "provenance_sha256"),
                "metadata_sha256", f(basis, "metadata_sha256"), "problem_sha256", f(basis, "problem_sha256"),
                "observations_sha256", f(basis, "observations_sha256"), "entrypoints_sha256", f(basis, "entrypoints_sha256")), "library", library);
    }

    private static WireValue declaredLibrary(WireValue basis) {
        return obj("signature_schema", f(basis, "signature_schema"), "identity", f(basis, "library_identity"),
                "revision", f(basis, "library_revision"), "profile", f(basis, "profile"));
    }

    private static WireValue actualLibrary(WireValue library) {
        return obj("signature_schema", f(library, "schema"), "identity", f(library, "identity"),
                "revision", f(library, "revision"), "profile", f(f(library, "profile"), "reference"));
    }
}
