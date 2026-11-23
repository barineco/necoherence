// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import java.lang.management.ManagementFactory;
import java.util.ArrayList;
import java.util.List;
import necoherence.composition.SemanticExecution;
import necoherence.network.NetworkEffect;

public final class AdmissionProbe {
    private AdmissionProbe() {}

    @FunctionalInterface
    interface Throwing<T> { T get() throws Exception; }

    static <T> T made(Throwing<T> value) {
        try { return value.get(); } catch (Exception failure) { throw new IllegalStateException(failure); }
    }

    static void runOnce(GeneratedProbe.Initialized initialized) {
        var providers = new GeneratedProbe.Providers(input -> new SemanticExecution.ProviderSuccess<>(made(() -> GeneratedProbe.ExecutionOperationOutcomeSuccess.of(true))));
        var result = GeneratedProbe.run(initialized, providers, made(() -> GeneratedProbe.Arguments.of(true)), NetworkEffect.NetworkState.empty());
        if (!(result instanceof GeneratedProbe.Progressed progressed && progressed.progress() instanceof GeneratedProbe.Completed))
            throw new IllegalStateException("run did not complete: " + result);
    }

    public static void main(String[] arguments) throws Exception {
        int runs = Integer.parseInt(arguments[0]);
        var initialized = (GeneratedProbe.Initialized) GeneratedProbe.initialize();
        long[] initialization = arguments[1].equals("count") ? admissiononce.AdmissionCounter.calls() : null;
        runOnce(initialized);
        if (arguments[1].equals("count")) {
            long[] before = admissiononce.AdmissionCounter.calls();
            long jumps = admissiononce.AdmissionCounter.jumps();
            for (int index = 0; index < runs; index++) runOnce(initialized);
            long[] after = admissiononce.AdmissionCounter.calls();
            List<String> fields = new ArrayList<>();
            List<String> initializationFields = new ArrayList<>();
            for (int index = 0; index < after.length; index++) {
                String component = admissiononce.AdmissionAgent.COMPONENTS.get(index);
                fields.add("\"" + component + "\":" + (after[index] - before[index]));
                initializationFields.add("\"" + component + "\":" + initialization[index]);
            }
            System.out.println("{\"calls\":{" + String.join(",", fields) + "},\"init\":{" + String.join(",", initializationFields) + "},\"quantity\":" + (double) (admissiononce.AdmissionCounter.jumps() - jumps) / runs + "}");
            return;
        }
        var threads = (com.sun.management.ThreadMXBean) ManagementFactory.getThreadMXBean();
        long thread = Thread.currentThread().threadId();
        long total = 0;
        for (int index = 0; index < runs; index++) {
            long before = threads.getThreadAllocatedBytes(thread);
            runOnce(initialized);
            total += threads.getThreadAllocatedBytes(thread) - before;
        }
        System.out.println("{\"second\":" + (double) total / runs + "}");
    }
}
