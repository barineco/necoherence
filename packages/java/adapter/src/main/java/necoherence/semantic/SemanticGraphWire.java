// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.NIL;
import static necoherence.semantic.SemanticValues.a;
import static necoherence.semantic.SemanticValues.arr;
import static necoherence.semantic.SemanticValues.b;
import static necoherence.semantic.SemanticValues.readField;
import static necoherence.semantic.SemanticValues.i;
import static necoherence.semantic.SemanticValues.readList;
import static necoherence.semantic.SemanticValues.n;
import static necoherence.semantic.SemanticValues.nil;
import static necoherence.semantic.SemanticValues.obj;
import static necoherence.semantic.SemanticValues.readOption;
import static necoherence.semantic.SemanticValues.readPlainList;
import static necoherence.semantic.SemanticValues.s;
import static necoherence.semantic.SemanticValues.str;
import static necoherence.semantic.SemanticValues.variant;
import static necoherence.semantic.SemanticValues.readWithin;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import necoherence.composition.SemanticComposition.Field;
import necoherence.composition.SemanticComposition.Index;
import necoherence.composition.SemanticComposition.PathStep;
import necoherence.composition.SemanticComposition.SlotContract;
import necoherence.composition.SemanticComposition.TypeRef;
import necoherence.composition.SemanticComposition.Variant;
import necoherence.semantic.SemanticTypes.*;
import necoherence.semantic.SemanticValues.ObjectValue;
import necoherence.semantic.SemanticValues.WireValue;
import necoherence.semantic.WireFailure.Syntax;
import necoherence.semantic.WireFailure.UnknownTag;
import necoherence.semantic.WireFailure.WireException;

/**
 * The wire boundary of the semantic graph. Decoders read the wire form into the typed graph, and encoders
 * write the typed graph back. A tag outside the wire form is a typed {@link UnknownTag} failure, never a default.
 *
 * <p>Every decoder reads its value at the root {@code $} and reports the failure paths relative to that value, as the
 * Lean decoders do. A public decoder takes the path of its value and prefixes the failure paths with it.
 */
public final class SemanticGraphWire {
    private SemanticGraphWire() {}

    /**
     * The readings of a semantic graph wire form, each the Lean reader of one tool or of the canonical wire. A reading
     * admits the shape tags of its reader, reads the node metadata and the source references only when it reads them,
     * reads the shape before the reference only for the public validation, and reads the payload of a shape at the
     * {@code value} or {@code fields} member only when the reader names the member in its failure path.
     */
    public enum GraphReading {
        CANONICAL(Set.of("Boolean", "Integer", "Decimal", "String", "Bytes", "Product", "Array", "TaggedUnion", "Unknown",
                "Sealed", "Never", "Alias", "RawBody", "Opaque", "Unit"), true, false, false),
        DEFAULT_MATERIALIZATION(Set.of("Boolean", "Integer", "Decimal", "String", "Unknown", "Unit", "Never", "Alias", "Array",
                "Product", "TaggedUnion"), true, false, true),
        PUBLIC_VALIDATION(Set.of("String"), false, true, true);

        private final Set<String> shapeTags;
        private final boolean metadata;
        private final boolean shapeFirst;
        private final boolean namedMembers;

        GraphReading(Set<String> shapeTags, boolean metadata, boolean shapeFirst, boolean namedMembers) {
            this.shapeTags = shapeTags;
            this.metadata = metadata;
            this.shapeFirst = shapeFirst;
            this.namedMembers = namedMembers;
        }

        Set<String> shapeTags() { return shapeTags; }

        boolean readsMetadata() { return metadata; }

        boolean shapeFirst() { return shapeFirst; }

        boolean namedMembers() { return namedMembers; }
    }

    private static WireException unknownTag(String path, String tag) {
        return new WireException(new UnknownTag(path, tag));
    }

    private static void closed(WireValue value, String... expected) {
        SemanticValues.keys(value, "$", expected);
    }

    private static String tagOf(WireValue value) {
        return readField(value, "tag", SemanticValues::s);
    }

    private static WireValue payloadOf(WireValue json) {
        closed(json, "tag", "value");
        return ((ObjectValue) json).get("value");
    }

    private static WireValue fieldsOf(WireValue json) {
        closed(json, "tag", "fields");
        return ((ObjectValue) json).get("fields");
    }

    public static SemanticGraph decodeGraph(WireValue graph) { return decodeGraph(graph, "$", GraphReading.CANONICAL); }

    /**
     * Reads a semantic graph of the wire form in the order of the Lean reader of the given reading.
     * @param graph the wire value of the graph
     * @param path the path of the graph, prefixed to every failure path
     * @param reading the Lean reader that decides the admitted members
     * @return the typed graph
     * @throws WireException with the wire failure at the path of the failing member
     */
    public static SemanticGraph decodeGraph(WireValue graph, String path, GraphReading reading) {
        return readWithin(path, value -> graphValue(value, reading), graph);
    }

    private static SemanticGraph graphValue(WireValue graph, GraphReading reading) {
        closed(graph, "profile", "nodes", "source_refs");
        VersionedSemanticProfile profile = readField(graph, "profile", SemanticGraphWire::profileValue);
        List<TypeNode> nodes = readField(graph, "nodes", value -> readList(value, item -> nodeValue(item, reading)));
        List<SourceRef> sourceRefs = reading.readsMetadata()
                ? readField(graph, "source_refs", value -> readList(value, SemanticGraphWire::sourceRefValue))
                : List.of();
        return new SemanticGraph(profile, nodes, sourceRefs);
    }

    private static TypeNode nodeValue(WireValue node, GraphReading reading) {
        closed(node, "reference", "shape", "description", "attributes", "extensions");
        TypeRef reference;
        TypeShape shape;
        if (reading.shapeFirst()) {
            shape = readField(node, "shape", value -> shapeValue(value, reading));
            reference = readField(node, "reference", SemanticGraphWire::typeRefValue);
        } else {
            reference = readField(node, "reference", SemanticGraphWire::typeRefValue);
            shape = readField(node, "shape", value -> shapeValue(value, reading));
        }
        if (!reading.readsMetadata()) return new TypeNode(reference, shape, Optional.empty(), List.of(), List.of());
        Optional<String> description = readField(node, "description", value -> readOption(value, SemanticValues::s));
        List<OccurrenceRef> attributes = readField(node, "attributes", value -> readList(value, SemanticGraphWire::occurrenceValue));
        List<OccurrenceRef> extensions = readField(node, "extensions", value -> readList(value, SemanticGraphWire::occurrenceValue));
        return new TypeNode(reference, shape, description, attributes, extensions);
    }

    public static SourceRef sourceRef(WireValue source, String path) { return readWithin(path, SemanticGraphWire::sourceRefValue, source); }

    private static SourceRef sourceRefValue(WireValue source) {
        closed(source, "repository", "revision", "path", "content_digest", "document_id", "declared_revision");
        return new SourceRef(readField(source, "repository", SemanticValues::s), readField(source, "revision", SemanticValues::s),
                readField(source, "path", SemanticValues::s), readField(source, "content_digest", SemanticValues::s),
                readField(source, "document_id", SemanticValues::s), readField(source, "declared_revision", value -> readOption(value, SemanticValues::i)));
    }

    public static SourceRef sourceIdentity(WireValue source, String path) { return readWithin(path, SemanticGraphWire::sourceIdentityValue, source); }

    private static SourceRef sourceIdentityValue(WireValue source) {
        closed(source, "repository", "revision", "path", "content_digest");
        return new SourceRef(readField(source, "repository", SemanticValues::s), readField(source, "revision", SemanticValues::s),
                readField(source, "path", SemanticValues::s), readField(source, "content_digest", SemanticValues::s), "", Optional.empty());
    }

    public static TypeRef typeRef(WireValue reference, String path) { return readWithin(path, SemanticGraphWire::typeRefValue, reference); }

    private static TypeRef typeRefValue(WireValue reference) {
        closed(reference, "source", "definition_name", "pointer");
        return new TypeRef(readField(reference, "source", SemanticGraphWire::sourceRefValue),
                readField(reference, "definition_name", SemanticValues::s),
                readField(reference, "pointer", value -> readList(value, SemanticValues::s)));
    }

    public static SlotContract slotContract(WireValue value, String path) { return readWithin(path, SemanticGraphWire::slotContractValue, value); }

    private static SlotContract slotContractValue(WireValue value) {
        closed(value, "type_ref", "required", "nullable");
        return new SlotContract(readField(value, "type_ref", SemanticGraphWire::typeRefValue),
                readField(value, "required", SemanticValues::b), readField(value, "nullable", SemanticValues::b));
    }

    public static PathStep pathStep(WireValue step) { return pathStepValue(step); }

    private static PathStep pathStepValue(WireValue step) {
        String tag = tagOf(step);
        return switch (tag) {
            case "Field" -> { closed(step, "tag", "value"); yield new Field(readField(step, "value", SemanticValues::s)); }
            case "Index" -> { closed(step, "tag", "value"); yield new Index(readField(step, "value", SemanticValues::n)); }
            case "Variant" -> { closed(step, "tag", "value"); yield new Variant(readField(step, "value", SemanticValues::s)); }
            default -> throw unknownTag("$.tag", tag);
        };
    }

    public static ProfileRef profileRef(WireValue reference, String path) { return readWithin(path, SemanticGraphWire::profileRefValue, reference); }

    private static ProfileRef profileRefValue(WireValue reference) {
        closed(reference, "identity", "revision", "content_digest");
        return new ProfileRef(readField(reference, "identity", SemanticValues::s), readField(reference, "revision", SemanticValues::s),
                readField(reference, "content_digest", SemanticValues::s));
    }

    static VersionedSemanticProfile profile(WireValue profile, String path) { return readWithin(path, SemanticGraphWire::profileValue, profile); }

    private static VersionedSemanticProfile profileValue(WireValue profile) {
        closed(profile, "reference", "source_refs", "integer_domains", "default_integer_domain", "numbers",
                "grapheme_rules", "format_bindings", "bytes_policy", "wrappers", "tag");
        ProfileRef reference = readField(profile, "reference", SemanticGraphWire::profileRefValue);
        List<SourceRef> sources = readField(profile, "source_refs", value -> readList(value, SemanticGraphWire::sourceIdentityValue));
        List<IntegerDomainBinding> domains = readField(profile, "integer_domains", value -> readList(value, SemanticGraphWire::integerDomainBinding));
        String defaultDomain = readField(profile, "default_integer_domain", SemanticValues::s);
        NumberModel numbers = readField(profile, "numbers", SemanticGraphWire::numberModel);
        Optional<GraphemeRules> graphemeRules = readField(profile, "grapheme_rules", value -> readOption(value, rules -> GraphemeWire.decode(rules, "$")));
        List<FormatBinding> formats = readField(profile, "format_bindings", value -> readList(value, SemanticGraphWire::formatBinding));
        Optional<BytesPolicy> bytes = readField(profile, "bytes_policy", value -> readOption(value, SemanticGraphWire::bytesPolicy));
        List<Wrapper> wrappers = readField(profile, "wrappers", value -> readList(value, SemanticGraphWire::wrapper));
        Optional<TagModel> tagModel = readField(profile, "tag", value -> readOption(value, SemanticGraphWire::tagModel));
        return new VersionedSemanticProfile(reference, sources, List.copyOf(domains), defaultDomain, numbers, graphemeRules, List.copyOf(formats),
                bytes, wrappers, tagModel);
    }

    private static NumberModel numberModel(WireValue model) {
        closed(model, "decimals");
        return new NumberModel(readField(model, "decimals", SemanticValues::b));
    }

    private static IntegerDomainBinding integerDomainBinding(WireValue binding) {
        closed(binding, "name", "reference", "range", "forms");
        return new IntegerDomainBinding(readField(binding, "name", SemanticValues::s),
                readField(binding, "reference", SemanticGraphWire::profileRefValue),
                readField(binding, "range", SemanticGraphWire::integerDomain),
                readField(binding, "forms", value -> readList(value, SemanticGraphWire::integerForm)));
    }

    private static IntegerDomain integerDomain(WireValue range) {
        String tag = tagOf(range);
        return switch (tag) {
            case "Unbounded" -> { closed(range, "tag"); yield new UnboundedDomain(); }
            case "Inclusive" -> {
                WireValue row = fieldsOf(range);
                closed(row, "minimum", "maximum");
                yield new InclusiveDomain(readField(row, "minimum", SemanticValues::i), readField(row, "maximum", SemanticValues::i));
            }
            default -> throw unknownTag("$.tag", tag);
        };
    }

    private static IntegerForm integerForm(WireValue form) {
        String tag = tagOf(form);
        return switch (tag) {
            case "Number" -> { closed(form, "tag"); yield IntegerForm.NUMBER; }
            case "IntegralDecimal" -> { closed(form, "tag"); yield IntegerForm.INTEGRAL_DECIMAL; }
            case "DecimalString" -> { closed(form, "tag"); yield IntegerForm.DECIMAL_STRING; }
            default -> throw unknownTag("$.tag", tag);
        };
    }

    private static FormatBinding formatBinding(WireValue binding) {
        closed(binding, "name", "reference", "rule");
        return new FormatBinding(readField(binding, "name", SemanticValues::s),
                readField(binding, "reference", SemanticGraphWire::profileRefValue),
                readField(binding, "rule", SemanticGraphWire::formatRuleValue));
    }

    private static BytesPolicy bytesPolicy(WireValue policy) {
        closed(policy, "reference", "padding_optional", "alphabet", "strict_pad_bits", "wrapper");
        return new BytesPolicy(readField(policy, "reference", SemanticGraphWire::profileRefValue),
                readField(policy, "padding_optional", SemanticValues::b),
                readField(policy, "alphabet", SemanticGraphWire::bytesAlphabet),
                readField(policy, "strict_pad_bits", SemanticValues::b),
                readField(policy, "wrapper", value -> readOption(value, SemanticValues::s)));
    }

    private static BytesAlphabet bytesAlphabet(WireValue alphabet) {
        String tag = tagOf(alphabet);
        return switch (tag) {
            case "Standard" -> { closed(alphabet, "tag"); yield BytesAlphabet.STANDARD; }
            case "UrlSafe" -> { closed(alphabet, "tag"); yield BytesAlphabet.URL_SAFE; }
            case "Either" -> { closed(alphabet, "tag"); yield BytesAlphabet.EITHER; }
            default -> throw unknownTag("$.tag", tag);
        };
    }

    private static Wrapper wrapper(WireValue wrapper) {
        closed(wrapper, "name", "key", "payload");
        return new Wrapper(readField(wrapper, "name", SemanticValues::s), readField(wrapper, "key", SemanticValues::s),
                readField(wrapper, "payload", SemanticGraphWire::wrapperPayload));
    }

    private static WrapperPayload wrapperPayload(WireValue payload) {
        String tag = tagOf(payload);
        return switch (tag) {
            case "Bytes" -> { closed(payload, "tag"); yield new BytesPayload(); }
            case "Text" -> new TextPayload(readOption(payloadOf(payload), SemanticValues::s));
            default -> throw unknownTag("$.tag", tag);
        };
    }

    private static TagModel tagModel(WireValue tagModel) {
        closed(tagModel, "key", "format", "sealed");
        return new TagModel(readField(tagModel, "key", SemanticValues::s),
                readField(tagModel, "format", value -> readOption(value, SemanticValues::s)),
                readField(tagModel, "sealed", value -> readList(value, SemanticGraphWire::sealedForm)));
    }

    private static SealedForm sealedForm(WireValue form) {
        closed(form, "tag", "fields", "extras");
        String tag = readField(form, "tag", SemanticValues::s);
        List<SealedField> fields = readField(form, "fields", value -> readList(value, SemanticGraphWire::sealedField));
        SealedExtras extras = readField(form, "extras", SemanticGraphWire::sealedExtras);
        return new SealedForm(tag, List.copyOf(fields), extras);
    }

    private static SealedField sealedField(WireValue field) {
        closed(field, "key", "required", "leaf");
        return new SealedField(readField(field, "key", SemanticValues::s), readField(field, "required", SemanticValues::b),
                readField(field, "leaf", SemanticGraphWire::sealedLeaf));
    }

    private static SealedLeaf sealedLeaf(WireValue leaf) {
        String tag = tagOf(leaf);
        return switch (tag) {
            case "String" -> new StringLeaf(stringSpec(payloadOf(leaf)));
            case "Integer" -> new IntegerLeaf(integerSpec(payloadOf(leaf)));
            default -> throw unknownTag("$.tag", tag);
        };
    }

    private static SealedExtras sealedExtras(WireValue extras) {
        String tag = tagOf(extras);
        return switch (tag) {
            case "Reject" -> { closed(extras, "tag"); yield SealedExtras.REJECT; }
            case "Any" -> { closed(extras, "tag"); yield SealedExtras.ANY; }
            default -> throw unknownTag("$.tag", tag);
        };
    }

    private static FormatUse formatUse(WireValue use) {
        String tag = tagOf(use);
        return switch (tag) {
            case "Named" -> new NamedFormat(SemanticValues.s(payloadOf(use)));
            case "Inline" -> new InlineFormat(formatRuleValue(payloadOf(use)));
            default -> throw unknownTag("$.tag", tag);
        };
    }

    private static Optional<FormatUse> optionalFormatUse(WireValue use) {
        return readOption(use, SemanticGraphWire::formatUse);
    }

    private static StringSpec stringSpec(WireValue spec) {
        closed(spec, "format", "lengths", "wrapper", "const_value", "enum_values", "examples", "default_value");
        return new StringSpec(readField(spec, "format", SemanticGraphWire::optionalFormatUse),
                readField(spec, "lengths", value -> readList(value, SemanticGraphWire::lengthBound)),
                readField(spec, "wrapper", value -> readOption(value, SemanticValues::s)),
                readField(spec, "const_value", value -> readOption(value, SemanticValues::s)),
                readField(spec, "enum_values", value -> readOption(value, items -> List.copyOf(readList(items, SemanticValues::s)))),
                readField(spec, "examples", value -> readList(value, SemanticValues::s)),
                readField(spec, "default_value", value -> readOption(value, SemanticValues::s)));
    }

    private static LengthBound lengthBound(WireValue bound) {
        closed(bound, "unit", "minimum", "maximum");
        return new LengthBound(readField(bound, "unit", SemanticGraphWire::lengthUnit),
                readField(bound, "minimum", value -> readOption(value, SemanticValues::n)),
                readField(bound, "maximum", value -> readOption(value, SemanticValues::n)));
    }

    private static StringLengthUnit lengthUnit(WireValue unit) {
        String tag = tagOf(unit);
        return switch (tag) {
            case "Utf8Bytes" -> { closed(unit, "tag"); yield StringLengthUnit.UTF8_BYTES; }
            case "UnicodeScalars" -> { closed(unit, "tag"); yield StringLengthUnit.UNICODE_SCALARS; }
            case "Graphemes" -> { closed(unit, "tag"); yield StringLengthUnit.GRAPHEMES; }
            default -> throw unknownTag("$.tag", tag);
        };
    }

    private static IntegerSpec integerSpec(WireValue spec) {
        closed(spec, "domain", "minimum", "maximum", "const_value", "enum_values", "default_value");
        return new IntegerSpec(readField(spec, "domain", value -> readOption(value, SemanticValues::s)),
                readField(spec, "minimum", value -> readOption(value, SemanticValues::i)),
                readField(spec, "maximum", value -> readOption(value, SemanticValues::i)),
                readField(spec, "const_value", value -> readOption(value, SemanticValues::i)),
                readField(spec, "enum_values", value -> readOption(value, items -> List.copyOf(readList(items, SemanticValues::i)))),
                readField(spec, "default_value", value -> readOption(value, SemanticValues::i)));
    }

    private static BooleanSpec booleanSpec(WireValue spec) {
        closed(spec, "const_value", "default_value");
        return new BooleanSpec(readField(spec, "const_value", value -> readOption(value, SemanticValues::b)),
                readField(spec, "default_value", value -> readOption(value, SemanticValues::b)));
    }

    private static DecimalBound decimalBound(WireValue bound) {
        closed(bound, "mantissa", "scale", "exclusive");
        return new DecimalBound(readField(bound, "mantissa", SemanticValues::i), readField(bound, "scale", SemanticValues::n),
                readField(bound, "exclusive", SemanticValues::b));
    }

    private static DecimalSpec decimalSpec(WireValue spec) {
        closed(spec, "minimum", "maximum");
        return new DecimalSpec(readField(spec, "minimum", value -> readOption(value, SemanticGraphWire::decimalBound)),
                readField(spec, "maximum", value -> readOption(value, SemanticGraphWire::decimalBound)));
    }

    private static LengthSpec lengthSpec(WireValue spec) {
        closed(spec, "minimum", "maximum");
        return new LengthSpec(readField(spec, "minimum", value -> readOption(value, SemanticValues::n)),
                readField(spec, "maximum", value -> readOption(value, SemanticValues::n)));
    }

    private static ElementContract elementValue(WireValue contract) {
        closed(contract, "type_ref", "nullable");
        return new ElementContract(readField(contract, "type_ref", SemanticGraphWire::typeRefValue),
                readField(contract, "nullable", SemanticValues::b));
    }

    private static FieldSpec fieldSpec(WireValue field) {
        closed(field, "wire_name", "slot", "origin");
        return new FieldSpec(readField(field, "wire_name", SemanticValues::s),
                readField(field, "slot", SemanticGraphWire::slotContractValue),
                readField(field, "origin", SemanticGraphWire::occurrenceValue));
    }

    private static <T> T spec(WireValue shape, String member, GraphReading reading, SemanticValues.WireReader<T> reader) {
        closed(shape, "tag", member);
        return reading.namedMembers() ? readField(shape, member, reader) : reader.read(((ObjectValue) shape).get(member));
    }

    private static ProductSpec productSpec(WireValue spec, GraphReading reading) {
        closed(spec, "fields", "extras");
        return new ProductSpec(List.copyOf(readField(spec, "fields", value -> readList(value, SemanticGraphWire::fieldSpec))),
                readField(spec, "extras", value -> extraMembers(value, reading)));
    }

    private static ExtraMembers extraMembers(WireValue extras, GraphReading reading) {
        String tag = tagOf(extras);
        return switch (tag) {
            case "Reject" -> { closed(extras, "tag"); yield new RejectExtras(); }
            case "Allow" -> spec(extras, "fields", reading, SemanticGraphWire::allowExtras);
            default -> throw unknownTag("$.tag", tag);
        };
    }

    private static AllowExtras allowExtras(WireValue body) {
        closed(body, "key_format", "value");
        return new AllowExtras(readField(body, "key_format", SemanticGraphWire::optionalFormatUse),
                readField(body, "value", SemanticGraphWire::elementValue));
    }

    private static ArraySpec arraySpec(WireValue spec) {
        closed(spec, "item", "min_length", "max_length");
        return new ArraySpec(readField(spec, "item", SemanticGraphWire::elementValue),
                readField(spec, "min_length", value -> readOption(value, SemanticValues::n)),
                readField(spec, "max_length", value -> readOption(value, SemanticValues::n)));
    }

    private static UnionSpec unionSpec(WireValue spec) {
        closed(spec, "branches");
        return new UnionSpec(readField(spec, "branches", value -> readList(value, SemanticGraphWire::unionBranch)));
    }

    private static UnionBranch unionBranch(WireValue branch) {
        closed(branch, "target", "wire_tag", "selector", "origin");
        return new UnionBranch(readField(branch, "target", SemanticGraphWire::typeRefValue),
                readField(branch, "wire_tag", SemanticValues::s),
                readField(branch, "selector", SemanticGraphWire::selectorValue),
                readField(branch, "origin", SemanticGraphWire::occurrenceValue));
    }

    private static SealedRefinement sealedRefinement(WireValue refinement) {
        closed(refinement, "key", "leaf");
        return new SealedRefinement(readField(refinement, "key", SemanticValues::s), readField(refinement, "leaf", SemanticGraphWire::sealedLeaf));
    }

    private static UnknownKind unknownKind(WireValue kind) {
        String tag = tagOf(kind);
        return switch (tag) {
            case "Any" -> { closed(kind, "tag"); yield UnknownKind.ANY; }
            case "OrdinaryObject" -> { closed(kind, "tag"); yield UnknownKind.ORDINARY_OBJECT; }
            default -> throw unknownTag("$.tag", tag);
        };
    }

    private static TypeShape shapeValue(WireValue shape, GraphReading reading) {
        String tag = tagOf(shape);
        if (!reading.shapeTags().contains(tag)) throw unknownTag("$.tag", tag);
        return switch (tag) {
            case "Boolean" -> new BooleanShape(spec(shape, "value", reading, SemanticGraphWire::booleanSpec));
            case "Integer" -> new IntegerShape(spec(shape, "value", reading, SemanticGraphWire::integerSpec));
            case "Decimal" -> new DecimalShape(spec(shape, "value", reading, SemanticGraphWire::decimalSpec));
            case "String" -> new StringShape(spec(shape, "value", reading, SemanticGraphWire::stringSpec));
            case "Bytes" -> new BytesShape(spec(shape, "value", reading, SemanticGraphWire::lengthSpec));
            case "Product" -> new ProductShape(spec(shape, "value", reading, value -> productSpec(value, reading)));
            case "Array" -> new ArrayShape(spec(shape, "value", reading, SemanticGraphWire::arraySpec));
            case "TaggedUnion" -> new TaggedUnionShape(spec(shape, "value", reading, SemanticGraphWire::unionSpec));
            case "Sealed" -> spec(shape, "fields", reading, SemanticGraphWire::sealedShape);
            case "Never" -> { closed(shape, "tag"); yield new NeverShape(); }
            case "Alias" -> spec(shape, "fields", reading, SemanticGraphWire::aliasShape);
            case "Unknown" -> new UnknownShape(spec(shape, "value", reading, SemanticGraphWire::unknownKind));
            case "Unit" -> { closed(shape, "tag"); yield new UnitShape(); }
            case "RawBody" -> spec(shape, "fields", reading, SemanticGraphWire::rawBodyShape);
            case "Opaque" -> spec(shape, "fields", reading, SemanticGraphWire::opaqueShape);
            default -> throw unknownTag("$.tag", tag);
        };
    }

    public static TypeShape shape(WireValue shape) { return shapeValue(shape, GraphReading.CANONICAL); }

    private static SealedShape sealedShape(WireValue spec) {
        closed(spec, "tag", "refinements");
        return new SealedShape(readField(spec, "tag", SemanticValues::s),
                readField(spec, "refinements", value -> readList(value, SemanticGraphWire::sealedRefinement)));
    }

    private static AliasShape aliasShape(WireValue spec) {
        closed(spec, "target", "reference_text");
        return new AliasShape(readField(spec, "target", SemanticGraphWire::typeRefValue), readField(spec, "reference_text", SemanticValues::s));
    }

    private static RawBodyShape rawBodyShape(WireValue spec) {
        closed(spec, "encoding");
        return new RawBodyShape(readField(spec, "encoding", SemanticValues::s));
    }

    private static OpaqueShape opaqueShape(WireValue spec) {
        closed(spec, "type_name");
        return new OpaqueShape(readField(spec, "type_name", SemanticValues::s));
    }

    private static OccurrenceRef occurrenceValue(WireValue value) {
        closed(value, "source", "pointer");
        return new OccurrenceRef(readField(value, "source", SemanticGraphWire::sourceRefValue),
                readField(value, "pointer", items -> readList(items, SemanticValues::s)));
    }

    private static BranchSelector selectorValue(WireValue selector) {
        String tag = tagOf(selector);
        return switch (tag) {
            case "InternalTag" -> { closed(selector, "tag"); yield new InternalTagSelector(); }
            case "MemberShape" -> new MemberShapeSelector(readPlainList(payloadOf(selector), SemanticGraphWire::memberCheck));
            case "Kind" -> new KindSelector(valueKind(payloadOf(selector)));
            case "Otherwise" -> { closed(selector, "tag"); yield new OtherwiseSelector(); }
            default -> throw unknownTag("$.tag", tag);
        };
    }

    private static MemberCheck memberCheck(WireValue check) {
        closed(check, "key", "test");
        return new MemberCheck(readField(check, "key", SemanticValues::s), readField(check, "test", SemanticGraphWire::memberTest));
    }

    private static MemberTest memberTest(WireValue test) {
        String tag = tagOf(test);
        return switch (tag) {
            case "Absent" -> { closed(test, "tag"); yield new AbsentTest(); }
            case "Format" -> new FormatTest(SemanticValues.s(payloadOf(test)));
            default -> throw unknownTag("$.tag", tag);
        };
    }

    private static ValueKind valueKind(WireValue kind) {
        String tag = tagOf(kind);
        return switch (tag) {
            case "Null" -> { closed(kind, "tag"); yield ValueKind.NULL; }
            case "Boolean" -> { closed(kind, "tag"); yield ValueKind.BOOLEAN; }
            case "Number" -> { closed(kind, "tag"); yield ValueKind.NUMBER; }
            case "String" -> { closed(kind, "tag"); yield ValueKind.STRING; }
            case "Array" -> { closed(kind, "tag"); yield ValueKind.ARRAY; }
            case "Object" -> { closed(kind, "tag"); yield ValueKind.OBJECT; }
            default -> throw unknownTag("$.tag", tag);
        };
    }

    public static FormatRule formatRule(WireValue rule) { return formatRuleValue(rule); }


    private static FormatRule formatRuleValue(WireValue rule) {
        String tag = tagOf(rule);
        return switch (tag) {
            case "Literal" -> new LiteralRule(SemanticValues.s(payloadOf(rule)));
            case "Sequence" -> new SequenceRule(readPlainList(payloadOf(rule), SemanticGraphWire::formatRuleValue));
            case "Optional" -> new OptionalRule(formatRuleValue(payloadOf(rule)));
            case "Labels" -> {
                WireValue row = fieldsOf(rule);
                closed(row, "separator", "min_count", "max_count", "total_max", "rule");
                yield new LabelsRule(readField(row, "separator", SemanticValues::s), readField(row, "min_count", SemanticValues::n),
                        readField(row, "max_count", value -> readOption(value, SemanticValues::n)),
                        readField(row, "total_max", value -> readOption(value, SemanticValues::n)),
                        formatRuleValue(member(row, "rule")));
            }
            case "Bounded" -> {
                WireValue row = fieldsOf(rule);
                closed(row, "unit", "maximum", "rule");
                yield new BoundedRule(readField(row, "unit", SemanticGraphWire::lengthUnit), readField(row, "maximum", SemanticValues::n),
                        formatRuleValue(member(row, "rule")));
            }
            case "AsciiDfa" -> new AsciiDfaRule(dfaSpec(payloadOf(rule)));
            case "Timestamp" -> new TimestampRule(calendarRule(payloadOf(rule)));
            case "Choice" -> new ChoiceRule(readPlainList(payloadOf(rule), SemanticGraphWire::formatRuleValue));
            case "Identifier" -> {
                WireValue row = fieldsOf(rule);
                closed(row, "first_alphabet", "rest_alphabet", "exact_length", "min_length", "max_length", "forbidden");
                yield new IdentifierRule(readField(row, "first_alphabet", SemanticValues::s), readField(row, "rest_alphabet", SemanticValues::s),
                        readField(row, "exact_length", value -> readOption(value, SemanticValues::n)), readField(row, "min_length", SemanticValues::n),
                        readField(row, "max_length", value -> readOption(value, SemanticValues::n)),
                        readField(row, "forbidden", value -> readList(value, SemanticValues::s)));
            }
            case "AbsoluteUri" -> {
                WireValue row = fieldsOf(rule);
                closed(row, "max_bytes");
                yield new AbsoluteUriRule(readField(row, "max_bytes", value -> readOption(value, SemanticValues::n)));
            }
            case "LanguageTag" -> {
                WireValue row = fieldsOf(rule);
                closed(row, "grandfathered");
                yield new LanguageTagRule(readField(row, "grandfathered", value -> readList(value, SemanticValues::s)));
            }
            case "Text" -> { closed(rule, "tag"); yield new TextRule(); }
            case "Not" -> new NotRule(formatRuleValue(payloadOf(rule)));
            default -> throw unknownTag("$.tag", tag);
        };
    }

    private static WireValue member(WireValue row, String key) {
        return ((ObjectValue) row).get(key);
    }

    private static DfaSpec dfaSpec(WireValue spec) {
        closed(spec, "state_count", "initial_state", "accepting_states", "transitions");
        return new DfaSpec(readField(spec, "state_count", SemanticValues::n), readField(spec, "initial_state", SemanticValues::n),
                readField(spec, "accepting_states", value -> readList(value, SemanticValues::n)),
                readField(spec, "transitions", value -> readList(value, SemanticGraphWire::dfaTransition)));
    }

    private static DfaTransition dfaTransition(WireValue row) {
        closed(row, "from_state", "first", "last", "to_state");
        return new DfaTransition(readField(row, "from_state", SemanticValues::n), readField(row, "first", SemanticValues::n),
                readField(row, "last", SemanticValues::n), readField(row, "to_state", SemanticValues::n));
    }

    private static CalendarRule calendarRule(WireValue rule) {
        closed(rule, "allow_second_60", "minimum_year", "maximum_year", "rejectUtcYearOutsideRange");
        return new CalendarRule(readField(rule, "allow_second_60", SemanticValues::b), readField(rule, "minimum_year", SemanticValues::n),
                readField(rule, "maximum_year", SemanticValues::n), readField(rule, "rejectUtcYearOutsideRange", SemanticValues::b));
    }

    public static boolean formatAccepts(Optional<SemanticTypes.GraphemeRules> graphemeRules, WireValue rule, String text) {
        return rule != null && SemanticValidation.formatAcceptsFast(graphemeRules, formatRule(rule), text);
    }

    public static SemanticObligation obligation(WireValue obligation, String path) { return readWithin(path, SemanticGraphWire::obligationValue, obligation); }

    private static SemanticObligation obligationValue(WireValue obligation) {
        closed(obligation, "type_ref", "origin", "value_path", "profile", "reason");
        TypeRef typeRef = readField(obligation, "type_ref", SemanticGraphWire::typeRefValue);
        OccurrenceRef origin = readField(obligation, "origin", SemanticGraphWire::occurrenceValue);
        List<PathStep> valuePath = readField(obligation, "value_path", value -> readList(value, SemanticGraphWire::pathStepValue));
        ProfileRef profile = readField(obligation, "profile", SemanticGraphWire::profileRefValue);
        SemanticReason reason = readField(obligation, "reason", SemanticGraphWire::reasonValue);
        return new SemanticObligation(typeRef, origin, valuePath, profile, reason);
    }

    public static EvaluationProvenance evaluationProvenance(WireValue provenance, String path) {
        return readWithin(path, SemanticGraphWire::evaluationProvenanceValue, provenance);
    }

    private static EvaluationProvenance evaluationProvenanceValue(WireValue provenance) {
        closed(provenance, "operation", "type_ref", "value_path");
        return new EvaluationProvenance(readField(provenance, "operation", SemanticValues::s),
                readField(provenance, "type_ref", SemanticGraphWire::typeRefValue),
                readField(provenance, "value_path", value -> readList(value, SemanticGraphWire::pathStepValue)));
    }

    public static SemanticReason reason(WireValue reason, String path) { return readWithin(path, SemanticGraphWire::reasonValue, reason); }

    private static SemanticReason reasonValue(WireValue reason) {
        String tag = tagOf(reason);
        return switch (tag) {
            case "UnknownFormat" -> new UnknownFormat(reasonArgument(reason));
            case "MissingGraphemeRules" -> { closed(reason, "tag"); yield new MissingGraphemeRules(); }
            case "MissingBytesPolicy" -> { closed(reason, "tag"); yield new MissingBytesPolicy(); }
            case "UnknownIntegerDomain" -> new UnknownIntegerDomain(reasonArgument(reason));
            case "UnknownWrapper" -> new UnknownWrapper(reasonArgument(reason));
            case "WrapperPayload" -> new WrapperPayloadReason(reasonArgument(reason));
            case "UnknownSealedTag" -> new UnknownSealedTag(reasonArgument(reason));
            case "DecimalNotAdmitted" -> { closed(reason, "tag"); yield new DecimalNotAdmitted(); }
            case "IntegerBound" -> { closed(reason, "tag"); yield new IntegerBound(); }
            case "OpaqueType" -> new OpaqueType(reasonArgument(reason));
            case "MissingTagModel" -> { closed(reason, "tag"); yield new MissingTagModel(); }
            case "UninterpretedExtension" -> new UninterpretedExtension(reasonArgument(reason));
            case "UnresolvedType" -> { closed(reason, "tag"); yield new UnresolvedType(); }
            case "InvalidProfile" -> new InvalidProfile(reasonArgument(reason));
            case "MembershipBound" -> { closed(reason, "tag"); yield new MembershipBound(); }
            case "CertificateMismatch" -> new CertificateMismatchReason(reasonArgument(reason));
            case "ProjectionUnavailable" -> new ProjectionUnavailable(reasonArgument(reason));
            default -> throw unknownTag("$.tag", tag);
        };
    }

    private static String reasonArgument(WireValue reason) {
        closed(reason, "tag", "value");
        return readField(reason, "value", SemanticValues::s);
    }

    public static WireValue sourceRefWire(SourceRef source) {
        return obj("repository", str(source.repository()), "revision", str(source.revision()), "path", str(source.path()),
                "content_digest", str(source.contentDigest()), "document_id", str(source.documentId()),
                "declared_revision", naturalText(source.declaredRevision()));
    }
    public static WireValue typeRefWire(TypeRef reference) {
        return obj("source", sourceRefWire(reference.source()), "definition_name", str(reference.definitionName()),
                "pointer", arr(reference.pointer().stream().map(SemanticValues::str).toList()));
    }
    public static WireValue pathStepWire(PathStep step) {
        if (step instanceof Field field) return variant("Field", str(field.wireName()));
        if (step instanceof Index index) return variant("Index", str(index.index().toString()));
        return variant("Variant", str(((Variant) step).wireTag()));
    }
    public static WireValue profileRefWire(ProfileRef reference) {
        return obj("identity", str(reference.identity()), "revision", str(reference.revision()),
                "content_digest", str(reference.contentDigest()));
    }

    public static WireValue obligationWire(SemanticObligation obligation) {
        return obj("type_ref", typeRefWire(obligation.typeRef()),
                "origin", obj("source", sourceRefWire(obligation.origin().source()),
                        "pointer", arr(obligation.origin().pointer().stream().map(SemanticValues::str).toList())),
                "value_path", arr(obligation.valuePath().stream().map(SemanticGraphWire::pathStepWire).toList()),
                "profile", profileRefWire(obligation.profile()), "reason", reasonWire(obligation.reason()));
    }

    private static WireValue reasonWire(SemanticReason reason) {
        return switch (reason) {
            case UnknownFormat value -> variant("UnknownFormat", str(value.name()));
            case MissingGraphemeRules unused -> variant("MissingGraphemeRules");
            case MissingBytesPolicy unused -> variant("MissingBytesPolicy");
            case UnknownIntegerDomain value -> variant("UnknownIntegerDomain", str(value.name()));
            case UnknownWrapper value -> variant("UnknownWrapper", str(value.name()));
            case WrapperPayloadReason value -> variant("WrapperPayload", str(value.name()));
            case UnknownSealedTag value -> variant("UnknownSealedTag", str(value.tag()));
            case DecimalNotAdmitted unused -> variant("DecimalNotAdmitted");
            case IntegerBound unused -> variant("IntegerBound");
            case OpaqueType value -> variant("OpaqueType", str(value.name()));
            case MissingTagModel unused -> variant("MissingTagModel");
            case UnresolvedType unused -> variant("UnresolvedType");
            case MembershipBound unused -> variant("MembershipBound");
            case UninterpretedExtension value -> variant("UninterpretedExtension", str(value.key()));
            case InvalidProfile value -> variant("InvalidProfile", str(value.condition()));
            case ProjectionUnavailable value -> variant("ProjectionUnavailable", str(value.condition()));
            case CertificateMismatchReason value -> variant("CertificateMismatch", str(value.condition()));
        };
    }
    private static WireValue lengthUnitWire(StringLengthUnit unit) {
        return variant(switch (unit) {
            case UTF8_BYTES -> "Utf8Bytes";
            case UNICODE_SCALARS -> "UnicodeScalars";
            case GRAPHEMES -> "Graphemes";
        });
    }

    private static WireValue optionalNatural(Optional<BigInteger> value) {
        return value.<WireValue>map(SemanticGraphWire::decimalText).orElse(NIL);
    }

    /** The wire form of a rule. One call converts each rule object once, and keeps nothing after it returns. */
    public static WireValue formatRuleWire(FormatRule rule) {
        return formatRuleWire(rule, new java.util.IdentityHashMap<>());
    }

    private static WireValue formatRuleWire(FormatRule rule, java.util.Map<FormatRule, WireValue> converted) {
        WireValue cached = converted.get(rule);
        if (cached != null) return cached;
        WireValue encoded = switch (rule) {
            case LiteralRule value -> variant("Literal", str(value.value()));
            case SequenceRule value -> variant("Sequence", arr(value.parts().stream().map(part -> formatRuleWire(part, converted)).toList()));
            case OptionalRule value -> variant("Optional", formatRuleWire(value.rule(), converted));
            case LabelsRule value -> SemanticValues.fields("Labels", obj("separator", str(value.separator()),
                    "min_count", decimalText(value.minCount()), "max_count", optionalNatural(value.maxCount()),
                    "total_max", optionalNatural(value.totalMax()), "rule", formatRuleWire(value.rule(), converted)));
            case BoundedRule value -> SemanticValues.fields("Bounded", obj("unit", lengthUnitWire(value.unit()),
                    "maximum", decimalText(value.maximum()), "rule", formatRuleWire(value.rule(), converted)));
            case AsciiDfaRule value -> variant("AsciiDfa", obj("state_count", decimalText(value.spec().stateCount()),
                    "initial_state", decimalText(value.spec().initialState()),
                    "accepting_states", arr(value.spec().acceptingStates().stream().map(state -> decimalText(state)).toList()),
                    "transitions", arr(value.spec().transitions().stream().map(row -> obj("from_state", decimalText(row.fromState()),
                            "first", decimalText(row.first()), "last", decimalText(row.last()), "to_state", decimalText(row.toState()))).toList())));
            case IdentifierRule value -> SemanticValues.fields("Identifier", obj("first_alphabet", str(value.firstAlphabet()),
                    "rest_alphabet", str(value.restAlphabet()), "exact_length", optionalNatural(value.exactLength()),
                    "min_length", decimalText(value.minLength()), "max_length", optionalNatural(value.maxLength()),
                    "forbidden", arr(value.forbidden().stream().map(SemanticValues::str).toList())));
            case TimestampRule value -> variant("Timestamp", obj("allow_second_60", new SemanticValues.BooleanValue(value.rule().allowSecond60()),
                    "minimum_year", decimalText(value.rule().minimumYear()), "maximum_year", decimalText(value.rule().maximumYear()),
                    "rejectUtcYearOutsideRange", new SemanticValues.BooleanValue(value.rule().rejectUtcYearOutsideRange())));
            case AbsoluteUriRule value -> SemanticValues.fields("AbsoluteUri", obj("max_bytes", optionalNatural(value.maxBytes())));
            case LanguageTagRule value -> SemanticValues.fields("LanguageTag", obj("grandfathered",
                    arr(value.grandfathered().stream().map(SemanticValues::str).toList())));
            case ChoiceRule value -> variant("Choice", arr(value.rules().stream().map(part -> formatRuleWire(part, converted)).toList()));
            case TextRule unused -> variant("Text");
            case NotRule value -> variant("Not", formatRuleWire(value.rule(), converted));
        };
        converted.put(rule, encoded);
        return encoded;
    }
    private static WireValue naturalText(Optional<BigInteger> value) {
        return value.<WireValue>map(number -> str(number.toString())).orElse(NIL);
    }

    private static WireValue decimalText(BigInteger value) {
        return str(value.toString());
    }

    private static WireValue optionalText(Optional<String> value) {
        return value.<WireValue>map(text -> str(text)).orElse(NIL);
    }

    private static WireValue occurrenceWire(OccurrenceRef occurrence) {
        return obj("source", sourceRefWire(occurrence.source()), "pointer", arr(occurrence.pointer().stream().map(SemanticValues::str).toList()));
    }

    private static WireValue formatUseWire(Optional<FormatUse> use, java.util.Map<FormatRule, WireValue> converted) {
        if (use.isEmpty()) return NIL;
        if (use.get() instanceof NamedFormat named) return variant("Named", str(named.name()));
        return variant("Inline", formatRuleWire(((InlineFormat) use.get()).rule(), converted));
    }

    private static WireValue integerSpecWire(IntegerSpec spec) {
        return obj("domain", optionalText(spec.domain()), "minimum", naturalText(spec.minimum()),
                "maximum", naturalText(spec.maximum()), "const_value", naturalText(spec.constValue()),
                "enum_values", spec.enumValues().<WireValue>map(values -> arr(values.stream().map(value -> str(value.toString())).toList())).orElse(NIL),
                "default_value", naturalText(spec.defaultValue()));
    }

    private static WireValue stringSpecWire(StringSpec spec, java.util.Map<FormatRule, WireValue> converted) {
        return obj("format", formatUseWire(spec.format(), converted),
                "lengths", arr(spec.lengths().stream().map(bound -> obj("unit", lengthUnitWire(bound.unit()),
                        "minimum", naturalText(bound.minimum()), "maximum", naturalText(bound.maximum()))).toList()),
                "wrapper", optionalText(spec.wrapper()), "const_value", optionalText(spec.constValue()),
                "enum_values", spec.enumValues().<WireValue>map(values -> arr(values.stream().map(SemanticValues::str).toList())).orElse(NIL),
                "examples", arr(spec.examples().stream().map(SemanticValues::str).toList()),
                "default_value", optionalText(spec.defaultValue()));
    }

    private static WireValue sealedLeafWire(SealedLeaf leaf, java.util.Map<FormatRule, WireValue> converted) {
        return leaf instanceof StringLeaf string ? variant("String", stringSpecWire(string.spec(), converted))
                : variant("Integer", integerSpecWire(((IntegerLeaf) leaf).spec()));
    }

    private static WireValue elementWire(ElementContract contract) {
        return obj("type_ref", typeRefWire(contract.typeRef()), "nullable", new SemanticValues.BooleanValue(contract.nullable()));
    }

    private static WireValue decimalBoundWire(Optional<DecimalBound> bound) {
        return bound.<WireValue>map(value -> obj("mantissa", str(value.mantissa().toString()), "scale", str(value.scale().toString()),
                "exclusive", new SemanticValues.BooleanValue(value.exclusive()))).orElse(NIL);
    }

    private static WireValue selectorWire(BranchSelector selector) {
        return switch (selector) {
            case InternalTagSelector unused -> variant("InternalTag");
            case MemberShapeSelector shaped -> variant("MemberShape", arr(shaped.tests().stream().map(check -> obj("key", str(check.key()),
                    "test", check.test() instanceof AbsentTest ? variant("Absent") : variant("Format", str(((FormatTest) check.test()).name())))).toList()));
            case KindSelector kind -> variant("Kind", variant(switch (kind.kind()) {
                case NULL -> "Null";
                case BOOLEAN -> "Boolean";
                case NUMBER -> "Number";
                case STRING -> "String";
                case ARRAY -> "Array";
                case OBJECT -> "Object";
            }));
            case OtherwiseSelector unused -> variant("Otherwise");
        };
    }

    public static WireValue shapeWire(TypeShape shape) {
        java.util.Map<FormatRule, WireValue> converted = new java.util.IdentityHashMap<>();
        return switch (shape) {
            case BooleanShape value -> variant("Boolean", obj("const_value",
                    value.spec().constValue().<WireValue>map(constant -> new SemanticValues.BooleanValue(constant)).orElse(NIL),
                    "default_value", value.spec().defaultValue().<WireValue>map(constant -> new SemanticValues.BooleanValue(constant)).orElse(NIL)));
            case IntegerShape value -> variant("Integer", integerSpecWire(value.spec()));
            case DecimalShape value -> variant("Decimal", obj("minimum", decimalBoundWire(value.spec().minimum()),
                    "maximum", decimalBoundWire(value.spec().maximum())));
            case StringShape value -> variant("String", stringSpecWire(value.spec(), converted));
            case BytesShape value -> variant("Bytes", obj("minimum", naturalText(value.spec().minimum()), "maximum", naturalText(value.spec().maximum())));
            case ProductShape value -> variant("Product", obj("fields", arr(value.spec().fields().stream().map(field -> obj(
                    "wire_name", str(field.wireName()),
                    "slot", obj("type_ref", typeRefWire(field.slot().typeRef()), "required", new SemanticValues.BooleanValue(field.slot().required()),
                            "nullable", new SemanticValues.BooleanValue(field.slot().nullable())),
                    "origin", occurrenceWire(field.origin()))).toList()),
                    "extras", value.spec().extras() instanceof AllowExtras allow
                            ? SemanticValues.fields("Allow", obj("key_format", formatUseWire(allow.keyFormat(), converted), "value", elementWire(allow.value())))
                            : variant("Reject")));
            case ArrayShape value -> variant("Array", obj("item", elementWire(value.spec().item()),
                    "min_length", naturalText(value.spec().minLength()), "max_length", naturalText(value.spec().maxLength())));
            case AliasShape value -> SemanticValues.fields("Alias", obj("target", typeRefWire(value.target()), "reference_text", str(value.referenceText())));
            case TaggedUnionShape value -> variant("TaggedUnion", obj("branches", arr(value.spec().branches().stream().map(branch -> obj(
                    "target", typeRefWire(branch.target()), "wire_tag", str(branch.wireTag()),
                    "selector", selectorWire(branch.selector()), "origin", occurrenceWire(branch.origin()))).toList())));
            case SealedShape value -> SemanticValues.fields("Sealed", obj("tag", str(value.tag()),
                    "refinements", arr(value.refinements().stream().map(refinement -> obj("key", str(refinement.key()),
                            "leaf", sealedLeafWire(refinement.leaf(), converted))).toList())));
            case NeverShape unused -> variant("Never");
            case UnknownShape value -> variant("Unknown", variant(value.kind() == UnknownKind.ANY ? "Any" : "OrdinaryObject"));
            case UnitShape unused -> variant("Unit");
            case RawBodyShape value -> SemanticValues.fields("RawBody", obj("encoding", str(value.encoding())));
            case OpaqueShape value -> SemanticValues.fields("Opaque", obj("type_name", str(value.typeName())));
        };
    }
}
