// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.composition;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;

import java.math.BigInteger;
import java.util.List;
import java.util.Optional;
import necoherence.composition.SemanticComposition.Field;
import necoherence.composition.SemanticComposition.Index;
import necoherence.composition.SemanticComposition.PathStep;
import necoherence.composition.SemanticComposition.Variant;
import necoherence.composition.SemanticExecution.InvalidPlan;
import necoherence.composition.SemanticExecution.ProviderRejected;
import necoherence.composition.SemanticExecution.ProviderSuccess;
import necoherence.semantic.ExactJson.JsonArr;
import necoherence.semantic.ExactJson.JsonMember;
import necoherence.semantic.ExactJson.JsonNull;
import necoherence.semantic.ExactJson.JsonNum;
import necoherence.semantic.ExactJson.JsonObj;
import necoherence.semantic.ExactJson.JsonStr;
import necoherence.semantic.ExactJson.JsonValue;
import necoherence.semantic.SemanticTypes.NumberModel;
import necoherence.semantic.SemanticTypes.ProfileRef;
import necoherence.semantic.SemanticTypes.TagModel;
import necoherence.semantic.SemanticTypes.VersionedSemanticProfile;
import necoherence.semantic.SemanticValidation;
import necoherence.semantic.SemanticValues.Absent;
import necoherence.semantic.SemanticValues.NullSlot;
import necoherence.semantic.SemanticValues.Present;
import necoherence.semantic.SemanticValues.Slot;

/** Checks the execution projection and the validation projection against the Lean definitions. */
class ProjectionAlignmentTest {
    private static final String TAG_KEY = "$type";

    private static VersionedSemanticProfile profile() {
        return new VersionedSemanticProfile(new ProfileRef("", "", ""), List.of(), List.of(), "",
                new NumberModel(false), Optional.empty(), List.of(), Optional.empty(), List.of(),
                Optional.of(new TagModel(TAG_KEY, Optional.empty(), List.of())));
    }

    private static JsonObj object(JsonMember... members) {
        return new JsonObj(List.of(members));
    }

    private static Slot<JsonValue> execute(JsonValue source, PathStep... path) {
        SemanticExecution.ProviderResult<Slot<JsonValue>> result =
                SemanticExecution.project(TAG_KEY, new Present<>(source), List.of(path));
        @SuppressWarnings("unchecked")
        ProviderSuccess<Slot<JsonValue>> success = (ProviderSuccess<Slot<JsonValue>>) assertInstanceOf(
                ProviderSuccess.class, result);
        return success.value();
    }

    /** A missing field is absent in the execution projection and continues to later steps as absent. */
    @org.junit.jupiter.api.Test
    void missingFieldIsAbsentThenRejectsFurtherSteps() {
        JsonObj source = object(new JsonMember("a", new JsonNum(BigInteger.ONE)));
        assertEquals(new Absent<JsonValue>(), execute(source, new Field("missing")));
        assertInstanceOf(ProviderRejected.class, SemanticExecution.project(TAG_KEY, new Present<>(source),
                List.of(new Field("missing"), new Field("deeper"))));
    }

    /** A variant step on a non-object is a shape mismatch, as the Lean execution projection reports. */
    @org.junit.jupiter.api.Test
    void variantOnNonObjectIsShapeMismatch() {
        JsonArr source = new JsonArr(List.of(new JsonStr("x")));
        assertEquals(new ProviderRejected<Slot<JsonValue>>(new InvalidPlan("projection shape mismatch")),
                SemanticExecution.project(TAG_KEY, new Present<>(source), List.of(new Variant("x"))));
    }

    /** A variant step on an object with another tag is a variant mismatch. */
    @org.junit.jupiter.api.Test
    void variantOnObjectWithOtherTagIsVariantMismatch() {
        JsonObj source = object(new JsonMember(TAG_KEY, new JsonStr("y")));
        assertEquals(new ProviderRejected<Slot<JsonValue>>(new InvalidPlan("variant projection mismatch")),
                SemanticExecution.project(TAG_KEY, new Present<>(source), List.of(new Variant("x"))));
    }

    /** A null field is a null slot, and an out-of-range index is an execution rejection. */
    @org.junit.jupiter.api.Test
    void nullFieldAndIndexBoundaryInExecutionProjection() {
        JsonObj source = object(new JsonMember("a", new JsonNull()));
        assertEquals(new NullSlot<JsonValue>(), execute(source, new Field("a")));
        assertEquals(new ProviderRejected<Slot<JsonValue>>(new InvalidPlan("array projection outside value")),
                SemanticExecution.project(TAG_KEY, new Present<>(new JsonArr(List.of())),
                        List.of(new Index(java.math.BigInteger.ZERO))));
    }

    /** The validation projection returns absent for a missing field and keeps a null slot. */
    @org.junit.jupiter.api.Test
    void validationProjectionFollowsLeanProjectedValue() {
        VersionedSemanticProfile profile = profile();
        JsonObj source = object(new JsonMember("a", new JsonNull()));
        assertEquals(new Absent<JsonValue>(), SemanticValidation.projectedValue(profile,
                new Present<>(source), List.of(new Field("missing"))));
        assertEquals(new NullSlot<JsonValue>(), SemanticValidation.projectedValue(profile,
                new Present<>(source), List.of(new Field("a"), new Field("deeper"))));
        assertEquals(new NullSlot<JsonValue>(), SemanticValidation.projectedValue(profile,
                new NullSlot<>(), List.of(new Field("a"))));
        assertEquals(new Absent<JsonValue>(), SemanticValidation.projectedValue(profile,
                new Absent<>(), List.of()));
    }
}
