// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import static necoherence.semantic.SemanticGeneration.*;
import java.util.*;
import java.math.BigInteger;
import java.util.function.*;
import necoherence.composition.SemanticExecution;
import necoherence.composition.SignatureCompositionWire;
import necoherence.composition.SemanticComposition.Prepared;
import necoherence.composition.SemanticComposition.PreparationFailed;
import necoherence.semantic.WireFailure.WireException;
import necoherence.semantic.SemanticTypes.IntegerShape;
import necoherence.semantic.SemanticTypes.StringShape;
import necoherence.semantic.SemanticTypes.TypeShape;
import necoherence.semantic.SemanticTypes.VersionedSemanticProfile;

/** Checked admission of opaque type identities and value contracts. */
public final class TypeSignatures {
    private TypeSignatures() {}
    /** An immutable library admitted through structural and semantic checks. */
    public static final class TypeSignatureLibrary {
        private final CheckedLibrary checked;
        private TypeSignatureLibrary(CheckedLibrary checked) { this.checked=checked; }
        public static TypeSignatureLibrary decode(String text)throws GenerationFailure {
            try {
                WireValue decoded=canonical(readJson(text),"TypeSignatureLibrary","$signatures");
                return new TypeSignatureLibrary(checkLibrary(decoded));
            }
            catch(GenerationFailure failure) { throw failure; }
            catch(WireException failure) { throw new GenerationFailure(failure.failure().path(),failure.failure().toString(),failure.failure()); }
        }
        private WireValue value() { return checked.value(); }
        public String encode() { return encodeWire(value()); }
        public String identity() { return s(f(value(),"identity")); }
        public String revision() { return s(f(value(),"revision")); }
        public List<WireValue> nodes() { return a(f(value(),"nodes")); }
        public List<WireValue> definitions() { return a(f(value(),"definitions")); }
        public List<WireValue> annotations() { return a(f(value(),"annotations")); }
    }
    /** Decodes caller-bound canonical profile bytes into the typed value-profile representation. */
    public static WireValue admitCanonicalProfile(WireValue expectedReference, List<WireValue> expectedSources,
            byte[] trustedBytes, byte[] inputBytes) throws GenerationFailure {
        return CanonicalProfiles.admit(expectedReference, expectedSources, trustedBytes, inputBytes);
    }
    static <D> void descriptors(Map<String,D> map, Function<String,D> record, BiConsumer<String,String> enumeration) {
        String records = """
SourceIdentity repository:s;revision:s;path:s;content_digest:s
SignatureOrigin source:SourceIdentity;locator:[s]
ProvenanceBinding target:AnnotationTarget;origins:[SignatureOrigin]
DefinitionGroup id:s;members:[s]
SignatureAnnotation target:AnnotationTarget;key:s;value:ExactJson
SignatureSlot type_id:s;required:b;nullable:b
SignatureField wire_name:s;slot:SignatureSlot
ElementContract type_id:s;nullable:b
SignatureProduct fields:[SignatureField];extras:ExtraMembers
SignatureArray item:ElementContract;min_length:?n;max_length:?n
SignatureBranch target:s;wire_tag:s;selector:BranchSelector
SignatureUnion branches:[SignatureBranch]
SealedRefinement key:s;leaf:SealedLeaf
SignatureNode id:s;shape:SignatureShape
SignatureInput id:s;contract:SignatureSlot
SignatureOutput id:s;contract:SignatureSlot
SignatureResourceProduction id:s;token_type:s;revision:n;quantity:n;provenance:s
SignatureOutcome id:s;form:OutcomeForm;cause:OutcomeCause;value_ports:[SignatureOutput];produced_resources:[SignatureResourceProduction]
OperationContract effect:EffectPoint;inputs:[SignatureInput];outcomes:[SignatureOutcome]
SignatureDefinition id:s;wire_identity:s;shape:SignatureDefinitionShape
SignatureGraphemeSource role:s;origin:SignatureOrigin
SignatureGraphemeRules reference:ProfileRef;component:GraphemeComponent;table_sha256:h;sources:[SignatureGraphemeSource];properties:[GraphemeRange];extended_pictographic:[CodepointRange];indic_conjunct:[IndicRange]
ValueProfile reference:ProfileRef;source_refs:[SourceIdentity];integer_domains:[IntegerDomainBinding];default_integer_domain:s;numbers:NumberModel;grapheme_rules:?SignatureGraphemeRules;format_bindings:[FormatBinding];bytes_policy:?BytesPolicy;wrappers:[Wrapper];tag:?TagModel
TypeSignatureLibrary schema:s;identity:s;revision:s;profile:ValueProfile;sources:[SourceIdentity];provenance:[ProvenanceBinding];groups:[DefinitionGroup];annotations:[SignatureAnnotation];nodes:[SignatureNode];definitions:[SignatureDefinition]
SignatureGenerationBasis signature_schema:s;library_identity:s;library_revision:s;profile:ProfileRef;graph_sha256:h;provenance_sha256:h;metadata_sha256:h;problem_sha256:?h;observations_sha256:?h;entrypoints_sha256:h
GoalObservations outputs:j;failures:j;final_resources:j;effects:j;residuals:j;execution_failures:j;provenance:j
ExpectedSignatureBasis basis:SignatureGenerationBasis;observations:?GoalObservations
SignatureEntrypoint identity:s;definition:s
SignatureGenerationInput schema:=ncoh-checked-generation@5;basis:SignatureGenerationBasis;signatures:TypeSignatureLibrary;composition:?j;entrypoints:[SignatureEntrypoint]
""";
        for (String line : records.lines().toList()) { int split=line.indexOf(' '); map.put(line.substring(0,split),record.apply(line.substring(split+1))); }
        enumeration.accept("AnnotationTarget","Library|Group:s|Definition:s|Type:s|Outcome{definition:s;outcome:s}");
        enumeration.accept("OutcomeCause","ValueContract{origin:SignatureOrigin}|ExternalCondition{specification:SignatureOrigin}");
        enumeration.accept("SignatureShape","Unknown:UnknownKind|Unit|Boolean:BooleanSpec|Integer:IntegerSpec|Decimal:DecimalSpec|String:StringSpec|Bytes:LengthSpec|Product:SignatureProduct|Array:SignatureArray|TaggedUnion:SignatureUnion|Sealed{tag:s;refinements:[SealedRefinement]}|Never|Alias{target:s}|RawBody{encoding:s}|Opaque{type_name:s}");
        enumeration.accept("SignatureDefinitionShape","Value:s|Symbol:s|Operation:OperationContract|Message:s");
    }
    private static final Comparator<String> TEXT_ORDER=SemanticValues::compareCodePoints;
    private static int compareTextLists(List<String> left,List<String> right) {
        for(int index=0;index<Math.min(left.size(),right.size());index++){int compared=compareCodePoints(left.get(index),right.get(index));if(compared!=0)return compared;}
        return Integer.compare(left.size(),right.size());
    }
    private static List<WireValue> sorted(WireValue rows, String field) { return a(rows).stream().sorted(Comparator.comparing(v->s(f(v,field)),TEXT_ORDER)).toList(); }
    static WireValue ordered(WireValue value) {
        if (value instanceof ObjectValue object) return new ObjectValue(object.members().stream().sorted(Comparator.comparing(Member::key,TEXT_ORDER)).map(m->new Member(m.key(),ordered(m.value()))).toList());
        if (value instanceof ArrayValue array) return arr(array.items().stream().map(TypeSignatures::ordered).toList());
        if (value instanceof DecimalValue decimal) return leanNumber(decimal.text());
        return value;
    }
    private static <K> List<WireValue> sortedByKey(List<WireValue> rows,Function<WireValue,K> key,Comparator<K> order) {
        List<Map.Entry<K,WireValue>> keyed=new ArrayList<>(rows.size());
        try { for(WireValue row:rows) keyed.add(Map.entry(key.apply(row),row)); }
        catch(RuntimeException failure) { return rows.stream().sorted((left,right)->order.compare(key.apply(left),key.apply(right))).toList(); }
        keyed.sort(Map.Entry.comparingByKey(order));
        List<WireValue> result=new ArrayList<>(keyed.size());
        for(Map.Entry<K,WireValue> entry:keyed) result.add(entry.getValue());
        return Collections.unmodifiableList(result);
    }
    static String hash(WireValue value) { return sha(encodeWire(ordered(value))); }
    private static WireValue semantic(WireValue value) {
        if (value instanceof ObjectValue object) {
            if (o(value).get("cause") != null) return new ObjectValue(object.members().stream().map(m -> new Member(m.key(), m.key().equals("cause") ? variant(tag(m.value())) : semantic(m.value()))).toList());
            return new ObjectValue(object.members().stream().map(m->new Member(m.key(),semantic(m.value()))).toList());
        }
        if (value instanceof ArrayValue array) return arr(array.items().stream().map(TypeSignatures::semantic).toList());
        return value;
    }
    /** Computes separate projections from a decoded signature library. */
    public static GenerationBasis basis(String libraryText, String entrypointsText) throws GenerationFailure {
        WireValue library=canonical(readJson(libraryText),"TypeSignatureLibrary","$signatures"), entries=canonical(readJson(entrypointsText),"[SignatureEntrypoint]","$entrypoints");
        return new GenerationBasis(computeBasis(library,entries,NIL),null);
    }
    /** The projections that a generation basis commits to by digest. */
    record Projections(WireValue graph, WireValue provenance, WireValue metadata, WireValue entrypoints, WireValue problem) {}
    static Projections projections(WireValue library, WireValue entries, WireValue problem) {
        WireValue graph=obj("profile",f(library,"profile"),"nodes",arr(sorted(f(library,"nodes"),"id")),"definitions",arr(sorted(f(library,"definitions"),"id")));
        List<WireValue> groups = sorted(f(library,"groups"),"id").stream().map(g -> obj("id",f(g,"id"),"members",arr(a(f(g,"members")).stream().sorted(Comparator.comparing(SemanticValues::s,TEXT_ORDER)).toList()))).toList();
        List<WireValue> annotations = sortedByKey(a(f(library,"annotations")),row->List.of(encodeWire(ordered(f(row,"target"))),s(f(row,"key")),encodeWire(ordered(f(row,"value")))),TypeSignatures::compareTextLists);
        WireValue metadata=obj("groups",arr(groups),"annotations",arr(annotations));
        List<WireValue> origins=new ArrayList<>();
        for(WireValue definition:sorted(f(library,"definitions"),"id")) if(tag(f(definition,"shape")).equals("Operation")) for(WireValue outcome:sorted(f(payload(f(definition,"shape")),"outcomes"),"id")) origins.add(obj("definition",f(definition,"id"),"outcome",f(outcome,"id"),"cause",f(outcome,"cause")));
        List<WireValue> bindings=sortedByKey(a(f(library,"provenance")),v->encodeWire(ordered(f(v,"target"))),TEXT_ORDER).stream().map(v->obj("target",f(v,"target"),"origins",arr(sortedByKey(a(f(v,"origins")),o->encodeWire(ordered(o)),TEXT_ORDER)))).toList();
        List<WireValue> sources=a(f(library,"sources")).stream().sorted((left,right)->compareTextLists(List.of(s(f(left,"repository")),s(f(left,"revision")),s(f(left,"path")),s(f(left,"content_digest"))),List.of(s(f(right,"repository")),s(f(right,"revision")),s(f(right,"path")),s(f(right,"content_digest"))))).toList();
        WireValue provenance=obj("sources",arr(sources),"provenance",arr(bindings),"outcome_origins",arr(origins));
        return new Projections(semantic(graph),provenance,metadata,arr(sorted(entries,"identity")),problem);
    }
    public static WireValue computeBasis(WireValue library, WireValue entries, WireValue problem) {
        Projections projected=projections(library,entries,problem);
        return obj("signature_schema",f(library,"schema"),"library_identity",f(library,"identity"),"library_revision",f(library,"revision"),"profile",f(f(library,"profile"),"reference"),"graph_sha256",str(hash(projected.graph())),"provenance_sha256",str(hash(projected.provenance())),"metadata_sha256",str(hash(projected.metadata())),"problem_sha256",nil(problem)?NIL:str(hash(problem)),"observations_sha256",nil(problem)?NIL:str(hash(GoalObservations.of(problem).value())),"entrypoints_sha256",str(hash(projected.entrypoints())));
    }
    public static WireValue decodeBasis(WireValue value, String path) throws GenerationFailure {
        return canonical(value, "SignatureGenerationBasis", path);
    }
    public static WireValue decodeShape(WireValue value, String path) throws GenerationFailure {
        return canonical(value, "SignatureShape", path);
    }
    public static WireValue decodeOutcomeCause(WireValue value, String path) throws GenerationFailure {
        return canonical(value, "OutcomeCause", path);
    }
    private static WireValue decodeExchange(WireValue parsed) throws GenerationFailure {
        try { return canonical(parsed,"SignatureGenerationInput","$"); }
        catch(GenerationFailure failure) {
            if(failure.path().equals("$.schema")&&failure.condition().equals("version"))
                throw new GenerationFailure("$.schema",s(member((ObjectValue)parsed,"schema")),GenerationFailureKind.UNSUPPORTED_SCHEMA);
            throw new GenerationFailure(failure.path(),failure.condition(),failure.wireFailure(),NIL,GenerationFailureKind.EXCHANGE_WIRE);
        }
    }
    /** Validates structure, value semantics, and caller-trusted projection digests. */
    public static CheckedGeneration admitGeneration(GenerationBasis expected,String text) throws GenerationFailure {
        WireValue parsed;
        try { parsed=readJson(text); }
        catch(GenerationFailure failure) { throw new GenerationFailure(failure.path(),failure.condition(),failure.wireFailure(),NIL,GenerationFailureKind.EXCHANGE_JSON); }
        catch(WireException failure) { throw new GenerationFailure(failure.failure().path(),failure.failure().toString(),failure.failure(),NIL,GenerationFailureKind.EXCHANGE_JSON); }
        return admitGeneration(expected,parsed);
    }
    static CheckedGeneration admitGeneration(GenerationBasis expected,WireValue parsed)throws GenerationFailure {
        WireValue input=decodeExchange(parsed);
        try {
            WireValue library=f(input,"signatures"), composition=f(input,"composition");
            if(a(f(input,"entrypoints")).isEmpty()&&nil(composition))
                throw new GenerationFailure("$entrypoints",NIL,GenerationFailureKind.ENTRYPOINTS_EMPTY);
            for(WireValue entry:a(f(input,"entrypoints"))) if(s(f(entry,"identity")).isEmpty())
                throw new GenerationFailure("$entrypoints",entry,GenerationFailureKind.ENTRYPOINT_IDENTITY_EMPTY);
            Set<String> entryIdentities=new HashSet<>();
            for(WireValue entry:a(f(input,"entrypoints"))) if(!entryIdentities.add(s(f(entry,"identity"))))
                throw new GenerationFailure("$entrypoints",entry,GenerationFailureKind.ENTRYPOINT_DUPLICATE);
            List<WireValue> selected=new ArrayList<>();
            for(WireValue entry:a(f(input,"entrypoints"))){
                WireValue definition=null;
                for(WireValue candidate:a(f(library,"definitions"))) if(f(candidate,"id").equals(f(entry,"definition"))){definition=candidate;break;}
                if(definition==null) throw new GenerationFailure("$entrypoints",entry,GenerationFailureKind.ENTRYPOINT_UNRESOLVED);
                selected.add(definition);
            }
            CheckedLibrary checkedLibrary;
            try { checkedLibrary=checkLibrary(library); }
            catch(GenerationFailure failure) {
                throw new GenerationFailure(failure.path(),failure.condition(),failure.wireFailure(),failure.observed(),GenerationFailureKind.LIBRARY);
            }
            Projections projections=projections(library,f(input,"entrypoints"),composition);
            SemanticExecution.AdmittedComposition admittedComposition=null;
            Exception compositionFailure=null;
            if(!nil(composition)) {
                try { admittedComposition=admitComposition(checkedLibrary,s(f(expected.value,"graph_sha256")),composition); }
                catch(GenerationFailure|WireException failure) { compositionFailure=failure; }
            }
            var admission=GenerationAdmission.admit(expected,f(input,"basis"),library,projections,compositionFailure==null);
            if(compositionFailure instanceof GenerationFailure failure) throw failure;
            if(compositionFailure instanceof WireException failure) throw failure;
            List<WireValue> internalNodes=new ArrayList<>();
            for(WireValue node:sorted(f(library,"nodes"),"id")) internalNodes.add(obj("reference",typeReference(s(f(node,"id"))),"shape",internalShape(f(node,"shape")),"description",NIL,"attributes",arr(List.of()),"extensions",arr(List.of())));
            Context context=new Context(obj("profile",f(library,"profile"),"nodes",arr(internalNodes),"source_refs",arr(List.of())));
            List<WireValue> providers=nil(composition)?List.of():a(f(f(composition,"problem"),"signatures"));
            return new CheckedGeneration(expected,input,context,java.util.stream.IntStream.range(0,internalNodes.size()).boxed().toList(),selected,providers,admittedComposition,admission);
        }catch(GenerationFailure failure){throw failure;}
        catch(WireException failure){
            throw new GenerationFailure(failure.failure().path(),failure.failure().toString(),failure.failure(),NIL,GenerationFailureKind.COMPOSITION_WIRE);
        }
    }
    private static SemanticExecution.AdmittedComposition admitComposition(CheckedLibrary checked,String graphSha256,WireValue composition)throws GenerationFailure, WireException {
        WireValue library=checked.value();
        keys(composition,"$",List.of("problem","derivation"));
        WireValue problemJson=f(composition,"problem");
        SignatureCompositionWire.ProblemWire problem=SignatureCompositionWire.decodeProblem(library,problemJson);
        var preparation=SignatureCompositionWire.prepare(checked,graphSha256,problem);
        if(preparation instanceof PreparationFailed failed)
            throw new GenerationFailure("$composition.problem",failed.failure());
        var prepared=((Prepared)preparation).value();
        return SignatureCompositionWire.admitDerivation(AdmissionAuthority.INSTANCE,library,problemJson,prepared,f(composition,"derivation"));
    }
    public static WireValue typeReference(String id) {
        return obj("source", obj("repository", str("ncoh-type-signatures"), "revision", str("1"), "path", str(""),
                "content_digest", str(""), "document_id", str(""), "declared_revision", NIL),
                "definition_name", str(id), "pointer", arr(List.of()));
    }
    public static WireValue internalSlot(WireValue slot){return obj("type_ref",typeReference(s(f(slot,"type_id"))),"required",f(slot,"required"),"nullable",f(slot,"nullable"));}
    public static WireValue internalShape(WireValue shape) {
        String kind = tag(shape); WireValue spec = o(shape).get("value");
        if (kind.equals("Product")) {
            List<WireValue> converted = new ArrayList<>();
            for (WireValue field : a(f(spec, "fields")))
                converted.add(obj("wire_name", f(field, "wire_name"), "slot", internalSlot(f(field, "slot")), "origin", syntheticOccurrence()));
            WireValue extras = f(spec, "extras");
            if (tag(extras).equals("Allow")) {
                WireValue values = payload(extras), contract = f(values, "value");
                extras = fields("Allow", obj("key_format", f(values, "key_format"), "value",
                        obj("type_ref", typeReference(s(f(contract, "type_id"))), "nullable", f(contract, "nullable"))));
            }
            return variant("Product", obj("fields", arr(converted), "extras", extras));
        }
        if (kind.equals("Array")) {
            WireValue item = f(spec, "item");
            return variant("Array", obj("item", obj("type_ref", typeReference(s(f(item, "type_id"))), "nullable", f(item, "nullable")),
                    "min_length", f(spec, "min_length"), "max_length", f(spec, "max_length")));
        }
        if (kind.equals("Alias")) return fields("Alias", obj("target", typeReference(s(f(payload(shape), "target"))), "reference_text", str("")));
        if (kind.equals("TaggedUnion")) return variant("TaggedUnion", obj("branches", arr(a(f(spec, "branches")).stream()
                .map(branch -> withOrigin(replace(branch, "target", typeReference(s(f(branch, "target")))))).toList())));
        return shape;
    }
    public static WireValue replace(WireValue object,String key,WireValue value) { return new ObjectValue(o(object).members().stream().map(m->m.key().equals(key)?new Member(key,value):m).toList()); }
    public static WireValue syntheticOccurrence() { return obj("source", SemanticGraphWire.sourceRefWire(new SemanticTypes.SourceRef("ncoh-type-signatures", "1", "", "", "", Optional.empty())), "pointer", arr(List.of())); }
    public static WireValue withOrigin(WireValue object) { List<Member> members = new ArrayList<>(o(object).members()); members.add(new Member("origin", syntheticOccurrence())); return new ObjectValue(members); }
    private static boolean sameWire(WireValue left,WireValue right) {
        if(left instanceof ObjectValue leftObject&&right instanceof ObjectValue rightObject){
            if(leftObject.members().size()!=rightObject.members().size())return false;
            for(Member member:leftObject.members()){
                WireValue value=rightObject.get(member.key());
                if(value==null||!sameWire(member.value(),value))return false;
            }
            return true;
        }
        if(left instanceof ArrayValue leftArray&&right instanceof ArrayValue rightArray){
            if(leftArray.items().size()!=rightArray.items().size())return false;
            for(int index=0;index<leftArray.items().size();index++)
                if(!sameWire(leftArray.items().get(index),rightArray.items().get(index)))return false;
            return true;
        }
        return left.equals(right);
    }
    /** Lean operationExtensionValid: the extended operation keeps the effect, the inputs and every base outcome, and adds only valid external failures. */
    public static boolean operationExtensionValid(WireValue library,WireValue base,WireValue extended) {
        List<WireValue> baseOutcomes=a(f(base,"outcomes")), extendedOutcomes=a(f(extended,"outcomes"));
        if(!sameWire(f(base,"effect"),f(extended,"effect"))||!sameWire(f(base,"inputs"),f(extended,"inputs"))||!uniqueNames(extendedOutcomes,"id"))return false;
        List<WireValue> sources=a(f(library,"sources"));
        for(WireValue outcome:baseOutcomes) if(extendedOutcomes.stream().noneMatch(candidate->sameWire(candidate,outcome)))return false;
        return extendedOutcomes.stream().allMatch(outcome->baseOutcomes.stream().anyMatch(candidate->sameWire(candidate,outcome))||externalSupplementValid(outcome,sources));
    }
    private static boolean externalSupplementValid(WireValue outcome,List<WireValue> sources) {
        try {
            WireValue cause=decodeOutcomeCause(f(outcome,"cause"),"$signature.cause");
            return tag(cause).equals("ExternalCondition")&&outcomeValid(replace(outcome,"cause",cause),sources);
        } catch(GenerationFailure rejected) { return false; }
    }
    public static final class CheckedProfile {
        private final WireValue value;
        CheckedProfile(WireValue value) { this.value=value; }
        public WireValue value() { return value; }
    }
    public static final class CheckedLibrary {
        private final WireValue value;
        private final CheckedProfile profile;
        CheckedLibrary(WireValue value, CheckedProfile profile) { this.value=value; this.profile=profile; }
        public WireValue value() { return value; }
        public CheckedProfile profile() { return profile; }
    }
    /** Lean library predicate codes used by the library declaration failures. */
    public enum LibraryPredicate { LB01, LB02, LB03, LB04, LB05, LB06, LB07, LB08, LB09, LB10, LB11, LB12, LB13, LB14, LB15, LB16, LB17, LB18, LB19 }
    /** Java representation of the Lean LibraryCheckFailure definition. */
    public sealed interface LibraryCheckFailure permits ProfileCheckFailure, LibraryDeclarationFailure {}
    /**
     * Java representation of the Lean LibraryCheckFailure.profile constructor.
     * @param reference profile reference of the failing profile
     * @param predicate failed profile predicate
     * @param location path of the failing profile field
     */
    public record ProfileCheckFailure(SemanticTypes.ProfileRef reference, SemanticValidation.ProfilePredicate predicate, List<String> location)
            implements LibraryCheckFailure {
        public ProfileCheckFailure { reference = Objects.requireNonNull(reference); predicate = Objects.requireNonNull(predicate); location = List.copyOf(location); }
    }
    /**
     * Java representation of the Lean LibraryCheckFailure.library constructor.
     * @param reference identity of the failing library
     * @param predicate failed library predicate
     * @param location path of the failing library field
     */
    public record LibraryDeclarationFailure(String reference, LibraryPredicate predicate, List<String> location)
            implements LibraryCheckFailure {
        public LibraryDeclarationFailure { reference = Objects.requireNonNull(reference); predicate = Objects.requireNonNull(predicate); location = List.copyOf(location); }
    }
    /**
     * Converts a declaration failure raised by the library check into its typed predicate.
     * @param library the library wire value that was checked
     * @param failure the declaration failure, whose condition is a predicate code
     * @return the typed library check failure
     */
    public static LibraryCheckFailure libraryCheckFailure(WireValue library, GenerationFailure failure) {
        List<String> location = List.of(failure.path().substring(1).split("\\."));
        String condition = failure.condition();
        if (condition.startsWith("PR")) {
            WireValue reference = f(f(library, "profile"), "reference");
            return new ProfileCheckFailure(new SemanticTypes.ProfileRef(s(f(reference, "identity")), s(f(reference, "revision")),
                    s(f(reference, "content_digest"))), SemanticValidation.ProfilePredicate.valueOf(condition), location);
        }
        return new LibraryDeclarationFailure(s(f(library, "identity")), LibraryPredicate.valueOf(condition), location);
    }
    private static void declarationFailure(String predicate, WireValue observed, String... location) throws GenerationFailure {
        throw new GenerationFailure("$" + String.join(".", location), predicate, null, observed);
    }
    private static void declarationFailure(String predicate, String... location) throws GenerationFailure {
        declarationFailure(predicate, NIL, location);
    }
    /** Decodes the wire profile into the typed profile and checks it with the typed Lean checkProfile. */
    public static CheckedProfile checkWireProfile(WireValue profile)throws GenerationFailure {
        checkedProfile(profile);
        return new CheckedProfile(profile);
    }
    private static VersionedSemanticProfile checkedProfile(WireValue profile)throws GenerationFailure {
        VersionedSemanticProfile typed = SemanticGraphWire.profile(profile, "$");
        if (SemanticValidation.checkProfile(typed) instanceof SemanticValidation.ProfileRejected rejected) {
            SemanticValidation.ProfileFailure failure = rejected.failure();
            WireValue observed = failure.predicate() == SemanticValidation.ProfilePredicate.PR01 ? f(profile, "reference") : profile;
            declarationFailure(failure.predicate().name(), observed, failure.location().toArray(String[]::new));
        }
        return typed;
    }
    public static CheckedLibrary checkLibrary(WireValue library)throws GenerationFailure {
        VersionedSemanticProfile semantic=checkedProfile(f(library,"profile"));
        ValidationTables tables=ValidationTables.of(semantic);
        CheckedProfile checked=new CheckedProfile(f(library,"profile"));
        List<WireValue> nodes=a(f(library,"nodes"));
        if(!libraryDeclarationValid(library)) declarationFailure("LB01", library, "library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("Product")&&!uniqueNames(a(f(payload(f(node,"shape")),"fields")),"wire_name"))) declarationFailure("LB02",library,"library");
        Set<String> wrapperKeys=a(f(f(library,"profile"),"wrappers")).stream().map(row->s(f(row,"key"))).collect(java.util.stream.Collectors.toSet());
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("Product")&&a(f(payload(f(node,"shape")),"fields")).stream().anyMatch(field->wrapperKeys.contains(s(f(field,"wire_name")))))) declarationFailure("LB03",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&!uniqueValues(a(f(payload(f(node,"shape")),"branches")).stream().map(branch->f(branch,"wire_tag")).toList()))) declarationFailure("LB04",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&otherwiseNotLast(a(f(payload(f(node,"shape")),"branches"))))) declarationFailure("LB05",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&a(f(payload(f(node,"shape")),"branches")).stream().anyMatch(branch->s(f(branch,"wire_tag")).isEmpty()||selectorHasEmptyKey(f(branch,"selector"))))) declarationFailure("LB06",library,"library");
        WireValue profile=f(library,"profile"), tagModel=f(profile,"tag");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&a(f(payload(f(node,"shape")),"branches")).stream().anyMatch(branch->tag(f(branch,"selector")).equals("InternalTag")&&!nil(tagModel)&&!tagAccepted(tables,s(f(branch,"wire_tag")))))) declarationFailure("LB07",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&a(f(payload(f(node,"shape")),"branches")).stream().anyMatch(branch->tag(f(branch,"selector")).equals("InternalTag")&&!nil(tagModel)&&!sealedTargetAgreement(nodes,tagModel,branch)))) declarationFailure("LB08",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&a(f(payload(f(node,"shape")),"branches")).stream().anyMatch(branch->!selectorValid(profile,f(branch,"selector"))))) declarationFailure("LB09",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("Sealed")&&!sealedNodeValid(nodes,tagModel,node))) declarationFailure("LB10",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&a(f(payload(f(node,"shape")),"branches")).stream().anyMatch(branch->tag(f(branch,"selector")).equals("InternalTag")&&!objectTarget(nodes,s(f(branch,"target")))))) declarationFailure("LB11",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("Product")&&!extrasFormatValid(profile,f(payload(f(node,"shape")),"extras")))) declarationFailure("LB12",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("String")&&!stringSpecValid(profile,payload(f(node,"shape"))))) declarationFailure("LB13",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("Integer")&&!integerSpecValid(profile,payload(f(node,"shape"))))) declarationFailure("LB14",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("Decimal")&&!decimalSpecValid(payload(f(node,"shape"))))) declarationFailure("LB15",library,"library");
        if(nodes.stream().anyMatch(node->Set.of("Array","Bytes").contains(tag(f(node,"shape")))&&!nodeBoundsValid(f(node,"shape")))) declarationFailure("LB16",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&!tagFieldAgreement(nodes,tables,tagModel,node))) declarationFailure("LB17",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&!uniqueValues(a(f(payload(f(node,"shape")),"branches")).stream().map(branch->tag(f(branch,"selector")).equals("InternalTag")?arr(List.of(f(branch,"selector"),f(branch,"wire_tag"))):f(branch,"selector")).toList()))) declarationFailure("LB18",library,"library");
        if(nodes.stream().anyMatch(node -> defaultInvalid(tables,node))) declarationFailure("LB19",library,"library");
        return new CheckedLibrary(library,checked);
    }
    /** Decodes the inline format rule and applies the typed check with the depth bound of the enclosing string value. */
    private static boolean inlineFormatWellFormed(WireValue rule) {
        try {
            SemanticTypes.FormatRule typed = SemanticGraphWire.formatRule(rule);
            return SemanticValidation.formatRuleWellFormed(SemanticTypes.formatRuleDepth(typed) + 1, typed);
        } catch (WireException | GenerationFailure rejected) {
            return false;
        }
    }
    private static boolean uniqueNames(List<WireValue> rows,String field){
        Set<String> values=new HashSet<>();return rows.stream().allMatch(row->{String value=s(f(row,field));return !value.isEmpty()&&values.add(value);});
    }
    private static boolean uniqueValues(List<WireValue> rows){return new HashSet<>(rows).size()==rows.size();}
    private static boolean libraryDeclarationValid(WireValue library){
        if(!s(f(library,"schema")).equals("ncoh-type-signatures@1")||s(f(library,"identity")).isEmpty()||s(f(library,"revision")).isEmpty()||!digest(f(f(f(library,"profile"),"reference"),"content_digest")))return false;
        List<WireValue> sources=a(f(library,"sources")), nodes=a(f(library,"nodes")), definitions=a(f(library,"definitions")), groups=a(f(library,"groups"));
        if(new HashSet<>(sources).size()!=sources.size()||!uniqueNames(nodes,"id")||!uniqueNames(definitions,"id")||!uniqueNames(groups,"id"))return false;
        for(WireValue source:sources)if(!digest(f(source,"content_digest")))return false;
        Set<String> nodeIds=nodes.stream().map(row->s(f(row,"id"))).collect(java.util.stream.Collectors.toSet());
        Set<String> definitionIds=definitions.stream().map(row->s(f(row,"id"))).collect(java.util.stream.Collectors.toSet());
        Set<WireValue> sourceSet=new HashSet<>(sources);
        for(WireValue node:nodes)for(String ref:shapeReferences(f(node,"shape")))if(!nodeIds.contains(ref))return false;
        for(WireValue definition:definitions){
            for(String ref:definitionReferences(f(definition,"shape")))if(!nodeIds.contains(ref))return false;
            if(tag(f(definition,"shape")).equals("Operation")&&!operationValid(payload(f(definition,"shape")),sources))return false;
        }
        for(WireValue group:groups)for(WireValue member:a(f(group,"members")))if(!definitionIds.contains(s(member)))return false;
        for(WireValue row:a(f(library,"provenance"))){
            if(!targetValid(f(row,"target"),nodes,definitions,groups))return false;
            for(WireValue origin:a(f(row,"origins")))if(!sourceSet.contains(f(origin,"source")))return false;
        }
        for(WireValue row:a(f(library,"annotations")))if(!targetValid(f(row,"target"),nodes,definitions,groups))return false;
        return true;
    }
    private static boolean operationValid(WireValue operation,List<WireValue> sources){
        List<WireValue> outcomes=a(f(operation,"outcomes"));
        if(!uniqueNames(a(f(operation,"inputs")),"id")||!uniqueNames(outcomes,"id")||outcomes.isEmpty())return false;
        return outcomes.stream().allMatch(outcome->outcomeValid(outcome,sources));
    }
    /** Lean outcomeValid: the value ports and the produced resources have unique identities, and the cause names a source of the library. */
    public static boolean outcomeValid(WireValue outcome,List<WireValue> sources){
        List<WireValue> ports=a(f(outcome,"value_ports"));
        if(!uniqueNames(ports,"id")||!uniqueNames(a(f(outcome,"produced_resources")),"id"))return false;
        WireValue cause=f(outcome,"cause");
        boolean external=tag(cause).equals("ExternalCondition");
        WireValue source=f(f(payload(cause),external?"specification":"origin"),"source");
        if(sources.stream().noneMatch(candidate->sameWire(candidate,source)))return false;
        return !external||!ports.isEmpty()&&tag(f(outcome,"form")).equals("DeclaredFailure");
    }
    private static boolean targetValid(WireValue target,List<WireValue> nodes,List<WireValue> definitions,List<WireValue> groups){
        String kind=tag(target);
        if(kind.equals("Library"))return true;
        if(kind.equals("Outcome")){
            WireValue reference=payload(target);
            return definitions.stream().filter(row->s(f(row,"id")).equals(s(f(reference,"definition")))).anyMatch(row->
                    tag(f(row,"shape")).equals("Operation")&&a(f(payload(f(row,"shape")),"outcomes")).stream().anyMatch(item->s(f(item,"id")).equals(s(f(reference,"outcome")))));
        }
        List<WireValue> rows=kind.equals("Type")?nodes:kind.equals("Group")?groups:definitions;
        return rows.stream().anyMatch(row->s(f(row,"id")).equals(s(payload(target))));
    }
    private static final java.util.regex.Pattern DIGEST=java.util.regex.Pattern.compile("[0-9a-f]{64}");
    private static boolean digest(WireValue value){return value instanceof StringValue&&DIGEST.matcher(s(value)).matches();}
    private static List<String> shapeReferences(WireValue shape){
        WireValue spec=o(shape).get("value");if(spec==null)spec=o(shape).get("fields");
        return switch(tag(shape)){
            case "Alias"->List.of(s(f(spec,"target")));
            case "Array"->List.of(s(f(f(spec,"item"),"type_id")));
            case "Product"->{List<String> out=new ArrayList<>();for(WireValue row:a(f(spec,"fields")))out.add(s(f(f(row,"slot"),"type_id")));if(tag(f(spec,"extras")).equals("Allow"))out.add(s(f(f(payload(f(spec,"extras")),"value"),"type_id")));yield out;}
            case "TaggedUnion"->a(f(spec,"branches")).stream().map(row->s(f(row,"target"))).toList();
            default->List.of();
        };
    }
    private static List<String> definitionReferences(WireValue shape){
        String kind=tag(shape);if(kind.equals("Value")||kind.equals("Message"))return List.of(s(payload(shape)));
        if(!kind.equals("Operation"))return List.of();
        List<String> out=new ArrayList<>();WireValue operation=payload(shape);
        for(WireValue port:a(f(operation,"inputs")))out.add(s(f(f(port,"contract"),"type_id")));
        for(WireValue outcome:a(f(operation,"outcomes"))){for(WireValue port:a(f(outcome,"value_ports")))out.add(s(f(f(port,"contract"),"type_id")));for(WireValue production:a(f(outcome,"produced_resources")))out.add(s(f(production,"token_type")));}
        return out;
    }
    private static boolean otherwiseNotLast(List<WireValue> branches){
        for(int i=0;i<branches.size();i++)if(tag(f(branches.get(i),"selector")).equals("Otherwise")&&i+1!=branches.size())return true;return false;
    }
    private static boolean selectorHasEmptyKey(WireValue selector){
        return tag(selector).equals("MemberShape")&&a(payload(selector)).stream().anyMatch(test->s(f(test,"key")).isEmpty());
    }
    static Optional<SemanticTypes.GraphemeRules> graphemeRulesOf(WireValue profile){
        WireValue rules=f(profile,"grapheme_rules");
        return nil(rules)?Optional.empty():Optional.of(GraphemeWire.decode(rules,"$.grapheme_rules"));
    }
    private static boolean tagAccepted(ValidationTables tables,String value){
        if(tables.tag().isEmpty()||tables.tag().get().format().isEmpty())return true;
        return SemanticValidation.namedFormatAccepts(tables,tables.tag().get().format().get(),value);
    }
    private static boolean sealedTargetAgreement(List<WireValue> nodes,WireValue model,WireValue branch){
        if(nil(model))return false;boolean form=a(f(model,"sealed")).stream().anyMatch(row->f(row,"tag").equals(f(branch,"wire_tag")));
        boolean target=nodes.stream().anyMatch(row->f(row,"id").equals(f(branch,"target"))&&tag(f(row,"shape")).equals("Sealed")&&f(payload(f(row,"shape")),"tag").equals(f(branch,"wire_tag")));
        return form==target;
    }
    private static boolean selectorValid(WireValue profile,WireValue selector){
        if(!tag(selector).equals("MemberShape"))return true;
        List<WireValue> tests=a(payload(selector));if(!uniqueNames(tests,"key"))return false;
        Set<String> formats=a(f(profile,"format_bindings")).stream().map(row->s(f(row,"name"))).collect(java.util.stream.Collectors.toSet());
        return tests.stream().allMatch(test->!tag(f(test,"test")).equals("Format")||formats.contains(s(payload(f(test,"test")))));
    }
    private static boolean sealedNodeValid(List<WireValue> nodes,WireValue model,WireValue node){
        if(nil(model))return false;WireValue spec=payload(f(node,"shape")),form=a(f(model,"sealed")).stream().filter(row->f(row,"tag").equals(f(spec,"tag"))).findFirst().orElse(null);
        if(form==null||!uniqueNames(a(f(spec,"refinements")),"key"))return false;
        return a(f(spec,"refinements")).stream().allMatch(refinement->a(f(form,"fields")).stream().anyMatch(field->f(field,"key").equals(f(refinement,"key"))&&tag(f(field,"leaf")).equals(tag(f(refinement,"leaf")))));
    }
    private static boolean objectTarget(List<WireValue> nodes,String id){
        return nodes.stream().anyMatch(node->s(f(node,"id")).equals(id)&&Set.of("Product","Sealed").contains(tag(f(node,"shape"))));
    }
    private static boolean extrasFormatValid(WireValue profile,WireValue extras){
        if(tag(extras).equals("Reject")||nil(f(payload(extras),"key_format")))return true;WireValue use=f(payload(extras),"key_format");
        if(tag(use).equals("Inline"))return true;
        return a(f(profile,"format_bindings")).stream().anyMatch(row->f(row,"name").equals(payload(use)));
    }
    private static boolean stringSpecValid(WireValue profile,WireValue spec){
        if(!nil(f(spec,"wrapper"))&&a(f(profile,"wrappers")).stream().noneMatch(row->f(row,"name").equals(f(spec,"wrapper"))&&tag(f(row,"payload")).equals("Text")))return false;
        WireValue use=f(spec,"format");if(!nil(use)){if(tag(use).equals("Inline")){if(!inlineFormatWellFormed(payload(use)))return false;}else if(a(f(profile,"format_bindings")).stream().noneMatch(row->f(row,"name").equals(payload(use))))return false;}
        return a(f(spec,"lengths")).stream().allMatch(bound->boundsOrdered(f(bound,"minimum"),f(bound,"maximum")));
    }
    private static boolean integerSpecValid(WireValue profile,WireValue spec){
        return integerBoundsOrdered(f(spec,"minimum"),f(spec,"maximum"))&&(nil(f(spec,"domain"))||a(f(profile,"integer_domains")).stream().anyMatch(row->f(row,"name").equals(f(spec,"domain"))));
    }
    private static boolean decimalSpecValid(WireValue spec){
        if(nil(f(spec,"minimum"))||nil(f(spec,"maximum")))return true;return f(f(spec,"minimum"),"scale").equals(f(f(spec,"maximum"),"scale"))&&i(f(f(spec,"minimum"),"mantissa")).compareTo(i(f(f(spec,"maximum"),"mantissa")))<=0;
    }
    private static boolean boundsOrdered(WireValue minimum,WireValue maximum){return nil(minimum)||nil(maximum)||n(minimum).compareTo(n(maximum))<=0;}
    private static boolean integerBoundsOrdered(WireValue minimum,WireValue maximum){return nil(minimum)||nil(maximum)||i(minimum).compareTo(i(maximum))<=0;}
    private static boolean nodeBoundsValid(WireValue shape){
        WireValue spec=payload(shape);
        return tag(shape).equals("Bytes")?boundsOrdered(f(spec,"minimum"),f(spec,"maximum")):boundsOrdered(f(spec,"min_length"),f(spec,"max_length"));
    }
    private static boolean tagFieldAgreement(List<WireValue> nodes,ValidationTables tables,WireValue model,WireValue node){
        if(nil(model))return true;
        for(WireValue branch:a(f(payload(f(node,"shape")),"branches")))if(tag(f(branch,"selector")).equals("InternalTag")){
            WireValue target=nodes.stream().filter(row->f(row,"id").equals(f(branch,"target"))).findFirst().orElse(null);if(target==null)continue;
            if(tag(f(target,"shape")).equals("Product")){
                WireValue field=a(f(payload(f(target,"shape")),"fields")).stream().filter(row->f(row,"wire_name").equals(f(model,"key"))).findFirst().orElse(null);
                if(field==null)return false;
                WireValue type=nodes.stream().filter(row->f(row,"id").equals(f(f(field,"slot"),"type_id"))).findFirst().orElse(null);
                if(type==null||!tag(f(type,"shape")).equals("String")||(SemanticValidation.stringCondition(tables,((StringShape)SemanticGraphWire.shape(internalShape(f(type,"shape")))).spec(),s(f(branch,"wire_tag"))).isPresent()))return false;
            }
        }return true;
    }
    private static boolean defaultInvalid(ValidationTables semantic,WireValue node){
        TypeShape shape=SemanticGraphWire.shape(internalShape(f(node,"shape")));
        if(shape instanceof StringShape string){
            List<String> values=new ArrayList<>();
            string.spec().constValue().ifPresent(values::add);string.spec().enumValues().ifPresent(values::addAll);string.spec().defaultValue().ifPresent(values::add);
            return values.stream().anyMatch(value->SemanticValidation.stringCondition(semantic,string.spec(),value).isPresent());
        }
        if(shape instanceof IntegerShape integer){
            List<BigInteger> values=new ArrayList<>();
            integer.spec().constValue().ifPresent(values::add);integer.spec().enumValues().ifPresent(values::addAll);integer.spec().defaultValue().ifPresent(values::add);
            return values.stream().anyMatch(value->SemanticValidation.integerCondition(semantic,integer.spec(),new ExactJson.JsonNum(value)).isPresent());
        }
        return false;
    }
    /** Returns exact annotations in their admitted target representation. */
    public static List<WireValue> annotations(CheckedGeneration checked) { return List.copyOf(a(f(f(checked.input,"signatures"),"annotations"))); }
    /** Selects annotations by exact target identity. */
    public static List<WireValue> annotations(CheckedGeneration checked,WireValue target) { return annotations(checked).stream().filter(v->f(v,"target").equals(target)).toList(); }
    /** Parses exact wire JSON without numeric conversion. */
    public static WireValue parseWire(String text) { return readJson(text); }
}
