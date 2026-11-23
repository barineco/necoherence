// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use std::cell::RefCell;
use std::collections::VecDeque;
use std::io::{ErrorKind, Read, Write};
use std::net::{IpAddr, Shutdown, TcpStream};
use std::panic::{catch_unwind, AssertUnwindSafe};
#[cfg(test)]
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread;
use std::time::Duration;
use ureq::unversioned::resolver::{ResolvedSocketAddrs, Resolver};
use ureq::unversioned::transport::{
    Buffers, ConnectionDetails, Connector, Either, LazyBuffers, NextTimeout, Transport,
};
use ureq::Error;

thread_local! {
    static CURRENT: RefCell<Option<Arc<Interrupt>>> = const { RefCell::new(None) };
}

fn current() -> Option<Arc<Interrupt>> {
    CURRENT.with(|slot| slot.borrow().clone())
}

struct State {
    stopped: bool,
    finished: bool,
    sockets: Vec<Arc<TcpStream>>,
}

pub struct Interrupt {
    state: Mutex<State>,
    changed: Condvar,
}

fn lock(state: &Mutex<State>) -> MutexGuard<'_, State> {
    state.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Interrupt {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(State {
                stopped: false,
                finished: false,
                sockets: Vec::new(),
            }),
            changed: Condvar::new(),
        })
    }

    fn stop_locked(&self, state: &mut State) {
        if state.stopped || state.finished {
            return;
        }
        state.stopped = true;
        for socket in &state.sockets {
            let _ = socket.shutdown(Shutdown::Both);
        }
        self.changed.notify_all();
    }

    pub fn stop_after(&self, publish: impl FnOnce()) {
        let mut state = lock(&self.state);
        publish();
        self.stop_locked(&mut state);
    }

    pub fn unless_stopped(&self, publish: impl FnOnce()) {
        let state = lock(&self.state);
        if !state.stopped {
            publish();
        }
    }

    fn finish(&self) {
        let mut state = lock(&self.state);
        state.finished = true;
        state.sockets.clear();
    }

    fn is_stopped(&self) -> bool {
        lock(&self.state).stopped
    }

    fn register(&self, socket: &Arc<TcpStream>) -> bool {
        let mut state = lock(&self.state);
        if state.stopped {
            return false;
        }
        if !state.sockets.iter().any(|known| Arc::ptr_eq(known, socket)) {
            state.sockets.push(Arc::clone(socket));
        }
        true
    }

    fn poke(&self) {
        drop(lock(&self.state));
        self.changed.notify_all();
    }
}

pub struct Scope(Arc<Interrupt>);

impl Scope {
    pub fn enter(interrupt: &Arc<Interrupt>) -> Self {
        CURRENT.with(|slot| *slot.borrow_mut() = Some(Arc::clone(interrupt)));
        Self(Arc::clone(interrupt))
    }
}

impl Drop for Scope {
    fn drop(&mut self) {
        CURRENT.with(|slot| *slot.borrow_mut() = None);
        self.0.finish();
    }
}

fn aborted() -> Error {
    Error::Io(std::io::Error::new(
        ErrorKind::ConnectionAborted,
        "interrupted",
    ))
}

type BlockingJob = Box<dyn FnOnce() + Send + 'static>;

struct PoolState {
    jobs: VecDeque<BlockingJob>,
    threads: usize,
    idle: usize,
    closed: bool,
}

struct PoolShared {
    state: Mutex<PoolState>,
    wake: Condvar,
    limit: usize,
    #[cfg(test)]
    spawned: AtomicUsize,
}

pub struct BlockingPool(Arc<PoolShared>);

impl std::fmt::Debug for BlockingPool {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("BlockingPool")
            .finish_non_exhaustive()
    }
}

fn lock_pool(state: &Mutex<PoolState>) -> MutexGuard<'_, PoolState> {
    state.lock().unwrap_or_else(PoisonError::into_inner)
}

fn serve(shared: &PoolShared) {
    loop {
        let job = {
            let mut state = lock_pool(&shared.state);
            loop {
                if let Some(job) = state.jobs.pop_front() {
                    break Some(job);
                }
                if state.closed {
                    break None;
                }
                state.idle += 1;
                state = shared
                    .wake
                    .wait(state)
                    .unwrap_or_else(PoisonError::into_inner);
                state.idle -= 1;
            }
        };
        match job {
            Some(job) => {
                let _ = catch_unwind(AssertUnwindSafe(job));
            }
            None => return,
        }
    }
}

impl BlockingPool {
    pub fn new(limit: usize) -> Self {
        Self(Arc::new(PoolShared {
            state: Mutex::new(PoolState {
                jobs: VecDeque::new(),
                threads: 0,
                idle: 0,
                closed: false,
            }),
            wake: Condvar::new(),
            limit,
            #[cfg(test)]
            spawned: AtomicUsize::new(0),
        }))
    }

    fn submit(&self, job: BlockingJob) -> std::io::Result<()> {
        let mut state = lock_pool(&self.0.state);
        state.jobs.push_back(job);
        if state.jobs.len() > state.idle && state.threads < self.0.limit {
            let shared = Arc::clone(&self.0);
            match thread::Builder::new()
                .name("rust-network-blocking".to_owned())
                .spawn(move || serve(&shared))
            {
                Ok(_) => {
                    state.threads += 1;
                    #[cfg(test)]
                    self.0.spawned.fetch_add(1, Ordering::SeqCst);
                }
                Err(error) if state.threads == 0 => {
                    state.jobs.pop_back();
                    return Err(error);
                }
                Err(_) => {}
            }
        }
        self.0.wake.notify_one();
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn spawned(&self) -> usize {
        self.0.spawned.load(Ordering::SeqCst)
    }

    #[cfg(test)]
    pub(crate) fn queued(&self) -> usize {
        lock_pool(&self.0.state).jobs.len()
    }

    #[cfg(test)]
    pub(crate) fn limit(&self) -> usize {
        self.0.limit
    }
}

impl Drop for BlockingPool {
    fn drop(&mut self) {
        lock_pool(&self.0.state).closed = true;
        self.0.wake.notify_all();
    }
}

fn off_thread<T: Send + 'static>(
    pool: &BlockingPool,
    work: impl FnOnce() -> T + Send + 'static,
) -> Result<T, Error> {
    let Some(interrupt) = current() else {
        return Ok(work());
    };
    let slot: Arc<Mutex<Option<std::thread::Result<T>>>> = Arc::new(Mutex::new(None));
    let theirs = Arc::clone(&slot);
    let wake = Arc::clone(&interrupt);
    pool.submit(Box::new(move || {
        if wake.is_stopped() {
            return;
        }
        let value = std::panic::catch_unwind(std::panic::AssertUnwindSafe(work));
        *theirs.lock().unwrap_or_else(PoisonError::into_inner) = Some(value);
        wake.poke();
    }))
    .map_err(Error::Io)?;
    let mut state = lock(&interrupt.state);
    loop {
        if state.stopped {
            return Err(aborted());
        }
        if let Some(value) = slot.lock().unwrap_or_else(PoisonError::into_inner).take() {
            return match value {
                Ok(value) => Ok(value),
                Err(payload) => std::panic::resume_unwind(payload),
            };
        }
        state = interrupt
            .changed
            .wait(state)
            .unwrap_or_else(PoisonError::into_inner);
    }
}

fn socket_failure(error: std::io::Error, timeout: NextTimeout) -> Error {
    if matches!(error.kind(), ErrorKind::TimedOut | ErrorKind::WouldBlock) {
        Error::Timeout(timeout.reason)
    } else {
        Error::Io(error)
    }
}

#[derive(Debug)]
pub struct InterruptTransport {
    stream: TcpStream,
    socket: Arc<TcpStream>,
    buffers: LazyBuffers,
    read_timeout: Option<Duration>,
    write_timeout: Option<Duration>,
    broken: bool,
}

impl InterruptTransport {
    fn enter(&mut self) -> Result<(), Error> {
        if self.broken {
            return Err(aborted());
        }
        if let Some(interrupt) = current() {
            if !interrupt.register(&self.socket) {
                self.broken = true;
                return Err(aborted());
            }
        }
        Ok(())
    }

    fn leave(&mut self) {
        if current().is_some_and(|interrupt| interrupt.is_stopped()) {
            self.broken = true;
        }
    }

    fn transmit(&mut self, amount: usize, timeout: NextTimeout) -> Result<(), Error> {
        let wanted = timeout.not_zero().map(|limit| *limit);
        if wanted != self.write_timeout {
            self.stream.set_write_timeout(wanted)?;
            self.write_timeout = wanted;
        }
        let output = self.buffers.output().get(..amount).unwrap_or_default();
        self.stream
            .write_all(output)
            .map_err(|error| socket_failure(error, timeout))
    }

    fn receive(&mut self, timeout: NextTimeout) -> Result<bool, Error> {
        let wanted = timeout.not_zero().map(|limit| *limit);
        if wanted != self.read_timeout {
            self.stream.set_read_timeout(wanted)?;
            self.read_timeout = wanted;
        }
        let amount = self
            .stream
            .read(self.buffers.input_append_buf())
            .map_err(|error| socket_failure(error, timeout))?;
        self.buffers.input_appended(amount);
        Ok(amount > 0)
    }

    fn idle_and_open(&mut self) -> bool {
        if self.stream.set_nonblocking(true).is_err() {
            return false;
        }
        let mut probe = [0u8];
        match self.stream.read(&mut probe) {
            Err(error) if error.kind() == ErrorKind::WouldBlock => {}
            Ok(_) | Err(_) => return false,
        }
        self.stream.set_nonblocking(false).is_ok()
    }
}

impl Transport for InterruptTransport {
    fn buffers(&mut self) -> &mut dyn Buffers {
        &mut self.buffers
    }

    fn transmit_output(&mut self, amount: usize, timeout: NextTimeout) -> Result<(), Error> {
        self.enter()?;
        let result = self.transmit(amount, timeout);
        self.leave();
        result
    }

    fn await_input(&mut self, timeout: NextTimeout) -> Result<bool, Error> {
        self.enter()?;
        let result = self.receive(timeout);
        self.leave();
        result
    }

    fn is_open(&mut self) -> bool {
        !self.broken && self.idle_and_open()
    }
}

#[cfg(test)]
type Dial = Arc<dyn Fn(std::net::SocketAddr) -> std::io::Result<TcpStream> + Send + Sync + 'static>;

#[derive(Debug)]
pub struct InterruptibleTcp {
    pool: Arc<BlockingPool>,
    #[cfg(test)]
    dial: DialFn,
}

#[cfg(test)]
struct DialFn(Dial);

#[cfg(test)]
impl std::fmt::Debug for DialFn {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("DialFn")
    }
}

impl InterruptibleTcp {
    pub fn new(pool: Arc<BlockingPool>) -> Self {
        Self {
            pool,
            #[cfg(test)]
            dial: DialFn(Arc::new(TcpStream::connect)),
        }
    }

    #[cfg(test)]
    pub(super) fn dialing(
        mut self,
        dial: impl Fn(std::net::SocketAddr) -> std::io::Result<TcpStream> + Send + Sync + 'static,
    ) -> Self {
        self.dial = DialFn(Arc::new(dial));
        self
    }
}

fn address_specific(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        ErrorKind::ConnectionRefused
            | ErrorKind::HostUnreachable
            | ErrorKind::NetworkUnreachable
            | ErrorKind::AddrNotAvailable
    )
}

impl<In: Transport> Connector<In> for InterruptibleTcp {
    type Out = Either<In, InterruptTransport>;

    fn connect(
        &self,
        details: &ConnectionDetails,
        chained: Option<In>,
    ) -> Result<Option<Self::Out>, Error> {
        if chained.is_some() {
            return Ok(chained.map(Either::A));
        }
        let config = details.config;
        let mut last = None;
        for address in &details.addrs {
            let address = *address;
            #[cfg(test)]
            let dial = Arc::clone(&self.dial.0);
            #[cfg(not(test))]
            let dial = TcpStream::connect::<std::net::SocketAddr>;
            match off_thread(&self.pool, move || dial(address))? {
                Ok(stream) => {
                    if config.no_delay() {
                        stream.set_nodelay(true)?;
                    }
                    let socket = Arc::new(stream.try_clone()?);
                    return Ok(Some(Either::B(InterruptTransport {
                        stream,
                        socket,
                        buffers: LazyBuffers::new(
                            config.input_buffer_size(),
                            config.output_buffer_size(),
                        ),
                        read_timeout: None,
                        write_timeout: None,
                        broken: false,
                    })));
                }
                Err(error) if address_specific(&error) => last = Some(error),
                Err(error) => return Err(Error::Io(error)),
            }
        }
        Err(Error::Io(last.unwrap_or_else(|| {
            std::io::Error::from(ErrorKind::ConnectionRefused)
        })))
    }
}

#[derive(Debug)]
pub struct InterruptibleResolver<R>(Arc<R>, Arc<BlockingPool>);

impl<R: Resolver> InterruptibleResolver<R> {
    pub fn new(inner: R, pool: Arc<BlockingPool>) -> Self {
        Self(Arc::new(inner), pool)
    }
}

fn is_address_literal(uri: &ureq::http::Uri) -> bool {
    uri.host().is_some_and(|host| {
        host.trim_start_matches('[')
            .trim_end_matches(']')
            .parse::<IpAddr>()
            .is_ok()
    })
}

impl<R: Resolver> Resolver for InterruptibleResolver<R> {
    fn resolve(
        &self,
        uri: &ureq::http::Uri,
        config: &ureq::config::Config,
        timeout: NextTimeout,
    ) -> Result<ResolvedSocketAddrs, Error> {
        if is_address_literal(uri) {
            return self.0.resolve(uri, config, timeout);
        }
        let inner = Arc::clone(&self.0);
        let uri = uri.clone();
        let config = config.clone();
        off_thread(&self.1, move || inner.resolve(&uri, &config, timeout))?
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    type TestResult<T = ()> = Result<T, Box<dyn std::error::Error>>;

    fn pair() -> TestResult<(Arc<TcpStream>, TcpStream)> {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let client = TcpStream::connect(listener.local_addr()?)?;
        let (server, _) = listener.accept()?;
        Ok((Arc::new(client), server))
    }

    #[test]
    fn stopping_twice_equals_stopping_once() -> TestResult {
        let (client, mut server) = pair()?;
        let interrupt = Interrupt::new();
        assert!(interrupt.register(&client));
        interrupt.stop_after(|| {});
        interrupt.stop_after(|| {});
        assert!(interrupt.is_stopped());
        assert!(!interrupt.register(&client));
        let mut byte = [0u8];
        assert_eq!(server.read(&mut byte)?, 0);
        let mut once = 0usize;
        interrupt.unless_stopped(|| once += 1);
        assert_eq!(once, 0);
        Ok(())
    }

    #[test]
    fn stopping_a_finished_worker_does_nothing() -> TestResult {
        let (client, mut server) = pair()?;
        let interrupt = Interrupt::new();
        assert!(interrupt.register(&client));
        interrupt.finish();
        interrupt.stop_after(|| {});
        interrupt.stop_after(|| {});
        assert!(!interrupt.is_stopped());
        let mut writer: &TcpStream = &client;
        writer.write_all(b"x")?;
        let mut byte = [0u8];
        assert_eq!(server.read(&mut byte)?, 1);
        Ok(())
    }
}
