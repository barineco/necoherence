// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(
    clippy::expect_used,
    clippy::panic,
    clippy::result_large_err,
    clippy::unwrap_used
)]

#[path = "../../../../packages/rust/adapter/tests/fixtures/semantic_execution_samples.rs"]
#[allow(dead_code, unused_imports)]
mod samples;

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::{Cell, RefCell};
use std::sync::Arc;

use necoherence::network_effect::*;
use necoherence::request_progression::ExecutionHandle;
use necoherence::semantic_composition as composition;
use necoherence::semantic_execution as execution;
use necoherence::semantic_types::*;
use samples::{
    attempt_input, http_argument_provider, http_pair_provider, http_provider,
    pure_argument_provider, pure_pair_provider, pure_provider, response,
};

thread_local! {
    static COUNTING: Cell<bool> = const { Cell::new(false) };
    static ALLOCATIONS: Cell<usize> = const { Cell::new(0) };
    static SITES: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
}

struct ProbeAllocator;

fn note_allocation() {
    if !COUNTING
        .try_with(|counting| counting.get())
        .unwrap_or(false)
    {
        return;
    }
    let _ = COUNTING.try_with(|counting| counting.set(false));
    let _ = ALLOCATIONS.try_with(|count| count.set(count.get() + 1));
    let trace = std::backtrace::Backtrace::force_capture().to_string();
    let site = first_necoherence_frame(&trace);
    let _ = SITES.try_with(|sites| sites.borrow_mut().push(site));
    let _ = COUNTING.try_with(|counting| counting.set(true));
}

fn first_necoherence_frame(trace: &str) -> String {
    let mut lines = trace.lines();
    while let Some(line) = lines.next() {
        let Some((_, symbol)) = line.split_once(": ") else {
            continue;
        };
        let symbol = symbol.trim();
        if !symbol.starts_with("necoherence::") {
            continue;
        }
        let location = lines
            .next()
            .map(|next| next.trim().trim_start_matches("at ").to_string())
            .unwrap_or_default();
        return format!("{symbol} @ {location}");
    }
    let top: Vec<&str> = trace
        .lines()
        .filter(|line| line.contains(": "))
        .filter(|line| {
            !line.contains("backtrace")
                && !line.contains("note_allocation")
                && !line.contains("__rust_")
                && !line.contains("GlobalAlloc")
        })
        .take(4)
        .collect();
    format!("outside necoherence: {}", top.join(" | "))
}

unsafe impl GlobalAlloc for ProbeAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        note_allocation();
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        note_allocation();
        unsafe { System.alloc_zeroed(layout) }
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        note_allocation();
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: ProbeAllocator = ProbeAllocator;

fn counted<T>(window: impl FnOnce() -> T) -> (T, usize, Vec<String>) {
    ALLOCATIONS.with(|count| count.set(0));
    SITES.with(|sites| sites.borrow_mut().clear());
    COUNTING.with(|counting| counting.set(true));
    let result = window();
    COUNTING.with(|counting| counting.set(false));
    let count = ALLOCATIONS.with(|count| count.get());
    let sites = SITES.with(|sites| std::mem::take(&mut *sites.borrow_mut()));
    (result, count, sites)
}

fn paused<T>(call: impl FnOnce() -> T) -> T {
    let was_counting = COUNTING.with(|counting| counting.replace(false));
    let result = call();
    COUNTING.with(|counting| counting.set(was_counting));
    result
}

fn paused_provider(provider: execution::Provider) -> execution::Provider {
    let execution::Provider {
        reference,
        implementation,
    } = provider;
    let implementation = match implementation {
        execution::ProviderImplementation::Pure(callback) => {
            execution::ProviderImplementation::Pure(Arc::new(move |arguments| {
                paused(|| callback(arguments))
            }))
        }
        execution::ProviderImplementation::PreparedHttp(owner) => {
            let prepare = owner.prepare;
            let decode = owner.decode;
            execution::ProviderImplementation::PreparedHttp(execution::PreparedNetworkOwner {
                prepare: Arc::new(move |arguments| paused(|| prepare(arguments))),
                decode: Arc::new(move |response| paused(|| decode(response))),
            })
        }
    };
    execution::Provider {
        reference,
        implementation,
    }
}

fn report(window: &str, count: usize, sites: &[String]) {
    println!("STATE_MACHINE window={window} allocations={count}");
    for site in sites {
        println!("STATE_MACHINE site window={window} {site}");
    }
}

#[test]
fn state_machine_windows_between_suspensions_do_not_allocate() {
    let pure_text = samples::admitted(samples::PURE);
    let pure_preparation = pure_text.prepare_admission().unwrap().unwrap();
    let pure_reference = samples::operation_reference(pure_preparation.prepared());
    let pure_checked_run = execution::PreparedRun::new(pure_preparation.admitted());
    let provider = paused_provider(pure_provider(
        &pure_reference,
        "success",
        SlotValue::Present(JsonValue::Bool(true)),
    ));
    let pure_checked_workspace = pure_checked_run.workspace();
    let providers = vec![provider];
    let arguments = vec![samples::argument_true()];
    let (pure, pure_count, pure_sites) = counted(|| {
        execution::start(
            &pure_checked_run,
            pure_checked_workspace,
            providers,
            arguments,
            NetworkState::default(),
        )
    });
    assert!(matches!(
        pure,
        Ok(execution::Progress::Completed(
            execution::ExecutionResult::Success(_),
            _
        ))
    ));
    report("pure start to completion", pure_count, &pure_sites);

    let http_text = samples::admitted(samples::HTTP);
    let http_preparation = http_text.prepare_admission().unwrap().unwrap();
    let http_reference = samples::operation_reference(http_preparation.prepared());
    let http_checked_run = execution::PreparedRun::new(http_preparation.admitted());
    let provider = paused_provider(http_provider(&http_reference));
    let http_checked_workspace = http_checked_run.workspace();
    let providers = vec![provider];
    let arguments = vec![samples::argument_true()];
    let network = NetworkState::with_capacity(1);
    let (started, start_count, start_sites) = counted(|| {
        execution::start(
            &http_checked_run,
            http_checked_workspace,
            providers,
            arguments,
            network,
        )
    });
    let Ok(execution::Progress::Pending(pending_start, execution::NetworkInstruction::Send)) =
        started
    else {
        panic!("HTTP execution must request send");
    };
    report("http start to send", start_count, &start_sites);

    let attempt = pending_start
        .send_command()
        .unwrap()
        .prepared
        .input
        .attempt
        .clone();
    let observation = execution::ExecutionObservation::Start(StartObservation::Started {
        attempt,
        handle: ExecutionHandle { value: "h".into() },
    });
    let (observed, observe_count, observe_sites) =
        counted(|| execution::resume(pending_start, observation));
    let Ok(execution::Progress::Pending(pending_response, execution::NetworkInstruction::Observe)) =
        observed
    else {
        panic!("start observation must request response observation");
    };
    let observed_start = pending_response.observed_attempt().unwrap().clone();
    report(
        "http start observation to observe",
        observe_count,
        &observe_sites,
    );

    let delivered = execution::ExecutionObservation::Host(HostObservation::Delivered {
        delivery: 0u8.into(),
        observation: response(&observed_start),
    });
    let (completed, complete_count, complete_sites) =
        counted(|| execution::resume(pending_response, delivered));
    assert!(matches!(
        completed,
        Ok(execution::Progress::Completed(
            execution::ExecutionResult::Success(_),
            _
        ))
    ));
    report(
        "http response observation to completion",
        complete_count,
        &complete_sites,
    );

    let argument_text = samples::admitted(samples::PURE);
    let argument_preparation = argument_text.prepare_admission().unwrap().unwrap();
    let argument_reference = samples::operation_reference(argument_preparation.prepared());
    let argument_run = execution::PreparedRun::new(argument_preparation.admitted());
    let argument_workspace = argument_run.workspace();
    let arguments = vec![(
        composition::InputId("argument".into()),
        SlotValue::Present(JsonValue::Bool(true)),
    )];
    let providers = vec![paused_provider(pure_argument_provider(&argument_reference))];
    let network = NetworkState::default();
    let (argued, argued_count, argued_sites) = counted(|| {
        execution::start(
            &argument_run,
            argument_workspace,
            providers,
            arguments,
            network,
        )
    });
    assert!(matches!(
        argued,
        Ok(execution::Progress::Completed(
            execution::ExecutionResult::Success(_),
            _
        ))
    ));
    report(
        "pure invoke with argument start to completion",
        argued_count,
        &argued_sites,
    );

    let http_argument_text = samples::admitted(samples::HTTP);
    let http_argument_preparation = http_argument_text.prepare_admission().unwrap().unwrap();
    let http_argument_reference =
        samples::operation_reference(http_argument_preparation.prepared());
    let http_argument_run = execution::PreparedRun::new(http_argument_preparation.admitted());
    let http_argument_workspace = http_argument_run.workspace();
    let arguments = vec![(
        composition::InputId("argument".into()),
        SlotValue::Present(JsonValue::Bool(true)),
    )];
    let providers = vec![paused_provider(http_argument_provider(
        &http_argument_reference,
    ))];
    let network = NetworkState::with_capacity(1);
    let (argued_started, argued_start_count, argued_start_sites) = counted(|| {
        execution::start(
            &http_argument_run,
            http_argument_workspace,
            providers,
            arguments,
            network,
        )
    });
    assert!(matches!(
        argued_started,
        Ok(execution::Progress::Pending(
            _,
            execution::NetworkInstruction::Send
        ))
    ));
    report(
        "http invoke with argument start to send",
        argued_start_count,
        &argued_start_sites,
    );

    let pair_text = samples::admitted(samples::PAIR);
    let pair_preparation = pair_text.prepare_admission().unwrap().unwrap();
    let pair_reference = samples::operation_reference(pair_preparation.prepared());
    let pair_run = execution::PreparedRun::new(pair_preparation.admitted());
    let pair_workspace = pair_run.workspace();
    let arguments = vec![
        (
            composition::InputId("left".into()),
            SlotValue::Present(JsonValue::Bool(true)),
        ),
        (
            composition::InputId("right".into()),
            SlotValue::Present(JsonValue::Bool(true)),
        ),
    ];
    let providers = vec![paused_provider(pure_pair_provider(&pair_reference))];
    let network = NetworkState::default();
    let (paired, pair_count, pair_sites) =
        counted(|| execution::start(&pair_run, pair_workspace, providers, arguments, network));
    assert!(matches!(
        paired,
        Ok(execution::Progress::Completed(
            execution::ExecutionResult::Success(_),
            _
        ))
    ));
    report(
        "pure invoke with pair input start to completion",
        pair_count,
        &pair_sites,
    );

    let http_pair_text = samples::admitted(samples::PAIR_HTTP);
    let http_pair_preparation = http_pair_text.prepare_admission().unwrap().unwrap();
    let http_pair_reference = samples::operation_reference(http_pair_preparation.prepared());
    let http_pair_run = execution::PreparedRun::new(http_pair_preparation.admitted());
    let http_pair_workspace = http_pair_run.workspace();
    let arguments = vec![
        (
            composition::InputId("left".into()),
            SlotValue::Present(JsonValue::Bool(true)),
        ),
        (
            composition::InputId("right".into()),
            SlotValue::Present(JsonValue::Bool(true)),
        ),
    ];
    let providers = vec![paused_provider(http_pair_provider(&http_pair_reference))];
    let network = NetworkState::with_capacity(1);
    let (pair_started, pair_start_count, pair_start_sites) = counted(|| {
        execution::start(
            &http_pair_run,
            http_pair_workspace,
            providers,
            arguments,
            network,
        )
    });
    assert!(matches!(
        pair_started,
        Ok(execution::Progress::Pending(
            _,
            execution::NetworkInstruction::Send
        ))
    ));
    report(
        "http invoke with pair input start to send",
        pair_start_count,
        &pair_start_sites,
    );

    assert_eq!(
        [
            pure_count,
            start_count,
            observe_count,
            complete_count,
            argued_count,
            argued_start_count,
            pair_count,
            pair_start_count,
        ],
        [0, 0, 0, 0, 0, 0, 0, 0],
        "core state machine windows allocate between suspensions"
    );
}

fn network_effect_sites(sites: &[String]) -> Vec<&String> {
    sites
        .iter()
        .filter(|site| site.starts_with("necoherence::network_effect"))
        .collect()
}

#[test]
fn network_effect_operations_do_not_allocate_in_network_effect() {
    let input = Arc::new(attempt_input());
    let state = NetworkState::with_capacity(1);

    let (prepared_step, prepare_count, prepare_sites) =
        counted(|| prepare(state, Arc::clone(&input)));
    let PrepareStep::Prepared(state, prepared) = prepared_step else {
        panic!("root attempt must be prepared");
    };
    report("network effect prepare", prepare_count, &prepare_sites);

    let (sent, send_count, send_sites) = counted(|| send_command(state, prepared));
    let CommandStep::CommandReady(state, command) = sent else {
        panic!("prepared attempt must be ready to send");
    };
    report("network effect send_command", send_count, &send_sites);

    let attempt = command.prepared.input.attempt.clone();
    let started_observation = StartObservation::Started {
        attempt,
        handle: ExecutionHandle { value: "h".into() },
    };
    let (started_step, start_count, start_sites) =
        counted(|| observe_start(state, command.prepared, started_observation));
    let NetworkStep::Started(state, started) = started_step else {
        panic!("start observation must start the attempt");
    };
    report("network effect observe_start", start_count, &start_sites);

    let delivered = HostObservation::Delivered {
        delivery: 0u8.into(),
        observation: response(&started),
    };
    let (delivered_step, delivery_count, delivery_sites) = counted(|| observe(state, delivered));
    assert!(matches!(delivered_step, NetworkStep::Terminal(_, _)));
    report(
        "network effect first delivery observation",
        delivery_count,
        &delivery_sites,
    );

    assert_eq!(
        network_effect_sites(&prepare_sites),
        Vec::<&String>::new(),
        "prepare allocates inside network_effect"
    );
    assert_eq!(
        network_effect_sites(&delivery_sites),
        Vec::<&String>::new(),
        "delivery observation allocates inside network_effect"
    );
}
