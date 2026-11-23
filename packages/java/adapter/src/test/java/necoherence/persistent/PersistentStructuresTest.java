// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.persistent;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.TreeSet;
import org.junit.jupiter.api.Test;

final class PersistentStructuresTest {

    private record CollidingKey(int id, int hash) {
        @Override
        public int hashCode() {
            return hash;
        }

        @Override
        public boolean equals(Object other) {
            return other instanceof CollidingKey key && key.id == id;
        }
    }

    @Test
    void vectorFollowsAListModelAndKeepsEarlierVersions() {
        Random random = new Random(7);
        List<Integer> model = new ArrayList<>();
        PersistentVector<Integer> vector = PersistentVector.empty();
        List<PersistentVector<Integer>> earlier = new ArrayList<>();
        List<List<Integer>> earlierModels = new ArrayList<>();
        for (int step = 0; step < 5000; step++) {
            if (model.isEmpty() || random.nextInt(3) > 0) {
                model.add(step);
                vector = vector.append(step);
            } else {
                int index = random.nextInt(model.size());
                model.set(index, -step);
                vector = vector.set(index, -step);
            }
            if (step % 997 == 0) {
                earlier.add(vector);
                earlierModels.add(new ArrayList<>(model));
            }
        }
        assertEquals(model, vector.toList());
        assertEquals(model.size(), vector.size());
        for (int i = 0; i < earlier.size(); i++) {
            assertEquals(earlierModels.get(i), earlier.get(i).toList());
        }
        assertEquals(model, PersistentVector.of(model).toList());
    }

    @Test
    void mapFollowsAHashMapModelIncludingCollidingHashes() {
        Random random = new Random(11);
        Map<CollidingKey, Integer> model = new HashMap<>();
        PersistentMap<CollidingKey, Integer> map = PersistentMap.empty();
        PersistentMap<CollidingKey, Integer> snapshot = map;
        Map<CollidingKey, Integer> snapshotModel = new HashMap<>();
        for (int step = 0; step < 6000; step++) {
            CollidingKey key = new CollidingKey(random.nextInt(900), random.nextInt(4) == 0 ? 5 : random.nextInt());
            CollidingKey stored = model.keySet().stream().filter(k -> k.id() == key.id()).findFirst().orElse(key);
            model.put(stored, step);
            map = map.put(stored, step);
            if (step == 3000) {
                snapshot = map;
                snapshotModel = new HashMap<>(model);
            }
        }
        assertEquals(model.size(), map.size());
        for (Map.Entry<CollidingKey, Integer> entry : model.entrySet()) {
            assertEquals(entry.getValue(), map.get(entry.getKey()));
        }
        for (Map.Entry<CollidingKey, Integer> entry : snapshotModel.entrySet()) {
            assertEquals(entry.getValue(), snapshot.get(entry.getKey()));
        }
        assertNull(map.get(new CollidingKey(10_000, 5)));
    }

    @Test
    void positionSetFollowsATreeSetModelAndYieldsItsSmallestMember() {
        Random random = new Random(13);
        TreeSet<Integer> model = new TreeSet<>();
        PositionSet set = PositionSet.empty();
        PositionSet snapshot = set;
        List<Integer> snapshotModel = List.of();
        for (int step = 0; step < 6000; step++) {
            int position = random.nextInt(40_000);
            if (random.nextBoolean()) {
                model.add(position);
                set = set.add(position);
            } else {
                model.remove(position);
                set = set.remove(position);
            }
            assertEquals(model.isEmpty() ? -1 : model.first(), set.first());
            if (step == 3000) {
                snapshot = set;
                snapshotModel = new ArrayList<>(model);
            }
        }
        assertEquals(new ArrayList<>(model), set.toList());
        assertEquals(snapshotModel, snapshot.toList());
        assertTrue(set.contains(model.first()));
    }
}
