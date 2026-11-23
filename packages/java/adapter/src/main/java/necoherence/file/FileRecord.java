// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.file;

import java.util.List;

/** A file's contents and the digest an external touchpoint computed for them. */
public record FileRecord(ContentDigest digest, List<Byte> bytes) {

    public FileRecord {
        bytes = List.copyOf(bytes);
    }
}
