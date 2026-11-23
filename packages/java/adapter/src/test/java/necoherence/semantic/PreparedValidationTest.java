// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.lang.ref.Reference;
import java.lang.ref.WeakReference;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import necoherence.composition.SemanticComposition.SlotContract;
import necoherence.composition.SemanticComposition.TypeRef;
import necoherence.semantic.ExactJson.JsonMember;
import necoherence.semantic.ExactJson.JsonNum;
import necoherence.semantic.ExactJson.JsonObj;
import necoherence.semantic.ExactJson.JsonStr;
import necoherence.semantic.ExactJson.JsonValue;
import necoherence.semantic.SemanticTypes.*;
import necoherence.semantic.SemanticValidation.Failed;
import necoherence.semantic.SemanticValidation.Ok;
import necoherence.semantic.SemanticValidation.ValidationUnresolved;
import necoherence.semantic.SemanticValidation.ValueRejected;
import org.junit.jupiter.api.Test;

/** Validation over a prepared value builds no table and computes no meaning obligation, and holds no input after it returns. */
final class PreparedValidationTest {
    private static final ProfileRef PROFILE = new ProfileRef("profile", "1", "0".repeat(64));
    private static final SourceRef SOURCE = new SourceRef("r", "1", "p", "0".repeat(64), "d", Optional.empty());

    private static TypeRef ref(String name) { return new TypeRef(SOURCE, name, List.of()); }

    private static TypeNode node(String name, TypeShape shape) {
        return new TypeNode(ref(name), shape, Optional.empty(), List.of(), List.of());
    }

    private static GraphemeRules graphemeRules() {
        WireValue reference = obj("identity", str("profile"), "revision", str("4"), "content_digest", str("a".repeat(64)));
        WireValue rules = obj("reference", reference,
                "component", obj("unicode_version", str("16"), "uax29_revision", str("45"), "cluster_profile", str("extended")),
                "table_sha256", str("b".repeat(64)), "sources", arr(List.of()),
                "properties", arr(List.of(obj("first", str("0"), "last", str("1"), "property", variant("Other")),
                        obj("first", str("769"), "last", str("769"), "property", variant("Extend")))),
                "extended_pictographic", arr(List.of()), "indic_conjunct", arr(List.of()));
        return GraphemeWire.decode(rules, "$");
    }

    private static VersionedSemanticProfile profile() {
        FormatRule word = new BoundedRule(StringLengthUnit.GRAPHEMES, BigInteger.valueOf(3), new TextRule());
        SealedForm form = new SealedForm("s", List.of(new SealedField("name", true,
                new StringLeaf(new StringSpec(Optional.empty(), List.of(), Optional.empty(), Optional.of("x"), Optional.empty(),
                        List.of(), Optional.empty())))), SealedExtras.REJECT);
        return new VersionedSemanticProfile(PROFILE, List.of(), List.of(
                new IntegerDomainBinding("numbers", PROFILE, new UnboundedDomain(), List.of(IntegerForm.NUMBER))),
                "numbers", new NumberModel(false), Optional.of(graphemeRules()),
                List.of(new FormatBinding("word", PROFILE, word)), Optional.empty(), List.of(),
                Optional.of(new TagModel("$type", Optional.empty(), List.of(form))));
    }

    private static List<String> codes() {
        List<String> codes = new ArrayList<>();
        for (int index = 0; index < 20; index++) codes.add("c" + index);
        return codes;
    }

    private static List<BigInteger> numbers() {
        List<BigInteger> numbers = new ArrayList<>();
        for (int index = 0; index < 20; index++) numbers.add(BigInteger.valueOf(index));
        return numbers;
    }

    private static FieldSpec field(String name, String type) {
        return new FieldSpec(name, new SlotContract(ref(type), true, false), new OccurrenceRef(SOURCE, List.of()));
    }

    private static SemanticGraph graph(int filler, boolean unresolvedFormat) {
        List<TypeNode> nodes = new ArrayList<>();
        nodes.add(node("name", new StringShape(new StringSpec(Optional.of(new InlineFormat(
                new BoundedRule(StringLengthUnit.GRAPHEMES, BigInteger.valueOf(2), new TextRule()))),
                List.of(new LengthBound(StringLengthUnit.GRAPHEMES, Optional.empty(), Optional.of(BigInteger.valueOf(2)))),
                Optional.empty(), Optional.empty(), Optional.empty(), List.of(), Optional.empty()))));
        nodes.add(node("code", new StringShape(new StringSpec(Optional.of(new NamedFormat("word")), List.of(),
                Optional.empty(), Optional.empty(), Optional.of(codes()), List.of(), Optional.empty()))));
        nodes.add(node("number", new IntegerShape(new IntegerSpec(Optional.empty(), Optional.empty(), Optional.empty(),
                Optional.empty(), Optional.of(numbers()), Optional.empty()))));
        nodes.add(node("box", new ProductShape(new ProductSpec(
                List.of(field("name", "name"), field("code", "code"), field("number", "number")), new RejectExtras()))));
        nodes.add(node("sealed", new SealedShape("s", List.of())));
        nodes.add(node("bad", new StringShape(new StringSpec(Optional.of(new NamedFormat("missing")), List.of(),
                Optional.empty(), Optional.empty(), Optional.empty(), List.of(), Optional.empty()))));
        if (unresolvedFormat) nodes.add(node("holder", new ProductShape(new ProductSpec(List.of(field("bad", "bad")), new RejectExtras()))));
        for (int index = 0; index < filler; index++)
            nodes.add(node("filler" + index, new IntegerShape(new IntegerSpec(Optional.empty(), Optional.empty(),
                    Optional.empty(), Optional.empty(), Optional.empty(), Optional.empty()))));
        return new SemanticGraph(profile(), nodes, List.of());
    }

    private static JsonValue box(String name, String code, long number) {
        return new JsonObj(List.of(new JsonMember("name", new JsonStr(name)), new JsonMember("code", new JsonStr(code)),
                new JsonMember("number", new JsonNum(BigInteger.valueOf(number)))));
    }

    private static boolean accepts(Context context, JsonValue value) {
        return SemanticValidation.validateValue(context, ref("box"), value, Optional.empty()) instanceof Ok<?>;
    }

    @Test void validationOnOnePreparedValueAcceptsAndRejects() {
        Context context = new Context(graph(50, false));
        assertTrue(accepts(context, box("ab", "c7", 9)));
        assertEquals(false, accepts(context, box("ab", "zz", 9)));
        assertEquals(false, accepts(context, box("abcd", "c7", 9)));
        assertEquals(false, accepts(context, box("ab", "c7", 99)));
        assertInstanceOf(Ok.class, SemanticValidation.validateSlot(context, new SlotContract(ref("box"), true, false),
                new Present<>(box("ab", "c19", 19))));
        assertInstanceOf(Accepted.class, SemanticValidation.acceptsSlot(context, new SlotContract(ref("box"), true, false),
                new Present<>(box("ab", "c19", 19))));
    }

    @Test void aReferenceWithRemainingObligationsFailsAsUnresolvedAndTheOthersStillValidate() {
        Context context = new Context(graph(0, true));
        SemanticValidation.Except<?> holder = SemanticValidation.validateValue(context, ref("holder"), new JsonObj(List.of()), Optional.empty());
        assertInstanceOf(ValidationUnresolved.class, assertInstanceOf(Failed.class, holder).failure());
        assertInstanceOf(ValueRejected.class, assertInstanceOf(Failed.class,
                SemanticValidation.validateValue(context, ref("box"), box("ab", "zz", 1), Optional.empty())).failure());
    }

    private static Context bytesContext() {
        VersionedSemanticProfile base = profile();
        VersionedSemanticProfile withBytes = new VersionedSemanticProfile(base.reference(), base.sourceRefs(), base.integerDomains(),
                base.defaultIntegerDomain(), base.numbers(), base.graphemeRules(), base.formatBindings(),
                Optional.of(new BytesPolicy(PROFILE, true, BytesAlphabet.STANDARD, true, Optional.empty())), base.wrappers(), base.tag());
        List<TypeNode> nodes = List.of(
                node("blob", new BytesShape(new LengthSpec(Optional.empty(), Optional.empty()))),
                node("body", new RawBodyShape("text")),
                node("pack", new ArrayShape(new ArraySpec(new ElementContract(ref("blob"), false), Optional.empty(), Optional.empty()))));
        return new Context(new SemanticGraph(withBytes, nodes, List.of()));
    }

    private static WireValue reference(String name) { return SemanticGraphWire.typeRefWire(ref(name)); }

    @Test void readingTheBytesOfACheckedValueGivesThem() throws Exception {
        Context context = bytesContext();
        for (String name : List.of("blob", "body")) {
            WireValue value = str("AAEC");
            Checked checked = context.check(reference(name), value);
            Bytes bytes = context.bytes(checked, checked.value());
            assertArrayEquals(new byte[] {0, 1, 2}, bytes.value(), name);
        }
    }

    @Test void readingTheBytesInsideACheckedValueGivesThem() throws Exception {
        Context context = bytesContext();
        ArrayValue pack = new ArrayValue(List.of(str("AAEC"), str("AwQF")));
        Checked checked = context.check(reference("pack"), pack);
        List<byte[]> read = new ArrayList<>();
        for (WireValue item : pack.items()) read.add(context.bytes(checked, item).value());
        assertArrayEquals(new byte[] {3, 4, 5}, read.get(1));
    }

    @Test void aSlotThatIsCheckedOnceGivesItsBytes() throws Exception {
        Context context = bytesContext();
        WireValue value = str("AAEC");
        Checked checked = context.checkSlot(reference("blob"), true, false, new Present<>(value));
        assertArrayEquals(new byte[] {0, 1, 2}, context.bytes(checked, value).value());
    }

    @Test void aCheckedValueIsOnlyBuiltByAValidatingContext() throws Exception {
        Context context = bytesContext();
        assertThrows(ValueRejection.class, () -> context.check(reference("blob"), str("A")));
        assertThrows(ValueRejection.class, () -> context.decodeChecked(reference("blob"), "\"A\""));
        for (var constructor : Checked.class.getDeclaredConstructors())
            assertEquals(false, java.lang.reflect.Modifier.isPublic(constructor.getModifiers()));
        assertEquals(true, java.lang.reflect.Modifier.isFinal(Checked.class.getModifiers()));
        Checked checked = context.check(reference("blob"), str("AAEC"));
        assertThrows(IllegalArgumentException.class, () -> context.bytes(checked, str("AAEC")));
        assertThrows(IllegalArgumentException.class, () -> bytesContext().bytes(checked, checked.value()));
    }

    private static WeakReference<Object> validatedValue(Context context) {
        JsonValue value = box("ab", "c7", 9);
        assertTrue(accepts(context, value));
        assertEquals(false, accepts(context, box("ab", "zz", 9)));
        return new WeakReference<>(value);
    }

    private static List<WeakReference<Object>> validatedGraph() {
        SemanticGraph graph = graph(20, false);
        Context context = new Context(graph);
        JsonValue value = box("ab", "c7", 9);
        assertTrue(accepts(context, value));
        return List.of(new WeakReference<>(graph), new WeakReference<>(context), new WeakReference<>(value),
                new WeakReference<>(graph.nodes().getFirst()));
    }

    private static boolean collected(List<WeakReference<Object>> references) {
        for (int attempt = 0; attempt < 100; attempt++) {
            System.gc();
            if (references.stream().allMatch(reference -> reference.get() == null)) return true;
            try { Thread.sleep(10); } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return false; }
        }
        return false;
    }

    @Test void theGraphAndTheValueAreCollectedOnceTheyAreDropped() {
        assertTrue(collected(validatedGraph()));
    }

    @Test void aValueIsCollectedWhilePreparedValueIsAlive() {
        Context context = new Context(graph(20, false));
        WeakReference<Object> value = validatedValue(context);
        assertTrue(collected(List.of(value)));
        assertNotEquals(null, context.typed());
        assertNull(value.get());
        Reference.reachabilityFence(context);
    }
}
