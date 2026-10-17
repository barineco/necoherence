// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticGeneration.*;
import static necoherence.semantic.SemanticValues.*;
import java.math.BigInteger;
import java.util.List;

public final class DeclarationWireTest {
    private static final WireValue TRUE=new BooleanValue(true),FALSE=new BooleanValue(false);
    private static WireValue canonicalRoundtrip(String descriptor,WireValue value)throws Exception{
        WireValue first=canonical(value,descriptor,"$test");
        WireValue second=canonical(readJson(encodeWire(first)),descriptor,"$test");
        if(!first.equals(second)||!encodeWire(first).equals(encodeWire(second)))throw new AssertionError(descriptor+" roundtrip");
        return first;
    }
    private static void unknownField(String descriptor,WireValue value,String field)throws Exception{
        List<Member> members=new java.util.ArrayList<>(o(value).members());members.add(new Member(field,NIL));
        try{canonical(new ObjectValue(members),descriptor,"$test");throw new AssertionError(descriptor+" accepted "+field);}
        catch(GenerationFailure failure){if(!(failure.wireFailure() instanceof UnknownField unknown)||!unknown.field().equals(field))throw failure;}
    }
    private static void unknownTag(String descriptor,String name)throws Exception{
        try{canonical(variant(name),descriptor,"$test");throw new AssertionError(descriptor+" accepted "+name);}
        catch(GenerationFailure failure){if(!(failure.wireFailure() instanceof UnknownTag unknown)||!unknown.tag().equals(name))throw failure;}
    }
    private static WireValue stringSpec(){return obj("format",NIL,"lengths",arr(List.of()),"wrapper",NIL,"const_value",NIL,"enum_values",NIL,"examples",arr(List.of()),"default_value",NIL);}
    private static WireValue integerSpec(){return obj("domain",str("integer"),"minimum",NIL,"maximum",NIL,"const_value",NIL,"enum_values",NIL,"default_value",NIL);}
    private static void declarations()throws Exception{
        List<WireValue> formats=List.of(
                variant("AsciiDfa",obj("state_count",str("1"),"initial_state",str("0"),"accepting_states",arr(List.of(str("0"))),"transitions",arr(List.of()))),
                variant("Timestamp",obj("allow_second_60",FALSE,"minimum_year",str("0"),"maximum_year",str("9999"),"rejectUtcYearOutsideRange",TRUE)),
                variant("Choice",arr(List.of(variant("Text")))),
                fields("Identifier",obj("first_alphabet",str("a"),"rest_alphabet",str("a"),"exact_length",NIL,"min_length",str("1"),"max_length",str("2"),"forbidden",arr(List.of()))),
                fields("AbsoluteUri",obj("max_bytes",NIL)),fields("LanguageTag",obj("grandfathered",arr(List.of()))),
                variant("Literal",str("x")),variant("Sequence",arr(List.of(variant("Text")))),variant("Optional",variant("Text")),
                fields("Labels",obj("separator",str("."),"min_count",str("1"),"max_count",NIL,"total_max",NIL,"rule",variant("Text"))),
                fields("Bounded",obj("unit",variant("UnicodeScalars"),"maximum",str("2"),"rule",variant("Text"))),
                variant("Text"),variant("Not",variant("Literal",str("x"))));
        for(WireValue format:formats)try{canonicalRoundtrip("FormatRule",format);}catch(Exception failure){throw new AssertionError("format "+format,failure);}
        List<WireValue> shapes=List.of(
                variant("Unknown",variant("Any")),variant("Unknown",variant("OrdinaryObject")),variant("Unit"),
                variant("Boolean",obj("const_value",NIL,"default_value",NIL)),variant("Integer",integerSpec()),
                variant("Decimal",obj("minimum",NIL,"maximum",NIL)),variant("String",stringSpec()),
                variant("Bytes",obj("minimum",NIL,"maximum",NIL)),
                variant("Product",obj("fields",arr(List.of()),"extras",variant("Reject"))),
                variant("Array",obj("item",obj("type_id",str("unit"),"nullable",FALSE),"min_length",NIL,"max_length",NIL)),
                variant("TaggedUnion",obj("branches",arr(List.of(obj("target",str("unit"),"wire_tag",str("unit"),"selector",variant("Kind",variant("Null"))))))),
                fields("Sealed",obj("tag",str("sealed"),"refinements",arr(List.of()))),variant("Never"),
                fields("Alias",obj("target",str("unit"))),fields("RawBody",obj("encoding",str("raw"))),fields("Opaque",obj("type_name",str("opaque"))));
        for(WireValue shape:shapes)canonicalRoundtrip("SignatureShape",shape);
        List<WireValue> conditions=List.of(variant("MissingRequired"),variant("NullNotAllowed"),variant("WrongValueKind",str("string")),variant("ConstMismatch"),variant("EnumMismatch"),variant("BelowMinimum"),variant("AboveMaximum"),variant("IntegerDomain"),variant("StringLength"),variant("ArrayLength"),variant("BytesLength"),variant("Format",str("f")),variant("InvalidBytes"),variant("InvalidWrapper",str("text")),variant("InvalidTag"),variant("ReservedForm"),variant("NoBranchSelected"),variant("KeyFormat",str("key")),variant("Uninhabited"),variant("DuplicateField",str("key")),variant("UnexpectedField",str("key")),variant("InvalidDataModel"),variant("ReferenceCycle"));
        for(WireValue condition:conditions){canonicalRoundtrip("ValueCondition",condition);canonicalRoundtrip("SigValueCondition",condition);}
        WireValue source=obj("repository",str("synthetic"),"revision",str("1"),"path",str("types"),"content_digest",str("a".repeat(64)));
        WireValue diagnostic=obj("type_id",str("unit"),"definition_ref",str("unit"),"origin",obj("source",source,"pointer",arr(List.of())),"value_path",arr(List.of()),"condition",variant("InvalidDataModel"),"observed",str("null"),"reference_trace",arr(List.of()));
        canonicalRoundtrip("SigValueFailure",diagnostic);
    }
    private static void envelopes()throws Exception{
        WireValue library=SemanticLibraryFixture.library();String text=encodeWire(library);
        if(!TypeSignatures.TypeSignatureLibrary.decode(text).encode().equals(text))throw new AssertionError("library identity one");
        if(!TypeSignatures.TypeSignatureLibrary.decode(TypeSignatures.TypeSignatureLibrary.decode(text).encode()).encode().equals(text))throw new AssertionError("library identity two");
        WireValue reference=f(f(library,"profile"),"reference");
        WireValue invalidReference=TypeSignatures.replace(reference,"identity",str(""));
        WireValue invalidProfile=TypeSignatures.replace(f(library,"profile"),"reference",invalidReference);
        WireValue invalidLibrary=TypeSignatures.replace(library,"profile",invalidProfile);
        try{TypeSignatures.TypeSignatureLibrary.decode(encodeWire(invalidLibrary));throw new AssertionError("library decoder accepted PR01");}
        catch(GenerationFailure failure){
            if(!failure.condition().equals("PR01")||!failure.path().equals("$profile")||!failure.observed().equals(invalidReference))throw failure;
        }
        WireValue entries=SemanticLibraryFixture.entries;GenerationBasis basis=TypeSignatures.basis(text,encodeWire(entries));
        if(!GenerationBasis.decode(basis.encode()).encode().equals(basis.encode()))throw new AssertionError("basis roundtrip");
        WireValue envelope=obj("schema",str("ncoh-checked-generation@4"),"basis",basis.value,"signatures",library,"composition",NIL,"entrypoints",entries);
        CheckedGeneration checked=TypeSignatures.admitGeneration(basis,encodeWire(envelope));
        if(!encodeWire(checked.input).equals(encodeWire(envelope)))throw new AssertionError("generation envelope roundtrip");
    }
    private static void oldEntries()throws Exception{
        unknownTag("FormatRule","Cid");unknownTag("SignatureShape","CidLink");unknownTag("SignatureShape","Blob");unknownTag("SignatureShape","Record");unknownTag("FormatRule","UnsupportedFormatRule");
        WireValue string=stringSpec();for(String field:List.of("known_values","min_length","max_length","min_graphemes","max_graphemes","extra"))unknownField("StringSpec",string,field);
        unknownField("SignatureUnion",obj("branches",arr(List.of())),"closed");
        try{canonical(str("01"),"n","$test");throw new AssertionError("noncanonical Nat accepted");}catch(GenerationFailure expected){if(!expected.condition().equals("canonical exact natural"))throw expected;}
        WireValue profile=f(SemanticLibraryFixture.library(),"profile");unknownField("ValueProfile",profile,"representation");
    }
    private static void sampleBounds()throws Exception{
        WireValue bounds=obj("max_expanded_states",str("10000"),"max_binding_candidates",str("100000"),
                "max_type_obligations",str("10000"),"max_branch_nodes",str("100000"),"resource_bounds",NIL,"max_sample_length",str("59"));
        WireValue restored=canonicalRoundtrip("SearchBounds",bounds);
        if(!f(restored,"max_sample_length").equals(str("59")))throw new AssertionError("caller sample bound");
        for(WireValue invalid:List.of(new IntegerValue(BigInteger.valueOf(59)),str("-1"),str("059"))){
            try{canonical(TypeSignatures.replace(bounds,"max_sample_length",invalid),"SearchBounds","$test");throw new AssertionError("invalid sample bound accepted");}
            catch(GenerationFailure expected){}
        }
        WireValue missing=new ObjectValue(o(bounds).members().stream().filter(member->!member.key().equals("max_sample_length")).toList());
        try{canonical(missing,"SearchBounds","$test");throw new AssertionError("missing sample bound accepted");}
        catch(GenerationFailure expected){}
        unknownField("SearchBounds",bounds,"extra");
    }
    public static void main(String[] args)throws Exception{declarations();envelopes();oldEntries();sampleBounds();System.out.println("Java: @4 declaration, diagnostic, basis and sample-bound wire checks passed");}
}
