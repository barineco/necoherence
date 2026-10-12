// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.file;

import java.util.List;

/** Command intent that requests a file's contents be replaced. */
public record ReplaceContents(List<Byte> newContents, ContentDigest newDigest) {

    public ReplaceContents {
        newContents = List.copyOf(newContents);
    }
}
