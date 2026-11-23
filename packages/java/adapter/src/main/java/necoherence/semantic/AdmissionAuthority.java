// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

/** Proof that a composition is built by the admission entry of this package. Only this package obtains it. */
public final class AdmissionAuthority {
    static final AdmissionAuthority INSTANCE = new AdmissionAuthority();

    private AdmissionAuthority() {}
}
