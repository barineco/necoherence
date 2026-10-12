// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.file;

import necoherence.core.UnknownResource;

/**
 * Closed rejection: {@code path} and {@code command.basis.resource} name different resources, the
 * resource is absent, or its contents were never observed.
 */
public sealed interface ReplaceRejection
        permits ReplaceRejection.ResourcePathMismatchRejection, ReplaceRejection.UnknownResourceRejection,
        ReplaceRejection.UnobservedContentsRejection {

    record ResourcePathMismatchRejection(ResourcePathMismatch mismatch) implements ReplaceRejection {
    }

    record UnknownResourceRejection(UnknownResource unknownResource) implements ReplaceRejection {
    }

    record UnobservedContentsRejection(UnobservedContents unobservedContents) implements ReplaceRejection {
    }
}
