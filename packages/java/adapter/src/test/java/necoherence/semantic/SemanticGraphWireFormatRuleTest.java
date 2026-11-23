// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.NIL;
import static necoherence.semantic.SemanticValues.arr;
import static necoherence.semantic.SemanticValues.obj;
import static necoherence.semantic.SemanticValues.str;
import static necoherence.semantic.SemanticValues.variant;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.util.List;
import necoherence.semantic.SemanticTypes.LabelsRule;
import necoherence.semantic.SemanticValues.WireValue;
import necoherence.semantic.WireFailure.WireException;
import org.junit.jupiter.api.Test;

class SemanticGraphWireFormatRuleTest {
    @Test
    void labelsRecordWithTheClosedKeysIsAccepted() {
        assertInstanceOf(LabelsRule.class, SemanticGraphWire.formatRule(labels()));
    }

    @Test
    void labelsRecordWithAnExtraTopLevelKeyIsRejected() {
        WireValue fields = fields();
        WireValue withExtra = obj("tag", str("Labels"), "fields", fields, "extra", NIL);
        assertThrows(WireException.class, () -> SemanticGraphWire.formatRule(withExtra));
    }

    @Test
    void textUnitRuleWithAnExtraKeyIsRejected() {
        WireValue text = obj("tag", str("Text"), "value", obj());
        assertThrows(WireException.class, () -> SemanticGraphWire.formatRule(text));
    }

    @Test
    void textUnitRuleWithTheClosedKeyIsAccepted() {
        assertInstanceOf(necoherence.semantic.SemanticTypes.TextRule.class, SemanticGraphWire.formatRule(obj("tag", str("Text"))));
    }

    @Test
    void kindSelectorWithAnExtraKeyInTheUnitKindIsRejected() {
        WireValue selector = obj("tag", str("Kind"), "value", obj("tag", str("String"), "extra", NIL));
        assertThrows(WireException.class, () -> SemanticGraphWire.shape(taggedUnion(selector)));
    }

    @Test
    void rejectExtrasWithAnExtraKeyIsRejected() {
        WireValue extras = obj("tag", str("Reject"), "extra", NIL);
        assertThrows(WireException.class, () -> SemanticGraphWire.shape(product(extras)));
    }

    private static WireValue taggedUnion(WireValue selector) {
        WireValue source = obj("repository", str("owner"), "revision", str("1"), "path", str("spec"),
                "content_digest", str("a".repeat(64)), "document_id", str(""), "declared_revision", NIL);
        WireValue reference = obj("source", source, "definition_name", str("Name"), "pointer", arr(List.of()));
        WireValue branch = obj("target", reference, "wire_tag", str("Tag"), "selector", selector,
                "origin", obj("source", source, "pointer", arr(List.of())));
        return variant("TaggedUnion", obj("branches", arr(List.of(branch))));
    }

    private static WireValue product(WireValue extras) {
        return variant("Product", obj("fields", arr(List.of()), "extras", extras));
    }


    private static WireValue labels() {
        return obj("tag", str("Labels"), "fields", fields());
    }

    private static WireValue fields() {
        return obj("separator", str(","), "min_count", str("1"), "max_count", NIL, "total_max", NIL,
                "rule", obj("tag", str("Text")));
    }
}
