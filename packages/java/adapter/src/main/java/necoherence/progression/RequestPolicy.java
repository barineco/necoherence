// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.progression;

/** Policy for completion acceptance and request start order. */
public enum RequestPolicy {
    LATEST_WINS,
    FIFO,
    ALL_EXECUTE
}
