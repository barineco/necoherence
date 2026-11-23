// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import java.math.BigInteger;
import java.util.ArrayDeque;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import necoherence.composition.SemanticComposition.TypeRef;
import necoherence.semantic.SemanticFormats.Program;
import necoherence.semantic.SemanticGraphemes.Table;
import necoherence.semantic.SemanticTypes.*;

final class ValidationTables {
    private static final int ENUM_INDEX_SIZE = 16;

    final SemanticGraph graph;
    final VersionedSemanticProfile profile;
    private final Map<String, FormatBinding> formats;
    private final Map<String, IntegerDomainBinding> domains;
    private final Optional<Table> graphemes;
    private final Map<List<?>, Set<?>> enums;
    private final Map<SealedForm, Set<String>> sealedKeys;
    private final Map<ProductSpec, Set<String>> fieldNames;
    private final Map<ProductSpec, Map<String, FieldSpec>> fields;
    private final Map<FormatRule, Program> programs;
    private final Set<TypeRef> clean;

    static ValidationTables of(SemanticGraph graph) { return new ValidationTables(graph); }

    static ValidationTables of(VersionedSemanticProfile profile) {
        return new ValidationTables(new SemanticGraph(profile, List.of(), List.of()));
    }

    private ValidationTables(SemanticGraph graph) {
        this.graph = graph;
        this.profile = graph.profile();
        this.formats = Collections.unmodifiableMap(formatIndex(profile));
        this.domains = Collections.unmodifiableMap(domainIndex(profile));
        this.graphemes = profile.graphemeRules().flatMap(ValidationTables::tryTable);
        Collector collector = new Collector();
        for (FormatBinding binding : profile.formatBindings()) collector.rule(binding.rule());
        if (profile.tag().isPresent()) {
            for (SealedForm form : profile.tag().get().sealed()) {
                collector.sealed(form);
                for (SealedField field : form.fields()) collector.leaf(field.leaf());
            }
        }
        for (TypeNode node : graph.nodes()) collector.shape(node.shape());
        this.enums = Collections.unmodifiableMap(collector.enums);
        this.sealedKeys = Collections.unmodifiableMap(collector.sealedKeys);
        this.fieldNames = Collections.unmodifiableMap(collector.fieldNames);
        this.fields = Collections.unmodifiableMap(collector.fields);
        this.programs = Collections.unmodifiableMap(collector.programs);
        this.clean = Collections.unmodifiableSet(cleanReferences());
    }

    private static Map<String, FormatBinding> formatIndex(VersionedSemanticProfile profile) {
        Map<String, FormatBinding> index = new HashMap<>();
        for (FormatBinding binding : profile.formatBindings()) index.putIfAbsent(binding.name(), binding);
        return index;
    }

    private static Map<String, IntegerDomainBinding> domainIndex(VersionedSemanticProfile profile) {
        Map<String, IntegerDomainBinding> index = new HashMap<>();
        for (IntegerDomainBinding binding : profile.integerDomains()) index.putIfAbsent(binding.name(), binding);
        return index;
    }

    private static Table graphemeTableOf(GraphemeRules rules) { return new Table(rules); }

    private static Program programOf(FormatRule rule) { return new Program(rule); }

    private static Set<String> sealedKeysOf(SealedForm form) {
        Set<String> keys = new HashSet<>();
        for (SealedField field : form.fields()) keys.add(field.key());
        return keys;
    }

    private static Set<String> fieldNamesOf(ProductSpec spec) {
        Set<String> names = new HashSet<>();
        for (FieldSpec field : spec.fields()) names.add(field.wireName());
        return names;
    }

    private static Map<String, FieldSpec> fieldsOf(ProductSpec spec) {
        Map<String, FieldSpec> byName = new HashMap<>();
        for (FieldSpec field : spec.fields()) byName.putIfAbsent(field.wireName(), field);
        return byName;
    }

    private static Optional<Table> tryTable(GraphemeRules rules) {
        try {
            return Optional.of(graphemeTableOf(rules));
        } catch (RuntimeException unbuildable) {
            return Optional.empty();
        }
    }

    private static final class Collector {
        final Map<List<?>, Set<?>> enums = new IdentityHashMap<>();
        final Map<SealedForm, Set<String>> sealedKeys = new IdentityHashMap<>();
        final Map<ProductSpec, Set<String>> fieldNames = new IdentityHashMap<>();
        final Map<ProductSpec, Map<String, FieldSpec>> fields = new IdentityHashMap<>();
        final Map<FormatRule, Program> programs = new IdentityHashMap<>();

        void rule(FormatRule rule) {
            if (programs.containsKey(rule)) return;
            try {
                programs.put(rule, programOf(rule));
            } catch (RuntimeException uncompilable) {
            }
        }

        void use(Optional<FormatUse> use) {
            if (use.isPresent() && use.get() instanceof InlineFormat inline) rule(inline.rule());
        }

        void enumeration(Optional<? extends List<?>> values) {
            if (values.isPresent() && values.get().size() > ENUM_INDEX_SIZE && !enums.containsKey(values.get()))
                enums.put(values.get(), enumSet(values.get()));
        }

        void leaf(SealedLeaf leaf) {
            if (leaf instanceof StringLeaf string) string(string.spec());
            else integer(((IntegerLeaf) leaf).spec());
        }

        void string(StringSpec spec) {
            enumeration(spec.enumValues());
            use(spec.format());
        }

        void integer(IntegerSpec spec) { enumeration(spec.enumValues()); }

        void sealed(SealedForm form) {
            sealedKeys.put(form, sealedKeysOf(form));
        }

        void product(ProductSpec spec) {
            fieldNames.put(spec, fieldNamesOf(spec));
            fields.put(spec, fieldsOf(spec));
            if (spec.extras() instanceof AllowExtras allow) use(allow.keyFormat());
        }

        void shape(TypeShape shape) {
            switch (shape) {
                case StringShape string -> string(string.spec());
                case IntegerShape integer -> integer(integer.spec());
                case ProductShape product -> product(product.spec());
                case SealedShape sealed -> { for (SealedRefinement refinement : sealed.refinements()) leaf(refinement.leaf()); }
                default -> { }
            }
        }
    }

    private static Set<Object> enumSet(List<?> values) {
        return new HashSet<>(values);
    }

    /** The references of the graph from which no reference without meaning is reachable (Lean meaningObligations is empty). */
    private Set<TypeRef> cleanReferences() {
        Set<TypeRef> unclean = new HashSet<>();
        Map<TypeRef, List<TypeRef>> parents = new HashMap<>();
        List<TypeRef> declared = new java.util.ArrayList<>();
        for (TypeNode node : graph.nodes()) {
            if (graph.findType(node.ref()).orElse(null) != node) continue;
            declared.add(node.ref());
            if (!SemanticValidation.nodeMeaningObligations(this, node.ref()).isEmpty()) unclean.add(node.ref());
            for (TypeRef child : SemanticTypes.typeChildren(node.shape())) {
                parents.computeIfAbsent(child, key -> new java.util.ArrayList<>()).add(node.ref());
                if (graph.findType(child).isEmpty()) unclean.add(child);
            }
        }
        ArrayDeque<TypeRef> pending = new ArrayDeque<>(unclean);
        while (!pending.isEmpty())
            for (TypeRef parent : parents.getOrDefault(pending.pop(), List.of()))
                if (unclean.add(parent)) pending.push(parent);
        Set<TypeRef> result = new HashSet<>(declared);
        result.removeAll(unclean);
        return result;
    }

    boolean clean(TypeRef ref) { return clean.contains(ref); }

    Optional<TypeNode> findType(TypeRef ref) { return graph.findType(ref); }

    Optional<TagModel> tag() { return profile.tag(); }
    List<Wrapper> wrappers() { return profile.wrappers(); }
    Optional<BytesPolicy> bytesPolicy() { return profile.bytesPolicy(); }
    NumberModel numbers() { return profile.numbers(); }
    Optional<GraphemeRules> graphemeRules() { return profile.graphemeRules(); }
    List<FormatBinding> formatBindings() { return profile.formatBindings(); }
    String defaultIntegerDomain() { return profile.defaultIntegerDomain(); }
    ProfileRef reference() { return profile.reference(); }

    Optional<FormatBinding> formatBinding(String name) { return Optional.ofNullable(formats.get(name)); }

    Optional<IntegerDomainBinding> integerBinding(Optional<String> domain) {
        return Optional.ofNullable(domains.get(domain.orElse(profile.defaultIntegerDomain())));
    }

    boolean enumContains(List<?> values, Object value) {
        if (values.size() <= ENUM_INDEX_SIZE) return values.contains(value);
        Set<?> known = enums.get(values);
        return (known != null ? known : enumSet(values)).contains(value);
    }

    Set<String> fieldNames(ProductSpec spec) {
        Set<String> known = fieldNames.get(spec);
        if (known != null) return known;
        return fieldNamesOf(spec);
    }

    Map<String, FieldSpec> fieldsByName(ProductSpec spec) {
        Map<String, FieldSpec> known = fields.get(spec);
        if (known != null) return known;
        return fieldsOf(spec);
    }

    boolean sealedKnownKey(SealedForm form, String key) {
        Set<String> known = sealedKeys.get(form);
        if (known == null) known = sealedKeysOf(form);
        return known.contains(key);
    }

    boolean formatAccepts(FormatRule rule, String text) {
        Program known = programs.get(rule);
        if (known == null) known = programOf(rule);
        return SemanticFormats.accepts(graphemeTable(), known, text);
    }

    Optional<Table> graphemeTable() {
        if (graphemes.isPresent() || profile.graphemeRules().isEmpty()) return graphemes;
        return Optional.of(graphemeTableOf(profile.graphemeRules().get()));
    }

    Optional<Long> formatLength(StringLengthUnit unit, String value) {
        return SemanticValidation.formatLength(graphemeTable(), unit, value);
    }

    BigInteger fuelBound() { return BigInteger.valueOf(graph.nodes().size() + 1L); }
}
