// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.file;

import java.util.List;

/** A path already reduced to root flag and non-special segments. */
public record NormalizedPath(boolean root, List<String> segments) {

    public NormalizedPath {
        segments = List.copyOf(segments);
    }
}
