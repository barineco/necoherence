// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticGeneration.*;
import static necoherence.semantic.SemanticValues.*;
import java.math.BigInteger;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import necoherence.semantic.WireFailure.WireException;

final class CanonicalProfiles {
    private CanonicalProfiles() {}

    static WireValue admit(WireValue expectedReference, List<WireValue> expectedSources,
            byte[] trustedBytes, byte[] inputBytes) throws GenerationFailure {
        Objects.requireNonNull(expectedReference, "expectedReference");
        Objects.requireNonNull(expectedSources, "expectedSources");
        Objects.requireNonNull(trustedBytes, "trustedBytes");
        Objects.requireNonNull(inputBytes, "inputBytes");
        WireValue reference = canonical(expectedReference, "ProfileRef", "$expected");
        require(!s(f(reference, "content_digest")).isEmpty(), "$expected.content_digest", "digest mismatch");
        require(Arrays.equals(trustedBytes, inputBytes), "$canonical", "trusted/input bytes mismatch");
        try {
            WireValue profile = canonical(boundedJsonParse(utf8(inputBytes)), "ValueProfile", "$canonical.profile");
            require(f(profile, "reference").equals(reference), "$canonical.profile.reference", "expected reference");
            List<WireValue> sources = new ArrayList<>();
            for (int i = 0; i < expectedSources.size(); i++)
                sources.add(canonical(expectedSources.get(i), "SourceIdentity", "$expectedSources[" + i + "]"));
            require(a(f(profile, "source_refs")).equals(sources), "$canonical.profile.source_refs", "expected sources");
            TypeSignatures.checkWireProfile(profile);
            return profile;
        } catch (GenerationFailure failure) {
            throw failure;
        } catch (WireException failure) {
            throw new GenerationFailure(failure.failure().path(), failure.failure().toString(), failure.failure());
        }
    }

    private static String utf8(byte[] bytes) throws GenerationFailure {
        try {
            return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString();
        } catch (CharacterCodingException failure) {
            throw new GenerationFailure("$canonical", "UTF-8 JSON");
        }
    }







    private static void text(WireValue value, String path) throws GenerationFailure { require(value instanceof StringValue, path, "string"); }
}
