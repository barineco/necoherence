// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

package admissiononce;

public final class AdmissionCounter {
    private AdmissionCounter() {}

    private static final long[] CALLS = new long[AdmissionAgent.COMPONENTS.size()];
    private static long jumps;

    public static void call(int component) { CALLS[component]++; }

    public static void jump() { jumps++; }

    public static long[] calls() { return CALLS.clone(); }

    public static long jumps() { return jumps; }
}
