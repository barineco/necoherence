// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.file;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;

import java.math.BigInteger;
import java.util.List;
import necoherence.core.Basis;
import necoherence.core.Command;
import necoherence.core.Nat;
import necoherence.core.Never;
import necoherence.core.Outcome;
import necoherence.core.ResourceId;
import necoherence.core.UnknownResource;
import necoherence.core.World;
import org.junit.jupiter.api.Test;

/** Tests translating lean/Necoherence/FileEffect.lean. */
final class FileEffectTest {

    private static NormalizedPath path(boolean root, String... segments) {
        return new NormalizedPath(root, List.of(segments));
    }

    private static ResourceId fileResource(String name) {
        return new ResourceId("file", name);
    }

    private static necoherence.core.Revision revision(long value) {
        return ((necoherence.core.Validation.Valid<necoherence.core.Revision>)
                necoherence.core.Revision.of(BigInteger.valueOf(value))).value();
    }

    @Test
    void normalizePathDropsEmptyAndDotSegments() {
        NormalizedPath normalized = FileEffect.normalizePath(true, List.of("a", "", ".", "b"));
        assertEquals(List.of("a", "b"), normalized.segments());
    }

    @Test
    void normalizePathPopsOnDotDot() {
        NormalizedPath normalized = FileEffect.normalizePath(true, List.of("a", "b", ".."));
        assertEquals(List.of("a"), normalized.segments());
    }

    @Test
    void normalizePathDropsDotDotWithNothingToPop() {
        NormalizedPath normalized = FileEffect.normalizePath(true, List.of("..", "a"));
        assertEquals(List.of("a"), normalized.segments());
    }

    @Test
    void normalizePathIsIdempotent() {
        List<String> raw = List.of("a", "..", "b", ".", "c");
        NormalizedPath once = FileEffect.normalizePath(true, raw);
        NormalizedPath twice = FileEffect.normalizePath(true, once.segments());
        assertEquals(once, twice);
    }

    @Test
    void trackAlwaysApplies() {
        FileEffect.TrackReq req = new FileEffect.TrackReq(path(true, "a"), new World(List.of()), Nat.zero());
        Outcome<FileEffect.Tracked, Never, Never, Never> result = FileEffect.track(req);
        assertInstanceOf(Outcome.Applied.class, result);
    }

    @Test
    void trackOfAnAlreadyTrackedPathReturnsItsCurrentRevisionUnchanged() {
        ResourceId resource = fileResource("/a");
        World world = new World(List.of(new World.Entry(resource, revision(3))));
        FileEffect.TrackReq req = new FileEffect.TrackReq(path(true, "a"), world, Nat.zero());
        Outcome.Applied<FileEffect.Tracked, Never, Never, Never> result =
                assertInstanceOf(Outcome.Applied.class, FileEffect.track(req));
        assertEquals("3", result.value().observation().payload().value().toString());
        assertEquals(world, result.value().world());
    }

    @Test
    void readOfAnAbsentPathIsRejected() {
        FileEffect.ReadReq req = new FileEffect.ReadReq(
                path(true, "missing"), new World(List.of()), new Digests(List.of()),
                new ExternalFileState(List.of(), List.of(), List.of()), Nat.zero());
        Outcome<FileEffect.Read, UnknownResource, Never, ReadFailure> result = FileEffect.read(req);
        assertInstanceOf(Outcome.Rejected.class, result);
    }

    @Test
    void readOfAPresentPathSucceedsAndRecordsTheDigest() {
        NormalizedPath p = path(true, "a");
        FileRecord record = new FileRecord(new ContentDigest("d1"), List.of((byte) 1, (byte) 2));
        ExternalFileState state = new ExternalFileState(
                List.of(new ExternalFileState.PathRecord(p, record)), List.of(), List.of());
        FileEffect.ReadReq req = new FileEffect.ReadReq(p, new World(List.of()), new Digests(List.of()), state, Nat.zero());
        Outcome.Applied<FileEffect.Read, UnknownResource, Never, ReadFailure> result =
                assertInstanceOf(Outcome.Applied.class, FileEffect.read(req));
        assertEquals(record.bytes(), result.value().observation().payload().contents());
        assertEquals(1, result.value().digests().entries().size());
    }

    @Test
    void readOfADeclaredReadFailureBoundaryFails() {
        NormalizedPath p = path(true, "a");
        ExternalFileState state = new ExternalFileState(List.of(), List.of(p), List.of());
        FileEffect.ReadReq req = new FileEffect.ReadReq(p, new World(List.of()), new Digests(List.of()), state, Nat.zero());
        Outcome<FileEffect.Read, UnknownResource, Never, ReadFailure> result = FileEffect.read(req);
        assertInstanceOf(Outcome.BoundaryFailed.class, result);
    }

    private static ExternalFileState trackedState(NormalizedPath p, ContentDigest digest, List<Byte> bytes) {
        return new ExternalFileState(List.of(new ExternalFileState.PathRecord(p, new FileRecord(digest, bytes))), List.of(), List.of());
    }

    @Test
    void replaceSucceedsAndSetsNewRecord() {
        NormalizedPath p = path(true, "a");
        ResourceId resource = fileResource("/a");
        ContentDigest expected = new ContentDigest("d1");
        World world = new World(List.of(new World.Entry(resource, revision(2))));
        Digests digests = new Digests(List.of(new Digests.Entry(resource, expected)));
        ExternalFileState state = trackedState(p, expected, List.of((byte) 1));

        ReplaceContents intent = new ReplaceContents(List.of((byte) 9), new ContentDigest("d2"));
        Command<ReplaceContents> command = new Command<>(intent, new Basis(resource, revision(2)));
        FileEffect.ReplaceReq req = new FileEffect.ReplaceReq(command, p, world, digests, state, Nat.one());

        Outcome.Applied<FileEffect.Replaced, ReplaceRejection, ReplaceConflict, WriteFailure> result =
                assertInstanceOf(Outcome.Applied.class, FileEffect.replace(req));
        assertEquals(new ContentDigest("d2"), result.value().state().lookup(p).orElseThrow().digest());
        assertEquals(List.of((byte) 9), result.value().state().lookup(p).orElseThrow().bytes());
    }

    @Test
    void replaceRejectsOnResourcePathMismatch() {
        NormalizedPath p = path(true, "a");
        ResourceId wrongResource = fileResource("/b");
        ReplaceContents intent = new ReplaceContents(List.of((byte) 1), new ContentDigest("d2"));
        Command<ReplaceContents> command =
                new Command<>(intent, new Basis(wrongResource, revision(0)));
        FileEffect.ReplaceReq req = new FileEffect.ReplaceReq(
                command, p, new World(List.of()), new Digests(List.of()),
                new ExternalFileState(List.of(), List.of(), List.of()), Nat.zero());
        Outcome<FileEffect.Replaced, ReplaceRejection, ReplaceConflict, WriteFailure> result = FileEffect.replace(req);
        Outcome.Rejected<FileEffect.Replaced, ReplaceRejection, ReplaceConflict, WriteFailure> rejected =
                assertInstanceOf(Outcome.Rejected.class, result);
        assertInstanceOf(ReplaceRejection.ResourcePathMismatchRejection.class, rejected.reason());
    }

    @Test
    void replaceRejectsUnobservedContents() {
        NormalizedPath p = path(true, "a");
        ResourceId resource = fileResource("/a");
        ReplaceContents intent = new ReplaceContents(List.of((byte) 1), new ContentDigest("d2"));
        Command<ReplaceContents> command =
                new Command<>(intent, new Basis(resource, revision(0)));
        FileEffect.ReplaceReq req = new FileEffect.ReplaceReq(
                command, p, new World(List.of()), new Digests(List.of()),
                new ExternalFileState(List.of(), List.of(), List.of()), Nat.zero());
        Outcome<FileEffect.Replaced, ReplaceRejection, ReplaceConflict, WriteFailure> result = FileEffect.replace(req);
        Outcome.Rejected<FileEffect.Replaced, ReplaceRejection, ReplaceConflict, WriteFailure> rejected =
                assertInstanceOf(Outcome.Rejected.class, result);
        assertInstanceOf(ReplaceRejection.UnobservedContentsRejection.class, rejected.reason());
    }

    @Test
    void replaceConflictsOnStaleRevision() {
        NormalizedPath p = path(true, "a");
        ResourceId resource = fileResource("/a");
        ContentDigest expected = new ContentDigest("d1");
        World world = new World(List.of(new World.Entry(resource, revision(5))));
        Digests digests = new Digests(List.of(new Digests.Entry(resource, expected)));
        ExternalFileState state = trackedState(p, expected, List.of((byte) 1));

        ReplaceContents intent = new ReplaceContents(List.of((byte) 9), new ContentDigest("d2"));
        Command<ReplaceContents> command =
                new Command<>(intent, new Basis(resource, revision(4)));
        FileEffect.ReplaceReq req = new FileEffect.ReplaceReq(command, p, world, digests, state, Nat.zero());

        Outcome<FileEffect.Replaced, ReplaceRejection, ReplaceConflict, WriteFailure> result = FileEffect.replace(req);
        Outcome.Conflicted<FileEffect.Replaced, ReplaceRejection, ReplaceConflict, WriteFailure> conflicted =
                assertInstanceOf(Outcome.Conflicted.class, result);
        assertInstanceOf(ReplaceConflict.StaleBasisConflict.class, conflicted.conflict());
    }

    @Test
    void replaceConflictsOnExternalMutation() {
        NormalizedPath p = path(true, "a");
        ResourceId resource = fileResource("/a");
        ContentDigest expected = new ContentDigest("d1");
        World world = new World(List.of(new World.Entry(resource, revision(2))));
        Digests digests = new Digests(List.of(new Digests.Entry(resource, expected)));
        // The external state's current digest differs from the last recorded digest.
        ExternalFileState state = trackedState(p, new ContentDigest("mutated"), List.of((byte) 7));

        ReplaceContents intent = new ReplaceContents(List.of((byte) 9), new ContentDigest("d2"));
        Command<ReplaceContents> command =
                new Command<>(intent, new Basis(resource, revision(2)));
        FileEffect.ReplaceReq req = new FileEffect.ReplaceReq(command, p, world, digests, state, Nat.zero());

        Outcome<FileEffect.Replaced, ReplaceRejection, ReplaceConflict, WriteFailure> result = FileEffect.replace(req);
        Outcome.Conflicted<FileEffect.Replaced, ReplaceRejection, ReplaceConflict, WriteFailure> conflicted =
                assertInstanceOf(Outcome.Conflicted.class, result);
        assertInstanceOf(ReplaceConflict.ExternalMutationConflict.class, conflicted.conflict());
    }

    @Test
    void replaceBoundaryFailsOnDeclaredWriteFailure() {
        NormalizedPath p = path(true, "a");
        ResourceId resource = fileResource("/a");
        ContentDigest expected = new ContentDigest("d1");
        World world = new World(List.of(new World.Entry(resource, revision(2))));
        Digests digests = new Digests(List.of(new Digests.Entry(resource, expected)));
        ExternalFileState state = new ExternalFileState(
                List.of(new ExternalFileState.PathRecord(p, new FileRecord(expected, List.of((byte) 1)))),
                List.of(), List.of(p));

        ReplaceContents intent = new ReplaceContents(List.of((byte) 9), new ContentDigest("d2"));
        Command<ReplaceContents> command =
                new Command<>(intent, new Basis(resource, revision(2)));
        FileEffect.ReplaceReq req = new FileEffect.ReplaceReq(command, p, world, digests, state, Nat.zero());

        Outcome<FileEffect.Replaced, ReplaceRejection, ReplaceConflict, WriteFailure> result = FileEffect.replace(req);
        assertInstanceOf(Outcome.BoundaryFailed.class, result);
    }
}
