// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.network;

import java.util.Arrays;

/**
 * Immutable sequence of bytes.
 *
 * <p>Construction and {@link #toArray} copy, so a caller cannot change the bytes of a built value. Equality
 * compares the bytes.
 */
public final class ByteString {
    private static final ByteString EMPTY = new ByteString(new byte[0]);

    private final byte[] values;

    private ByteString(byte[] values) {
        this.values = values;
    }

    public static ByteString empty() {
        return EMPTY;
    }

    public static ByteString copyOf(byte[] bytes) {
        return new ByteString(bytes.clone());
    }

    /** Build from values in 0..255; each argument is narrowed to its low eight bits. */
    public static ByteString ofUnsigned(int... bytes) {
        byte[] values = new byte[bytes.length];
        for (int i = 0; i < bytes.length; i++) {
            values[i] = (byte) bytes[i];
        }
        return new ByteString(values);
    }

    public int size() {
        return values.length;
    }

    /** Return the byte at {@code index} as a value in 0..255. */
    public int unsigned(int index) {
        return Byte.toUnsignedInt(values[index]);
    }

    public byte[] toArray() {
        return values.clone();
    }

    @Override
    public boolean equals(Object other) {
        return other instanceof ByteString bytes && Arrays.equals(values, bytes.values);
    }

    @Override
    public int hashCode() {
        return Arrays.hashCode(values);
    }

    @Override
    public String toString() {
        return "ByteString" + Arrays.toString(values);
    }
}
