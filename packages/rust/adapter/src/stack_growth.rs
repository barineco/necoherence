// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

const RED_ZONE: usize = 128 * 1024;
const STACK_SEGMENT: usize = 4 * 1024 * 1024;

pub(crate) fn grow<R>(callback: impl FnOnce() -> R) -> R {
    stacker::maybe_grow(RED_ZONE, STACK_SEGMENT, callback)
}
