// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::exact_json::exponent_digits_reach_limit;
use std::cmp::Ordering;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum WhitespacePolicy {
    JsonWhitespace,
    NoWhitespace,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Exponent<'a> {
    Omitted,
    Nonnegative(&'a [u8]),
    Negative(&'a [u8]),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct DecimalToken<'a> {
    negative: bool,
    whole: &'a [u8],
    fraction: &'a [u8],
    exponent: Exponent<'a>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Term<'a> {
    Zero,
    Digits { negative: bool, digits: &'a [u8] },
    Magnitude { negative: bool, value: usize },
}

pub(crate) fn sum_sign(mut terms: [Term<'_>; 5]) -> Ordering {
    let mut carry: i16 = 0;
    let mut lower_nonzero = false;
    loop {
        let mut active = false;
        let mut q = carry;
        for term in &mut terms {
            match term {
                Term::Zero => {}
                Term::Digits { negative, digits } => {
                    let slice: &[u8] = digits;
                    if let Some((last, prefix)) = slice.split_last() {
                        active = true;
                        let digit = i16::from(*last - b'0');
                        q += if *negative { -digit } else { digit };
                        *digits = prefix;
                    }
                }
                Term::Magnitude { negative, value } => {
                    if *value != 0 {
                        active = true;
                        let digit = (*value % 10) as i16;
                        q += if *negative { -digit } else { digit };
                        *value /= 10;
                    }
                }
            }
        }
        if !active {
            break;
        }
        carry = q.div_euclid(10);
        lower_nonzero |= q.rem_euclid(10) != 0;
    }
    match carry.cmp(&0) {
        Ordering::Greater => Ordering::Greater,
        Ordering::Less => Ordering::Less,
        Ordering::Equal if lower_nonzero => Ordering::Greater,
        Ordering::Equal => Ordering::Equal,
    }
}

fn is_json_whitespace(byte: u8) -> bool {
    matches!(byte, 0x09 | 0x0A | 0x0D | 0x20)
}

fn json_digit(byte: u8) -> bool {
    byte.is_ascii_digit()
}
fn json_whole_number(whole: &[u8]) -> bool {
    match whole.split_first() {
        None => false,
        Some((b'0', rest)) => rest.is_empty(),
        Some((first, rest)) => {
            (b'1'..=b'9').contains(first) && rest.iter().all(|byte| json_digit(*byte))
        }
    }
}
fn skip_digits(body: &[u8], mut index: usize) -> usize {
    while body.get(index).is_some_and(|byte| json_digit(*byte)) {
        index += 1;
    }
    index
}

impl<'a> DecimalToken<'a> {
    pub(crate) fn lex(text: &'a str, policy: WhitespacePolicy) -> Option<Self> {
        let bytes = text.as_bytes();
        let (start, end) = match policy {
            WhitespacePolicy::JsonWhitespace => {
                let start = bytes
                    .iter()
                    .position(|byte| !is_json_whitespace(*byte))
                    .unwrap_or(bytes.len());
                let end = bytes
                    .iter()
                    .rposition(|byte| !is_json_whitespace(*byte))
                    .map_or(start, |last| last + 1);
                (start, end)
            }
            WhitespacePolicy::NoWhitespace => (0, bytes.len()),
        };
        let body: &'a [u8] = bytes.get(start..end)?;
        let mut index = 0usize;
        let negative = body.first() == Some(&b'-');
        if negative {
            index = 1;
        }
        let whole_start = index;
        match body.get(index).copied() {
            Some(b'0') => index += 1,
            Some(b'1'..=b'9') => index = skip_digits(body, index),
            _ => return None,
        }
        let whole = body.get(whole_start..index)?;
        if !json_whole_number(whole) {
            return None;
        }
        let mut fraction: &'a [u8] = &[];
        if body.get(index) == Some(&b'.') {
            index += 1;
            let fraction_start = index;
            index = skip_digits(body, index);
            if index == fraction_start {
                return None;
            }
            fraction = body.get(fraction_start..index)?;
        }
        let exponent = if matches!(body.get(index), Some(b'e' | b'E')) {
            index += 1;
            let negative_exponent = match body.get(index).copied() {
                Some(b'+') => {
                    index += 1;
                    false
                }
                Some(b'-') => {
                    index += 1;
                    true
                }
                _ => false,
            };
            let exponent_start = index;
            index = skip_digits(body, index);
            if index == exponent_start {
                return None;
            }
            let digits = body.get(exponent_start..index)?;
            if negative_exponent {
                Exponent::Negative(digits)
            } else {
                Exponent::Nonnegative(digits)
            }
        } else {
            Exponent::Omitted
        };
        if index != body.len() {
            return None;
        }
        Some(Self {
            negative,
            whole,
            fraction,
            exponent,
        })
    }

    pub(crate) fn exponent(self) -> Exponent<'a> {
        self.exponent
    }

    pub(crate) fn is_negative(self) -> bool {
        self.negative
    }

    pub(crate) fn whole_digits(self) -> &'a [u8] {
        self.whole
    }

    pub(crate) fn fraction_digits(self) -> &'a [u8] {
        self.fraction
    }

    pub(crate) fn coefficient_digits(self) -> impl DoubleEndedIterator<Item = u8> + 'a {
        self.whole
            .iter()
            .chain(self.fraction.iter())
            .map(|byte| *byte - b'0')
    }

    pub(crate) fn is_zero(self) -> bool {
        self.coefficient_digits().all(|digit| digit == 0)
    }

    pub(crate) fn significant_digits(self) -> usize {
        if self.is_zero() {
            return 0;
        }
        let leading = self
            .coefficient_digits()
            .take_while(|digit| *digit == 0)
            .count();
        self.whole.len() + self.fraction.len() - leading
    }

    pub(crate) fn trailing_zeros(self) -> usize {
        self.coefficient_digits()
            .rev()
            .take_while(|digit| *digit == 0)
            .count()
    }

    pub(crate) fn exponent_term(self) -> Term<'a> {
        match self.exponent {
            Exponent::Omitted => Term::Zero,
            Exponent::Nonnegative(digits) => Term::Digits {
                negative: false,
                digits,
            },
            Exponent::Negative(digits) => Term::Digits {
                negative: true,
                digits,
            },
        }
    }

    pub(crate) fn parser_accepts(self) -> bool {
        match self.exponent {
            Exponent::Omitted => true,
            Exponent::Nonnegative(digits) | Exponent::Negative(digits) => {
                !exponent_digits_reach_limit(digits.iter().map(|digit| u32::from(*digit - b'0')))
            }
        }
    }

    pub(crate) fn is_integral(self) -> bool {
        self.is_zero()
            || sum_sign([
                self.exponent_term(),
                Term::Magnitude {
                    negative: false,
                    value: self.trailing_zeros(),
                },
                Term::Magnitude {
                    negative: true,
                    value: self.fraction.len(),
                },
                Term::Zero,
                Term::Zero,
            ]) != Ordering::Less
    }

    pub(crate) fn exceeds_range_digits(self, limit_len: usize) -> bool {
        let Exponent::Nonnegative(digits) = self.exponent else {
            return false;
        };
        if self.is_zero() {
            return false;
        }
        let exponent = Term::Digits {
            negative: false,
            digits,
        };
        let fraction = Term::Magnitude {
            negative: true,
            value: self.fraction.len(),
        };
        if sum_sign([exponent, fraction, Term::Zero, Term::Zero, Term::Zero]) == Ordering::Less {
            return false;
        }
        sum_sign([
            exponent,
            Term::Magnitude {
                negative: false,
                value: self.significant_digits(),
            },
            fraction,
            Term::Magnitude {
                negative: true,
                value: limit_len,
            },
            Term::Zero,
        ]) == Ordering::Greater
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token(text: &str) -> Option<DecimalToken<'_>> {
        DecimalToken::lex(text, WhitespacePolicy::NoWhitespace)
    }

    fn token_ws(text: &str) -> Option<DecimalToken<'_>> {
        DecimalToken::lex(text, WhitespacePolicy::JsonWhitespace)
    }

    fn magnitude(negative: bool, value: usize) -> Term<'static> {
        Term::Magnitude { negative, value }
    }

    #[test]
    fn strict_json_number_shapes_are_accepted() {
        assert!(token("0").is_some());
        assert!(token("-0").is_some());
        assert!(token("10").is_some());
        assert!(token("1.5e+3").is_some());
        assert!(token("1E-0").is_some());
        assert!(token("1e00").is_some());
    }

    #[test]
    fn leading_plus_leading_zero_and_missing_digits_are_rejected() {
        assert!(token("+1").is_none());
        assert!(token("01").is_none());
        assert!(token("-01").is_none());
        assert!(token("1.").is_none());
        assert!(token(".5").is_none());
        assert!(token("1e").is_none());
        assert!(token("1e+").is_none());
        assert!(token("-").is_none());
        assert!(token("").is_none());
    }

    #[test]
    fn whitespace_policies_differ_only_at_the_ends() {
        assert!(token(" 1 ").is_none());
        assert!(token_ws(" 1 ").is_some());
        assert!(token_ws("\t\r\n1\t").is_some());
        assert!(token_ws("\u{0B}1").is_none());
        assert!(token_ws("1 1").is_none());
        assert!(token_ws("   ").is_none());
    }

    #[test]
    fn exponent_kinds_are_distinguished() {
        let signed = token("-12.30e4");
        assert_eq!(signed.map(DecimalToken::is_negative), Some(true));
        assert_eq!(signed.map(DecimalToken::whole_digits), Some(&b"12"[..]));
        assert_eq!(signed.map(DecimalToken::fraction_digits), Some(&b"30"[..]));
        assert_eq!(
            signed.map(DecimalToken::exponent),
            Some(Exponent::Nonnegative(b"4"))
        );

        assert_eq!(
            token("1").map(DecimalToken::exponent),
            Some(Exponent::Omitted)
        );
        assert_eq!(
            token("1e5").map(DecimalToken::exponent),
            Some(Exponent::Nonnegative(b"5"))
        );
        assert_eq!(
            token("1e+5").map(DecimalToken::exponent),
            Some(Exponent::Nonnegative(b"5"))
        );
        assert_eq!(
            token("1e-5").map(DecimalToken::exponent),
            Some(Exponent::Negative(b"5"))
        );
    }

    #[test]
    fn fold_adds_carries_and_cancels() {
        assert_eq!(
            sum_sign([
                Term::Digits {
                    negative: false,
                    digits: b"99",
                },
                magnitude(false, 1),
                Term::Zero,
                Term::Zero,
                Term::Zero,
            ]),
            Ordering::Greater
        );
        assert_eq!(
            sum_sign([
                magnitude(false, 10),
                magnitude(true, 9),
                magnitude(true, 1),
                Term::Zero,
                Term::Zero
            ]),
            Ordering::Equal
        );
    }

    #[test]
    fn fold_reports_negative_carry_at_the_end() {
        assert_eq!(
            sum_sign([
                magnitude(true, 100),
                magnitude(false, 99),
                Term::Zero,
                Term::Zero,
                Term::Zero
            ]),
            Ordering::Less
        );
        assert_eq!(
            sum_sign([
                magnitude(true, 10),
                magnitude(false, 1),
                Term::Zero,
                Term::Zero,
                Term::Zero
            ]),
            Ordering::Less
        );
        assert_eq!(
            sum_sign([
                magnitude(true, 100),
                magnitude(false, 100),
                Term::Zero,
                Term::Zero,
                Term::Zero
            ]),
            Ordering::Equal
        );
        assert_eq!(
            sum_sign([
                magnitude(false, 5),
                magnitude(true, 0),
                Term::Zero,
                Term::Zero,
                Term::Zero
            ]),
            Ordering::Greater
        );
    }

    #[test]
    fn parser_rejects_exponents_reaching_the_reader_limit_in_both_signs() {
        assert!(token("1e9999").is_some_and(DecimalToken::parser_accepts));
        assert!(token("1e-9999").is_some_and(DecimalToken::parser_accepts));
        assert!(token("1").is_some_and(DecimalToken::parser_accepts));
        assert!(!token("1e10000").is_some_and(DecimalToken::parser_accepts));
        assert!(!token("1E+10000").is_some_and(DecimalToken::parser_accepts));
        assert!(!token("1e-10000").is_some_and(DecimalToken::parser_accepts));
        assert!(!token("0e-10000").is_some_and(DecimalToken::parser_accepts));
        let zeros = "0".repeat(5000);
        assert!(token(&format!("1e-{zeros}9999")).is_some_and(DecimalToken::parser_accepts));
        assert!(!token(&format!("1e{zeros}10000")).is_some_and(DecimalToken::parser_accepts));
    }

    #[test]
    fn integrality_uses_exponent_trailing_zeros_and_fraction() {
        assert!(token("1.0").is_some_and(DecimalToken::is_integral));
        assert!(!token("1.5").is_some_and(DecimalToken::is_integral));
        assert!(!token("15e-1").is_some_and(DecimalToken::is_integral));
        assert!(token("10e-1").is_some_and(DecimalToken::is_integral));
        assert!(token("0.0e-999999").is_some_and(DecimalToken::is_integral));
        assert!(token("1.5e1").is_some_and(DecimalToken::is_integral));
    }

    #[test]
    fn range_digit_guard_requires_an_explicit_nonnegative_exponent() {
        assert!(token("1e5").is_some_and(|t| t.exceeds_range_digits(0)));
        assert!(!token("1e-5").is_some_and(|t| t.exceeds_range_digits(0)));
        assert!(!token("1").is_some_and(|t| t.exceeds_range_digits(0)));
        assert!(!token("0e5").is_some_and(|t| t.exceeds_range_digits(0)));
    }

    #[test]
    fn range_digit_guard_counts_significant_digits_with_fraction() {
        assert!(token("1.5e1").is_some_and(|t| t.exceeds_range_digits(1)));
        assert!(!token("1.5e1").is_some_and(|t| t.exceeds_range_digits(2)));
        assert!(!token("1.5e0").is_some_and(|t| t.exceeds_range_digits(0)));
        assert!(token("100e0").is_some_and(|t| t.exceeds_range_digits(2)));
        assert!(!token("100e0").is_some_and(|t| t.exceeds_range_digits(3)));
        assert!(token("0.5e1").is_some_and(|t| t.exceeds_range_digits(0)));
    }
}
