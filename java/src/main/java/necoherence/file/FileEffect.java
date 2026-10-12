// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.file;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import necoherence.core.Basis;
import necoherence.core.Command;
import necoherence.core.Core;
import necoherence.core.Lookup;
import necoherence.core.Nat;
import necoherence.core.Never;
import necoherence.core.Observation;
import necoherence.core.Outcome;
import necoherence.core.ResourceId;
import necoherence.core.Revision;
import necoherence.core.StaleBasis;
import necoherence.core.UnknownResource;
import necoherence.core.World;

/** File effect as a pure state transition over an external file world. */
public final class FileEffect {

    private FileEffect() {
    }

    private static final String FILE_KIND = "file";

    private static List<String> normalizeSegments(List<String> raw) {
        List<String> acc = new ArrayList<>();
        for (String segment : raw) {
            if (segment.isEmpty() || segment.equals(".")) {
                continue;
            }
            if (segment.equals("..")) {
                if (!acc.isEmpty()) {
                    acc.remove(acc.size() - 1);
                }
                continue;
            }
            acc.add(segment);
        }
        return acc;
    }

    /** Normalize a raw root flag and segment list into a {@link NormalizedPath}. */
    public static NormalizedPath normalizePath(boolean root, List<String> raw) {
        return new NormalizedPath(root, normalizeSegments(raw));
    }

    private static ResourceId pathResource(NormalizedPath path) {
        String body = String.join("/", path.segments());
        return new ResourceId(FILE_KIND, path.root() ? "/" + body : body);
    }

    public static DigestLookup lookupDigest(Digests digests, ResourceId resource) {
        for (Digests.Entry entry : digests.entries()) {
            if (entry.resource().equals(resource)) {
                return new DigestLookup.Found(entry.digest());
            }
        }
        return new DigestLookup.Unobserved(new UnobservedContents(resource));
    }

    public static Digests setDigest(Digests digests, ResourceId resource, ContentDigest digest) {
        List<Digests.Entry> rebuilt = new ArrayList<>(digests.entries().size() + 1);
        boolean found = false;
        for (Digests.Entry entry : digests.entries()) {
            if (entry.resource().equals(resource)) {
                rebuilt.add(new Digests.Entry(resource, digest));
                found = true;
            } else {
                rebuilt.add(entry);
            }
        }
        if (!found) {
            rebuilt.add(new Digests.Entry(resource, digest));
        }
        return new Digests(rebuilt);
    }

    private record RegisteredResource(Observation<Revision> observation, World world) {
    }

    private static RegisteredResource registerResource(World world, ResourceId resource, Nat observedAt) {
        Lookup lookup = Core.lookup(world, resource);
        if (lookup instanceof Lookup.Unknown) {
            Revision zero = Revision.zero();
            List<World.Entry> entries = new ArrayList<>(world.entries());
            entries.add(new World.Entry(resource, zero));
            World nextWorld = new World(entries);
            return new RegisteredResource(new Observation<>(zero, new Basis(resource, zero), observedAt), nextWorld);
        }
        Revision revision = ((Lookup.Found) lookup).revision();
        return new RegisteredResource(new Observation<>(revision, new Basis(resource, revision), observedAt), world);
    }

    /** Request to register a path as an owned resource without reading it. */
    public record TrackReq(NormalizedPath path, World world, Nat observedAt) {
    }

    /** Product of a successful {@code track}. */
    public record Tracked(Observation<Revision> observation, World world) {
    }

    /** {@code track} never fails: registering a revision touches no file contents. */
    public static Outcome<Tracked, Never, Never, Never> track(TrackReq req) {
        ResourceId resource = pathResource(req.path());
        RegisteredResource registered = registerResource(req.world(), resource, req.observedAt());
        return new Outcome.Applied<>(new Tracked(registered.observation(), registered.world()));
    }

    /** Request to read a path's contents from the external state. */
    public record ReadReq(NormalizedPath path, World world, Digests digests, ExternalFileState state, Nat observedAt) {
    }

    /** Product of a successful {@code read}. */
    public record Read(Observation<FileSnapshot> observation, World world, Digests digests) {
    }

    public static Outcome<Read, UnknownResource, Never, ReadFailure> read(ReadReq req) {
        if (req.state().readFailures().contains(req.path())) {
            return new Outcome.BoundaryFailed<>(new ReadFailure(req.path()));
        }
        ResourceId resource = pathResource(req.path());
        Optional<FileRecord> record = req.state().lookup(req.path());
        if (record.isEmpty()) {
            return new Outcome.Rejected<>(new UnknownResource(resource));
        }
        Digests digests = setDigest(req.digests(), resource, record.get().digest());
        RegisteredResource registered = registerResource(req.world(), resource, req.observedAt());
        FileSnapshot snapshot = new FileSnapshot(req.path(), record.get().bytes(), record.get().digest());
        Observation<FileSnapshot> observation = new Observation<>(
                snapshot, registered.observation().basis(), registered.observation().observedAt());
        return new Outcome.Applied<>(new Read(observation, registered.world(), digests));
    }

    /** Request to replace a file's contents as a compare-and-replace atomic write. */
    public record ReplaceReq(
            Command<ReplaceContents> command,
            NormalizedPath path,
            World world,
            Digests digests,
            ExternalFileState state,
            Nat observedAt) {
    }

    /** Product of a successful {@code replace}. */
    public record Replaced(Observation<FileSnapshot> observation, World world, Digests digests, ExternalFileState state) {
    }

    public static Outcome<Replaced, ReplaceRejection, ReplaceConflict, WriteFailure> replace(ReplaceReq req) {
        ResourceId resource = req.command().basis().resource();
        if (!resource.equals(pathResource(req.path()))) {
            return new Outcome.Rejected<>(new ReplaceRejection.ResourcePathMismatchRejection(
                    new ResourcePathMismatch(resource, req.path())));
        }
        DigestLookup digestLookup = lookupDigest(req.digests(), resource);
        if (digestLookup instanceof DigestLookup.Unobserved unobserved) {
            return new Outcome.Rejected<>(new ReplaceRejection.UnobservedContentsRejection(unobserved.unobservedContents()));
        }
        ContentDigest expected = ((DigestLookup.Found) digestLookup).digest();
        Outcome<Core.AppliedValue<ReplaceContents>, UnknownResource, StaleBasis, Never> applyOutcome =
                Core.apply(req.world(), req.command());
        if (applyOutcome instanceof Outcome.Rejected<Core.AppliedValue<ReplaceContents>, UnknownResource, StaleBasis, Never> rejected) {
            return new Outcome.Rejected<>(new ReplaceRejection.UnknownResourceRejection(rejected.reason()));
        }
        if (applyOutcome instanceof Outcome.Conflicted<Core.AppliedValue<ReplaceContents>, UnknownResource, StaleBasis, Never> conflicted) {
            return new Outcome.Conflicted<>(new ReplaceConflict.StaleBasisConflict(conflicted.conflict()));
        }
        World worldAfterBasis =
                ((Outcome.Applied<Core.AppliedValue<ReplaceContents>, UnknownResource, StaleBasis, Never>) applyOutcome)
                        .value().world();
        Optional<FileRecord> current = req.state().lookup(req.path());
        if (current.isEmpty()) {
            return new Outcome.Rejected<>(new ReplaceRejection.UnknownResourceRejection(new UnknownResource(resource)));
        }
        if (!current.get().digest().equals(expected)) {
            return new Outcome.Conflicted<>(
                    new ReplaceConflict.ExternalMutationConflict(new ExternalMutation(expected, current.get().digest())));
        }
        if (req.state().writeFailures().contains(req.path())) {
            return new Outcome.BoundaryFailed<>(new WriteFailure(req.path()));
        }
        List<Byte> newContents = req.command().intent().newContents();
        ContentDigest newDigest = req.command().intent().newDigest();
        FileRecord record = new FileRecord(newDigest, newContents);
        ExternalFileState newState = req.state().setFile(req.path(), record);
        Digests newDigests = setDigest(req.digests(), resource, newDigest);
        RegisteredResource registered = registerResource(worldAfterBasis, resource, req.observedAt());
        FileSnapshot snapshot = new FileSnapshot(req.path(), newContents, newDigest);
        Observation<FileSnapshot> observation = new Observation<>(
                snapshot, registered.observation().basis(), registered.observation().observedAt());
        return new Outcome.Applied<>(new Replaced(observation, registered.world(), newDigests, newState));
    }
}
