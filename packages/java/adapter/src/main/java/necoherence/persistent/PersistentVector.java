// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.persistent;

import java.util.ArrayList;
import java.util.List;

/**
 * Immutable indexed sequence that shares unchanged nodes between versions.
 *
 * <p>Positions are zero-based. {@code get}, {@code set} and {@code append}
 * visit a number of nodes proportional to the logarithm (base 32) of the size.
 */
public final class PersistentVector<T> {
    private static final int WIDTH = 32;
    private static final PersistentVector<?> EMPTY = new PersistentVector<>(new Object[WIDTH], 1, 0);

    private final Object[] root;
    private final int height;
    private final int size;

    private PersistentVector(Object[] root, int height, int size) {
        this.root = root;
        this.height = height;
        this.size = size;
    }

    @SuppressWarnings("unchecked")
    public static <T> PersistentVector<T> empty() {
        return (PersistentVector<T>) EMPTY;
    }

    public static <T> PersistentVector<T> of(List<T> values) {
        int count = values.size();
        if (count == 0) {
            return empty();
        }
        List<Object[]> level = new ArrayList<>();
        for (int start = 0; start < count; start += WIDTH) {
            Object[] leaf = new Object[WIDTH];
            for (int offset = 0; offset < WIDTH && start + offset < count; offset++) {
                leaf[offset] = values.get(start + offset);
            }
            level.add(leaf);
        }
        int height = 1;
        while (level.size() > 1) {
            List<Object[]> parents = new ArrayList<>();
            for (int start = 0; start < level.size(); start += WIDTH) {
                Object[] parent = new Object[WIDTH];
                for (int offset = 0; offset < WIDTH && start + offset < level.size(); offset++) {
                    parent[offset] = level.get(start + offset);
                }
                parents.add(parent);
            }
            level = parents;
            height++;
        }
        return new PersistentVector<>(level.get(0), height, count);
    }

    public int size() {
        return size;
    }

    @SuppressWarnings("unchecked")
    public T get(int index) {
        if (index < 0 || index >= size) {
            throw new IndexOutOfBoundsException(index);
        }
        Object[] node = root;
        for (int level = height - 1; level > 0; level--) {
            node = (Object[]) node[(index >>> (5 * level)) & 31];
        }
        return (T) node[index & 31];
    }

    public PersistentVector<T> set(int index, T value) {
        if (index < 0 || index >= size) {
            throw new IndexOutOfBoundsException(index);
        }
        return new PersistentVector<>(replace(root, height - 1, index, value), height, size);
    }

    public PersistentVector<T> append(T value) {
        Object[] top = root;
        int newHeight = height;
        if (size == capacity(height)) {
            top = new Object[WIDTH];
            top[0] = root;
            newHeight = height + 1;
        }
        return new PersistentVector<>(replace(top, newHeight - 1, size, value), newHeight, size + 1);
    }

    public List<T> toList() {
        List<T> result = new ArrayList<>(size);
        collect(root, height - 1, result);
        return result;
    }

    private static long capacity(int height) {
        return 1L << (5 * height);
    }

    private static Object[] replace(Object[] node, int level, int index, Object value) {
        Object[] copy = node.clone();
        if (level == 0) {
            copy[index & 31] = value;
            return copy;
        }
        int slot = (index >>> (5 * level)) & 31;
        Object[] child = (Object[]) node[slot];
        copy[slot] = replace(child == null ? new Object[WIDTH] : child, level - 1, index, value);
        return copy;
    }

    @SuppressWarnings("unchecked")
    private void collect(Object[] node, int level, List<T> into) {
        for (Object slot : node) {
            if (slot == null || into.size() == size) {
                return;
            }
            if (level == 0) {
                into.add((T) slot);
            } else {
                collect((Object[]) slot, level - 1, into);
            }
        }
    }
}
