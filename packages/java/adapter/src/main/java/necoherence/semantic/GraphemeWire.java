// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.a;
import static necoherence.semantic.SemanticValues.keys;
import static necoherence.semantic.SemanticValues.f;
import static necoherence.semantic.SemanticValues.n;
import static necoherence.semantic.SemanticValues.s;
import static necoherence.semantic.SemanticValues.tag;

import java.util.ArrayList;
import java.util.List;
import necoherence.semantic.SemanticTypes.CodepointRange;
import necoherence.semantic.SemanticTypes.GraphemeComponent;
import necoherence.semantic.SemanticTypes.GraphemeProperty;
import necoherence.semantic.SemanticTypes.GraphemeRange;
import necoherence.semantic.SemanticTypes.GraphemeRules;
import necoherence.semantic.SemanticTypes.GraphemeSource;
import necoherence.semantic.SemanticTypes.IndicProperty;
import necoherence.semantic.SemanticTypes.IndicRange;
import necoherence.semantic.SemanticTypes.Origin;
import necoherence.semantic.SemanticTypes.ProfileRef;
import necoherence.semantic.SemanticTypes.SourceIdentity;
import necoherence.semantic.SemanticValues.WireValue;
import necoherence.semantic.WireFailure.UnknownTag;
import necoherence.semantic.WireFailure.WireException;

/** Decodes the grapheme rules of the profile wire form into the typed grapheme rules. */
public final class GraphemeWire {
    private GraphemeWire() {}

    /**
     * Decodes the grapheme rules at the path. A property tag, or a rule row, outside the wire form is a typed
     * {@link UnknownTag} failure.
     */
    public static GraphemeRules decode(WireValue rules, String path) {
        keys(rules, path, "reference", "component", "table_sha256", "sources", "properties",
                "extended_pictographic", "indic_conjunct");
        List<WireValue> propertyRows = a(f(rules, "properties"));
        List<GraphemeRange> properties = new ArrayList<>(propertyRows.size());
        for (int index = 0; index < propertyRows.size(); index++) {
            WireValue row = propertyRows.get(index);
            String rowPath = element(path, "properties", index);
            keys(row, rowPath, "first", "last", "property");
            properties.add(new GraphemeRange(n(f(row, "first")), n(f(row, "last")), property(f(row, "property"), path)));
        }
        List<WireValue> pictographicRows = a(f(rules, "extended_pictographic"));
        List<CodepointRange> pictographic = new ArrayList<>(pictographicRows.size());
        for (int index = 0; index < pictographicRows.size(); index++) {
            WireValue row = pictographicRows.get(index);
            keys(row, element(path, "extended_pictographic", index), "first", "last");
            pictographic.add(new CodepointRange(n(f(row, "first")), n(f(row, "last"))));
        }
        List<WireValue> indicRows = a(f(rules, "indic_conjunct"));
        List<IndicRange> indic = new ArrayList<>(indicRows.size());
        for (int index = 0; index < indicRows.size(); index++) {
            WireValue row = indicRows.get(index);
            keys(row, element(path, "indic_conjunct", index), "first", "last", "property");
            indic.add(new IndicRange(n(f(row, "first")), n(f(row, "last")), indicProperty(f(row, "property"), path)));
        }
        WireValue component = f(rules, "component");
        keys(component, path + ".component", "unicode_version", "uax29_revision", "cluster_profile");
        List<WireValue> sourceRows = a(f(rules, "sources"));
        List<GraphemeSource> sources = new ArrayList<>(sourceRows.size());
        for (int index = 0; index < sourceRows.size(); index++) sources.add(source(sourceRows.get(index), element(path, "sources", index)));
        return new GraphemeRules(profileRef(f(rules, "reference"), path + ".reference"),
                properties, pictographic, indic,
                new GraphemeComponent(s(f(component, "unicode_version")), s(f(component, "uax29_revision")),
                        s(f(component, "cluster_profile"))),
                s(f(rules, "table_sha256")), sources);
    }

    private static ProfileRef profileRef(WireValue reference, String path) {
        keys(reference, path, "identity", "revision", "content_digest");
        return new ProfileRef(s(f(reference, "identity")), s(f(reference, "revision")), s(f(reference, "content_digest")));
    }
    private static GraphemeProperty property(WireValue value, String path) {
        return switch (tag(value)) {
            case "Other" -> GraphemeProperty.OTHER;
            case "Cr" -> GraphemeProperty.CR;
            case "Lf" -> GraphemeProperty.LF;
            case "Control" -> GraphemeProperty.CONTROL;
            case "Extend" -> GraphemeProperty.EXTEND;
            case "Zwj" -> GraphemeProperty.ZWJ;
            case "RegionalIndicator" -> GraphemeProperty.REGIONAL_INDICATOR;
            case "Prepend" -> GraphemeProperty.PREPEND;
            case "SpacingMark" -> GraphemeProperty.SPACING_MARK;
            case "L" -> GraphemeProperty.L;
            case "V" -> GraphemeProperty.V;
            case "T" -> GraphemeProperty.T;
            case "Lv" -> GraphemeProperty.LV;
            case "Lvt" -> GraphemeProperty.LVT;
            default -> throw unknownTag(path + ".properties.property", value);
        };
    }

    private static IndicProperty indicProperty(WireValue value, String path) {
        return switch (tag(value)) {
            case "Other" -> IndicProperty.OTHER;
            case "Consonant" -> IndicProperty.CONSONANT;
            case "Extend" -> IndicProperty.EXTEND;
            case "Linker" -> IndicProperty.LINKER;
            default -> throw unknownTag(path + ".indic_conjunct.property", value);
        };
    }

    private static GraphemeSource source(WireValue row, String path) {
        keys(row, path, "role", "origin");
        WireValue origin = f(row, "origin");
        keys(origin, path + ".origin", "source", "locator");
        WireValue source = f(origin, "source");
        keys(source, path + ".origin.source", "repository", "revision", "path", "content_digest");
        List<WireValue> locatorValues = a(f(origin, "locator"));
        List<String> locator = new ArrayList<>(locatorValues.size());
        for (WireValue value : locatorValues) locator.add(s(value));
        return new GraphemeSource(s(f(row, "role")), new Origin(new SourceIdentity(s(f(source, "repository")),
                s(f(source, "revision")), s(f(source, "path")), s(f(source, "content_digest"))), locator));
    }

    private static WireException unknownTag(String path, WireValue value) {
        return new WireException(new UnknownTag(path, tag(value)));
    }

    private static String element(String path, String key, int index) {
        return path + "." + key + "[" + index + "]";
    }
}
