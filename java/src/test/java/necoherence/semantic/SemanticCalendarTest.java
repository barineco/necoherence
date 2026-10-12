// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;

public final class SemanticCalendarTest {
    private static void check(WireValue rule, String text, boolean expected) {
        if (recognize(rule, text) != expected) throw new AssertionError(text);
    }
    public static void main(String[] args) {
        WireValue calendar = obj("allow_second_60", new BooleanValue(false), "minimum_year", str("0"), "maximum_year", str("9999"), "rejectUtcYearOutsideRange", new BooleanValue(true));
        WireValue strict = variant("Timestamp", calendar);
        check(strict, "9999-12-31T23:59:59Z", true);
        check(strict, "9999-12-31T23:59:59-23:59", false);
        check(strict, "0000-01-01T00:00:00Z", true);
        check(strict, "0000-01-01T00:00:00+00:01", false);
        check(strict, "2026-10-02T12:30:45.123456789012345678901234567890Z", true);
        check(strict, "2026-10-02T12:30:45-00:00", false);
        WireValue leap = variant("Timestamp", obj("allow_second_60", new BooleanValue(true), "minimum_year", str("0"), "maximum_year", str("9999"), "rejectUtcYearOutsideRange", new BooleanValue(true)));
        check(leap, "9999-12-31T23:59:60Z", true);
        check(leap, "9999-12-31T23:59:60+00:00", true);
        check(leap, "0000-01-01T00:00:60+00:01", false);
        System.out.println("calendar boundary cases=9");
    }
}
