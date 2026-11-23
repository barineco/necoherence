// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import java.util.List;
import neco.quotient.Result;
import neco.quotient.encoding.Encoding;
import neco.quotient.encoding.EncodingFailure;
import neco.quotient.encoding.JsonValue;
import necoherence.composition.SemanticComposition.TypeRef;
import necoherence.semantic.SemanticGeneration.GenerationBasis;
import necoherence.semantic.SemanticTypes.SemanticObligation;
import necoherence.semantic.SemanticValues.ArrayValue;
import necoherence.semantic.SemanticValues.BooleanValue;
import necoherence.semantic.SemanticValues.DecimalValue;
import necoherence.semantic.SemanticValues.IntegerValue;
import necoherence.semantic.SemanticValues.NullValue;
import necoherence.semantic.SemanticValues.ObjectValue;
import necoherence.semantic.SemanticValues.StringValue;
import necoherence.semantic.SemanticValues.WireValue;

public final class SemanticResidualRecord {
    public static final String SCHEMA = "necoherence.semantic-residual.v1";

    private SemanticResidualRecord() {}

    public static Result<byte[], EncodingFailure> encodeSemanticResidual(GenerationBasis basis, TypeRef typeRef,
            ExactJson.JsonValue value, List<SemanticObligation> obligations) {
        List<JsonValue> obligationWires = obligations.stream()
                .map(obligation -> toNeco(SemanticGraphWire.obligationWire(obligation))).toList();
        List<JsonValue> residuals;
        switch (Encoding.normalizeResiduals(obligationWires)) {
            case neco.quotient.encoding.Result.Accepted<List<JsonValue>, EncodingFailure> accepted -> residuals = accepted.value();
            case neco.quotient.encoding.Result.Rejected<List<JsonValue>, EncodingFailure> failed -> {
                return new Result.Rejected<>(failed.error());
            }
        }
        JsonValue record = new JsonValue.Obj(List.of(
                new JsonValue.Field("schema", new JsonValue.Text(SCHEMA)),
                new JsonValue.Field("basis", toNeco(basis.value)),
                new JsonValue.Field("input", new JsonValue.Obj(List.of(
                        new JsonValue.Field("type_ref", toNeco(SemanticGraphWire.typeRefWire(typeRef))),
                        new JsonValue.Field("value", toNeco(SemanticGeneration.toExact(WireJson.toWire(value))))))),
                new JsonValue.Field("residuals", new JsonValue.Arr(residuals))));
        return switch (Encoding.canonicalBytes(record)) {
            case neco.quotient.encoding.Result.Accepted<byte[], EncodingFailure> accepted -> new Result.Accepted<>(accepted.value());
            case neco.quotient.encoding.Result.Rejected<byte[], EncodingFailure> failed -> new Result.Rejected<>(failed.error());
        };
    }

    static JsonValue toNeco(WireValue value) {
        return switch (value) {
            case NullValue unused -> new JsonValue.Null();
            case BooleanValue v -> new JsonValue.Bool(v.value());
            case IntegerValue v -> new JsonValue.Number(v.value().toString());
            case DecimalValue v -> new JsonValue.Number(v.text());
            case StringValue v -> new JsonValue.Text(v.value());
            case ArrayValue v -> new JsonValue.Arr(v.items().stream().map(SemanticResidualRecord::toNeco).toList());
            case ObjectValue v -> new JsonValue.Obj(v.members().stream()
                    .map(member -> new JsonValue.Field(member.key(), toNeco(member.value()))).toList());
        };
    }
}
