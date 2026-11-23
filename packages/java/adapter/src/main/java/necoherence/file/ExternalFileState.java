// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.file;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import necoherence.persistent.PersistentMap;
import necoherence.persistent.PersistentVector;

/**
 * The external world {@code track}, {@code read}, and {@code replace} observe and update.
 * {@code files} holds present paths and their records; {@code readFailures} and {@code writeFailures}
 * are paths an adapter has declared unreadable or unwritable for the next call.
 *
 * <p>{@link #of} accepts any lists, including a file list that repeats a path. {@link #files()} returns the
 * records in order. Operations find a path through an index of first positions and replace one record
 * without copying the others; a list that repeats a path updates every match.
 */
public final class ExternalFileState {
    private final PersistentVector<PathRecord> files;
    private final PersistentMap<NormalizedPath, Integer> firstPositions;
    private final boolean distinct;
    private final List<NormalizedPath> readFailures;
    private final List<NormalizedPath> writeFailures;
    private final Set<NormalizedPath> readFailureSet;
    private final Set<NormalizedPath> writeFailureSet;

    private ExternalFileState(PersistentVector<PathRecord> files, PersistentMap<NormalizedPath, Integer> firstPositions,
            boolean distinct, List<NormalizedPath> readFailures, List<NormalizedPath> writeFailures,
            Set<NormalizedPath> readFailureSet, Set<NormalizedPath> writeFailureSet) {
        this.files = files;
        this.firstPositions = firstPositions;
        this.distinct = distinct;
        this.readFailures = readFailures;
        this.writeFailures = writeFailures;
        this.readFailureSet = readFailureSet;
        this.writeFailureSet = writeFailureSet;
    }

    public static ExternalFileState of(
            List<PathRecord> files, List<NormalizedPath> readFailures, List<NormalizedPath> writeFailures) {
        PersistentMap<NormalizedPath, Integer> positions = PersistentMap.empty();
        boolean distinct = true;
        for (int position = 0; position < files.size(); position++) {
            NormalizedPath path = files.get(position).path();
            if (positions.containsKey(path)) {
                distinct = false;
            } else {
                positions = positions.put(path, position);
            }
        }
        List<NormalizedPath> reads = List.copyOf(readFailures);
        List<NormalizedPath> writes = List.copyOf(writeFailures);
        return new ExternalFileState(
                PersistentVector.of(files), positions, distinct, reads, writes, Set.copyOf(reads), Set.copyOf(writes));
    }

    /** Return the present paths and their records in order. */
    public List<PathRecord> files() {
        return List.copyOf(files.toList());
    }

    public List<NormalizedPath> readFailures() {
        return readFailures;
    }

    public List<NormalizedPath> writeFailures() {
        return writeFailures;
    }

    boolean readFails(NormalizedPath path) {
        return readFailureSet.contains(path);
    }

    boolean writeFails(NormalizedPath path) {
        return writeFailureSet.contains(path);
    }

    public record PathRecord(NormalizedPath path, FileRecord record) {
    }

    /** Current record at {@code path}, or empty when the path is absent. */
    public Optional<FileRecord> lookup(NormalizedPath path) {
        Integer position = firstPositions.get(path);
        return position == null ? Optional.empty() : Optional.of(files.get(position).record());
    }

    /** Replace {@code path}'s record, adding it when absent. A single total step: never partial. */
    public ExternalFileState setFile(NormalizedPath path, FileRecord record) {
        Integer position = firstPositions.get(path);
        if (position == null) {
            return new ExternalFileState(files.append(new PathRecord(path, record)),
                    firstPositions.put(path, files.size()), distinct, readFailures, writeFailures, readFailureSet,
                    writeFailureSet);
        }
        if (distinct) {
            return new ExternalFileState(files.set(position, new PathRecord(path, record)), firstPositions, true,
                    readFailures, writeFailures, readFailureSet, writeFailureSet);
        }
        PersistentVector<PathRecord> next = files;
        for (int index = 0; index < files.size(); index++) {
            if (files.get(index).path().equals(path)) {
                next = next.set(index, new PathRecord(path, record));
            }
        }
        return new ExternalFileState(
                next, firstPositions, false, readFailures, writeFailures, readFailureSet, writeFailureSet);
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof ExternalFileState state
                && files().equals(state.files())
                && readFailures.equals(state.readFailures)
                && writeFailures.equals(state.writeFailures);
    }

    @Override
    public int hashCode() {
        return java.util.Objects.hash(files(), readFailures, writeFailures);
    }

    @Override
    public String toString() {
        return "ExternalFileState[files=" + files() + ", readFailures=" + readFailures + ", writeFailures="
                + writeFailures + "]";
    }
}
