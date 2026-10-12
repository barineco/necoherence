// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.file;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

/**
 * The external world {@code track}, {@code read}, and {@code replace} observe and update.
 * {@code files} holds present paths and their records; {@code readFailures} and {@code writeFailures}
 * are paths an adapter has declared unreadable or unwritable for the next call.
 */
public record ExternalFileState(
        List<PathRecord> files, List<NormalizedPath> readFailures, List<NormalizedPath> writeFailures) {

    public ExternalFileState {
        files = List.copyOf(files);
        readFailures = List.copyOf(readFailures);
        writeFailures = List.copyOf(writeFailures);
    }

    public record PathRecord(NormalizedPath path, FileRecord record) {
    }

    /** Current record at {@code path}, or empty when the path is absent. */
    public Optional<FileRecord> lookup(NormalizedPath path) {
        for (PathRecord entry : files) {
            if (entry.path().equals(path)) {
                return Optional.of(entry.record());
            }
        }
        return Optional.empty();
    }

    /** Replace {@code path}'s record, adding it when absent. A single total step: never partial. */
    public ExternalFileState setFile(NormalizedPath path, FileRecord record) {
        List<PathRecord> rebuilt = new ArrayList<>(files.size() + 1);
        boolean found = false;
        for (PathRecord entry : files) {
            if (entry.path().equals(path)) {
                rebuilt.add(new PathRecord(path, record));
                found = true;
            } else {
                rebuilt.add(entry);
            }
        }
        if (!found) {
            rebuilt.add(new PathRecord(path, record));
        }
        return new ExternalFileState(rebuilt, readFailures, writeFailures);
    }
}
