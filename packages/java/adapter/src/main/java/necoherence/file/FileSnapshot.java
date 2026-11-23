// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.file;

import java.util.List;

/** Contents of a file as observed at some basis. */
public record FileSnapshot(NormalizedPath path, List<Byte> contents, ContentDigest digest) {

    public FileSnapshot {
        contents = List.copyOf(contents);
    }
}
