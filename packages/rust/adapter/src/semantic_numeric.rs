// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use std::cmp::Ordering;

use num_bigint::{BigInt, BigUint, Sign};
use num_traits::Zero;

use crate::exact_json_view::JsonValueView;
use crate::semantic_types::{
    DecimalBound, DecimalSpec, IntegerDomain, IntegerDomainBinding, IntegerForm, IntegerSpec,
    JsonValue, ValueCondition, VersionedSemanticProfile,
};
use crate::semantic_validation::{wrong_kind, ConditionView};

mod decimal;

use decimal::{sum_sign, DecimalToken, Exponent, Term, WhitespacePolicy};

fn direct(condition: ValueCondition) -> Option<ConditionView<'static>> {
    Some(ConditionView::Direct(condition))
}

struct Bound<'g> {
    mantissa: &'g BigInt,
    negative: bool,
    zero: bool,
    digits: String,
    scale: String,
}

impl<'g> Bound<'g> {
    fn integer(mantissa: &'g BigInt) -> Self {
        Self::new(mantissa, "0".to_owned())
    }

    fn decimal(bound: &'g DecimalBound) -> Self {
        Self::new(&bound.mantissa, bound.scale.to_string())
    }

    fn new(mantissa: &'g BigInt, scale: String) -> Self {
        Self {
            mantissa,
            negative: mantissa.sign() == Sign::Minus,
            zero: mantissa.is_zero(),
            digits: mantissa.magnitude().to_string(),
            scale,
        }
    }
}

fn compare_integer(value: &BigInt, bound: &Bound<'_>) -> Ordering {
    value.cmp(bound.mantissa)
}

fn digit_at(token: DecimalToken<'_>, index: usize) -> u8 {
    let whole = token.whole_digits();
    match whole.get(index) {
        Some(byte) => *byte,
        None => token
            .fraction_digits()
            .get(index - whole.len())
            .copied()
            .unwrap_or(b'0'),
    }
}

fn compare_aligned(token: DecimalToken<'_>, bound_digits: &[u8], significant: usize) -> Ordering {
    let lead = token
        .whole_digits()
        .iter()
        .chain(token.fraction_digits())
        .take_while(|byte| **byte == b'0')
        .count();
    let width = significant.max(bound_digits.len());
    for index in 0..width {
        let left = digit_at(token, lead + index);
        let right = bound_digits.get(index).copied().unwrap_or(b'0');
        match left.cmp(&right) {
            Ordering::Equal => {}
            other => return other,
        }
    }
    Ordering::Equal
}

fn compare_magnitude(token: DecimalToken<'_>, bound: &Bound<'_>) -> Ordering {
    let significant = token.significant_digits();
    let order = sum_sign([
        token.exponent_term(),
        Term::Digits {
            negative: false,
            digits: bound.scale.as_bytes(),
        },
        Term::Magnitude {
            negative: false,
            value: significant,
        },
        Term::Magnitude {
            negative: true,
            value: token.fraction_digits().len(),
        },
        Term::Magnitude {
            negative: true,
            value: bound.digits.len(),
        },
    ]);
    match order {
        Ordering::Equal => compare_aligned(token, bound.digits.as_bytes(), significant),
        other => other,
    }
}

fn compare_token(token: DecimalToken<'_>, bound: &Bound<'_>) -> Ordering {
    match (token.is_zero(), bound.zero) {
        (true, true) => Ordering::Equal,
        (true, false) => {
            if bound.negative {
                Ordering::Greater
            } else {
                Ordering::Less
            }
        }
        (false, true) => {
            if token.is_negative() {
                Ordering::Less
            } else {
                Ordering::Greater
            }
        }
        (false, false) if token.is_negative() != bound.negative => {
            if token.is_negative() {
                Ordering::Less
            } else {
                Ordering::Greater
            }
        }
        (false, false) => {
            let magnitude = compare_magnitude(token, bound);
            if token.is_negative() {
                magnitude.reverse()
            } else {
                magnitude
            }
        }
    }
}

fn pow10(shift: &BigUint) -> BigUint {
    let bits = shift.bits();
    let mut result = BigUint::from(1u8);
    let mut base = BigUint::from(10u8);
    for bit in 0..bits {
        if shift.bit(bit) {
            result *= &base;
        }
        if bit + 1 < bits {
            base = &base * &base;
        }
    }
    result
}

#[derive(Clone, Copy)]
enum Raw<'a> {
    Num(&'a BigInt),
    Dec(&'a str),
    Str(&'a str),
}

impl<'a> Raw<'a> {
    fn of_view(value: JsonValueView<'a>) -> Option<Self> {
        if let Some(integer) = value.as_integer() {
            Some(Raw::Num(integer))
        } else if let Some(text) = value.as_decimal_text() {
            Some(Raw::Dec(text))
        } else {
            value.as_str().map(Raw::Str)
        }
    }

    fn of_json(value: &'a JsonValue) -> Option<Self> {
        match value {
            JsonValue::Num(integer) => Some(Raw::Num(integer)),
            JsonValue::Dec(text) => Some(Raw::Dec(text.as_str())),
            JsonValue::Str(text) => Some(Raw::Str(text.as_str())),
            _ => None,
        }
    }
}

enum Integral<'a> {
    Native(&'a BigInt),
    Token(DecimalToken<'a>),
}

fn read_integral<'a>(binding: &IntegerDomainBinding, raw: Raw<'a>) -> Option<Integral<'a>> {
    match raw {
        Raw::Num(integer) if binding.forms.contains(&IntegerForm::Number) => {
            Some(Integral::Native(integer))
        }
        Raw::Dec(text) if binding.forms.contains(&IntegerForm::IntegralDecimal) => {
            DecimalToken::lex(text, WhitespacePolicy::NoWhitespace).map(Integral::Token)
        }
        Raw::Str(text) if binding.forms.contains(&IntegerForm::DecimalString) => {
            DecimalToken::lex(text, WhitespacePolicy::NoWhitespace).map(Integral::Token)
        }
        _ => None,
    }
}

fn owned_integer(token: DecimalToken<'_>) -> Option<BigInt> {
    if !token.parser_accepts() || !token.is_integral() {
        return None;
    }
    if token.is_zero() {
        return Some(BigInt::zero());
    }
    let trailing = token.trailing_zeros();
    let fraction = token.fraction_digits().len();
    let kept = token.whole_digits().len() + fraction - trailing;
    let digits: Vec<u8> = token
        .whole_digits()
        .iter()
        .chain(token.fraction_digits())
        .copied()
        .take(kept)
        .collect();
    let coefficient = BigUint::parse_bytes(&digits, 10)?;
    let exponent = match token.exponent() {
        Exponent::Omitted => BigInt::zero(),
        Exponent::Nonnegative(digits) => BigInt::parse_bytes(digits, 10)?,
        Exponent::Negative(digits) => -BigInt::parse_bytes(digits, 10)?,
    };
    let shift = exponent + BigInt::from(trailing) - BigInt::from(fraction);
    let magnitude = coefficient * pow10(&shift.to_biguint()?);
    let sign = if token.is_negative() {
        Sign::Minus
    } else {
        Sign::Plus
    };
    Some(BigInt::from_biguint(sign, magnitude))
}

pub(crate) fn parse_integer(binding: &IntegerDomainBinding, value: &JsonValue) -> Option<BigInt> {
    match read_integral(binding, Raw::of_json(value)?)? {
        Integral::Native(integer) => Some(integer.clone()),
        Integral::Token(token) => owned_integer(token),
    }
}

pub(crate) struct PreparedInteger<'g> {
    binding: Option<&'g IntegerDomainBinding>,
    range: Option<(Bound<'g>, Bound<'g>)>,
    limit: usize,
    const_value: Option<Bound<'g>>,
    enum_values: Option<Vec<Bound<'g>>>,
    minimum: Option<Bound<'g>>,
    maximum: Option<Bound<'g>>,
}

impl<'g> PreparedInteger<'g> {
    pub(crate) fn new(
        binding: Option<&'g IntegerDomainBinding>,
        spec: Option<&'g IntegerSpec>,
    ) -> Self {
        let range = match binding.map(|binding| &binding.range) {
            Some(IntegerDomain::Inclusive { minimum, maximum }) => {
                Some((Bound::integer(minimum), Bound::integer(maximum)))
            }
            Some(IntegerDomain::Unbounded) | None => None,
        };
        let limit = range.as_ref().map_or(0, |(minimum, maximum)| {
            minimum.digits.len().max(maximum.digits.len())
        });
        Self {
            binding,
            range,
            limit,
            const_value: spec
                .and_then(|spec| spec.const_value.as_ref())
                .map(Bound::integer),
            enum_values: spec
                .and_then(|spec| spec.enum_values.as_ref())
                .map(|values| values.iter().map(Bound::integer).collect()),
            minimum: spec
                .and_then(|spec| spec.minimum.as_ref())
                .map(Bound::integer),
            maximum: spec
                .and_then(|spec| spec.maximum.as_ref())
                .map(Bound::integer),
        }
    }

    fn check_bounds(
        &self,
        compare: impl Fn(&Bound<'_>) -> Ordering,
    ) -> Option<ConditionView<'static>> {
        if let Some((minimum, maximum)) = &self.range {
            if compare(minimum).is_lt() || compare(maximum).is_gt() {
                return direct(ValueCondition::IntegerDomain);
            }
        }
        if let Some(constant) = &self.const_value {
            if !compare(constant).is_eq() {
                return direct(ValueCondition::ConstMismatch);
            }
        }
        if let Some(values) = &self.enum_values {
            if !values.iter().any(|value| compare(value).is_eq()) {
                return direct(ValueCondition::EnumMismatch);
            }
        }
        if let Some(minimum) = &self.minimum {
            if compare(minimum).is_lt() {
                return direct(ValueCondition::BelowMinimum);
            }
        }
        if let Some(maximum) = &self.maximum {
            if compare(maximum).is_gt() {
                return direct(ValueCondition::AboveMaximum);
            }
        }
        None
    }

    fn check_token(&self, token: DecimalToken<'_>) -> Option<ConditionView<'static>> {
        if self.range.is_some() && token.exceeds_range_digits(self.limit) {
            return direct(ValueCondition::IntegerDomain);
        }
        if !token.parser_accepts() || !token.is_integral() {
            return Some(wrong_kind("integer"));
        }
        self.check_bounds(|bound| compare_token(token, bound))
    }

    fn check_integral(&self, integral: Integral<'_>) -> Option<ConditionView<'static>> {
        match integral {
            Integral::Native(integer) => self.check_bounds(|bound| compare_integer(integer, bound)),
            Integral::Token(token) => self.check_token(token),
        }
    }

    fn check_raw(&self, raw: Raw<'_>) -> Option<ConditionView<'static>> {
        let Some(binding) = self.binding else {
            return direct(ValueCondition::IntegerDomain);
        };
        match read_integral(binding, raw) {
            Some(integral) => self.check_integral(integral),
            None => Some(wrong_kind("integer")),
        }
    }

    pub(crate) fn check(&self, value: JsonValueView<'_>) -> Option<ConditionView<'static>> {
        match Raw::of_view(value) {
            Some(raw) => self.check_raw(raw),
            None if self.binding.is_none() => direct(ValueCondition::IntegerDomain),
            None => Some(wrong_kind("integer")),
        }
    }
}

pub(crate) struct PreparedDecimal<'g> {
    minimum: Option<(Bound<'g>, bool)>,
    maximum: Option<(Bound<'g>, bool)>,
}

impl<'g> PreparedDecimal<'g> {
    pub(crate) fn new(spec: &'g DecimalSpec) -> Self {
        Self {
            minimum: spec
                .minimum
                .as_ref()
                .map(|bound| (Bound::decimal(bound), bound.exclusive)),
            maximum: spec
                .maximum
                .as_ref()
                .map(|bound| (Bound::decimal(bound), bound.exclusive)),
        }
    }

    pub(crate) fn check(&self, text: &str) -> Option<ConditionView<'static>> {
        let Some(token) = DecimalToken::lex(text, WhitespacePolicy::JsonWhitespace) else {
            return direct(ValueCondition::InvalidDataModel);
        };
        if !token.parser_accepts() {
            return direct(ValueCondition::InvalidDataModel);
        }
        if let Some((minimum, exclusive)) = &self.minimum {
            let order = compare_token(token, minimum);
            if order.is_lt() || (order.is_eq() && *exclusive) {
                return direct(ValueCondition::BelowMinimum);
            }
        }
        if let Some((maximum, exclusive)) = &self.maximum {
            let order = compare_token(token, maximum);
            if order.is_gt() || (order.is_eq() && *exclusive) {
                return direct(ValueCondition::AboveMaximum);
            }
        }
        None
    }
}

pub(crate) struct PreparedDataNumeric<'g> {
    integer: PreparedInteger<'g>,
    decimals: bool,
}

impl<'g> PreparedDataNumeric<'g> {
    pub(crate) fn new(profile: &'g VersionedSemanticProfile) -> Self {
        Self {
            integer: PreparedInteger::new(profile.integer_domain(None), None),
            decimals: profile.numbers.decimals,
        }
    }

    pub(crate) fn check_number(&self, value: &BigInt) -> Option<ConditionView<'static>> {
        self.integer
            .check_raw(Raw::Num(value))
            .map(|_| ConditionView::Direct(ValueCondition::IntegerDomain))
    }

    pub(crate) fn check_decimal(&self, text: &str) -> Option<ConditionView<'static>> {
        let Some(outer) = DecimalToken::lex(text, WhitespacePolicy::JsonWhitespace) else {
            return direct(ValueCondition::InvalidDataModel);
        };
        if !outer.parser_accepts() {
            return direct(ValueCondition::InvalidDataModel);
        }
        match self.integer.check_raw(Raw::Dec(text)) {
            None => None,
            Some(ConditionView::Direct(ValueCondition::IntegerDomain)) => {
                direct(ValueCondition::IntegerDomain)
            }
            Some(_) if self.decimals => None,
            Some(_) => direct(ValueCondition::InvalidDataModel),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn order(text: &str, bound: &Bound<'_>) -> Option<Ordering> {
        DecimalToken::lex(text, WhitespacePolicy::NoWhitespace)
            .map(|token| compare_token(token, bound))
    }

    fn scaled(mantissa: &BigInt, scale: u32) -> Bound<'_> {
        Bound::new(mantissa, scale.to_string())
    }

    #[test]
    fn decimal_bound_scale_orders_equal_and_neighbouring_values() {
        let fifteen = BigInt::from(15);
        let b = scaled(&fifteen, 1);
        assert_eq!(order("1.5", &b), Some(Ordering::Equal));
        assert_eq!(order("1.50", &b), Some(Ordering::Equal));
        assert_eq!(order("15e-1", &b), Some(Ordering::Equal));
        assert_eq!(order("1.49", &b), Some(Ordering::Less));
        assert_eq!(order("1.51", &b), Some(Ordering::Greater));
        assert_eq!(order("-1.5", &b), Some(Ordering::Less));
    }

    #[test]
    fn exponent_decides_magnitude_before_digits() {
        let ninety_nine = BigInt::from(99);
        let hundred = BigInt::from(100);
        assert_eq!(order("99", &Bound::integer(&hundred)), Some(Ordering::Less));
        assert_eq!(
            order("100", &Bound::integer(&ninety_nine)),
            Some(Ordering::Greater)
        );
        assert_eq!(
            order("0.99e2", &Bound::integer(&ninety_nine)),
            Some(Ordering::Equal)
        );
    }

    #[test]
    fn huge_exponents_are_ordered_without_powers() {
        let one = BigInt::from(1);
        let thousand = BigInt::from(1000);
        let negative_one = BigInt::from(-1);
        assert_eq!(
            order("1e1000000000000", &Bound::integer(&thousand)),
            Some(Ordering::Greater)
        );
        assert_eq!(
            order("-1e1000000000000", &Bound::integer(&negative_one)),
            Some(Ordering::Less)
        );
        assert_eq!(
            order("1e-1000000000000", &Bound::integer(&one)),
            Some(Ordering::Less)
        );
    }

    #[test]
    fn zero_bound_and_zero_value_follow_the_sign_rules() {
        let zero = BigInt::from(0);
        let one = BigInt::from(1);
        let negative_one = BigInt::from(-1);
        assert_eq!(order("0.0", &Bound::integer(&zero)), Some(Ordering::Equal));
        assert_eq!(order("-0e5", &Bound::integer(&zero)), Some(Ordering::Equal));
        assert_eq!(order("0", &Bound::integer(&one)), Some(Ordering::Less));
        assert_eq!(
            order("0", &Bound::integer(&negative_one)),
            Some(Ordering::Greater)
        );
        assert_eq!(order("-3", &Bound::integer(&zero)), Some(Ordering::Less));
    }

    #[test]
    fn data_decimal_without_default_domain_is_integer_domain_under_both_policies() {
        for decimals in [true, false] {
            let data = PreparedDataNumeric {
                integer: PreparedInteger::new(None, None),
                decimals,
            };
            assert!(matches!(
                data.check_decimal("1.5"),
                Some(ConditionView::Direct(ValueCondition::IntegerDomain))
            ));
            assert!(matches!(
                data.check_decimal(" 1.5 "),
                Some(ConditionView::Direct(ValueCondition::IntegerDomain))
            ));
            assert!(matches!(
                data.check_decimal(" 1.5x"),
                Some(ConditionView::Direct(ValueCondition::InvalidDataModel))
            ));
        }
    }

    fn binding(forms: &[IntegerForm]) -> IntegerDomainBinding {
        IntegerDomainBinding {
            name: "integer".into(),
            reference: crate::semantic_types::ProfileRef {
                identity: "p".into(),
                revision: "1".into(),
                content_digest: "d".into(),
            },
            range: IntegerDomain::Unbounded,
            forms: forms.to_vec(),
        }
    }

    #[test]
    fn owned_projection_reads_each_form_and_its_lean_integer_contract() {
        let all = binding(&[
            IntegerForm::Number,
            IntegerForm::IntegralDecimal,
            IntegerForm::DecimalString,
        ]);
        assert_eq!(
            parse_integer(&all, &JsonValue::Num(BigInt::from(5))),
            Some(BigInt::from(5))
        );
        let dec = |text: &str| parse_integer(&all, &JsonValue::Dec(text.into()));
        assert_eq!(dec("120.0e-1"), Some(BigInt::from(12)));
        assert_eq!(dec("1e3"), Some(BigInt::from(1000)));
        assert_eq!(dec("-2.5e1"), Some(BigInt::from(-25)));
        assert_eq!(
            dec("1200000000000000000000000e-22"),
            Some(BigInt::from(120))
        );
        assert_eq!(dec("-0.0"), Some(BigInt::zero()));
        assert_eq!(dec("0e-99999999999999999999"), None);
        assert_eq!(dec("1.5"), None);
        assert_eq!(dec("1e-1"), None);
        assert_eq!(dec("+1"), None);
        assert_eq!(dec("01"), None);
        assert_eq!(dec(" 1"), None);
        assert_eq!(dec("0e9999"), Some(BigInt::zero()));
        assert_eq!(dec("0e10000"), None);
        assert_eq!(dec("1e10000"), None);
        assert_eq!(dec("1e-10000"), None);
        let string = |text: &str| parse_integer(&all, &JsonValue::Str(text.into()));
        assert_eq!(string("-42"), Some(BigInt::from(-42)));
        assert_eq!(string("1.0e1"), Some(BigInt::from(10)));
        assert_eq!(string("+5"), None);
        assert_eq!(string("007"), None);
    }

    #[test]
    fn owned_projection_requires_the_matching_form() {
        let number_only = binding(&[IntegerForm::Number]);
        assert_eq!(
            parse_integer(&number_only, &JsonValue::Dec("1".into())),
            None
        );
        assert_eq!(
            parse_integer(&number_only, &JsonValue::Str("1".into())),
            None
        );
        let decimal_only = binding(&[IntegerForm::IntegralDecimal]);
        assert_eq!(
            parse_integer(&decimal_only, &JsonValue::Num(BigInt::from(1))),
            None
        );
        assert_eq!(
            parse_integer(&decimal_only, &JsonValue::Str("1".into())),
            None
        );
    }

    #[test]
    fn power_of_ten_is_built_by_squaring() {
        assert_eq!(pow10(&BigUint::from(0u8)), BigUint::from(1u8));
        assert_eq!(pow10(&BigUint::from(1u8)), BigUint::from(10u8));
        assert_eq!(
            pow10(&BigUint::from(13u8)),
            BigUint::from(10_000_000_000_000u64)
        );
    }
}
