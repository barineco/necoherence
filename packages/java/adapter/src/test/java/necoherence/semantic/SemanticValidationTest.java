// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

package necoherence.semantic;

import static necoherence.semantic.SemanticValues.*;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import necoherence.composition.SemanticComposition.Field;
import necoherence.composition.SemanticComposition.Index;
import necoherence.composition.SemanticComposition.SlotContract;
import necoherence.composition.SemanticComposition.TypeRef;
import necoherence.composition.SemanticComposition.Variant;
import necoherence.composition.SemanticComposition.VariantAssumption;
import necoherence.composition.SemanticComposition.VariantSelectionUndetermined;
import necoherence.composition.SemanticProjection;
import necoherence.semantic.SemanticTypes.*;
import necoherence.semantic.SemanticValidation.*;
import necoherence.semantic.ExactJson;
import necoherence.semantic.WireJson;
import org.junit.jupiter.api.Test;

final class SemanticValidationTest {
    private static final WireValue SOURCE = obj("repository", str("r"), "revision", str("1"), "path", str("p"),
            "content_digest", str("0".repeat(64)), "document_id", str("d"), "declared_revision", NIL);
    private static final ProfileRef PROFILE = new ProfileRef("profile", "1", "0".repeat(64));

    private static TypeRef ref(String name) { return new TypeRef(SemanticGraphWire.sourceRef(SOURCE, "$"), name, List.of()); }

    private static BigInteger big(long value) { return BigInteger.valueOf(value); }

    private static IntegerSpec integer(Optional<String> domain, Optional<Long> minimum, Optional<Long> maximum,
            Optional<Long> constant, Optional<List<BigInteger>> values) {
        return new IntegerSpec(domain, minimum.map(SemanticValidationTest::big), maximum.map(SemanticValidationTest::big),
                constant.map(SemanticValidationTest::big), values, Optional.empty());
    }

    private static IntegerSpec anyInteger() {
        return integer(Optional.empty(), Optional.empty(), Optional.empty(), Optional.empty(), Optional.empty());
    }

    private static StringSpec text(Optional<FormatUse> format, List<LengthBound> lengths, Optional<String> wrapper,
            Optional<String> constant, Optional<List<String>> values) {
        return new StringSpec(format, lengths, wrapper, constant, values, List.of(), Optional.empty());
    }

    private static StringSpec anyText() {
        return text(Optional.empty(), List.of(), Optional.empty(), Optional.empty(), Optional.empty());
    }

    private static SlotContract slot(String name, boolean required, boolean nullable) {
        return new SlotContract(ref(name), required, nullable);
    }

    private static FieldSpec field(String name, String type, boolean required, boolean nullable) {
        return new FieldSpec(name, slot(type, required, nullable), new OccurrenceRef(SemanticGraphWire.sourceRef(SOURCE, "$"), List.of()));
    }

    private static UnionBranch branch(String target, String tag, BranchSelector selector) {
        return new UnionBranch(ref(target), tag, selector, new OccurrenceRef(SemanticGraphWire.sourceRef(SOURCE, "$"), List.of()));
    }

    private static TypeNode node(String name, TypeShape shape) {
        return new TypeNode(ref(name), shape, Optional.empty(), List.of(), List.of());
    }

    private static VersionedSemanticProfile profile(boolean decimals) { return profile(decimals, true); }

    private static VersionedSemanticProfile profile(boolean decimals, boolean tagged) {
        FormatRule literal = new LiteralRule("a");
        SealedForm form = new SealedForm("s", List.of(
                new SealedField("name", true, new StringLeaf(text(Optional.empty(), List.of(), Optional.empty(),
                        Optional.of("x"), Optional.empty()))),
                new SealedField("count", false, new IntegerLeaf(anyInteger()))), SealedExtras.REJECT);
        SealedForm open = new SealedForm("o", List.of(), SealedExtras.ANY);
        return new VersionedSemanticProfile(PROFILE, List.of(), List.of(
                new IntegerDomainBinding("numbers", PROFILE, new UnboundedDomain(), List.of(IntegerForm.NUMBER)),
                new IntegerDomainBinding("small", PROFILE, new InclusiveDomain(big(0), big(10)),
                        List.of(IntegerForm.NUMBER, IntegerForm.INTEGRAL_DECIMAL, IntegerForm.DECIMAL_STRING))),
                "numbers", new NumberModel(decimals), Optional.empty(),
                List.of(new FormatBinding("letter-a", PROFILE, literal)),
                Optional.of(new BytesPolicy(PROFILE, true, BytesAlphabet.STANDARD, true, Optional.empty())),
                List.of(new Wrapper("w", "$w", new TextPayload(Optional.empty()))),
                tagged ? Optional.of(new TagModel("$type", Optional.empty(), List.of(form, open))) : Optional.empty());
    }

    private static SemanticGraph graph(boolean decimals, TypeNode... nodes) {
        return new SemanticGraph(profile(decimals), List.of(nodes), List.of());
    }

    private static ValueFailure rejected(SemanticGraph graph, String type, WireValue value) {
        Except<ValidatedValue> result = SemanticValidation.validateValue(new SemanticValues.Context(graph), ref(type), WireJson.fromWire(value), Optional.empty());
        return assertInstanceOf(ValueRejected.class, assertInstanceOf(Failed.class, result).failure()).failure();
    }

    private static void accepted(SemanticGraph graph, String type, WireValue value) {
        assertInstanceOf(Ok.class, SemanticValidation.validateValue(new SemanticValues.Context(graph), ref(type), WireJson.fromWire(value), Optional.empty()));
    }

    private static WireValue number(long value) { return num(big(value)); }

    private static WireValue object(Object... members) { return obj(members); }

    @Test void booleanRejectsConstMismatchAndOtherKinds() {
        SemanticGraph graph = graph(true, node("b", new BooleanShape(new BooleanSpec(Optional.of(true), Optional.empty()))));
        accepted(graph, "b", new BooleanValue(true));
        assertEquals(SimpleValueCondition.CONST_MISMATCH, rejected(graph, "b", new BooleanValue(false)).condition());
        assertEquals(new WrongValueKind("boolean"), rejected(graph, "b", str("x")).condition());
    }

    @Test void integerConditionsFollowTheLeanOrder() {
        SemanticGraph graph = graph(true,
                node("const", new IntegerShape(integer(Optional.empty(), Optional.empty(), Optional.empty(), Optional.of(3L), Optional.empty()))),
                node("enum", new IntegerShape(integer(Optional.empty(), Optional.empty(), Optional.empty(), Optional.empty(), Optional.of(List.of(big(1), big(2)))))),
                node("range", new IntegerShape(integer(Optional.empty(), Optional.of(2L), Optional.of(4L), Optional.empty(), Optional.empty()))),
                node("small", new IntegerShape(integer(Optional.of("small"), Optional.empty(), Optional.empty(), Optional.empty(), Optional.empty()))),
                node("missing-domain", new IntegerShape(integer(Optional.of("none"), Optional.empty(), Optional.empty(), Optional.empty(), Optional.empty()))));
        assertEquals(SimpleValueCondition.CONST_MISMATCH, rejected(graph, "const", number(4)).condition());
        assertEquals(SimpleValueCondition.ENUM_MISMATCH, rejected(graph, "enum", number(3)).condition());
        assertEquals(SimpleValueCondition.BELOW_MINIMUM, rejected(graph, "range", number(1)).condition());
        assertEquals(SimpleValueCondition.ABOVE_MAXIMUM, rejected(graph, "range", number(5)).condition());
        assertEquals(new WrongValueKind("integer"), rejected(graph, "range", str("1")).condition());
        assertEquals(SimpleValueCondition.INTEGER_DOMAIN, rejected(graph, "small", number(11)).condition());
        accepted(graph, "small", new DecimalValue("7.0"));
        accepted(graph, "small", str("7"));
        assertEquals(SimpleValueCondition.INTEGER_DOMAIN, rejected(graph, "small", new DecimalValue("1e400")).condition());
        assertInstanceOf(Failed.class, SemanticValidation.validateValue(new SemanticValues.Context(graph), ref("missing-domain"), WireJson.fromWire(number(1)), Optional.empty()));
    }

    @Test void decimalBoundsCompareMathematically() {
        DecimalSpec spec = new DecimalSpec(Optional.of(new DecimalBound(big(15), big(1), true)),
                Optional.of(new DecimalBound(big(30), big(1), false)));
        SemanticGraph graph = graph(true, node("d", new DecimalShape(spec)));
        assertEquals(SimpleValueCondition.BELOW_MINIMUM, rejected(graph, "d", new DecimalValue("1.50")).condition());
        assertEquals(SimpleValueCondition.BELOW_MINIMUM, rejected(graph, "d", new DecimalValue("1.4")).condition());
        accepted(graph, "d", new DecimalValue("2.0"));
        assertEquals(SimpleValueCondition.ABOVE_MAXIMUM, rejected(graph, "d", new DecimalValue("3.01")).condition());
        assertEquals(new WrongValueKind("decimal"), rejected(graph, "d", number(2)).condition());
    }

    @Test void decimalValueEqualToAnInclusiveMinimumAndExclusiveMaximumIsAboveMaximum() {
        DecimalSpec spec = new DecimalSpec(Optional.of(new DecimalBound(big(5), big(0), false)),
                Optional.of(new DecimalBound(big(5), big(0), true)));
        SemanticGraph graph = graph(true, node("d", new DecimalShape(spec)));
        assertEquals(SimpleValueCondition.ABOVE_MAXIMUM, rejected(graph, "d", new DecimalValue("5")).condition());
        assertEquals(SimpleValueCondition.ABOVE_MAXIMUM, rejected(graph, "d", new DecimalValue("5.0")).condition());
    }

    @Test void stringConditionsAndWrappers() {
        SemanticGraph graph = graph(true,
                node("const", new StringShape(text(Optional.empty(), List.of(), Optional.empty(), Optional.of("x"), Optional.empty()))),
                node("enum", new StringShape(text(Optional.empty(), List.of(), Optional.empty(), Optional.empty(), Optional.of(List.of("a", "b"))))),
                node("length", new StringShape(text(Optional.empty(), List.of(new LengthBound(StringLengthUnit.UNICODE_SCALARS,
                        Optional.empty(), Optional.of(big(1)))), Optional.empty(), Optional.empty(), Optional.empty()))),
                node("format", new StringShape(text(Optional.of(new NamedFormat("letter-a")), List.of(), Optional.empty(), Optional.empty(), Optional.empty()))),
                node("wrapped", new StringShape(text(Optional.empty(), List.of(), Optional.of("w"), Optional.empty(), Optional.empty()))));
        assertEquals(SimpleValueCondition.CONST_MISMATCH, rejected(graph, "const", str("y")).condition());
        assertEquals(SimpleValueCondition.ENUM_MISMATCH, rejected(graph, "enum", str("c")).condition());
        assertEquals(SimpleValueCondition.STRING_LENGTH, rejected(graph, "length", str("ab")).condition());
        assertEquals(new FormatCondition("letter-a"), rejected(graph, "format", str("b")).condition());
        assertEquals(new WrongValueKind("string"), rejected(graph, "const", number(1)).condition());
        accepted(graph, "wrapped", object("$w", str("text")));
        assertEquals(new WrongValueKind("string wrapper"), rejected(graph, "wrapped", str("text")).condition());
    }

    @Test void bytesRejectInvalidEncodingsAndLengths() {
        SemanticGraph graph = graph(true,
                node("bytes", new BytesShape(new LengthSpec(Optional.empty(), Optional.of(big(2))))),
                node("raw", new RawBodyShape("base64")));
        accepted(graph, "bytes", str("AAA="));
        assertEquals(SimpleValueCondition.BYTES_LENGTH, rejected(graph, "bytes", str("AAAAAAA=")).condition());
        assertEquals(SimpleValueCondition.INVALID_BYTES, rejected(graph, "bytes", str("%%")).condition());
        assertEquals(SimpleValueCondition.INVALID_BYTES, rejected(graph, "raw", number(1)).condition());
    }

    @Test void productRejectsMissingNullExtraDuplicateAndForeignObjects() {
        ProductSpec closed = new ProductSpec(List.of(field("a", "int", true, false), field("n", "int", false, false)), new RejectExtras());
        ProductSpec open = new ProductSpec(List.of(), new AllowExtras(Optional.of(new NamedFormat("letter-a")),
                new ElementContract(ref("int"), false)));
        SemanticGraph graph = graph(true, node("int", new IntegerShape(anyInteger())),
                node("closed", new ProductShape(closed)), node("open", new ProductShape(open)));
        WireValue minimal = object("a", number(1));
        accepted(graph, "closed", minimal);
        assertEquals(SimpleValueCondition.MISSING_REQUIRED, rejected(graph, "closed", object()).condition());
        assertEquals(SimpleValueCondition.NULL_NOT_ALLOWED, rejected(graph, "closed", object("a", number(1), "n", NIL)).condition());
        assertEquals(new UnexpectedField("z"), rejected(graph, "closed", object("a", number(1), "z", number(1))).condition());
        assertEquals(new DuplicateField("a"), rejected(graph, "closed", object("a", number(1), "a", number(2))).condition());
        assertEquals(new WrongValueKind("plain data object"), rejected(graph, "closed", object("$w", str("x"))).condition());
        assertEquals(new WrongValueKind("object"), rejected(graph, "closed", number(1)).condition());
        assertEquals(new KeyFormat("b"), rejected(graph, "open", object("b", number(1))).condition());
        accepted(graph, "open", object("a", number(1)));
        assertEquals(List.of(new Field("a")), rejected(graph, "closed", object("a", str("x"))).valuePath());
    }

    @Test void arraysCheckLengthAndElements() {
        ArraySpec spec = new ArraySpec(new ElementContract(ref("int"), true), Optional.of(big(1)), Optional.of(big(2)));
        SemanticGraph graph = graph(true, node("int", new IntegerShape(anyInteger())), node("array", new ArrayShape(spec)));
        accepted(graph, "array", arr(List.of(NIL)));
        assertEquals(SimpleValueCondition.ARRAY_LENGTH, rejected(graph, "array", arr(List.of())).condition());
        ValueFailure element = rejected(graph, "array", arr(List.of(number(1), str("x"))));
        assertEquals(List.of(new Index(big(1))), element.valuePath());
        assertEquals(new WrongValueKind("array"), rejected(graph, "array", number(1)).condition());
    }

    @Test void aliasesAndUnionsForwardToTheirTargets() {
        SemanticGraph graph = graph(true, node("int", new IntegerShape(anyInteger())),
                node("alias", new AliasShape(ref("int"), "int")),
                node("union", new TaggedUnionShape(new UnionSpec(List.of(branch("int", "i", new KindSelector(ValueKind.NUMBER)))))));
        accepted(graph, "alias", number(1));
        assertEquals(new WrongValueKind("integer"), rejected(graph, "alias", str("x")).condition());
        accepted(graph, "union", number(1));
        assertEquals(SimpleValueCondition.NO_BRANCH_SELECTED, rejected(graph, "union", str("x")).condition());
    }

    @Test void sealedChecksFormFieldsRefinementsAndExtras() {
        SemanticGraph graph = graph(true,
                node("sealed", new SealedShape("s", List.of(new SealedRefinement("count", new IntegerLeaf(
                        integer(Optional.empty(), Optional.empty(), Optional.of(5L), Optional.empty(), Optional.empty())))))),
                node("other", new SealedShape("o", List.of())));
        WireValue valid = object("$type", str("s"), "name", str("x"));
        accepted(graph, "sealed", valid);
        assertEquals(SimpleValueCondition.INVALID_DATA_MODEL, rejected(graph, "other", valid).condition());
        assertEquals(SimpleValueCondition.CONST_MISMATCH, rejected(graph, "sealed", object("$type", str("s"), "name", str("y"))).condition());
        assertEquals(SimpleValueCondition.MISSING_REQUIRED, rejected(graph, "sealed", object("$type", str("s"))).condition());
        assertEquals(SimpleValueCondition.ABOVE_MAXIMUM, rejected(graph, "sealed", object("$type", str("s"), "name", str("x"), "count", number(9))).condition());
        assertEquals(new UnexpectedField("z"), rejected(graph, "sealed", object("$type", str("s"), "name", str("x"), "z", number(1))).condition());
        accepted(graph, "other", object("$type", str("o"), "extra", number(1)));
        assertEquals(SimpleValueCondition.INVALID_DATA_MODEL, rejected(graph, "other", object("$type", str("o"), "extra", str("\ud800"))).condition());
        assertEquals(new WrongValueKind("sealed object"), rejected(graph, "sealed", number(1)).condition());
        assertEquals(new WrongValueKind("sealed object"), rejected(graph, "sealed", object("a", number(1))).condition());
    }

    @Test void remainingShapesFollowTheirLeanArms() {
        SemanticGraph graph = graph(false, node("never", new NeverShape()), node("any", new UnknownShape(UnknownKind.ANY)),
                node("ordinary", new UnknownShape(UnknownKind.ORDINARY_OBJECT)), node("unit", new UnitShape()),
                node("opaque", new OpaqueShape("t")));
        assertEquals(SimpleValueCondition.INVALID_DATA_MODEL, rejected(graph, "never", NIL).condition());
        accepted(graph, "any", object("a", arr(List.of(number(1), str("x")))));
        assertEquals(SimpleValueCondition.INVALID_DATA_MODEL, rejected(graph, "any", new DecimalValue("1.5")).condition());
        assertEquals(new WrongValueKind("ordinary object"), rejected(graph, "ordinary", number(1)).condition());
        accepted(graph, "ordinary", object("a", number(1)));
        accepted(graph, "unit", NIL);
        assertEquals(new WrongValueKind("unit"), rejected(graph, "unit", number(1)).condition());
        assertInstanceOf(ValidationUnresolved.class, assertInstanceOf(Failed.class,
                SemanticValidation.validateValue(new SemanticValues.Context(graph), ref("opaque"), ExactJson.NIL, Optional.empty())).failure());
    }

    @Test void membershipChecksCyclesFuelAndCertificates() {
        SemanticGraph graph = graph(true, node("a", new AliasShape(ref("b"), "b")), node("b", new AliasShape(ref("a"), "a")),
                node("int", new IntegerShape(anyInteger())),
                node("array", new ArrayShape(new ArraySpec(new ElementContract(ref("int"), false), Optional.empty(), Optional.empty()))));
        Expansion expansion = SemanticValidation.expandValue(new SemanticValues.Context(graph), ref("a"), List.of(), ExactJson.NIL);
        assertInstanceOf(Requirements.class, expansion);
        ValueFailure cycle = rejected(graph, "a", NIL);
        assertEquals(SimpleValueCondition.REFERENCE_CYCLE, cycle.condition());
        assertEquals(List.of(ref("b"), ref("a")), cycle.referenceTrace());
        MembershipResult bounded = SemanticValidation.checkValueFuel(ValidationTables.of(graph), BigInteger.ONE, List.of(), ref("array"), List.of(),
                WireJson.fromWire(arr(List.of(number(1)))), Optional.empty());
        assertInstanceOf(MemberUnresolved.class, bounded);
        WireValue value = arr(List.of(number(1)));
        MemberProof exact = new MemberProof(List.of(new MemberProof(List.of())));
        accepted(graph, "array", value);
        assertEquals(new CertificateMismatch("extra membership children"), assertInstanceOf(Failed.class,
                SemanticValidation.validateValue(new SemanticValues.Context(graph), ref("array"), WireJson.fromWire(value), Optional.of(new MemberProof(List.of(
                        new MemberProof(List.of()), new MemberProof(List.of())))))).failure());
        assertEquals(new CertificateMismatch("missing membership children"), assertInstanceOf(Failed.class,
                SemanticValidation.validateValue(new SemanticValues.Context(graph), ref("array"), WireJson.fromWire(value), Optional.of(new MemberProof(List.of())))).failure());
        assertInstanceOf(Ok.class, SemanticValidation.validateValue(new SemanticValues.Context(graph), ref("array"), WireJson.fromWire(value), Optional.of(exact)));
    }

    @Test void slotsCheckPresenceBeforeValues() {
        SemanticGraph graph = graph(true, node("int", new IntegerShape(anyInteger())));
        assertInstanceOf(Ok.class, SemanticValidation.validateSlot(new SemanticValues.Context(graph), slot("int", false, false), new Absent<>()));
        ValueFailure absent = assertInstanceOf(ValueRejected.class, assertInstanceOf(Failed.class,
                SemanticValidation.validateSlot(new SemanticValues.Context(graph), slot("int", true, false), new Absent<>())).failure()).failure();
        assertEquals(SimpleValueCondition.MISSING_REQUIRED, absent.condition());
        assertEquals(new Absent<WireValue>(), absent.observed());
        assertEquals(SimpleValueCondition.NULL_NOT_ALLOWED, assertInstanceOf(ValueRejected.class, assertInstanceOf(Failed.class,
                SemanticValidation.validateSlot(new SemanticValues.Context(graph), slot("int", true, false), new NullSlot<>())).failure()).failure().condition());
        assertInstanceOf(Accepted.class, SemanticValidation.acceptsSlot(new SemanticValues.Context(graph), slot("int", true, false), new Present<>(WireJson.fromWire(number(1)))));
        assertInstanceOf(Rejected.class, SemanticValidation.acceptsSlot(new SemanticValues.Context(graph), slot("int", true, false), new Present<>(WireJson.fromWire(str("x")))));
        assertInstanceOf(Unresolved.class, SemanticValidation.acceptsSlot(new SemanticValues.Context(graph), slot("missing", true, false), new Present<>(ExactJson.NIL)));
    }

    @Test void languageTagMatchesGrandfatheredEntriesIgnoringCase() {
        FormatRule rule = new LanguageTagRule(List.of("I-Klingon"));
        assertEquals(true, SemanticValidation.formatAcceptsFast(Optional.empty(), rule, "i-klingon"));
        assertEquals(true, SemanticValidation.formatAcceptsFast(Optional.empty(), rule, "en-US"));
        assertEquals(false, SemanticValidation.formatAcceptsFast(Optional.empty(), rule, "i-klingons"));
        assertEquals(false, SemanticValidation.formatAcceptsFast(Optional.empty(), rule, "é"));
    }

    @Test void integralDecimalReadsTheLeanExponentBelowItsLimit() {
        assertEquals(Optional.of(BigInteger.TEN), SemanticValidation.decimalInteger("1e000000001"));
        assertEquals(Optional.of(BigInteger.TEN), SemanticValidation.decimalInteger("1e0000000001"));
        assertEquals(Optional.of(BigInteger.ZERO), SemanticValidation.decimalInteger("0e000000000"));
        assertEquals(Optional.empty(), SemanticValidation.decimalInteger("1e-000000001"));
        assertEquals(Optional.of(BigInteger.TEN.pow(9999)), SemanticValidation.decimalInteger("1e9999"));
        assertEquals(Optional.empty(), SemanticValidation.decimalInteger("1e10000"));
        assertEquals(Optional.empty(), SemanticValidation.decimalInteger("1e1000000000"));
    }

    @Test void decimalIntegerPartsGiveTheLeanNormalFormOfIntegralSpellings() {
        assertEquals(Optional.of(new NormalizedDecimal(0, BigInteger.ZERO, BigInteger.ZERO)), SemanticValidation.decimalIntegerParts("0.00"));
        assertEquals(Optional.of(new NormalizedDecimal(0, BigInteger.ZERO, BigInteger.ZERO)), SemanticValidation.decimalIntegerParts("0"));
        assertEquals(Optional.of(new NormalizedDecimal(1, big(1), big(1))), SemanticValidation.decimalIntegerParts("1.0"));
        assertEquals(Optional.of(new NormalizedDecimal(1, big(15), big(3))), SemanticValidation.decimalIntegerParts("15e1"));
        assertEquals(Optional.of(new NormalizedDecimal(-1, big(12), big(2))), SemanticValidation.decimalIntegerParts("-12"));
        assertEquals(Optional.of(new NormalizedDecimal(1, big(1), big(4))), SemanticValidation.decimalIntegerParts("1000"));
        assertEquals(Optional.of(new NormalizedDecimal(1, big(1), big(10000))), SemanticValidation.decimalIntegerParts("1e9999"));
        assertEquals(Optional.of(BigInteger.valueOf(150)), SemanticValidation.decimalInteger("15e1"));
    }

    @Test void decimalIntegerPartsRejectNonIntegralAndNonLeanSpellings() {
        assertEquals(Optional.empty(), SemanticValidation.decimalIntegerParts("1.50"));
        assertEquals(Optional.empty(), SemanticValidation.decimalIntegerParts(" 1"));
        assertEquals(Optional.empty(), SemanticValidation.decimalIntegerParts("+1"));
        assertEquals(Optional.empty(), SemanticValidation.decimalIntegerParts("1e10000"));
    }

    @Test void dataFailureIsTheFirstInDocumentOrderWithItsPath() {
        ExactJson.JsonValue bad = new ExactJson.JsonStr("\uD800");
        ExactJson.JsonValue value = new ExactJson.JsonArr(List.of(new ExactJson.JsonStr("x"),
                new ExactJson.JsonArr(List.of(new ExactJson.JsonObj(List.of(new ExactJson.JsonMember("k", new ExactJson.JsonStr("x")),
                        new ExactJson.JsonMember("bad", bad))), bad))));
        DataFailure failure = SemanticValidation.dataValueFailure(ValidationTables.of(profile(false)), List.of(), value).orElseThrow();
        assertEquals(List.of(new Index(BigInteger.ONE), new Index(BigInteger.ZERO), new Field("bad")), failure.path());
        assertEquals(SimpleValueCondition.INVALID_DATA_MODEL, failure.condition());
        assertEquals(bad, failure.observed());
    }

    @Test void dataFailureAtTheDeepestLevelKeepsTheWholePath() {
        int depth = 10000;
        ExactJson.JsonValue value = new ExactJson.JsonStr("\uD800");
        for (int level = 0; level < depth; level++) value = new ExactJson.JsonArr(List.of(value));
        DataFailure failure = SemanticValidation.dataValueFailure(ValidationTables.of(profile(false)), List.of(), value).orElseThrow();
        assertEquals(depth, failure.path().size());
        assertEquals(new Index(BigInteger.ZERO), failure.path().get(depth - 1));
        assertEquals(SimpleValueCondition.INVALID_DATA_MODEL, failure.condition());
    }

    @Test void decimalSpellingsAreTheLeanJsonNumbers() {
        assertEquals(Optional.empty(), SemanticValues.parseLeanNumber("x"));
        assertEquals(Optional.empty(), SemanticValues.parseLeanNumber("+1"));
        assertEquals(Optional.empty(), SemanticValues.parseLeanNumber(".5"));
        assertEquals(Optional.empty(), SemanticValues.parseLeanNumber("1."));
        assertEquals(Optional.empty(), SemanticValues.parseLeanNumber("1e18446744073709551617"));
        assertEquals(Optional.empty(), SemanticValues.parseLeanNumber("1e10000"));
        assertEquals(Optional.empty(), SemanticValues.parseLeanNumber("1E+10000"));
        assertEquals(Optional.empty(), SemanticValues.parseLeanNumber("1e-10000"));
        assertEquals(Optional.of(new SemanticValues.DecimalNumber(big(1), big(-9999))), SemanticValues.parseLeanNumber("1e9999"));
        assertEquals(Optional.of(new SemanticValues.DecimalNumber(big(150), big(2))), SemanticValues.parseLeanNumber(" 1.50 "));
    }

    @Test void decimalBoundsCompareExactlyWithinTheExponentLimit() {
        DecimalSpec spec = new DecimalSpec(Optional.of(new DecimalBound(big(1), big(9000), false)),
                Optional.of(new DecimalBound(big(1), big(0), false)));
        SemanticGraph graph = graph(true, node("d", new DecimalShape(spec)));
        accepted(graph, "d", new DecimalValue("1"));
        accepted(graph, "d", new DecimalValue("10e-9001"));
        assertEquals(SimpleValueCondition.ABOVE_MAXIMUM, rejected(graph, "d", new DecimalValue("1e9999")).condition());
        assertEquals(SimpleValueCondition.BELOW_MINIMUM, rejected(graph, "d", new DecimalValue("1e-9999")).condition());
        assertEquals(SimpleValueCondition.INVALID_DATA_MODEL, rejected(graph, "d", new DecimalValue("1e10000")).condition());
        assertEquals(SimpleValueCondition.INVALID_DATA_MODEL, rejected(graph, "d", new DecimalValue("1e-10000")).condition());
    }

    @Test void unboundedIntegralDecimalFollowsTheExponentLimitOfTheReader() {
        VersionedSemanticProfile integral = new VersionedSemanticProfile(PROFILE, List.of(), List.of(
                new IntegerDomainBinding("numbers", PROFILE, new UnboundedDomain(), List.of(IntegerForm.NUMBER, IntegerForm.INTEGRAL_DECIMAL))),
                "numbers", new NumberModel(true), Optional.empty(), List.of(), Optional.empty(), List.of(), Optional.empty());
        SemanticGraph graph = new SemanticGraph(integral, List.of(node("int", new IntegerShape(anyInteger()))), List.of());
        accepted(graph, "int", new DecimalValue("1e9999"));
        assertEquals(new WrongValueKind("integer"), rejected(graph, "int", new DecimalValue("1e10000")).condition());
        assertEquals(Optional.empty(), SemanticValidation.dataValueFailure(ValidationTables.of(integral), List.of(), new ExactJson.JsonDec("1e9999")));
        assertEquals(SimpleValueCondition.INVALID_DATA_MODEL,
                SemanticValidation.dataValueFailure(ValidationTables.of(integral), List.of(), new ExactJson.JsonDec("1e10000")).orElseThrow().condition());
    }

    @Test void timestampYearBoundsHoldAtAnyMagnitude() {
        CalendarRule wide = new CalendarRule(false, big(2000), big(3000000000L), true);
        assertEquals(true, SemanticFormats.accepts(Optional.empty(), new TimestampRule(wide), "2020-01-01T00:00:00+01:00"));
        assertEquals(false, SemanticFormats.accepts(Optional.empty(), new TimestampRule(wide), "2000-01-01T00:00:00+01:00"));
    }

    @Test void percentEncodingAcceptsOnlyAsciiHexDigits() {
        assertEquals(false, SemanticFormats.accepts(Optional.empty(), new AbsoluteUriRule(Optional.empty()), "a:%\u0660\u0660"));
        assertEquals(true, SemanticFormats.accepts(Optional.empty(), new AbsoluteUriRule(Optional.empty()), "a:%7F"));
    }

    @Test void slotCertificatesCarryTheSourceRefsOfTheGraph() {
        SemanticGraph graph = new SemanticGraph(profile(true), List.of(node("int", new IntegerShape(anyInteger()))),
                List.of(SemanticGraphWire.sourceRef(SOURCE, "$")));
        Except<ValidatedSlot> result = SemanticValidation.validateSlot(new SemanticValues.Context(graph), slot("int", true, false), new Present<>(WireJson.fromWire(number(1))));
        assertInstanceOf(Ok.class, result);
        assertEquals(List.of(SemanticGraphWire.sourceRef(SOURCE, "$")), ((Ok<ValidatedSlot>) result).value().certificate().sourceRefs());
    }

    @Test void variantSelectionNeedsTheProfileTag() {
        TypeNode union = node("union", new TaggedUnionShape(new UnionSpec(List.of(branch("target", "b", new KindSelector(ValueKind.STRING))))));
        SemanticGraph graph = new SemanticGraph(profile(true, false), List.of(union, node("target", new IntegerShape(anyInteger()))), List.of());
        SemanticProjection.ProjectionRejection rejection = assertThrows(SemanticProjection.ProjectionRejection.class,
                () -> SemanticProjection.projectSlot(new SemanticValues.Context(graph), slot("union", true, false), List.of(new Variant("b")),
                        List.of(new VariantAssumption(List.of(), "b"))));
        assertEquals(new VariantSelectionUndetermined(List.of(), "b"), rejection.failure());
    }

    @Test void textWithLoneSurrogatesIsRejectedByTheSingleUnicodeCheck() {
        assertEquals(false, ExactJson.unicodeValid("\uD800"));
        assertThrows(WireFailure.WireException.class, () -> requireUnicode("\uD800"));
    }

    @Test void scaledPowersOfTenAreBoundedByTheIntegerBitLength() {
        assertEquals(Optional.of(big(1000)), SemanticValues.scaleByTenPower(big(1), big(3)));
        assertEquals(Optional.of(big(7)), SemanticValues.scaleByTenPower(big(7), big(0)));
        assertEquals(Optional.empty(), SemanticValues.scaleByTenPower(big(1), big(536870912)));
        assertEquals(Optional.empty(), SemanticValues.scaleByTenPower(big(1), BigInteger.ONE.shiftLeft(40)));
    }

    @Test void decimalBoundsCompareDigitStringsOfDifferentLengths() {
        DecimalSpec spec = new DecimalSpec(Optional.of(new DecimalBound(big(125), big(2), false)), Optional.empty());
        SemanticGraph graph = graph(true, node("d", new DecimalShape(spec)));
        accepted(graph, "d", new DecimalValue("1.3"));
        accepted(graph, "d", new DecimalValue("1.25"));
        assertEquals(SimpleValueCondition.BELOW_MINIMUM, rejected(graph, "d", new DecimalValue("1.249")).condition());
    }

    @Test void objectMembersAreCheckedInTheKeyOrder() {
        SemanticGraph graph = graph(false, node("ordinary", new UnknownShape(UnknownKind.ORDINARY_OBJECT)));
        ValueFailure failure = rejected(graph, "ordinary", SemanticGeneration.readJson("{\"b\":1.5,\"a\":2.5}"));
        assertEquals(List.of(new Field("a")), failure.valuePath());
    }
}
