// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import java.lang.management.ManagementFactory;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import necoherence.core.Basis;
import necoherence.core.Command;
import necoherence.core.Core;
import necoherence.core.Nat;
import necoherence.core.ResourceId;
import necoherence.core.Revision;
import necoherence.core.World;
import necoherence.admission.Admission;
import necoherence.admission.AdmissionProvenance;
import necoherence.admission.AdmissionSignal;
import necoherence.admission.CapacityObservation;
import necoherence.admission.DynamicAdmissionInput;
import necoherence.admission.DynamicAdmissionResult;
import necoherence.admission.DynamicAdmissionState;
import necoherence.admission.EnvironmentSpecification;
import necoherence.file.ContentDigest;
import necoherence.file.Digests;
import necoherence.file.ExternalFileState;
import necoherence.file.FileEffect;
import necoherence.file.FileRecord;
import necoherence.file.NormalizedPath;
import necoherence.file.ReplaceContents;
import necoherence.network.NetworkEffect;
import necoherence.network.NetworkEffect.AttemptIdentity;
import necoherence.network.NetworkEffect.AttemptInput;
import necoherence.network.NetworkEffect.NetworkState;
import necoherence.network.NetworkEffect.PreparedAttempt;
import necoherence.progression.Accepted;
import necoherence.progression.AdapterResult;
import necoherence.progression.AdapterSignal;
import necoherence.progression.ConfiguredSafetyLimit;
import necoherence.progression.CostSelection;
import necoherence.progression.EvidenceVersion;
import necoherence.progression.ExecutionHandle;
import necoherence.progression.MeaningPermission;
import necoherence.progression.Progression;
import necoherence.progression.RequestEffectClass;
import necoherence.progression.RequestFootprint;
import necoherence.progression.RequestIdentity;
import necoherence.progression.RequestInput;
import necoherence.progression.RequestPolicy;
import necoherence.progression.RequestProgressionSnapshot;
import necoherence.progression.ResourceBudget;
import necoherence.progression.ResourceDemand;
import necoherence.progression.Running;
import necoherence.progression.StartDecisionResult;
import necoherence.progression.StartObservationResult;
import necoherence.progression.Starting;
import necoherence.progression.SubmitResult;
import necoherence.composition.SemanticComposition.SlotContract;
import necoherence.composition.SemanticComposition.TypeRef;
import necoherence.reconcile.Reconcile;
import necoherence.semantic.ExactJson;
import necoherence.semantic.SemanticTypes;
import necoherence.semantic.SemanticValidation;
import necoherence.semantic.SemanticValues;
import necoherence.store.Stores;

/**
 * Cost guest for the Java state families.
 *
 * <p>usage: {@code JavaCost <operation> <n> [<jump limit> <byte limit>]}. It builds a state that holds n entries in the
 * shape that maximizes the cost of the operation, runs k operations on the evolving state (k = n, or 10 for
 * an operation that reads a whole input), and prints the jump
 * instructions executed by {@code necoherence/} classes (counted by the agent) and the bytes allocated by
 * the thread. Run with {@code -Xint -javaagent:<agent>}.
 */
public final class JavaCost {
    private JavaCost() {
    }

    private static final class Holder {
        Object state;
        Object[] first;
        Object[] second;
        Object[] third;
    }

    private interface Scenario {
        Holder build(int n);

        void step(Holder holder, int index);

        default int steps(int n) {
            return n;
        }
    }

    private static Nat n(long value) {
        return Nat.fromLong(value);
    }

    private static ResourceId rid(int i) {
        return new ResourceId("k", "r" + i);
    }

    private static Revision rev(long i) {
        return Revision.fromNat(n(i));
    }

    private static RequestIdentity pid(long i) {
        return new RequestIdentity("k", "p", n(i));
    }

    private static final ResourceDemand DEMAND = new ResourceDemand(n(1), n(1), n(1));

    private static ResourceBudget budget() {
        long large = 1_000_000_000L;
        return new ResourceBudget(new ConfiguredSafetyLimit("p", n(large)),
                new ConfiguredSafetyLimit("i", n(large)), new ConfiguredSafetyLimit("c", n(large)));
    }

    private static RequestInput requestInput(long i) {
        RequestIdentity identity = pid(i);
        return new RequestInput(identity, new RequestFootprint(List.of(), List.of(), RequestEffectClass.PURE), DEMAND,
                new MeaningPermission.Permitted(identity, List.of()));
    }

    private static CostSelection executeNow(RequestIdentity identity) {
        return new CostSelection.ExecuteNow(identity, new EvidenceVersion("e", "d", "a"), Nat.zero());
    }

    private static RequestProgressionSnapshot snapshotOf(SubmitResult result) {
        return ((SubmitResult.SubmitAccepted) result).snapshot();
    }

    private static RequestProgressionSnapshot pendingSnapshot(RequestPolicy policy, int n) {
        RequestProgressionSnapshot snapshot = Progression.empty(policy, budget());
        for (int i = 0; i < n; i++) {
            snapshot = snapshotOf(Progression.submit(snapshot, requestInput(i)));
        }
        return snapshot;
    }

    private static RequestProgressionSnapshot preparingSnapshot(int n) {
        RequestProgressionSnapshot snapshot = pendingSnapshot(RequestPolicy.ALL_EXECUTE, n);
        for (int i = 0; i < n; i++) {
            RequestIdentity identity = pid(i);
            snapshot = ((StartDecisionResult.Execute) Progression.decideStart(
                    snapshot, new Accepted(identity), executeNow(identity))).snapshot();
        }
        return snapshot;
    }

    private static RequestProgressionSnapshot publishingSnapshot(int n) {
        RequestProgressionSnapshot snapshot = preparingSnapshot(n);
        for (int i = 0; i < n; i++) {
            RequestIdentity identity = pid(i);
            snapshot = ((StartObservationResult.Publishing) Progression.applyStartObservation(snapshot,
                    new Starting(identity, null), started(identity))).snapshot();
        }
        return snapshot;
    }

    private static AdapterResult<AdapterSignal<String>> started(RequestIdentity identity) {
        return new AdapterResult.AppliedSignal<>(new AdapterSignal.Started<>(identity, new ExecutionHandle("h")));
    }

    private static AdapterResult<AdapterSignal<String>> completed(RequestIdentity identity) {
        return new AdapterResult.AppliedSignal<>(new AdapterSignal.Completed<>(identity, new ExecutionHandle("h"), "v"));
    }

    private static NetworkEffect.HostConfiguration configuration() {
        return new NetworkEffect.HostConfiguration(n(32), n(32),
                Optional.of(new NetworkEffect.CancellationCapability(new NetworkEffect.OpaqueEvidence("c"))),
                Optional.empty());
    }

    private static AttemptIdentity attempt(int i) {
        return new AttemptIdentity(pid(i), n(0));
    }

    private static AttemptInput attemptInput(int i) {
        return new AttemptInput(attempt(i),
                new NetworkEffect.HttpWireInstruction("GET", "http://127.0.0.1/", List.of(), necoherence.network.ByteString.empty()),
                Optional.empty(), configuration());
    }

    private static NetworkEffect.EffectStatus unknown() {
        return new NetworkEffect.EffectStatus.Unknown(NetworkEffect.UnknownEffectReason.NoResponse);
    }

    private static NetworkEffect.AdapterObservation response(int i) {
        return new NetworkEffect.AdapterObservation.ResponseObservation(attempt(i), new ExecutionHandle("h" + i),
                new NetworkEffect.SourceSequence.None(), new NetworkEffect.RawHttpResponse(200, List.of(), necoherence.network.ByteString.empty()),
                NetworkEffect.HeaderProvenance.WireObserved, unknown());
    }

    /** Network state with n attempts, advanced through {@code stage} operations (1 prepared ... 4 settled). */
    private static Holder networkHolder(int n, int stage) {
        Holder holder = new Holder();
        NetworkState state = NetworkState.empty();
        holder.first = new Object[n];
        for (int i = 0; i < n; i++) {
            NetworkEffect.PrepareStep.Prepared prepared =
                    (NetworkEffect.PrepareStep.Prepared) NetworkEffect.prepare(state, attemptInput(i));
            state = prepared.state();
            holder.first[i] = prepared.prepared();
        }
        for (int i = 0; i < n && stage >= 2; i++) {
            state = ((NetworkEffect.CommandStep.CommandReady<NetworkEffect.SendCommand>) NetworkEffect.sendCommand(
                    state, (PreparedAttempt) holder.first[i])).state();
        }
        holder.second = new Object[n];
        for (int i = 0; i < n && stage >= 3; i++) {
            NetworkEffect.NetworkStep.Started step = (NetworkEffect.NetworkStep.Started) NetworkEffect.observeStart(
                    state, (PreparedAttempt) holder.first[i],
                    new NetworkEffect.StartObservation.Started(attempt(i), new ExecutionHandle("h" + i)));
            state = step.state();
            holder.second[i] = step.started();
        }
        for (int i = 0; i < n && stage >= 4; i++) {
            state = ((NetworkEffect.NetworkStep.Terminal) NetworkEffect.observe(state,
                    new NetworkEffect.HostObservation.Delivered(n(0), response(i)))).state();
        }
        holder.state = state;
        return holder;
    }

    private static NormalizedPath filePath(int i) {
        return FileEffect.normalizePath(true, List.of("f" + i));
    }

    private static ResourceId fileResource(int i) {
        return new ResourceId("file", "/f" + i);
    }

    /** n tracked files: the state, the world and the digests all hold the n files; the last file is the target. */
    private static Holder fileHolder(int n) {
        Holder h = new Holder();
        List<ExternalFileState.PathRecord> files = new ArrayList<>();
        List<World.Entry> worldEntries = new ArrayList<>();
        List<Digests.Entry> digestEntries = new ArrayList<>();
        ContentDigest initial = new ContentDigest("d0");
        for (int i = 0; i < n; i++) {
            files.add(new ExternalFileState.PathRecord(filePath(i), new FileRecord(initial, List.of((byte) 0))));
            worldEntries.add(new World.Entry(fileResource(i), rev(0)));
            digestEntries.add(new Digests.Entry(fileResource(i), initial));
        }
        h.first = new Object[] {ExternalFileState.of(files, List.of(), List.of()), new World(worldEntries),
                Digests.of(digestEntries)};
        h.second = new Object[n];
        for (int i = 0; i < n; i++) {
            h.second[i] = new Command<>(new ReplaceContents(List.of((byte) 1), new ContentDigest("d" + (i + 1))),
                    new Basis(fileResource(n - 1), rev(i)));
        }
        h.state = new Object[] {h.first[1], h.first[2], h.first[0]};
        return h;
    }

    private static AdmissionProvenance provenanceOf(int futureUses, int base) {
        List<necoherence.progression.RequestIdentity> identities = new ArrayList<>();
        for (int i = 0; i < futureUses; i++) {
            identities.add(pid(base + i));
        }
        return new AdmissionProvenance(identities, List.<AdmissionSignal>of());
    }

    private static DynamicAdmissionInput admissionInput(
            DynamicAdmissionState state, long identity, Optional<CostSelection> start) {
        return new DynamicAdmissionInput(state, requestInput(identity), new EnvironmentSpecification(n(1)),
                new CapacityObservation(budget(), n(0)), n(0), start);
    }

    private static DynamicAdmissionState admitted(DynamicAdmissionInput input) {
        var applied = (necoherence.core.Outcome.Applied<DynamicAdmissionResult, ?, ?, ?>)
                Admission.admitDynamicRequest(input);
        var decision = applied.value().admissionDecision();
        return decision instanceof necoherence.admission.AdmissionDecision.Submitted submitted
                ? submitted.state()
                : ((necoherence.admission.AdmissionDecision.Started) decision).state();
    }

    private static RequestProgressionSnapshot cancelledSnapshot(int n) {
        RequestProgressionSnapshot snapshot = pendingSnapshot(RequestPolicy.FIFO, n);
        for (int i = 0; i < n; i++) {
            snapshot = ((necoherence.progression.CancelDecisionResult.Cancelled) Progression.decideCancel(
                    snapshot, pid(i))).snapshot();
        }
        return snapshot;
    }

    private static Scenario scenario(String name) {
        return switch (name) {
            case "core_lookup" -> new Scenario() {
                public Holder build(int n) {
                    Holder h = new Holder();
                    h.state = world(n);
                    h.first = new Object[] {rid(n - 1)};
                    return h;
                }

                public void step(Holder h, int i) {
                    sink = Core.lookup((World) h.state, (ResourceId) h.first[0]);
                }
            };
            case "core_bump" -> new Scenario() {
                public Holder build(int n) {
                    Holder h = new Holder();
                    h.state = world(n);
                    h.first = new Object[] {rid(n - 1)};
                    return h;
                }

                public void step(Holder h, int i) {
                    h.state = Core.bump((World) h.state, (ResourceId) h.first[0]);
                }
            };
            case "core_apply", "core_apply_conflicted", "core_apply_unknown" -> new Scenario() {
                public Holder build(int n) {
                    Holder h = new Holder();
                    h.state = world(n);
                    h.first = new Object[n];
                    for (int i = 0; i < n; i++) {
                        h.first[i] = switch (name) {
                            case "core_apply" -> new Command<>("x", new Basis(rid(n - 1), rev(n + i)));
                            case "core_apply_conflicted" -> new Command<>("x", new Basis(rid(n - 1), rev(0)));
                            default -> new Command<>("x", new Basis(rid(n), rev(1)));
                        };
                    }
                    return h;
                }

                @SuppressWarnings("unchecked")
                public void step(Holder h, int i) {
                    var outcome = Core.apply((World) h.state, (Command<String>) h.first[i]);
                    if (outcome instanceof necoherence.core.Outcome.Applied<Core.AppliedValue<String>, ?, ?, ?> applied) {
                        h.state = applied.value().world();
                    }
                }
            };
            case "store_observe", "store_apply" -> new Scenario() {
                public Holder build(int n) {
                    Holder h = new Holder();
                    List<Stores.Store.Entry<String>> entries = new ArrayList<>();
                    for (int i = 0; i < n; i++) {
                        entries.add(new Stores.Store.Entry<>(rid(i), rev(i + 1), "p"));
                    }
                    h.state = new Stores.Store<>(entries);
                    h.first = new Object[n];
                    for (int i = 0; i < n; i++) {
                        h.first[i] = new Command<>("x", new Basis(rid(n - 1), rev(n + i)));
                    }
                    return h;
                }

                @SuppressWarnings("unchecked")
                public void step(Holder h, int i) {
                    Stores.Store<String> store = (Stores.Store<String>) h.state;
                    if (name.equals("store_observe")) {
                        sink = Stores.observe(store, ((Command<String>) h.first[0]).basis().resource());
                        return;
                    }
                    var outcome = Stores.apply(store, (Command<String>) h.first[i]);
                    if (outcome instanceof necoherence.core.Outcome.Applied<Stores.AppliedStore<String>, ?, ?, ?> applied) {
                        h.state = applied.value().store();
                    }
                }
            };
            case "reconcile_linear" -> new Scenario() {
                public Holder build(int n) {
                    Holder h = new Holder();
                    h.state = world(n);
                    List<Optional<Basis>> bases = new ArrayList<>();
                    for (int i = 0; i < n; i++) {
                        bases.add(Optional.of(new Basis(rid(i), rev(i))));
                    }
                    h.first = new Object[] {bases};
                    return h;
                }

                @SuppressWarnings("unchecked")
                public void step(Holder h, int i) {
                    sink = Reconcile.reconcile((List<Optional<Basis>>) h.first[0], (World) h.state, Nat.zero());
                }

                public int steps(int n) {
                    return 10;
                }
            };
            case "rp_submit_fifo", "rp_submit_latest_wins" -> new Scenario() {
                public Holder build(int n) {
                    Holder h = new Holder();
                    h.state = pendingSnapshot(name.equals("rp_submit_fifo") ? RequestPolicy.FIFO : RequestPolicy.LATEST_WINS, n);
                    h.first = new Object[n];
                    for (int i = 0; i < n; i++) {
                        h.first[i] = requestInput(n + i);
                    }
                    return h;
                }

                public void step(Holder h, int i) {
                    h.state = snapshotOf(Progression.submit((RequestProgressionSnapshot) h.state, (RequestInput) h.first[i]));
                }
            };
            case "rp_decide_start", "rp_decide_start_blocked" -> new Scenario() {
                public Holder build(int n) {
                    Holder h = new Holder();
                    h.state = pendingSnapshot(RequestPolicy.FIFO, n);
                    h.first = new Object[n];
                    h.second = new Object[n];
                    for (int i = 0; i < n; i++) {
                        int target = name.equals("rp_decide_start") ? i : n - 1;
                        h.first[i] = new Accepted(pid(target));
                        h.second[i] = executeNow(pid(target));
                    }
                    return h;
                }

                public void step(Holder h, int i) {
                    var result = Progression.decideStart(
                            (RequestProgressionSnapshot) h.state, (Accepted) h.first[i], (CostSelection) h.second[i]);
                    if (result instanceof StartDecisionResult.Execute execute) {
                        h.state = execute.snapshot();
                    }
                }
            };
            case "rp_apply_start_observation" -> new Scenario() {
                public Holder build(int n) {
                    Holder h = new Holder();
                    h.state = preparingSnapshot(n);
                    h.first = new Object[n];
                    h.second = new Object[n];
                    for (int i = 0; i < n; i++) {
                        h.first[i] = new Starting(pid(i), null);
                        h.second[i] = started(pid(i));
                    }
                    return h;
                }

                @SuppressWarnings("unchecked")
                public void step(Holder h, int i) {
                    var result = Progression.applyStartObservation((RequestProgressionSnapshot) h.state,
                            (Starting) h.first[i], (AdapterResult<AdapterSignal<String>>) h.second[i]);
                    if (result instanceof StartObservationResult.Publishing publishing) {
                        h.state = publishing.snapshot();
                    }
                }
            };
            case "rp_apply_completion_observation" -> new Scenario() {
                public Holder build(int n) {
                    Holder h = new Holder();
                    h.state = publishingSnapshot(n);
                    h.first = new Object[n];
                    h.second = new Object[n];
                    for (int i = 0; i < n; i++) {
                        h.first[i] = new Running(pid(i), new ExecutionHandle("h"));
                        h.second[i] = completed(pid(i));
                    }
                    return h;
                }

                @SuppressWarnings("unchecked")
                public void step(Holder h, int i) {
                    var result = Progression.applyCompletionObservation((RequestProgressionSnapshot) h.state,
                            (Running) h.first[i], (AdapterResult<AdapterSignal<String>>) h.second[i]);
                    if (result instanceof necoherence.progression.CompletionObservationResult.Applied<String> applied) {
                        h.state = applied.snapshot();
                    }
                }
            };
            case "rp_decide_cancel" -> new Scenario() {
                public Holder build(int n) {
                    Holder h = new Holder();
                    h.state = pendingSnapshot(RequestPolicy.ALL_EXECUTE, n);
                    return h;
                }

                public void step(Holder h, int i) {
                    var result = Progression.decideCancel((RequestProgressionSnapshot) h.state, pid(i));
                    if (result instanceof necoherence.progression.CancelDecisionResult.Cancelled cancelled) {
                        h.state = cancelled.snapshot();
                    }
                }
            };
            case "rp_derive_pending", "rp_derive_in_flight", "rp_derive_concurrent" -> new Scenario() {
                public Holder build(int n) {
                    Holder h = new Holder();
                    h.state = pendingSnapshot(RequestPolicy.ALL_EXECUTE, n);
                    return h;
                }

                public void step(Holder h, int i) {
                    RequestProgressionSnapshot snapshot = (RequestProgressionSnapshot) h.state;
                    sink = switch (name) {
                        case "rp_derive_pending" -> Progression.derivePending(snapshot);
                        case "rp_derive_in_flight" -> Progression.deriveInFlight(snapshot);
                        default -> Progression.deriveConcurrent(snapshot);
                    };
                }
            };
            case "ne_prepare" -> new Scenario() {
                public Holder build(int n) {
                    Holder h = networkHolder(n, 1);
                    h.third = new Object[n];
                    for (int i = 0; i < n; i++) {
                        h.third[i] = attemptInput(n + i);
                    }
                    return h;
                }

                public void step(Holder h, int i) {
                    h.state = ((NetworkEffect.PrepareStep.Prepared) NetworkEffect.prepare(
                            (NetworkState) h.state, (AttemptInput) h.third[i])).state();
                }
            };
            case "ne_send_command" -> new Scenario() {
                public Holder build(int n) {
                    return networkHolder(n, 1);
                }

                @SuppressWarnings("unchecked")
                public void step(Holder h, int i) {
                    h.state = ((NetworkEffect.CommandStep.CommandReady<NetworkEffect.SendCommand>) NetworkEffect.sendCommand(
                            (NetworkState) h.state, (PreparedAttempt) h.first[i])).state();
                }
            };
            case "ne_observe_start" -> new Scenario() {
                public Holder build(int n) {
                    return networkHolder(n, 2);
                }

                public void step(Holder h, int i) {
                    h.state = ((NetworkEffect.NetworkStep.Started) NetworkEffect.observeStart((NetworkState) h.state,
                            (PreparedAttempt) h.first[i],
                            new NetworkEffect.StartObservation.Started(attempt(i), new ExecutionHandle("h" + i)))).state();
                }
            };
            case "ne_cancel_command" -> new Scenario() {
                public Holder build(int n) {
                    return networkHolder(n, 3);
                }

                public void step(Holder h, int i) {
                    sink = NetworkEffect.cancelCommand(
                            (NetworkState) h.state, (NetworkEffect.StartedAttempt) h.second[i]);
                }
            };
            case "ne_observe_pending" -> new Scenario() {
                public Holder build(int n) {
                    return networkHolder(n, 3);
                }

                public void step(Holder h, int i) {
                    sink = NetworkEffect.observe((NetworkState) h.state,
                            new NetworkEffect.HostObservation.Pending(attempt(i), new ExecutionHandle("h" + i)));
                }
            };
            case "ne_observe_delivered" -> new Scenario() {
                public Holder build(int n) {
                    return networkHolder(n, 3);
                }

                public void step(Holder h, int i) {
                    h.state = ((NetworkEffect.NetworkStep.Terminal) NetworkEffect.observe((NetworkState) h.state,
                            new NetworkEffect.HostObservation.Delivered(n(0), response(i)))).state();
                }
            };
            case "ne_observe_late" -> new Scenario() {
                public Holder build(int n) {
                    return networkHolder(n, 4);
                }

                public void step(Holder h, int i) {
                    h.state = ((NetworkEffect.NetworkStep.Late) NetworkEffect.observe((NetworkState) h.state,
                            new NetworkEffect.HostObservation.Delivered(n(1), response(i)))).state();
                }
            };
            case "ne_annotate_effect" -> new Scenario() {
                public Holder build(int n) {
                    return networkHolder(n, 4);
                }

                public void step(Holder h, int i) {
                    var witness = new NetworkEffect.EffectWitness(
                            attempt(i), NetworkEffect.EffectWitnessSource.Protocol, new NetworkEffect.OpaqueEvidence("w"));
                    h.state = ((NetworkEffect.StateStep.Applied) NetworkEffect.annotateEffect((NetworkState) h.state,
                            new NetworkEffect.EffectObservation(
                                    attempt(i), new NetworkEffect.EffectStatus.EffectOccurred(witness)))).state();
                }
            };
            case "ne_retry" -> new Scenario() {
                public Holder build(int n) {
                    return networkHolder(n, 4);
                }

                public void step(Holder h, int i) {
                    AttemptIdentity next = new AttemptIdentity(pid(i), n(1));
                    var authorization = new NetworkEffect.RetryAuthorization(
                            pid(i), attempt(i), next, new NetworkEffect.OpaqueEvidence("r"));
                    h.state = ((NetworkEffect.PrepareStep.Prepared) NetworkEffect.retry((NetworkState) h.state,
                            new NetworkEffect.RetryRequest(new NetworkEffect.RetryPermission.RetryAllowed(authorization),
                                    attemptInput(i).instruction(), Optional.empty(), configuration()))).state();
                }
            };
            case "ne_read_network_state" -> new Scenario() {
                public Holder build(int n) {
                    return networkHolder(n, 4);
                }

                public void step(Holder h, int i) {
                    sink = NetworkEffect.readNetworkState((NetworkState) h.state);
                }
            };
            case "file_effect_read" -> new Scenario() {
                public Holder build(int n) {
                    return fileHolder(n);
                }

                public void step(Holder h, int i) {
                    Object[] held = (Object[]) h.state;
                    var outcome = FileEffect.read(new FileEffect.ReadReq(filePath(((Object[]) h.second).length - 1),
                            (World) held[0], (Digests) held[1], (ExternalFileState) held[2], n(i)));
                    var applied = (necoherence.core.Outcome.Applied<FileEffect.Read, ?, ?, ?>) outcome;
                    h.state = new Object[] {applied.value().world(), applied.value().digests(), held[2]};
                }
            };
            case "file_effect_replace" -> new Scenario() {
                public Holder build(int n) {
                    return fileHolder(n);
                }

                @SuppressWarnings("unchecked")
                public void step(Holder h, int i) {
                    Object[] held = (Object[]) h.state;
                    var outcome = FileEffect.replace(new FileEffect.ReplaceReq((Command<ReplaceContents>) h.second[i],
                            filePath(h.second.length - 1), (World) held[0], (Digests) held[1],
                            (ExternalFileState) held[2], n(i)));
                    var applied = (necoherence.core.Outcome.Applied<FileEffect.Replaced, ?, ?, ?>) outcome;
                    h.state = new Object[] {applied.value().world(), applied.value().digests(), applied.value().state()};
                }
            };
            case "file_effect_track" -> new Scenario() {
                public Holder build(int n) {
                    return fileHolder(n);
                }

                public void step(Holder h, int i) {
                    Object[] held = (Object[]) h.state;
                    var outcome = FileEffect.track(
                            new FileEffect.TrackReq(filePath(h.second.length + i), (World) held[0], n(i)));
                    var applied = (necoherence.core.Outcome.Applied<FileEffect.Tracked, ?, ?, ?>) outcome;
                    h.state = new Object[] {applied.value().world(), held[1], held[2]};
                }
            };
            case "da_admit_submitted", "da_admit_executed" -> new Scenario() {
                public Holder build(int n) {
                    Holder h = new Holder();
                    boolean executed = name.equals("da_admit_executed");
                    h.state = DynamicAdmissionState.of(
                            pendingSnapshot(executed ? RequestPolicy.ALL_EXECUTE : RequestPolicy.FIFO, n), budget(),
                            provenanceOf(0, 0));
                    h.first = new Object[n];
                    for (int i = 0; i < n; i++) {
                        h.first[i] = executed ? Optional.of(executeNow(pid(n + i))) : Optional.empty();
                    }
                    return h;
                }

                @SuppressWarnings("unchecked")
                public void step(Holder h, int i) {
                    int n = h.first.length;
                    h.state = admitted(admissionInput(
                            (DynamicAdmissionState) h.state, n + i, (Optional<CostSelection>) h.first[i]));
                }
            };
            case "sv_validate_value" -> new Scenario() {
                public Holder build(int n) {
                    Holder h = new Holder();
                    h.state = new SemanticValues.Context(semanticGraph(n));
                    h.first = new Object[] {semanticRef("box")};
                    h.second = new Object[] {semanticBox()};
                    return h;
                }

                public void step(Holder h, int i) {
                    sink = SemanticValidation.validateValue((SemanticValues.Context) h.state, (TypeRef) h.first[0],
                            (ExactJson.JsonValue) h.second[0], Optional.empty());
                }

                @Override
                public int steps(int n) {
                    return 100;
                }
            };
            case "da_elide_admission_provenance" -> new Scenario() {
                public Holder build(int n) {
                    Holder h = new Holder();
                    h.state = DynamicAdmissionState.of(cancelledSnapshot(n), budget(), provenanceOf(n, 2 * n));
                    return h;
                }

                public void step(Holder h, int i) {
                    var outcome = Admission.elideAdmissionProvenance((DynamicAdmissionState) h.state, pid(i));
                    h.state = ((necoherence.core.Outcome.Applied<Admission.ElisionApplied, ?, ?, ?>) outcome)
                            .value().state();
                }
            };
            default -> throw new IllegalArgumentException(name);
        };
    }

    private static final SemanticTypes.SourceRef SEMANTIC_SOURCE =
            new SemanticTypes.SourceRef("r", "1", "p", "0".repeat(64), "d", Optional.empty());

    private static TypeRef semanticRef(String name) {
        return new TypeRef(SEMANTIC_SOURCE, name, List.of());
    }

    private static SemanticTypes.TypeNode semanticNode(String name, SemanticTypes.TypeShape shape) {
        return new SemanticTypes.TypeNode(semanticRef(name), shape, Optional.empty(), List.of(), List.of());
    }

    private static SemanticTypes.IntegerSpec anyInteger() {
        return new SemanticTypes.IntegerSpec(Optional.empty(), Optional.empty(), Optional.empty(), Optional.empty(),
                Optional.empty(), Optional.empty());
    }

    private static SemanticTypes.FieldSpec semanticField(String name, String type) {
        return new SemanticTypes.FieldSpec(name, new SlotContract(semanticRef(type), true, false),
                new SemanticTypes.OccurrenceRef(SEMANTIC_SOURCE, List.of()));
    }

    /** A graph of n nodes: the product box over a text and an integer, and n - 3 unrelated integers. */
    private static SemanticTypes.SemanticGraph semanticGraph(int n) {
        SemanticTypes.ProfileRef reference = new SemanticTypes.ProfileRef("profile", "1", "0".repeat(64));
        SemanticTypes.VersionedSemanticProfile profile = new SemanticTypes.VersionedSemanticProfile(reference, List.of(),
                List.of(new SemanticTypes.IntegerDomainBinding("numbers", reference, new SemanticTypes.UnboundedDomain(),
                        List.of(SemanticTypes.IntegerForm.NUMBER))),
                "numbers", new SemanticTypes.NumberModel(false), Optional.empty(), List.of(), Optional.empty(), List.of(),
                Optional.empty());
        List<SemanticTypes.TypeNode> nodes = new ArrayList<>();
        nodes.add(semanticNode("text", new SemanticTypes.StringShape(new SemanticTypes.StringSpec(
                Optional.of(new SemanticTypes.InlineFormat(new SemanticTypes.LiteralRule("a"))), List.of(), Optional.empty(),
                Optional.empty(), Optional.empty(), List.of(), Optional.empty()))));
        nodes.add(semanticNode("number", new SemanticTypes.IntegerShape(anyInteger())));
        nodes.add(semanticNode("box", new SemanticTypes.ProductShape(new SemanticTypes.ProductSpec(
                List.of(semanticField("text", "text"), semanticField("number", "number")), new SemanticTypes.RejectExtras()))));
        for (int i = 3; i < n; i++) {
            nodes.add(semanticNode("unrelated" + i, new SemanticTypes.IntegerShape(anyInteger())));
        }
        return new SemanticTypes.SemanticGraph(profile, nodes, List.of());
    }

    private static ExactJson.JsonValue semanticBox() {
        return new ExactJson.JsonObj(List.of(new ExactJson.JsonMember("text", new ExactJson.JsonStr("a")),
                new ExactJson.JsonMember("number", new ExactJson.JsonNum(java.math.BigInteger.valueOf(7)))));
    }

    private static World world(int n) {
        List<World.Entry> entries = new ArrayList<>();
        for (int i = 0; i < n; i++) {
            entries.add(new World.Entry(rid(i), rev(i + 1)));
        }
        return new World(entries);
    }

    private static Object sink;

    private interface Body {
        void run() throws Exception;
    }

    private static final class Prepared {
        private static final SemanticTypes.ProfileRef PROFILE = new SemanticTypes.ProfileRef("profile", "1", "0".repeat(64));
        private static final SemanticTypes.SourceRef SOURCE =
                new SemanticTypes.SourceRef("r", "1", "p", "0".repeat(64), "d", Optional.empty());
        private final StringBuilder phases = new StringBuilder();
        private final List<Object> retained = new ArrayList<>();

        private static TypeRef ref(String name) {
            return new TypeRef(SOURCE, name, List.of());
        }

        private static SemanticTypes.TypeNode node(String name, SemanticTypes.TypeShape shape) {
            return new SemanticTypes.TypeNode(ref(name), shape, Optional.empty(), List.of(), List.of());
        }

        private static SemanticTypes.GraphemeRules graphemeRules() {
            SemanticValues.WireValue reference = SemanticValues.obj("identity", SemanticValues.str("profile"),
                    "revision", SemanticValues.str("4"), "content_digest", SemanticValues.str("a".repeat(64)));
            SemanticValues.WireValue rules = SemanticValues.obj("reference", reference,
                    "component", SemanticValues.obj("unicode_version", SemanticValues.str("16"),
                            "uax29_revision", SemanticValues.str("45"), "cluster_profile", SemanticValues.str("extended")),
                    "table_sha256", SemanticValues.str("b".repeat(64)), "sources", SemanticValues.arr(List.of()),
                    "properties", SemanticValues.arr(List.of(
                            SemanticValues.obj("first", SemanticValues.str("0"), "last", SemanticValues.str("1"),
                                    "property", SemanticValues.variant("Other")),
                            SemanticValues.obj("first", SemanticValues.str("769"), "last", SemanticValues.str("769"),
                                    "property", SemanticValues.variant("Extend")))),
                    "extended_pictographic", SemanticValues.arr(List.of()), "indic_conjunct", SemanticValues.arr(List.of()));
            return necoherence.semantic.GraphemeWire.decode(rules, "$");
        }

        private static SemanticTypes.VersionedSemanticProfile profile() {
            SemanticTypes.FormatRule word = new SemanticTypes.BoundedRule(SemanticTypes.StringLengthUnit.GRAPHEMES,
                    java.math.BigInteger.valueOf(3), new SemanticTypes.TextRule());
            SemanticTypes.SealedForm form = new SemanticTypes.SealedForm("s", List.of(new SemanticTypes.SealedField("name", true,
                    new SemanticTypes.StringLeaf(new SemanticTypes.StringSpec(Optional.empty(), List.of(), Optional.empty(),
                            Optional.of("x"), Optional.empty(), List.of(), Optional.empty())))), SemanticTypes.SealedExtras.REJECT);
            return new SemanticTypes.VersionedSemanticProfile(PROFILE, List.of(), List.of(
                    new SemanticTypes.IntegerDomainBinding("numbers", PROFILE, new SemanticTypes.UnboundedDomain(),
                            List.of(SemanticTypes.IntegerForm.NUMBER))),
                    "numbers", new SemanticTypes.NumberModel(false), Optional.of(graphemeRules()),
                    List.of(new SemanticTypes.FormatBinding("word", PROFILE, word)), Optional.empty(), List.of(),
                    Optional.of(new SemanticTypes.TagModel("$type", Optional.empty(), List.of(form))));
        }

        private static List<String> codes() {
            List<String> codes = new ArrayList<>();
            for (int index = 0; index < 20; index++) {
                codes.add("c" + index);
            }
            return codes;
        }

        private static List<java.math.BigInteger> numbers() {
            List<java.math.BigInteger> numbers = new ArrayList<>();
            for (int index = 0; index < 20; index++) {
                numbers.add(java.math.BigInteger.valueOf(index));
            }
            return numbers;
        }

        private static SemanticTypes.FieldSpec field(String name, String type) {
            return new SemanticTypes.FieldSpec(name, new SlotContract(ref(type), true, false),
                    new SemanticTypes.OccurrenceRef(SOURCE, List.of()));
        }

        private static SemanticTypes.StringSpec plainString(Optional<SemanticTypes.FormatUse> format,
                List<SemanticTypes.LengthBound> lengths, Optional<List<String>> values) {
            return new SemanticTypes.StringSpec(format, lengths, Optional.empty(), Optional.empty(), values, List.of(),
                    Optional.empty());
        }

        private static SemanticTypes.SemanticGraph graph(int filler, boolean unresolvedFormat) {
            List<SemanticTypes.TypeNode> nodes = new ArrayList<>();
            nodes.add(node("name", new SemanticTypes.StringShape(plainString(Optional.of(new SemanticTypes.InlineFormat(
                    new SemanticTypes.BoundedRule(SemanticTypes.StringLengthUnit.GRAPHEMES, java.math.BigInteger.valueOf(2),
                            new SemanticTypes.TextRule()))),
                    List.of(new SemanticTypes.LengthBound(SemanticTypes.StringLengthUnit.GRAPHEMES, Optional.empty(),
                            Optional.of(java.math.BigInteger.valueOf(2)))), Optional.empty()))));
            nodes.add(node("code", new SemanticTypes.StringShape(plainString(Optional.of(new SemanticTypes.NamedFormat("word")),
                    List.of(), Optional.of(codes())))));
            nodes.add(node("number", new SemanticTypes.IntegerShape(new SemanticTypes.IntegerSpec(Optional.empty(),
                    Optional.empty(), Optional.empty(), Optional.empty(), Optional.of(numbers()), Optional.empty()))));
            nodes.add(node("box", new SemanticTypes.ProductShape(new SemanticTypes.ProductSpec(
                    List.of(field("name", "name"), field("code", "code"), field("number", "number")),
                    new SemanticTypes.RejectExtras()))));
            nodes.add(node("sealed", new SemanticTypes.SealedShape("s", List.of())));
            nodes.add(node("bad", new SemanticTypes.StringShape(plainString(Optional.of(new SemanticTypes.NamedFormat("missing")),
                    List.of(), Optional.empty()))));
            if (unresolvedFormat) {
                nodes.add(node("holder", new SemanticTypes.ProductShape(new SemanticTypes.ProductSpec(
                        List.of(field("bad", "bad")), new SemanticTypes.RejectExtras()))));
            }
            for (int index = 0; index < filler; index++) {
                nodes.add(node("filler" + index, new SemanticTypes.IntegerShape(anyInteger())));
            }
            return new SemanticTypes.SemanticGraph(profile(), nodes, List.of());
        }

        private static ExactJson.JsonValue box(String name, String code, long number) {
            return new ExactJson.JsonObj(List.of(new ExactJson.JsonMember("name", new ExactJson.JsonStr(name)),
                    new ExactJson.JsonMember("code", new ExactJson.JsonStr(code)),
                    new ExactJson.JsonMember("number", new ExactJson.JsonNum(java.math.BigInteger.valueOf(number)))));
        }

        private static SemanticValues.Context bytesContext() {
            SemanticTypes.VersionedSemanticProfile base = profile();
            SemanticTypes.VersionedSemanticProfile withBytes = new SemanticTypes.VersionedSemanticProfile(base.reference(),
                    base.sourceRefs(), base.integerDomains(), base.defaultIntegerDomain(), base.numbers(), base.graphemeRules(),
                    base.formatBindings(), Optional.of(new SemanticTypes.BytesPolicy(PROFILE, true,
                            SemanticTypes.BytesAlphabet.STANDARD, true, Optional.empty())), base.wrappers(), base.tag());
            List<SemanticTypes.TypeNode> nodes = List.of(
                    node("blob", new SemanticTypes.BytesShape(new SemanticTypes.LengthSpec(Optional.empty(), Optional.empty()))),
                    node("body", new SemanticTypes.RawBodyShape("text")),
                    node("pack", new SemanticTypes.ArrayShape(new SemanticTypes.ArraySpec(
                            new SemanticTypes.ElementContract(ref("blob"), false), Optional.empty(), Optional.empty()))));
            return new SemanticValues.Context(new SemanticTypes.SemanticGraph(withBytes, nodes, List.of()));
        }

        private static SemanticValues.WireValue reference(String name) {
            return necoherence.semantic.SemanticGraphWire.typeRefWire(ref(name));
        }

        private static boolean accepts(SemanticValues.Context context, ExactJson.JsonValue value) {
            return SemanticValidation.validateValue(context, ref("box"), value, Optional.empty())
                    instanceof SemanticValidation.Ok<?>;
        }

        private static void require(boolean condition, String message) {
            if (!condition) {
                throw new IllegalStateException(message);
            }
        }

        private void phase(String label, boolean build, long validations, long meaning, Body body) throws Exception {
            long[] before = ncohagent.Counter.methods.clone();
            body.run();
            long[] after = ncohagent.Counter.methods.clone();
            StringBuilder counts = new StringBuilder();
            for (int index = 0; index < after.length; index++) {
                counts.append(index == 0 ? "" : ",").append('"').append(ncohagent.Counter.names[index]).append("\":")
                        .append(after[index] - before[index]);
            }
            phases.append(phases.length() == 0 ? "" : ",").append("{\"label\":\"").append(label).append("\",\"build\":")
                    .append(build).append(",\"validations\":").append(validations).append(",\"meaning\":").append(meaning)
                    .append(",\"counts\":{").append(counts).append("}}");
        }

        String run() throws Exception {
            phase("build", true, 0, 0, () -> retained.add(new SemanticValues.Context(graph(5, false))));
            SemanticValues.Context prepared = new SemanticValues.Context(graph(50, false));
            SlotContract slot = new SlotContract(ref("box"), true, false);
            phase("repeated", false, 40 * 6, 0, () -> {
                for (int round = 0; round < 40; round++) {
                    require(accepts(prepared, box("ab", "c7", 9)), "accepted value was rejected");
                    require(!accepts(prepared, box("ab", "zz", 9)), "rejected value was accepted");
                    require(!accepts(prepared, box("abcd", "c7", 9)), "rejected value was accepted");
                    require(!accepts(prepared, box("ab", "c7", 99)), "rejected value was accepted");
                    require(SemanticValidation.validateSlot(prepared, slot, new SemanticValues.Present<>(box("ab", "c19", 19)))
                            instanceof SemanticValidation.Ok<?>, "accepted slot was rejected");
                    require(SemanticValidation.acceptsSlot(prepared, slot, new SemanticValues.Present<>(box("ab", "c19", 19)))
                            instanceof SemanticTypes.Accepted, "accepted slot was not accepted");
                }
            });
            SemanticValues.Context holders = new SemanticValues.Context(graph(0, true));
            phase("remaining obligations", false, 1, 1, () -> require(SemanticValidation.validateValue(holders, ref("holder"),
                    new ExactJson.JsonObj(List.of()), Optional.empty()) instanceof SemanticValidation.Failed<?>,
                    "reference with remaining obligations did not fail"));
            phase("rejection after obligations", false, 1, 0, () -> require(SemanticValidation.validateValue(holders, ref("box"),
                    box("ab", "zz", 1), Optional.empty()) instanceof SemanticValidation.Failed<?>, "rejected value was accepted"));
            SemanticValues.Context bytes = bytesContext();
            for (String name : List.of("blob", "body")) {
                phase("bytes " + name, false, 1, 0, () -> {
                    SemanticValues.WireValue value = SemanticValues.str("AAEC");
                    necoherence.semantic.Checked checked = bytes.check(reference(name), value);
                    require(bytes.bytes(checked, checked.value()).value().length == 3, "unexpected bytes");
                });
            }
            phase("bytes inside a checked value", false, 1, 0, () -> {
                SemanticValues.ArrayValue pack = new SemanticValues.ArrayValue(
                        List.of(SemanticValues.str("AAEC"), SemanticValues.str("AwQF")));
                necoherence.semantic.Checked checked = bytes.check(reference("pack"), pack);
                for (SemanticValues.WireValue item : pack.items()) {
                    require(bytes.bytes(checked, item).value().length == 3, "unexpected bytes");
                }
            });
            phase("bytes of a checked slot", false, 1, 0, () -> {
                SemanticValues.WireValue value = SemanticValues.str("AAEC");
                necoherence.semantic.Checked checked = bytes.checkSlot(reference("blob"), true, false,
                        new SemanticValues.Present<>(value));
                require(bytes.bytes(checked, value).value().length == 3, "unexpected bytes");
            });
            return "{\"operation\":\"sv_prepared_once\",\"phases\":[" + phases + "]}";
        }
    }

    public static void main(String[] args) throws Exception {
        String name = args[0];
        if (name.equals("sv_prepared_once")) {
            System.out.println(new Prepared().run());
            return;
        }
        int n = Integer.parseInt(args[1]);
        Scenario scenario = scenario(name);
        int warm = Math.min(n, 60);
        Holder warmup = scenario.build(warm);
        for (int i = 0; i < Math.min(scenario.steps(warm), warm); i++) {
            scenario.step(warmup, i);
        }
        Holder holder = scenario.build(n);
        int steps = scenario.steps(n);
        com.sun.management.ThreadMXBean threads =
                (com.sun.management.ThreadMXBean) ManagementFactory.getThreadMXBean();
        long thread = Thread.currentThread().threadId();
        long jumpLimit = args.length > 2 ? Long.parseLong(args[2]) : Long.MAX_VALUE;
        long byteLimit = args.length > 3 ? Long.parseLong(args[3]) : Long.MAX_VALUE;
        long jumps0 = ncohagent.Counter.jumps;
        long bytes0 = threads.getThreadAllocatedBytes(thread);
        for (int i = 0; i < steps; i++) {
            scenario.step(holder, i);
            if (i % 16 == 15 && (ncohagent.Counter.jumps - jumps0 > jumpLimit
                    || threads.getThreadAllocatedBytes(thread) - bytes0 > byteLimit)) {
                System.out.println("{\"operation\":\"" + name + "\",\"n\":" + n + ",\"exceeded\":true}");
                return;
            }
        }
        long bytes1 = threads.getThreadAllocatedBytes(thread);
        long jumps1 = ncohagent.Counter.jumps;
        System.out.println("{\"operation\":\"" + name + "\",\"n\":" + n + ",\"k\":" + steps
                + ",\"jumps\":" + (jumps1 - jumps0) + ",\"bytes\":" + (bytes1 - bytes0) + "}");
    }
}
