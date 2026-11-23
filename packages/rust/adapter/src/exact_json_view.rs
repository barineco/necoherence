// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::exact_json::JsonValue;
use crate::semantic_execution::ProductView;
use crate::semantic_types::{SlotValue, ValueKind};
use num_bigint::BigInt;

static JSON_NULL: JsonValue = JsonValue::Null;

#[derive(Clone, Copy, Debug)]
pub struct JsonValueView<'a> {
    repr: Repr<'a>,
}

#[derive(Clone, Copy, Debug)]
enum Repr<'a> {
    Native(&'a JsonValue),
    NativeObject(&'a [(String, JsonValue)]),
    Fields(&'a [(&'a str, SlotValue<JsonValueView<'a>>)]),
    Product(ProductView<'a>),
}

#[derive(Clone)]
struct Members<'a> {
    inner: MembersRepr<'a>,
}

#[derive(Clone)]
enum MembersRepr<'a> {
    Native(std::slice::Iter<'a, (String, JsonValue)>),
    Fields(std::slice::Iter<'a, (&'a str, SlotValue<JsonValueView<'a>>)>),
    Product { view: ProductView<'a>, index: usize },
}

impl<'a> Iterator for Members<'a> {
    type Item = (&'a str, JsonValueView<'a>);

    fn next(&mut self) -> Option<Self::Item> {
        match &mut self.inner {
            MembersRepr::Native(items) => items
                .next()
                .map(|(key, value)| (key.as_str(), JsonValueView::from_json(value))),
            MembersRepr::Fields(fields) => loop {
                let &(key, ref value) = fields.next()?;
                match value {
                    SlotValue::Absent => continue,
                    SlotValue::Null => return Some((key, JsonValueView::null())),
                    SlotValue::Present(view) => return Some((key, *view)),
                }
            },
            MembersRepr::Product { view, index } => loop {
                let (key, value) = match view.field(*index) {
                    Ok(Some(entry)) => entry,
                    Ok(None) | Err(_) => return None,
                };
                *index += 1;
                match value {
                    SlotValue::Absent => continue,
                    SlotValue::Null => return Some((key, JsonValueView::null())),
                    SlotValue::Present(member) => return Some((key, member)),
                }
            },
        }
    }
}

impl<'a> JsonValueView<'a> {
    pub fn from_json(value: &'a JsonValue) -> Self {
        match value {
            JsonValue::Obj(members) => Self {
                repr: Repr::NativeObject(members.as_slice()),
            },
            _ => Self {
                repr: Repr::Native(value),
            },
        }
    }

    pub fn object(fields: &'a [(&'a str, SlotValue<JsonValueView<'a>>)]) -> Self {
        Self {
            repr: Repr::Fields(fields),
        }
    }

    pub(crate) fn product(view: ProductView<'a>) -> Self {
        Self {
            repr: Repr::Product(view),
        }
    }

    fn null() -> Self {
        Self {
            repr: Repr::Native(&JSON_NULL),
        }
    }

    pub fn kind(self) -> ValueKind {
        match self.repr {
            Repr::Native(value) => match value {
                JsonValue::Null => ValueKind::Null,
                JsonValue::Bool(_) => ValueKind::Boolean,
                JsonValue::Num(_) | JsonValue::Dec(_) => ValueKind::Number,
                JsonValue::Str(_) => ValueKind::String,
                JsonValue::Arr(_) => ValueKind::Array,
                JsonValue::Obj(_) => ValueKind::Object,
            },
            Repr::NativeObject(_) | Repr::Fields(_) | Repr::Product(_) => ValueKind::Object,
        }
    }

    pub fn as_bool(self) -> Option<bool> {
        match self.repr {
            Repr::Native(JsonValue::Bool(value)) => Some(*value),
            _ => None,
        }
    }

    pub fn as_integer(self) -> Option<&'a BigInt> {
        match self.repr {
            Repr::Native(JsonValue::Num(value)) => Some(value),
            _ => None,
        }
    }

    pub fn as_decimal_text(self) -> Option<&'a str> {
        match self.repr {
            Repr::Native(JsonValue::Dec(text)) => Some(text.as_str()),
            _ => None,
        }
    }

    pub fn as_str(self) -> Option<&'a str> {
        match self.repr {
            Repr::Native(JsonValue::Str(text)) => Some(text.as_str()),
            _ => None,
        }
    }

    pub fn as_array(self) -> Option<&'a [JsonValue]> {
        match self.repr {
            Repr::Native(JsonValue::Arr(items)) => Some(items.as_slice()),
            _ => None,
        }
    }

    pub fn members(
        self,
    ) -> Option<impl Iterator<Item = (&'a str, JsonValueView<'a>)> + Clone + 'a> {
        match self.repr {
            Repr::Native(_) => None,
            Repr::NativeObject(members) => Some(Members {
                inner: MembersRepr::Native(members.iter()),
            }),
            Repr::Fields(fields) => Some(Members {
                inner: MembersRepr::Fields(fields.iter()),
            }),
            Repr::Product(view) => Some(Members {
                inner: MembersRepr::Product { view, index: 0 },
            }),
        }
    }

    pub fn member(self, key: &str) -> Option<JsonValueView<'a>> {
        self.members()?
            .find(|(member, _)| *member == key)
            .map(|(_, value)| value)
    }

    pub fn size(self) -> usize {
        crate::stack_growth::grow(|| self.size_frame())
    }

    fn size_frame(self) -> usize {
        let children = if let Some(items) = self.as_array() {
            items
                .iter()
                .map(|item| JsonValueView::from_json(item).size())
                .sum()
        } else if let Some(members) = self.members() {
            members.map(|(_, member)| member.size()).sum()
        } else {
            0
        };
        1 + children
    }

    pub fn to_owned(&self) -> JsonValue {
        match self.repr {
            Repr::Native(value) => value.clone(),
            Repr::NativeObject(members) => JsonValue::Obj(members.to_vec()),
            Repr::Fields(_) | Repr::Product(_) => JsonValue::Obj(
                (*self)
                    .members()
                    .into_iter()
                    .flatten()
                    .map(|(key, value)| (key.to_owned(), value.to_owned()))
                    .collect(),
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absent_members_are_omitted_and_null_is_static() {
        let payload = JsonValue::Str("p".into());
        let one = JsonValue::Num(BigInt::from(1));
        let fields = [
            ("a", SlotValue::Absent),
            ("b", SlotValue::Null),
            ("a", SlotValue::Present(JsonValueView::from_json(&one))),
            ("b", SlotValue::Present(JsonValueView::from_json(&payload))),
        ];
        let view = JsonValueView::object(&fields);
        let keys: Vec<&str> = view
            .members()
            .into_iter()
            .flatten()
            .map(|(k, _)| k)
            .collect();
        assert_eq!(keys, ["b", "a", "b"]);
        assert_eq!(
            view.member("a").and_then(JsonValueView::as_integer),
            Some(&BigInt::from(1))
        );
        assert_eq!(
            view.member("b").map(JsonValueView::kind),
            Some(ValueKind::Null)
        );
        assert!(view.member("missing").is_none());
        assert_eq!(
            view.to_owned(),
            JsonValue::Obj(vec![
                ("b".into(), JsonValue::Null),
                ("a".into(), one.clone()),
                ("b".into(), payload.clone()),
            ])
        );
    }

    #[test]
    fn to_owned_takes_a_shared_receiver_and_returns_json() {
        let payload = JsonValue::Str("p".into());
        let view = JsonValueView::from_json(&payload);
        let by_ref: JsonValue = JsonValueView::to_owned(&view);
        let by_value: JsonValue = view.to_owned();
        assert_eq!(by_ref, payload);
        assert_eq!(by_value, payload);
    }

    #[test]
    fn nested_object_projection_matches_native_order() {
        let inner_fields = [("x", SlotValue::Absent), ("y", SlotValue::Null)];
        let inner = JsonValueView::object(&inner_fields);
        let outer_fields = [("n", SlotValue::Present(inner))];
        let outer = JsonValueView::object(&outer_fields);
        let owned = outer.to_owned();
        assert_eq!(
            owned,
            JsonValue::Obj(vec![(
                "n".into(),
                JsonValue::Obj(vec![("y".into(), JsonValue::Null)])
            )])
        );
        let native = JsonValueView::from_json(&owned);
        assert_eq!(native.kind(), ValueKind::Object);
        assert_eq!(native.to_owned(), owned);
    }
}
