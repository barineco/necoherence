// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.network;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Type;
import java.math.BigInteger;
import org.junit.jupiter.api.Test;

final class NetworkEffectRunnerIntegerCheck {
    @Test void integerDecodeRejectsValuesOutsideTheIntRangeAsInvalidInput() throws Exception {
        Method dec = NetworkEffectRunner.class.getDeclaredMethod("dec", Object.class, Type.class);
        dec.setAccessible(true);
        assertEquals((Object) Integer.MAX_VALUE, dec.invoke(null, BigInteger.valueOf(Integer.MAX_VALUE), int.class));
        InvocationTargetException failure = assertThrows(InvocationTargetException.class,
                () -> dec.invoke(null, BigInteger.ONE.shiftLeft(40), int.class));
        assertEquals("integer outside the int range", failure.getCause().getMessage());
    }
}
