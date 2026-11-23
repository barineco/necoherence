// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.function.Predicate;

/** The declared family of quantities that a composition goal makes observable in an execution result: the success outputs, the failure embeddings, the final resource requirement, the suspension and network instruction sequence, the residual set, the typed execution failure kinds and the result provenance. */
public final class GoalObservations {
    private static final List<String> EXECUTION_FAILURES = List.of("argumentCoverage", "invalidOutcome",
            "invalidPlan", "missingArgument", "missingProvider", "missingValue", "network", "networkTerminal",
            "provider", "providerCoverage", "providerEffect", "resource", "value");

    private final WireValue value;
    private final String canonical;

    GoalObservations(WireValue value) {
        this.value = TypeSignatures.ordered(value);
        this.canonical = encodeWire(this.value);
    }

    /** Builds the observations from the {@code goal} of a composition problem. */
    public static GoalObservations of(WireValue composition) {
        WireValue goal = member(member(composition, "problem"), "goal");
        return new GoalObservations(obj(
                "outputs", rows(member(goal, "outputs"), List.of("id", "contract")),
                "failures", rows(member(goal, "failures"), List.of("id", "contract", "final_resources")),
                "final_resources", member(goal, "final_resources"),
                "effects", arr(List.of(str("network_instruction"), str("pending"))),
                "residuals", str("residual_set"),
                "execution_failures", arr(EXECUTION_FAILURES.stream().map(SemanticValues::str).toList()),
                "provenance", str("certificate_basis")));
    }

    /** Builds the observations from the outputs and the failure embeddings that the return nodes of the composition derivation return. They equal the goal observations exactly when the return nodes cover the declarations of the goal. */
    public static GoalObservations ofPlan(WireValue composition) {
        WireValue goal = member(member(composition, "problem"), "goal");
        List<WireValue> returns = new ArrayList<>();
        planReturns(member(member(member(composition, "derivation"), "plan"), "root"), returns);
        List<List<String>> successes = new ArrayList<>();
        List<String> embeddings = new ArrayList<>();
        for (WireValue value : returns) {
            if (text(member(value, "tag")).equals("Success")) {
                List<String> ports = new ArrayList<>();
                if (member(value, "value") instanceof ArrayValue pairs) for (WireValue pair : pairs.items())
                    if (pair instanceof ArrayValue items && !items.items().isEmpty() && items.items().get(0) instanceof StringValue port) ports.add(port.value());
                successes.add(ports);
            } else if (member(member(value, "fields"), "embedding") instanceof StringValue embedding) embeddings.add(embedding.value());
        }
        WireValue outputs = member(goal, "outputs"), failures = member(goal, "failures");
        List<String> outputIds = rowIds(outputs), failureIds = rowIds(failures);
        Set<String> undeclaredPorts = new LinkedHashSet<>();
        for (List<String> ports : successes) for (String port : ports) if (!outputIds.contains(port)) undeclaredPorts.add(port);
        Set<String> undeclaredEmbeddings = new LinkedHashSet<>();
        for (String embedding : embeddings) if (!failureIds.contains(embedding)) undeclaredEmbeddings.add(embedding);
        return new GoalObservations(obj(
                "outputs", keptRows(outputs, List.of("id", "contract"),
                        id -> !successes.isEmpty() && successes.stream().allMatch(ports -> ports.contains(id)), undeclaredPorts),
                "failures", keptRows(failures, List.of("id", "contract", "final_resources"), embeddings::contains, undeclaredEmbeddings),
                "final_resources", member(goal, "final_resources"),
                "effects", arr(List.of(str("network_instruction"), str("pending"))),
                "residuals", str("residual_set"),
                "execution_failures", arr(EXECUTION_FAILURES.stream().map(SemanticValues::str).toList()),
                "provenance", str("certificate_basis")));
    }

    private static void planReturns(WireValue tree, List<WireValue> returns) {
        WireValue node = member(tree, "node");
        String tag = text(member(node, "tag"));
        if (tag.equals("Return")) { returns.add(member(node, "value")); return; }
        if (!tag.equals("Invoke") && !tag.equals("Guard")) return;
        if (member(member(node, "fields"), "arms") instanceof ArrayValue arms) for (WireValue arm : arms.items())
            if (arm instanceof ArrayValue pair && pair.items().size() == 2) planReturns(pair.items().get(1), returns);
    }

    private static String text(WireValue value) { return value instanceof StringValue string ? string.value() : ""; }

    private static List<String> rowIds(WireValue rows) {
        List<String> ids = new ArrayList<>();
        if (rows instanceof ArrayValue array) for (WireValue item : array.items())
            if (member(item, "id") instanceof StringValue id) ids.add(id.value());
        return ids;
    }

    private static WireValue keptRows(WireValue value, List<String> keys, Predicate<String> kept, Set<String> extra) {
        List<WireValue> declared = new ArrayList<>();
        if (value instanceof ArrayValue array) for (WireValue item : array.items())
            if (kept.test(text(member(item, "id")))) declared.add(item);
        List<WireValue> result = new ArrayList<>(a(rows(arr(declared), keys)));
        for (String id : extra) result.add(new ObjectValue(keys.stream()
                .map(key -> new Member(key, key.equals("id") ? str(id) : NIL)).toList()));
        return arr(result);
    }

    /** @return the observations as a wire value with members in code point order */
    public WireValue value() { return value; }

    private static WireValue member(WireValue value, String key) {
        if (!(value instanceof ObjectValue object)) return NIL;
        WireValue result = object.get(key);
        return result == null ? NIL : result;
    }

    private static WireValue rows(WireValue value, List<String> keys) {
        if (!(value instanceof ArrayValue array)) return arr(List.of());
        return arr(array.items().stream().map(item -> (WireValue) new ObjectValue(
                keys.stream().map(key -> new Member(key, member(item, key))).toList())).toList());
    }

    @Override public boolean equals(Object other) {
        return other instanceof GoalObservations observations && canonical.equals(observations.canonical);
    }

    @Override public int hashCode() { return canonical.hashCode(); }

    @Override public String toString() { return canonical; }
}
