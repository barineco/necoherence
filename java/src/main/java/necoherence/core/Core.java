// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.core;

import java.util.ArrayList;
import java.util.List;

/**
 * Static free functions over the core vocabulary.
 *
 * <p>Every function here takes the value it operates on as its first
 * argument rather than being a method on that value's type: {@code
 * lookup(world, resource)} and {@code bump(world, resource)}, not {@code
 * world.lookup(resource)}. Receiver syntax is not used, so {@code World}
 * carries no methods of its own beyond the record accessors Java generates.
 */
public final class Core {

    private Core() {
    }

    /**
     * Return the first revision paired with {@code resource}, or its absence.
     *
     * <p>Presence is a two-way fact about the world, not a fallible
     * operation, so absence is reported with the same payload already used
     * elsewhere for an absent resource rather than with a value outside the
     * type.
     */
    public static Lookup lookup(World world, ResourceId resource) {
        for (World.Entry entry : world.entries()) {
            if (entry.resource().equals(resource)) {
                return new Lookup.Found(entry.revision());
            }
        }
        return new Lookup.Unknown(new UnknownResource(resource));
    }

    /** Return a world with the first matching resource's revision incremented. */
    public static World bump(World world, ResourceId resource) {
        List<World.Entry> rebuilt = new ArrayList<>(world.entries().size());
        boolean found = false;
        for (World.Entry entry : world.entries()) {
            if (!found && entry.resource().equals(resource)) {
                rebuilt.add(new World.Entry(entry.resource(), entry.revision().successor()));
                found = true;
            } else {
                rebuilt.add(entry);
            }
        }
        return new World(rebuilt);
    }

    /**
     * Build a {@link Command} that retains the observation's basis.
     *
     * <p>This is the public construction path for {@link Command}.
     */
    public static <A, B> Command<B> commandOf(Observation<A> observation, B intent) {
        return new Command<>(intent, observation.basis());
    }

    /**
     * Apply {@code command} to {@code world} and return a closed outcome.
     *
     * <p>Absent resource yields {@code Rejected}. Mismatched revision yields
     * {@code Conflicted}. Matching revision yields {@code Applied} with
     * bumped world.
     */
    public static <A> Outcome<AppliedValue<A>, UnknownResource, StaleBasis, Never> apply(
            World world, Command<A> command) {
        Lookup current = lookup(world, command.basis().resource());
        if (current instanceof Lookup.Unknown unknown) {
            return new Outcome.Rejected<>(unknown.unknownResource());
        }
        Revision actual = ((Lookup.Found) current).revision();
        if (!actual.equals(command.basis().revision())) {
            return new Outcome.Conflicted<>(new StaleBasis(command.basis().revision(), actual));
        }
        World bumped = bump(world, command.basis().resource());
        return new Outcome.Applied<>(new AppliedValue<>(command.intent(), bumped));
    }

    /**
     * Pair of intent and resulting world carried by a successful
     * {@link Outcome.Applied}.
     *
     * <p>Python returns a {@code tuple[A, World]}; Java has no anonymous
     * tuple type, so this named record stands in for it. The field names
     * ({@code intent}, {@code world}) name what each position means.
     */
    public record AppliedValue<A>(A intent, World world) {
    }
}
