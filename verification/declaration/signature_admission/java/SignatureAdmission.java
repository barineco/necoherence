// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import static necoherence.semantic.SemanticValues.*;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import neco.quotient.CheckResult;
import neco.quotient.Condition;
import neco.quotient.ConditionFailure;
import neco.quotient.DigestChecks;
import neco.quotient.Mismatch;
import neco.quotient.Origin;
import neco.quotient.Prerequisite;
import neco.quotient.ProjectionResult;
import neco.quotient.SourceChecks;
import neco.quotient.Status;
import necoherence.composition.SemanticComposition.InclusionWitnessFailure;
import necoherence.composition.SemanticComposition.InitialMembershipFailure;
import necoherence.semantic.SemanticGeneration;
import necoherence.semantic.SemanticGeneration.CheckedGeneration;
import necoherence.semantic.SemanticGeneration.GenerationBasis;
import necoherence.semantic.SemanticGeneration.GenerationFailure;
import necoherence.semantic.TypeSignatures;

/** Reads a generation exchange and an expected basis from stdin and prints the admission result as JSON. */
public final class SignatureAdmission {
    private SignatureAdmission() {}

    public static void main(String[] args) throws IOException {
        if (args.length == 1 && args[0].equals("--batch")) {
            BufferedReader lines = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
            for (String line = lines.readLine(); line != null; line = lines.readLine()) {
                System.out.println(runGuarded(line));
            }
        } else {
            System.out.println(run(new String(System.in.readAllBytes(), StandardCharsets.UTF_8)));
        }
    }

    static String runGuarded(String line) {
        try {
            return run(line);
        } catch (Exception | StackOverflowError failure) {
            return encodeWire(obj("error", str(failure.getClass().getSimpleName() + ": " + failure.getMessage())));
        }
    }

    static String run(String input) {
        WireValue document;
        try {
            document = SemanticGeneration.readJson(input);
        } catch (RuntimeException failure) {
            return failed(requestFailure("request_json"));
        }
        String exchange;
        try {
            exchange = s(f(document, "exchange"));
        } catch (RuntimeException failure) {
            return failed(requestFailure("request_exchange"));
        }
        WireValue expectedJson;
        try {
            expectedJson = f(document, "expected_basis");
        } catch (RuntimeException failure) {
            return failed(requestFailure("request_expected_basis"));
        }
        GenerationBasis expected;
        try {
            expected = GenerationBasis.decode(encodeWire(expectedJson));
        } catch (GenerationFailure failure) {
            return failed(requestFailure("expected_basis." + wireTag(failure)));
        }
        String mode = requestMode(document);
        if (mode == null) return failed(requestFailure("request_mode"));
        return admission(expected, exchange);
    }

    private static String admission(GenerationBasis expected, String exchange) {
        try {
            return encodeWire(obj("result", str("accepted"),
                    "checked", checked(TypeSignatures.admitGeneration(expected, exchange))));
        } catch (GenerationFailure failure) {
            return failed(failure(failure));
        }
    }

    private static String requestMode(WireValue document) {
        WireValue value;
        try {
            value = f(document, "mode");
        } catch (RuntimeException failure) {
            return "admission";
        }
        try {
            String mode = s(value);
            return mode.equals("admission") ? mode : null;
        } catch (RuntimeException failure) {
            return null;
        }
    }

    private static String wireTag(GenerationFailure failure) {
        return failure.wireFailure() == null ? "syntax" : lowerCamel(failure.wireFailure());
    }

    private static String failed(WireValue failure) {
        return encodeWire(obj("result", str("failed"), "failure", failure));
    }

    private static WireValue decode(String reason) {
        return obj("kind", str("decode"), "reason", str(reason));
    }

    private static WireValue requestFailure(String reason) {
        return obj("kind", str("request"), "reason", str(reason));
    }

    private static WireValue checked(CheckedGeneration checked) {
        WireValue input = checked.input;
        WireValue basis = checked.basis().value;
        List<WireValue> entries = new ArrayList<>(a(f(input, "entrypoints")));
        entries.sort((left, right) -> compareCodePoints(s(f(left, "identity")), s(f(right, "identity"))));
        WireValue library = f(input, "signatures");
        WireValue composition = nil(f(input, "composition")) ? NIL : obj("problem_sha256", f(basis, "problem_sha256"));
        return obj("basis", basis,
                "library", obj("identity", f(library, "identity"), "revision", f(library, "revision")),
                "entrypoints", arr(entries.stream().map(entry -> obj("identity", f(entry, "identity"),
                        "definition", f(entry, "definition"))).toList()),
                "composition", composition);
    }

    private static WireValue failure(GenerationFailure failure) {
        return switch (failure.kind()) {
            case UNSUPPORTED_SCHEMA -> obj("kind", str("schema"), "actual", str(failure.condition()));
            case ENTRYPOINTS_EMPTY -> obj("kind", str("entrypoints_empty"));
            case ENTRYPOINT_IDENTITY_EMPTY -> obj("kind", str("entrypoint_identity_empty"));
            case ENTRYPOINT_DUPLICATE -> obj("kind", str("entrypoint_duplicate"),
                    "identity", f(failure.observed(), "identity"));
            case ENTRYPOINT_UNRESOLVED -> obj("kind", str("entrypoint_unresolved"),
                    "identity", f(failure.observed(), "identity"), "definition", f(failure.observed(), "definition"));
            case LIBRARY -> obj("kind", str("declaration"), "reason", str(failure.condition().toLowerCase(java.util.Locale.ROOT)));
            case CERTIFICATE -> certificate(failure.mismatch());
            case COMPOSITION_INPUT -> obj("kind", str("composition"),
                    "reason", str(lowerCamel(failure.compositionInputFailure())));
            case COMPOSITION -> obj("kind", str("composition"), "reason", str(lowerCamel(failure.witnessFailure())));
            case EXCHANGE_JSON -> decode("exchange_json");
            case EXCHANGE_WIRE -> decode("exchange." + wireTag(failure));
            case WIRE -> decode(lowerCamel(failure.wireFailure()));
            case COMPOSITION_WIRE -> obj("kind", str("composition"), "reason", str(lowerCamel(failure.wireFailure())));
            case GENERATION -> decode(failure.condition());
        };
    }

    /**
     * Lists the conditions that carry a ConditionFailure in the order decode, source, coordinate, observations,
     * residual. The digest condition has no ConditionFailure and is reported through the digests field.
     */
    private static WireValue certificate(Mismatch<String> mismatch) {
        List<WireValue> failures = new ArrayList<>();
        var checks = mismatch.checks();
        if (checks.decode() instanceof Prerequisite.Failed<ConditionFailure<String>, DigestChecks>(var failed)) {
            failures.add(conditionFailure(failed));
        }
        if (checks.source() instanceof Prerequisite.Failed<ConditionFailure<String>, SourceChecks<String>>(var failed)) {
            failures.add(conditionFailure(failed));
        } else if (checks.source() instanceof Prerequisite.Established<ConditionFailure<String>, SourceChecks<String>>(
                var children)) {
            for (CheckResult<ConditionFailure<String>> result
                    : List.of(children.coordinate(), children.observations(), children.residual())) {
                if (result instanceof CheckResult.Mismatched<ConditionFailure<String>>(var failed)) {
                    failures.add(conditionFailure(failed));
                }
            }
        }
        List<Object> conditionFields = new ArrayList<>();
        for (Condition condition : Condition.values()) {
            conditionFields.add(conditionName(condition));
            conditionFields.add(str(state(mismatch.statusAt(condition))));
        }
        Origin origin = mismatch.origin();
        return obj("kind", str("certificate"),
                "conditions", obj(conditionFields.toArray()),
                "failures", arr(failures),
                "digests", digests(checks.decode()),
                "origin", obj("rule_revision", str(origin.ruleRevision()),
                        "source_identity", str(origin.sourceIdentity()), "source_revision", str(origin.sourceRevision())),
                "provenance", str(mismatch.provenance()));
    }

    /** Names the result of each projection when the decode condition holds, or null otherwise. */
    private static WireValue digests(Prerequisite<ConditionFailure<String>, DigestChecks> decode) {
        if (!(decode instanceof Prerequisite.Established<ConditionFailure<String>, DigestChecks>(var digests))) {
            return NIL;
        }
        List<Object> fields = new ArrayList<>();
        for (var entry : digests.results().entrySet()) {
            fields.add(entry.getKey());
            fields.add(str(label(entry.getValue())));
        }
        return obj(fields.toArray());
    }

    private static String label(ProjectionResult result) {
        return switch (result) {
            case ProjectionResult.Matched matched -> "matched";
            case ProjectionResult.CertificateOnly certificateOnly -> "certificateOnly";
            case ProjectionResult.RecomputedOnly recomputedOnly -> "recomputedOnly";
            case ProjectionResult.Different different -> "different";
        };
    }

    private static WireValue conditionFailure(ConditionFailure<String> failure) {
        return obj("condition", str(conditionName(failure.condition())), "operation", str(failure.operation()));
    }

    private static String state(Status<String> status) {
        if (status instanceof Status.Matched<String>) return "Matched";
        if (status instanceof Status.Mismatched<String>) return "Mismatched";
        if (status instanceof Status.UncheckedByDecode<String>) return "UncheckedByDecode";
        return "UncheckedBySource";
    }

    private static String conditionName(Condition condition) {
        return condition.name().toLowerCase(Locale.ROOT);
    }

    /** Converts a Java variant name to the lowerCamel constructor name used by the Lean definitions. */
    private static String lowerCamel(Object failure) {
        if (failure instanceof InclusionWitnessFailure) return "inclusion";
        if (failure instanceof InitialMembershipFailure) return "initialMembership";
        String name = failure.getClass().getSimpleName();
        return Character.toLowerCase(name.charAt(0)) + name.substring(1);
    }
}
