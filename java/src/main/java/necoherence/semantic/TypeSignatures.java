// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import static necoherence.semantic.SemanticGeneration.*;
import java.util.*;
import java.math.BigInteger;
import java.util.function.*;

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
            catch(RuntimeException failure) { throw new GenerationFailure("$signatures",failure.getMessage()); }
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
TypeSignatureLibrary schema:=ncoh-type-signatures@1;identity:s;revision:s;profile:ValueProfile;sources:[SourceIdentity];provenance:[ProvenanceBinding];groups:[DefinitionGroup];annotations:[SignatureAnnotation];nodes:[SignatureNode];definitions:[SignatureDefinition]
SignatureGenerationBasis signature_schema:=ncoh-type-signatures@1;library_identity:s;library_revision:s;profile:ProfileRef;graph_sha256:h;provenance_sha256:h;metadata_sha256:h;problem_sha256:?h;entrypoints_sha256:h
SignatureEntrypoint identity:s;definition:s
SignatureGenerationInput schema:=ncoh-checked-generation@4;basis:SignatureGenerationBasis;signatures:TypeSignatureLibrary;composition:?SigGenerationComposition;entrypoints:[SignatureEntrypoint]
""";
        for (String line : records.lines().toList()) { int split=line.indexOf(' '); map.put(line.substring(0,split),record.apply(line.substring(split+1))); }
        enumeration.accept("AnnotationTarget","Library|Group:s|Definition:s|Type:s|Outcome{definition:s;outcome:s}");
        enumeration.accept("OutcomeCause","ValueContract{origin:SignatureOrigin}|ExternalCondition{specification:SignatureOrigin}");
        enumeration.accept("SignatureShape","Unknown:UnknownKind|Unit|Boolean:BooleanSpec|Integer:IntegerSpec|Decimal:DecimalSpec|String:StringSpec|Bytes:LengthSpec|Product:SignatureProduct|Array:SignatureArray|TaggedUnion:SignatureUnion|Sealed{tag:s;refinements:[SealedRefinement]}|Never|Alias{target:s}|RawBody{encoding:s}|Opaque{type_name:s}");
        enumeration.accept("SignatureDefinitionShape","Value:s|Symbol:s|Operation:OperationContract|Message:s");
    }
    private static int compareText(String left,String right) {
        for(int a=0,b=0;a<left.length()&&b<right.length();) {
            int x=left.codePointAt(a),y=right.codePointAt(b);
            if(x!=y)return Integer.compare(x,y);
            a+=Character.charCount(x);b+=Character.charCount(y);
            if(a==left.length()||b==right.length())return Integer.compare(left.length()-a,right.length()-b);
        }
        return Integer.compare(left.length(),right.length());
    }
    private static final Comparator<String> TEXT_ORDER=TypeSignatures::compareText;
    private static List<WireValue> sorted(WireValue rows, String field) { return a(rows).stream().sorted(Comparator.comparing(v->s(f(v,field)),TEXT_ORDER)).toList(); }
    private static WireValue ordered(WireValue value) {
        if (value instanceof ObjectValue object) return new ObjectValue(object.members().stream().sorted(Comparator.comparing(Member::key,TEXT_ORDER)).map(m->new Member(m.key(),ordered(m.value()))).toList());
        if (value instanceof ArrayValue array) return arr(array.items().stream().map(TypeSignatures::ordered).toList());
        return value;
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
        return new GenerationBasis(computeBasis(library,entries,NIL));
    }
    public static WireValue computeBasis(WireValue library, WireValue entries, WireValue problem) {
        WireValue graph=obj("profile",f(library,"profile"),"nodes",arr(sorted(f(library,"nodes"),"id")),"definitions",arr(sorted(f(library,"definitions"),"id")));
        List<WireValue> groups = sorted(f(library,"groups"),"id").stream().map(g -> obj("id",f(g,"id"),"members",arr(a(f(g,"members")).stream().sorted(Comparator.comparing(SemanticValues::s,TEXT_ORDER)).toList()))).toList();
        List<WireValue> annotations = a(f(library,"annotations")).stream().sorted(Comparator.comparing(v -> encodeWire(ordered(f(v,"target"))) + "\u0000" + s(f(v,"key")) + "\u0000" + encodeWire(ordered(f(v,"value"))),TEXT_ORDER)).toList();
        WireValue metadata=obj("groups",arr(groups),"annotations",arr(annotations));
        List<WireValue> origins=new ArrayList<>();
        for(WireValue definition:sorted(f(library,"definitions"),"id")) if(tag(f(definition,"shape")).equals("Operation")) for(WireValue outcome:sorted(f(payload(f(definition,"shape")),"outcomes"),"id")) origins.add(obj("definition",f(definition,"id"),"outcome",f(outcome,"id"),"cause",f(outcome,"cause")));
        List<WireValue> bindings=a(f(library,"provenance")).stream().sorted(Comparator.comparing(v->encodeWire(ordered(f(v,"target"))),TEXT_ORDER)).map(v->obj("target",f(v,"target"),"origins",arr(a(f(v,"origins")).stream().sorted(Comparator.comparing(o->encodeWire(ordered(o)),TEXT_ORDER)).toList()))).toList();
        List<WireValue> sources=a(f(library,"sources")).stream().sorted(Comparator.comparing(v->s(f(v,"repository"))+"\u0000"+s(f(v,"revision"))+"\u0000"+s(f(v,"path"))+"\u0000"+s(f(v,"content_digest")),TEXT_ORDER)).toList();
        WireValue provenance=obj("sources",arr(sources),"provenance",arr(bindings),"outcome_origins",arr(origins));
        return obj("signature_schema",f(library,"schema"),"library_identity",f(library,"identity"),"library_revision",f(library,"revision"),"profile",f(f(library,"profile"),"reference"),"graph_sha256",str(hash(semantic(graph))),"provenance_sha256",str(hash(provenance)),"metadata_sha256",str(hash(metadata)),"problem_sha256",nil(problem)?NIL:str(hash(problem)),"entrypoints_sha256",str(hash(arr(sorted(entries,"identity")))));
    }
    private static Map<String,WireValue> index(WireValue rows,String field,String path) throws GenerationFailure {
        Map<String,WireValue> result=new LinkedHashMap<>(); for(WireValue row:a(rows)){String id=s(f(row,field));require(!id.isEmpty()&&result.put(id,row)==null,path,"unique nonempty identity");}return result;
    }
    private static void target(WireValue target,Map<String,WireValue> nodes,Map<String,WireValue> definitions,Map<String,WireValue> groups) throws GenerationFailure {
        String kind=tag(target); if(kind.equals("Library"))return;
        if(kind.equals("Outcome")){WireValue p=payload(target), definition=definitions.get(s(f(p,"definition")));require(definition!=null&&tag(f(definition,"shape")).equals("Operation"),"$metadata","resolved operation");require(a(f(payload(f(definition,"shape")),"outcomes")).stream().anyMatch(o->f(o,"id").equals(f(p,"outcome"))),"$metadata","resolved outcome");return;}
        require((kind.equals("Type")?nodes:kind.equals("Group")?groups:definitions).containsKey(s(payload(target))),"$metadata","resolved target");
    }
    private static void origin(WireValue origin,Collection<WireValue> sources) throws GenerationFailure {require(sources.contains(f(origin,"source")),"$provenance","resolved source");}
    /** Validates structure, value semantics, and caller-trusted projection digests. */
    public static CheckedGeneration admitGeneration(GenerationBasis expected,String text) throws GenerationFailure {
        try { return admitGeneration(expected,readJson(text)); }
        catch(RuntimeException failure) { throw new GenerationFailure("$",failure.getMessage()==null?failure.getClass().getSimpleName():failure.getMessage()); }
    }
    static CheckedGeneration admitGeneration(GenerationBasis expected,WireValue parsed)throws GenerationFailure {
        WireValue schema = parsed instanceof ObjectValue ? member((ObjectValue) parsed, "schema") : null;
        if (schema instanceof StringValue text && !text.value().equals("ncoh-checked-generation@4"))
            throw new GenerationFailure("$.schema", "UnsupportedSchema", new UnsupportedSchema(text.value()));
        try {
            WireValue input=canonical(parsed,"SignatureGenerationInput","$"), library=f(input,"signatures");
            require(expected.value.equals(f(input,"basis")),"$.basis","caller-trusted basis mismatch");
            require(computeBasis(library,f(input,"entrypoints"),f(input,"composition")).equals(f(input,"basis")),"$.basis","signature projection digest mismatch");
            Map<String,WireValue> nodes=index(f(library,"nodes"),"id","$nodes"), definitions=index(f(library,"definitions"),"id","$definitions"), groups=index(f(library,"groups"),"id","$groups");
            index(f(library,"definitions"),"wire_identity","$definitions");
            require(!s(f(library,"identity")).isEmpty()&&!s(f(library,"revision")).isEmpty(),"$signatures","library identity/revision");
            Set<WireValue> sources=new HashSet<>(a(f(library,"sources")));require(sources.size()==a(f(library,"sources")).size(),"$sources","unique source identity");
            for(WireValue source:sources) for(String field:List.of("repository","revision","path")) require(!s(f(source,field)).isEmpty(),"$sources","nonempty source identity");
            checkLibrary(library);
            for(WireValue group:groups.values()){Set<WireValue> seen=new HashSet<>();for(WireValue id:a(f(group,"members")))require(definitions.containsKey(s(id))&&seen.add(id),"$groups","resolved unique member");}
            for(WireValue row:a(f(library,"provenance"))){target(f(row,"target"),nodes,definitions,groups);for(WireValue item:a(f(row,"origins")))origin(item,sources);}
            Set<WireValue> annotationKeys=new HashSet<>();for(WireValue row:a(f(library,"annotations"))){target(f(row,"target"),nodes,definitions,groups);require(!s(f(row,"key")).isEmpty()&&annotationKeys.add(arr(List.of(f(row,"target"),f(row,"key")))),"$annotations","unique annotation key per target");exact(f(row,"value"));}
            WireValue profile=internalProfile(f(library,"profile"));
            List<WireValue> internalNodes=new ArrayList<>();for(WireValue node:sorted(f(library,"nodes"),"id")) internalNodes.add(obj("reference",f(node,"id"),"shape",internalShape(f(node,"shape"))));
            Context context=new Context(obj("profile",profile,"nodes",arr(internalNodes),"definitions",f(library,"definitions")));
            for(int i=0;i<internalNodes.size();i++){for(WireValue child:Context.children(context.shape(i)))require(nodes.containsKey(s(child)),"$nodes","resolved type identity");checkShape(context,i);context.meaning(i);}
            List<WireValue> providers=new ArrayList<>();for(WireValue definition:definitions.values()){WireValue shape=f(definition,"shape");String kind=tag(shape);if(kind.equals("Value")||kind.equals("Message"))require(nodes.containsKey(s(payload(shape))),"$definitions","resolved type");else if(kind.equals("Operation")){WireValue operation=payload(shape);checkOperation(operation,nodes,sources);providers.add(operation);}}
            index(f(input,"entrypoints"),"identity","$entrypoints");require(!a(f(input,"entrypoints")).isEmpty(),"$entrypoints","entrypoint required");List<WireValue> selected=new ArrayList<>();for(WireValue entry:a(f(input,"entrypoints"))){WireValue definition=definitions.get(s(f(entry,"definition")));require(definition!=null,"$entrypoints","resolved definition");selected.add(definition);}
            WireValue composition=f(input,"composition");
            if(!nil(composition)) {
                WireValue internal=replace(input,"composition",internalComposition(composition));
                verifySignatureComposition(input,context);
                providers=new ArrayList<>(a(f(f(f(internal,"composition"),"problem"),"signatures")));
            } else providers=List.of();
            return new CheckedGeneration(expected,input,context,java.util.stream.IntStream.range(0,internalNodes.size()).boxed().toList(),selected,providers);
        }catch(GenerationFailure failure){throw failure;}
        catch(ValueFailure failure){throw new GenerationFailure("$values"+failure.path(),failure.condition());}
        catch(RuntimeException failure){
            GenerationFailure reported=new GenerationFailure("$",failure.getMessage()==null?failure.getClass().getSimpleName():failure.getMessage());
            reported.initCause(failure);throw reported;
        }
    }
    static void checkCompositionOutcome(WireValue library,WireValue outcome)throws GenerationFailure {
        WireValue cause=f(outcome,"cause");String kind=tag(cause);
        origin(f(payload(cause),kind.equals("ExternalCondition")?"specification":"origin"),a(f(library,"sources")));
        if(kind.equals("ExternalCondition"))require(tag(f(outcome,"form")).equals("DeclaredFailure")&&!a(f(outcome,"value_ports")).isEmpty(),"$outcomes","typed external declared failure");
    }
    public static WireValue internalSlot(WireValue slot){return obj("type_ref",f(slot,"type_id"),"required",f(slot,"required"),"nullable",f(slot,"nullable"));}
    private static WireValue internalShape(WireValue shape) {
        String kind = tag(shape); WireValue spec = o(shape).get("value");
        if (kind.equals("Product")) {
            List<WireValue> converted = new ArrayList<>();
            for (WireValue field : a(f(spec, "fields")))
                converted.add(obj("wire_name", f(field, "wire_name"), "slot", internalSlot(f(field, "slot"))));
            WireValue extras = f(spec, "extras");
            if (tag(extras).equals("Allow")) {
                WireValue values = payload(extras), contract = f(values, "value");
                extras = fields("Allow", obj("key_format", f(values, "key_format"), "value",
                        obj("type_ref", f(contract, "type_id"), "nullable", f(contract, "nullable"))));
            }
            return variant("Product", obj("fields", arr(converted), "extras", extras));
        }
        if (kind.equals("Array")) {
            WireValue item = f(spec, "item");
            return variant("Array", obj("item", obj("type_ref", f(item, "type_id"), "nullable", f(item, "nullable")),
                    "min_length", f(spec, "min_length"), "max_length", f(spec, "max_length")));
        }
        return shape;
    }
    private static void checkShape(Context context,int type)throws GenerationFailure,ValueFailure {
        WireValue shape=context.shape(type);String kind=tag(shape);
        if(kind.equals("Alias"))require(context.resolve(context.reference(type))!=null,"$nodes","defined alias meaning");
    }
    private static void checkOperation(WireValue operation,Map<String,WireValue> nodes,Set<WireValue> sources)throws GenerationFailure {
        index(f(operation,"inputs"),"id","$ports");index(f(operation,"outcomes"),"id","$outcomes");require(!a(f(operation,"outcomes")).isEmpty(),"$outcomes","declared outcomes");
        require(a(f(operation,"outcomes")).stream().anyMatch(o->tag(f(o,"form")).equals("Success")),"$outcomes","success outcome");
        for(WireValue port:a(f(operation,"inputs")))slot(f(port,"contract"),nodes);
        for(WireValue outcome:a(f(operation,"outcomes"))){WireValue cause=f(outcome,"cause");origin(f(payload(cause),tag(cause).equals("ExternalCondition")?"specification":"origin"),sources);index(f(outcome,"value_ports"),"id","$outputs");for(WireValue port:a(f(outcome,"value_ports")))slot(f(port,"contract"),nodes);if(tag(cause).equals("ExternalCondition"))require(tag(f(outcome,"form")).equals("DeclaredFailure")&&!a(f(outcome,"value_ports")).isEmpty(),"$outcomes","typed external declared failure");}
        for(WireValue outcome:a(f(operation,"outcomes"))) {index(f(outcome,"produced_resources"),"id","$productions");for(WireValue resource:a(f(outcome,"produced_resources"))) require(nodes.containsKey(s(f(resource,"token_type"))),"$productions","resolved resource type");}
    }
    private static void slot(WireValue slot,Map<String,WireValue> nodes)throws GenerationFailure{require(nodes.containsKey(s(f(slot,"type_id"))),"$ports","resolved type");}
    /** Preserves each basic outcome and admits only sourced external failures as supplements. */
    public static void checkOperationSignature(String libraryText,String definitionId,String signatureText)throws GenerationFailure {
        WireValue library=canonical(readJson(libraryText),"TypeSignatureLibrary","$signatures"), signature=canonical(readJson(signatureText),"OperationContract","$signature");Map<String,WireValue> definitions=index(f(library,"definitions"),"id","$definitions");WireValue definition=definitions.get(definitionId);require(definition!=null&&tag(f(definition,"shape")).equals("Operation"),"$signature","operation definition");WireValue basic=payload(f(definition,"shape"));require(f(basic,"effect").equals(f(signature,"effect"))&&f(basic,"inputs").equals(f(signature,"inputs")),"$signature","basic effect and inputs");Map<String,WireValue> outcomes=index(f(signature,"outcomes"),"id","$outcomes");checkOperation(signature,index(f(library,"nodes"),"id","$nodes"),new HashSet<>(a(f(library,"sources"))));for(WireValue outcome:a(f(basic,"outcomes")))require(outcome.equals(outcomes.remove(s(f(outcome,"id")))),"$signature","basic outcome preserved");for(WireValue outcome:outcomes.values())require(tag(f(outcome,"cause")).equals("ExternalCondition"),"$signature","external supplement");
    }
    public static WireValue replace(WireValue object,String key,WireValue value) { return new ObjectValue(o(object).members().stream().map(m->m.key().equals(key)?new Member(key,value):m).toList()); }
    static WireValue problemBasis(WireValue basis) { return replace(replace(basis,"problem_sha256",NIL),"entrypoints_sha256",str(hash(arr(List.of())))); }
    public static WireValue internalComposition(WireValue value) {
        if(value instanceof ObjectValue object) return new ObjectValue(object.members().stream().map(m->new Member(m.key().equals("type_id")?"type_ref":m.key(),Set.of("source_shape","destination_shape").contains(m.key())?internalShape(m.value()):internalComposition(m.value()))).toList());
        if(value instanceof ArrayValue array) return arr(array.items().stream().map(TypeSignatures::internalComposition).toList());
        return value;
    }
    static void checkOperationSignatureValue(WireValue library,String definitionId,WireValue function)throws GenerationFailure {
        Map<String,WireValue> definitions=index(f(library,"definitions"),"id","$definitions");WireValue definition=definitions.get(definitionId);
        require(definition!=null&&tag(f(definition,"shape")).equals("Operation"),"$signature","resolved operation");
        WireValue basic=payload(f(definition,"shape"));
        require(f(f(function,"reference"),"identity").equals(f(definition,"wire_identity"))&&f(f(function,"reference"),"revision").equals(f(library,"revision")),"$signature","operation identity/revision");
        require(f(f(function,"reference"),"content_digest").equals(f(computeBasis(library,arr(List.of()),NIL),"graph_sha256")),"$signature","operation graph digest");
        require(f(function,"effect").equals(f(basic,"effect")),"$signature","basic effect");
        List<WireValue> expectedInputs=a(f(basic,"inputs")).stream().map(p->obj("id",f(p,"id"),"contract",internalSlot(f(p,"contract")))).toList();
        List<WireValue> actualInputs=a(f(function,"inputs")).stream().map(p->obj("id",f(p,"id"),"contract",f(p,"contract"))).toList();
        require(expectedInputs.equals(actualInputs),"$signature","basic inputs");
        Map<String,WireValue> outcomes=index(f(function,"outcomes"),"id","$outcomes");
        for(WireValue outcome:a(f(basic,"outcomes"))) {
            WireValue actual=outcomes.remove(s(f(outcome,"id")));require(actual!=null,"$signature","basic outcome preserved");
            require(f(actual,"form").equals(f(outcome,"form"))&&f(actual,"cause").equals(f(outcome,"cause")),"$signature","basic outcome form/cause");
            List<WireValue> ports=a(f(outcome,"value_ports")).stream().map(p->obj("id",f(p,"id"),"contract",internalSlot(f(p,"contract")))).toList();
            List<WireValue> actualPorts=a(f(actual,"value_ports")).stream().map(p->obj("id",f(p,"id"),"contract",f(p,"contract"))).toList();
            require(ports.equals(actualPorts)&&f(actual,"produced_resources").equals(f(outcome,"produced_resources")),"$signature","basic outcome contract");
        }
        for(WireValue outcome:outcomes.values()) {
            require(tag(f(outcome,"cause")).equals("ExternalCondition")&&tag(f(outcome,"form")).equals("DeclaredFailure")&&!a(f(outcome,"value_ports")).isEmpty(),"$signature","typed external supplement");
            origin(f(payload(f(outcome,"cause")),"specification"),new HashSet<>(a(f(library,"sources"))));
        }
    }
    private static WireValue internalProfile(WireValue profile) {
        WireValue rules=f(profile,"grapheme_rules");if(nil(rules))return profile;
        WireValue sources=arr(a(f(rules,"sources")).stream().map(row->{WireValue source=f(f(row,"origin"),"source");return obj("role",f(row,"role"),"source",source);}).toList());
        return replace(profile,"grapheme_rules",replace(rules,"sources",sources));
    }
    public record CheckedProfile(WireValue value) {}
    public record CheckedLibrary(WireValue value, CheckedProfile profile) {}
    private static void declarationFailure(String predicate, WireValue observed, String... location) throws GenerationFailure {
        throw new GenerationFailure("$" + String.join(".", location), predicate, null, observed);
    }
    private static void declarationFailure(String predicate, String... location) throws GenerationFailure {
        declarationFailure(predicate, NIL, location);
    }
    public static CheckedProfile checkProfile(WireValue profile)throws GenerationFailure {
        WireValue reference=f(profile,"reference");
        List<WireValue> domains=a(f(profile,"integer_domains")), bindings=a(f(profile,"format_bindings"));
        List<WireValue> wrappers=a(f(profile,"wrappers")); WireValue bytes=f(profile,"bytes_policy"), model=f(profile,"tag");
        if(!validProfileReference(reference)
                || domains.stream().anyMatch(row->!validProfileReference(f(row,"reference")))
                || bindings.stream().anyMatch(row->!validProfileReference(f(row,"reference")))
                || !nil(bytes)&&!validProfileReference(f(bytes,"reference"))
                || !nil(f(profile,"grapheme_rules"))&&!validProfileReference(f(f(profile,"grapheme_rules"),"reference")))
            declarationFailure("PR01", reference, "profile");
        if(!uniqueNames(domains,"name")) declarationFailure("PR02",profile,"integer_domains");
        if(domains.stream().anyMatch(row->{WireValue range=f(row,"range");return tag(range).equals("Inclusive")&&n(f(payload(range),"minimum")).compareTo(n(f(payload(range),"maximum")))>0;}))
            declarationFailure("PR03",profile,"integer_domains");
        if(domains.stream().anyMatch(row->a(f(row,"forms")).isEmpty())) declarationFailure("PR04",profile,"integer_domains");
        if(domains.stream().noneMatch(row->f(row,"name").equals(f(profile,"default_integer_domain"))))
            declarationFailure("PR05",profile,"default_integer_domain");
        if(!uniqueNames(bindings,"name")) declarationFailure("PR06",profile,"format_bindings");
        if(bindings.stream().anyMatch(row->!formatRuleWellFormed(f(row,"rule")))) declarationFailure("PR07",profile,"format_bindings");
        if(!uniqueNames(wrappers,"name")||!uniqueNames(wrappers,"key")) declarationFailure("PR08",profile,"wrappers");
        Set<String> formatNames=bindings.stream().map(row->s(f(row,"name"))).collect(java.util.stream.Collectors.toSet());
        if(wrappers.stream().anyMatch(row->tag(f(row,"payload")).equals("Text")&&!nil(payload(f(row,"payload")))&&!formatNames.contains(s(payload(f(row,"payload"))))))
            declarationFailure("PR09",profile,"wrappers");
        if(!nil(bytes)&&!nil(f(bytes,"wrapper"))&&wrappers.stream().noneMatch(row->f(row,"name").equals(f(bytes,"wrapper"))&&tag(f(row,"payload")).equals("Bytes")))
            declarationFailure("PR10",profile,"bytes_policy","wrapper");
        if(!nil(model)){
            Set<String> wrapperKeys=wrappers.stream().map(row->s(f(row,"key"))).collect(java.util.stream.Collectors.toSet());
            if(s(f(model,"key")).isEmpty()||wrapperKeys.contains(s(f(model,"key")))) declarationFailure("PR11",profile,"tag","key");
            if(!nil(f(model,"format"))&&!formatNames.contains(s(f(model,"format")))) declarationFailure("PR12",profile,"tag","format");
            List<WireValue> sealed=a(f(model,"sealed"));
            if(!uniqueNames(sealed,"tag")||sealed.stream().anyMatch(form->!nil(f(model,"format"))
                    &&!SemanticValues.recognize(bindings.stream().filter(row->f(row,"name").equals(f(model,"format"))).findFirst().map(row->f(row,"rule")).orElse(null),s(f(form,"tag")))))
                declarationFailure("PR13",profile,"tag","sealed");
            if(sealed.stream().anyMatch(form->!uniqueNames(a(f(form,"fields")),"key")
                    ||a(f(form,"fields")).stream().anyMatch(field->s(f(field,"key")).equals(s(f(model,"key")))||wrapperKeys.contains(s(f(field,"key"))))))
                declarationFailure("PR14",profile,"tag","sealed","fields");
            if(sealed.stream().anyMatch(form->a(f(form,"fields")).stream().anyMatch(field->!sealedLeafValid(f(field,"leaf"),domains,wrappers,formatNames))))
                declarationFailure("PR15",profile,"tag","sealed","fields");
        }
        WireValue rules=f(profile,"grapheme_rules");
        if(!nil(rules)&&(badRanges(f(rules,"properties"))||badRanges(f(rules,"extended_pictographic"))||badRanges(f(rules,"indic_conjunct"))))
            declarationFailure("PR16",profile,"grapheme_rules");
        return new CheckedProfile(profile);
    }
    public static CheckedLibrary checkLibrary(WireValue library)throws GenerationFailure {
        CheckedProfile checked=checkProfile(f(library,"profile"));
        List<WireValue> nodes=a(f(library,"nodes"));
        if(!libraryDeclarationValid(library)) declarationFailure("LB01", library, "library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("Product")&&!uniqueNames(a(f(payload(f(node,"shape")),"fields")),"wire_name"))) declarationFailure("LB02",library,"library");
        Set<String> wrapperKeys=a(f(f(library,"profile"),"wrappers")).stream().map(row->s(f(row,"key"))).collect(java.util.stream.Collectors.toSet());
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("Product")&&a(f(payload(f(node,"shape")),"fields")).stream().anyMatch(field->wrapperKeys.contains(s(f(field,"wire_name")))))) declarationFailure("LB03",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&!uniqueValues(a(f(payload(f(node,"shape")),"branches")).stream().map(branch->f(branch,"wire_tag")).toList()))) declarationFailure("LB04",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&otherwiseNotLast(a(f(payload(f(node,"shape")),"branches"))))) declarationFailure("LB05",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&a(f(payload(f(node,"shape")),"branches")).stream().anyMatch(branch->s(f(branch,"wire_tag")).isEmpty()||selectorHasEmptyKey(f(branch,"selector"))))) declarationFailure("LB06",library,"library");
        WireValue profile=f(library,"profile"), tagModel=f(profile,"tag");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&a(f(payload(f(node,"shape")),"branches")).stream().anyMatch(branch->tag(f(branch,"selector")).equals("InternalTag")&&!nil(tagModel)&&!tagAccepted(profile,s(f(branch,"wire_tag")))))) declarationFailure("LB07",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&a(f(payload(f(node,"shape")),"branches")).stream().anyMatch(branch->tag(f(branch,"selector")).equals("InternalTag")&&!sealedTargetAgreement(nodes,tagModel,branch)))) declarationFailure("LB08",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&a(f(payload(f(node,"shape")),"branches")).stream().anyMatch(branch->!selectorValid(profile,f(branch,"selector"))))) declarationFailure("LB09",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("Sealed")&&!sealedNodeValid(nodes,tagModel,node))) declarationFailure("LB10",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&a(f(payload(f(node,"shape")),"branches")).stream().anyMatch(branch->tag(f(branch,"selector")).equals("InternalTag")&&!objectTarget(nodes,s(f(branch,"target")))))) declarationFailure("LB11",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("Product")&&!extrasFormatValid(profile,f(payload(f(node,"shape")),"extras")))) declarationFailure("LB12",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("String")&&!stringSpecValid(profile,payload(f(node,"shape"))))) declarationFailure("LB13",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("Integer")&&!integerSpecValid(profile,payload(f(node,"shape"))))) declarationFailure("LB14",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("Decimal")&&!decimalSpecValid(payload(f(node,"shape"))))) declarationFailure("LB15",library,"library");
        if(nodes.stream().anyMatch(node->Set.of("Array","Bytes").contains(tag(f(node,"shape")))&&!nodeBoundsValid(f(node,"shape")))) declarationFailure("LB16",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&!tagFieldAgreement(nodes,profile,tagModel,node))) declarationFailure("LB17",library,"library");
        if(nodes.stream().anyMatch(node->tag(f(node,"shape")).equals("TaggedUnion")&&!uniqueValues(a(f(payload(f(node,"shape")),"branches")).stream().map(branch->f(branch,"selector")).toList()))) declarationFailure("LB18",library,"library");
        if(nodes.stream().anyMatch(node -> defaultInvalid(profile,node))) declarationFailure("LB19",library,"library");
        return new CheckedLibrary(library,checked);
    }
    private static boolean formatRuleWellFormed(WireValue rule) {
        return switch(tag(rule)) {
            case "AsciiDfa" -> validDfa(payload(rule));
            case "Timestamp" -> n(f(payload(rule),"minimum_year")).compareTo(n(f(payload(rule),"maximum_year")))<=0&&n(f(payload(rule),"maximum_year")).compareTo(java.math.BigInteger.valueOf(9999))<=0;
            case "Identifier" -> {
                WireValue row=payload(rule); BigInteger minimum=n(f(row,"min_length")); WireValue maximum=f(row,"max_length"),exact=f(row,"exact_length");
                yield !s(f(row,"first_alphabet")).isEmpty()&&!s(f(row,"rest_alphabet")).isEmpty()&&SemanticValues.ascii(s(f(row,"first_alphabet")))&&SemanticValues.ascii(s(f(row,"rest_alphabet")))
                        &&(nil(maximum)||minimum.compareTo(n(maximum))<=0)&&(nil(exact)||n(exact).compareTo(minimum)>=0&&(nil(maximum)||n(exact).compareTo(n(maximum))<=0));
            }
            case "Sequence","Choice" -> a(payload(rule)).stream().allMatch(TypeSignatures::formatRuleWellFormed);
            case "Optional","Not" -> formatRuleWellFormed(payload(rule));
            case "Labels" -> !s(f(payload(rule),"separator")).isEmpty()&&formatRuleWellFormed(f(payload(rule),"rule"));
            case "Bounded" -> formatRuleWellFormed(f(payload(rule),"rule"));
            default -> true;
        };
    }
    private static boolean uniqueNames(List<WireValue> rows,String field){
        Set<String> values=new HashSet<>();return rows.stream().allMatch(row->{String value=s(f(row,field));return !value.isEmpty()&&values.add(value);});
    }
    private static boolean uniqueValues(List<WireValue> rows){return new HashSet<>(rows).size()==rows.size();}
    private static boolean validProfileReference(WireValue reference) {
        return !s(f(reference,"identity")).isEmpty()&&!s(f(reference,"revision")).isEmpty()&&!s(f(reference,"content_digest")).isEmpty();
    }
    private static boolean badRanges(WireValue rows){
        return a(rows).stream().anyMatch(row->n(f(row,"last")).compareTo(n(f(row,"first")))<0);
    }
    private static boolean sealedLeafValid(WireValue leaf,List<WireValue> domains,List<WireValue> wrappers,Set<String> formats){
        WireValue spec=payload(leaf);
        if(tag(leaf).equals("Integer"))return nil(f(spec,"domain"))||domains.stream().anyMatch(row->f(row,"name").equals(f(spec,"domain")));
        if(!nil(f(spec,"wrapper"))&&wrappers.stream().noneMatch(row->f(row,"name").equals(f(spec,"wrapper"))&&tag(f(row,"payload")).equals("Text")))return false;
        WireValue use=f(spec,"format");
        if(!nil(use)&&(tag(use).equals("Named")?!formats.contains(s(payload(use))):!formatRuleWellFormed(payload(use))))return false;
        return a(f(spec,"lengths")).stream().allMatch(bound->boundsOrdered(f(bound,"minimum"),f(bound,"maximum")));
    }
    private static boolean libraryDeclarationValid(WireValue library){
        if(!s(f(library,"schema")).equals("ncoh-type-signatures@1")||s(f(library,"identity")).isEmpty()||s(f(library,"revision")).isEmpty()||!digest(f(f(f(library,"profile"),"reference"),"content_digest")))return false;
        if(!uniqueNames(a(f(library,"nodes")),"id")||!uniqueNames(a(f(library,"definitions")),"id")||!uniqueNames(a(f(library,"groups")),"id"))return false;
        Set<String> nodes=a(f(library,"nodes")).stream().map(row->s(f(row,"id"))).collect(java.util.stream.Collectors.toSet());
        for(WireValue source:a(f(library,"sources")))if(!digest(f(source,"content_digest")))return false;
        for(WireValue node:a(f(library,"nodes")))for(String ref:shapeReferences(f(node,"shape")))if(!nodes.contains(ref))return false;
        for(WireValue definition:a(f(library,"definitions")))for(String ref:definitionReferences(f(definition,"shape")))if(!nodes.contains(ref))return false;
        return true;
    }
    private static boolean digest(WireValue value){return value instanceof StringValue&&s(value).matches("[0-9a-f]{64}");}
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
    private static boolean tagAccepted(WireValue profile,String value){
        WireValue model=f(profile,"tag");if(nil(model)||nil(f(model,"format")))return true;
        WireValue binding=a(f(profile,"format_bindings")).stream().filter(row->f(row,"name").equals(f(model,"format"))).findFirst().orElse(null);
        return binding!=null&&SemanticValues.recognize(f(binding,"rule"),value);
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
        if(tag(use).equals("Inline"))return formatRuleWellFormed(payload(use));
        return a(f(profile,"format_bindings")).stream().anyMatch(row->f(row,"name").equals(payload(use)));
    }
    private static boolean stringSpecValid(WireValue profile,WireValue spec){
        if(!nil(f(spec,"wrapper"))&&a(f(profile,"wrappers")).stream().noneMatch(row->f(row,"name").equals(f(spec,"wrapper"))&&tag(f(row,"payload")).equals("Text")))return false;
        WireValue use=f(spec,"format");if(!nil(use)){if(tag(use).equals("Inline")){if(!formatRuleWellFormed(payload(use)))return false;}else if(a(f(profile,"format_bindings")).stream().noneMatch(row->f(row,"name").equals(payload(use))))return false;}
        return a(f(spec,"lengths")).stream().allMatch(bound->boundsOrdered(f(bound,"minimum"),f(bound,"maximum")));
    }
    private static boolean integerSpecValid(WireValue profile,WireValue spec){
        return boundsOrdered(f(spec,"minimum"),f(spec,"maximum"))&&(nil(f(spec,"domain"))||a(f(profile,"integer_domains")).stream().anyMatch(row->f(row,"name").equals(f(spec,"domain"))));
    }
    private static boolean decimalSpecValid(WireValue spec){
        if(nil(f(spec,"minimum"))||nil(f(spec,"maximum")))return true;return f(f(spec,"minimum"),"scale").equals(f(f(spec,"maximum"),"scale"))&&n(f(f(spec,"minimum"),"mantissa")).compareTo(n(f(f(spec,"maximum"),"mantissa")))<=0;
    }
    private static boolean boundsOrdered(WireValue minimum,WireValue maximum){return nil(minimum)||nil(maximum)||n(minimum).compareTo(n(maximum))<=0;}
    private static boolean nodeBoundsValid(WireValue shape){
        WireValue spec=payload(shape);
        return tag(shape).equals("Bytes")?boundsOrdered(f(spec,"minimum"),f(spec,"maximum")):boundsOrdered(f(spec,"min_length"),f(spec,"max_length"));
    }
    private static boolean tagFieldAgreement(List<WireValue> nodes,WireValue profile,WireValue model,WireValue node){
        if(nil(model))return a(f(payload(f(node,"shape")),"branches")).stream().noneMatch(branch->tag(f(branch,"selector")).equals("InternalTag"));
        for(WireValue branch:a(f(payload(f(node,"shape")),"branches")))if(tag(f(branch,"selector")).equals("InternalTag")){
            WireValue target=nodes.stream().filter(row->f(row,"id").equals(f(branch,"target"))).findFirst().orElse(null);if(target==null)continue;
            if(tag(f(target,"shape")).equals("Product")){
                WireValue field=a(f(payload(f(target,"shape")),"fields")).stream().filter(row->f(row,"wire_name").equals(f(model,"key"))).findFirst().orElse(null);
                if(field==null)return false;
                WireValue type=nodes.stream().filter(row->f(row,"id").equals(f(f(field,"slot"),"type_id"))).findFirst().orElse(null);
                if(type==null||!tag(f(type,"shape")).equals("String")||!stringValueValid(profile,s(f(branch,"wire_tag")),payload(f(type,"shape"))))return false;
            }
        }return true;
    }
    private static boolean defaultInvalid(WireValue profile,WireValue node){
        String kind=tag(f(node,"shape"));if(!Set.of("String","Integer").contains(kind))return false;WireValue spec=payload(f(node,"shape"));
        if(kind.equals("String")){List<WireValue> values=new ArrayList<>();if(!nil(f(spec,"const_value")))values.add(f(spec,"const_value"));if(!nil(f(spec,"enum_values")))values.addAll(a(f(spec,"enum_values")));if(!nil(f(spec,"default_value")))values.add(f(spec,"default_value"));return values.stream().anyMatch(value->!stringValueValid(profile,s(value),spec));}
        List<WireValue> values=new ArrayList<>();if(!nil(f(spec,"const_value")))values.add(f(spec,"const_value"));if(!nil(f(spec,"enum_values")))values.addAll(a(f(spec,"enum_values")));if(!nil(f(spec,"default_value")))values.add(f(spec,"default_value"));return values.stream().anyMatch(value->!boundsValue(n(value),f(spec,"minimum"),f(spec,"maximum")));
    }
    private static boolean stringValueValid(WireValue profile,String value,WireValue spec){
        if(!nil(f(spec,"const_value"))&&!s(f(spec,"const_value")).equals(value))return false;
        if(!nil(f(spec,"enum_values"))&&a(f(spec,"enum_values")).stream().noneMatch(candidate->s(candidate).equals(value)))return false;
        WireValue use=f(spec,"format");
        if(!nil(use)){
            WireValue rule=tag(use).equals("Inline")?payload(use):a(f(profile,"format_bindings")).stream()
                    .filter(row->f(row,"name").equals(payload(use))).findFirst().map(row->f(row,"rule")).orElse(null);
            if(!SemanticValues.recognize(rule,value))return false;
        }
        return true;
    }
    private static boolean boundsValue(BigInteger value,WireValue minimum,WireValue maximum){return(nil(minimum)||value.compareTo(n(minimum))>=0)&&(nil(maximum)||value.compareTo(n(maximum))<=0);}
    private static boolean validDfa(WireValue spec) {
        java.math.BigInteger count=n(f(spec,"state_count"));
        if(count.signum()<=0||n(f(spec,"initial_state")).signum()<0||n(f(spec,"initial_state")).compareTo(count)>=0)return false;
        if(a(f(spec,"accepting_states")).stream().anyMatch(state->n(state).signum()<0||n(state).compareTo(count)>=0))return false;
        List<WireValue> transitions=a(f(spec,"transitions"));
        for(int i=0;i<transitions.size();i++){WireValue left=transitions.get(i);java.math.BigInteger from=n(f(left,"from_state")),first=n(f(left,"first")),last=n(f(left,"last")),to=n(f(left,"to_state"));if(from.signum()<0||from.compareTo(count)>=0||to.signum()<0||to.compareTo(count)>=0||first.signum()<0||first.compareTo(last)>0||last.compareTo(java.math.BigInteger.valueOf(127))>0)return false;for(int j=i+1;j<transitions.size();j++){WireValue right=transitions.get(j);if(from.equals(n(f(right,"from_state")))&&first.compareTo(n(f(right,"last")))<=0&&n(f(right,"first")).compareTo(last)<=0)return false;}}
        return true;
    }
    private static WireValue graphemeRows(WireValue rows,boolean property,boolean indic)throws GenerationFailure {
        List<WireValue> result=new ArrayList<>();java.math.BigInteger previous=java.math.BigInteger.valueOf(-1);
        for(WireValue row:a(rows)){
            java.math.BigInteger first=n(f(row,"first")),last=n(f(row,"last"));
            require(first.compareTo(previous)>0&&first.compareTo(last)<=0&&last.compareTo(java.math.BigInteger.valueOf(0x10ffff))<=0&&!(first.intValue()<=0xdfff&&last.intValue()>=0xd800),"$profile.grapheme","sorted disjoint scalar ranges");previous=last;
            List<WireValue> tuple=new ArrayList<>(List.of(num(first),num(last)));
            if(property){String name=tag(f(row,"property"));name=switch(name){case "Cr"->"CR";case "Lf"->"LF";case "Zwj"->"ZWJ";case "RegionalIndicator"->"Regional_Indicator";case "Lv"->"LV";case "Lvt"->"LVT";case "Other"->indic?"None":"Other";default->name;};tuple.add(str(name));}
            result.add(arr(tuple));
        }return arr(result);
    }
    /** Returns exact annotations in their admitted target representation. */
    public static List<WireValue> annotations(CheckedGeneration checked) { return List.copyOf(a(f(f(checked.input,"signatures"),"annotations"))); }
    /** Selects annotations by exact target identity. */
    public static List<WireValue> annotations(CheckedGeneration checked,WireValue target) { return annotations(checked).stream().filter(v->f(v,"target").equals(target)).toList(); }
    /** Returns immutable declarations keyed by their opaque definition identities. */
    public static Map<String,WireValue> declarations(CheckedGeneration checked) { Map<String,WireValue> result=new LinkedHashMap<>();for(WireValue definition:checked.definitions)result.put(s(f(definition,"id")),definition);return Map.copyOf(result); }
    /** Parses exact wire JSON without numeric conversion. */
    public static WireValue parseWire(String text) { return readJson(text); }
}
