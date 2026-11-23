// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.file;

/** Closed sum of a held digest and an unobserved-contents payload. */
public sealed interface DigestLookup permits DigestLookup.Found, DigestLookup.Unobserved {

    record Found(ContentDigest digest) implements DigestLookup {
    }

    record Unobserved(UnobservedContents unobservedContents) implements DigestLookup {
    }
}
