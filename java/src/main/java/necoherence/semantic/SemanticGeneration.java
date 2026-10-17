// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;

/** Shared value inclusion, composition certificates, and execution. */
public final class SemanticGeneration {
    private SemanticGeneration() {}
    public sealed interface WireFailure permits UnsupportedSchema, UnknownField, UnknownTag, SyntaxFailure {}
    public record UnsupportedSchema(String schema) implements WireFailure {}
    public record UnknownField(String path, String field) implements WireFailure {}
    public record UnknownTag(String path, String tag) implements WireFailure {}
    public record SyntaxFailure(String message) implements WireFailure {}
    public static final class GenerationFailure extends Exception {
        private final String path, condition;
        private final WireFailure wireFailure;
        private final WireValue observed;
        GenerationFailure(String path, String condition) { this(path, condition, null, NIL); }
        GenerationFailure(String path, String condition, WireFailure wireFailure) {
            this(path, condition, wireFailure, NIL);
        }
        GenerationFailure(String path, String condition, WireFailure wireFailure, WireValue observed) {
            super(path + ": " + condition);
            this.path = path; this.condition = condition; this.wireFailure = wireFailure;
            this.observed = Objects.requireNonNull(observed);
        }
        public String path() { return path; }
        public String condition() { return condition; }
        public WireFailure wireFailure() { return wireFailure; }
        public WireValue observed() { return observed; }
    }
    public static final class GenerationBasis {
        public final WireValue value;
        GenerationBasis(WireValue value) { this.value = value; }
        /** Reads the basis obtained through the caller's trusted source, independently of the envelope. */
        public static GenerationBasis decode(String text) throws GenerationFailure {
            try { WireValue value = readJson(text); return new GenerationBasis(canonical(value, "SignatureGenerationBasis", "$basis")); }
            catch (RuntimeException error) { throw new GenerationFailure("$basis", error.getMessage()); }
        }
        public String encode() { return encodeWire(value); }
    }
    public record ProviderInterface(String identity, String revision, String contentDigest,
            String signatureAssumption, String effect, List<String> inputs, List<String> outcomes) {
        public ProviderInterface { inputs = List.copyOf(inputs); outcomes = List.copyOf(outcomes); }
    }
    public static final class CheckedGeneration {
        public final GenerationBasis basis;
        public final WireValue input;
        public final Context context;
        public final List<Integer> types;
        public final List<WireValue> definitions, providers;
        CheckedGeneration(GenerationBasis basis, WireValue input, Context context,
                List<Integer> types, List<WireValue> definitions, List<WireValue> providers) {
            this.basis = basis; this.input = input; this.context = context;
            this.types = List.copyOf(types); this.definitions = List.copyOf(definitions); this.providers = List.copyOf(providers);
        }
        public GenerationBasis basis() { return basis; }
        public Context valueContext() { return context; }
        public Slot<WireValue> suppliedValue(String inputIdentity) throws GenerationFailure {
            require(!nil(f(input, "composition")), "$initial", "composition required");
            WireValue initial = find(a(f(f(f(input, "composition"), "problem"), "initial_inputs")), "id", str(inputIdentity));
            require(initial != null && tag(f(initial, "source")).equals("SuppliedValue"), "$initial", "declared supplied value");
            return exchangeSlot(payload(f(initial, "source")));
        }
        public List<ProviderInterface> providerInterfaces() {
            List<ProviderInterface> result = new ArrayList<>();
            for (WireValue provider : providers) {
                WireValue ref = f(provider, "reference");
                result.add(new ProviderInterface(s(f(ref, "identity")), s(f(ref, "revision")), s(f(ref, "content_digest")),
                        s(f(provider, "assumption_ref")), tag(f(provider, "effect")),
                        a(f(provider, "inputs")).stream().map(v -> s(f(v, "id"))).toList(),
                        a(f(provider, "outcomes")).stream().map(v -> s(f(v, "id"))).toList()));
            }
            return List.copyOf(result);
        }
    }
    static void verifySignatureComposition(WireValue input, Context context) throws GenerationFailure, ValueFailure { new Checker(input, context).verify(); }
    static void verifyInclusion(Context context, WireValue basis, WireValue source, WireValue destination,
            WireValue certificate) throws GenerationFailure, ValueFailure {
        new Inclusions(context, basis).verify(source, destination, certificate);
    }
    static void require(boolean condition, String path, String reason) throws GenerationFailure { if (!condition) throw new GenerationFailure(path, reason); }
    static String sha(String text) {
        try { return java.util.HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8))); }
        catch (NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
    }
    static WireValue exact(WireValue value) {
        return switch (tag(value)) {
            case "Null" -> NIL;
            case "Bool", "String" -> f(value, "value");
            case "Integer" -> num(n(f(value, "value")));
            case "Decimal" -> new DecimalValue(s(f(value, "text")));
            case "Array" -> arr(a(f(value, "items")).stream().map(SemanticGeneration::exact).toList());
            case "Object" -> new ObjectValue(a(f(value, "members")).stream().map(row -> new Member(s(f(row, "key")), exact(f(row, "value")))).toList());
            default -> throw new IllegalArgumentException("ExactJson variant");
        };
    }
    public static WireValue toExact(WireValue value) {
        return switch (value) {
            case NullValue unused -> variant("Null"); case BooleanValue v -> variant("Bool", v);
            case IntegerValue v -> variant("Integer", str(v.value().toString()));
            case DecimalValue v -> obj("tag", str("Decimal"), "text", str(v.text())); case StringValue v -> variant("String", v);
            case ArrayValue v -> obj("tag", str("Array"), "items", arr(v.items().stream().map(SemanticGeneration::toExact).toList()));
            case ObjectValue v -> obj("tag", str("Object"), "members", arr(v.members().stream().map(row -> obj("key", str(row.key()), "value", toExact(row.value()))).toList()));
        };
    }
    static WireValue contract(WireValue reference, boolean required, boolean nullable) { return obj("type_ref", reference, "required", new BooleanValue(required), "nullable", new BooleanValue(nullable)); }
    private sealed interface Descriptor permits Atom, Vector, Maybe, Tuple, RecordDesc, EnumDesc {}
    private record Atom(String name) implements Descriptor {}
    private record Vector(Descriptor item) implements Descriptor {}
    private record Maybe(Descriptor item) implements Descriptor {}
    private record Tuple(List<Descriptor> items) implements Descriptor {}
    private record NamedField(String name, Descriptor type) {}
    private record RecordDesc(List<NamedField> fields) implements Descriptor {}
    private record EnumDesc(Map<String, Descriptor> variants) implements Descriptor {}
    private static final String WIRE_RECORDS = """
ProfileRef identity:s;revision:s;content_digest:s
CodepointRange first:n;last:n
GraphemeRange first:n;last:n;property:GraphemeProperty
IndicRange first:n;last:n;property:IndicProperty
GraphemeComponent unicode_version:s;uax29_revision:s;cluster_profile:s
GraphemeSource role:s;source:SourceRef
GraphemeRules reference:ProfileRef;component:GraphemeComponent;table_sha256:s;sources:[GraphemeSource];properties:[GraphemeRange];extended_pictographic:[CodepointRange];indic_conjunct:[IndicRange]
IntegerDomainBinding name:s;reference:ProfileRef;range:IntegerDomain;forms:[IntegerForm]
NumberModel decimals:b
BytesPolicy reference:ProfileRef;padding_optional:b;alphabet:BytesAlphabet;strict_pad_bits:b;wrapper:?s
CalendarRule allow_second_60:b;minimum_year:n;maximum_year:n;rejectUtcYearOutsideRange:b
DfaTransition from_state:n;first:n;last:n;to_state:n
DfaSpec state_count:n;initial_state:n;accepting_states:[n];transitions:[DfaTransition]
LengthBound unit:StringLengthUnit;minimum:?n;maximum:?n
FormatBinding name:s;reference:ProfileRef;rule:FormatRule
Wrapper name:s;key:s;payload:WrapperPayload
SealedField key:s;required:b;leaf:SealedLeaf
SealedForm tag:s;fields:[SealedField];extras:SealedExtras
TagModel key:s;format:?s;sealed:[SealedForm]
SlotContract type_ref:TypeRef;required:b;nullable:b
LengthSpec minimum:?n;maximum:?n
BooleanSpec const_value:?b;default_value:?b
IntegerSpec domain:?s;minimum:?i;maximum:?i;const_value:?i;enum_values:?[i];default_value:?i
DecimalBound mantissa:i;scale:n;exclusive:b
DecimalSpec minimum:?DecimalBound;maximum:?DecimalBound
StringSpec format:?FormatUse;lengths:[LengthBound];wrapper:?s;const_value:?s;enum_values:?[s];examples:[s];default_value:?s
SemanticObligation type_ref:TypeRef;origin:OccurrenceRef;value_path:[PathStep];profile:ProfileRef;reason:SemanticReason
ValueFailure type_ref:TypeRef;definition_ref:DefinitionRef;origin:OccurrenceRef;value_path:[PathStep];condition:ValueCondition;observed:s;reference_trace:[TypeRef]
ProjectionCertificate profile:ProfileRef;source_refs:[SourceRef];source:SlotContract;path:[PathStep];assumptions:[ProjectionAssumption];destination:SlotContract
FunctionRef identity:s;revision:s;content_digest:h
TypePair source:SlotContract;destination:SlotContract;source_tag:?s
PairEntry pair:TypePair;source_shape:SignatureShape;destination_shape:SignatureShape;rule:InclusionRule;children:[n]
InclusionCertificate basis:SemanticBasis;source:SlotContract;destination:SlotContract;root:n;empty_types:[TypeRef];pairs:[PairEntry]
TypeObligation pair:TypePair;path:[PathStep];reason:TypeObligationReason
CounterexampleCertificate basis:SemanticBasis;source:SlotContract;destination:SlotContract;value:SlotValue;destination_failure:ValueFailure
ValueRef producer:ProducerRef;path:[PathStep]
ResourceLot id:s;token_type:TypeRef;producer:ResourceProducer;revision:n;quantity:n;provenance:s
ResourceRequirement id:s;token_type:TypeRef;mode:BindingMode;multiplicity:n;required_revision:n;identity:ResourceIdentityConstraint
ResourceProduction id:s;token_type:TypeRef;revision:n;quantity:n;provenance:s
InitialInput id:s;contract:SlotContract;source:InitialSource;resource:?s
InputPort id:s;contract:SlotContract;source_constraint:SourceConstraint;resource_requirement:?s
OutputPort id:s;contract:SlotContract;resource_production:?s
OutcomeContract id:s;form:OutcomeForm;value_ports:[OutputPort];produced_resources:[ResourceProduction]
FunctionSignature reference:FunctionRef;form:FunctionForm;effect:CompositionEffect;inputs:[InputPort];outcomes:[OutcomeContract];resource_inputs:[ResourceRequirement];assumption_ref:s;handles_failure:?FailureOrigin
InvocationSite id:s;function:FunctionRef
PermittedProjection source_type:TypeRef;path:[PathStep]
DeclaredGuard id:s;source_type:TypeRef;path:[PathStep];kind:GuardKind
FieldConstraint field:s;source:SourceConstraint;presence:FieldPresence
ConstructionRule identity:s;type_ref:TypeRef;nested_fields:[(s,s)];field_constraints:[FieldConstraint]
InvocationDomain identity:s;revision:s;sites:[InvocationSite];permitted_projections:[PermittedProjection];permitted_constructions:[ConstructionRule];permitted_transforms:[FunctionRef];guards:[DeclaredGuard]
ResourceGoal lot:ResourceLotRef;multiplicity:n;revision:n
GoalPort id:s;contract:SlotContract;source_constraint:SourceConstraint
FailureEmbedding id:s;origin:FailureOrigin;contract:SlotContract;final_resources:[ResourceGoal]
GoalSpec outputs:[GoalPort];failures:[FailureEmbedding];final_resources:[ResourceGoal]
ResourceBounds max_bindings:n;max_search_steps:n;max_tokens:n
SearchBounds max_expanded_states:n;max_binding_candidates:n;max_type_obligations:n;max_branch_nodes:n;resource_bounds:?ResourceBounds;max_sample_length:n
CompositionInput identity:s;revision:s;basis:SemanticBasis;signatures:[FunctionSignature];initial_inputs:[InitialInput];initial_resources:[ResourceLot];goal:GoalSpec;invocation_domain:InvocationDomain;allowed_effects:[CompositionEffect];explicit_order:[(s,s)];selection_policy:?SelectionPolicy;bounds:SearchBounds
ResourceBinding requirement:s;lot:ResourceLotRef;inclusion:InclusionCertificate
InvocationPlan site:s;function:FunctionRef;bindings:[(s,BindingExpr)];resources:[ResourceBinding]
PlanTree rank:n;node:PlanNode
CompositionPlan input_identity:s;input_revision:s;root:PlanTree
BranchTrace steps:[TraceStep];terminal:ReturnPlan
ResourceLotCorrespondence lot:ResourceLotRef;place:s;producer:ResourceProducer;token_target:s;token_type:s;revision:n;quantity:n;provenance:s
ValueCorrespondence producer:ProducerRef;place:s;token_target:s;revision:n
NormalizedResourceBinding transition:s;lot:ResourceLotRef;read:n;consume:n;required_revision:n
ResourceCorrespondence lots:[ResourceLotCorrespondence];values:[ValueCorrespondence];normalized_bindings:[NormalizedResourceBinding];execution_order:[s]
ResourceTraceCertificate trace:BranchTrace;lowering:SolverInput;correspondence:ResourceCorrespondence;reachability:ReachabilityWitness;acyclicity:AcyclicWitness;value_sources:[(ProducerRef,SlotValue)]
CompositionWitness input_snapshot:CompositionInput;initial_membership:[(s,SlotValue)];resource_traces:[ResourceTraceCertificate]
RawComposition plan:CompositionPlan;witness:CompositionWitness;selection:SelectionEvidence
ConnectionFailure value:?ValueRef;destination:SlotContract;counterexample:CounterexampleCertificate
AvailableValue producer:ProducerRef;contract:SlotContract;resource:?ResourceLotRef
BranchFact guard:s;inspected:ValueRef;arm:GuardArm;refinement:?SlotContract;assumptions:[ProjectionAssumption];exact:?SlotValue
SearchState available:[AvailableValue];used_sites:[s];used_guards:[s];facts:[BranchFact];trace:[TraceStep];pending_failure:?FailureOrigin
MissingSupply site:?s;port:s;contract:SlotContract
TerminalCoverage terminal:ReturnPlan;assessment:TerminalAssessment
ChoiceCoverage choice:ChoiceSkeleton;children:[n]
ClosedSearchState state:SearchState;terminals:[TerminalCoverage];choices:[ChoiceCoverage];rejected_connections:[ConnectionFailure];missing_supply:[MissingSupply]
CompositionClosureWitness input_snapshot:CompositionInput;root:n;states:[ClosedSearchState]
ColoredToken target:s;index:n;revision:n;kind:TokenKind
TypedPlace identity:s;token_type:s;revision:n
TypedTransition identity:s;input_places:[s];output_places:[s];failure_places:[s];revision:n
InputBinding transition_id:s;name:s;place:s;token_type:s;identity:s;provenance:s;multiplicity:n;mode:BindingMode;required_revision:n
DeclarationGraph places:[s];transitions:[s];edges:[(s,s)];revision:n
DomainBound target_identity:s;index:n;revision:n;max_bindings:n;max_search_steps:n
Marking places:[(s,[ColoredToken])]
SolverInput places:[TypedPlace];transitions:[TypedTransition];bindings:[InputBinding];goal:GoalPredicate;graph:DeclarationGraph;marking:Marking;bound:DomainBound
ReachabilityWitness path:[s];final_marking:Marking
ClosureWitness explored_markings:[Marking];steps:n;frontier:[Marking]
AcyclicWitness explored_markings:[Marking];steps:n;frontier:[Marking]
GenerationComposition problem:CompositionInput;derivation:RawComposition
""";
    private static final Map<String, Descriptor> DESCRIPTORS = descriptors();
    private static Map<String, Descriptor> descriptors() {
        Map<String, Descriptor> result = new LinkedHashMap<>();
        for (String line : WIRE_RECORDS.lines().toList()) { int space = line.indexOf(' '); if (space > 0) result.put(line.substring(0, space), recordDesc(line.substring(space + 1))); }
        enums(result, "IntegerDomain", "Unbounded|Inclusive{minimum:i;maximum:i}");
        enums(result, "IntegerForm", "Number|IntegralDecimal|DecimalString");
        enums(result, "BytesAlphabet", "Standard|UrlSafe|Either");
        enums(result, "StringLengthUnit", "Utf8Bytes|UnicodeScalars|Graphemes");
        enums(result, "GraphemeProperty", "Other|Cr|Lf|Control|Extend|Zwj|RegionalIndicator|Prepend|SpacingMark|L|V|T|Lv|Lvt"); enums(result, "IndicProperty", "Other|Consonant|Extend|Linker");
        enums(result, "FormatRule", "Literal:s|Sequence:[FormatRule]|Optional:FormatRule|Labels{separator:s;min_count:n;max_count:?n;total_max:?n;rule:FormatRule}|Bounded{unit:StringLengthUnit;maximum:n;rule:FormatRule}|AsciiDfa:DfaSpec|Identifier{first_alphabet:s;rest_alphabet:s;exact_length:?n;min_length:n;max_length:?n;forbidden:[s]}|Timestamp:CalendarRule|AbsoluteUri{max_bytes:?n}|LanguageTag{grandfathered:[s]}|Choice:[FormatRule]|Text|Not:FormatRule");
        enums(result, "FormatUse", "Named:s|Inline:FormatRule");
        enums(result, "WrapperPayload", "Bytes|Text:?s");
        enums(result, "SealedLeaf", "String:StringSpec|Integer:IntegerSpec");
        enums(result, "SealedExtras", "Reject|Any");
        enums(result, "UnknownKind", "Any|OrdinaryObject");
        enums(result, "ExtraMembers", "Reject|Allow{key_format:?FormatUse;value:ElementContract}");
        enums(result, "ValueKind", "Null|Boolean|Number|String|Array|Object");
        enums(result, "MemberTest", "Absent|Format:s");
        enums(result, "BranchSelector", "InternalTag|MemberShape:[MemberCheck]|Kind:ValueKind|Otherwise");
        result.put("MemberCheck", recordDesc("key:s;test:MemberTest"));
        enums(result, "SlotValue", "Absent|Null|Present:ExactJson"); enums(result, "PathStep", "Field:s|Index:n|Variant:s");
        enums(result, "EffectPoint", "HttpRequestResponse|DataOnly");
        enums(result, "SemanticReason", "MissingGraphemeRules|MissingBytesPolicy|UnknownIntegerDomain:s|UnknownWrapper:s|WrapperPayload:s|UnknownSealedTag:s|DecimalNotAdmitted|IntegerBound|OpaqueType:s|MissingTagModel|UninterpretedExtension:s|UnresolvedType|InvalidProfile:s|MembershipBound|CertificateMismatch:s|ProjectionUnavailable:s|UnknownFormat:s");
        enums(result, "ValueCondition", "MissingRequired|NullNotAllowed|WrongValueKind:s|ConstMismatch|EnumMismatch|BelowMinimum|AboveMaximum|IntegerDomain|StringLength|ArrayLength|BytesLength|Format:s|InvalidBytes|InvalidWrapper:s|InvalidTag|ReservedForm|NoBranchSelected|KeyFormat:s|Uninhabited|DuplicateField:s|UnexpectedField:s|InvalidDataModel|ReferenceCycle");
        enums(result, "ProjectionAssumption", "Present:[PathStep]|NonNull:[PathStep]|Variant{path:[PathStep];tag:s}|IndexPresent{path:[PathStep];index:n}");
        enums(result, "InclusionRule", "EmptySource|Boolean|IntegerIntersection|FiniteStrings|StringConditions|BytesLength|Unit|UnfoldSource|UnfoldDestination|Array|Product|SourceUnion|DestinationUnion");
        enums(result, "TypeObligationReason", "ConstraintImplication|Presence|UnionRemainder|Inhabitation|ObligationBoundExhausted|Meaning:[SemanticObligation]|ExtraField:s");
        enums(result, "ProducerRef", "Initial:s|InvocationOutcome{site:s;outcome:s;port:s}"); enums(result, "SourceConstraint", "AnyCompatible|InitialOnly{input:s;path:[PathStep]}|ProducedBy{site:s;outcome:s;port:s;path:[PathStep]}");
        enums(result, "FieldPresence", "Required|Optional");
        enums(result, "ResourceLotRef", "Initial:s|Produced{site:s;outcome:s;production:s}"); enums(result, "ResourceProducer", "Initial{identity:s;revision:s}|InvocationOutcome{site:s;outcome:s}"); enums(result, "ResourceIdentityConstraint", "Any|Exactly:ResourceProducer");
        enums(result, "BindingMode", "Read|Consume"); enums(result, "InitialSource", "Argument|SuppliedValue:SlotValue"); enums(result, "OutcomeForm", "Success|DeclaredFailure"); enums(result, "FunctionForm", "Pure|DeclaredTransform|Operation:DefinitionRef"); enums(result, "CompositionEffect", "PureFunction|HttpRequestResponse|DataOnly");
        enums(result, "GuardArm", "Present|Absent|Null|UnknownVariant|Accepted|Rejected|Variant:s"); enums(result, "FailureOrigin", "Function{function:FunctionRef;outcome:s}|Guard{guard:s;arm:GuardArm}"); enums(result, "GuardKind", "Presence|Variants|Validate:SlotContract"); enums(result, "SelectionPolicy", "RequireUnique|AnyFeasible");
        enums(result, "BindingCompatibility", "Inclusion:InclusionCertificate|SuppliedValue{value:SlotValue}"); enums(result, "BindingExpr", "Source{value:ValueRef;projection:ProjectionCertificate;compatibility:BindingCompatibility}|Product{construction:s;type_ref:TypeRef;fields:[(s,BindingExpr)]}");
        enums(result, "ReturnPlan", "Success:[(s,BindingExpr)]|Failure{embedding:s;value:BindingExpr}"); enums(result, "PlanNode", "Return:ReturnPlan|Invoke{invocation:InvocationPlan;arms:[(s,PlanTree)];empty_outcomes:[s]}|Guard{guard:s;inspected:ValueRef;arms:[(GuardArm,PlanTree)]}"); enums(result, "TraceStep", "Invocation{invocation:InvocationPlan;outcome:s}|Guard{guard:s;inspected:ValueRef;arm:GuardArm}");
        enums(result, "UnresolvedObligation", "BranchInhabitation|StateBoundExhausted|BindingBoundExhausted|BranchBoundExhausted|UnresolvedUniqueness|Meaning:[SemanticObligation]|ResourceSolverUnknown:UnknownReason|Type{value:?ValueRef;obligations:[TypeObligation]}|Inhabitation{producer:ProducerRef;contract:SlotContract}|ResourceCapacityBound{required:n;limit:n}");
        enums(result, "ChoiceSkeleton", "Invoke{invocation:InvocationPlan;outcomes:[s];empty_outcomes:[s]}|Guard{guard:s;inspected:ValueRef;arms:[GuardArm]}"); enums(result, "TerminalAssessment", "Feasible:ResourceTraceCertificate|EmptyValues:[ProducerRef]|Unknown:[UnresolvedObligation]|ResourceUnreachable{trace:BranchTrace;lowering:SolverInput;correspondence:ResourceCorrespondence;closure:ClosureWitness}|RejectedLowering{trace:BranchTrace;reason:s}");
        enums(result, "SelectionEvidence", "AnyFeasible|Unique{closure:CompositionClosureWitness;canonical_plan:s}"); enums(result, "TokenKind", "Input|Output|Failure|Effect|Observation|Accepted"); enums(result, "GoalPredicate", "PlaceHasAtLeast{place:s;count:n}|PlaceHasToken{place:s;target:s;index:n;revision:n}|And:(GoalPredicate,GoalPredicate)|Or:(GoalPredicate,GoalPredicate)|Not:GoalPredicate"); enums(result, "UnknownReason", "BindingBoundExhausted:n|SearchStepBoundExhausted:n");
        enums(result, "ExactJson", "Null|Bool:b|Integer:i|Decimal{text:d}|String:s|Array{items:[ExactJson]}|Object{members:[ExactMember]}"); result.put("ExactMember", recordDesc("key:s;value:ExactJson"));
        result.put("TypeRef", recordDesc("source:SourceRef;definition_name:s;pointer:[s]"));
        result.put("DefinitionRef", recordDesc("source:SourceRef;name:s"));
        result.put("SemanticBasis", new Atom("SignatureGenerationBasis"));
        result.put("SourceRef", recordDesc("repository:s;revision:s;path:s;content_digest:s;document_id:s;declared_revision:?i"));
        result.put("OccurrenceRef", recordDesc("source:SourceRef;pointer:[s]"));
        TypeSignatures.descriptors(result, SemanticGeneration::recordDesc, (name, variants) -> enums(result, name, variants));
        Map<String, Descriptor> original = new LinkedHashMap<>(result);
        for (var entry : original.entrySet()) result.put("Sig" + entry.getKey(), signatureDescriptor(entry.getValue(), original));
        result.put("SigSourceRef", recordDesc("repository:s;revision:s;path:s;content_digest:h"));
        RecordDesc outcome = (RecordDesc) result.get("SigOutcomeContract");
        List<NamedField> outcomeFields = new ArrayList<>(outcome.fields());
        outcomeFields.add(new NamedField("cause", new Atom("OutcomeCause")));
        result.put("SigOutcomeContract", new RecordDesc(outcomeFields));
        result.put("SigPairEntry",recordDesc("pair:SigTypePair;source_shape:SignatureShape;destination_shape:SignatureShape;rule:SigInclusionRule;children:[n]"));
        return Map.copyOf(result);
    }
    private static Descriptor signatureDescriptor(Descriptor descriptor, Map<String, Descriptor> original) {
        if (descriptor == null) return null;
        if (descriptor instanceof Atom atom) {
            if (Set.of("TypeRef", "DefinitionRef").contains(atom.name())) return new Atom("s");
            if (atom.name().equals("SemanticBasis")) return new Atom("SignatureGenerationBasis");
            if (atom.name().equals("ExactJson")) return atom;
            return new Atom(original.containsKey(atom.name()) ? "Sig" + atom.name() : atom.name());
        }
        if (descriptor instanceof Vector vector) return new Vector(signatureDescriptor(vector.item(), original));
        if (descriptor instanceof Maybe maybe) return new Maybe(signatureDescriptor(maybe.item(), original));
        if (descriptor instanceof Tuple tuple) return new Tuple(tuple.items().stream().map(v -> signatureDescriptor(v, original)).toList());
        if (descriptor instanceof RecordDesc record) return new RecordDesc(record.fields().stream().map(v -> new NamedField(v.name().equals("type_ref") ? "type_id" : v.name(), signatureDescriptor(v.type(), original))).toList());
        Map<String, Descriptor> variants = new LinkedHashMap<>();
        ((EnumDesc) descriptor).variants().forEach((key, value) -> variants.put(key, signatureDescriptor(value, original)));
        return new EnumDesc(variants);
    }
    private static Descriptor typeDesc(String text) {
        if (text.startsWith("?")) return new Maybe(typeDesc(text.substring(1)));
        if (text.startsWith("[")) return new Vector(typeDesc(text.substring(1, text.length() - 1)));
        if (text.startsWith("(")) return new Tuple(splitTop(text.substring(1, text.length() - 1), ',').stream().map(SemanticGeneration::typeDesc).toList());
        return new Atom(text);
    }
    private static RecordDesc recordDesc(String text) {
        List<NamedField> result = new ArrayList<>(); if (!text.isEmpty()) for (String field : splitTop(text, ';')) { int split = field.indexOf(':'); result.add(new NamedField(field.substring(0, split), typeDesc(field.substring(split + 1)))); }
        return new RecordDesc(List.copyOf(result));
    }
    private static List<String> splitTop(String text, char separator) {
        List<String> result = new ArrayList<>(); int depth = 0, start = 0;
        for (int i = 0; i < text.length(); i++) { char c = text.charAt(i); if (c == '[' || c == '(' || c == '{') depth++; if (c == ']' || c == ')' || c == '}') depth--; if (c == separator && depth == 0) { result.add(text.substring(start, i)); start = i + 1; } }
        result.add(text.substring(start)); return result;
    }
    private static void enums(Map<String, Descriptor> schemas, String name, String variants) {
        Map<String, Descriptor> result = new LinkedHashMap<>(); for (String variant : splitTop(variants, '|')) {
            int brace = variant.indexOf('{'), colon = variant.indexOf(':');
            if (brace >= 0 && (colon < 0 || brace < colon)) result.put(variant.substring(0, brace), recordDesc(variant.substring(brace + 1, variant.length() - 1)));
            else if (colon >= 0) result.put(variant.substring(0, colon), typeDesc(variant.substring(colon + 1))); else result.put(variant, null);
        }
        schemas.put(name, new EnumDesc(Collections.unmodifiableMap(result)));
    }
    static WireValue canonical(WireValue value, String descriptor, String path) throws GenerationFailure { return canonical(value, typeDesc(descriptor), path, 0); }
    private static WireValue canonical(WireValue value, Descriptor descriptor, String path, int depth) throws GenerationFailure {
        require(depth <= 512, path, "finite exchange nesting");
        if (descriptor instanceof Atom atom) {
            String name = atom.name();
            if (Set.of("s", "i", "n", "h", "d").contains(name) || name.startsWith("=")) {
                require(value instanceof StringValue, path, "string"); String text = s(value);
                if (name.equals("i")) require(text.matches("0|-?[1-9][0-9]*"), path, "canonical exact integer");
                if (name.equals("n")) require(text.matches("0|[1-9][0-9]*"), path, "canonical exact natural");
                if (name.equals("h")) require(text.matches("[0-9a-f]{64}"), path, "SHA-256 spelling");
                if (name.equals("d")) require(text.matches("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?"), path, "decimal spelling");
                if (name.startsWith("=")) require(text.equals(name.substring(1)), path, "version"); return value;
            }
            if (name.equals("b")) { require(value instanceof BooleanValue, path, "boolean"); return value; }
            Descriptor resolved = DESCRIPTORS.get(name); require(resolved != null, path, "declared exchange type " + name); return canonical(value, resolved, path, depth + 1);
        }
        if (descriptor instanceof Maybe maybe) return nil(value) ? NIL : canonical(value, maybe.item(), path, depth + 1);
        if (descriptor instanceof Vector vector) {
            require(value instanceof ArrayValue, path, "array"); List<WireValue> result = new ArrayList<>(); for (int i = 0; i < a(value).size(); i++) result.add(canonical(a(value).get(i), vector.item(), path + "[" + i + "]", depth + 1)); return arr(result);
        }
        if (descriptor instanceof Tuple tuple) {
            require(value instanceof ArrayValue && a(value).size() == tuple.items().size(), path, "exact tuple"); List<WireValue> result = new ArrayList<>(); for (int i = 0; i < tuple.items().size(); i++) result.add(canonical(a(value).get(i), tuple.items().get(i), path + "[" + i + "]", depth + 1)); return arr(result);
        }
        if (descriptor instanceof RecordDesc record) {
            require(value instanceof ObjectValue, path, "object");
            Set<String> expected=record.fields().stream().map(NamedField::name).collect(java.util.stream.Collectors.toSet());
            for(Member member:o(value).members())if(!expected.contains(member.key()))
                throw new GenerationFailure(path+"."+member.key(),"UnknownField",new UnknownField(path,member.key()));
            List<Member> result = new ArrayList<>();
            for (NamedField field : record.fields()) {
                WireValue member = o(value).get(field.name()); require(member != null, path + "." + field.name(), "required field");
                result.add(new Member(field.name(), canonical(member, field.type(), path + "." + field.name(), depth + 1)));
            }
            return new ObjectValue(result);
        }
        EnumDesc enumeration = (EnumDesc) descriptor;
        require(value instanceof ObjectValue && o(value).get("tag") instanceof StringValue, path, "tagged variant"); String name = tag(value);
        if(!enumeration.variants().containsKey(name))throw new GenerationFailure(path,"UnknownTag",new UnknownTag(path,name));
        Descriptor content = enumeration.variants().get(name);
        int expectedFields=content==null?1:2;
        if(o(value).members().size()!=expectedFields)
            for(Member member:o(value).members())if(!Set.of("tag",content instanceof RecordDesc?"fields":"value").contains(member.key()))
                throw new GenerationFailure(path+"."+member.key(),"UnknownField",new UnknownField(path,member.key()));
        require(o(value).members().size()==expectedFields,path,"variant fields");
        if (content == null) return variant(name);
        if (enumeration == DESCRIPTORS.get("ExactJson") && Set.of("Decimal", "Array", "Object").contains(name)) {
            String key = name.equals("Decimal") ? "text" : name.equals("Array") ? "items" : "members"; require(o(value).get(key) != null, path, "exact JSON variant field"); return obj("tag", str(name), key, canonical(o(value).get(key), ((RecordDesc) content).fields().get(0).type(), path + "." + key, depth + 1));
        }
        String field = content instanceof RecordDesc ? "fields" : "value"; require(o(value).get(field) != null, path, "variant payload"); return obj("tag", str(name), field, canonical(o(value).get(field), content, path + "." + field, depth + 1));
    }
    public static WireValue readJson(String text) { return new Reader(text).document(); }
    private static final class Reader {
        private final String text; private int position;
        Reader(String text) { this.text = Objects.requireNonNull(text); }
        IllegalArgumentException fail(String condition) { return new IllegalArgumentException("JSON " + condition + " at " + position); }
        void whitespace() { while (position < text.length() && " \t\r\n".indexOf(text.charAt(position)) >= 0) position++; }
        char peek() { return position == text.length() ? '\0' : text.charAt(position); }
        boolean take(char c) { if (peek() == c) { position++; return true; } return false; }
        void need(char c) { whitespace(); if (!take(c)) throw fail("expected " + c); }
        WireValue document() { whitespace(); WireValue value = value(0); whitespace(); if (position != text.length()) throw fail("trailing input"); return value; }
        WireValue value(int depth) {
            if (depth > 512) throw fail("nesting"); whitespace();
            if (take('{')) { List<Member> members = new ArrayList<>(); whitespace(); if (take('}')) return new ObjectValue(members); do { whitespace(); String key = string(); need(':'); members.add(new Member(key, value(depth + 1))); whitespace(); if (take('}')) return new ObjectValue(members); } while (take(',')); throw fail("object separator"); }
            if (take('[')) { List<WireValue> values = new ArrayList<>(); whitespace(); if (take(']')) return arr(values); do { values.add(value(depth + 1)); whitespace(); if (take(']')) return arr(values); } while (take(',')); throw fail("array separator"); }
            if (peek() == '"') return str(string());
            for (String token : List.of("true", "false", "null")) if (text.startsWith(token, position)) { position += token.length(); return token.equals("null") ? NIL : new BooleanValue(token.equals("true")); }
            int start = position; take('-'); if (!take('0')) { if (peek() < '1' || peek() > '9') throw fail("number"); digits(); }
            boolean decimal = false; if (take('.')) { decimal = true; digits(); } if (take('e') || take('E')) { decimal = true; if (!take('+')) take('-'); digits(); }
            String spelling = text.substring(start, position); return decimal ? new DecimalValue(spelling) : num(new BigInteger(spelling));
        }
        void digits() { int start = position; while (peek() >= '0' && peek() <= '9') position++; if (position == start) throw fail("digits"); }
        String string() {
            if (!take('"')) throw fail("string"); StringBuilder result = new StringBuilder(); while (position < text.length()) {
                char c = text.charAt(position++); if (c == '"') { requireUnicode(result.toString()); return result.toString(); } if (c < 32) throw fail("control character"); if (c != '\\') { result.append(c); continue; } if (position == text.length()) throw fail("escape");
                switch (text.charAt(position++)) {
                    case '"' -> result.append('"'); case '\\' -> result.append('\\'); case '/' -> result.append('/'); case 'b' -> result.append('\b'); case 'f' -> result.append('\f'); case 'n' -> result.append('\n'); case 'r' -> result.append('\r'); case 't' -> result.append('\t');
                    case 'u' -> { int code = 0; for (int i = 0; i < 4; i++) { int digit = peek() < 128 ? Character.digit(peek(), 16) : -1; if (digit < 0) throw fail("Unicode escape"); code = code * 16 + digit; position++; } result.append((char) code); }
                    default -> throw fail("escape");
                }
            }
            throw fail("unterminated string");
        }
    }
    public sealed interface AssignabilityDecision permits Compatible, Incompatible, Unknown {}
    public record Compatible() implements AssignabilityDecision {}
    public record Incompatible(Slot<WireValue> value, ValueFailure destinationFailure) implements AssignabilityDecision {
        public Incompatible { Objects.requireNonNull(value); Objects.requireNonNull(destinationFailure); }
    }
    public record Unknown(List<String> obligations) implements AssignabilityDecision {
        public Unknown { obligations = List.copyOf(obligations); }
    }
    /** Classifies inclusion and returns the same accepted-source witness used by Lean's counterexample search. */
    public static AssignabilityDecision checkAssignable(Context context, WireValue source, WireValue destination,
            int maxObligations) {
        if (maxObligations < 0) throw new IllegalArgumentException("negative obligation bound");
        try {
            if (new Inclusions(context, NIL).compatible(source, destination, maxObligations)) return new Compatible();
        } catch (ValueFailure failure) {
            return new Unknown(List.of(failure.condition()));
        }
        SampleResult generated = inclusionSamples(context, f(source, "type_ref"), f(destination, "type_ref"),
                maxObligations, 10000);
        List<Slot<WireValue>> samples = new ArrayList<>();
        if (!b(f(source, "required"))) samples.add(new Absent<>());
        if (b(f(source, "nullable"))) samples.add(new NullSlot<>());
        generated.values().forEach(value -> samples.add(new Present<>(value)));
        for (Slot<WireValue> sample : samples) {
            try { context.validateContract(source, sample); }
            catch (ValueFailure rejectedBySource) { continue; }
            try { context.validateContract(destination, sample); }
            catch (ValueFailure rejectedByDestination) { return new Incompatible(sample, rejectedByDestination); }
        }
        List<String> obligations = new ArrayList<>();
        obligations.add("constraintImplication");
        obligations.addAll(generated.obligations());
        return new Unknown(obligations);
    }

    /** Produces source samples and product probes used by Lean's counterexample search. */
    public static SampleResult inclusionSamples(Context context, WireValue sourceRef, WireValue destinationRef,
            int maxObligations, int maxSampleLength) {
        if (maxObligations < 0 || maxSampleLength < 0) throw new IllegalArgumentException("negative search bound");
        int fuel = Math.min(maxObligations, context.nodes.size() + 1);
        SampleResult generated = sampleValueFuel(context, sourceRef, fuel, maxSampleLength);
        List<WireValue> candidates = new ArrayList<>();
        WireValue source = context.resolve(sourceRef), destination = context.resolve(destinationRef);
        if (source != null && destination != null && tag(source).equals("Product") && tag(destination).equals("Product")) {
            for (WireValue field : a(f(payload(destination), "fields"))) {
                String name = s(f(field, "wire_name"));
                if (a(f(payload(source), "fields")).stream().anyMatch(row -> s(f(row, "wire_name")).equals(name))) continue;
                for (WireValue sample : generated.values().stream().limit(1).toList()) {
                    if (!(sample instanceof ObjectValue object)) continue;
                    for (WireValue probe : List.of(NIL, new BooleanValue(true), str("x"), str("y"), num(BigInteger.ZERO))) {
                        List<Member> members = new ArrayList<>();
                        members.add(new Member(name, probe)); members.addAll(object.members());
                        candidates.add(new ObjectValue(members));
                    }
                }
            }
            WireValue extras = f(payload(source), "extras");
            if (tag(extras).equals("Allow")) {
                WireValue valueContract = f(payload(extras), "value");
                for (String key : formatUseSamples(context, f(payload(extras), "key_format"), 1))
                    for (WireValue value : elementSampleValues(context, valueContract, fuel, List.of()))
                        candidates.add(obj(key, value));
            }
        }
        List<WireValue> additional = new ArrayList<>();
        boolean omitted = false;
        for (WireValue candidate : candidates) {
            if (!sampleWithinBound(candidate, maxSampleLength)) { omitted = true; continue; }
            try {
                context.validateSlot(sourceRef, true, false, new Present<>(candidate));
                additional.add(candidate);
            } catch (ValueFailure failure) {}
        }
        List<WireValue> values = new ArrayList<>(generated.values()); values.addAll(additional);
        List<String> obligations = new ArrayList<>(generated.obligations());
        if (omitted) obligations.add("sampleBound");
        return new SampleResult(values, obligations);
    }
    public static SampleResult inclusionSamples(Context context, WireValue sourceRef, WireValue destinationRef, int maxObligations) {
        return inclusionSamples(context, sourceRef, destinationRef, maxObligations, Integer.MAX_VALUE);
    }

    public record SampleResult(List<WireValue> values, List<String> obligations) {
        public SampleResult {
            values = List.copyOf(values);
            obligations = List.copyOf(obligations);
        }
        public boolean possible() { return !values.isEmpty() || !obligations.isEmpty(); }
        public boolean sampleBound() { return obligations.contains("sampleBound"); }
    }
    public static SampleResult sampleValueFuel(Context context, WireValue reference, int fuel) {
        return sampleValueFuel(context, reference, fuel, Integer.MAX_VALUE);
    }
    public static SampleResult sampleValueFuel(Context context, WireValue reference, int fuel, int maxSampleLength) {
        if (fuel < 0 || maxSampleLength < 0) throw new IllegalArgumentException("negative sample bound");
        List<WireValue> candidates = sampleValues(context, reference, fuel, List.of());
        List<WireValue> values = candidates.stream().filter(value -> sampleWithinBound(value, maxSampleLength)).toList();
        return new SampleResult(values, values.size() == candidates.size() ? List.of() : List.of("sampleBound"));
    }
    public static SampleResult slotSamples(Context context, WireValue contract, int fuel) {
        return slotSamples(context, contract, fuel, Integer.MAX_VALUE);
    }
    public static SampleResult slotSamples(Context context, WireValue contract, int fuel, int maxSampleLength) {
        SampleResult generated = sampleValueFuel(context, f(contract, "type_ref"), fuel, maxSampleLength);
        List<WireValue> values = new ArrayList<>();
        if (!b(f(contract, "required"))) values.add(variant("Absent"));
        if (b(f(contract, "nullable"))) values.add(variant("Null"));
        for (WireValue value : generated.values()) values.add(variant("Present", toExact(value)));
        return new SampleResult(values, generated.obligations());
    }
    private static boolean sampleWithinBound(WireValue value, int maximum) {
        if (value instanceof StringValue text) return text.value().length() <= maximum;
        if (value instanceof DecimalValue decimal) return decimal.text().length() <= maximum;
        if (value instanceof ArrayValue array) return array.items().size() <= maximum;
        if (value instanceof ObjectValue object) return object.members().size() <= maximum;
        return true;
    }
    private static WireValue integerBinding(Context context, WireValue spec) {
        WireValue name = nil(f(spec, "domain")) ? f(context.profile, "default_integer_domain") : f(spec, "domain");
        return a(f(context.profile, "integer_domains")).stream()
                .filter(row -> f(row, "name").equals(name)).findFirst().orElse(null);
    }
    private static List<String> formatUseSamples(Context context, WireValue use, int limit) {
        if (nil(use)) return List.of("x");
        if (tag(use).equals("Inline")) return formatRuleSamples(payload(use), limit);
        return formatSamples(context, s(payload(use)), limit);
    }
    private static List<String> formatSamples(Context context, String name, int limit) {
        return a(f(context.profile, "format_bindings")).stream()
                .filter(row -> s(f(row, "name")).equals(name)).findFirst()
                .map(row -> formatRuleSamples(f(row, "rule"), limit)).orElse(List.of());
    }
    private static List<String> formatRuleSamples(WireValue rule, int limit) {
        List<String> candidates = new ArrayList<>();
        switch (tag(rule)) {
            case "Literal" -> candidates.add(s(payload(rule)));
            case "Text" -> candidates.addAll(List.of("", "a"));
            case "Not" -> {
                List<String> excluded = formatRuleSamples(payload(rule), limit);
                candidates.addAll(List.of("", "a", "aa")); candidates.addAll(excluded);
                excluded.forEach(text -> candidates.add(text + "x"));
            }
            case "Choice" -> a(payload(rule)).forEach(child -> candidates.addAll(formatRuleSamples(child, limit)));
            case "Optional" -> { candidates.add(""); candidates.addAll(formatRuleSamples(payload(rule), limit)); }
            case "Bounded" -> candidates.addAll(formatRuleSamples(f(payload(rule), "rule"), limit));
            case "Labels" -> {
                WireValue row = payload(rule);
                for (String sample : formatRuleSamples(f(row, "rule"), limit))
                    candidates.add(String.join(s(f(row, "separator")),
                            Collections.nCopies(Math.max(1, n(f(row, "minimum")).intValueExact()), sample)));
            }
            case "Sequence" -> {
                List<String> heads = new ArrayList<>(); boolean complete = true;
                for (WireValue child : a(payload(rule))) {
                    List<String> samples = formatRuleSamples(child, limit);
                    if (samples.isEmpty()) { complete = false; break; }
                    heads.add(samples.getFirst());
                }
                if (complete) candidates.add(String.join("", heads));
            }
            default -> candidates.addAll(List.of("", "a", "aa", "a:", "a:b"));
        }
        List<String> accepted = new ArrayList<>();
        for (String candidate : candidates)
            if (SemanticValues.recognize(rule, candidate) && !accepted.contains(candidate)) accepted.add(candidate);
        return accepted.stream().limit(limit).toList();
    }
    private static WireValue withoutMember(String key, WireValue value) {
        return new ObjectValue(o(value).members().stream().filter(member -> !member.key().equals(key)).toList());
    }
    private static WireValue sealedForm(Context context, String sealedTag) {
        WireValue model = f(context.profile, "tag");
        if (nil(model)) return null;
        return a(f(model, "sealed")).stream().filter(form -> s(f(form, "tag")).equals(sealedTag)).findFirst().orElse(null);
    }
    private static WireValue refinementLeaf(WireValue sealedSpec, WireValue field) {
        return a(f(sealedSpec, "refinements")).stream()
                .filter(refinement -> f(refinement, "key").equals(f(field, "key")))
                .map(refinement -> f(refinement, "leaf")).findFirst().orElse(f(field, "leaf"));
    }
    private static WireValue sealedLeafSample(Context context, WireValue leaf) {
        WireValue spec = payload(leaf);
        if (tag(leaf).equals("Integer")) {
            if (!nil(f(spec, "const_value"))) return num(n(f(spec, "const_value")));
            if (!nil(f(spec, "enum_values")) && !a(f(spec, "enum_values")).isEmpty()) return num(n(a(f(spec, "enum_values")).getFirst()));
            if (!nil(f(spec, "minimum"))) return num(n(f(spec, "minimum")));
            if (!nil(f(spec, "maximum"))) return num(n(f(spec, "maximum")));
            return null;
        }
        if (!nil(f(spec, "const_value"))) return str(s(f(spec, "const_value")));
        if (!nil(f(spec, "enum_values")) && !a(f(spec, "enum_values")).isEmpty()) return str(s(a(f(spec, "enum_values")).getFirst()));
        if (!a(f(spec, "examples")).isEmpty()) return str(s(a(f(spec, "examples")).getFirst()));
        List<String> values = formatUseSamples(context, f(spec, "format"), 1);
        return values.isEmpty() ? null : str(values.getFirst());
    }
    private static List<WireValue> elementSampleValues(Context context, WireValue contract,
            int fuel, List<WireValue> seen) {
        List<WireValue> values = new ArrayList<>(sampleValues(context, f(contract, "type_ref"), fuel, seen));
        if (context.elementAcceptsNull(context.index(f(contract, "type_ref")), b(f(contract, "nullable")))) {
            values.remove(NIL);
            values.addFirst(NIL);
        }
        return values;
    }
    private static List<WireValue> sampleValues(Context context, WireValue reference, int fuel, List<WireValue> seen) {
        if (fuel == 0 || seen.contains(reference)) return List.of();
        List<WireValue> chain = new ArrayList<>(); chain.add(reference); chain.addAll(seen);
        WireValue shape = context.shape(context.index(reference)), spec = o(shape).get("value");
        if (spec == null) spec = o(shape).get("fields");
        if (spec == null) spec = NIL;
        List<WireValue> candidates = new ArrayList<>();
        switch (tag(shape)) {
            case "Boolean" -> {
                if (nil(f(spec, "const_value"))) { candidates.add(new BooleanValue(false)); candidates.add(new BooleanValue(true)); }
                else candidates.add(f(spec, "const_value"));
            }
            case "Integer" -> {
                List<BigInteger> numbers = new ArrayList<>();
                if (!nil(f(spec, "const_value"))) numbers.add(n(f(spec, "const_value")));
                if (!nil(f(spec, "enum_values"))) for (WireValue value : a(f(spec, "enum_values"))) numbers.add(n(value));
                if (!nil(f(spec, "minimum"))) numbers.add(n(f(spec, "minimum")));
                if (!nil(f(spec, "maximum"))) numbers.add(n(f(spec, "maximum")));
                WireValue binding = integerBinding(context, spec);
                if (binding != null && tag(f(binding, "range")).equals("Inclusive")) {
                    numbers.add(n(f(payload(f(binding, "range")), "minimum")));
                    numbers.add(n(f(payload(f(binding, "range")), "maximum")));
                }
                numbers.addAll(List.of(BigInteger.ZERO, BigInteger.ONE, BigInteger.ONE.negate()));
                if (binding != null) for (WireValue form : a(f(binding, "forms"))) for (BigInteger number : numbers)
                    candidates.add(switch (tag(form)) {
                        case "Number" -> num(number);
                        case "IntegralDecimal" -> new DecimalValue(number.toString());
                        case "DecimalString" -> str(number.toString());
                        default -> throw new IllegalStateException("integer form");
                    });
            }
            case "Decimal" -> {
                for (String key : List.of("minimum", "maximum")) if (!nil(f(spec, key))) {
                    WireValue bound = f(spec, key);
                    candidates.add(new DecimalValue(n(f(bound, "mantissa")) + "e-" + n(f(bound, "scale"))));
                }
                candidates.addAll(List.of(new DecimalValue("0.0"), new DecimalValue("1.0"), new DecimalValue("-1.0")));
            }
            case "String" -> {
                List<String> texts = new ArrayList<>();
                if (!nil(f(spec, "const_value"))) texts.add(s(f(spec, "const_value")));
                if (!nil(f(spec, "enum_values"))) for (WireValue value : a(f(spec, "enum_values"))) texts.add(s(value));
                for (WireValue value : a(f(spec, "examples"))) texts.add(s(value));
                texts.addAll(formatUseSamples(context, f(spec, "format"), fuel));
                texts.add(""); texts.add("a");
                for (WireValue bound : a(f(spec, "lengths"))) for (String key : List.of("minimum", "maximum"))
                    if (!nil(f(bound, key))) texts.add("a".repeat(n(f(bound, key)).intValueExact()));
                for (String text : texts) candidates.add(context.encodeText(reference, text));
            }
            case "Bytes" -> {
                List<BigInteger> lengths = new ArrayList<>(List.of(BigInteger.ZERO, BigInteger.ONE));
                if (!nil(f(spec, "minimum"))) lengths.add(n(f(spec, "minimum")));
                if (!nil(f(spec, "maximum"))) lengths.add(n(f(spec, "maximum")));
                for (BigInteger length : lengths) candidates.add(context.encodeBytes(new Bytes(new byte[length.intValueExact()])));
            }
            case "Unit" -> candidates.add(NIL);
            case "Unknown" -> candidates.addAll(List.of(new ObjectValue(List.of()), NIL, new BooleanValue(false), num(BigInteger.ZERO), str(""), arr(List.of())));
            case "Alias" -> candidates.addAll(sampleValues(context, f(spec, "target"), fuel - 1, chain));
            case "Array" -> {
                List<BigInteger> lengths = new ArrayList<>(List.of(BigInteger.ZERO, BigInteger.ONE));
                if (!nil(f(spec, "min_length"))) lengths.add(n(f(spec, "min_length")));
                if (!nil(f(spec, "max_length"))) lengths.add(n(f(spec, "max_length")));
                WireValue item = f(spec, "item");
                for (BigInteger length : lengths) {
                    if (length.signum() == 0) { candidates.add(arr(List.of())); continue; }
                    for (WireValue value : elementSampleValues(context, item, fuel - 1, chain))
                        candidates.add(arr(Collections.nCopies(length.intValueExact(), value)));
                }
            }
            case "Product" -> {
                for (List<Member> members : constructProduct(context, a(f(spec, "fields")), fuel, chain)) candidates.add(new ObjectValue(members));
                WireValue extras = f(spec, "extras");
                if (tag(extras).equals("Allow")) {
                    WireValue valueContract = f(payload(extras), "value");
                    for (String key : formatUseSamples(context, f(payload(extras), "key_format"), 1))
                        for (WireValue value : elementSampleValues(context, valueContract, fuel - 1, chain).stream().limit(1).toList())
                            candidates.add(obj(key, value));
                }
            }
            case "TaggedUnion" -> {
                for (WireValue branch : a(f(spec, "branches"))) for (WireValue value : sampleValues(context, f(branch, "target"), fuel - 1, chain)) {
                    String selector = tag(f(branch, "selector"));
                    if (selector.equals("InternalTag") && value instanceof ObjectValue)
                        candidates.add(withMember(context.tagKey(), s(f(branch, "wire_tag")), value));
                    else if (selector.equals("MemberShape") && value instanceof ObjectValue object) {
                        WireValue shaped = object;
                        for (WireValue test : a(payload(f(branch, "selector")))) {
                            String key = s(f(test, "key")), kind = tag(f(test, "test"));
                            if (kind.equals("Absent")) shaped = withoutMember(key, shaped);
                            else {
                                List<String> samples = formatSamples(context, s(payload(f(test, "test"))), 1);
                                if (!samples.isEmpty()) shaped = withMember(key, samples.getFirst(), shaped);
                            }
                        }
                        candidates.add(shaped);
                    } else if (selector.equals("Kind") || selector.equals("Otherwise")) candidates.add(value);
                }
            }
            case "Sealed" -> {
                WireValue form = sealedForm(context, s(f(spec, "tag")));
                if (form != null) {
                    List<Member> members = new ArrayList<>(); members.add(new Member(context.tagKey(), f(form, "tag")));
                    boolean complete = true;
                    for (WireValue field : a(f(form, "fields"))) if (b(f(field, "required"))) {
                        WireValue leaf = refinementLeaf(spec, field);
                        WireValue value = sealedLeafSample(context, leaf);
                        if (value == null) { complete = false; break; }
                        members.add(new Member(s(f(field, "key")), value));
                    }
                    if (complete) candidates.add(new ObjectValue(members));
                }
            }
            default -> {}
        }
        List<WireValue> accepted = new ArrayList<>();
        for (WireValue candidate : candidates) try {
            context.validateSlot(reference, true, false, new Present<>(candidate));
            if (!accepted.contains(candidate)) accepted.add(candidate);
        } catch (ValueFailure failure) {}
        return accepted;
    }

    private static List<List<Member>> constructProduct(Context context, List<WireValue> fields, int fuel, List<WireValue> chain) {
        if (fields.isEmpty()) return List.of(List.of());
        WireValue field = fields.getFirst(), slot = f(field, "slot");
        List<List<Member>> remaining = constructProduct(context, fields.subList(1, fields.size()), fuel, chain);
        List<WireValue> here = new ArrayList<>();
        if (!b(f(slot, "required"))) here.add(null);
        if (b(f(slot, "nullable"))) here.add(NIL);
        here.addAll(sampleValues(context, f(slot, "type_ref"), fuel - 1, chain));
        List<List<Member>> result = new ArrayList<>();
        for (WireValue value : here) for (List<Member> members : remaining) {
            if (result.size() >= fuel + 1) return result;
            List<Member> row = new ArrayList<>();
            if (value != null) row.add(new Member(s(f(field, "wire_name")), value));
            row.addAll(members); result.add(row);
        }
        return result;
    }

    /** Projects a slot contract through a path with explicit dominating assumptions. */
    public static WireValue projectSlot(Context context, WireValue source, List<WireValue> path,
            List<WireValue> assumptions) throws GenerationFailure, ValueFailure {
        return projection(context, arr(List.of()), source, path, assumptions);
    }

    private record InclusionStep(String rule, List<WireValue> children) {}
    private static WireValue pair(WireValue source, WireValue destination, WireValue tag) { return obj("source", source, "destination", destination, "source_tag", tag); }
    private static WireValue presentPair(WireValue source, WireValue destination, WireValue tag) { return pair(contract(source, true, false), contract(destination, true, false), tag); }
    private static boolean formatIncluded(WireValue profile, WireValue source, WireValue destination) {
        if (nil(destination)) return true;
        if (nil(source)) return false;
        WireValue sourceRule=formatRule(profile,source),destinationRule=formatRule(profile,destination);
        return formatRuleIncluded(sourceRule,destinationRule);
    }
    private static WireValue formatRule(WireValue profile,WireValue use){
        if(tag(use).equals("Inline"))return payload(use);
        return a(f(profile,"format_bindings")).stream().filter(binding->f(binding,"name").equals(payload(use))).findFirst().map(binding->f(binding,"rule")).orElse(null);
    }
    private static boolean formatRuleIncluded(WireValue source,WireValue destination){
        if(source==null||destination==null)return false;
        if(source.equals(destination)||tag(destination).equals("Text"))return true;
        return tag(destination).equals("Choice")&&a(payload(destination)).stream().anyMatch(branch->formatRuleIncluded(source,branch));
    }
    private static final class Inclusions {
        final Context context; final WireValue basis; final Set<WireValue> empty;
        Inclusions(Context context, WireValue basis) throws ValueFailure {
            this.context = context; this.basis = basis; this.empty = new LinkedHashSet<>(context.indices.keySet());
            boolean changed;
            do {
                changed = false;
                for (WireValue node : context.nodes) if (empty.contains(f(node, "reference")) && !locallyEmpty(f(node, "reference"), empty)) { empty.remove(f(node, "reference")); changed = true; }
            } while (changed);
        }
        WireValue integerBinding(WireValue spec){
            WireValue name=nil(f(spec,"domain"))?f(context.profile,"default_integer_domain"):f(spec,"domain");
            return a(f(context.profile,"integer_domains")).stream().filter(row->f(row,"name").equals(name)).findFirst().orElse(null);
        }
        BigInteger[] integerBounds(WireValue spec) {
            BigInteger minimum = null, maximum = null; WireValue binding=integerBinding(spec);
            if(binding!=null&&tag(f(binding,"range")).equals("Inclusive")){WireValue domain=payload(f(binding,"range"));minimum=n(f(domain,"minimum"));maximum=n(f(domain,"maximum"));}
            if (!nil(f(spec, "minimum"))) minimum = lower(minimum, n(f(spec, "minimum")));
            if (!nil(f(spec, "maximum"))) maximum = upper(maximum, n(f(spec, "maximum")));
            if (!nil(f(spec, "const_value"))) { BigInteger value = n(f(spec, "const_value")); minimum = lower(minimum, value); maximum = upper(maximum, value); }
            return new BigInteger[]{minimum, maximum};
        }
        List<BigInteger> finiteIntegers(WireValue spec) {
            WireValue values = !nil(f(spec, "const_value")) ? arr(List.of(f(spec, "const_value"))) : f(spec, "enum_values");
            if (nil(values)) return null; BigInteger[] bounds = integerBounds(spec); List<BigInteger> result = new ArrayList<>();
            for (WireValue value : a(values)) { BigInteger number = n(value); if (within(number, bounds) && (nil(f(spec, "enum_values")) || a(f(spec, "enum_values")).contains(str(number.toString())))) result.add(number); }
            return result;
        }
        List<WireValue> finiteStrings(WireValue reference, WireValue spec) throws ValueFailure {
            WireValue values = !nil(f(spec, "const_value")) ? arr(List.of(f(spec, "const_value"))) : f(spec, "enum_values");
            if (nil(values)) return null; List<WireValue> result = new ArrayList<>();
            for (WireValue value : a(values)) {
                try { if (accepts(contract(reference, true, false), new Present<>(value))) result.add(value); }
                catch (ValueFailure failure) { if (failure.condition().startsWith("UndefinedMeaning:")) return null; throw failure; }
            }
            return result;
        }
        boolean locallyEmpty(WireValue reference, Set<WireValue> candidate) throws ValueFailure {
            WireValue shape = context.shape(context.index(reference)); String kind = tag(shape); WireValue spec = o(shape).get("value");
            return switch (kind) {
                case "Alias" -> candidate.contains(f(payload(shape), "target"));
                case "Integer" -> { List<BigInteger> finite = finiteIntegers(spec); BigInteger[] bounds = integerBounds(spec); yield finite != null ? finite.isEmpty() : bounds[0] != null && bounds[1] != null && bounds[0].compareTo(bounds[1]) > 0; }
                case "String" -> { List<WireValue> finite = finiteStrings(reference, spec); yield finite != null && finite.isEmpty(); }
                case "Bytes" -> inverted(f(spec, "minimum"), f(spec, "maximum"));
                case "Product" -> a(f(spec, "fields")).stream().anyMatch(field -> b(f(f(field, "slot"), "required")) && !b(f(f(field, "slot"), "nullable")) && candidate.contains(f(f(field, "slot"), "type_ref")));
                case "Array" -> inverted(f(spec, "min_length"), f(spec, "max_length")) || !nil(f(spec, "min_length")) && n(f(spec, "min_length")).signum() > 0 && candidate.contains(f(f(spec, "item"),"type_ref"));
                case "TaggedUnion" -> a(f(spec, "branches")).stream().allMatch(branch -> candidate.contains(f(branch, "target")));
                case "Never" -> true;
                default -> false;
            };
        }
        boolean accepts(WireValue contract, Slot<WireValue> value) throws ValueFailure {
            try { context.validateContract(contract, value); return true; }
            catch (ValueFailure failure) { if (failure.condition().startsWith("UndefinedMeaning:")) throw failure; return false; }
        }
        boolean elementAcceptsNull(WireValue contract) {
            return context.elementAcceptsNull(context.index(f(contract, "type_ref")), b(f(contract, "nullable")));
        }
        boolean emptySlot(WireValue contract) { return b(f(contract, "required")) && !b(f(contract, "nullable")) && empty.contains(f(contract, "type_ref")); }
        void verify(WireValue source, WireValue destination, WireValue certificate) throws GenerationFailure, ValueFailure {
            require(f(certificate, "basis").equals(basis) && f(certificate, "source").equals(source) && f(certificate, "destination").equals(destination), "$inclusion", "basis/contracts");
            context.meaning(context.index(f(source, "type_ref"))); context.meaning(context.index(f(destination, "type_ref")));
            List<WireValue> suppliedEmpty = a(f(certificate, "empty_types")); Set<WireValue> emptySet = new HashSet<>(suppliedEmpty);
            require(emptySet.size() == suppliedEmpty.size(), "$inclusion", "duplicate empty type");
            for (WireValue ref : suppliedEmpty) require(locallyEmpty(ref, emptySet), "$inclusion", "forged emptiness");
            List<WireValue> pairs = a(f(certificate, "pairs")); int root = indexNumber(f(certificate, "root"));
            require(root < pairs.size() && f(pairs.get(root), "pair").equals(pair(source, destination, NIL)), "$inclusion", "root pair");
            Set<Integer> visited = new HashSet<>(); ArrayDeque<Integer> pending = new ArrayDeque<>(); pending.push(root);
            while (!pending.isEmpty()) {
                int index = pending.pop(); if (!visited.add(index)) continue; require(index < pairs.size(), "$inclusion", "pair index"); WireValue entry = pairs.get(index), pair = f(entry, "pair");
                require(context.shape(context.index(f(f(pair, "source"), "type_ref"))).equals(f(entry, "source_shape")) && context.shape(context.index(f(f(pair, "destination"), "type_ref"))).equals(f(entry, "destination_shape")), "$inclusion", "source-qualified shapes");
                InclusionStep expected = local(pair, emptySet); require(tag(f(entry, "rule")).equals(wireRuleName(pair, expected)), "$inclusion", "rule mismatch");
                List<WireValue> children = a(f(entry, "children")); require(children.size() == expected.children().size(), "$inclusion", "child coverage"); boolean[] matched = new boolean[children.size()];
                for (WireValue expectedChild : expected.children()) {
                    int found = -1;
                    for (int i = 0; i < children.size(); i++) { int child = indexNumber(children.get(i)); if (!matched[i] && child < pairs.size() && f(pairs.get(child), "pair").equals(expectedChild)) { found = i; break; } }
                    require(found >= 0, "$inclusion", "child obligation"); matched[found] = true; pending.push(indexNumber(children.get(found)));
                }
            }
            require(visited.size() == pairs.size(), "$inclusion", "extraneous obligations");
        }
        boolean compatible(WireValue source, WireValue destination) throws ValueFailure {
            return compatible(source, destination, Integer.MAX_VALUE);
        }
        boolean compatible(WireValue source, WireValue destination, int maxObligations) throws ValueFailure {
            Set<WireValue> visited = new HashSet<>(); ArrayDeque<WireValue> pending = new ArrayDeque<>(); pending.push(pair(source, destination, NIL));
            context.meaning(context.index(f(source, "type_ref"))); context.meaning(context.index(f(destination, "type_ref")));
            try { while (!pending.isEmpty()) { WireValue pair = pending.pop(); if (!visited.add(pair)) continue; if (visited.size() > maxObligations) return false; pending.addAll(local(pair, empty).children()); } return true; }
            catch (GenerationFailure failure) { return false; }
        }
        InclusionStep local(WireValue pair, Set<WireValue> empty) throws GenerationFailure, ValueFailure {
            WireValue source = f(pair, "source"), destination = f(pair, "destination"), sourceRef = f(source, "type_ref"), destinationRef = f(destination, "type_ref"), sourceTag = f(pair, "source_tag");
            require((b(f(source, "required")) || !b(f(destination, "required"))) && (!b(f(source, "nullable")) || b(f(destination, "nullable"))), "$inclusion", "presence implication");
            WireValue sshape = context.shape(context.index(sourceRef)), dshape = context.shape(context.index(destinationRef)); String skind = tag(sshape), dkind = tag(dshape); WireValue s = o(sshape).get("value"), d = o(dshape).get("value");
            List<WireValue> children = new ArrayList<>();
            if (empty.contains(sourceRef)) return new InclusionStep("EmptySource", List.of());
            require(!empty.contains(destinationRef), "$inclusion", "destination empty");
            if (sshape.equals(dshape)) return new InclusionStep("SameDefinedType", List.of());
            if (skind.equals("Alias"))
                return new InclusionStep("UnfoldSource", List.of(presentPair(f(payload(sshape), "target"), destinationRef, sourceTag)));
            if (dkind.equals("Alias"))
                return new InclusionStep("UnfoldDestination", List.of(presentPair(sourceRef, f(payload(dshape), "target"), sourceTag)));
            if (skind.equals("TaggedUnion") && dkind.equals("TaggedUnion")) {
                List<WireValue[]> mapped = unionBranchPairs(a(f(s, "branches")), a(f(d, "branches")));
                require(mapped != null, "$inclusion", "union selector image");
                for (WireValue[] mappedPair : mapped)
                    children.add(presentPair(f(mappedPair[0], "target"), f(mappedPair[1], "target"), NIL));
                return new InclusionStep("SourceUnion", children);
            }
            require(skind.equals(dkind), "$inclusion", "kind implication");
            switch (skind) {
                case "Boolean":
                    require(nil(f(d, "const_value")) || f(s, "const_value").equals(f(d, "const_value")),
                            "$inclusion", "boolean condition");
                    return new InclusionStep("Boolean", List.of());
                case "Integer": {
                    WireValue sourceBinding = integerBinding(s), destinationBinding = integerBinding(d);
                    require(sourceBinding != null && destinationBinding != null
                                    && a(f(sourceBinding, "forms")).equals(List.of(variant("Number")))
                                    && a(f(destinationBinding, "forms")).equals(List.of(variant("Number")))
                                    && f(s, "domain").equals(f(d, "domain")),
                            "$inclusion", "integer domain and forms");
                    List<BigInteger> finite = finiteIntegers(s); boolean accepted = true;
                    if (finite != null) {
                        for (BigInteger value : finite)
                            if (within(value, integerBounds(s)))
                                try { context.validateSlot(destinationRef, true, false, new Present<>(num(value))); }
                                catch (ValueFailure failure) { accepted = false; break; }
                    } else {
                        accepted = nil(f(d, "const_value")) && nil(f(d, "enum_values"))
                                && contained(new BigInteger[]{nil(f(s, "minimum")) ? null : n(f(s, "minimum")),
                                            nil(f(s, "maximum")) ? null : n(f(s, "maximum"))},
                                        new BigInteger[]{nil(f(d, "minimum")) ? null : n(f(d, "minimum")),
                                            nil(f(d, "maximum")) ? null : n(f(d, "maximum"))});
                    }
                    require(accepted, "$inclusion", "integer intersection");
                    return new InclusionStep("IntegerIntersection", List.of());
                }
                case "String":
                    require(sameStringExceptLengths(s, d) && lengthBoundsContained(f(s, "lengths"), f(d, "lengths")),
                            "$inclusion", "string conditions");
                    return new InclusionStep("StringConditions", List.of());
                case "Array": {
                    require(naturalContained(f(s, "min_length"), f(s, "max_length"),
                                    f(d, "min_length"), f(d, "max_length")),
                            "$inclusion", "array length");
                    WireValue sourceItem = f(s, "item"), destinationItem = f(d, "item");
                    require(!elementAcceptsNull(sourceItem) || elementAcceptsNull(destinationItem),
                            "$inclusion", "array item nullability");
                    children.add(presentPair(f(sourceItem, "type_ref"), f(destinationItem, "type_ref"), NIL));
                    return new InclusionStep("Array", children);
                }
                case "Product": {
                    List<WireValue> sourceFields = a(f(s, "fields")), destinationFields = a(f(d, "fields"));
                    WireValue sourceExtras = f(s, "extras"), destinationExtras = f(d, "extras");
                    String tagKey = context.tagKey();
                    for (WireValue destinationField : destinationFields) {
                        String name = s(f(destinationField, "wire_name"));
                        WireValue destinationSlot = f(destinationField, "slot");
                        WireValue sourceField = sourceFields.stream()
                                .filter(field -> s(f(field, "wire_name")).equals(name)).findFirst().orElse(null);
                        if (sourceField != null) {
                            require(presenceIncluded(f(sourceField, "slot"), destinationSlot),
                                    "$inclusion", "field presence");
                            children.add(pair(f(sourceField, "slot"), destinationSlot, NIL));
                        } else {
                            require(!b(f(destinationSlot, "required")) && !name.equals(tagKey)
                                            && tag(sourceExtras).equals("Allow"),
                                    "$inclusion", "missing destination field");
                            WireValue sourceValue = f(payload(sourceExtras), "value");
                            require(!elementAcceptsNull(sourceValue) || b(f(destinationSlot, "nullable")),
                                    "$inclusion", "extras field nullability");
                            children.add(presentPair(f(sourceValue, "type_ref"), f(destinationSlot, "type_ref"), NIL));
                        }
                    }
                    for (WireValue sourceField : sourceFields) {
                        String name = s(f(sourceField, "wire_name"));
                        if (destinationFields.stream().anyMatch(field -> s(f(field, "wire_name")).equals(name))
                                || name.equals(tagKey)) continue;
                        require(tag(destinationExtras).equals("Allow")
                                        && extraAllowsKey(f(payload(destinationExtras), "key_format"), name),
                                "$inclusion", "unexpected source field");
                        WireValue sourceSlot = f(sourceField, "slot"), destinationValue = f(payload(destinationExtras), "value");
                        require(!b(f(sourceSlot, "nullable")) || elementAcceptsNull(destinationValue),
                                "$inclusion", "field extras nullability");
                        children.add(presentPair(f(sourceSlot, "type_ref"), f(destinationValue, "type_ref"), NIL));
                    }
                    if (tag(sourceExtras).equals("Allow")) {
                        require(tag(destinationExtras).equals("Allow")
                                        && formatUseIncluded(f(payload(sourceExtras), "key_format"),
                                            f(payload(destinationExtras), "key_format")),
                                "$inclusion", "destination extras");
                        WireValue sourceValue = f(payload(sourceExtras), "value"), destinationValue = f(payload(destinationExtras), "value");
                        require(!elementAcceptsNull(sourceValue) || elementAcceptsNull(destinationValue),
                                "$inclusion", "extras nullability");
                        children.add(presentPair(f(sourceValue, "type_ref"), f(destinationValue, "type_ref"), NIL));
                    }
                    return new InclusionStep("Product", children);
                }
                default: throw new GenerationFailure("$inclusion", "undefined implication");
            }
        }
        String wireRuleName(WireValue pair, InclusionStep step) throws GenerationFailure {
            if (!step.rule().equals("SameDefinedType")) return step.rule();
            String sourceKind = tag(context.shape(context.index(f(f(pair, "source"), "type_ref"))));
            return switch (sourceKind) {
                case "Boolean" -> "Boolean";
                case "Integer" -> "IntegerIntersection";
                case "String" -> "StringConditions";
                case "Unit" -> "Unit";
                default -> throw new GenerationFailure("$inclusion", "construction source requires a primitive inclusion");
            };
        }
        boolean presenceIncluded(WireValue source, WireValue destination) {
            return (b(f(source, "required")) || !b(f(destination, "required")))
                    && (!b(f(source, "nullable")) || b(f(destination, "nullable")));
        }
        boolean sameStringExceptLengths(WireValue source, WireValue destination) {
            return TypeSignatures.replace(source, "lengths", arr(List.of()))
                    .equals(TypeSignatures.replace(destination, "lengths", arr(List.of())));
        }
        boolean extraAllowsKey(WireValue use, String key) {
            if (nil(use)) return true;
            WireValue rule = formatRule(context.profile, use);
            return rule != null && SemanticValues.recognize(rule, key);
        }
        boolean formatUseIncluded(WireValue source, WireValue destination) {
            if (nil(destination)) return true;
            if (nil(source)) return false;
            return formatIncluded(context.profile, source, destination);
        }
        List<WireValue[]> unionBranchPairs(List<WireValue> sources, List<WireValue> destinations) {
            if (sources.isEmpty()) return new ArrayList<>();
            if (destinations.isEmpty()) return null;
            WireValue source = sources.getFirst(), destination = destinations.getFirst();
            if (selectorsEqual(source, destination)) {
                List<WireValue[]> rest = unionBranchPairs(sources.subList(1, sources.size()),
                        destinations.subList(1, destinations.size()));
                if (rest == null) return null;
                rest.addFirst(new WireValue[]{source, destination});
                return rest;
            }
            if (sources.stream().allMatch(candidate -> selectorsDisjoint(destination, candidate)))
                return unionBranchPairs(sources, destinations.subList(1, destinations.size()));
            return null;
        }
        boolean selectorsEqual(WireValue source, WireValue destination) {
            WireValue sourceSelector = f(source, "selector"), destinationSelector = f(destination, "selector");
            if (!tag(sourceSelector).equals(tag(destinationSelector))) return false;
            return switch (tag(sourceSelector)) {
                case "InternalTag" -> f(source, "wire_tag").equals(f(destination, "wire_tag"));
                case "MemberShape", "Kind" -> source.equals(destination);
                case "Otherwise" -> true;
                default -> false;
            };
        }
        boolean selectorsDisjoint(WireValue left, WireValue right) {
            WireValue a = f(left, "selector"), b = f(right, "selector");
            if (tag(a).equals("Otherwise") || tag(b).equals("Otherwise")) return false;
            if (tag(a).equals("InternalTag") && tag(b).equals("InternalTag"))
                return !f(left, "wire_tag").equals(f(right, "wire_tag"));
            if (tag(a).equals("Kind") && tag(b).equals("Kind")) return !payload(a).equals(payload(b));
            return false;
        }
        List<WireValue> requiredTags(WireValue reference, WireValue shape) throws ValueFailure {
            if (!tag(shape).equals("Product")) return null;
            for (WireValue field : a(f(payload(shape), "fields"))) if (s(f(field, "wire_name")).equals(context.tagKey()) && b(f(f(field, "slot"), "required")) && !b(f(f(field, "slot"), "nullable"))) {
                WireValue type = f(f(field, "slot"), "type_ref"), resolved = context.resolve(type);
                if (resolved != null && tag(resolved).equals("String")) return finiteStrings(type, payload(resolved));
            }
            return null;
        }
    }
    private static BigInteger lower(BigInteger left, BigInteger right) { return left == null ? right : left.max(right); }
    private static BigInteger upper(BigInteger left, BigInteger right) { return left == null ? right : left.min(right); }
    private static boolean within(BigInteger value, BigInteger[] bounds) { return (bounds[0] == null || value.compareTo(bounds[0]) >= 0) && (bounds[1] == null || value.compareTo(bounds[1]) <= 0); }
    private static boolean contained(BigInteger[] source, BigInteger[] destination) { return (destination[0] == null || source[0] != null && source[0].compareTo(destination[0]) >= 0) && (destination[1] == null || source[1] != null && source[1].compareTo(destination[1]) <= 0); }
    private static boolean naturalContained(WireValue smin, WireValue smax, WireValue dmin, WireValue dmax) { return contained(new BigInteger[]{nil(smin) ? BigInteger.ZERO : n(smin), nil(smax) ? null : n(smax)}, new BigInteger[]{nil(dmin) ? BigInteger.ZERO : n(dmin), nil(dmax) ? null : n(dmax)}); }
    private static boolean lengthBoundsContained(WireValue source,WireValue destination){
        for(WireValue target:a(destination)){
            WireValue matching=a(source).stream().filter(bound->f(bound,"unit").equals(f(target,"unit"))).findFirst().orElse(null);
            WireValue sourceMin=matching==null?NIL:f(matching,"minimum"),sourceMax=matching==null?NIL:f(matching,"maximum");
            if(!naturalContained(sourceMin,sourceMax,f(target,"minimum"),f(target,"maximum")))return false;
        }
        return true;
    }
    private static boolean decimalContained(WireValue source,WireValue destination){
        return decimalLowerContained(f(source,"minimum"),f(destination,"minimum"))
                &&decimalUpperContained(f(source,"maximum"),f(destination,"maximum"));
    }
    private static java.math.BigDecimal decimalBound(WireValue bound){
        return new java.math.BigDecimal(n(f(bound,"mantissa")),n(f(bound,"scale")).intValueExact());
    }
    private static boolean decimalLowerContained(WireValue source,WireValue destination){
        if(nil(destination))return true;if(nil(source))return false;int order=decimalBound(source).compareTo(decimalBound(destination));
        return order>0||order==0&&(!b(f(destination,"exclusive"))||b(f(source,"exclusive")));
    }
    private static boolean decimalUpperContained(WireValue source,WireValue destination){
        if(nil(destination))return true;if(nil(source))return false;int order=decimalBound(source).compareTo(decimalBound(destination));
        return order<0||order==0&&(!b(f(destination,"exclusive"))||b(f(source,"exclusive")));
    }
    private static boolean inverted(WireValue minimum, WireValue maximum) { return !nil(minimum) && !nil(maximum) && n(minimum).compareTo(n(maximum)) > 0; }
    private static int indexNumber(WireValue value) { return n(value).intValueExact(); }
    private static WireValue find(List<WireValue> values, String field, WireValue identity) {
        for (WireValue value : values) if (f(value, field).equals(identity)) return value;
        return null;
    }
    private static WireValue tupleLookup(WireValue values, WireValue identity) throws GenerationFailure {
        WireValue result = null; for (WireValue tuple : a(values)) if (a(tuple).get(0).equals(identity)) { require(result == null, "$bindings", "duplicate identity"); result = a(tuple).get(1); }
        require(result != null, "$bindings", "missing identity"); return result;
    }
    private static void unique(List<WireValue> values, String field, String path) throws GenerationFailure {
        Set<WireValue> seen = new HashSet<>(); for (WireValue value : values) { WireValue identity = f(value, field); require(!s(identity).isEmpty() && seen.add(identity), path, "nonempty unique identity"); }
    }
    private static WireValue initialProducer(WireValue id) { return variant("Initial", id); }
    private static WireValue outcomeProducer(WireValue site, WireValue outcome, WireValue port) { return fields("InvocationOutcome", obj("site", site, "outcome", outcome, "port", port)); }
    private static WireValue producedLot(WireValue site, WireValue outcome, WireValue production) { return fields("Produced", obj("site", site, "outcome", outcome, "production", production)); }
    private static WireValue valueRef(WireValue producer, List<WireValue> path) { return obj("producer", producer, "path", arr(path)); }
    private static final class State {
        final List<WireValue> available = new ArrayList<>(), usedSites = new ArrayList<>(), usedGuards = new ArrayList<>(), facts = new ArrayList<>(), trace = new ArrayList<>();
        WireValue pendingFailure = NIL;
        State() {}
        State(State before) { available.addAll(before.available); usedSites.addAll(before.usedSites); usedGuards.addAll(before.usedGuards); facts.addAll(before.facts); trace.addAll(before.trace); pendingFailure = before.pendingFailure; }
        WireValue wire() { return obj("available", arr(available), "used_sites", arr(usedSites), "used_guards", arr(usedGuards), "facts", arr(facts), "trace", arr(trace), "pending_failure", pendingFailure); }
        static State from(WireValue value) {
            State state = new State(); state.available.addAll(a(f(value, "available"))); state.usedSites.addAll(a(f(value, "used_sites"))); state.usedGuards.addAll(a(f(value, "used_guards"))); state.facts.addAll(a(f(value, "facts"))); state.trace.addAll(a(f(value, "trace"))); state.pendingFailure = f(value, "pending_failure"); return state;
        }
    }
    private static final class Checker {
        final WireValue input, problem, raw, basis, domain, goal, bounds;
        final Context context; final Inclusions inclusions;
        final List<WireValue> signatures, initials, initialLots, guards, sites;
        int planNodes;
        Checker(WireValue input, Context context) throws ValueFailure {
            input=TypeSignatures.replace(input,"composition",TypeSignatures.internalComposition(f(input,"composition")));
            this.input = input; this.problem = f(f(input, "composition"), "problem"); this.raw = f(f(input, "composition"), "derivation"); this.context = context;
            basis = TypeSignatures.problemBasis(f(input, "basis"));
            domain = f(problem, "invocation_domain"); goal = f(problem, "goal"); bounds = f(problem, "bounds");
            signatures = a(f(problem, "signatures")); initials = a(f(problem, "initial_inputs")); initialLots = a(f(problem, "initial_resources")); guards = a(f(domain, "guards")); sites = a(f(domain, "sites")); inclusions = new Inclusions(context, basis);
        }
        String resourceTypeIdentity(WireValue reference) { return typeIdentity(reference); }
        WireValue signature(WireValue reference) throws GenerationFailure {
            WireValue signature = find(signatures, "reference", reference); require(signature != null, "$signature", "resolved function revision"); return signature;
        }
        WireValue siteSignature(WireValue site) throws GenerationFailure {
            WireValue declaration = find(sites, "id", site); require(declaration != null, "$site", "resolved site"); return signature(f(declaration, "function"));
        }
        void verify() throws GenerationFailure, ValueFailure {
            prepare(); WireValue plan = f(raw, "plan"), witness = f(raw, "witness");
            require(f(plan, "input_identity").equals(f(problem, "identity")) && f(plan, "input_revision").equals(f(problem, "revision")) && f(witness, "input_snapshot").equals(problem), "$composition", "input snapshot/revision");
            require(a(f(witness, "initial_membership")).size() == initials.size(), "$composition", "initial membership coverage");
            for (WireValue initial : initials) {
                WireValue value = tupleLookup(f(witness, "initial_membership"), f(initial, "id")); context.validateContract(f(initial, "contract"), exchangeSlot(value));
                if (tag(f(initial, "source")).equals("SuppliedValue")) require(value.equals(payload(f(initial, "source"))), "$composition", "supplied initial value");
            }
            Set<WireValue> usedCertificates = new HashSet<>();
            require(verifyTree(initialState(), f(plan, "root"), null, witness, usedCertificates), "$composition", "no successful goal branch");
            require(usedCertificates.size() == a(f(witness, "resource_traces")).size(), "$composition", "extraneous branch evidence");
            WireValue selection = f(raw, "selection"), policy = f(problem, "selection_policy");
            if (tag(selection).equals("AnyFeasible")) require(!nil(policy) && tag(policy).equals("AnyFeasible"), "$selection", "caller policy mismatch");
            else {
                require(nil(policy) || !tag(policy).equals("AnyFeasible"), "$selection", "caller policy mismatch");
                Set<String> plans = verifyClosure(f(payload(selection), "closure"));
                String key = candidateKey(a(f(witness, "resource_traces")));
                require(plans.size() == 1 && plans.contains(key) && s(f(payload(selection), "canonical_plan")).equals(key), "$selection", "finite-domain uniqueness");
            }
        }
        void prepare() throws GenerationFailure, ValueFailure {
            require(f(problem, "basis").equals(basis), "$problem.basis", "semantic basis mismatch");
            for (String field : List.of("identity", "revision")) require(!s(f(problem, field)).isEmpty(), "$problem", "identity/revision");
            unique(initials, "id", "$initials"); unique(initialLots, "id", "$resources"); unique(sites, "id", "$sites"); unique(guards, "id", "$guards");
            unique(a(f(goal, "outputs")), "id", "$goals"); unique(a(f(goal, "failures")), "id", "$failures"); require(!a(f(goal, "outputs")).isEmpty(), "$goals", "goal outputs");
            Set<WireValue> functions = new HashSet<>();
            for (WireValue function : signatures) {
                WireValue reference = f(function, "reference"); require(functions.add(reference) && !s(f(reference, "identity")).isEmpty() && !s(f(reference, "revision")).isEmpty() && !s(f(function, "assumption_ref")).isEmpty(), "$signature", "versioned function-body assumption");
                unique(a(f(function, "inputs")), "id", "$ports"); unique(a(f(function, "outcomes")), "id", "$outcomes"); unique(a(f(function, "resource_inputs")), "id", "$requirements"); require(!a(f(function, "outcomes")).isEmpty(), "$outcomes", "declared outcomes");
                String form = tag(f(function, "form")), effect = tag(f(function, "effect"));
                if (form.equals("Operation")) operationSignature(function, payload(f(function, "form")));
                else {
                    require(effect.equals("PureFunction"), "$signature", "pure function effect");
                    for (WireValue definition : a(f(context.graph, "definitions"))) if (tag(f(definition, "shape")).equals("Operation")) {
                        require(!f(definition,"wire_identity").equals(f(reference,"identity")), "$signature", "operation form required");
                    }
                }
                for (WireValue port : a(f(function, "inputs"))) { context.index(f(f(port, "contract"), "type_ref")); sourceConstraint(f(port, "source_constraint")); if (!nil(f(port, "resource_requirement"))) require(find(a(f(function, "resource_inputs")), "id", f(port, "resource_requirement")) != null, "$ports", "resource backing"); }
                for (WireValue requirement : a(f(function, "resource_inputs"))) { context.index(f(requirement, "token_type")); require(n(f(requirement, "multiplicity")).signum() > 0, "$requirements", "positive multiplicity"); }
                for (WireValue outcome : a(f(function, "outcomes"))) {
                    TypeSignatures.checkCompositionOutcome(f(input,"signatures"),outcome);
                    unique(a(f(outcome, "value_ports")), "id", "$outputs"); unique(a(f(outcome, "produced_resources")), "id", "$productions");
                    for (WireValue port : a(f(outcome, "value_ports"))) { context.index(f(f(port, "contract"), "type_ref")); if (!nil(f(port, "resource_production"))) require(find(a(f(outcome, "produced_resources")), "id", f(port, "resource_production")) != null, "$outputs", "production backing"); }
                    for (WireValue production : a(f(outcome, "produced_resources"))) context.index(f(production, "token_type"));
                }
            }
            for (WireValue site : sites) {
                WireValue function = signature(f(site, "function")); require(a(f(problem, "allowed_effects")).contains(f(function, "effect")), "$sites", "allowed effect");
                require(!tag(f(function, "form")).equals("DeclaredTransform") || a(f(domain, "permitted_transforms")).contains(f(function, "reference")), "$sites", "permitted transform");
            }
            for (WireValue initial : initials) {
                context.index(f(f(initial, "contract"), "type_ref"));
                if (tag(f(initial, "source")).equals("SuppliedValue")) context.validateContract(f(initial, "contract"), exchangeSlot(payload(f(initial, "source"))));
                if (!nil(f(initial, "resource"))) require(find(initialLots, "id", f(initial, "resource")) != null, "$initials", "resource lot backing");
            }
            for (WireValue lot : initialLots) {
                context.index(f(lot, "token_type")); require(tag(f(lot, "producer")).equals("Initial") && !s(f(payload(f(lot, "producer")), "identity")).isEmpty() && !s(f(payload(f(lot, "producer")), "revision")).isEmpty() && !s(f(lot, "provenance")).isEmpty(), "$resources", "initial producer/provenance");
            }
            for (WireValue output : a(f(goal, "outputs"))) { context.index(f(f(output, "contract"), "type_ref")); sourceConstraint(f(output, "source_constraint")); }
            for (WireValue embedding : a(f(goal, "failures"))) { context.index(f(f(embedding, "contract"), "type_ref")); failureOrigin(f(embedding, "origin")); for (WireValue resource : a(f(embedding, "final_resources"))) lot(f(resource, "lot")); }
            for (WireValue function : signatures) if (!nil(f(function, "handles_failure"))) failureOrigin(f(function, "handles_failure"));
            for (WireValue resource : a(f(goal, "final_resources"))) lot(f(resource, "lot"));
            for (WireValue projection : a(f(domain, "permitted_projections"))) context.index(f(projection, "source_type"));
            for (WireValue guard : guards) { context.index(f(guard, "source_type")); if (tag(f(guard, "kind")).equals("Validate")) context.meaning(context.index(f(payload(f(guard, "kind")), "type_ref"))); }
            List<WireValue> constructions = a(f(domain, "permitted_constructions")); unique(constructions, "identity", "$constructions");
            for (WireValue construction : constructions) {
                WireValue shape = context.resolve(f(construction, "type_ref")); require(shape != null && tag(shape).equals("Product"), "$construction", "resolved product");
                Set<WireValue> seen = new HashSet<>();
                for (WireValue nested : a(f(construction, "nested_fields"))) {
                    require(seen.add(a(nested).get(0)), "$construction", "unique nested field");
                    WireValue field = find(a(f(payload(shape), "fields")), "wire_name", a(nested).get(0)), target = find(constructions, "identity", a(nested).get(1));
                    require(field != null && target != null && f(target, "type_ref").equals(f(f(field, "slot"), "type_ref")), "$construction", "nested rule/type");
                }
                for (WireValue constrained : a(f(construction, "field_constraints"))) {
                    WireValue name = f(constrained, "field");
                    require(seen.add(name), "$construction", "unique non-nested constrained field");
                    require(find(a(f(payload(shape), "fields")), "wire_name", name) != null, "$construction", "declared constrained field");
                    sourceConstraint(f(constrained, "source"));
                }
                constructionAcyclic(f(construction, "identity"), new HashSet<>());
            }
            for (WireValue order : a(f(problem, "explicit_order"))) require(!a(order).get(0).equals(a(order).get(1)) && find(sites, "id", a(order).get(0)) != null && find(sites, "id", a(order).get(1)) != null, "$order", "site order");
        }
        void constructionAcyclic(WireValue id, Set<WireValue> active) throws GenerationFailure {
            require(active.add(id), "$construction", "acyclic expansion"); WireValue rule = find(a(f(domain, "permitted_constructions")), "identity", id); require(rule != null, "$construction", "rule");
            for (WireValue nested : a(f(rule, "nested_fields"))) constructionAcyclic(a(nested).get(1), active); active.remove(id);
        }
        void operationSignature(WireValue function, WireValue reference) throws GenerationFailure {
            TypeSignatures.checkOperationSignatureValue(f(input, "signatures"), s(reference), function);
        }
        void sourceConstraint(WireValue constraint) throws GenerationFailure {
            if (tag(constraint).equals("AnyCompatible")) return;
            WireValue p = payload(constraint), source;
            if (tag(constraint).equals("InitialOnly")) {
                WireValue initial = find(initials, "id", f(p, "input")); require(initial != null, "$source_constraint", "initial");
                source = f(initial, "contract");
            } else {
                WireValue function = siteSignature(f(p, "site")), outcome = find(a(f(function, "outcomes")), "id", f(p, "outcome"));
                require(outcome != null, "$source_constraint", "outcome");
                WireValue port = find(a(f(outcome, "value_ports")), "id", f(p, "port")); require(port != null, "$source_constraint", "outcome port");
                source = f(port, "contract");
            }
            constraintPath(f(source, "type_ref"), a(f(p, "path")));
        }
        void constraintPath(WireValue reference, List<WireValue> path) throws GenerationFailure {
            int position = 0; Set<WireValue> visited = new HashSet<>();
            while (position < path.size()) {
                require(visited.add(arr(List.of(reference, str(Integer.toString(position))))), "$source_constraint", "productive reference path");
                WireValue shape = context.shape(context.index(reference)), spec = payload(shape), step = path.get(position);
                if (tag(shape).equals("Alias")) { reference = f(spec, "target"); continue; }
                if (tag(shape).equals("Record")) { reference = f(spec, "payload"); continue; }
                if (tag(shape).equals("Product") && tag(step).equals("Field")) {
                    WireValue field = find(a(f(spec, "fields")), "wire_name", payload(step)); require(field != null, "$source_constraint", "field");
                    reference = f(f(field, "slot"), "type_ref");
                } else if (tag(shape).equals("Array") && tag(step).equals("Index")) reference = f(spec, "item");
                else if (tag(shape).equals("TaggedUnion") && tag(step).equals("Variant")) {
                    WireValue branch = find(a(f(spec, "branches")), "wire_tag", payload(step)); require(branch != null, "$source_constraint", "branch");
                    reference = f(branch, "target");
                } else throw new GenerationFailure("$source_constraint", "shape/path mismatch");
                position++;
            }
            context.index(reference);
        }
        WireValue fieldConstraint(WireValue construction, WireValue name) {
            for (WireValue constrained : a(f(construction, "field_constraints"))) if (f(constrained, "field").equals(name)) return f(constrained, "source");
            return variant("AnyCompatible");
        }
        boolean fieldRequired(WireValue construction, WireValue field) {
            if (b(f(f(field, "slot"), "required"))) return true;
            for (WireValue constrained : a(f(construction, "field_constraints"))) if (f(constrained, "field").equals(f(field, "wire_name"))) return tag(f(constrained, "presence")).equals("Required");
            return false;
        }
        void failureOrigin(WireValue origin) throws GenerationFailure {
            WireValue p = payload(origin);
            if (tag(origin).equals("Guard")) require(find(guards, "id", f(p, "guard")) != null, "$failure", "declared guard");
            else { WireValue outcome = find(a(f(signature(f(p, "function")), "outcomes")), "id", f(p, "outcome")); require(outcome != null && tag(f(outcome, "form")).equals("DeclaredFailure"), "$failure", "declared failure outcome"); }
        }
        State initialState() {
            State state = new State();
            for (WireValue initial : initials) state.available.add(obj("producer", initialProducer(f(initial, "id")), "contract", f(initial, "contract"), "resource", nil(f(initial, "resource")) ? NIL : variant("Initial", f(initial, "resource"))));
            return state;
        }
        boolean allows(WireValue constraint, WireValue value) {
            if (tag(constraint).equals("AnyCompatible")) return true;
            WireValue p = payload(constraint), producer = f(value, "producer");
            if (!f(p, "path").equals(f(value, "path"))) return false;
            return switch (tag(constraint)) {
                case "InitialOnly" -> tag(producer).equals("Initial") && f(p, "input").equals(payload(producer));
                case "ProducedBy" -> tag(producer).equals("InvocationOutcome") && f(p, "site").equals(f(payload(producer), "site")) && f(p, "outcome").equals(f(payload(producer), "outcome")) && f(p, "port").equals(f(payload(producer), "port"));
                default -> false;
            };
        }
        WireValue lot(WireValue reference) throws GenerationFailure {
            if (tag(reference).equals("Initial")) { WireValue lot = find(initialLots, "id", payload(reference)); require(lot != null, "$resource", "initial lot"); return lot; }
            WireValue p = payload(reference), function = siteSignature(f(p, "site")), outcome = find(a(f(function, "outcomes")), "id", f(p, "outcome")); require(outcome != null, "$resource", "outcome");
            WireValue production = find(a(f(outcome, "produced_resources")), "id", f(p, "production")); require(production != null, "$resource", "production");
            return obj("id", f(p, "production"), "token_type", f(production, "token_type"), "producer", fields("InvocationOutcome", obj("site", f(p, "site"), "outcome", f(p, "outcome"))), "revision", f(production, "revision"), "quantity", f(production, "quantity"), "provenance", f(production, "provenance"));
        }
        WireValue declaredValue(WireValue producer) throws GenerationFailure {
            if (tag(producer).equals("Initial")) { WireValue initial = find(initials, "id", payload(producer)); require(initial != null, "$producer", "initial"); return obj("producer", producer, "contract", f(initial, "contract"), "resource", nil(f(initial, "resource")) ? NIL : variant("Initial", f(initial, "resource"))); }
            WireValue p = payload(producer), outcome = find(a(f(siteSignature(f(p, "site")), "outcomes")), "id", f(p, "outcome")); require(outcome != null, "$producer", "outcome"); WireValue port = find(a(f(outcome, "value_ports")), "id", f(p, "port")); require(port != null, "$producer", "port");
            return obj("producer", producer, "contract", f(port, "contract"), "resource", nil(f(port, "resource_production")) ? NIL : producedLot(f(p, "site"), f(p, "outcome"), f(port, "resource_production")));
        }
        List<WireValue> stateLots(State state) throws GenerationFailure {
            List<WireValue> result = new ArrayList<>(); for (WireValue lot : initialLots) result.add(variant("Initial", f(lot, "id")));
            for (WireValue step : state.trace) if (tag(step).equals("Invocation")) {
                WireValue p = payload(step), invocation = f(p, "invocation"), outcome = find(a(f(siteSignature(f(invocation, "site")), "outcomes")), "id", f(p, "outcome"));
                for (WireValue production : a(f(outcome, "produced_resources"))) result.add(producedLot(f(invocation, "site"), f(p, "outcome"), f(production, "id")));
            }
            return result;
        }
        WireValue effectiveProjection(State state, WireValue value) throws GenerationFailure, ValueFailure {
            WireValue source = find(state.available, "producer", f(value, "producer")); require(source != null, "$projection", "earlier producer");
            WireValue contract = f(source, "contract"); List<WireValue> prefix = List.of(), path = a(f(value, "path")), assumptions = new ArrayList<>();
            for (int i = state.facts.size() - 1; i >= 0; i--) {
                WireValue fact = state.facts.get(i), inspected = f(fact, "inspected");
                if (f(inspected, "producer").equals(f(value, "producer")) && !nil(f(fact, "refinement")) && starts(path, a(f(inspected, "path")))) { contract = f(fact, "refinement"); prefix = a(f(inspected, "path")); break; }
            }
            for (WireValue fact : state.facts) if (f(f(fact, "inspected"), "producer").equals(f(value, "producer"))) for (WireValue assumption : a(f(fact, "assumptions"))) {
                List<WireValue> at = assumptionPath(assumption); if (!starts(at, prefix)) continue; List<WireValue> relative = at.subList(prefix.size(), at.size());
                assumptions.add(Set.of("Present", "NonNull").contains(tag(assumption)) ? variant(tag(assumption), arr(relative)) : fields(tag(assumption), tag(assumption).equals("Variant") ? obj("path", arr(relative), "tag", f(payload(assumption), "tag")) : obj("path", arr(relative), "index", f(payload(assumption), "index"))));
            }
            return projection(context, arr(List.of()), contract, path.subList(prefix.size(), path.size()), assumptions);
        }
        Slot<WireValue> exactValue(State state, WireValue value) throws GenerationFailure {
            List<WireValue> path = a(f(value, "path"));
            for (int i = state.facts.size() - 1; i >= 0; i--) {
                WireValue fact = state.facts.get(i), inspected = f(fact, "inspected"); if (f(inspected, "producer").equals(f(value, "producer")) && !nil(f(fact, "exact")) && starts(path, a(f(inspected, "path")))) return projectSlotValue(context, exchangeSlot(f(fact, "exact")), path.subList(a(f(inspected, "path")).size(), path.size()));
            }
            WireValue producer = f(value, "producer"); if (!tag(producer).equals("Initial")) return null;
            WireValue initial = find(initials, "id", payload(producer)); require(initial != null, "$producer", "initial declaration");
            return tag(f(initial, "source")).equals("SuppliedValue") ? projectSlotValue(context, exchangeSlot(payload(f(initial, "source"))), path) : null;
        }
        void binding(State state, WireValue expression, WireValue destination, WireValue constraint) throws GenerationFailure, ValueFailure {
            WireValue p = payload(expression);
            if (tag(expression).equals("Source")) {
                WireValue value = f(p, "value"), source = find(state.available, "producer", f(value, "producer")); require(source != null && allows(constraint, value), "$binding", "producer/path source constraint");
                List<WireValue> path = a(f(value, "path"));
                require(path.isEmpty() || a(f(domain, "permitted_projections")).stream().anyMatch(v -> f(v, "source_type").equals(f(f(source, "contract"), "type_ref")) && f(v, "path").equals(f(value, "path"))) || guards.stream().anyMatch(v -> f(v, "source_type").equals(f(f(source, "contract"), "type_ref")) && f(v, "path").equals(f(value, "path"))), "$binding", "permitted projection");
                WireValue expected = effectiveProjection(state, value); require(expected.equals(f(p, "projection")), "$projection", "source/path/dominating guards");
                Slot<WireValue> exact = exactValue(state, value); require(!inclusions.emptySlot(f(expected, "destination")) && (exact == null || inclusions.accepts(f(expected, "destination"), exact)), "$binding", "inhabited source");
                WireValue compatibility = f(p, "compatibility");
                if (tag(compatibility).equals("Inclusion")) inclusions.verify(f(expected, "destination"), destination, payload(compatibility));
                else {
                    Slot<WireValue> supplied = exchangeSlot(f(payload(compatibility), "value")); require(exact != null && exact.equals(supplied), "$binding", "exact supplied value");
                    context.validateContract(f(expected, "destination"), supplied); context.validateContract(destination, supplied);
                }
            } else {
                WireValue type = f(p, "type_ref"), construction = find(a(f(domain, "permitted_constructions")), "identity", f(p, "construction"));
                require(construction != null && f(construction, "type_ref").equals(type) && type.equals(f(destination, "type_ref")) && tag(constraint).equals("AnyCompatible"), "$binding", "declared product construction");
                WireValue shape = context.resolve(type); require(shape != null && tag(shape).equals("Product"), "$binding", "product"); context.meaning(context.index(type)); Set<WireValue> present = new HashSet<>();
                for (WireValue tuple : a(f(p, "fields"))) {
                    WireValue name = a(tuple).get(0), child = a(tuple).get(1), field = find(a(f(payload(shape), "fields")), "wire_name", name); require(field != null && present.add(name), "$binding", "product field coverage");
                    if (tag(child).equals("Product")) require(a(f(construction, "nested_fields")).contains(arr(List.of(name, f(payload(child), "construction")))), "$binding", "nested construction rule");
                    if (!b(f(f(field, "slot"), "nullable")) && tag(child).equals("Source")) {
                        WireValue sourceValue = f(payload(child), "value"); Slot<WireValue> exact = exactValue(state, sourceValue);
                        WireValue projected = f(effectiveProjection(state, sourceValue), "destination"), resolved = context.resolve(f(projected, "type_ref"));
                        boolean presentNull = exact instanceof Present<WireValue> actual && nil(actual.value()) || exact == null && resolved != null && (tag(resolved).equals("Unit") || tag(resolved).equals("Unknown") && !context.ordinaryOnly());
                        require(!presentNull, "$binding", "explicit null cannot satisfy a non-null field");
                    }
                    if (s(name).equals(context.tagKey()) && !context.tagKey().isEmpty()) {
                        require(tag(child).equals("Source"), "$binding", "string discriminator source");
                        WireValue sourceValue = f(payload(child), "value"); Slot<WireValue> exact = exactValue(state, sourceValue); List<WireValue> tags = new ArrayList<>();
                        if (exact instanceof Present<WireValue> actual && actual.value() instanceof StringValue) tags.add(actual.value());
                        else if (exact instanceof Absent<WireValue>) {}
                        else {
                            WireValue projected = f(effectiveProjection(state, sourceValue), "destination"), resolved = context.resolve(f(projected, "type_ref"));
                            require(exact == null && !b(f(projected, "nullable")) && resolved != null && tag(resolved).equals("String"), "$binding", "finite discriminator implication");
                            List<WireValue> finite = inclusions.finiteStrings(f(projected, "type_ref"), payload(resolved)); require(finite != null, "$binding", "finite discriminator cases"); tags.addAll(finite);
                        }
                        for (WireValue discriminator : tags) require((context.ordinaryTagAccepted(discriminator) && (!context.ordinaryOnly() || !s(discriminator).equals(context.tagKey()))), "$binding", "canonical plain-object discriminator");
                    }
                    binding(state, child, f(field, "slot"), fieldConstraint(construction, name));
                }
                for (WireValue field : a(f(payload(shape), "fields"))) require(!fieldRequired(construction, field) || present.contains(f(field, "wire_name")), "$binding", "required construction field");
            }
        }
        void invocation(State state, WireValue invocation) throws GenerationFailure, ValueFailure {
            WireValue site = f(invocation, "site"), function = siteSignature(site);
            require(f(function, "reference").equals(f(invocation, "function")) && !state.usedSites.contains(site) && (f(function, "handles_failure").equals(state.pendingFailure) || nil(f(function, "handles_failure")) && !mustHandle(state.pendingFailure)), "$invocation", "function revision/site/failure handler");
            for (WireValue order : a(f(problem, "explicit_order"))) require(!a(order).get(1).equals(site) || state.usedSites.contains(a(order).get(0)), "$invocation", "explicit order");
            require(a(f(invocation, "bindings")).size() == a(f(function, "inputs")).size() && a(f(invocation, "resources")).size() == a(f(function, "resource_inputs")).size(), "$invocation", "binding coverage");
            for (WireValue port : a(f(function, "inputs"))) {
                WireValue expression = tupleLookup(f(invocation, "bindings"), f(port, "id")); binding(state, expression, f(port, "contract"), f(port, "source_constraint"));
                if (!nil(f(port, "resource_requirement"))) {
                    WireValue selected = find(a(f(invocation, "resources")), "requirement", f(port, "resource_requirement")); List<WireValue> sources = bindingSources(expression);
                    require(selected != null && sources.size() == 1 && f(declaredValue(f(sources.get(0), "producer")), "resource").equals(f(selected, "lot")), "$invocation", "input backing lot");
                }
            }
            List<WireValue> lots = stateLots(state); Set<WireValue> requirements = new HashSet<>();
            for (WireValue selected : a(f(invocation, "resources"))) {
                WireValue requirement = find(a(f(function, "resource_inputs")), "id", f(selected, "requirement")); require(requirement != null && requirements.add(f(selected, "requirement")) && lots.contains(f(selected, "lot")), "$invocation", "resource supply");
                WireValue lot = lot(f(selected, "lot")); require(f(lot, "revision").equals(f(requirement, "required_revision")) && (tag(f(requirement, "identity")).equals("Any") || payload(f(requirement, "identity")).equals(f(lot, "producer"))), "$invocation", "resource producer/revision");
                inclusions.verify(contract(f(lot, "token_type"), true, false), contract(f(requirement, "token_type"), true, false), f(selected, "inclusion"));
            }
            if (!nil(f(function, "handles_failure"))) require(usesFailure(state, f(function, "handles_failure"), a(f(invocation, "bindings")).stream().flatMap(tuple -> bindingSources(a(tuple).get(1)).stream()).toList()), "$invocation", "actual failure binding");
        }
        State afterInvocation(State state, WireValue invocation, WireValue outcome) throws GenerationFailure {
            State next = new State(state); next.usedSites.add(f(invocation, "site"));
            for (WireValue port : a(f(outcome, "value_ports"))) next.available.add(obj("producer", outcomeProducer(f(invocation, "site"), f(outcome, "id"), f(port, "id")), "contract", f(port, "contract"), "resource", nil(f(port, "resource_production")) ? NIL : producedLot(f(invocation, "site"), f(outcome, "id"), f(port, "resource_production"))));
            next.trace.add(fields("Invocation", obj("invocation", invocation, "outcome", f(outcome, "id"))));
            next.pendingFailure = tag(f(outcome, "form")).equals("Success") ? NIL : fields("Function", obj("function", f(invocation, "function"), "outcome", f(outcome, "id"))); return next;
        }
        List<WireValue> guardArms(State state, WireValue guard, WireValue inspected) throws GenerationFailure, ValueFailure {
            WireValue source = find(state.available, "producer", f(inspected, "producer")); require(!state.usedGuards.contains(f(guard, "id")) && source != null && f(f(source, "contract"), "type_ref").equals(f(guard, "source_type")) && f(inspected, "path").equals(f(guard, "path")), "$guard", "declaration/producer/path");
            WireValue projected = f(effectiveProjection(state, inspected), "destination"); Slot<WireValue> exact = exactValue(state, inspected);
            if (exact != null) return List.of(guardArm(context, guard, exact, projected));
            List<WireValue> result = new ArrayList<>();
            if (tag(f(guard, "kind")).equals("Validate")) {
                WireValue destination = payload(f(guard, "kind"));
                if (disjoint(projected, destination)) result.add(variant("Rejected"));
                else if (inclusions.compatible(projected, destination)) result.add(variant("Accepted"));
                else { result.add(variant("Accepted")); result.add(variant("Rejected")); }
            } else {
                if (!b(f(projected, "required"))) result.add(variant("Absent")); if (b(f(projected, "nullable"))) result.add(variant("Null"));
                if (!inclusions.empty.contains(f(projected, "type_ref"))) {
                    if (tag(f(guard, "kind")).equals("Presence")) result.add(variant("Present"));
                    else {
                        WireValue shape = context.resolve(f(projected, "type_ref")); require(shape != null && tag(shape).equals("TaggedUnion"), "$guard", "union refinement");
                        for (WireValue branch : a(f(payload(shape), "branches"))) if (!inclusions.empty.contains(f(branch, "target"))) result.add(variant("Variant", f(branch, "wire_tag")));
                        if (!b(f(payload(shape), "closed"))) result.add(variant("UnknownVariant"));
                    }
                }
            }
            return result;
        }
        boolean disjoint(WireValue source, WireValue destination) throws ValueFailure {
            if (!b(f(source, "required")) && !b(f(destination, "required")) || b(f(source, "nullable")) && b(f(destination, "nullable"))) return false;
            if (inclusions.empty.contains(f(source, "type_ref")) || inclusions.empty.contains(f(destination, "type_ref"))) return true;
            WireValue ss = context.resolve(f(source, "type_ref")), ds = context.resolve(f(destination, "type_ref")); if (ss == null || ds == null) return false;
            String sk = tag(ss), dk = tag(ds);
            if (sk.equals("Unknown") || dk.equals("Unknown")) return false;
            if (!sk.equals(dk)) return !Set.of("TaggedUnion", "Product", "Sealed").contains(sk) || !Set.of("TaggedUnion", "Product", "Sealed").contains(dk);
            WireValue s = o(ss).get("value"), d = o(ds).get("value");
            if (sk.equals("Integer")) {
                List<BigInteger> finite = inclusions.finiteIntegers(s), target = inclusions.finiteIntegers(d); BigInteger[] sb = inclusions.integerBounds(s), db = inclusions.integerBounds(d);
                if (finite != null) return finite.stream().allMatch(value -> !within(value, db) || !nil(f(d, "enum_values")) && !a(f(d, "enum_values")).contains(str(value.toString())));
                if (target != null) return target.stream().allMatch(value -> !within(value, sb));
                BigInteger min = db[0] == null ? sb[0] : lower(sb[0], db[0]), max = db[1] == null ? sb[1] : upper(sb[1], db[1]); return min != null && max != null && min.compareTo(max) > 0;
            }
            if (sk.equals("Boolean")) return !nil(f(s, "const_value")) && !nil(f(d, "const_value")) && !f(s, "const_value").equals(f(d, "const_value"));
            if (sk.equals("String")) {
                List<WireValue> finite = inclusions.finiteStrings(f(source, "type_ref"), s); if (finite != null) { for (WireValue value : finite) if (inclusions.accepts(destination, new Present<>(value))) return false; return true; }
                finite = inclusions.finiteStrings(f(destination, "type_ref"), d); if (finite != null) { for (WireValue value : finite) if (inclusions.accepts(source, new Present<>(value))) return false; return true; }
            }
            if (sk.equals("String") || sk.equals("Array")) {
                BigInteger min = nil(f(s, "min_length")) ? BigInteger.ZERO : n(f(s, "min_length")), max = nil(f(s, "max_length")) ? null : n(f(s, "max_length"));
                if (!nil(f(d, "min_length"))) min = min.max(n(f(d, "min_length"))); if (!nil(f(d, "max_length"))) max = upper(max, n(f(d, "max_length"))); return max != null && min.compareTo(max) > 0;
            }
            return false;
        }
        State afterGuard(State state, WireValue guard, WireValue inspected, WireValue arm) throws GenerationFailure, ValueFailure {
            WireValue projected = f(effectiveProjection(state, inspected), "destination"), refinement = NIL, exact = NIL; List<WireValue> assumptions = new ArrayList<>(); String kind = tag(arm);
            if (kind.equals("Present") || kind.equals("UnknownVariant")) refinement = contract(f(projected, "type_ref"), true, false);
            else if (kind.equals("Accepted")) refinement = payload(f(guard, "kind"));
            else if (kind.equals("Variant")) assumptions.add(fields("Variant", obj("path", f(inspected, "path"), "tag", payload(arm))));
            else if (kind.equals("Absent") || kind.equals("Null")) exact = variant(kind);
            Slot<WireValue> fixed = exactValue(state, inspected); if (fixed != null) exact = encodeSlot(fixed);
            State next = new State(state); next.usedGuards.add(f(guard, "id")); next.facts.add(obj("guard", f(guard, "id"), "inspected", inspected, "arm", arm, "refinement", refinement, "assumptions", arr(assumptions), "exact", exact));
            next.trace.add(fields("Guard", obj("guard", f(guard, "id"), "inspected", inspected, "arm", arm)));
            if (!mustHandle(state.pendingFailure) && Set.of("Absent", "Null", "UnknownVariant", "Rejected").contains(kind)) next.pendingFailure = fields("Guard", obj("guard", f(guard, "id"), "arm", arm));
            return next;
        }
        boolean usesFailure(State state, WireValue origin, List<WireValue> sources) {
            WireValue p = payload(origin);
            if (tag(origin).equals("Function")) {
                for (int i = state.trace.size() - 1; i >= 0; i--) {
                    WireValue step = state.trace.get(i); if (!tag(step).equals("Invocation")) continue; WireValue invocation = f(payload(step), "invocation");
                    if (f(invocation, "function").equals(f(p, "function")) && f(payload(step), "outcome").equals(f(p, "outcome"))) return sources.stream().anyMatch(source -> tag(f(source, "producer")).equals("InvocationOutcome") && f(payload(f(source, "producer")), "site").equals(f(invocation, "site")) && f(payload(f(source, "producer")), "outcome").equals(f(p, "outcome")));
                }
            } else for (int i = state.facts.size() - 1; i >= 0; i--) {
                WireValue fact = state.facts.get(i); if (f(fact, "guard").equals(f(p, "guard")) && f(fact, "arm").equals(f(p, "arm"))) return sources.stream().anyMatch(source -> f(source, "producer").equals(f(f(fact, "inspected"), "producer")) && starts(a(f(source, "path")), a(f(f(fact, "inspected"), "path"))));
            }
            return false;
        }
        boolean terminal(State state, WireValue terminal) throws GenerationFailure, ValueFailure {
            if (tag(terminal).equals("Success")) {
                require(!mustHandle(state.pendingFailure) && a(payload(terminal)).size() == a(f(goal, "outputs")).size(), "$return", "goal/failure coverage");
                for (WireValue output : a(f(goal, "outputs"))) binding(state, tupleLookup(payload(terminal), f(output, "id")), f(output, "contract"), f(output, "source_constraint")); return true;
            }
            WireValue p = payload(terminal), embedding = find(a(f(goal, "failures")), "id", f(p, "embedding")); require(embedding != null && f(embedding, "origin").equals(state.pendingFailure), "$return", "failure embedding origin");
            binding(state, f(p, "value"), f(embedding, "contract"), variant("AnyCompatible")); require(usesFailure(state, f(embedding, "origin"), bindingSources(f(p, "value"))), "$return", "actual failure value"); return false;
        }
        boolean emptyOutcome(WireValue outcome) { return a(f(outcome, "value_ports")).stream().anyMatch(port -> inclusions.emptySlot(f(port, "contract"))); }
        boolean verifyTree(State state, WireValue tree, BigInteger parentRank, WireValue witness, Set<WireValue> used) throws GenerationFailure, ValueFailure {
            BigInteger rank = n(f(tree, "rank")); require(BigInteger.valueOf(++planNodes).compareTo(n(f(bounds, "max_branch_nodes"))) <= 0 && (parentRank == null || rank.compareTo(parentRank) > 0), "$plan", "finite dependency rank");
            WireValue node = f(tree, "node"), p = payload(node); boolean success = false;
            if (tag(node).equals("Return")) {
                success = terminal(state, p); WireValue trace = obj("steps", arr(state.trace), "terminal", p), certificate = null;
                for (WireValue candidate : a(f(witness, "resource_traces"))) if (f(candidate, "trace").equals(trace)) { require(certificate == null, "$witness", "one branch certificate"); certificate = candidate; }
                require(certificate != null && used.add(certificate), "$witness", "branch resource/producer evidence"); verifyTrace(state, p, certificate);
            } else if (tag(node).equals("Invoke")) {
                WireValue invocation = f(p, "invocation"); invocation(state, invocation); WireValue function = siteSignature(f(invocation, "site"));
                List<WireValue> expected = new ArrayList<>(), empty = new ArrayList<>();
                for (WireValue outcome : a(f(function, "outcomes"))) (emptyOutcome(outcome) ? empty : expected).add(f(outcome, "id"));
                require(multiset(expected).equals(multiset(a(f(p, "arms")).stream().map(tuple -> a(tuple).get(0)).toList())) && multiset(empty).equals(multiset(a(f(p, "empty_outcomes")))) && !expected.isEmpty(), "$plan", "all outcome branches");
                for (WireValue arm : a(f(p, "arms"))) success |= verifyTree(afterInvocation(state, invocation, find(a(f(function, "outcomes")), "id", a(arm).get(0))), a(arm).get(1), rank, witness, used);
            } else {
                WireValue guard = find(guards, "id", f(p, "guard")); require(guard != null, "$plan", "guard declaration"); List<WireValue> expected = guardArms(state, guard, f(p, "inspected"));
                require(!expected.isEmpty() && multiset(expected).equals(multiset(a(f(p, "arms")).stream().map(tuple -> a(tuple).get(0)).toList())), "$plan", "all guard branches");
                for (WireValue arm : a(f(p, "arms"))) success |= verifyTree(afterGuard(state, guard, f(p, "inspected"), a(arm).get(0)), a(arm).get(1), rank, witness, used);
            }
            return success;
        }
        void verifyTrace(State state, WireValue terminal, WireValue certificate) throws GenerationFailure, ValueFailure {
            require(f(certificate, "trace").equals(obj("steps", arr(state.trace), "terminal", terminal)), "$resource_trace", "branch trace");
            WireValue models = f(certificate, "value_sources"); require(a(models).size() == state.available.size(), "$value_models", "producer coverage");
            Map<WireValue, Slot<WireValue>> values = new LinkedHashMap<>();
            for (WireValue model : a(models)) require(values.put(a(model).get(0), exchangeSlot(a(model).get(1))) == null, "$value_models", "unique producer");
            for (WireValue available : state.available) {
                WireValue producer = f(available, "producer"); require(values.containsKey(producer), "$value_models", "producer"); context.validateContract(f(available, "contract"), values.get(producer));
                if (tag(producer).equals("Initial")) {
                    WireValue initial = find(initials, "id", payload(producer));
                    if (tag(f(initial, "source")).equals("SuppliedValue")) require(values.get(producer).equals(exchangeSlot(payload(f(initial, "source")))), "$value_models", "supplied source");
                }
            }
            for (WireValue step : state.trace) {
                WireValue p = payload(step);
                if (tag(step).equals("Guard")) {
                    WireValue guard = find(guards, "id", f(p, "guard")), inspected = f(p, "inspected"); State before = initialState();
                    for (WireValue previous : state.trace) { if (previous == step) break; before = afterTraceStep(before, previous); }
                    require(guardArm(context, guard, projectSlotValue(context, values.get(f(inspected, "producer")), a(f(inspected, "path"))), f(effectiveProjection(before, inspected), "destination")).equals(f(p, "arm")), "$value_models", "actual guard branch");
                } else {
                    WireValue invocation = f(p, "invocation"), function = siteSignature(f(invocation, "site"));
                    for (WireValue port : a(f(function, "inputs"))) context.validateContract(f(port, "contract"), evaluateBinding(context, tupleLookup(f(invocation, "bindings"), f(port, "id")), values));
                }
            }
            if (tag(terminal).equals("Success")) for (WireValue output : a(f(goal, "outputs"))) context.validateContract(f(output, "contract"), evaluateBinding(context, tupleLookup(payload(terminal), f(output, "id")), values));
            else {
                WireValue embedding = find(a(f(goal, "failures")), "id", f(payload(terminal), "embedding")); context.validateContract(f(embedding, "contract"), evaluateBinding(context, f(payload(terminal), "value"), values));
            }
            Lowered lowered = new ResourceLowerer(this).lower(f(certificate, "trace"));
            require(lowered.input().equals(f(certificate, "lowering")) && lowered.correspondence().equals(f(certificate, "correspondence")), "$resource_trace", "reconstructed resource lowering");
            require(f(f(certificate, "reachability"), "path").equals(f(lowered.correspondence(), "execution_order")), "$resource_trace", "selected execution order");
            verifyReachability(lowered.input(), f(certificate, "reachability")); verifyResourceClosure(lowered.input(), f(certificate, "acyclicity"), true);
        }
        State afterTraceStep(State state, WireValue step) throws GenerationFailure, ValueFailure {
            WireValue p = payload(step);
            if (tag(step).equals("Invocation")) {
                WireValue invocation = f(p, "invocation"); return afterInvocation(state, invocation, find(a(f(siteSignature(f(invocation, "site")), "outcomes")), "id", f(p, "outcome")));
            }
            return afterGuard(state, find(guards, "id", f(p, "guard")), f(p, "inspected"), f(p, "arm"));
        }
        int closureBindings;
        void bindingBudget() throws GenerationFailure { require(BigInteger.valueOf(++closureBindings).compareTo(n(f(bounds, "max_binding_candidates"))) <= 0, "$closure", "complete binding bound"); }
        WireValue deriveInclusion(WireValue source, WireValue destination) throws GenerationFailure, ValueFailure {
            List<WireValue> pairs = new ArrayList<>(), entries = new ArrayList<>(); pairs.add(pair(source, destination, NIL));
            for (int at = 0; at < pairs.size(); at++) {
                require(BigInteger.valueOf(pairs.size()).compareTo(n(f(bounds, "max_type_obligations"))) <= 0, "$closure", "type obligation bound");
                WireValue pair = pairs.get(at); InclusionStep step = inclusions.local(pair, inclusions.empty); List<WireValue> children = new ArrayList<>();
                for (WireValue child : step.children()) { int index = pairs.indexOf(child); if (index < 0) { index = pairs.size(); pairs.add(child); } children.add(str(Integer.toString(index))); }
                entries.add(obj("pair", pair, "source_shape", context.shape(context.index(f(f(pair, "source"), "type_ref"))), "destination_shape", context.shape(context.index(f(f(pair, "destination"), "type_ref"))), "rule", variant(inclusions.wireRuleName(pair, step)), "children", arr(children)));
            }
            List<WireValue> empty = new ArrayList<>(); for (WireValue node : context.nodes) if (inclusions.empty.contains(f(node, "reference"))) empty.add(f(node, "reference"));
            return obj("basis", basis, "source", source, "destination", destination, "root", ZERO, "empty_types", arr(empty), "pairs", arr(entries));
        }
        void counterexample(WireValue certificate) throws GenerationFailure, ValueFailure {
            require(f(certificate, "basis").equals(basis), "$counterexample", "basis");
            Slot<WireValue> value = exchangeSlot(f(certificate, "value")); context.validateContract(f(certificate, "source"), value); boolean rejected = false;
            try { context.validateContract(f(certificate, "destination"), value); }
            catch (ValueFailure failure) {
                if (failure.condition().startsWith("UndefinedMeaning:")) throw failure; rejected = true;
                WireValue supplied = f(certificate, "destination_failure"), ref = f(supplied, "type_ref"); context.index(ref);
                require(ref.equals(failure.typeRef()), "$counterexample", "failure source identity");
                require(a(f(supplied, "value_path")).equals(failure.path()) && failure.condition().split(": ", 2)[0].equals(tag(f(supplied, "condition"))) && f(supplied, "reference_trace").equals(arr(failure.referenceTrace())), "$counterexample", "actual rejection path/condition/trace");
                Slot<WireValue> observed = projectSlotValue(context, value, a(f(supplied, "value_path")));
                require(s(f(supplied, "observed")).equals(observed(observed)), "$counterexample", "observed rejection value");
                if (o(f(supplied, "condition")).get("value") != null) {
                    String[] condition = failure.condition().split(": ", 2);
                    require(condition.length == 2 && f(f(supplied, "condition"), "value").equals(str(condition[1])), "$counterexample", "condition detail");
                }
            }
            require(rejected, "$counterexample", "destination rejection");
        }
        final class Enumeration {
            final State state; final WireValue record;
            final List<WireValue> terminals = new ArrayList<>(), choices = new ArrayList<>(), missing = new ArrayList<>(), rejected = new ArrayList<>();
            Enumeration(State state, WireValue record) { this.state = state; this.record = record; }
            void rejectConnection(WireValue value, WireValue source, WireValue destination, Slot<WireValue> exact) throws GenerationFailure, ValueFailure {
                WireValue match = null;
                for (WireValue rejection : a(f(record, "rejected_connections"))) {
                    WireValue certificate = f(rejection, "counterexample");
                    if (f(rejection, "value").equals(value) && f(rejection, "destination").equals(destination) && f(certificate, "source").equals(source) && f(certificate, "destination").equals(destination) && (exact == null || exchangeSlot(f(certificate, "value")).equals(exact))) { match = rejection; break; }
                }
                require(match != null, "$closure", "unresolved implication/rejection evidence"); counterexample(f(match, "counterexample")); rejected.add(match);
            }
            List<WireValue> sourceBindings(WireValue destination, WireValue constraint) throws GenerationFailure, ValueFailure {
                List<WireValue> result = new ArrayList<>();
                for (WireValue available : state.available) {
                    WireValue producer = f(available, "producer"), source = f(available, "contract"); if (inclusions.emptySlot(source)) continue;
                    List<List<WireValue>> paths = new ArrayList<>(); paths.add(List.of());
                    for (WireValue projection : a(f(domain, "permitted_projections"))) if (f(projection, "source_type").equals(f(source, "type_ref")) && !paths.contains(a(f(projection, "path")))) paths.add(a(f(projection, "path")));
                    for (WireValue fact : state.facts) if (f(f(fact, "inspected"), "producer").equals(producer) && !paths.contains(a(f(f(fact, "inspected"), "path")))) paths.add(a(f(f(fact, "inspected"), "path")));
                    for (List<WireValue> path : paths) {
                        WireValue value = valueRef(producer, path), projection; if (!allows(constraint, value)) continue; bindingBudget();
                        try { projection = effectiveProjection(state, value); } catch (GenerationFailure failure) { continue; }
                        WireValue projected = f(projection, "destination"); Slot<WireValue> exact = exactValue(state, value); WireValue compatibility;
                        if (exact != null) {
                            if (!inclusions.accepts(projected, exact)) continue;
                            if (!inclusions.accepts(destination, exact)) { rejectConnection(value, projected, destination, exact); continue; }
                            compatibility = fields("SuppliedValue", obj("value", encodeSlot(exact)));
                        } else {
                            if (inclusions.emptySlot(projected)) continue;
                            if (!inclusions.compatible(projected, destination)) { rejectConnection(value, projected, destination, null); continue; }
                            compatibility = variant("Inclusion", deriveInclusion(projected, destination));
                        }
                        WireValue expression = fields("Source", obj("value", value, "projection", projection, "compatibility", compatibility));
                        binding(state, expression, destination, constraint); result.add(expression);
                    }
                }
                return result;
            }
            List<WireValue> constructBindings(WireValue destination, WireValue construction) throws GenerationFailure, ValueFailure {
                WireValue shape = context.resolve(f(construction, "type_ref")); List<List<WireValue>> products = new ArrayList<>(); products.add(List.of());
                for (WireValue field : a(f(payload(shape), "fields"))) {
                    List<WireValue> choices = sourceBindings(f(field, "slot"), fieldConstraint(construction, f(field, "wire_name")));
                    for (WireValue nested : a(f(construction, "nested_fields"))) if (a(nested).get(0).equals(f(field, "wire_name"))) choices.addAll(constructBindings(f(field, "slot"), find(a(f(domain, "permitted_constructions")), "identity", a(nested).get(1))));
                    List<List<WireValue>> next = new ArrayList<>();
                    for (List<WireValue> product : products) {
                        if (!fieldRequired(construction, field)) next.add(product);
                        for (WireValue choice : choices) { bindingBudget(); List<WireValue> fields = new ArrayList<>(product); fields.add(arr(List.of(f(field, "wire_name"), choice))); next.add(fields); }
                    }
                    products = next;
                    if (products.isEmpty()) break;
                }
                List<WireValue> result = new ArrayList<>();
                for (List<WireValue> fields : products) {
                    WireValue expression = fields("Product", obj("construction", f(construction, "identity"), "type_ref", f(construction, "type_ref"), "fields", arr(fields)));
                    try { binding(state, expression, destination, variant("AnyCompatible")); result.add(expression); } catch (GenerationFailure failure) {}
                }
                return result;
            }
            List<WireValue> bindings(WireValue destination, WireValue constraint) throws GenerationFailure, ValueFailure {
                List<WireValue> result = sourceBindings(destination, constraint);
                if (tag(constraint).equals("AnyCompatible")) for (WireValue construction : a(f(domain, "permitted_constructions"))) if (f(construction, "type_ref").equals(f(destination, "type_ref"))) result.addAll(constructBindings(destination, construction));
                return result;
            }
            List<List<WireValue>> resourceBindings(WireValue function) throws GenerationFailure, ValueFailure {
                List<List<WireValue>> products = new ArrayList<>(); products.add(List.of());
                for (WireValue requirement : a(f(function, "resource_inputs"))) {
                    List<WireValue> choices = new ArrayList<>();
                    for (WireValue reference : stateLots(state)) {
                        bindingBudget(); WireValue lot = lot(reference);
                        if (!f(lot, "revision").equals(f(requirement, "required_revision")) || !tag(f(requirement, "identity")).equals("Any") && !payload(f(requirement, "identity")).equals(f(lot, "producer"))) continue;
                        WireValue source = contract(f(lot, "token_type"), true, false), destination = contract(f(requirement, "token_type"), true, false);
                        if (!inclusions.compatible(source, destination)) { rejectConnection(NIL, source, destination, null); continue; }
                        choices.add(obj("requirement", f(requirement, "id"), "lot", reference, "inclusion", deriveInclusion(source, destination)));
                    }
                    List<List<WireValue>> next = new ArrayList<>();
                    for (List<WireValue> product : products) for (WireValue choice : choices) { bindingBudget(); List<WireValue> selected = new ArrayList<>(product); selected.add(choice); next.add(selected); }
                    products = next;
                }
                return products;
            }
            List<List<WireValue>> portProducts(List<WireValue> ports, WireValue site) throws GenerationFailure, ValueFailure {
                List<List<WireValue>> products = new ArrayList<>(); products.add(List.of());
                for (WireValue port : ports) {
                    List<WireValue> options = bindings(f(port, "contract"), f(port, "source_constraint"));
                    if (options.isEmpty()) missing.add(obj("site", site, "port", f(port, "id"), "contract", f(port, "contract")));
                    List<List<WireValue>> next = new ArrayList<>();
                    for (List<WireValue> product : products) for (WireValue option : options) { bindingBudget(); List<WireValue> selected = new ArrayList<>(product); selected.add(arr(List.of(f(port, "id"), option))); next.add(selected); }
                    products = next;
                }
                return products;
            }
            void enumerate() throws GenerationFailure, ValueFailure {
                if (!mustHandle(state.pendingFailure)) for (List<WireValue> returns : portProducts(a(f(goal, "outputs")), NIL)) terminals.add(variant("Success", arr(returns)));
                if (!nil(state.pendingFailure)) for (WireValue embedding : a(f(goal, "failures"))) if (f(embedding, "origin").equals(state.pendingFailure)) {
                    for (WireValue expression : bindings(f(embedding, "contract"), variant("AnyCompatible"))) { WireValue returned = fields("Failure", obj("embedding", f(embedding, "id"), "value", expression)); try { terminal(state, returned); terminals.add(returned); } catch (GenerationFailure failure) {} }
                }
                for (WireValue site : sites) {
                    if (state.usedSites.contains(f(site, "id")) || a(f(problem, "explicit_order")).stream().anyMatch(order -> a(order).get(1).equals(f(site, "id")) && !state.usedSites.contains(a(order).get(0)))) continue;
                    WireValue function = signature(f(site, "function"));
                    if (!f(function, "handles_failure").equals(state.pendingFailure) && !(nil(f(function, "handles_failure")) && !mustHandle(state.pendingFailure))) continue;
                    List<List<WireValue>> bindings = portProducts(a(f(function, "inputs")), f(site, "id")); if (bindings.isEmpty()) continue;
                    List<List<WireValue>> resources = resourceBindings(function); List<WireValue> outcomes = new ArrayList<>(), empty = new ArrayList<>();
                    for (WireValue outcome : a(f(function, "outcomes"))) (emptyOutcome(outcome) ? empty : outcomes).add(f(outcome, "id"));
                    if (outcomes.isEmpty()) continue;
                    for (List<WireValue> selected : bindings) for (List<WireValue> resource : resources) {
                        bindingBudget(); WireValue invocation = obj("site", f(site, "id"), "function", f(function, "reference"), "bindings", arr(selected), "resources", arr(resource));
                        try { invocation(state, invocation); choices.add(fields("Invoke", obj("invocation", invocation, "outcomes", arr(outcomes), "empty_outcomes", arr(empty)))); } catch (GenerationFailure failure) {}
                    }
                }
                for (WireValue guard : guards) {
                    if (state.usedGuards.contains(f(guard, "id"))) continue;
                    for (WireValue available : state.available) if (f(f(available, "contract"), "type_ref").equals(f(guard, "source_type"))) {
                        bindingBudget(); WireValue inspected = obj("producer", f(available, "producer"), "path", f(guard, "path"));
                        try { List<WireValue> arms = guardArms(state, guard, inspected); if (!arms.isEmpty()) choices.add(fields("Guard", obj("guard", f(guard, "id"), "inspected", inspected, "arms", arr(arms)))); } catch (GenerationFailure failure) {}
                    }
                }
                require(multiset(terminals.stream().map(terminal -> str(returnKey(terminal))).toList()).equals(multiset(a(f(record, "terminals")).stream().map(coverage -> str(returnKey(f(coverage, "terminal")))).toList())) && multiset(choices.stream().map(choice -> str(choiceKey(choice))).toList()).equals(multiset(a(f(record, "choices")).stream().map(coverage -> str(choiceKey(f(coverage, "choice")))).toList())), "$closure", "complete terminal/choice coverage");
                require(arr(missing).equals(f(record, "missing_supply")) && arr(rejected).equals(f(record, "rejected_connections")), "$closure", "missing supplies/counterexamples");
            }
        }
        Set<String> verifyClosure(WireValue closure) throws GenerationFailure, ValueFailure {
            require(f(closure, "input_snapshot").equals(problem), "$closure", "input snapshot"); List<WireValue> records = a(f(closure, "states")); int root = indexNumber(f(closure, "root"));
            require(root < records.size() && f(records.get(root), "state").equals(initialState().wire()), "$closure", "initial state");
            Set<Integer> reached = new HashSet<>(); ArrayDeque<Integer> pending = new ArrayDeque<>(); pending.push(root);
            while (!pending.isEmpty()) {
                int index = pending.pop(); if (!reached.add(index)) continue; require(index < records.size(), "$closure", "state index");
                for (WireValue choice : a(f(records.get(index), "choices"))) for (WireValue child : a(f(choice, "children"))) pending.push(indexNumber(child));
            }
            require(reached.size() == records.size(), "$closure", "all states reachable"); Set<WireValue> states = new HashSet<>(); int expanded = 0;
            for (WireValue record : records) {
                require(states.add(f(record, "state")), "$closure", "unique states"); State state = State.from(f(record, "state")); new Enumeration(state, record).enumerate();
                if (!a(f(record, "choices")).isEmpty()) expanded++;
                for (WireValue terminal : a(f(record, "terminals"))) verifyAssessment(state, f(terminal, "terminal"), f(terminal, "assessment"));
                for (WireValue coverage : a(f(record, "choices"))) {
                    WireValue choice = f(coverage, "choice"), p = payload(choice); List<State> children = new ArrayList<>();
                    if (tag(choice).equals("Invoke")) {
                        invocation(state, f(p, "invocation")); WireValue function = siteSignature(f(f(p, "invocation"), "site")); List<WireValue> expected = new ArrayList<>(), empty = new ArrayList<>();
                        for (WireValue outcome : a(f(function, "outcomes"))) (emptyOutcome(outcome) ? empty : expected).add(f(outcome, "id"));
                        require(multiset(expected).equals(multiset(a(f(p, "outcomes")))) && multiset(empty).equals(multiset(a(f(p, "empty_outcomes")))), "$closure", "outcome coverage");
                        for (WireValue outcome : a(f(p, "outcomes"))) children.add(afterInvocation(state, f(p, "invocation"), find(a(f(function, "outcomes")), "id", outcome)));
                    } else {
                        WireValue guard = find(guards, "id", f(p, "guard")); require(guard != null && multiset(guardArms(state, guard, f(p, "inspected"))).equals(multiset(a(f(p, "arms")))), "$closure", "guard coverage");
                        for (WireValue arm : a(f(p, "arms"))) children.add(afterGuard(state, guard, f(p, "inspected"), arm));
                    }
                    require(children.size() == a(f(coverage, "children")).size(), "$closure", "child coverage");
                    for (int i = 0; i < children.size(); i++) { int child = indexNumber(a(f(coverage, "children")).get(i)); require(child < records.size() && sameState(State.from(f(records.get(child), "state")), children.get(i)) && children.get(i).trace.size() > state.trace.size(), "$closure", "successor state/rank"); }
                }
            }
            require(BigInteger.valueOf(expanded).compareTo(n(f(bounds, "max_expanded_states"))) <= 0, "$closure", "expanded state bound");
            List<ClosedCandidate> candidates = closedCandidates(records, root, new HashMap<>(), new HashSet<>()); Set<String> result = new LinkedHashSet<>();
            for (ClosedCandidate candidate : candidates) if (candidate.success()) result.add(candidateKey(candidate.certificates())); return result;
        }
        boolean sameState(State actual, State expected) throws GenerationFailure, ValueFailure {
            if (actual.wire().equals(expected.wire())) return true;
            if (!actual.available.equals(expected.available) || !actual.usedSites.equals(expected.usedSites) || !actual.usedGuards.equals(expected.usedGuards) || !actual.facts.equals(expected.facts) || !actual.pendingFailure.equals(expected.pendingFailure) || actual.trace.size() != expected.trace.size()) return false;
            State replay = initialState();
            for (int i = 0; i < actual.trace.size(); i++) { WireValue step = actual.trace.get(i); if (!traceKey(step).equals(traceKey(expected.trace.get(i)))) return false; WireValue p = payload(step); if (tag(step).equals("Invocation")) invocation(replay, f(p, "invocation")); else if (!guardArms(replay, find(guards, "id", f(p, "guard")), f(p, "inspected")).contains(f(p, "arm"))) return false; replay = afterTraceStep(replay, step); }
            return replay.wire().equals(actual.wire());
        }
        void verifyAssessment(State state, WireValue returned, WireValue assessment) throws GenerationFailure, ValueFailure {
            terminal(state, returned); String kind = tag(assessment); WireValue p = payload(assessment);
            if (kind.equals("Feasible")) { verifyTrace(state, returned, p); return; }
            WireValue trace = obj("steps", arr(state.trace), "terminal", returned);
            if (kind.equals("EmptyValues")) {
                List<WireValue> empty = state.available.stream().filter(value -> inclusions.emptySlot(f(value, "contract"))).map(value -> f(value, "producer")).toList(); require(!empty.isEmpty() && p.equals(arr(empty)), "$closure", "empty producer proof"); return;
            }
            require(kind.equals("ResourceUnreachable"), "$closure", "resolved terminal assessment"); require(f(p, "trace").equals(trace), "$closure", "resource trace"); Lowered lowered = new ResourceLowerer(this).lower(trace);
            require(lowered.input().equals(f(p, "lowering")) && lowered.correspondence().equals(f(p, "correspondence")), "$closure", "unreachable lowering"); verifyResourceClosure(lowered.input(), f(p, "closure"), false);
        }
        record ClosedCandidate(List<WireValue> certificates, boolean success, int nodes) {}
        List<ClosedCandidate> closedCandidates(List<WireValue> records, int index, Map<Integer, List<ClosedCandidate>> memo, Set<Integer> active) throws GenerationFailure {
            if (memo.containsKey(index)) return memo.get(index); require(active.add(index), "$closure", "acyclic finite search graph"); WireValue record = records.get(index); List<ClosedCandidate> result = new ArrayList<>();
            for (WireValue coverage : a(f(record, "terminals"))) if (tag(f(coverage, "assessment")).equals("Feasible")) result.add(new ClosedCandidate(List.of(payload(f(coverage, "assessment"))), tag(f(coverage, "terminal")).equals("Success"), 1));
            for (WireValue coverage : a(f(record, "choices"))) {
                List<ClosedCandidate> products = new ArrayList<>(); products.add(new ClosedCandidate(List.of(), false, 1));
                for (WireValue child : a(f(coverage, "children"))) {
                    List<ClosedCandidate> next = new ArrayList<>();
                    for (ClosedCandidate before : products) for (ClosedCandidate after : closedCandidates(records, indexNumber(child), memo, active)) {
                        int nodes = Math.addExact(before.nodes(), after.nodes()); require(BigInteger.valueOf(nodes).compareTo(n(f(bounds, "max_branch_nodes"))) <= 0, "$closure", "branch node bound"); List<WireValue> certificates = new ArrayList<>(before.certificates()); certificates.addAll(after.certificates()); next.add(new ClosedCandidate(List.copyOf(certificates), before.success() || after.success(), nodes));
                    }
                    products = next;
                }
                result.addAll(products);
            }
            Map<String, ClosedCandidate> distinct = new LinkedHashMap<>(); for (ClosedCandidate candidate : result) distinct.putIfAbsent(candidateKey(candidate.certificates()), candidate);
            active.remove(index); List<ClosedCandidate> candidates = List.copyOf(distinct.values()); memo.put(index, candidates); return candidates;
        }
        String candidateKey(List<WireValue> certificates) {
            List<String> branches = new ArrayList<>(); for (WireValue certificate : certificates) branches.add(canonicalTrace(f(certificate, "trace"))); branches.sort(SemanticGeneration::compareUtf8); return encodeTuple(branches);
        }
        String canonicalTrace(WireValue trace) {
            List<String> parts = new ArrayList<>(), unordered = new ArrayList<>();
            for (WireValue step : a(f(trace, "steps"))) {
                WireValue p = payload(step);
                if (tag(step).equals("Invocation")) {
                    WireValue invocation = f(p, "invocation"), function = find(signatures, "reference", f(invocation, "function"));
                    boolean free = tag(f(function, "effect")).equals("PureFunction") && a(f(function, "outcomes")).size() == 1 && tag(f(a(f(function, "outcomes")).get(0), "form")).equals("Success") && a(f(function, "resource_inputs")).stream().allMatch(requirement -> tag(f(requirement, "mode")).equals("Read")) && a(f(a(f(function, "outcomes")).get(0), "produced_resources")).isEmpty();
                    String key = encodeTuple(invocationKey(invocation), s(f(p, "outcome")));
                    if (free) unordered.add(key); else { unordered.sort(SemanticGeneration::compareUtf8); parts.addAll(unordered); unordered.clear(); parts.add(key); }
                } else { unordered.sort(SemanticGeneration::compareUtf8); parts.addAll(unordered); unordered.clear(); parts.add(traceKey(step)); }
            }
            unordered.sort(SemanticGeneration::compareUtf8); parts.addAll(unordered); parts.add(returnKey(f(trace, "terminal"))); return encodeTuple(parts);
        }
    }
    private static String observed(Slot<WireValue> value) {
        if (value instanceof Absent<WireValue>) return "absent";
        if (value instanceof NullSlot<WireValue>) return "null";
        return switch (((Present<WireValue>) value).value()) {
            case NullValue unused -> "null"; case BooleanValue bool -> Boolean.toString(bool.value()); case IntegerValue integer -> integer.value().toString();
            case DecimalValue decimal -> decimal.text(); case StringValue string -> string.value(); case ArrayValue unused -> "array"; case ObjectValue unused -> "object";
        };
    }
    private static Map<WireValue, Integer> multiset(List<WireValue> values) { Map<WireValue, Integer> result = new HashMap<>(); for (WireValue value : values) result.merge(value, 1, Integer::sum); return result; }
    private static boolean mustHandle(WireValue origin) { return !nil(origin) && (tag(origin).equals("Function") || tag(f(payload(origin), "arm")).equals("Rejected")); }
    private static List<WireValue> bindingSources(WireValue expression) {
        if (tag(expression).equals("Source")) return List.of(f(payload(expression), "value"));
        List<WireValue> result = new ArrayList<>(); for (WireValue tuple : a(f(payload(expression), "fields"))) result.addAll(bindingSources(a(tuple).get(1))); return result;
    }
    private static boolean starts(List<WireValue> path, List<WireValue> prefix) { return path.size() >= prefix.size() && path.subList(0, prefix.size()).equals(prefix); }
    private static List<WireValue> assumptionPath(WireValue assumption) { return a(Set.of("Present", "NonNull").contains(tag(assumption)) ? payload(assumption) : f(payload(assumption), "path")); }
    private static WireValue projection(Context context, WireValue sources, WireValue source, List<WireValue> path, List<WireValue> assumptions) throws GenerationFailure, ValueFailure {
        context.meaning(context.index(f(source, "type_ref"))); WireValue reference = f(source, "type_ref"); boolean required = b(f(source, "required")), nullable = b(f(source, "nullable")); int position = 0; Set<WireValue> visited = new HashSet<>();
        for (;;) {
            List<WireValue> traversed = path.subList(0, position);
            for (WireValue assumption : assumptions) if (assumptionPath(assumption).equals(traversed)) { if (tag(assumption).equals("NonNull")) nullable = false; else { required = true; nullable = false; } }
            if (position == path.size()) break;
            require(visited.add(arr(List.of(reference, str(Integer.toString(position))))), "$projection", "productive reference path");
            WireValue shape = context.shape(context.index(reference)), spec = payload(shape), step = path.get(position);
            if (tag(shape).equals("Alias")) { reference = f(spec, "target"); continue; }
            if (tag(shape).equals("Record")) { reference = f(spec, "payload"); continue; }
            if (tag(shape).equals("Product") && tag(step).equals("Field")) { WireValue field = find(a(f(spec, "fields")), "wire_name", payload(step)); require(field != null, "$projection", "field"); WireValue slot = f(field, "slot"); reference = f(slot, "type_ref"); required &= b(f(slot, "required")); nullable |= b(f(slot, "nullable")); }
            else if (tag(shape).equals("Array") && tag(step).equals("Index")) {
                boolean present = !nil(f(spec, "min_length")) && n(payload(step)).compareTo(n(f(spec, "min_length"))) < 0 || assumptions.stream().anyMatch(assumption -> tag(assumption).equals("IndexPresent") && assumptionPath(assumption).equals(traversed) && f(payload(assumption), "index").equals(payload(step)));
                reference = f(spec, "item"); required &= present;
            } else if (tag(shape).equals("TaggedUnion") && tag(step).equals("Variant")) {
                require(assumptions.stream().anyMatch(assumption -> tag(assumption).equals("Variant") && assumptionPath(assumption).equals(traversed) && f(payload(assumption), "tag").equals(payload(step))), "$projection", "dominating variant guard");
                WireValue branch = find(a(f(spec, "branches")), "wire_tag", payload(step)); require(branch != null, "$projection", "branch"); reference = f(branch, "target");
            } else throw new GenerationFailure("$projection", "shape/path mismatch");
            position++;
        }
        return obj("profile", f(context.profile, "reference"), "source_refs", sources, "source", source, "path", arr(path), "assumptions", arr(assumptions), "destination", contract(reference, required, nullable));
    }
    static Slot<WireValue> projectSlotValue(Context context, Slot<WireValue> source, List<WireValue> path) {
        if (!(source instanceof Present<WireValue> present) || path.isEmpty()) return source;
        WireValue value = present.value();
        for (int i = 0; i < path.size(); i++) {
            if (nil(value)) return new NullSlot<>(); WireValue step = path.get(i);
            if (tag(step).equals("Field")) { if (!(value instanceof ObjectValue)) return new Absent<>(); value = o(value).get(s(payload(step))); if (value == null) return new Absent<>(); }
            else if (tag(step).equals("Index")) { BigInteger index = n(payload(step)); if (!(value instanceof ArrayValue) || index.compareTo(BigInteger.valueOf(a(value).size())) >= 0) return new Absent<>(); value = a(value).get(index.intValue()); }
            else if (!(value instanceof ObjectValue) || !payload(step).equals(o(value).get(context.tagKey()))) return new Absent<>();
            if (i == path.size() - 1) return nil(value) ? new NullSlot<>() : new Present<>(value);
        }
        return new Present<>(value);
    }
    private static WireValue encodeSlot(Slot<WireValue> slot) {
        return switch (slot) { case Absent<WireValue> unused -> variant("Absent"); case NullSlot<WireValue> unused -> variant("Null"); case Present<WireValue> present -> variant("Present", toExact(present.value())); };
    }
    private static WireValue guardArm(Context context, WireValue guard, Slot<WireValue> value, WireValue projected) throws GenerationFailure, ValueFailure {
        if (tag(f(guard, "kind")).equals("Validate")) {
            try { context.validateContract(payload(f(guard, "kind")), value); return variant("Accepted"); }
            catch (ValueFailure failure) { if (failure.condition().startsWith("UndefinedMeaning:")) throw failure; return variant("Rejected"); }
        }
        if (value instanceof Absent<WireValue>) return variant("Absent"); if (value instanceof NullSlot<WireValue>) return variant("Null");
        if (tag(f(guard, "kind")).equals("Presence")) return variant("Present");
        WireValue actual = ((Present<WireValue>) value).value(); require(actual instanceof ObjectValue && o(actual).get(context.tagKey()) instanceof StringValue, "$guard", "tagged object");
        WireValue shape = context.resolve(f(projected, "type_ref")); require(shape != null && tag(shape).equals("TaggedUnion"), "$guard", "union shape");
        WireValue discriminator = o(actual).get(context.tagKey()); for (WireValue branch : a(f(payload(shape), "branches"))) if (f(branch, "wire_tag").equals(discriminator)) return variant("Variant", discriminator);
        require(!b(f(payload(shape), "closed")) && context.tagTextAccepted(s(discriminator)), "$guard", "known/qualified variant"); return variant("UnknownVariant");
    }
    static Slot<WireValue> evaluateBinding(Context context, WireValue expression, Map<WireValue, Slot<WireValue>> values) throws GenerationFailure {
        WireValue p = payload(expression);
        if (tag(expression).equals("Source")) { WireValue value = f(p, "value"); require(values.containsKey(f(value, "producer")), "$execution", "bound producer"); return projectSlotValue(context, values.get(f(value, "producer")), a(f(value, "path"))); }
        List<Member> fields = new ArrayList<>();
        for (WireValue tuple : a(f(p, "fields"))) {
            Slot<WireValue> value = evaluateBinding(context, a(tuple).get(1), values);
            if (value instanceof Present<WireValue> present) fields.add(new Member(s(a(tuple).get(0)), present.value()));
            else if (value instanceof NullSlot<WireValue>) fields.add(new Member(s(a(tuple).get(0)), NIL));
        }
        return new Present<>(new ObjectValue(fields));
    }
    private static String encodeTuple(List<String> parts) {
        StringBuilder result = new StringBuilder(); for (String part : parts) result.append(part.getBytes(StandardCharsets.UTF_8).length).append(':').append(part); return result.toString();
    }
    private static String encodeTuple(String... parts) { return encodeTuple(List.of(parts)); }
    private static String typeIdentity(WireValue reference) {
        WireValue source = f(reference, "source"), declared = f(source, "declared_revision");
        return encodeTuple("type", s(f(source, "repository")), s(f(source, "revision")), s(f(source, "path")),
                s(f(source, "content_digest")), s(f(source, "document_id")), nil(declared) ? "none" : "some",
                nil(declared) ? "" : s(declared), s(f(reference, "definition_name")),
                encodeTuple(a(f(reference, "pointer")).stream().map(SemanticValues::s).toList()));
    }
    private static String functionIdentity(WireValue reference) { return encodeTuple(s(f(reference, "identity")), s(f(reference, "revision")), s(f(reference, "content_digest"))); }
    private static String producerIdentity(WireValue producer) {
        return tag(producer).equals("Initial") ? encodeTuple("initial-value", s(payload(producer))) : encodeTuple("outcome-value", s(f(payload(producer), "site")), s(f(payload(producer), "outcome")), s(f(payload(producer), "port")));
    }
    private static String lotIdentity(WireValue lot) {
        return tag(lot).equals("Initial") ? encodeTuple("initial-lot", s(payload(lot))) : encodeTuple("produced-lot", s(f(payload(lot), "site")), s(f(payload(lot), "outcome")), s(f(payload(lot), "production")));
    }
    private static String invocationIdentity(WireValue invocation, WireValue outcome) { return encodeTuple("invocation", s(f(invocation, "site")), functionIdentity(f(invocation, "function")), s(outcome)); }
    private static String productionIdentity(WireValue site, WireValue outcome, WireValue production) { return encodeTuple("resource-production", s(site), s(outcome), s(production)); }
    private static WireValue ZERO = str("0"), ONE = str("1");
    private record Lowered(WireValue input, WireValue correspondence) {}
    private static final class Phase {
        final String identity; final WireValue revision; final List<WireValue> values = new ArrayList<>(); final LinkedHashMap<WireValue, BigInteger> reads = new LinkedHashMap<>(), consumes = new LinkedHashMap<>(); final List<String> outputs = new ArrayList<>();
        Phase(String identity, WireValue revision) { this.identity = identity; this.revision = revision; }
        void read(WireValue lot, BigInteger count) { reads.merge(lot, count, BigInteger::max); }
        void consume(WireValue lot, BigInteger count) { consumes.merge(lot, count, BigInteger::add); }
    }
    private static final class ResourceLowerer {
        final Checker checker;
        final List<WireValue> lots = new ArrayList<>(), values = new ArrayList<>(), places = new ArrayList<>(), marking = new ArrayList<>(), transitions = new ArrayList<>(), bindings = new ArrayList<>(), normalized = new ArrayList<>(), order = new ArrayList<>();
        final List<Phase> phases = new ArrayList<>();
        ResourceLowerer(Checker checker) { this.checker = checker; }
        void place(String identity, String type, WireValue revision) { places.add(obj("identity", str(identity), "token_type", str(type), "revision", revision)); }
        void marked(String place, String target, WireValue revision, int quantity) {
            List<WireValue> tokens = new ArrayList<>(quantity); WireValue token = obj("target", str(target), "index", ZERO, "revision", revision, "kind", variant("Input")); for (int i = 0; i < quantity; i++) tokens.add(token);
            marking.add(arr(List.of(str(place), arr(tokens))));
        }
        int count(WireValue quantity) throws GenerationFailure {
            WireValue bound = f(checker.bounds, "resource_bounds"); BigInteger cap = nil(bound) ? BigInteger.valueOf(100000) : n(f(bound, "max_tokens"));
            require(n(quantity).compareTo(cap) <= 0, "$resource", "resource token capacity bound"); return indexNumber(quantity);
        }
        void lot(WireValue reference, WireValue declaration, String target, WireValue quantity) throws GenerationFailure, ValueFailure {
            checker.context.meaning(checker.context.index(f(declaration, "token_type")));
            String identity = lotIdentity(reference), type = checker.resourceTypeIdentity(f(declaration, "token_type")); WireValue revision = f(declaration, "revision"); place(identity, type, revision);
            lots.add(obj("lot", reference, "place", str(identity), "producer", f(declaration, "producer"), "token_target", str(target), "token_type", str(type), "revision", revision, "quantity", quantity, "provenance", f(declaration, "provenance")));
        }
        Lowered lower(WireValue trace) throws GenerationFailure, ValueFailure {
            for (WireValue declaration : checker.initialLots) {
                WireValue reference = variant("Initial", f(declaration, "id")), producer = payload(f(declaration, "producer"));
                String target = encodeTuple("initial-resource", s(f(producer, "identity")), s(f(producer, "revision")), s(f(declaration, "id")));
                lot(reference, declaration, target, f(declaration, "quantity")); marked(lotIdentity(reference), target, f(declaration, "revision"), count(f(declaration, "quantity")));
            }
            for (WireValue initial : checker.initials) {
                WireValue producer = initialProducer(f(initial, "id")); String identity = producerIdentity(producer);
                place(identity, checker.resourceTypeIdentity(f(f(initial, "contract"), "type_ref")), ZERO); marked(identity, identity, ZERO, 1);
                values.add(obj("producer", producer, "place", str(identity), "token_target", str(identity), "revision", ZERO));
            }
            for (WireValue step : a(f(trace, "steps"))) {
                WireValue p = payload(step);
                if (tag(step).equals("Guard")) {
                    Phase phase = new Phase(encodeTuple("guard", s(f(p, "guard")), producerIdentity(f(f(p, "inspected"), "producer"))), ZERO); phase.values.add(f(f(p, "inspected"), "producer")); phases.add(phase); continue;
                }
                WireValue invocation = f(p, "invocation"), outcomeId = f(p, "outcome"), function = checker.siteSignature(f(invocation, "site")), outcome = find(a(f(function, "outcomes")), "id", outcomeId);
                Phase phase = new Phase(invocationIdentity(invocation, outcomeId), ZERO);
                for (WireValue port : a(f(function, "inputs"))) for (WireValue source : bindingSources(tupleLookup(f(invocation, "bindings"), f(port, "id")))) {
                    WireValue producer = f(source, "producer"); require(find(values, "producer", producer) != null, "$resource", "earlier value producer"); if (!phase.values.contains(producer)) phase.values.add(producer);
                    WireValue backed = f(checker.declaredValue(producer), "resource"); if (!nil(backed)) phase.read(backed, BigInteger.ONE);
                }
                for (WireValue requirement : a(f(function, "resource_inputs"))) {
                    WireValue binding = find(a(f(invocation, "resources")), "requirement", f(requirement, "id")); require(binding != null && find(lots, "lot", f(binding, "lot")) != null, "$resource", "available lot");
                    if (tag(f(requirement, "mode")).equals("Read")) phase.read(f(binding, "lot"), n(f(requirement, "multiplicity"))); else phase.consume(f(binding, "lot"), n(f(requirement, "multiplicity")));
                }
                for (WireValue port : a(f(outcome, "value_ports"))) {
                    WireValue producer = outcomeProducer(f(invocation, "site"), outcomeId, f(port, "id")); String identity = producerIdentity(producer);
                    place(identity, checker.resourceTypeIdentity(f(f(port, "contract"), "type_ref")), ZERO); values.add(obj("producer", producer, "place", str(identity), "token_target", str(phase.identity), "revision", ZERO)); phase.outputs.add(identity);
                }
                phases.add(phase);
                for (WireValue production : a(f(outcome, "produced_resources"))) {
                    WireValue reference = producedLot(f(invocation, "site"), outcomeId, f(production, "id")), declaration = checker.lot(reference); String target = productionIdentity(f(invocation, "site"), outcomeId, f(production, "id"));
                    lot(reference, declaration, target, f(production, "quantity")); Phase created = new Phase(target, f(production, "revision")); for (int i = 0; i < count(f(production, "quantity")); i++) created.outputs.add(lotIdentity(reference)); phases.add(created);
                }
            }
            String control = encodeTuple("control", "0"), target = "control-root"; WireValue revision = ZERO; place(control, "control", ZERO); marked(control, target, ZERO, 1);
            BigInteger maximum = BigInteger.ZERO; for (WireValue row : marking) maximum = maximum.add(BigInteger.valueOf(a(a(row).get(1)).size()));
            for (int i = 0; i < phases.size(); i++) {
                Phase phase = phases.get(i); String permit = encodeTuple("permit", phase.identity), nextControl = encodeTuple("control", Integer.toString(i + 1)); place(permit, "control", ZERO); marked(permit, permit, ZERO, 1); place(nextControl, "control", phase.revision);
                List<String> inputPlaces = new ArrayList<>(List.of(control, permit)); List<WireValue> selected = new ArrayList<>();
                selected.add(resourceBinding(phase.identity, "order", control, "control", target, "selected branch order", ONE, "Consume", revision));
                selected.add(resourceBinding(phase.identity, "permit", permit, "control", permit, "finite site permit", ONE, "Consume", ZERO));
                for (WireValue producer : phase.values) {
                    WireValue value = find(values, "producer", producer), declaration = checker.declaredValue(producer); require(value != null, "$resource", "value correspondence"); inputPlaces.add(s(f(value, "place")));
                    selected.add(resourceBinding(phase.identity, encodeTuple("value-read", s(f(value, "place"))), s(f(value, "place")), checker.resourceTypeIdentity(f(f(declaration, "contract"), "type_ref")), s(f(value, "token_target")), producerIdentity(producer), ONE, "Read", f(value, "revision")));
                }
                Set<WireValue> refs = new LinkedHashSet<>(phase.reads.keySet()); refs.addAll(phase.consumes.keySet());
                for (WireValue reference : refs) {
                    WireValue lot = find(lots, "lot", reference); require(lot != null, "$resource", "lot normalization");
                    BigInteger read = phase.reads.getOrDefault(reference, BigInteger.ZERO), consume = phase.consumes.getOrDefault(reference, BigInteger.ZERO); inputPlaces.add(s(f(lot, "place")));
                    if (read.signum() != 0) selected.add(resourceBinding(phase.identity, encodeTuple("read", s(f(lot, "place"))), s(f(lot, "place")), s(f(lot, "token_type")), s(f(lot, "token_target")), s(f(lot, "provenance")), str(read.toString()), "Read", f(lot, "revision")));
                    if (consume.signum() != 0) selected.add(resourceBinding(phase.identity, encodeTuple("consume", s(f(lot, "place"))), s(f(lot, "place")), s(f(lot, "token_type")), s(f(lot, "token_target")), s(f(lot, "provenance")), str(consume.toString()), "Consume", f(lot, "revision")));
                    normalized.add(obj("transition", str(phase.identity), "lot", reference, "read", str(read.toString()), "consume", str(consume.toString()), "required_revision", f(lot, "revision")));
                }
                List<String> outputPlaces = new ArrayList<>(phase.outputs); outputPlaces.add(nextControl); maximum = maximum.add(BigInteger.valueOf(outputPlaces.size() + 1L));
                transitions.add(obj("identity", str(phase.identity), "input_places", arr(inputPlaces.stream().map(SemanticValues::str).toList()), "output_places", arr(outputPlaces.stream().map(SemanticValues::str).toList()), "failure_places", arr(List.of()), "revision", phase.revision));
                bindings.addAll(selected); order.add(str(phase.identity)); control = nextControl; target = phase.identity; revision = phase.revision;
            }
            WireValue resourceBounds = f(checker.bounds, "resource_bounds"); BigInteger cap = nil(resourceBounds) ? BigInteger.valueOf(100000) : n(f(resourceBounds, "max_tokens")); require(maximum.compareTo(cap) <= 0, "$resource", "total token capacity bound");
            WireValue goal = tokenGoal(control, target, revision), terminal = f(trace, "terminal"), finalResources; List<WireValue> returns;
            if (tag(terminal).equals("Success")) { returns = a(payload(terminal)).stream().map(tuple -> a(tuple).get(1)).toList(); finalResources = f(checker.goal, "final_resources"); }
            else { WireValue embedding = find(a(f(checker.goal, "failures")), "id", f(payload(terminal), "embedding")); require(embedding != null, "$resource", "failure embedding"); returns = List.of(f(payload(terminal), "value")); finalResources = f(embedding, "final_resources"); }
            for (WireValue returned : returns) for (WireValue source : bindingSources(returned)) {
                WireValue value = find(values, "producer", f(source, "producer")); require(value != null, "$resource", "goal producer"); goal = andGoal(goal, tokenGoal(s(f(value, "place")), s(f(value, "token_target")), f(value, "revision")));
                WireValue backing = f(checker.declaredValue(f(source, "producer")), "resource");
                if (!nil(backing)) { WireValue lot = find(lots, "lot", backing); require(lot != null, "$resource", "goal backing"); goal = andGoal(goal, countGoal(s(f(lot, "place")), ONE)); }
            }
            for (WireValue resource : a(finalResources)) {
                WireValue reference = f(resource, "lot"), lot = find(lots, "lot", reference);
                if (lot == null) {
                    require(tag(reference).equals("Produced"), "$resource", "missing initial correspondence"); WireValue p = payload(reference);
                    lot(reference, checker.lot(reference), productionIdentity(f(p, "site"), f(p, "outcome"), f(p, "production")), ZERO); lot = lots.get(lots.size() - 1);
                }
                goal = andGoal(goal, countGoal(s(f(lot, "place")), f(resource, "multiplicity")));
                if (n(f(resource, "multiplicity")).signum() != 0) goal = andGoal(goal, tokenGoal(s(f(lot, "place")), s(f(lot, "token_target")), f(resource, "revision")));
            }
            List<WireValue> edges = new ArrayList<>();
            for (WireValue transition : transitions) {
                for (WireValue from : a(f(transition, "input_places"))) edges.add(arr(List.of(from, f(transition, "identity"))));
                for (WireValue to : a(f(transition, "output_places"))) edges.add(arr(List.of(f(transition, "identity"), to)));
            }
            WireValue graph = obj("places", arr(places.stream().map(place -> f(place, "identity")).toList()), "transitions", arr(transitions.stream().map(transition -> f(transition, "identity")).toList()), "edges", arr(edges), "revision", ZERO);
            WireValue bound = obj("target_identity", f(checker.problem, "identity"), "index", ZERO, "revision", ZERO, "max_bindings", nil(resourceBounds) ? str(Integer.toString(bindings.size())) : f(resourceBounds, "max_bindings"), "max_search_steps", nil(resourceBounds) ? str(Integer.toString(transitions.size() + 1)) : f(resourceBounds, "max_search_steps"));
            WireValue lowered = obj("places", arr(places), "transitions", arr(transitions), "bindings", arr(bindings), "goal", goal, "graph", graph, "marking", obj("places", arr(marking)), "bound", bound);
            return new Lowered(lowered, obj("lots", arr(lots), "values", arr(values), "normalized_bindings", arr(normalized), "execution_order", arr(order)));
        }
    }
    private static WireValue resourceBinding(String transition, String name, String place, String type, String identity, String provenance, WireValue quantity, String mode, WireValue revision) {
        return obj("transition_id", str(transition), "name", str(name), "place", str(place), "token_type", str(type), "identity", str(identity), "provenance", str(provenance), "multiplicity", quantity, "mode", variant(mode), "required_revision", revision);
    }
    private static WireValue tokenGoal(String place, String target, WireValue revision) { return fields("PlaceHasToken", obj("place", str(place), "target", str(target), "index", ZERO, "revision", revision)); }
    private static WireValue countGoal(String place, WireValue quantity) { return fields("PlaceHasAtLeast", obj("place", str(place), "count", quantity)); }
    private static WireValue andGoal(WireValue left, WireValue right) { return variant("And", arr(List.of(left, right))); }
    private static List<WireValue> tokens(WireValue marking, WireValue place) {
        for (WireValue row : a(f(marking, "places"))) if (a(row).get(0).equals(place)) return a(a(row).get(1)); return List.of();
    }
    private static List<WireValue> resourceBindings(WireValue input, WireValue transition) { return a(f(input, "bindings")).stream().filter(binding -> f(binding, "transition_id").equals(f(transition, "identity"))).toList(); }
    private static boolean enabled(WireValue input, WireValue transition, WireValue marking) {
        for (WireValue binding : resourceBindings(input, transition)) {
            long quantity = tokens(marking, f(binding, "place")).stream().filter(token -> f(token, "target").equals(f(binding, "identity")) && f(token, "revision").equals(f(binding, "required_revision"))).count();
            if (BigInteger.valueOf(quantity).compareTo(n(f(binding, "multiplicity"))) < 0) return false;
        }
        return true;
    }
    private static WireValue applyResource(WireValue input, WireValue transition, WireValue marking) {
        LinkedHashMap<WireValue, List<WireValue>> places = new LinkedHashMap<>();
        for (WireValue row : a(f(marking, "places"))) places.put(a(row).get(0), new ArrayList<>(a(a(row).get(1))));
        for (WireValue binding : resourceBindings(input, transition)) {
            if (!tag(f(binding, "mode")).equals("Consume")) continue; int count = indexNumber(f(binding, "multiplicity")); List<WireValue> selected = new ArrayList<>();
            for (WireValue token : tokens(marking, f(binding, "place"))) if (selected.size() < count && f(token, "target").equals(f(binding, "identity")) && f(token, "revision").equals(f(binding, "required_revision"))) selected.add(token);
            for (WireValue token : selected) places.get(f(binding, "place")).remove(token);
        }
        WireValue output = obj("target", f(transition, "identity"), "index", ZERO, "revision", f(transition, "revision"), "kind", variant("Output"));
        for (WireValue place : a(f(transition, "output_places"))) places.computeIfAbsent(place, unused -> new ArrayList<>()).add(0, output);
        return obj("places", arr(places.entrySet().stream().map(row -> arr(List.of(row.getKey(), arr(row.getValue())))).toList()));
    }
    private static boolean resourceGoal(WireValue marking, WireValue goal) {
        WireValue p = payload(goal);
        return switch (tag(goal)) {
            case "PlaceHasAtLeast" -> BigInteger.valueOf(tokens(marking, f(p, "place")).size()).compareTo(n(f(p, "count"))) >= 0;
            case "PlaceHasToken" -> tokens(marking, f(p, "place")).stream().anyMatch(token -> f(token, "target").equals(f(p, "target")) && f(token, "index").equals(f(p, "index")) && f(token, "revision").equals(f(p, "revision")));
            case "And" -> resourceGoal(marking, a(p).get(0)) && resourceGoal(marking, a(p).get(1));
            case "Or" -> resourceGoal(marking, a(p).get(0)) || resourceGoal(marking, a(p).get(1));
            default -> !resourceGoal(marking, p);
        };
    }
    private static void resourceBound(WireValue input) throws GenerationFailure {
        Set<WireValue> candidateTransitions = new HashSet<>(); for (WireValue binding : a(f(input, "bindings"))) candidateTransitions.add(f(binding, "transition_id"));
        require(BigInteger.valueOf(candidateTransitions.size()).compareTo(n(f(f(input, "bound"), "max_bindings"))) <= 0, "$resource", "binding bound");
    }
    private static void verifyReachability(WireValue input, WireValue witness) throws GenerationFailure {
        resourceBound(input); require(BigInteger.valueOf(a(f(witness, "path")).size()).compareTo(n(f(f(input, "bound"), "max_search_steps"))) <= 0, "$reachability", "path bound"); WireValue marking = f(input, "marking");
        for (WireValue identity : a(f(witness, "path"))) { WireValue transition = find(a(f(input, "transitions")), "identity", identity); require(transition != null && enabled(input, transition, marking), "$reachability", "enabled declared transition"); marking = applyResource(input, transition, marking); }
        require(marking.equals(f(witness, "final_marking")) && resourceGoal(marking, f(input, "goal")), "$reachability", "final marking/goal");
    }
    private static void verifyResourceClosure(WireValue input, WireValue witness, boolean acyclic) throws GenerationFailure {
        resourceBound(input); List<WireValue> markings = a(f(witness, "explored_markings"));
        require(a(f(witness, "frontier")).isEmpty() && n(f(witness, "steps")).equals(BigInteger.valueOf(markings.size())) && n(f(witness, "steps")).compareTo(n(f(f(input, "bound"), "max_search_steps"))) <= 0 && markings.contains(f(input, "marking")) && new HashSet<>(markings).size() == markings.size(), "$closure", "finite complete marking basis");
        List<Set<Integer>> edges = new ArrayList<>();
        for (WireValue marking : markings) {
            Set<Integer> successors = new LinkedHashSet<>();
            for (WireValue transition : a(f(input, "transitions"))) if (enabled(input, transition, marking)) { int index = markings.indexOf(applyResource(input, transition, marking)); require(index >= 0, "$closure", "all enabled successors"); successors.add(index); }
            edges.add(successors);
            if (!acyclic) require(!resourceGoal(marking, f(input, "goal")), "$closure", "unreachable goal");
        }
        Set<Integer> reached = new HashSet<>(); ArrayDeque<Integer> pending = new ArrayDeque<>(); pending.add(markings.indexOf(f(input, "marking")));
        while (!pending.isEmpty()) { int index = pending.pop(); if (reached.add(index)) pending.addAll(edges.get(index)); }
        require(reached.size() == markings.size(), "$closure", "reachable closure states");
        if (acyclic) {
            int[] indegrees = new int[markings.size()]; for (Set<Integer> successors : edges) for (int successor : successors) indegrees[successor]++;
            for (int i = 0; i < indegrees.length; i++) if (indegrees[i] == 0) pending.push(i); int removed = 0;
            while (!pending.isEmpty()) { int index = pending.pop(); removed++; for (int successor : edges.get(index)) if (--indegrees[successor] == 0) pending.push(successor); }
            require(removed == markings.size(), "$closure", "acyclic marking graph");
        }
    }
    private static int compareUtf8(String left, String right) {
        int li = 0, ri = 0;
        while (li < left.length() && ri < right.length()) { int l = left.codePointAt(li), r = right.codePointAt(ri); if (l != r) return Integer.compare(l, r); li += Character.charCount(l); ri += Character.charCount(r); }
        return Integer.compare(left.length() - li, right.length() - ri);
    }
    private static String pathKey(WireValue path) {
        List<String> steps = new ArrayList<>(); for (WireValue step : a(path)) steps.add(encodeTuple(tag(step).toLowerCase(java.util.Locale.ROOT), s(payload(step)))); return encodeTuple(steps);
    }
    private static String armKey(WireValue arm) {
        String name = switch (tag(arm)) { case "UnknownVariant" -> "unknown-variant"; default -> tag(arm).toLowerCase(java.util.Locale.ROOT); };
        return tag(arm).equals("Variant") ? encodeTuple(name, s(payload(arm))) : encodeTuple(name);
    }
    private static String bindingKey(WireValue binding) {
        WireValue p = payload(binding);
        if (tag(binding).equals("Source")) return encodeTuple("source", producerIdentity(f(f(p, "value"), "producer")), pathKey(f(f(p, "value"), "path")));
        List<String> fields = new ArrayList<>(); for (WireValue tuple : a(f(p, "fields"))) fields.add(encodeTuple(s(a(tuple).get(0)), bindingKey(a(tuple).get(1)))); fields.sort(SemanticGeneration::compareUtf8);
        return encodeTuple("construct", s(f(p, "construction")), typeIdentity(f(p, "type_ref")), encodeTuple(fields));
    }
    public static String invocationKey(WireValue invocation) {
        List<String> bindings = new ArrayList<>(), resources = new ArrayList<>();
        for (WireValue tuple : a(f(invocation, "bindings"))) bindings.add(encodeTuple(s(a(tuple).get(0)), bindingKey(a(tuple).get(1))));
        for (WireValue binding : a(f(invocation, "resources"))) resources.add(encodeTuple(s(f(binding, "requirement")), lotIdentity(f(binding, "lot"))));
        bindings.sort(SemanticGeneration::compareUtf8); resources.sort(SemanticGeneration::compareUtf8);
        return encodeTuple("invoke", s(f(invocation, "site")), functionIdentity(f(invocation, "function")), encodeTuple(bindings), encodeTuple(resources));
    }
    public static String returnKey(WireValue returned) {
        WireValue p = payload(returned);
        if (tag(returned).equals("Failure")) return encodeTuple("failure", s(f(p, "embedding")), bindingKey(f(p, "value")));
        List<String> outputs = new ArrayList<>(); for (WireValue tuple : a(p)) outputs.add(encodeTuple(s(a(tuple).get(0)), bindingKey(a(tuple).get(1)))); outputs.sort(SemanticGeneration::compareUtf8); return encodeTuple("success", encodeTuple(outputs));
    }
    private static String traceKey(WireValue step) {
        WireValue p = payload(step);
        return tag(step).equals("Invocation") ? encodeTuple("invoke", invocationKey(f(p, "invocation")), s(f(p, "outcome"))) : encodeTuple("guard", s(f(p, "guard")), producerIdentity(f(f(p, "inspected"), "producer")), pathKey(f(f(p, "inspected"), "path")), armKey(f(p, "arm")));
    }
    private static String choiceKey(WireValue choice) {
        WireValue p = payload(choice);
        if (tag(choice).equals("Invoke")) {
            List<String> outcomes = a(f(p, "outcomes")).stream().map(SemanticValues::s).sorted(SemanticGeneration::compareUtf8).toList(), empty = a(f(p, "empty_outcomes")).stream().map(SemanticValues::s).sorted(SemanticGeneration::compareUtf8).toList();
            return encodeTuple("invoke", invocationKey(f(p, "invocation")), encodeTuple(outcomes), encodeTuple(empty));
        }
        List<String> arms = a(f(p, "arms")).stream().map(SemanticGeneration::armKey).sorted(SemanticGeneration::compareUtf8).toList();
        return encodeTuple("guard", s(f(p, "guard")), producerIdentity(f(f(p, "inspected"), "producer")), pathKey(f(f(p, "inspected"), "path")), encodeTuple(arms));
    }
    private static void collectPlan(WireValue tree, Set<WireValue> functions, Set<WireValue> guards, Map<String, WireValue> invocations) {
        WireValue node = f(tree, "node"); if (tag(node).equals("Return")) return; WireValue p = payload(node);
        if (tag(node).equals("Invoke")) { WireValue invocation = f(p, "invocation"); functions.add(f(invocation, "function")); invocations.put(invocationKey(invocation), invocation); }
        else guards.add(f(p, "guard"));
        for (WireValue arm : a(f(p, "arms"))) collectPlan(a(arm).get(1), functions, guards, invocations);
    }

    public record ResourceBalance(String lot, String tokenType, String producer, BigInteger revision, BigInteger quantity, String provenance) {}
    public record ExecutionSnapshot(List<ResourceBalance> resources, necoherence.network.NetworkEffect.NetworkState network) {
        public ExecutionSnapshot { resources = List.copyOf(resources); Objects.requireNonNull(network); }
    }
    /** Resource transitions for generated function composition. */
    public static final class Execution {
        private final Checker checker;
        private final Map<String, WireValue> invocations = new LinkedHashMap<>();
        private final Map<String, WireValue> terminals = new LinkedHashMap<>();
        private final Map<WireValue, BigInteger> quantities = new LinkedHashMap<>();
        private final Set<WireValue> usedSites = new HashSet<>();
        private WireValue active;
        private boolean committed;
        private necoherence.network.NetworkEffect.NetworkState network;
        public Execution(CheckedGeneration checked, necoherence.network.NetworkEffect.NetworkState network) throws GenerationFailure, ValueFailure {
            require(checked != null && !nil(f(checked.input, "composition")), "$composition", "composition required");
            Objects.requireNonNull(checked); this.checker = new Checker(checked.input, checked.context); this.network = Objects.requireNonNull(network);
            collectPlan(f(f(f(f(checker.input, "composition"), "derivation"), "plan"), "root"), new HashSet<>(), new HashSet<>(), invocations);
            collectTerminals(f(f(f(f(checker.input, "composition"), "derivation"), "plan"), "root"));
            for (WireValue lot : checker.initialLots) quantities.put(variant("Initial", f(lot, "id")), n(f(lot, "quantity")));
        }
        private void collectTerminals(WireValue tree) {
            WireValue node = f(tree, "node");
            if (tag(node).equals("Return")) { WireValue returned = payload(node); terminals.put(returnKey(returned), returned); }
            else for (WireValue arm : a(f(payload(node), "arms"))) collectTerminals(a(arm).get(1));
        }
        public synchronized void checkInvocation(String key) throws GenerationFailure {
            require(active == null && invocations.containsKey(key), "$execution", "one declared invocation at a time");
            WireValue invocation = invocations.get(key), function = checker.siteSignature(f(invocation, "site")); require(!usedSites.contains(f(invocation, "site")), "$execution", "site permit");
            Map<WireValue, BigInteger> reads = new LinkedHashMap<>(), consumes = new LinkedHashMap<>();
            for (WireValue tuple : a(f(invocation, "bindings"))) for (WireValue source : bindingSources(a(tuple).get(1))) { WireValue lot = f(checker.declaredValue(f(source, "producer")), "resource"); if (!nil(lot)) reads.merge(lot, BigInteger.ONE, BigInteger::max); }
            for (WireValue requirement : a(f(function, "resource_inputs"))) {
                WireValue selected = find(a(f(invocation, "resources")), "requirement", f(requirement, "id")); require(selected != null, "$execution", "resource binding"); WireValue lot = f(selected, "lot");
                (tag(f(requirement, "mode")).equals("Read") ? reads : consumes).merge(lot, n(f(requirement, "multiplicity")), tag(f(requirement, "mode")).equals("Read") ? BigInteger::max : BigInteger::add);
            }
            Set<WireValue> lots = new HashSet<>(reads.keySet()); lots.addAll(consumes.keySet());
            for (WireValue lot : lots) require(quantities.getOrDefault(lot, BigInteger.ZERO).compareTo(reads.getOrDefault(lot, BigInteger.ZERO).max(consumes.getOrDefault(lot, BigInteger.ZERO))) >= 0, "$execution", "resource availability before effect");
            active = invocation; committed = false;
        }
        public synchronized void commitInvocation() throws GenerationFailure {
            require(active != null && !committed, "$execution", "invocation reservation"); WireValue function = checker.siteSignature(f(active, "site")); Map<WireValue, BigInteger> consumes = new LinkedHashMap<>();
            for (WireValue requirement : a(f(function, "resource_inputs"))) if (tag(f(requirement, "mode")).equals("Consume")) { WireValue binding = find(a(f(active, "resources")), "requirement", f(requirement, "id")); consumes.merge(f(binding, "lot"), n(f(requirement, "multiplicity")), BigInteger::add); }
            for (Map.Entry<WireValue, BigInteger> consumed : consumes.entrySet()) quantities.put(consumed.getKey(), quantities.get(consumed.getKey()).subtract(consumed.getValue()));
            committed = true; usedSites.add(f(active, "site"));
        }
        public synchronized void completeInvocation(String outcomeId) throws GenerationFailure {
            require(active != null && committed, "$execution", "committed invocation"); WireValue function = checker.siteSignature(f(active, "site")), outcome = find(a(f(function, "outcomes")), "id", str(outcomeId)); require(outcome != null, "$execution", "declared outcome");
            for (WireValue production : a(f(outcome, "produced_resources"))) quantities.put(producedLot(f(active, "site"), f(outcome, "id"), f(production, "id")), n(f(production, "quantity")));
            active = null; committed = false;
        }
        public synchronized void releaseUnissued() throws GenerationFailure { require(active != null && !committed, "$execution", "unissued invocation"); active = null; }
        public synchronized void finish(String terminalIdentity) throws GenerationFailure {
            require(active == null && terminals.containsKey(terminalIdentity), "$execution", "declared terminal invocation state");
            WireValue returned = terminals.get(terminalIdentity), resources; List<WireValue> expressions;
            if (tag(returned).equals("Success")) { resources = f(checker.goal, "final_resources"); expressions = a(payload(returned)).stream().map(tuple -> a(tuple).get(1)).toList(); }
            else { WireValue embedding = find(a(f(checker.goal, "failures")), "id", f(payload(returned), "embedding")); require(embedding != null, "$execution", "failure embedding"); resources = f(embedding, "final_resources"); expressions = List.of(f(payload(returned), "value")); }
            for (WireValue expression : expressions) for (WireValue source : bindingSources(expression)) {
                WireValue backing = f(checker.declaredValue(f(source, "producer")), "resource");
                require(nil(backing) || quantities.getOrDefault(backing, BigInteger.ZERO).signum() > 0, "$execution", "returned value resource backing");
            }
            for (WireValue requirement : a(resources)) {
                WireValue lot = f(requirement, "lot"); BigInteger count = n(f(requirement, "multiplicity")); require(quantities.getOrDefault(lot, BigInteger.ZERO).compareTo(count) >= 0 && (count.signum() == 0 || f(checker.lot(lot), "revision").equals(f(requirement, "revision"))), "$execution", "terminal resources");
            }
        }
        public synchronized void network(necoherence.network.NetworkEffect.NetworkState state) { network = Objects.requireNonNull(state); }
        public synchronized necoherence.network.NetworkEffect.NetworkState network() { return network; }
        public synchronized ExecutionSnapshot snapshot() throws GenerationFailure {
            List<ResourceBalance> balances = new ArrayList<>();
            for (Map.Entry<WireValue, BigInteger> entry : quantities.entrySet()) { WireValue lot = checker.lot(entry.getKey()); balances.add(new ResourceBalance(lotIdentity(entry.getKey()), checker.resourceTypeIdentity(f(lot, "token_type")), encodeWire(f(lot, "producer")), n(f(lot, "revision")), entry.getValue(), s(f(lot, "provenance")))); }
            return new ExecutionSnapshot(balances, network);
        }
    }
}
