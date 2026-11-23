// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::search_state::no_duplicates;
use super::verification::{BranchTrace, TraceStep};
use necoherence::core::Nat;
use necoherence::inclusion::verify_inclusion;
use necoherence::semantic_composition::*;
use necoherence::semantic_types::*;
use necoherence::typed_mapping as resource;
use num_traits::{One, ToPrimitive, Zero};
use std::collections::HashSet;

#[derive(Debug, Clone, PartialEq)]
pub enum LoweringFailure {
    Invalid(String),
    Unknown(UnresolvedObligation),
}

pub(crate) fn producer_identity(producer: &ProducerRef) -> String {
    match producer {
        ProducerRef::Initial(id) => encode_tuple(&["initial-value", &id.0]),
        ProducerRef::InvocationOutcome {
            site,
            outcome,
            port,
        } => encode_tuple(&["outcome-value", &site.0, &outcome.0, &port.0]),
    }
}

pub(crate) fn lot_identity(lot: &ResourceLotRef) -> String {
    match lot {
        ResourceLotRef::Initial(id) => encode_tuple(&["initial-lot", &id.0]),
        ResourceLotRef::Produced {
            site,
            outcome,
            production,
        } => encode_tuple(&["produced-lot", &site.0, &outcome.0, &production.0]),
    }
}

fn invocation_identity(invocation: &InvocationPlan, outcome: &OutcomeId) -> String {
    encode_tuple(&[
        "invocation",
        &invocation.site.0,
        &function_identity(&invocation.function),
        &outcome.0,
    ])
}

fn production_identity(site: &SiteId, outcome: &OutcomeId, production: &ProductionId) -> String {
    encode_tuple(&["resource-production", &site.0, &outcome.0, &production.0])
}

pub(crate) fn declared_value(
    input: &CompositionInput,
    producer: &ProducerRef,
) -> Option<(SlotContract, Option<ResourceLotRef>)> {
    match producer {
        ProducerRef::Initial(id) => input
            .initial_inputs
            .iter()
            .find(|initial| initial.id == *id)
            .map(|initial| {
                (
                    initial.contract.clone(),
                    initial.resource.clone().map(ResourceLotRef::Initial),
                )
            }),
        ProducerRef::InvocationOutcome {
            site,
            outcome,
            port,
        } => {
            let output = site_signature(input, site)?
                .outcomes
                .iter()
                .find(|candidate| candidate.id == *outcome)?
                .value_ports
                .iter()
                .find(|candidate| candidate.id == *port)?;
            Some((
                output.contract.clone(),
                output
                    .resource_production
                    .clone()
                    .map(|production| ResourceLotRef::Produced {
                        site: site.clone(),
                        outcome: outcome.clone(),
                        production,
                    }),
            ))
        }
    }
}

fn field_binding_sources<'a>(fields: &'a [(String, BindingExpr)], result: &mut Vec<&'a ValueRef>) {
    for (_, binding) in fields {
        binding_sources(binding, result);
    }
}

pub(crate) fn binding_sources<'a>(binding: &'a BindingExpr, result: &mut Vec<&'a ValueRef>) {
    match binding {
        BindingExpr::Source { value, .. } => result.push(value),
        BindingExpr::Product { fields, .. } => field_binding_sources(fields, result),
    }
}

struct LoweredPhase {
    identity: String,
    revision: Nat,
    value_reads: Vec<ProducerRef>,
    reads: Vec<(ResourceLotRef, Nat)>,
    consumes: Vec<(ResourceLotRef, Nat)>,
    outputs: Vec<String>,
}

fn add_requirement(
    requirements: &mut Vec<(ResourceLotRef, Nat)>,
    lot: ResourceLotRef,
    count: Nat,
    consume: bool,
) {
    if let Some((_, previous)) = requirements
        .iter_mut()
        .find(|(reference, _)| *reference == lot)
    {
        if consume {
            *previous += count;
        } else if *previous < count {
            *previous = count;
        }
    } else {
        requirements.push((lot, count));
    }
}

pub fn lower_resource_trace(
    prepared: &PreparedCompositionInput<'_>,
    trace: &BranchTrace,
) -> Result<(resource::SolverInput, ResourceCorrespondence), LoweringFailure> {
    lower_resource_trace_core(prepared, trace, true)
}

fn token_capacity(input: &CompositionInput) -> Nat {
    input
        .bounds
        .resource_bounds
        .as_ref()
        .map(|bound| bound.max_tokens.clone())
        .unwrap_or_else(default_resource_token_bound)
}

fn exactly_one<'a, T>(
    items: &'a [T],
    predicate: impl Fn(&T) -> bool,
    reason: &str,
) -> Result<&'a T, LoweringFailure> {
    let candidates: Vec<&'a T> = items.iter().filter(|item| predicate(*item)).collect();
    match candidates.as_slice() {
        [item] => Ok(*item),
        _ => Err(LoweringFailure::Invalid(reason.to_owned())),
    }
}

struct LoweringAccumulator {
    lots: Vec<ResourceLotCorrespondence>,
    values: Vec<ValueCorrespondence>,
    marking: resource::Marking,
    places: Vec<resource::TypedPlace>,
    phases: Vec<LoweredPhase>,
    available: HashSet<ProducerRef>,
    used_sites: HashSet<SiteId>,
    used_guards: HashSet<GuardId>,
}

fn lower_initial(input: &CompositionInput) -> Result<LoweringAccumulator, LoweringFailure> {
    let invalid = |reason: String| LoweringFailure::Invalid(reason);
    let mut lots = Vec::new();
    let mut values = Vec::new();
    let mut marking = resource::Marking { places: Vec::new() };
    let mut places = Vec::new();
    let mut available = HashSet::new();
    for lot in &input.initial_resources {
        let reference = ResourceLotRef::Initial(lot.id.clone());
        let place = lot_identity(&reference);
        let target = match &lot.producer {
            ResourceProducer::Initial { identity, revision } => {
                encode_tuple(&["initial-resource", identity, revision, &lot.id.0])
            }
            _ => return Err(invalid("initial lot producer".to_owned())),
        };
        let quantity = lot.quantity.to_usize().ok_or_else(|| {
            LoweringFailure::Unknown(UnresolvedObligation::ResourceCapacityBound {
                required: lot.quantity.clone(),
                limit: token_capacity(input),
            })
        })?;
        let cap = token_capacity(input);
        if Nat::from(quantity) > cap {
            return Err(LoweringFailure::Unknown(
                UnresolvedObligation::ResourceCapacityBound {
                    required: lot.quantity.clone(),
                    limit: cap,
                },
            ));
        }
        let token_type = type_identity(&lot.token_type);
        places.push(resource::TypedPlace {
            identity: place.clone(),
            token_type: token_type.clone(),
            revision: lot.revision.clone(),
        });
        marking.places.push((
            place.clone(),
            vec![
                resource::ColoredToken {
                    target: target.clone(),
                    index: Nat::zero(),
                    revision: lot.revision.clone(),
                    kind: resource::TokenKind::Input
                };
                quantity
            ],
        ));
        lots.push(ResourceLotCorrespondence {
            lot: reference,
            place,
            producer: lot.producer.clone(),
            token_target: target,
            token_type,
            revision: lot.revision.clone(),
            quantity: lot.quantity.clone(),
            provenance: lot.provenance.clone(),
        });
    }
    for initial in &input.initial_inputs {
        let producer = ProducerRef::Initial(initial.id.clone());
        let place = producer_identity(&producer);
        let target = place.clone();
        places.push(resource::TypedPlace {
            identity: place.clone(),
            token_type: type_identity(&initial.contract.type_ref),
            revision: Nat::zero(),
        });
        marking.places.push((
            place.clone(),
            vec![resource::ColoredToken {
                target: target.clone(),
                index: Nat::zero(),
                revision: Nat::zero(),
                kind: resource::TokenKind::Input,
            }],
        ));
        available.insert(producer.clone());
        values.push(ValueCorrespondence {
            producer,
            place,
            token_target: target,
            revision: Nat::zero(),
        });
    }
    Ok(LoweringAccumulator {
        lots,
        values,
        marking,
        places,
        phases: Vec::new(),
        available,
        used_sites: HashSet::new(),
        used_guards: HashSet::new(),
    })
}

fn lower_trace_steps(
    prepared: &PreparedCompositionInput<'_>,
    steps: &[TraceStep],
    initial: LoweringAccumulator,
) -> Result<LoweringAccumulator, LoweringFailure> {
    let input = prepared.input();
    let invalid = |reason: String| LoweringFailure::Invalid(reason);
    let LoweringAccumulator {
        mut lots,
        mut values,
        marking,
        mut places,
        mut phases,
        mut available,
        mut used_sites,
        mut used_guards,
    } = initial;
    for step in steps {
        match step {
            TraceStep::Guard {
                guard, inspected, ..
            } => {
                if !used_guards.insert(guard.clone())
                    || !input
                        .invocation_domain
                        .guards
                        .iter()
                        .any(|declaration| declaration.id == *guard)
                    || !available.contains(&inspected.producer)
                {
                    return Err(invalid("guard declaration or producer".to_owned()));
                }
                phases.push(LoweredPhase {
                    identity: encode_tuple(&[
                        "guard",
                        &guard.0,
                        &producer_identity(&inspected.producer),
                    ]),
                    revision: Nat::zero(),
                    value_reads: vec![inspected.producer.clone()],
                    reads: Vec::new(),
                    consumes: Vec::new(),
                    outputs: Vec::new(),
                });
            }
            TraceStep::Invocation {
                invocation,
                outcome,
            } => {
                if !used_sites.insert(invocation.site.clone()) {
                    return Err(invalid("site fired twice".to_owned()));
                }
                let function = site_signature(input, &invocation.site)
                    .ok_or_else(|| invalid("site signature".to_owned()))?;
                if function.reference != invocation.function {
                    return Err(invalid("function revision".to_owned()));
                }
                let outcome_contract = function
                    .outcomes
                    .iter()
                    .find(|candidate| candidate.id == *outcome)
                    .ok_or_else(|| invalid("invocation outcome".to_owned()))?;
                if invocation.bindings.len() != function.inputs.len()
                    || invocation.resources.len() != function.resource_inputs.len()
                {
                    return Err(invalid("binding coverage".to_owned()));
                }
                let mut reads = Vec::new();
                let mut consumes = Vec::new();
                let mut value_reads = Vec::new();
                for port in &function.inputs {
                    let (_, binding) = exactly_one(
                        &invocation.bindings,
                        |(id, _)| *id == port.id,
                        "input binding",
                    )?;
                    let mut sources = Vec::new();
                    binding_sources(binding, &mut sources);
                    for source in &sources {
                        if !available.contains(&source.producer) {
                            return Err(invalid("value producer is not earlier".to_owned()));
                        }
                        if !value_reads.contains(&source.producer) {
                            value_reads.push(source.producer.clone());
                        }
                        if let Some((_, Some(lot))) = declared_value(input, &source.producer) {
                            add_requirement(&mut reads, lot, Nat::one(), false);
                        }
                    }
                    if let Some(requirement) = &port.resource_requirement {
                        let resource_binding = exactly_one(
                            &invocation.resources,
                            |binding| binding.requirement == *requirement,
                            "backing requirement",
                        )?;
                        let [source] = sources.as_slice() else {
                            return Err(invalid(
                                "resource backed input must have one producer".to_owned(),
                            ));
                        };
                        if declared_value(input, &source.producer)
                            .and_then(|(_, lot)| lot)
                            .as_ref()
                            != Some(&resource_binding.lot)
                        {
                            return Err(invalid("port resource backing differs".to_owned()));
                        }
                    }
                }
                for requirement in &function.resource_inputs {
                    let binding = exactly_one(
                        &invocation.resources,
                        |binding| binding.requirement == requirement.id,
                        "resource binding",
                    )?;
                    let lot = lots
                        .iter()
                        .find(|lot| lot.lot == binding.lot)
                        .ok_or_else(|| invalid("resource producer unavailable".to_owned()))?;
                    let declaration = declared_lot(input, &binding.lot)
                        .ok_or_else(|| invalid("resource declaration".to_owned()))?;
                    if declaration.revision != requirement.required_revision
                        || !matches!(&requirement.identity, ResourceIdentityConstraint::Any)
                            && requirement.identity
                                != ResourceIdentityConstraint::Exactly(declaration.producer.clone())
                    {
                        return Err(invalid("resource identity or revision".to_owned()));
                    }
                    verify_inclusion(
                        prepared.graph(),
                        &present_contract(declaration.token_type),
                        &present_contract(requirement.token_type.clone()),
                        &binding.inclusion,
                    )
                    .map_err(|_| invalid("resource type inclusion".to_owned()))?;
                    match requirement.mode {
                        resource::BindingMode::Read => add_requirement(
                            &mut reads,
                            lot.lot.clone(),
                            requirement.multiplicity.clone(),
                            false,
                        ),
                        resource::BindingMode::Consume => add_requirement(
                            &mut consumes,
                            lot.lot.clone(),
                            requirement.multiplicity.clone(),
                            true,
                        ),
                    }
                }
                let identity = invocation_identity(invocation, outcome);
                let mut outputs = Vec::new();
                for port in &outcome_contract.value_ports {
                    let producer = ProducerRef::InvocationOutcome {
                        site: invocation.site.clone(),
                        outcome: outcome.clone(),
                        port: port.id.clone(),
                    };
                    let place = producer_identity(&producer);
                    places.push(resource::TypedPlace {
                        identity: place.clone(),
                        token_type: type_identity(&port.contract.type_ref),
                        revision: Nat::zero(),
                    });
                    values.push(ValueCorrespondence {
                        producer: producer.clone(),
                        place: place.clone(),
                        token_target: identity.clone(),
                        revision: Nat::zero(),
                    });
                    available.insert(producer);
                    outputs.push(place);
                }
                phases.push(LoweredPhase {
                    identity,
                    revision: Nat::zero(),
                    value_reads,
                    reads,
                    consumes,
                    outputs,
                });
                for production in &outcome_contract.produced_resources {
                    let reference = ResourceLotRef::Produced {
                        site: invocation.site.clone(),
                        outcome: outcome.clone(),
                        production: production.id.clone(),
                    };
                    let place = lot_identity(&reference);
                    let target = production_identity(&invocation.site, outcome, &production.id);
                    let token_type = type_identity(&production.token_type);
                    let quantity = production.quantity.to_usize().ok_or_else(|| {
                        LoweringFailure::Unknown(UnresolvedObligation::ResourceCapacityBound {
                            required: production.quantity.clone(),
                            limit: token_capacity(input),
                        })
                    })?;
                    let cap = token_capacity(input);
                    if Nat::from(quantity) > cap {
                        return Err(LoweringFailure::Unknown(
                            UnresolvedObligation::ResourceCapacityBound {
                                required: production.quantity.clone(),
                                limit: cap,
                            },
                        ));
                    }
                    places.push(resource::TypedPlace {
                        identity: place.clone(),
                        token_type: token_type.clone(),
                        revision: production.revision.clone(),
                    });
                    lots.push(ResourceLotCorrespondence {
                        lot: reference,
                        place: place.clone(),
                        producer: ResourceProducer::InvocationOutcome {
                            site: invocation.site.clone(),
                            outcome: outcome.clone(),
                        },
                        token_target: target.clone(),
                        token_type,
                        revision: production.revision.clone(),
                        quantity: production.quantity.clone(),
                        provenance: production.provenance.clone(),
                    });
                    phases.push(LoweredPhase {
                        identity: target,
                        revision: production.revision.clone(),
                        value_reads: Vec::new(),
                        reads: Vec::new(),
                        consumes: Vec::new(),
                        outputs: vec![place; quantity],
                    });
                }
            }
        }
    }
    Ok(LoweringAccumulator {
        lots,
        values,
        marking,
        places,
        phases,
        available,
        used_sites,
        used_guards,
    })
}

pub(crate) fn lower_resource_trace_core(
    prepared: &PreparedCompositionInput<'_>,
    trace: &BranchTrace,
    final_goals: bool,
) -> Result<(resource::SolverInput, ResourceCorrespondence), LoweringFailure> {
    let input = prepared.input();
    let invalid = |reason: String| LoweringFailure::Invalid(reason);
    let LoweringAccumulator {
        lots,
        values,
        mut marking,
        mut places,
        phases,
        ..
    } = lower_trace_steps(prepared, &trace.steps, lower_initial(input)?)?;
    let root_control = encode_tuple(&["control", "0"]);
    places.push(resource::TypedPlace {
        identity: root_control.clone(),
        token_type: "control".to_owned(),
        revision: Nat::zero(),
    });
    marking.places.push((
        root_control.clone(),
        vec![resource::ColoredToken {
            target: "control-root".to_owned(),
            index: Nat::zero(),
            revision: Nat::zero(),
            kind: resource::TokenKind::Input,
        }],
    ));
    let mut previous_control = root_control;
    let mut previous_target = "control-root".to_owned();
    let mut previous_revision = Nat::zero();
    let mut transitions = Vec::new();
    let mut bindings = Vec::new();
    let mut normalized_bindings = Vec::new();
    let mut execution_order = Vec::new();
    let mut maximum_tokens = Nat::from(
        marking
            .places
            .iter()
            .map(|(_, tokens)| tokens.len())
            .sum::<usize>(),
    );
    for (index, phase) in phases.into_iter().enumerate() {
        let permit = encode_tuple(&["permit", &phase.identity]);
        places.push(resource::TypedPlace {
            identity: permit.clone(),
            token_type: "control".to_owned(),
            revision: Nat::zero(),
        });
        marking.places.push((
            permit.clone(),
            vec![resource::ColoredToken {
                target: permit.clone(),
                index: Nat::zero(),
                revision: Nat::zero(),
                kind: resource::TokenKind::Input,
            }],
        ));
        let next_control = encode_tuple(&["control", &(index + 1).to_string()]);
        places.push(resource::TypedPlace {
            identity: next_control.clone(),
            token_type: "control".to_owned(),
            revision: phase.revision.clone(),
        });
        let mut input_places = vec![previous_control.clone(), permit.clone()];
        let mut transition_bindings = vec![
            resource::InputBinding {
                transition_id: phase.identity.clone(),
                name: "order".to_owned(),
                place: previous_control.clone(),
                token_type: "control".to_owned(),
                identity: previous_target.clone(),
                provenance: "selected branch order".to_owned(),
                multiplicity: Nat::one(),
                mode: resource::BindingMode::Consume,
                required_revision: previous_revision.clone(),
            },
            resource::InputBinding {
                transition_id: phase.identity.clone(),
                name: "permit".to_owned(),
                place: permit.clone(),
                token_type: "control".to_owned(),
                identity: permit,
                provenance: "finite site permit".to_owned(),
                multiplicity: Nat::one(),
                mode: resource::BindingMode::Consume,
                required_revision: Nat::zero(),
            },
        ];
        for producer in &phase.value_reads {
            let value = values
                .iter()
                .find(|value| &value.producer == producer)
                .ok_or_else(|| invalid("input value correspondence unavailable".to_owned()))?;
            let declaration = declared_value(input, producer)
                .ok_or_else(|| invalid("input value declaration unavailable".to_owned()))?;
            input_places.push(value.place.clone());
            transition_bindings.push(resource::InputBinding {
                transition_id: phase.identity.clone(),
                name: encode_tuple(&["value-read", &value.place]),
                place: value.place.clone(),
                token_type: type_identity(&declaration.0.type_ref),
                identity: value.token_target.clone(),
                provenance: producer_identity(producer),
                multiplicity: Nat::one(),
                mode: resource::BindingMode::Read,
                required_revision: value.revision.clone(),
            });
        }
        let lot_refs: Vec<_> = phase
            .reads
            .iter()
            .chain(&phase.consumes)
            .map(|(lot, _)| lot)
            .collect();
        let mut seen = HashSet::new();
        for reference in lot_refs {
            if !seen.insert(reference) {
                continue;
            }
            let lot = lots
                .iter()
                .find(|lot| &lot.lot == reference)
                .ok_or_else(|| invalid("normalized lot".to_owned()))?;
            let read = phase
                .reads
                .iter()
                .find(|(lot, _)| lot == reference)
                .map(|(_, count)| count.clone())
                .unwrap_or_else(Nat::zero);
            let consume = phase
                .consumes
                .iter()
                .find(|(lot, _)| lot == reference)
                .map(|(_, count)| count.clone())
                .unwrap_or_else(Nat::zero);
            input_places.push(lot.place.clone());
            for (mode_name, mode, count) in [
                ("read", resource::BindingMode::Read, &read),
                ("consume", resource::BindingMode::Consume, &consume),
            ] {
                if count.is_zero() {
                    continue;
                }
                transition_bindings.push(resource::InputBinding {
                    transition_id: phase.identity.clone(),
                    name: encode_tuple(&[mode_name, &lot.place]),
                    place: lot.place.clone(),
                    token_type: lot.token_type.clone(),
                    identity: lot.token_target.clone(),
                    provenance: lot.provenance.clone(),
                    multiplicity: count.clone(),
                    mode,
                    required_revision: lot.revision.clone(),
                });
            }
            normalized_bindings.push(NormalizedResourceBinding {
                transition: phase.identity.clone(),
                lot: reference.clone(),
                read,
                consume,
                required_revision: lot.revision.clone(),
            });
        }
        let mut output_places = phase.outputs;
        output_places.push(next_control.clone());
        maximum_tokens += Nat::from(output_places.len() + 1);
        transitions.push(resource::TypedTransition {
            identity: phase.identity.clone(),
            input_places,
            output_places,
            failure_places: Vec::new(),
            revision: phase.revision.clone(),
        });
        bindings.extend(transition_bindings);
        execution_order.push(phase.identity.clone());
        previous_control = next_control;
        previous_target = phase.identity;
        previous_revision = phase.revision;
    }
    let cap = token_capacity(input);
    if maximum_tokens > cap {
        return Err(LoweringFailure::Unknown(
            UnresolvedObligation::ResourceCapacityBound {
                required: maximum_tokens,
                limit: cap,
            },
        ));
    }
    let mut goal = resource::GoalPredicate::PlaceHasToken {
        place: previous_control,
        target: previous_target,
        index: Nat::zero(),
        revision: previous_revision,
    };
    let (return_bindings, final_resources): (Vec<&BindingExpr>, &[ResourceGoal]) =
        match &trace.terminal {
            ReturnPlan::Success(outputs) => (
                outputs.iter().map(|(_, binding)| binding).collect(),
                if final_goals {
                    &input.goal.final_resources
                } else {
                    &[]
                },
            ),
            ReturnPlan::Failure { embedding, value } => {
                let embedding = input
                    .goal
                    .failures
                    .iter()
                    .find(|candidate| candidate.id == *embedding)
                    .ok_or_else(|| invalid("failure embedding".to_owned()))?;
                (vec![value], &embedding.final_resources)
            }
        };
    for binding in return_bindings {
        let mut sources = Vec::new();
        binding_sources(binding, &mut sources);
        for source in sources {
            let correspondence = values
                .iter()
                .find(|value| value.producer == source.producer)
                .ok_or_else(|| invalid("return value producer".to_owned()))?;
            goal = resource::GoalPredicate::And(
                Box::new(goal),
                Box::new(resource::GoalPredicate::PlaceHasToken {
                    place: correspondence.place.clone(),
                    target: correspondence.token_target.clone(),
                    index: Nat::zero(),
                    revision: correspondence.revision.clone(),
                }),
            );
            if let Some((_, Some(reference))) = declared_value(input, &source.producer) {
                let lot = lots
                    .iter()
                    .find(|lot| lot.lot == reference)
                    .ok_or_else(|| invalid("return backing lot".to_owned()))?;
                goal = resource::GoalPredicate::And(
                    Box::new(goal),
                    Box::new(resource::GoalPredicate::PlaceHasAtLeast {
                        place: lot.place.clone(),
                        count: Nat::one(),
                    }),
                );
            }
        }
    }
    for requirement in final_resources {
        let lot = lots
            .iter()
            .find(|lot| lot.lot == requirement.lot)
            .ok_or_else(|| invalid("terminal resource producer".to_owned()))?;
        if lot.revision != requirement.revision {
            return Err(invalid("terminal resource revision".to_owned()));
        }
        goal = resource::GoalPredicate::And(
            Box::new(goal),
            Box::new(resource::GoalPredicate::PlaceHasAtLeast {
                place: lot.place.clone(),
                count: requirement.multiplicity.clone(),
            }),
        );
    }
    let graph = resource::DeclarationGraph {
        places: places.iter().map(|place| place.identity.clone()).collect(),
        transitions: transitions
            .iter()
            .map(|transition| transition.identity.clone())
            .collect(),
        edges: transitions
            .iter()
            .flat_map(|transition| {
                transition
                    .input_places
                    .iter()
                    .map(|place| (place.clone(), transition.identity.clone()))
                    .chain(
                        transition
                            .output_places
                            .iter()
                            .map(|place| (transition.identity.clone(), place.clone())),
                    )
            })
            .collect(),
        revision: Nat::zero(),
    };
    let max_bindings = input
        .bounds
        .resource_bounds
        .as_ref()
        .map(|bound| bound.max_bindings.clone())
        .unwrap_or_else(|| Nat::from(bindings.len()));
    let max_search_steps = input
        .bounds
        .resource_bounds
        .as_ref()
        .map(|bound| bound.max_search_steps.clone())
        .unwrap_or_else(|| Nat::from(transitions.len() + 1));
    let bound = resource::DomainBound {
        target_identity: input.identity.clone(),
        index: Nat::zero(),
        revision: Nat::zero(),
        max_bindings,
        max_search_steps,
    };
    let lowered = resource::SolverInput {
        places,
        transitions,
        bindings,
        goal,
        graph,
        marking,
        bound,
    };
    if resource::validate(&lowered).is_some() {
        return Err(invalid("resource declaration rejected".to_owned()));
    }
    let place_identities: Vec<&str> = lowered
        .places
        .iter()
        .map(|place| place.identity.as_str())
        .collect();
    if !no_duplicates(&place_identities) {
        return Err(invalid("resource place identity collision".to_owned()));
    }
    Ok((
        lowered,
        ResourceCorrespondence {
            lots,
            values,
            normalized_bindings,
            execution_order,
        },
    ))
}

pub(crate) fn type_identity(reference: &TypeRef) -> String {
    let declared = reference
        .source
        .declared_revision
        .as_ref()
        .map(ToString::to_string)
        .unwrap_or_default();
    let has_revision = if reference.source.declared_revision.is_some() {
        "some"
    } else {
        "none"
    };
    let pointer: Vec<_> = reference.pointer.iter().map(String::as_str).collect();
    let pointer = encode_tuple(&pointer);
    encode_tuple(&[
        "type",
        &reference.source.repository,
        &reference.source.revision,
        &reference.source.path,
        &reference.source.content_digest,
        &reference.source.document_id,
        has_revision,
        &declared,
        &reference.definition_name,
        &pointer,
    ])
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceLotCorrespondence {
    pub lot: ResourceLotRef,
    pub place: String,
    pub producer: ResourceProducer,
    pub token_target: String,
    pub token_type: String,
    pub revision: Nat,
    pub quantity: Nat,
    pub provenance: String,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValueCorrespondence {
    pub producer: ProducerRef,
    pub place: String,
    pub token_target: String,
    pub revision: Nat,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NormalizedResourceBinding {
    pub transition: String,
    pub lot: ResourceLotRef,
    pub read: Nat,
    pub consume: Nat,
    pub required_revision: Nat,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceCorrespondence {
    pub lots: Vec<ResourceLotCorrespondence>,
    pub values: Vec<ValueCorrespondence>,
    pub normalized_bindings: Vec<NormalizedResourceBinding>,
    pub execution_order: Vec<String>,
}
