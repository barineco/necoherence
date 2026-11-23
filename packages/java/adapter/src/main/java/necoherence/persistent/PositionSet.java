// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.persistent;

import java.util.ArrayList;
import java.util.List;

/**
 * Immutable set of non-negative positions that shares unchanged nodes
 * between versions and yields its smallest member without a scan.
 */
public final class PositionSet {
    private static final PositionSet EMPTY = new PositionSet(new Branch(0, new Object[32]), 1);

    private record Branch(int occupied, Object[] children) {
    }

    private final Branch root;
    private final int height;

    private PositionSet(Branch root, int height) {
        this.root = root;
        this.height = height;
    }

    public static PositionSet empty() {
        return EMPTY;
    }

    public boolean isEmpty() {
        return root.occupied() == 0;
    }

    /** Return the smallest member, or -1 when the set is empty. */
    public int first() {
        if (root.occupied() == 0) {
            return -1;
        }
        Branch node = root;
        int position = 0;
        for (int level = height - 1; level > 0; level--) {
            int slot = Integer.numberOfTrailingZeros(node.occupied());
            position |= slot << (5 * level);
            node = (Branch) node.children()[slot];
        }
        return position | Integer.numberOfTrailingZeros(node.occupied());
    }

    public boolean contains(int position) {
        if (position >= (1L << (5 * height))) {
            return false;
        }
        Branch node = root;
        for (int level = height - 1; level > 0; level--) {
            Object child = node.children()[(position >>> (5 * level)) & 31];
            if (child == null) {
                return false;
            }
            node = (Branch) child;
        }
        return (node.occupied() & (1 << (position & 31))) != 0;
    }

    public PositionSet add(int position) {
        Branch top = root;
        int newHeight = height;
        while (position >= (1L << (5 * newHeight))) {
            Object[] children = new Object[32];
            children[0] = top;
            top = new Branch(top.occupied() == 0 ? 0 : 1, children);
            newHeight++;
        }
        return new PositionSet(update(top, newHeight - 1, position, true), newHeight);
    }

    public PositionSet remove(int position) {
        if (!contains(position)) {
            return this;
        }
        return new PositionSet(update(root, height - 1, position, false), height);
    }

    public List<Integer> toList() {
        List<Integer> result = new ArrayList<>();
        collect(root, height - 1, 0, result);
        return result;
    }

    private static Branch update(Branch node, int level, int position, boolean present) {
        if (level == 0) {
            int bit = 1 << (position & 31);
            return new Branch(present ? node.occupied() | bit : node.occupied() & ~bit, node.children());
        }
        int slot = (position >>> (5 * level)) & 31;
        Object[] children = node.children().clone();
        Branch child = (Branch) children[slot];
        Branch next = update(child == null ? new Branch(0, new Object[32]) : child, level - 1, position, present);
        children[slot] = next;
        int occupied = next.occupied() == 0 ? node.occupied() & ~(1 << slot) : node.occupied() | (1 << slot);
        return new Branch(occupied, children);
    }

    private static void collect(Branch node, int level, int base, List<Integer> into) {
        int remaining = node.occupied();
        while (remaining != 0) {
            int slot = Integer.numberOfTrailingZeros(remaining);
            remaining &= remaining - 1;
            if (level == 0) {
                into.add(base | slot);
            } else {
                collect((Branch) node.children()[slot], level - 1, base | (slot << (5 * level)), into);
            }
        }
    }
}
