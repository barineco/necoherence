// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.persistent;

/**
 * Immutable hash map that shares unchanged nodes between versions.
 *
 * <p>Keys must be non-null and define {@code equals} and a deterministic
 * {@code hashCode}. {@code put} returns a new map; the receiver is unchanged.
 */
public final class PersistentMap<K, V> {
    private static final PersistentMap<?, ?> EMPTY = new PersistentMap<>(new Object[32], 0);

    private record Entry<K, V>(int hash, K key, V value) {
    }

    private record Bucket<K, V>(int hash, Entry<K, V>[] entries) {
    }

    private final Object[] root;
    private final int size;

    private PersistentMap(Object[] root, int size) {
        this.root = root;
        this.size = size;
    }

    @SuppressWarnings("unchecked")
    public static <K, V> PersistentMap<K, V> empty() {
        return (PersistentMap<K, V>) EMPTY;
    }

    public int size() {
        return size;
    }

    public boolean containsKey(K key) {
        return find(key) != null;
    }

    /** Return the value bound to {@code key}, or {@code null} when absent. */
    public V get(K key) {
        Entry<K, V> entry = find(key);
        return entry == null ? null : entry.value();
    }

    public PersistentMap<K, V> put(K key, V value) {
        int hash = spread(key.hashCode());
        boolean[] added = new boolean[1];
        Object[] next = insert(root, 0, new Entry<>(hash, key, value), added);
        return new PersistentMap<>(next, added[0] ? size + 1 : size);
    }

    private static int spread(int hash) {
        return hash ^ (hash >>> 16);
    }

    private static int slot(int hash, int shift) {
        return (hash >>> shift) & 31;
    }

    @SuppressWarnings("unchecked")
    private Entry<K, V> find(K key) {
        int hash = spread(key.hashCode());
        Object[] node = root;
        int shift = 0;
        while (true) {
            Object item = node[slot(hash, shift)];
            if (item == null) {
                return null;
            }
            if (item instanceof Object[] child) {
                node = child;
                shift += 5;
            } else if (item instanceof Entry<?, ?> entry) {
                return entry.hash() == hash && entry.key().equals(key) ? (Entry<K, V>) entry : null;
            } else {
                Bucket<K, V> bucket = (Bucket<K, V>) item;
                for (Entry<K, V> entry : bucket.entries()) {
                    if (entry.key().equals(key)) {
                        return entry;
                    }
                }
                return null;
            }
        }
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    private static <K, V> Object[] insert(Object[] node, int shift, Entry<K, V> fresh, boolean[] added) {
        Object[] copy = node.clone();
        int index = slot(fresh.hash(), shift);
        Object item = node[index];
        if (item == null) {
            copy[index] = fresh;
            added[0] = true;
        } else if (item instanceof Object[] child) {
            copy[index] = insert(child, shift + 5, fresh, added);
        } else if (item instanceof Entry<?, ?> existing) {
            Entry<K, V> old = (Entry<K, V>) existing;
            if (old.hash() == fresh.hash() && old.key().equals(fresh.key())) {
                copy[index] = fresh;
            } else if (old.hash() == fresh.hash()) {
                copy[index] = new Bucket<>(old.hash(), new Entry[] {old, fresh});
                added[0] = true;
            } else {
                copy[index] = split(old, shift + 5, fresh, added);
            }
        } else {
            Bucket<K, V> bucket = (Bucket<K, V>) item;
            if (bucket.hash() != fresh.hash()) {
                copy[index] = split(bucket, shift + 5, fresh, added);
            } else {
                copy[index] = withinBucket(bucket, fresh, added);
            }
        }
        return copy;
    }

    private static <K, V> Object[] split(Object resident, int shift, Entry<K, V> fresh, boolean[] added) {
        int hash = resident instanceof Bucket<?, ?> b ? b.hash() : ((Entry<?, ?>) resident).hash();
        Object[] child = new Object[32];
        child[slot(hash, shift)] = resident;
        return insert(child, shift, fresh, added);
    }

    @SuppressWarnings("unchecked")
    private static <K, V> Bucket<K, V> withinBucket(Bucket<K, V> bucket, Entry<K, V> fresh, boolean[] added) {
        Entry<K, V>[] entries = bucket.entries();
        for (int i = 0; i < entries.length; i++) {
            if (entries[i].key().equals(fresh.key())) {
                Entry<K, V>[] copy = entries.clone();
                copy[i] = fresh;
                return new Bucket<>(bucket.hash(), copy);
            }
        }
        Entry<K, V>[] copy = java.util.Arrays.copyOf(entries, entries.length + 1);
        copy[entries.length] = fresh;
        added[0] = true;
        return new Bucket<>(bucket.hash(), copy);
    }
}
