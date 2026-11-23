// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::exact_json_view::JsonValueView;
use crate::semantic_numeric::{PreparedDataNumeric, PreparedDecimal, PreparedInteger};
use crate::semantic_types::TypeRef;
use crate::semantic_types::*;
use crate::semantic_validation::{
    decide_slot_in, meaning_blocked_table, meaning_obligations_in, prepare_format_with,
    BorrowedValueDecision, FormatWorkspace, GraphemeSource, PreparedFormat,
};
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::sync::Arc;

pub(crate) struct PreparedNamedFormat<'g> {
    binding: &'g FormatBinding,
    format: PreparedFormat<'g>,
}

pub(crate) enum ClassRef<'m, 'g> {
    Ordinary,
    Sealed { form: &'m PreparedSealedForm<'g> },
    Wrapper(&'g Wrapper),
}

pub(crate) struct PreparedProfile<'g> {
    profile: &'g VersionedSemanticProfile,
    graphemes: Option<GraphemeSource<'g>>,
    formats: Vec<PreparedNamedFormat<'g>>,
    data_numeric: PreparedDataNumeric<'g>,
    tag_key: Option<&'g str>,
    sealed: Vec<PreparedSealedForm<'g>>,
}

impl<'g> PreparedProfile<'g> {
    pub(crate) fn new(profile: &'g VersionedSemanticProfile) -> Self {
        let tag = profile.tag.as_ref();
        let graphemes = profile.grapheme_rules.as_ref().map(GraphemeSource::new);
        Self {
            profile,
            formats: profile
                .format_bindings
                .iter()
                .map(|binding| PreparedNamedFormat {
                    binding,
                    format: prepare_format_with(&binding.rule, graphemes.as_ref()),
                })
                .collect(),
            data_numeric: PreparedDataNumeric::new(profile),
            tag_key: tag.map(|tag| tag.key.as_str()),
            sealed: tag.map_or_else(Vec::new, |tag| {
                tag.sealed
                    .iter()
                    .map(|form| PreparedSealedForm::new(profile, graphemes.as_ref(), form))
                    .collect()
            }),
            graphemes,
        }
    }

    pub(crate) fn named(&self, name: &str) -> Option<&PreparedFormat<'g>> {
        self.formats
            .iter()
            .find(|entry| entry.binding.name == name)
            .map(|entry| &entry.format)
    }

    pub(crate) fn classify(&self, value: JsonValueView<'_>) -> ClassRef<'_, 'g> {
        if let Some(tag_key) = self.tag_key {
            if let Some(tag_value) = value.member(tag_key).and_then(JsonValueView::as_str) {
                if let Some(form) = self.sealed.iter().find(|form| form.form.tag == tag_value) {
                    return ClassRef::Sealed { form };
                }
            }
        }
        match self
            .profile
            .wrappers
            .iter()
            .find(|w| value.member(&w.key).is_some())
        {
            Some(wrapper) => ClassRef::Wrapper(wrapper),
            None => ClassRef::Ordinary,
        }
    }
}

pub(crate) struct PreparedSealedForm<'g> {
    form: &'g SealedForm,
    fields: Vec<PreparedSealedField<'g>>,
}

impl<'g> PreparedSealedForm<'g> {
    fn new(
        profile: &'g VersionedSemanticProfile,
        graphemes: Option<&GraphemeSource<'g>>,
        form: &'g SealedForm,
    ) -> Self {
        Self {
            form,
            fields: form
                .fields
                .iter()
                .map(|field| PreparedSealedField {
                    key: field.key.as_str(),
                    required: field.required,
                    leaf: PreparedLeaf::new(profile, graphemes, &field.leaf),
                })
                .collect(),
        }
    }
}

pub(crate) struct PreparedSealedField<'g> {
    key: &'g str,
    required: bool,
    leaf: PreparedLeaf<'g>,
}

pub(crate) enum PreparedLeaf<'g> {
    String(PreparedStringSpec<'g>),
    Integer(PreparedInteger<'g>),
}

impl<'g> PreparedLeaf<'g> {
    fn new(
        profile: &'g VersionedSemanticProfile,
        graphemes: Option<&GraphemeSource<'g>>,
        leaf: &'g SealedLeaf,
    ) -> Self {
        match leaf {
            SealedLeaf::String(spec) => Self::String(PreparedStringSpec::new(graphemes, spec)),
            SealedLeaf::Integer(spec) => Self::Integer(PreparedInteger::new(
                profile.integer_domain(spec.domain.as_deref()),
                Some(spec),
            )),
        }
    }
}

pub(crate) struct PreparedRefinement<'g> {
    key: &'g str,
    leaf: PreparedLeaf<'g>,
}

pub(crate) struct PreparedStringSpec<'g> {
    spec: &'g StringSpec,
    format: Option<PreparedUse<'g>>,
}

impl<'g> PreparedStringSpec<'g> {
    fn new(graphemes: Option<&GraphemeSource<'g>>, spec: &'g StringSpec) -> Self {
        Self {
            spec,
            format: spec
                .format
                .as_ref()
                .map(|usage| PreparedUse::new(graphemes, usage)),
        }
    }
}

pub(crate) enum PreparedUse<'g> {
    Named(&'g str),
    Inline(PreparedFormat<'g>),
}

impl<'g> PreparedUse<'g> {
    pub(crate) fn new(graphemes: Option<&GraphemeSource<'g>>, usage: &'g FormatUse) -> Self {
        match usage {
            FormatUse::Named(name) => Self::Named(name.as_str()),
            FormatUse::Inline(rule) => Self::Inline(prepare_format_with(rule, graphemes)),
        }
    }
}

pub(crate) struct Target<'g> {
    node: Option<usize>,
    reference: std::marker::PhantomData<&'g TypeRef>,
}

impl<'g> Target<'g> {
    fn new(index: &NodeIndex<'_>, reference: &'g TypeRef) -> Self {
        Self {
            node: index.get(reference),
            reference: std::marker::PhantomData,
        }
    }

    pub(crate) fn resolve(&self) -> Option<usize> {
        self.node
    }
}

const PRODUCT_SCAN_FIELDS: usize = 8;

pub(crate) struct PreparedProduct<'g> {
    spec: &'g ProductSpec,
    key_format: Option<PreparedUse<'g>>,
    fields: Vec<Target<'g>>,
    extra: Option<Target<'g>>,
    slot_of_name: Option<HashMap<&'g str, usize>>,
}

impl<'g> PreparedProduct<'g> {
    fn new(
        index: &NodeIndex<'_>,
        graphemes: Option<&GraphemeSource<'g>>,
        spec: &'g ProductSpec,
    ) -> Self {
        Self {
            spec,
            key_format: match &spec.extras {
                ExtraMembers::Allow {
                    key_format: Some(usage),
                    ..
                } => Some(PreparedUse::new(graphemes, usage)),
                _ => None,
            },
            fields: spec
                .fields
                .iter()
                .map(|field| Target::new(index, &field.slot.type_ref))
                .collect(),
            extra: match &spec.extras {
                ExtraMembers::Allow { value, .. } => Some(Target::new(index, &value.type_ref)),
                ExtraMembers::Reject => None,
            },
            slot_of_name: (spec.fields.len() > PRODUCT_SCAN_FIELDS).then(|| {
                let mut slots = HashMap::with_capacity(spec.fields.len());
                for (position, field) in spec.fields.iter().enumerate() {
                    slots.entry(field.wire_name.as_str()).or_insert(position);
                }
                slots
            }),
        }
    }
}

struct RefKey<'g>(&'g TypeRef);

impl Hash for RefKey<'_> {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.0.definition_name.hash(state);
        self.0.source.document_id.hash(state);
        self.0.pointer.hash(state);
    }
}

impl PartialEq for RefKey<'_> {
    fn eq(&self, other: &Self) -> bool {
        self.0 == other.0
    }
}

impl Eq for RefKey<'_> {}

pub(crate) struct NodeIndex<'g> {
    positions: HashMap<RefKey<'g>, usize>,
}

impl<'g> NodeIndex<'g> {
    pub(crate) fn new(graph: &'g SemanticGraph) -> Self {
        let mut positions = HashMap::with_capacity(graph.nodes.len());
        for (position, node) in graph.nodes.iter().enumerate() {
            positions.entry(RefKey(&node.reference)).or_insert(position);
        }
        Self { positions }
    }

    pub(crate) fn get(&self, reference: &TypeRef) -> Option<usize> {
        let positions: &HashMap<RefKey<'_>, usize> = &self.positions;
        positions.get(&RefKey(reference)).copied()
    }
}

pub(crate) enum PreparedShape<'g> {
    Boolean(&'g BooleanSpec),
    Integer(PreparedInteger<'g>),
    Decimal(PreparedDecimal<'g>),
    String(PreparedStringSpec<'g>),
    Bytes(&'g LengthSpec),
    Product(PreparedProduct<'g>),
    Array(&'g ArraySpec, Target<'g>),
    Alias(&'g TypeRef, Target<'g>),
    TaggedUnion(&'g UnionSpec, Vec<Target<'g>>),
    Sealed {
        tag: &'g str,
        refinements: Vec<PreparedRefinement<'g>>,
    },
    Never,
    Unknown(UnknownKind),
    Unit,
    RawBody,
    Opaque(&'g str),
}

impl<'g> PreparedShape<'g> {
    fn new(
        index: &NodeIndex<'_>,
        profile: &'g VersionedSemanticProfile,
        graphemes: Option<&GraphemeSource<'g>>,
        shape: &'g TypeShape,
    ) -> Self {
        match shape {
            TypeShape::Boolean(spec) => Self::Boolean(spec),
            TypeShape::Integer(spec) => Self::Integer(PreparedInteger::new(
                profile.integer_domain(spec.domain.as_deref()),
                Some(spec),
            )),
            TypeShape::Decimal(spec) => Self::Decimal(PreparedDecimal::new(spec)),
            TypeShape::String(spec) => Self::String(PreparedStringSpec::new(graphemes, spec)),
            TypeShape::Bytes(spec) => Self::Bytes(spec),
            TypeShape::Product(spec) => Self::Product(PreparedProduct::new(index, graphemes, spec)),
            TypeShape::Array(spec) => Self::Array(spec, Target::new(index, &spec.item.type_ref)),
            TypeShape::Alias { target, .. } => Self::Alias(target, Target::new(index, target)),
            TypeShape::TaggedUnion(spec) => Self::TaggedUnion(
                spec,
                spec.branches
                    .iter()
                    .map(|branch| Target::new(index, &branch.target))
                    .collect(),
            ),
            TypeShape::Sealed { tag, refinements } => Self::Sealed {
                tag: tag.as_str(),
                refinements: refinements
                    .iter()
                    .map(|refinement| PreparedRefinement {
                        key: refinement.key.as_str(),
                        leaf: PreparedLeaf::new(profile, graphemes, &refinement.leaf),
                    })
                    .collect(),
            },
            TypeShape::Never => Self::Never,
            TypeShape::Unknown(kind) => Self::Unknown(*kind),
            TypeShape::Unit => Self::Unit,
            TypeShape::RawBody { .. } => Self::RawBody,
            TypeShape::Opaque { type_name } => Self::Opaque(type_name.as_str()),
        }
    }
}

pub(crate) struct PreparedNode<'g> {
    shape: PreparedShape<'g>,
}

pub struct PreparedMetadata<'g> {
    graph: &'g SemanticGraph,
    profile: PreparedProfile<'g>,
    nodes: Vec<PreparedNode<'g>>,
    index: NodeIndex<'g>,
    meaning_blocked: Vec<bool>,
}

impl<'g> PreparedMetadata<'g> {
    pub(crate) fn new(graph: &'g SemanticGraph) -> Self {
        let profile = PreparedProfile::new(&graph.profile);
        let index = NodeIndex::new(graph);
        let nodes = graph
            .nodes
            .iter()
            .map(|node| PreparedNode {
                shape: PreparedShape::new(&index, &graph.profile, profile.graphemes(), &node.shape),
            })
            .collect();
        Self {
            graph,
            profile,
            nodes,
            index,
            meaning_blocked: Vec::new(),
        }
    }

    pub(crate) fn with_meaning(graph: &'g SemanticGraph) -> Self {
        let mut metadata = Self::new(graph);
        metadata.meaning_blocked = meaning_blocked_table(graph, &metadata.index);
        metadata
    }

    pub(crate) fn meaning_blocked(&self, reference: &TypeRef) -> bool {
        match self.node_index(reference) {
            Some(index) => self.meaning_blocked.get(index).copied().unwrap_or(true),
            None => true,
        }
    }

    pub fn meaning_obligations(&self, roots: &[TypeRef]) -> Vec<SemanticObligation> {
        meaning_obligations_in(self.graph, &self.index, roots)
    }

    pub(crate) fn node(&self, index: Option<usize>) -> Option<&PreparedNode<'g>> {
        self.nodes.get(index?)
    }

    pub(crate) fn node_index(&self, reference: &TypeRef) -> Option<usize> {
        self.index.get(reference)
    }

    pub(crate) fn index(&self) -> &NodeIndex<'g> {
        &self.index
    }

    pub(crate) fn product(&self, index: Option<usize>) -> Option<&PreparedProduct<'g>> {
        match self.node(index)?.shape() {
            PreparedShape::Product(product) => Some(product),
            _ => None,
        }
    }
}

pub struct PreparedValidator<'g> {
    metadata: Arc<PreparedMetadata<'g>>,
    workspace: FormatWorkspace,
}

impl<'g> PreparedValidator<'g> {
    pub fn new(graph: &'g SemanticGraph, workspace: FormatWorkspace) -> Self {
        Self {
            metadata: Arc::new(PreparedMetadata::with_meaning(graph)),
            workspace,
        }
    }

    pub fn with_empty_workspace(&self) -> Self {
        Self {
            metadata: Arc::clone(&self.metadata),
            workspace: FormatWorkspace::empty(),
        }
    }

    pub fn graph(&self) -> &'g SemanticGraph {
        self.metadata.graph
    }

    pub fn metadata(&self) -> &PreparedMetadata<'g> {
        &self.metadata
    }

    pub fn meaning_obligations(&self, roots: &[TypeRef]) -> Vec<SemanticObligation> {
        self.metadata.meaning_obligations(roots)
    }

    pub(crate) fn shared_metadata(&self) -> &Arc<PreparedMetadata<'g>> {
        &self.metadata
    }

    pub(crate) fn parts(&mut self) -> (&PreparedMetadata<'g>, &mut FormatWorkspace) {
        (&self.metadata, &mut self.workspace)
    }

    pub fn decide_view_slot<'a>(
        &mut self,
        slot: &'a SlotContract,
        value: SlotValue<JsonValueView<'a>>,
    ) -> BorrowedValueDecision<'a, 'g>
    where
        'g: 'a,
    {
        decide_slot_in(&self.metadata, &mut self.workspace, slot, value)
    }
}

impl<'g> PreparedProfile<'g> {
    pub(crate) fn profile(&self) -> &'g VersionedSemanticProfile {
        self.profile
    }

    pub(crate) fn graphemes(&self) -> Option<&GraphemeSource<'g>> {
        self.graphemes.as_ref()
    }

    pub(crate) fn data_numeric(&self) -> &PreparedDataNumeric<'g> {
        &self.data_numeric
    }
}

impl<'g> PreparedSealedForm<'g> {
    pub(crate) fn form(&self) -> &'g SealedForm {
        self.form
    }

    pub(crate) fn fields(&self) -> &[PreparedSealedField<'g>] {
        &self.fields
    }
}

impl<'g> PreparedSealedField<'g> {
    pub(crate) fn key(&self) -> &'g str {
        self.key
    }

    pub(crate) fn required(&self) -> bool {
        self.required
    }

    pub(crate) fn leaf(&self) -> &PreparedLeaf<'g> {
        &self.leaf
    }
}

impl<'g> PreparedRefinement<'g> {
    pub(crate) fn key(&self) -> &'g str {
        self.key
    }

    pub(crate) fn leaf(&self) -> &PreparedLeaf<'g> {
        &self.leaf
    }
}

impl<'g> PreparedStringSpec<'g> {
    pub(crate) fn spec(&self) -> &'g StringSpec {
        self.spec
    }

    pub(crate) fn format(&self) -> Option<&PreparedUse<'g>> {
        self.format.as_ref()
    }
}

impl<'g> PreparedProduct<'g> {
    pub(crate) fn spec(&self) -> &'g ProductSpec {
        self.spec
    }

    pub(crate) fn key_format(&self) -> Option<&PreparedUse<'g>> {
        self.key_format.as_ref()
    }

    pub(crate) fn field_targets(&self) -> &[Target<'g>] {
        &self.fields
    }

    pub(crate) fn extra_target(&self) -> Option<&Target<'g>> {
        self.extra.as_ref()
    }

    pub(crate) fn scans_fields(&self) -> bool {
        self.spec.fields.len() <= PRODUCT_SCAN_FIELDS
    }

    pub(crate) fn slot_of(&self, key: &str) -> Option<usize> {
        let fields = &self.spec.fields;
        if fields.len() <= PRODUCT_SCAN_FIELDS {
            return fields.iter().position(|field| field.wire_name == key);
        }
        self.slot_of_name.as_ref()?.get(key).copied()
    }
}

impl<'g> PreparedNode<'g> {
    pub(crate) fn shape(&self) -> &PreparedShape<'g> {
        &self.shape
    }
}

impl<'g> PreparedMetadata<'g> {
    pub(crate) fn graph(&self) -> &'g SemanticGraph {
        self.graph
    }

    pub(crate) fn profile(&self) -> &PreparedProfile<'g> {
        &self.profile
    }
}
