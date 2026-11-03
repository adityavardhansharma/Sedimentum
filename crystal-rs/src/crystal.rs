//! Crystal: agent memory that keeps what is true.
//!
//! Every memory is an ordinal (its place in the order this index read it),
//! and everything about it lives in flat arrays indexed by that ordinal or
//! by a word's number. Nothing in RAM is a pointer, a tree or a cache.
//!
//!   Lexicon   word (a u64, see words.rs) -> term id; per term its count
//!             and its postings. A word seen c times in N memories carries
//!             log2(N/c) bits, which is what ranking credits it.
//!   Postings  per term (and per scope), the ordinals that contain it, in
//!             blocks that double from 2 to 1024 entries, newest last. A
//!             word common enough to carry under 10 bits keeps no postings.
//!   Timeline  per ordinal: where its record is, its scope and flags.
//!   Facts     every version of a fact joins one cell; the cell names its
//!             newest version, which is the only one recall answers with.
//!   Lanes     one append-only file per writer process, the only source of
//!             truth. Text is entropy-coded with the lane's own word model.
//!
//! Concurrency: one writer at a time per process (a short spin-then-futex
//! lock); readers never lock. Arrays live in reserved address space and
//! never move; maps that grow are swapped and the old table is freed once
//! no reader can hold it. Fields only the writer touches live in `WState`
//! behind an `UnsafeCell`, used only with the write lock held.
//!
//! Changes from the Zig engine (see README):
//!   1. Durable writes: the lane is grown ahead by a background thread (so
//!      no writer zero-fills and fsyncs under the lock), and concurrent
//!      `sync` calls share one flush (group commit).
//!   2. Search: posting lists are merged (they are already sorted) instead
//!      of sorting every (memory, word) pair; liveness and scope checks
//!      run only for candidates actually considered; the rarest words are
//!      tried first and common words are skipped when they cannot change
//!      the top results.
//!   3. Reopen: the snapshot is trusted after its checksummed header;
//!      entries are bounds-checked when used instead of all at open.
//!   4. Writes never stop to read other writers' lanes; reads do.

use crate::ans::{self, Model};
use crate::hash::{hash, Crc32c};
use crate::meaning::{Meaning, Related};
use crate::words::{self, Terms, Word, TERMS_CAP};
use std::cell::{RefCell, UnsafeCell};
use std::fs::{File, OpenOptions};
use std::io::Write as _;
use std::marker::PhantomData;
use std::os::fd::AsRawFd;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::ptr::{self, addr_of_mut};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicPtr, AtomicU32, AtomicU64, AtomicUsize, Ordering::*};
use std::sync::{Arc, LazyLock, Mutex, OnceLock};
use std::time::{Duration, Instant};

// ------------------------------------------------------------------ format

const PAGE: usize = 4096;
pub const MAX_LANES: usize = 64;
const DATA_START: u64 = 4096;
const MAP_RESERVE: usize = 1 << 36;
const LANE_MAGIC: &[u8; 8] = b"CRYSRS01";
const FORMAT_VERSION: u32 = 1;
const PUB_END_AT: usize = 128;
const LANE_SHIFT: u32 = 40;
const GROW_MIN: u64 = 4 << 20;
const GROW_MAX: u64 = 32 << 20;
const MAX_MODELS: usize = 255;
const MAX_TEXT: u32 = 64 << 20;

const K_MEMORY: u8 = 1;
const K_SCOPE: u8 = 2;
const K_MODEL: u8 = 3;
const K_FORGET_SCOPE: u8 = 4;
const K_FORGET_ONE: u8 = 5;
const K_SETTLE: u8 = 6;
const ERASED_BIT: u8 = 0x80;

#[inline]
fn id_of(lane: usize, off: u64) -> u64 {
    ((lane as u64) << LANE_SHIFT) | off
}
#[inline]
fn lane_of(id: u64) -> usize {
    (id >> LANE_SHIFT) as usize
}
#[inline]
fn off_of(id: u64) -> u64 {
    id & ((1u64 << LANE_SHIFT) - 1)
}
#[inline]
fn align_up(x: u64, a: u64) -> u64 {
    (x + a - 1) / a * a
}
#[inline]
fn align_down(x: u64, a: u64) -> u64 {
    x / a * a
}

#[derive(Debug)]
pub enum Error {
    Io(std::io::Error),
    Corrupt,
    UnsupportedFormat,
    IndexFull,
    LaneFull,
    TooManyWriters,
    InvalidScope,
    InvalidSubject,
    TooLarge,
    Broken,
    NotFound,
    FlushFailed,
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}
impl From<ans::Corrupt> for Error {
    fn from(_: ans::Corrupt) -> Self {
        Error::Corrupt
    }
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}", self)
    }
}
impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

/// A record as stored: u32 length, u32 CRC-32C (over the length and every
/// byte from 9 up to the text), a kind byte (its top bit marks erased text,
/// so erasing never breaks the checksum), then the kind's fields.
/// A memory: varint time, scope ref, subject length, model, text length,
/// link (target id + 1, 0 none), then u32 text CRC, subject, coded text.
#[derive(Clone, Copy)]
struct Rec<'a> {
    len: u32,
    kind: u8,
    erased: bool,
    body: &'a [u8],
    time: u64,
    scope_ref: u32,
    model: u32,
    raw_len: u32,
    link: u64,
    text_crc: u32,
    subject: &'a [u8],
    text: &'a [u8],
    text_at: u32,
}

fn parse_rec(b: &[u8]) -> Option<Rec<'_>> {
    if b.len() < 9 {
        return None;
    }
    let len = u32::from_le_bytes(b[0..4].try_into().unwrap());
    if len < 9 || len as usize > b.len() {
        return None;
    }
    let r = &b[..len as usize];
    let kb = r[8];
    let mut rec = Rec { len, kind: kb & 0x7f, erased: kb & ERASED_BIT != 0, body: &r[9..], time: 0, scope_ref: 0, model: 0, raw_len: 0, link: 0, text_crc: 0, subject: &[], text: &[], text_at: 0 };
    let mut meta_end = len as usize;
    if rec.kind == K_MEMORY {
        let mut p = 9usize;
        rec.time = ans::get_varint(r, &mut p).ok()?;
        rec.scope_ref = u32::try_from(ans::get_varint(r, &mut p).ok()?).ok()?;
        let sl = ans::get_varint(r, &mut p).ok()?;
        rec.model = u32::try_from(ans::get_varint(r, &mut p).ok()?).ok()?;
        rec.raw_len = u32::try_from(ans::get_varint(r, &mut p).ok()?).ok()?;
        rec.link = ans::get_varint(r, &mut p).ok()?;
        if p + 4 > len as usize || sl > (len as usize - p - 4) as u64 {
            return None;
        }
        rec.text_crc = u32::from_le_bytes(r[p..p + 4].try_into().unwrap());
        p += 4;
        rec.subject = &r[p..p + sl as usize];
        p += sl as usize;
        meta_end = p;
        rec.text_at = p as u32;
        rec.text = &r[p..];
        if rec.raw_len > MAX_TEXT {
            return None;
        }
    }
    let mut c = Crc32c::new();
    c.update(&r[0..4]);
    c.update(&r[9..meta_end]);
    if c.finish() != u32::from_le_bytes(r[4..8].try_into().unwrap()) {
        return None;
    }
    Some(rec)
}

/// Writes the length and checksum of a record built in `r`.
fn seal(r: &mut [u8], meta_end: usize) {
    let len = r.len() as u32;
    r[0..4].copy_from_slice(&len.to_le_bytes());
    let mut c = Crc32c::new();
    c.update(&r[0..4]);
    c.update(&r[9..meta_end]);
    let v = c.finish();
    r[4..8].copy_from_slice(&v.to_le_bytes());
}

// ------------------------------------------------------------ OS helpers

fn os_err() -> Error {
    Error::Io(std::io::Error::last_os_error())
}

/// Address space for an array, committed a 4 KB page at a time as touched.
fn reserve_anon(at: *mut u8, len: usize) -> Result<*mut u8> {
    let mut flags = libc::MAP_PRIVATE | libc::MAP_ANONYMOUS | libc::MAP_NORESERVE;
    if !at.is_null() {
        flags |= libc::MAP_FIXED;
    }
    // SAFETY: plain anonymous mapping (or replacing our own mapping).
    let m = unsafe { libc::mmap(at as *mut libc::c_void, len, libc::PROT_READ | libc::PROT_WRITE, flags, -1, 0) };
    if m == libc::MAP_FAILED {
        return Err(os_err());
    }
    unsafe { libc::madvise(m, len, libc::MADV_NOHUGEPAGE) };
    Ok(m as *mut u8)
}

fn unmap(p: *mut u8, len: usize) {
    if !p.is_null() && len > 0 {
        unsafe { libc::munmap(p as *mut libc::c_void, len) };
    }
}

fn futex_wait(a: &AtomicU32, expected: u32, timeout: Option<Duration>) {
    let ts;
    let tsp = match timeout {
        Some(d) => {
            ts = libc::timespec { tv_sec: d.as_secs() as libc::time_t, tv_nsec: d.subsec_nanos() as libc::c_long };
            &ts as *const libc::timespec
        }
        None => ptr::null(),
    };
    unsafe { libc::syscall(libc::SYS_futex, a.as_ptr(), libc::FUTEX_WAIT | libc::FUTEX_PRIVATE_FLAG, expected, tsp) };
}

fn futex_wake(a: &AtomicU32, n: i32) {
    unsafe { libc::syscall(libc::SYS_futex, a.as_ptr(), libc::FUTEX_WAKE | libc::FUTEX_PRIVATE_FLAG, n) };
}

fn flock(f: &File, op: i32) -> std::io::Result<()> {
    if unsafe { libc::flock(f.as_raw_fd(), op) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

#[inline]
fn ld32(p: *const u32) -> u32 {
    unsafe { AtomicU32::from_ptr(p as *mut u32).load(Acquire) }
}
#[inline]
fn st32(p: *mut u32, v: u32) {
    unsafe { AtomicU32::from_ptr(p).store(v, Release) }
}
#[inline]
fn ld64(p: *const u64) -> u64 {
    unsafe { AtomicU64::from_ptr(p as *mut u64).load(Acquire) }
}
#[inline]
fn st64(p: *mut u64, v: u64) {
    unsafe { AtomicU64::from_ptr(p).store(v, Release) }
}

// ------------------------------------------------------------ flat arrays

/// An array in its own reserved stretch of address space: it never moves,
/// so readers index it without locks while one writer appends.
struct FlatVec<T> {
    mem: *mut u8,
    bytes: usize,
    len: AtomicUsize,
    _t: PhantomData<T>,
}
unsafe impl<T> Send for FlatVec<T> {}
unsafe impl<T> Sync for FlatVec<T> {}

#[derive(Clone, Copy)]
struct AnyVec<'a> {
    mem: *mut u8,
    bytes: usize,
    len: &'a AtomicUsize,
    size: usize,
}

impl<T: Copy> FlatVec<T> {
    fn new(cap: usize) -> Result<Self> {
        let bytes = align_up((cap * std::mem::size_of::<T>()) as u64, PAGE as u64) as usize;
        Ok(FlatVec { mem: reserve_anon(ptr::null_mut(), bytes)?, bytes, len: AtomicUsize::new(0), _t: PhantomData })
    }
    #[inline(always)]
    fn p(&self) -> *mut T {
        self.mem as *mut T
    }
    #[inline(always)]
    fn count(&self) -> usize {
        self.len.load(Acquire)
    }
    #[inline(always)]
    fn get(&self, i: usize) -> T {
        unsafe { self.p().add(i).read() }
    }
    #[inline(always)]
    fn at(&self, i: usize) -> *mut T {
        unsafe { self.p().add(i) }
    }
    /// Writer only.
    fn push(&self, x: T) -> Result<u32> {
        let n = self.len.load(Relaxed);
        if (n + 1) * std::mem::size_of::<T>() > self.bytes {
            return Err(Error::IndexFull);
        }
        unsafe { self.p().add(n).write(x) };
        self.len.store(n + 1, Release);
        Ok(n as u32)
    }
    /// Adds `k` zeroed elements; returns the first. Writer only.
    fn extend(&self, k: usize) -> Result<u32> {
        let n = self.len.load(Relaxed);
        if (n + k) * std::mem::size_of::<T>() > self.bytes {
            return Err(Error::IndexFull);
        }
        unsafe { ptr::write_bytes(self.p().add(n), 0, k) };
        self.len.store(n + k, Release);
        Ok(n as u32)
    }
    #[inline]
    fn items(&self) -> &[T] {
        unsafe { std::slice::from_raw_parts(self.p(), self.count()) }
    }
    #[allow(clippy::mut_from_ref)]
    fn items_mut(&self) -> &mut [T] {
        unsafe { std::slice::from_raw_parts_mut(self.p(), self.count()) }
    }
    /// Empties it, giving back its pages (also pages mapped from disk).
    fn reset(&self) -> Result<()> {
        reserve_anon(self.mem, self.bytes)?;
        self.len.store(0, Release);
        Ok(())
    }
    fn any(&self) -> AnyVec<'_> {
        AnyVec { mem: self.mem, bytes: self.bytes, len: &self.len, size: std::mem::size_of::<T>() }
    }
}

impl<T> Drop for FlatVec<T> {
    fn drop(&mut self) {
        unmap(self.mem, self.bytes);
    }
}

/// u64 -> u64, insert and update. Readers: `get`, lock-free. One writer.
struct Table {
    shift: u32,
    cap: usize,
    mem: *mut u8,
    bytes: usize,
}
impl Table {
    #[inline(always)]
    fn keys(&self) -> *mut u64 {
        self.mem as *mut u64
    }
    #[inline(always)]
    fn vals(&self) -> *mut u64 {
        unsafe { (self.mem as *mut u64).add(self.cap) }
    }
    #[inline(always)]
    fn slot_of(&self, e: u64) -> usize {
        (e.wrapping_mul(0x9E37_79B9_7F4A_7C15) >> self.shift) as usize
    }
}

struct Map {
    table: AtomicPtr<Table>,
    len: AtomicUsize,
    retired: UnsafeCell<Vec<*mut Table>>,
}
unsafe impl Sync for Map {}
unsafe impl Send for Map {}

impl Map {
    fn new() -> Self {
        Map { table: AtomicPtr::new(ptr::null_mut()), len: AtomicUsize::new(0), retired: UnsafeCell::new(Vec::new()) }
    }
    #[inline(always)]
    fn enc(k: u64) -> u64 {
        if k == u64::MAX {
            k
        } else {
            k + 1
        }
    }

    #[inline]
    fn get(&self, k: u64) -> Option<u64> {
        let t = self.table.load(Acquire);
        if t.is_null() {
            return None;
        }
        let t = unsafe { &*t };
        let e = Self::enc(k);
        let mask = t.cap - 1;
        let mut i = t.slot_of(e);
        loop {
            let x = ld64(unsafe { t.keys().add(i) });
            if x == 0 {
                return None;
            }
            if x == e {
                return Some(ld64(unsafe { t.vals().add(i) }));
            }
            i = (i + 1) & mask;
        }
    }

    /// Writer only.
    fn put(&self, k: u64, v: u64) -> Result<()> {
        let mut t = self.table.load(Relaxed);
        let len = self.len.load(Relaxed);
        if t.is_null() || (len + 1) * 4 > unsafe { (*t).cap } * 3 {
            let cap = if t.is_null() { 64 } else { (unsafe { (*t).cap }) * 2 };
            self.grow(cap)?;
            t = self.table.load(Relaxed);
        }
        let t = unsafe { &*t };
        let e = Self::enc(k);
        let mask = t.cap - 1;
        let mut i = t.slot_of(e);
        loop {
            let kp = unsafe { t.keys().add(i) };
            let x = unsafe { *kp };
            if x == e {
                st64(unsafe { t.vals().add(i) }, v);
                return Ok(());
            }
            if x == 0 {
                unsafe { *t.vals().add(i) = v };
                st64(kp, e);
                self.len.store(len + 1, Relaxed);
                return Ok(());
            }
            i = (i + 1) & mask;
        }
    }

    fn new_table(cap: usize) -> Result<*mut Table> {
        let bytes = align_up((cap * 16) as u64, PAGE as u64) as usize;
        let mem = reserve_anon(ptr::null_mut(), bytes)?;
        Ok(Box::into_raw(Box::new(Table { shift: 64 - cap.trailing_zeros(), cap, mem, bytes })))
    }

    fn grow(&self, cap: usize) -> Result<()> {
        let tp = Self::new_table(cap)?;
        let t = unsafe { &*tp };
        let mask = cap - 1;
        let o = self.table.load(Relaxed);
        if !o.is_null() {
            let o = unsafe { &*o };
            for j in 0..o.cap {
                let e = unsafe { *o.keys().add(j) };
                if e == 0 {
                    continue;
                }
                let v = unsafe { *o.vals().add(j) };
                let mut i = t.slot_of(e);
                while unsafe { *t.keys().add(i) } != 0 {
                    i = (i + 1) & mask;
                }
                unsafe {
                    *t.keys().add(i) = e;
                    *t.vals().add(i) = v;
                }
            }
            unsafe { (*self.retired.get()).push(o as *const Table as *mut Table) };
        }
        self.table.store(tp, SeqCst);
        Ok(())
    }

    fn free_table(t: *mut Table) {
        let b = unsafe { Box::from_raw(t) };
        unmap(b.mem, b.bytes);
    }

    /// Frees replaced tables, when no reader is inside a read. Writer only.
    fn reclaim(&self, readers: &Readers) {
        let r = unsafe { &mut *self.retired.get() };
        if r.is_empty() || !readers.quiet() {
            return;
        }
        for t in r.drain(..) {
            Self::free_table(t);
        }
    }

    fn clear(&self) {
        let t = self.table.swap(ptr::null_mut(), SeqCst);
        if !t.is_null() {
            unsafe { (*self.retired.get()).push(t) };
        }
        self.len.store(0, Relaxed);
    }

    fn bytes(&self) -> usize {
        let t = self.table.load(Acquire);
        if t.is_null() {
            0
        } else {
            unsafe { (*t).cap * 16 }
        }
    }
}

impl Drop for Map {
    fn drop(&mut self) {
        let t = self.table.swap(ptr::null_mut(), SeqCst);
        if !t.is_null() {
            Self::free_table(t);
        }
        for t in self.retired.get_mut().drain(..) {
            Self::free_table(t);
        }
    }
}

/// Readers announce themselves in slots of their own (a cache line each).
/// Memory a writer unlinked is freed only after it has seen every slot
/// empty.
#[repr(align(64))]
struct Slot(AtomicU32);

struct Readers {
    slots: [Slot; 64],
}

thread_local! {
    static MY_SLOT: std::cell::Cell<u8> = const { std::cell::Cell::new(255) };
}
static NEXT_SLOT: AtomicU32 = AtomicU32::new(0);

struct ReadGuard<'a>(&'a AtomicU32);
impl Drop for ReadGuard<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Release);
    }
}

impl Readers {
    fn new() -> Self {
        Readers { slots: std::array::from_fn(|_| Slot(AtomicU32::new(0))) }
    }
    fn enter(&self) -> ReadGuard<'_> {
        let s = MY_SLOT.with(|c| {
            let mut v = c.get();
            if v == 255 {
                v = (NEXT_SLOT.fetch_add(1, Relaxed) % 64) as u8;
                c.set(v);
            }
            v
        });
        let a = &self.slots[s as usize].0;
        a.fetch_add(1, SeqCst);
        ReadGuard(a)
    }
    fn quiet(&self) -> bool {
        self.slots.iter().all(|s| s.0.load(SeqCst) == 0)
    }
}

/// A mutex for short sections: spins a little before sleeping.
struct Lock {
    state: AtomicU32,
}
struct LockGuard<'a>(&'a Lock);
impl Drop for LockGuard<'_> {
    fn drop(&mut self) {
        if self.0.state.swap(0, Release) == 2 {
            futex_wake(&self.0.state, 1);
        }
    }
}
impl Lock {
    fn new() -> Self {
        Lock { state: AtomicU32::new(0) }
    }
    fn lock(&self) -> LockGuard<'_> {
        for _ in 0..200 {
            if self.state.load(Relaxed) == 0 && self.state.compare_exchange_weak(0, 1, Acquire, Relaxed).is_ok() {
                return LockGuard(self);
            }
            std::hint::spin_loop();
        }
        while self.state.swap(2, Acquire) != 0 {
            futex_wait(&self.state, 2, None);
        }
        LockGuard(self)
    }
}

// ------------------------------------------------------------------- state

#[derive(Clone)]
pub struct Options {
    /// Every write is durable before it returns. Off: call `sync`.
    pub sync_writes: bool,
    /// How fast recency fades in ranking (old memories keep 85%).
    pub half_life_ms: u64,
    /// Word meanings; with them, questions in other words find memories.
    pub meaning: Option<Arc<Meaning>>,
    /// A background thread makes writes durable as they come. Writers take
    /// a `promise` and wait on it only before acting outside the machine.
    pub flusher: bool,
}

impl Default for Options {
    fn default() -> Self {
        Options { sync_writes: true, half_life_ms: 7 * 24 * 3600 * 1000, meaning: None, flusher: false }
    }
}

struct Lane {
    file: File,
    map: *mut u8,
    /// Records before this offset are in the index.
    end: AtomicU64,
    idle: AtomicBool,
    models: Box<[AtomicPtr<Model>]>,
    nmodels: AtomicUsize,
    model_offs: UnsafeCell<Vec<u64>>,
    /// Lane scope ref -> scope id.
    scope_refs: FlatVec<u32>,
    /// Ordinals of this lane's memories, in record order.
    ords: FlatVec<u32>,
}
unsafe impl Sync for Lane {}
unsafe impl Send for Lane {}

impl Lane {
    fn published(&self) -> u64 {
        ld64(unsafe { self.map.add(PUB_END_AT) } as *const u64)
    }
    #[inline]
    fn model(&self, id: u32) -> Option<&Model> {
        if id == 0 || id as usize > self.nmodels.load(Acquire) {
            return None;
        }
        let p = self.models[id as usize - 1].load(Acquire);
        if p.is_null() {
            None
        } else {
            Some(unsafe { &*p })
        }
    }
    /// Writer only: drops every model.
    fn clear_models(&self) {
        let n = self.nmodels.swap(0, AcqRel);
        for i in 0..n {
            let p = self.models[i].swap(ptr::null_mut(), AcqRel);
            if !p.is_null() {
                drop(unsafe { Box::from_raw(p) });
            }
        }
        unsafe { (*self.model_offs.get()).clear() };
    }
    /// Writer only.
    fn add_model(&self, m: Box<Model>, off: u64) -> Result<()> {
        let n = self.nmodels.load(Relaxed);
        if n >= MAX_MODELS {
            return Err(Error::Corrupt);
        }
        self.models[n].store(Box::into_raw(m), Release);
        unsafe { (*self.model_offs.get()).push(off) };
        self.nmodels.store(n + 1, Release);
        Ok(())
    }
}

impl Drop for Lane {
    fn drop(&mut self) {
        self.clear_models();
        unmap(self.map, MAP_RESERVE);
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Cell {
    head: u32,
    root: u32,
    nver: u32,
}

const NO_POSTS: u32 = u32::MAX;
const FLAG_FORGOTTEN: u32 = 1 << 24;
const FLAG_SUBJECT: u32 = 1 << 25;
const SCOPE_MASK: u32 = (1 << 24) - 1;
const VC_LEN: usize = MAX_LANES;

/// Fields only the writer touches (write lock held, or open/close).
struct WState {
    erase_lo: u64,
    erase_hi: u64,
    broken: bool,
    dirty: bool,
    total_terms: u64,
    counter: ans::Counter,
    written: u64,
    next_model_at: u64,
    rec_buf: Vec<u8>,
}

/// Replay scratch (writer only, never re-entered).
struct Dec {
    buf: Vec<u8>,
    terms: Box<Terms>,
}

/// Background growth of our lane (fix 1): space is zero-filled and made
/// durable ahead of the writers, outside the write lock.
struct Grower {
    /// Bytes of our lane that exist, zero-filled and durable.
    alloc: AtomicU64,
    want: AtomicU64,
    seq: AtomicU32,
    done_seq: AtomicU32,
    err: AtomicBool,
    stop: AtomicBool,
}

pub struct Crystal {
    dir: PathBuf,
    sync_writes: bool,
    flusher: bool,
    half_life_ms: u64,
    meaning: Option<Arc<Meaning>>,
    meaning_on: AtomicBool,
    clock_override: AtomicU64,

    wlock: Lock,
    readers: Readers,
    lanes: Box<[OnceLock<Lane>]>,
    nlanes: AtomicUsize,
    me: usize,
    end: AtomicU64,
    synced: AtomicU64,
    syncs: AtomicU64,
    flushing: AtomicBool,
    group_sync: bool,
    wseq: AtomicU32,
    dseq: AtomicU32,
    flusher_waiting: AtomicBool,
    flusher_stop: AtomicBool,
    flusher_err: AtomicU32,
    flusher_thread: Mutex<Option<std::thread::JoinHandle<()>>>,
    grower: Grower,
    grower_thread: Mutex<Option<std::thread::JoinHandle<()>>>,
    erase_pending: AtomicBool,
    last_refresh: AtomicI64,
    merges: AtomicU64,

    // Lexicon.
    lex: Map,
    t_key: FlatVec<u64>,
    t_df: FlatVec<u32>,
    t_p0: FlatVec<u32>,
    t_tail: FlatVec<u32>,
    // Postings blocks: [prev, len | log2(cap) << 16, entries...].
    post: FlatVec<u32>,
    // Timeline.
    tl_loc: FlatVec<u64>,
    tl_sf: FlatVec<u32>,
    // Facts.
    fact_of: Map,
    cells: FlatVec<Cell>,
    subjects: Map,
    // Scopes: a tree by '/', each with its own postings.
    sc_map: Map,
    sc_name_off: FlatVec<u32>,
    sc_name_len: FlatVec<u16>,
    sc_names: FlatVec<u8>,
    sc_parent: FlatVec<u32>,
    sc_child: FlatVec<u32>,
    sc_sib: FlatVec<u32>,
    sc_p0: FlatVec<u32>,
    sc_tail: FlatVec<u32>,
    sc_forget: FlatVec<u32>,
    sc_settle: FlatVec<u32>,
    own_ref: FlatVec<u32>,
    vcs: FlatVec<u64>,

    w: UnsafeCell<WState>,
    dec: UnsafeCell<Dec>,
}

unsafe impl Sync for Crystal {}
unsafe impl Send for Crystal {}

struct SendPtr(*const Crystal);
unsafe impl Send for SendPtr {}

static MONO: LazyLock<Instant> = LazyLock::new(Instant::now);

fn lane_name(i: usize) -> String {
    format!("lane-{:03}.cx", i)
}

impl Crystal {
    #[allow(clippy::mut_from_ref)]
    #[inline]
    fn ws(&self) -> &mut WState {
        // SAFETY: only called with the write lock held, or before/after
        // any other thread can see the store.
        unsafe { &mut *self.w.get() }
    }

    #[inline]
    fn lane(&self, i: usize) -> &Lane {
        self.lanes[i].get().expect("lane")
    }

    fn meaning(&self) -> Option<&Meaning> {
        if self.meaning_on.load(Relaxed) {
            self.meaning.as_deref()
        } else {
            None
        }
    }

    /// Switches word meanings off or on (when the store was opened with them).
    pub fn set_meaning_enabled(&self, on: bool) {
        self.meaning_on.store(on, Relaxed);
    }

    fn scope_vecs(&self) -> [AnyVec<'_>; 11] {
        [self.sc_name_off.any(), self.sc_name_len.any(), self.sc_names.any(), self.sc_parent.any(), self.sc_child.any(), self.sc_sib.any(), self.sc_p0.any(), self.sc_tail.any(), self.sc_forget.any(), self.sc_settle.any(), self.own_ref.any()]
    }

    /// Every index array, in snapshot order.
    fn index_vecs(&self) -> [AnyVec<'_>; 20] {
        let s = self.scope_vecs();
        [self.t_key.any(), self.t_df.any(), self.t_p0.any(), self.t_tail.any(), self.post.any(), self.tl_loc.any(), self.tl_sf.any(), self.cells.any(), self.vcs.any(), s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10]]
    }

    /// Empty index with its reserved zero entries.
    fn reset_index(&self) -> Result<()> {
        for v in self.index_vecs() {
            reserve_anon(v.mem, v.bytes)?;
            v.len.store(0, Release);
        }
        for l in 0..self.nlanes.load(Acquire) {
            let lane = self.lane(l);
            lane.ords.reset()?;
            lane.scope_refs.reset()?;
            lane.end.store(DATA_START, Release);
            lane.clear_models();
        }
        self.lex.clear();
        self.fact_of.clear();
        self.subjects.clear();
        self.sc_map.clear();
        self.t_key.push(0)?;
        self.t_df.push(0)?;
        self.t_p0.push(0)?;
        self.t_tail.push(0)?;
        self.post.push(0)?;
        self.cells.push(Cell::default())?;
        self.vcs.extend(VC_LEN)?;
        self.push_scope(b"", 0)?;
        self.ws().total_terms = 0;
        self.merges.store(0, Relaxed);
        Ok(())
    }

    pub fn open(path: impl AsRef<Path>, options: Options) -> Result<Box<Crystal>> {
        let dir = path.as_ref().to_path_buf();
        std::fs::create_dir_all(&dir)?;
        let big: usize = 1 << 30;
        let mut lanes = Vec::with_capacity(MAX_LANES);
        for _ in 0..MAX_LANES {
            lanes.push(OnceLock::new());
        }
        let w = Box::new(Crystal {
            dir,
            sync_writes: options.sync_writes,
            flusher: options.flusher,
            half_life_ms: options.half_life_ms,
            meaning_on: AtomicBool::new(options.meaning.is_some()),
            meaning: options.meaning,
            clock_override: AtomicU64::new(u64::MAX),
            wlock: Lock::new(),
            readers: Readers::new(),
            lanes: lanes.into_boxed_slice(),
            nlanes: AtomicUsize::new(0),
            me: 0,
            end: AtomicU64::new(DATA_START),
            synced: AtomicU64::new(DATA_START),
            syncs: AtomicU64::new(0),
            flushing: AtomicBool::new(false),
            group_sync: std::env::var("CRYSTAL_SYNC").map(|v| v != "parallel").unwrap_or(true),
            wseq: AtomicU32::new(0),
            dseq: AtomicU32::new(0),
            flusher_waiting: AtomicBool::new(false),
            flusher_stop: AtomicBool::new(false),
            flusher_err: AtomicU32::new(0),
            flusher_thread: Mutex::new(None),
            grower: Grower { alloc: AtomicU64::new(DATA_START), want: AtomicU64::new(0), seq: AtomicU32::new(0), done_seq: AtomicU32::new(0), err: AtomicBool::new(false), stop: AtomicBool::new(false) },
            grower_thread: Mutex::new(None),
            erase_pending: AtomicBool::new(false),
            last_refresh: AtomicI64::new(i64::MIN / 2),
            merges: AtomicU64::new(0),
            lex: Map::new(),
            t_key: FlatVec::new(1 << 28)?,
            t_df: FlatVec::new(1 << 28)?,
            t_p0: FlatVec::new(1 << 28)?,
            t_tail: FlatVec::new(1 << 28)?,
            post: FlatVec::new(1 << 32)?,
            tl_loc: FlatVec::new(big)?,
            tl_sf: FlatVec::new(big)?,
            fact_of: Map::new(),
            cells: FlatVec::new(1 << 28)?,
            subjects: Map::new(),
            sc_map: Map::new(),
            sc_name_off: FlatVec::new(1 << 24)?,
            sc_name_len: FlatVec::new(1 << 24)?,
            sc_names: FlatVec::new(1 << 32)?,
            sc_parent: FlatVec::new(1 << 24)?,
            sc_child: FlatVec::new(1 << 24)?,
            sc_sib: FlatVec::new(1 << 24)?,
            sc_p0: FlatVec::new(1 << 24)?,
            sc_tail: FlatVec::new(1 << 24)?,
            sc_forget: FlatVec::new(1 << 24)?,
            sc_settle: FlatVec::new(1 << 24)?,
            own_ref: FlatVec::new(1 << 24)?,
            vcs: FlatVec::new(1 << 26)?,
            w: UnsafeCell::new(WState { erase_lo: u64::MAX, erase_hi: 0, broken: false, dirty: false, total_terms: 0, counter: ans::Counter::new(), written: 0, next_model_at: 64, rec_buf: Vec::new() }),
            dec: UnsafeCell::new(Dec { buf: Vec::new(), terms: Terms::boxed() }),
        });
        let mut w = w;
        // Claim the first lane no other writer holds. The OS drops the lock
        // when its holder dies, so a crashed writer's lane is reused.
        let mut own: Option<(usize, File)> = None;
        for i in 0..MAX_LANES {
            let f = OpenOptions::new().read(true).write(true).create(true).truncate(false).open(w.dir.join(lane_name(i)))?;
            match flock(&f, libc::LOCK_EX | libc::LOCK_NB) {
                Ok(()) => {
                    own = Some((i, f));
                    break;
                }
                Err(e) if e.raw_os_error() == Some(libc::EWOULDBLOCK) => continue,
                Err(e) => return Err(e.into()),
            }
        }
        let (me, own) = own.ok_or(Error::TooManyWriters)?;
        w.me = me;
        let len = own.metadata()?.len();
        if len < DATA_START {
            let mut head = vec![0u8; DATA_START as usize];
            head[0..8].copy_from_slice(LANE_MAGIC);
            head[8..12].copy_from_slice(&FORMAT_VERSION.to_le_bytes());
            head[PUB_END_AT..PUB_END_AT + 8].copy_from_slice(&DATA_START.to_le_bytes());
            own.write_all_at(&head, 0)?;
            own.sync_all()?;
        } else {
            let mut h = [0u8; 12];
            own.read_exact_at(&mut h, 0)?;
            if &h[0..8] != LANE_MAGIC {
                return Err(Error::Corrupt);
            }
            if u32::from_le_bytes(h[8..12].try_into().unwrap()) != FORMAT_VERSION {
                return Err(Error::UnsupportedFormat);
            }
        }
        let mut own = Some(own);
        let mut i = 0;
        while i < MAX_LANES {
            if i == me {
                w.add_lane(own.take().unwrap(), true, false)?;
            } else if !w.open_lane(i)? {
                break;
            }
            i += 1;
        }
        if w.nlanes.load(Acquire) <= me {
            return Err(Error::Corrupt);
        }
        w.grower.alloc.store(w.lane(me).file.metadata()?.len(), Release);
        w.load_index()?;
        let p = SendPtr(&*w as *const Crystal);
        *w.grower_thread.lock().unwrap() = Some(std::thread::spawn(move || {
            let p = p;
            // SAFETY: the store joins this thread before it is freed.
            unsafe { &*p.0 }.grower_loop()
        }));
        if w.flusher {
            let p = SendPtr(&*w as *const Crystal);
            *w.flusher_thread.lock().unwrap() = Some(std::thread::spawn(move || {
                let p = p;
                unsafe { &*p.0 }.flusher_loop()
            }));
        }
        Ok(w)
    }

    fn add_lane(&self, file: File, writable: bool, idle: bool) -> Result<()> {
        let prot = libc::PROT_READ | if writable { libc::PROT_WRITE } else { 0 };
        let m = unsafe { libc::mmap(ptr::null_mut(), MAP_RESERVE, prot, libc::MAP_SHARED, file.as_raw_fd(), 0) };
        if m == libc::MAP_FAILED {
            return Err(os_err());
        }
        let lane = Lane {
            file,
            map: m as *mut u8,
            end: AtomicU64::new(DATA_START),
            idle: AtomicBool::new(idle),
            models: (0..MAX_MODELS).map(|_| AtomicPtr::new(ptr::null_mut())).collect(),
            nmodels: AtomicUsize::new(0),
            model_offs: UnsafeCell::new(Vec::new()),
            scope_refs: FlatVec::new(1 << 24)?,
            ords: FlatVec::new(1 << 28)?,
        };
        let n = self.nlanes.load(Relaxed);
        if self.lanes[n].set(lane).is_err() {
            return Err(Error::Corrupt);
        }
        self.nlanes.store(n + 1, Release);
        Ok(())
    }

    /// Opens lane `i` for reading. False when it does not exist (yet).
    fn open_lane(&self, i: usize) -> Result<bool> {
        let f = match File::open(self.dir.join(lane_name(i))) {
            Ok(f) => f,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(e) => return Err(e.into()),
        };
        // A lane no writer holds may have records past the end it published:
        // hold its lock until it has been read by its records.
        let idle = match flock(&f, libc::LOCK_EX | libc::LOCK_NB) {
            Ok(()) => true,
            Err(e) if e.raw_os_error() == Some(libc::EWOULDBLOCK) => false,
            Err(e) => return Err(e.into()),
        };
        // Being created by its writer right now: look again later.
        if f.metadata()?.len() < DATA_START {
            return Ok(false);
        }
        let mut h = [0u8; 12];
        f.read_exact_at(&mut h, 0)?;
        if &h[0..8] != LANE_MAGIC {
            return Err(Error::Corrupt);
        }
        if u32::from_le_bytes(h[8..12].try_into().unwrap()) != FORMAT_VERSION {
            return Err(Error::UnsupportedFormat);
        }
        self.add_lane(f, false, idle)?;
        Ok(true)
    }

    /// Closes the store: writes the snapshot and gives back reserved space.
    pub fn close(self: Box<Self>) {
        drop(self)
    }

    fn shutdown(&mut self) {
        if let Some(t) = self.flusher_thread.get_mut().unwrap().take() {
            self.flusher_stop.store(true, Release);
            self.wseq.fetch_add(1, Release);
            futex_wake(&self.wseq, 1);
            let _ = t.join();
        }
        if let Some(t) = self.grower_thread.get_mut().unwrap().take() {
            self.grower.stop.store(true, Release);
            self.grower.seq.fetch_add(1, Release);
            futex_wake(&self.grower.seq, 1);
            let _ = t.join();
        }
        let _g = self.wlock.lock();
        let ws = self.ws();
        if ws.dirty && !ws.broken {
            let _ = self.write_snapshot();
        }
        // Give back the space reserved ahead.
        if !self.ws().broken && self.nlanes.load(Acquire) > self.me {
            let _ = self.lane(self.me).file.set_len(self.end.load(Acquire));
        }
    }

    pub fn set_clock_for_test(&self, ms: Option<u64>) {
        self.clock_override.store(ms.unwrap_or(u64::MAX), Relaxed);
    }

    fn now_ms(&self) -> u64 {
        let c = self.clock_override.load(Relaxed);
        if c != u64::MAX {
            return c;
        }
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
    }

    fn mono_ms(&self) -> i64 {
        MONO.elapsed().as_millis() as i64
    }

    // -------------------------------------------------------------- scopes

    fn scope_hash(name: &[u8]) -> u64 {
        hash(0x5c09e, name)
    }

    pub fn scope_name(&self, sid: u32) -> &[u8] {
        let off = self.sc_name_off.get(sid as usize) as usize;
        let len = self.sc_name_len.get(sid as usize) as usize;
        unsafe { std::slice::from_raw_parts(self.sc_names.p().add(off), len) }
    }

    fn scope_id(&self, name: &[u8]) -> Option<u32> {
        let sid = self.sc_map.get(Self::scope_hash(name))? as u32;
        if self.scope_name(sid) != name {
            return None;
        }
        Some(sid)
    }

    fn push_scope(&self, name: &[u8], parent: u32) -> Result<u32> {
        let off = self.sc_names.extend(name.len())?;
        unsafe { ptr::copy_nonoverlapping(name.as_ptr(), self.sc_names.p().add(off as usize), name.len()) };
        self.sc_name_off.push(off)?;
        self.sc_name_len.push(name.len() as u16)?;
        self.sc_parent.push(parent)?;
        self.sc_child.push(0)?;
        self.sc_sib.push(if parent != 0 || !name.is_empty() { self.sc_child.get(parent as usize) } else { 0 })?;
        self.sc_p0.push(0)?;
        self.sc_tail.push(0)?;
        self.sc_forget.push(0)?;
        self.sc_settle.push(0)?;
        let sid = self.own_ref.push(0)?;
        if !name.is_empty() {
            st32(self.sc_child.at(parent as usize), sid);
            self.sc_map.put(Self::scope_hash(name), sid as u64)?;
        }
        Ok(sid)
    }

    /// The scope's id, made (with its parents) if new. Writer only.
    fn ensure_scope(&self, name: &[u8]) -> Result<u32> {
        if let Some(s) = self.scope_id(name) {
            return Ok(s);
        }
        let parent = match name.iter().rposition(|&c| c == b'/') {
            Some(i) if i > 0 => self.ensure_scope(&name[..i])?,
            _ => 0,
        };
        self.push_scope(name, parent)
    }

    fn under_scope(&self, sid: u32, root: u32) -> bool {
        let mut s = sid;
        let mut depth = 0;
        while s != 0 && depth < 256 {
            if s == root {
                return true;
            }
            s = self.sc_parent.get(s as usize);
            depth += 1;
        }
        false
    }

    /// Ids of a scope and every scope below it.
    fn subtree(&self, root: u32, out: &mut Vec<u32>) {
        out.push(root);
        let mut i = out.len() - 1;
        while i < out.len() {
            let mut c = ld32(self.sc_child.at(out[i] as usize));
            while c != 0 {
                out.push(c);
                c = self.sc_sib.get(c as usize);
            }
            i += 1;
        }
    }

    fn scope_set(&self, scope: &[u8]) -> Option<ScopeSet> {
        if scope.is_empty() {
            return Some(ScopeSet { all: true, root: 0 });
        }
        Some(ScopeSet { all: false, root: self.scope_id(scope)? })
    }

    // ------------------------------------------------------------ postings

    fn append_post(&self, p0: *mut u32, tail: *mut u32, ord: u32) -> Result<()> {
        unsafe {
            if *p0 == 0 {
                st32(p0, ord + 1);
                return Ok(());
            }
            let t = *tail;
            let mut cap_log: u32 = 1;
            if t != 0 {
                let meta = self.post.get(t as usize + 1);
                let len = meta & 0xffff;
                cap_log = meta >> 16;
                if len < (1u32 << cap_log) {
                    *self.post.at((t + 2 + len) as usize) = ord;
                    st32(self.post.at(t as usize + 1), meta + 1);
                    return Ok(());
                }
                cap_log = (cap_log + 1).min(10);
            }
            let b = self.post.extend(2 + (1usize << cap_log))?;
            *self.post.at(b as usize) = t;
            *self.post.at(b as usize + 2) = ord;
            st32(self.post.at(b as usize + 1), 1 | (cap_log << 16));
            st32(tail, b);
        }
        Ok(())
    }

    #[inline]
    fn posts_init(&self, p0: *const u32, tail: *const u32) -> Posts {
        let t = ld32(tail);
        let f = ld32(p0);
        if t == NO_POSTS {
            return Posts::EMPTY;
        }
        let mut p = Posts { blk: t, i: 0, p0: f };
        if t != 0 {
            p.i = ld32(self.post.at(t as usize + 1)) & 0xffff;
        }
        p
    }

    #[inline]
    fn posts_next(&self, p: &mut Posts) -> Option<u32> {
        while p.blk != 0 {
            if p.i > 0 {
                p.i -= 1;
                return Some(self.post.get((p.blk + 2 + p.i) as usize));
            }
            p.blk = self.post.get(p.blk as usize);
            if p.blk != 0 {
                p.i = ld32(self.post.at(p.blk as usize + 1)) & 0xffff;
            }
        }
        if p.p0 != 0 {
            let o = p.p0 - 1;
            p.p0 = 0;
            return Some(o);
        }
        None
    }

    fn term_posts(&self, tid: u32) -> Posts {
        self.posts_init(self.t_p0.at(tid as usize), self.t_tail.at(tid as usize))
    }
    fn scope_posts(&self, sid: u32) -> Posts {
        self.posts_init(self.sc_p0.at(sid as usize), self.sc_tail.at(sid as usize))
    }

    // -------------------------------------------------------------- lookup

    /// A word's term id; 0 for a word seen once or never.
    fn term_id(&self, key: u64) -> u32 {
        match self.lex.get(key) {
            Some(v) if v & ONCE_BIT == 0 => v as u32,
            _ => 0,
        }
    }

    fn df(&self, tid: u32) -> u32 {
        if tid == 0 {
            0
        } else {
            unsafe { AtomicU32::from_ptr(self.t_df.at(tid as usize)).load(Relaxed) }
        }
    }

    /// How many memories a word is in.
    fn df_of(&self, key: u64) -> u32 {
        match self.lex.get(key) {
            None => 0,
            Some(v) if v & ONCE_BIT != 0 => 1,
            Some(v) => self.df(v as u32),
        }
    }

    /// A word's postings, newest first (empty for a word too common).
    fn posts_of(&self, key: u64) -> Posts {
        match self.lex.get(key) {
            None => Posts::EMPTY,
            Some(v) if v & ONCE_BIT != 0 => Posts { blk: 0, i: 0, p0: (v as u32) + 1 },
            Some(v) => self.term_posts(v as u32),
        }
    }

    #[inline]
    fn mem_count(&self) -> usize {
        self.tl_loc.count()
    }

    /// Bits a word carries: log2 of how many memories per one that has it.
    fn idf(&self, d: u32) -> f32 {
        let n = (self.mem_count() + 1) as f32;
        (n / (d as f32 + 0.5)).log2().max(0.0)
    }

    #[inline]
    fn alive(&self, ord: u32) -> bool {
        if ord as usize >= self.mem_count() {
            return false;
        }
        ld32(self.tl_sf.at(ord as usize)) & FLAG_FORGOTTEN == 0
    }

    #[inline]
    fn sid_of(&self, ord: u32) -> u32 {
        ld32(self.tl_sf.at(ord as usize)) & SCOPE_MASK
    }

    #[inline]
    fn cell_of(&self, ord: u32) -> u32 {
        self.fact_of.get(ord as u64).unwrap_or(0) as u32
    }

    /// The newest version of the fact `ord` belongs to.
    fn head_of(&self, ord: u32) -> u32 {
        let c = self.cell_of(ord);
        if c == 0 {
            return ord;
        }
        ld32(unsafe { addr_of_mut!((*self.cells.at(c as usize)).head) })
    }

    fn vc_has(&self, v: u32, lane: usize, off: u64) -> bool {
        v != 0 && off < ld64(self.vcs.at(v as usize * VC_LEN + lane))
    }

    fn settled(&self, ord: u32) -> bool {
        let id = self.tl_loc.get(ord as usize);
        let mut s = self.sid_of(ord);
        let mut depth = 0;
        while s != 0 && depth < 256 {
            if self.vc_has(ld32(self.sc_settle.at(s as usize)), lane_of(id), off_of(id)) {
                return true;
            }
            s = self.sc_parent.get(s as usize);
            depth += 1;
        }
        false
    }

    /// An older version of its fact, or settled under a summary.
    fn is_buried(&self, ord: u32) -> bool {
        self.head_of(ord) != ord || self.settled(ord)
    }

    /// Bytes of lane `l` the index may read.
    #[inline]
    fn lane_bytes(&self, l: usize) -> &[u8] {
        let lane = self.lane(l);
        let e = if l == self.me { self.end.load(Acquire) } else { lane.end.load(Acquire) };
        unsafe { std::slice::from_raw_parts(lane.map, e as usize) }
    }

    #[inline]
    fn rec_of(&self, id: u64) -> Option<Rec<'_>> {
        let l = lane_of(id);
        if l >= self.nlanes.load(Acquire) {
            return None;
        }
        let b = self.lane_bytes(l);
        let off = off_of(id) as usize;
        if off < DATA_START as usize || off >= b.len() {
            return None;
        }
        parse_rec(&b[off..])
    }

    /// Decodes a memory's text into `out` (exactly `r.raw_len` bytes).
    fn decode_text(&self, lane: usize, r: &Rec, out: &mut [u8]) -> Result<()> {
        if r.model == 0 {
            if r.text.len() != out.len() {
                return Err(Error::Corrupt);
            }
            out.copy_from_slice(r.text);
            return Ok(());
        }
        let m = self.lane(lane).model(r.model).ok_or(Error::Corrupt)?;
        ans::decode(m, r.text, out)?;
        Ok(())
    }

    fn text_intact(r: &Rec) -> bool {
        !r.erased && Crc32c::hash(r.text) == r.text_crc
    }

    /// Ordinal of a memory id, by binary search in its lane's record order.
    /// Entries are checked here, as they are used (fix 3).
    fn ord_of(&self, id: u64) -> Option<u32> {
        let l = lane_of(id);
        if l >= self.nlanes.load(Acquire) {
            return None;
        }
        let ords = self.lane(l).ords.items();
        let n = self.mem_count();
        let off = off_of(id);
        let (mut lo, mut hi) = (0usize, ords.len());
        while lo < hi {
            let mid = (lo + hi) / 2;
            let ord = ords[mid];
            if ord as usize >= n {
                return None;
            }
            let o = off_of(self.tl_loc.get(ord as usize));
            if o == off {
                return Some(ord);
            }
            if o < off {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        None
    }

    /// Copies a live memory out of its lane.
    fn load(&self, ord: u32) -> Result<Option<Memory>> {
        if !self.alive(ord) {
            return Ok(None);
        }
        let id = self.tl_loc.get(ord as usize);
        let Some(r) = self.rec_of(id) else { return Ok(None) };
        if r.erased {
            return Ok(None);
        }
        let scope = self.scope_name(self.sid_of(ord));
        let mut raw = Vec::with_capacity(scope.len() + r.subject.len() + r.raw_len as usize);
        raw.extend_from_slice(scope);
        raw.extend_from_slice(r.subject);
        let at = raw.len();
        raw.resize(at + r.raw_len as usize, 0);
        if let Err(e) = self.decode_text(lane_of(id), &r, &mut raw[at..]) {
            if !Self::text_intact(&r) {
                return Ok(None);
            }
            return Err(e);
        }
        // Erased while we decoded: that is a forgotten memory.
        if !Self::text_intact(&r) {
            return Ok(None);
        }
        Ok(Some(Memory { id, time: r.time, scope_len: scope.len(), subject_len: r.subject.len(), raw }))
    }

    /// A memory's text decoded into `out`, or None when gone.
    /// Returns (time, has subject).
    fn text_of(&self, ord: u32, out: &mut Vec<u8>) -> Option<(u64, bool)> {
        if !self.alive(ord) {
            return None;
        }
        let id = self.tl_loc.get(ord as usize);
        let r = self.rec_of(id)?;
        if r.erased {
            return None;
        }
        out.resize(r.raw_len as usize, 0);
        self.decode_text(lane_of(id), &r, out).ok()?;
        Some((r.time, !r.subject.is_empty()))
    }

    // --------------------------------------------------------------- index

    fn subject_key(sid: u32, subject: &[u8]) -> u64 {
        hash((sid as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15).wrapping_add(7), subject)
    }

    fn forgotten_by_vc(&self, sid: u32, lane: usize, off: u64) -> bool {
        let mut s = sid;
        let mut depth = 0;
        while s != 0 && depth < 256 {
            if self.vc_has(self.sc_forget.get(s as usize), lane, off) {
                return true;
            }
            s = self.sc_parent.get(s as usize);
            depth += 1;
        }
        false
    }

    /// Frees replaced tables no reader can hold any more. Writer only.
    fn reclaim(&self) {
        for m in [&self.lex, &self.fact_of, &self.subjects, &self.sc_map] {
            m.reclaim(&self.readers);
        }
    }

    fn new_cell(&self, ord: u32) -> Result<u32> {
        let c = self.cells.push(Cell { head: ord, root: ord, nver: 1 })?;
        self.fact_of.put(ord as u64, c as u64)?;
        Ok(c)
    }

    fn link_into(&self, c: u32, ord: u32) -> Result<()> {
        self.fact_of.put(ord as u64, c as u64)?;
        let cell = self.cells.at(c as usize);
        unsafe {
            if ord > (*cell).head {
                st32(addr_of_mut!((*cell).head), ord);
            }
            (*cell).nver += 1;
        }
        Ok(())
    }

    /// Adds a memory to the index. `tids` are its terms' ids when known.
    fn index_memory(&self, lane: usize, off: u64, f: MemFields, terms: &Terms, tids: Option<&[u32]>) -> Result<u32> {
        let ord = self.tl_loc.count() as u32;
        let mut sf = f.sid;
        if !f.subject.is_empty() {
            sf |= FLAG_SUBJECT;
        }
        if f.erased || self.forgotten_by_vc(f.sid, lane, off) {
            sf |= FLAG_FORGOTTEN;
        }
        self.tl_sf.push(sf)?;
        self.tl_loc.push(id_of(lane, off))?;
        self.lane(lane).ords.push(ord)?;
        self.append_post(self.sc_p0.at(f.sid as usize), self.sc_tail.at(f.sid as usize), ord)?;
        let limit = struct_limit(ord as usize + 1);
        let ws = self.ws();
        for (i, word) in terms.items().iter().enumerate() {
            ws.total_terms += terms.tf[i] as u64;
            let mut tid = tids.map(|t| t[i]).unwrap_or(0);
            if tid == 0 {
                match self.lex.get(word.key) {
                    None => {
                        self.lex.put(word.key, ONCE_BIT | ord as u64)?;
                        continue;
                    }
                    Some(v) if v & ONCE_BIT != 0 => {
                        // Seen a second time: it becomes a term.
                        tid = self.t_key.push(word.key)?;
                        self.t_df.push(1)?;
                        self.t_p0.push((v as u32) + 1)?;
                        self.t_tail.push(0)?;
                        self.lex.put(word.key, tid as u64)?;
                    }
                    Some(v) => tid = v as u32,
                }
            }
            let d = self.t_df.at(tid as usize);
            let dv = unsafe { *d } + 1;
            unsafe { AtomicU32::from_ptr(d).store(dv, Relaxed) };
            let tail = self.t_tail.at(tid as usize);
            if unsafe { *tail } == NO_POSTS {
                continue;
            }
            if dv > limit {
                // Too common to find anything: it keeps no postings.
                st32(tail, NO_POSTS);
                continue;
            }
            self.append_post(self.t_p0.at(tid as usize), tail, ord)?;
        }
        if !f.subject.is_empty() {
            let key = Self::subject_key(f.sid, f.subject);
            if let Some(c) = self.subjects.get(key) {
                self.link_into(c as u32, ord)?;
            } else {
                let c = self.new_cell(ord)?;
                self.subjects.put(key, c as u64)?;
            }
        } else if f.link != 0 {
            if let Some(target) = self.ord_of(f.link - 1) {
                let c = self.cell_of(target);
                let c = if c != 0 { c } else { self.new_cell(target)? };
                self.link_into(c, ord)?;
                self.merges.fetch_add(1, Relaxed);
            }
        }
        ws.dirty = true;
        Ok(ord)
    }

    /// Folds a marker's lane ends into a scope's vector (newest wins).
    fn merge_vc(&self, slot: *mut u32, vc: &[u64; VC_LEN]) -> Result<u32> {
        unsafe {
            if *slot == 0 {
                let at = self.vcs.extend(VC_LEN)?;
                st32(slot, at / VC_LEN as u32);
            }
            let base = *slot as usize * VC_LEN;
            for (i, &e) in vc.iter().enumerate() {
                let p = self.vcs.at(base + i);
                if e > *p {
                    st64(p, e);
                }
            }
            Ok(*slot)
        }
    }

    fn set_forgotten(&self, ord: u32) -> Result<()> {
        let p = self.tl_sf.at(ord as usize);
        let v = unsafe { *p };
        if v & FLAG_FORGOTTEN != 0 {
            return Ok(());
        }
        st32(p, v | FLAG_FORGOTTEN);
        let id = self.tl_loc.get(ord as usize);
        if lane_of(id) == self.me {
            self.erase_own(off_of(id))?;
        }
        Ok(())
    }

    fn apply_forget_scope(&self, name: &[u8], vc: &[u64; VC_LEN]) -> Result<()> {
        let sid = self.ensure_scope(name)?;
        let v = self.merge_vc(self.sc_forget.at(sid as usize), vc)?;
        let mut ids = Vec::new();
        self.subtree(sid, &mut ids);
        for s in ids {
            let mut p = self.scope_posts(s);
            while let Some(ord) = self.posts_next(&mut p) {
                let id = self.tl_loc.get(ord as usize);
                if self.vc_has(v, lane_of(id), off_of(id)) {
                    self.set_forgotten(ord)?;
                }
            }
        }
        Ok(())
    }

    /// Puts one record into the index (replay, and other writers' records).
    fn ingest(&self, lane: usize, off: u64, r: &Rec) -> Result<()> {
        match r.kind {
            K_MEMORY => {
                let l = self.lane(lane);
                if r.scope_ref as usize >= l.scope_refs.count() {
                    return Err(Error::Corrupt);
                }
                let sid = l.scope_refs.get(r.scope_ref as usize);
                let mut erased = r.erased;
                // SAFETY: writer only, and index_memory never replays.
                let dec = unsafe { &mut *self.dec.get() };
                if !erased {
                    dec.buf.resize(r.raw_len as usize, 0);
                    if self.decode_text(lane, r, &mut dec.buf).is_err() || Crc32c::hash(r.text) != r.text_crc {
                        erased = true;
                    }
                }
                dec.terms.fill(if erased { &[] } else { &dec.buf[..] });
                self.index_memory(lane, off, MemFields { sid, subject: r.subject, link: r.link, erased }, &dec.terms, None)?;
            }
            K_SCOPE => {
                let mut p = 0;
                let rf = ans::get_varint(r.body, &mut p)?;
                let refs = &self.lane(lane).scope_refs;
                if rf != refs.count() as u64 {
                    return Err(Error::Corrupt);
                }
                let sid = self.ensure_scope(&r.body[p..])?;
                refs.push(sid)?;
                if lane == self.me {
                    unsafe { *self.own_ref.at(sid as usize) = rf as u32 + 1 };
                }
            }
            K_MODEL => {
                let m = ans::parse(r.body)?;
                self.lane(lane).add_model(m, off)?;
            }
            K_FORGET_SCOPE | K_SETTLE => {
                let mut p = 0;
                let vc = read_vc(r.body, &mut p)?;
                let name = &r.body[p..];
                if r.kind == K_FORGET_SCOPE {
                    self.apply_forget_scope(name, &vc)?;
                } else {
                    let sid = self.ensure_scope(name)?;
                    self.merge_vc(self.sc_settle.at(sid as usize), &vc)?;
                }
                self.ws().dirty = true;
            }
            K_FORGET_ONE => {
                let mut p = 0;
                let target = ans::get_varint(r.body, &mut p)?;
                if let Some(ord) = self.ord_of(target) {
                    self.set_forgotten(ord)?;
                }
                self.ws().dirty = true;
            }
            _ => {}
        }
        Ok(())
    }

    /// Indexes lane `l` from its current end up to `limit`, by records.
    fn replay_lane(&self, l: usize, limit: u64) -> Result<()> {
        let lane = self.lane(l);
        let mut pos = lane.end.load(Acquire);
        let m = unsafe { std::slice::from_raw_parts(lane.map, limit as usize) };
        while pos < limit {
            let Some(r) = parse_rec(&m[pos as usize..]) else { break };
            self.ingest(l, pos, &r)?;
            pos += r.len as u64;
            lane.end.store(pos, Release);
        }
        Ok(())
    }

    fn load_index(&self) -> Result<()> {
        let from = self.load_snapshot().unwrap_or(None);
        if from.is_none() {
            self.reset_index()?;
        }
        for l in 0..self.nlanes.load(Acquire) {
            let lane = self.lane(l);
            if let Some(f) = &from {
                lane.end.store(f[l].max(DATA_START), Release);
            }
            let len = lane.file.metadata()?.len();
            let idle = lane.idle.load(Relaxed);
            let limit = if l == self.me || idle { len } else { len.min(lane.published()) };
            self.replay_lane(l, limit)?;
            if l != self.me && idle {
                let _ = flock(&lane.file, libc::LOCK_UN);
                lane.idle.store(false, Relaxed);
            }
        }
        // Our lane ends where its last whole record ends. Bytes after it (a
        // write cut off by a crash) are cleared, so nothing reads them later.
        let own = self.lane(self.me);
        let e = own.end.load(Acquire);
        let alloc = self.grower.alloc.load(Acquire);
        let mut o = e;
        let z = vec![0u8; 1 << 16];
        while o < alloc {
            let n = (z.len() as u64).min(alloc - o) as usize;
            let cur = unsafe { std::slice::from_raw_parts(own.map.add(o as usize), n) };
            if cur.iter().all(|&b| b == 0) {
                break;
            }
            own.file.write_all_at(&z[..n], o)?;
            o += n as u64;
        }
        if o > e {
            own.file.sync_all()?;
        }
        self.end.store(e, Release);
        self.synced.store(e, Release);
        self.publish();
        self.ws().next_model_at = if own.nmodels.load(Acquire) == 0 { 64 } else { 16384 };
        Ok(())
    }

    // -------------------------------------------------------------- writes

    #[inline]
    fn own_map(&self) -> *mut u8 {
        self.lane(self.me).map
    }

    fn publish(&self) {
        st64(unsafe { self.own_map().add(PUB_END_AT) } as *mut u64, self.end.load(Acquire));
    }

    /// Space for `len` bytes at the end of our lane. Writer only. The
    /// grower keeps space ready ahead; a writer only waits when it catches
    /// up with it.
    fn reserve(&self, len: u64) -> Result<u64> {
        let off = self.end.load(Acquire);
        let need = off + len;
        if need >= MAP_RESERVE as u64 {
            return Err(Error::LaneFull);
        }
        let g = &self.grower;
        let a = g.alloc.load(Acquire);
        let step = (a / 4).clamp(GROW_MIN, GROW_MAX);
        if need + step / 2 > a {
            let target = align_up(need.max(a + step), PAGE as u64).min(MAP_RESERVE as u64);
            if g.want.fetch_max(target, AcqRel) < target {
                g.seq.fetch_add(1, Release);
                futex_wake(&g.seq, 1);
            }
        }
        while need > g.alloc.load(Acquire) {
            if g.err.load(Acquire) {
                g.err.store(false, Release);
                return Err(Error::FlushFailed);
            }
            let s = g.done_seq.load(Acquire);
            if need <= g.alloc.load(Acquire) {
                break;
            }
            futex_wait(&g.done_seq, s, Some(Duration::from_millis(10)));
        }
        Ok(off)
    }

    fn grower_loop(&self) {
        let g = &self.grower;
        let file = &self.lane(self.me).file;
        let z = vec![0u8; 1 << 20];
        loop {
            let seen = g.seq.load(Acquire);
            if g.stop.load(Acquire) {
                return;
            }
            let want = g.want.load(Acquire);
            let a = g.alloc.load(Acquire);
            if want > a {
                let res: std::io::Result<()> = (|| {
                    file.set_len(want)?;
                    let mut o = a;
                    while o < want {
                        let n = (z.len() as u64).min(want - o) as usize;
                        file.write_all_at(&z[..n], o)?;
                        o += n as u64;
                    }
                    file.sync_data()
                })();
                match res {
                    Ok(()) => g.alloc.store(want, Release),
                    Err(_) => g.err.store(true, Release),
                }
                g.done_seq.fetch_add(1, Release);
                futex_wake(&g.done_seq, i32::MAX);
                if g.err.load(Acquire) {
                    futex_wait(&g.seq, g.seq.load(Acquire), Some(Duration::from_millis(10)));
                }
                continue;
            }
            futex_wait(&g.seq, seen, Some(Duration::from_millis(100)));
        }
    }

    /// Appends a sealed record to our lane and publishes it. Writer only.
    fn append_record(&self, rec: &[u8]) -> Result<u64> {
        let off = self.reserve(rec.len() as u64)?;
        unsafe { ptr::copy_nonoverlapping(rec.as_ptr(), self.own_map().add(off as usize), rec.len()) };
        let e = off + rec.len() as u64;
        self.end.store(e, Release);
        self.lane(self.me).end.store(e, Release);
        self.publish();
        self.wseq.fetch_add(1, Release);
        Ok(off)
    }

    fn append_simple(&self, kind: u8, body: &[u8]) -> Result<u64> {
        let mut b = std::mem::take(&mut self.ws().rec_buf);
        b.clear();
        b.extend_from_slice(&[0u8; 9]);
        b[8] = kind;
        b.extend_from_slice(body);
        let n = b.len();
        seal(&mut b, n);
        let r = self.append_record(&b);
        self.ws().rec_buf = b;
        r
    }

    /// Our lane's ref for a scope, writing the scope down first if new.
    fn own_ref_of(&self, sid: u32) -> Result<u32> {
        let r = self.own_ref.get(sid as usize);
        if r != 0 {
            return Ok(r - 1);
        }
        let refs = &self.lane(self.me).scope_refs;
        let rf = refs.count() as u32;
        let mut body = Vec::new();
        ans::put_varint(&mut body, rf as u64);
        body.extend_from_slice(self.scope_name(sid));
        self.append_simple(K_SCOPE, &body)?;
        refs.push(sid)?;
        unsafe { *self.own_ref.at(sid as usize) = rf + 1 };
        Ok(rf)
    }

    /// Codes text with our lane's newest model. Returns (model, coded len),
    /// model 0 meaning stored as is.
    fn code_text(&self, text: &[u8], syms: &mut Vec<u16>, enc: &mut Vec<u8>) -> (u32, usize, usize) {
        let lane = self.lane(self.me);
        let nm = lane.nmodels.load(Acquire) as u32;
        let g = nm as usize;
        if nm == 0 || text.is_empty() {
            return (0, text.len(), g);
        }
        let Some(m) = lane.model(nm) else { return (0, text.len(), g) };
        if syms.len() < text.len() {
            syms.resize(text.len(), 0);
        }
        let b = ans::bound(text.len());
        if enc.len() < b {
            enc.resize(b, 0);
        }
        let n = ans::encode(m, text, &mut syms[..text.len()], &mut enc[..b]);
        if n >= text.len() {
            return (0, text.len(), g);
        }
        (nm, n, g)
    }

    pub fn remember(&self, scope: &[u8], body: &[u8], opts: RememberOptions) -> Result<u64> {
        self.remember_many(&[Item { scope, text: body, subject: opts.subject, time: opts.time }])
    }

    /// Saves memories in order. Returns the first one's id. Writes never
    /// stop to read other writers' lanes (fix 4); reads do.
    pub fn remember_many(&self, items: &[Item]) -> Result<u64> {
        for it in items {
            validate(it.scope, it.subject.unwrap_or(b""), it.text)?;
        }
        let mut first = 0;
        TL.with(|tl| -> Result<()> {
            let tl = &mut *tl.borrow_mut();
            let mut tids = [0u32; TERMS_CAP];
            let mut dfs = [0u32; TERMS_CAP];
            for (k, it) in items.iter().enumerate() {
                // Everything that only reads the index is done before the
                // lock: the words, their counts, which fact this continues,
                // the coding.
                tl.terms.fill(it.text);
                let (mut model, mut n, gen) = self.code_text(it.text, &mut tl.syms, &mut tl.enc);
                let mut link = 0u64;
                {
                    let _r = self.readers.enter();
                    for (i, word) in tl.terms.items().iter().enumerate() {
                        tids[i] = self.term_id(word.key);
                        dfs[i] = if tids[i] != 0 { self.df(tids[i]) } else { self.df_of(word.key) };
                    }
                    if it.subject.is_none() {
                        if let Some(s) = self.scope_id(it.scope) {
                            let nt = tl.terms.len;
                            if let Some(t) = self.find_lineage(s, &tl.terms, &dfs[..nt], &mut tl.ft, &mut tl.text) {
                                link = t + 1;
                            }
                        }
                    }
                }
                let _g = self.wlock.lock();
                if self.ws().broken {
                    return Err(Error::Broken);
                }
                // A new model came meanwhile: code again with it.
                if gen != self.lane(self.me).nmodels.load(Acquire) {
                    (model, n, _) = self.code_text(it.text, &mut tl.syms, &mut tl.enc);
                }
                let stored: &[u8] = if model == 0 { it.text } else { &tl.enc[..n] };
                let nt = tl.terms.len;
                let id = self.append_memory(it, &tl.terms, stored, model, &tids[..nt], link)?;
                if k == 0 {
                    first = id;
                }
            }
            Ok(())
        })?;
        if self.sync_writes && !self.flusher {
            self.sync()?;
        }
        if self.flusher_waiting.load(Acquire) {
            futex_wake(&self.wseq, 1);
        }
        Ok(first)
    }

    /// Writer only (lock held).
    fn append_memory(&self, it: &Item, terms: &Terms, stored: &[u8], model: u32, tids: &[u32], link: u64) -> Result<u64> {
        let sid = self.ensure_scope(it.scope)?;
        let rf = self.own_ref_of(sid)?;
        let subject = it.subject.unwrap_or(b"");
        let time = it.time.unwrap_or_else(|| self.now_ms());
        let ws = self.ws();
        let mut b = std::mem::take(&mut ws.rec_buf);
        b.clear();
        b.extend_from_slice(&[0u8; 9]);
        b[8] = K_MEMORY;
        ans::put_varint(&mut b, time);
        ans::put_varint(&mut b, rf as u64);
        ans::put_varint(&mut b, subject.len() as u64);
        ans::put_varint(&mut b, model as u64);
        ans::put_varint(&mut b, it.text.len() as u64);
        ans::put_varint(&mut b, link);
        b.extend_from_slice(&Crc32c::hash(stored).to_le_bytes());
        b.extend_from_slice(subject);
        let meta_end = b.len();
        b.extend_from_slice(stored);
        seal(&mut b, meta_end);
        let off = self.append_record(&b);
        self.ws().rec_buf = b;
        let off = off?;
        self.index_memory(self.me, off, MemFields { sid, subject, link, erased: false }, terms, Some(tids))?;

        let ws = self.ws();
        ws.written += 1;
        if ws.written & 255 == 0 {
            self.reclaim();
        }
        // A writer learns its words: counts feed the next model.
        if ws.written + 65536 >= ws.next_model_at {
            ws.counter.add(it.text);
        }
        if ws.written >= ws.next_model_at {
            if self.lane(self.me).nmodels.load(Acquire) < MAX_MODELS {
                self.new_model()?;
            }
            let ws = self.ws();
            ws.next_model_at = if ws.next_model_at < 262144 { ws.next_model_at * 16 } else { ws.next_model_at + (1 << 20) };
        }
        Ok(id_of(self.me, off))
    }

    fn new_model(&self) -> Result<()> {
        let m = self.ws().counter.model();
        let mut body = Vec::new();
        ans::serialize(&m, &mut body);
        let off = self.append_simple(K_MODEL, &body)?;
        self.lane(self.me).add_model(m, off)?;
        self.ws().counter.reset();
        Ok(())
    }

    // ------------------------------------------------------------- lineage

    /// The value a memory gives a name: the nearest word in the name's
    /// sentence that no other memory has.
    fn value_of(&self, terms: &Terms, name: Word, new_dfs: Option<&[u32]>) -> Option<Word> {
        let mut best: Option<Word> = None;
        for (i, word) in terms.items().iter().enumerate() {
            if word.key == name.key || word.sent != name.sent || words::is_cue(word.key) {
                continue;
            }
            let one_off = match new_dfs {
                Some(d) => d[i] == 0,
                None => self.df_of(word.key) == 1,
            };
            if !one_off {
                continue;
            }
            if best.is_none_or(|b| abs_diff(word.pos, name.pos) < abs_diff(b.pos, name.pos)) {
                best = Some(*word);
            }
        }
        best
    }

    /// The words of a memory's claim about `anchor`, with how much each
    /// belongs to it.
    fn claim_of(&self, terms: &Terms, anchor: u64, new_dfs: Option<&[u32]>) -> Claim {
        let mut c = Claim::default();
        let Some(ai) = terms.find(anchor) else { return c };
        let name = terms.words[ai];
        let value = self.value_of(terms, name, new_dfs);
        let meaning = self.meaning();
        for word in terms.items() {
            if c.n == c.keys.len() {
                break;
            }
            if word.key == anchor || word.number || words::is_cue(word.key) {
                continue;
            }
            if let Some(v) = value {
                if v.key == word.key {
                    continue;
                }
            }
            let wt = span_weight(*word, name, value);
            if wt == 0.0 {
                continue;
            }
            c.keys[c.n] = word.key;
            c.wts[c.n] = wt;
            c.mi[c.n] = meaning.and_then(|m| m.index(word.key));
            c.n += 1;
        }
        c
    }

    /// The memory a new one updates, if it is a new version of a known fact.
    /// Only reads the index (runs before the write lock).
    fn find_lineage(&self, sid: u32, terms: &Terms, dfs: &[u32], ft: &mut Terms, text: &mut Vec<u8>) -> Option<u64> {
        let n = self.mem_count();
        if n == 0 {
            return None;
        }
        let alim = (n / 256).clamp(1, 64) as u32;
        let rare_lim = (n / 1024).max(4) as u32;
        let mut anchors = [0usize; 3];
        let mut na = 0;
        let mut nnew = 0;
        let mut cue = false;
        for (i, word) in terms.items().iter().enumerate() {
            if words::is_cue(word.key) {
                cue = true;
                continue;
            }
            if dfs[i] == 0 {
                nnew += 1;
            }
            if dfs[i] == 0 || dfs[i] > alim || word.number {
                continue;
            }
            // Keep the three rarest.
            if na < anchors.len() {
                anchors[na] = i;
                na += 1;
            } else {
                let mut worst = 0;
                for k in 1..na {
                    if dfs[anchors[k]] > dfs[anchors[worst]] {
                        worst = k;
                    }
                }
                if dfs[i] < dfs[anchors[worst]] {
                    anchors[worst] = i;
                }
            }
        }
        if na == 0 || nnew == 0 {
            return None;
        }
        if nnew > 1 {
            let rarest = anchors[..na].iter().map(|&a| dfs[a]).min().unwrap_or(u32::MAX);
            if !cue || rarest > 4 {
                return None;
            }
        }
        let parent = self.sc_parent.get(sid as usize);

        // Earlier facts that share an anchor, in the same scope or a sibling.
        let mut facts: [(u32, u64); 32] = [(0, 0); 32];
        let mut nf = 0;
        for &ai in &anchors[..na] {
            let key = terms.words[ai].key;
            let mut p = self.posts_of(key);
            let mut steps = 0;
            while let Some(ord) = self.posts_next(&mut p) {
                if steps >= 64 {
                    break;
                }
                steps += 1;
                if !self.alive(ord) {
                    continue;
                }
                let s = self.sid_of(ord);
                if s != sid && (parent == 0 || self.sc_parent.get(s as usize) != parent) {
                    continue;
                }
                let h = self.head_of(ord);
                if facts[..nf].iter().any(|f| f.0 == h) {
                    continue;
                }
                if nf == facts.len() {
                    break;
                }
                facts[nf] = (h, key);
                nf += 1;
            }
        }
        if nf == 0 {
            return None;
        }

        let meaning = self.meaning();
        let mut best: Option<usize> = None;
        let mut best_s: f32 = -1.0;
        let mut second_s: f32 = 0.0;
        let mut best_shared = 0;
        let mut strong: Option<usize> = None;
        let mut strong_shared = 0;
        for (k, f) in facts[..nf].iter().enumerate() {
            if self.text_of(f.0, text).is_none() {
                continue;
            }
            ft.fill(text);
            // Rare words in common, the name included.
            let mut shared = 0;
            for (i, word) in terms.items().iter().enumerate() {
                if dfs[i] == 0 || dfs[i] > rare_lim {
                    continue;
                }
                if ft.find(word.key).is_some() {
                    shared += 1;
                }
            }
            let mine = self.claim_of(terms, f.1, Some(dfs));
            let theirs = self.claim_of(ft, f.1, None);
            let s = (cover_of(meaning, &mine, &theirs) + cover_of(meaning, &theirs, &mine)) / 2.0;
            if shared >= 3 && shared > strong_shared {
                strong = Some(k);
                strong_shared = shared;
            }
            if s > best_s {
                second_s = second_s.max(best_s);
                best_s = s;
                best = Some(k);
                best_shared = shared;
            } else {
                second_s = second_s.max(s);
            }
        }
        if let Some(k) = strong {
            return Some(self.tl_loc.get(facts[k].0 as usize));
        }
        let k = best?;
        let clear_win = best_s >= second_s * 1.3 + 0.02;
        let link = (cue && nf == 1) || (cue && best_s >= 0.25 && clear_win) || (nf == 1 && best_shared >= 2) || (best_s >= 0.6 && best_s >= second_s * 1.5);
        if link {
            Some(self.tl_loc.get(facts[k].0 as usize))
        } else {
            None
        }
    }

    // ---------------------------------------------------------- durability

    /// Makes every write so far durable. Concurrent callers share one flush
    /// (group commit): the first flushes everything written so far, the
    /// others wait for it and return if it covered them.
    pub fn sync(&self) -> Result<()> {
        if self.erase_pending.load(Acquire) {
            let (lo, hi) = {
                let _g = self.wlock.lock();
                let ws = self.ws();
                let r = (ws.erase_lo, ws.erase_hi);
                ws.erase_lo = u64::MAX;
                ws.erase_hi = 0;
                self.erase_pending.store(false, Release);
                r
            };
            if hi > lo {
                self.flush_own(lo, hi)?;
            }
        }
        let target = self.end.load(Acquire);
        if !self.group_sync {
            let from = self.synced.load(Acquire);
            if from >= target {
                return Ok(());
            }
            self.flush_own(from, target)?;
            self.syncs.fetch_add(1, Relaxed);
            self.synced.fetch_max(target, Release);
            return Ok(());
        }
        loop {
            if self.synced.load(Acquire) >= target {
                return Ok(());
            }
            if self.flushing.compare_exchange(false, true, Acquire, Relaxed).is_ok() {
                let from = self.synced.load(Acquire);
                let to = self.end.load(Acquire);
                let r = if to > from { self.flush_own(from, to) } else { Ok(()) };
                if r.is_ok() && to > from {
                    self.syncs.fetch_add(1, Relaxed);
                    self.synced.fetch_max(to, Release);
                }
                self.flushing.store(false, Release);
                self.dseq.fetch_add(1, Release);
                futex_wake(&self.dseq, i32::MAX);
                r?;
                continue;
            }
            let d = self.dseq.load(Acquire);
            if self.synced.load(Acquire) >= target {
                return Ok(());
            }
            if self.flushing.load(Acquire) {
                futex_wait(&self.dseq, d, Some(Duration::from_millis(5)));
            }
        }
    }

    fn flush_own(&self, from: u64, to: u64) -> Result<()> {
        let lo = align_down(from.min(to), PAGE as u64);
        if to > lo {
            let r = unsafe { libc::msync(self.own_map().add(lo as usize) as *mut libc::c_void, (to - lo) as usize, libc::MS_SYNC) };
            if r != 0 {
                return Err(os_err());
            }
        }
        Ok(())
    }

    /// A promise for everything written so far.
    pub fn promise(&self) -> u64 {
        self.end.load(Acquire)
    }

    pub fn is_durable(&self, p: u64) -> bool {
        self.synced.load(Acquire) >= p
    }

    pub fn wait_durable(&self, p: u64) -> Result<()> {
        if !self.flusher {
            return self.sync();
        }
        let d0 = self.dseq.load(Acquire);
        while self.synced.load(Acquire) < p {
            let d = self.dseq.load(Acquire);
            if d != d0 && self.flusher_err.load(Acquire) != 0 {
                return Err(Error::FlushFailed);
            }
            if self.synced.load(Acquire) >= p {
                break;
            }
            futex_wait(&self.dseq, d, Some(Duration::from_millis(5)));
        }
        Ok(())
    }

    fn flusher_loop(&self) {
        loop {
            let seen = self.wseq.load(Acquire);
            let e = self.end.load(Acquire);
            let sy = self.synced.load(Acquire);
            let pending = e > sy || self.erase_pending.load(Acquire);
            if pending {
                // While writes keep coming, flush whole pages only.
                let whole = align_down(e, PAGE as u64);
                if whole > sy && !self.erase_pending.load(Acquire) {
                    match self.flush_own(sy, whole) {
                        Ok(()) => {
                            self.syncs.fetch_add(1, Relaxed);
                            self.synced.fetch_max(whole, Release);
                            self.flusher_err.store(0, Release);
                        }
                        Err(_) => self.flusher_err.store(1, Release),
                    }
                    self.dseq.fetch_add(1, Release);
                    futex_wake(&self.dseq, i32::MAX);
                    continue;
                }
                if whole <= sy && e > sy && !self.flusher_stop.load(Acquire) {
                    futex_wait(&self.wseq, seen, Some(Duration::from_micros(1000)));
                    if self.wseq.load(Acquire) != seen {
                        continue;
                    }
                }
                match self.sync() {
                    Ok(()) => self.flusher_err.store(0, Release),
                    Err(_) => self.flusher_err.store(1, Release),
                }
                self.dseq.fetch_add(1, Release);
                futex_wake(&self.dseq, i32::MAX);
                if self.flusher_err.load(Acquire) == 0 {
                    continue;
                }
                if self.flusher_stop.load(Acquire) {
                    return;
                }
                futex_wait(&self.wseq, self.wseq.load(Acquire), Some(Duration::from_millis(10)));
                continue;
            }
            if self.flusher_stop.load(Acquire) {
                return;
            }
            self.flusher_waiting.store(true, SeqCst);
            if self.wseq.load(SeqCst) == seen && !self.flusher_stop.load(Acquire) {
                futex_wait(&self.wseq, seen, Some(Duration::from_millis(10)));
            }
            self.flusher_waiting.store(false, Release);
        }
    }

    pub fn sync_count(&self) -> u64 {
        self.syncs.load(Relaxed)
    }

    // --------------------------------------------------------- other lanes

    fn maybe_refresh(&self) -> Result<()> {
        let now = self.mono_ms();
        let last = self.last_refresh.load(Relaxed);
        if now - last < 20 {
            return Ok(());
        }
        if self.last_refresh.compare_exchange(last, now, Relaxed, Relaxed).is_err() {
            return Ok(());
        }
        let _g = self.wlock.lock();
        self.refresh_locked()
    }

    /// Reads what other writers added since we last looked.
    pub fn refresh(&self) -> Result<()> {
        let _g = self.wlock.lock();
        self.refresh_locked()
    }

    fn refresh_locked(&self) -> Result<()> {
        while self.nlanes.load(Acquire) < MAX_LANES {
            if !self.open_lane(self.nlanes.load(Acquire))? {
                break;
            }
        }
        for l in 0..self.nlanes.load(Acquire) {
            if l == self.me {
                continue;
            }
            let lane = self.lane(l);
            if lane.idle.load(Relaxed) {
                self.replay_lane(l, lane.file.metadata()?.len())?;
                let _ = flock(&lane.file, libc::LOCK_UN);
                lane.idle.store(false, Relaxed);
                continue;
            }
            let p = lane.published();
            if p > lane.end.load(Acquire) {
                self.replay_lane(l, p.min(lane.file.metadata()?.len()))?;
            }
        }
        Ok(())
    }

    // -------------------------------------------------------------- forget

    /// Zeroes a memory's text in our lane and marks it erased. Writer only.
    fn erase_own(&self, off: u64) -> Result<()> {
        let e = self.lane(self.me).end.load(Acquire);
        if off >= e {
            return Ok(());
        }
        let b = unsafe { std::slice::from_raw_parts_mut(self.own_map(), e as usize) };
        let Some(r) = parse_rec(&b[off as usize..]) else { return Ok(()) };
        if r.kind != K_MEMORY || r.erased {
            return Ok(());
        }
        let lo = off + r.text_at as u64;
        let hi = off + r.len as u64;
        b[lo as usize..hi as usize].fill(0);
        let kb = unsafe { std::sync::atomic::AtomicU8::from_ptr(b.as_mut_ptr().add(off as usize + 8)) };
        kb.fetch_or(ERASED_BIT, Release);
        let ws = self.ws();
        ws.erase_lo = ws.erase_lo.min(off);
        ws.erase_hi = ws.erase_hi.max(hi);
        self.erase_pending.store(true, Release);
        Ok(())
    }

    /// Lane ends this writer knows of: every record before them is covered.
    fn known_ends(&self, out: &mut Vec<u8>) {
        let n = self.nlanes.load(Acquire);
        ans::put_varint(out, n as u64);
        for l in 0..n {
            ans::put_varint(out, if l == self.me { self.end.load(Acquire) } else { self.lane(l).end.load(Acquire) });
        }
    }

    fn append_and_ingest(&self, kind: u8, body: &[u8]) -> Result<()> {
        let off = self.append_simple(kind, body)?;
        let e = self.end.load(Acquire);
        let b = unsafe { std::slice::from_raw_parts(self.own_map(), e as usize) };
        let r = parse_rec(&b[off as usize..]).ok_or(Error::Corrupt)?;
        self.ingest(self.me, off, &r)
    }

    /// Forgets a scope and everything below it, in every lane. Returns how
    /// many memories were forgotten.
    pub fn forget_scope(&self, scope: &[u8]) -> Result<usize> {
        if scope.is_empty() || scope.len() > 1024 {
            return Err(Error::InvalidScope);
        }
        let n = {
            let _g = self.wlock.lock();
            self.refresh_locked()?;
            let mut n = 0;
            if let Some(sid) = self.scope_id(scope) {
                let mut ids = Vec::new();
                self.subtree(sid, &mut ids);
                for s in ids {
                    let mut p = self.scope_posts(s);
                    while let Some(ord) = self.posts_next(&mut p) {
                        if self.alive(ord) {
                            n += 1;
                        }
                    }
                }
            }
            let mut body = Vec::new();
            self.known_ends(&mut body);
            body.extend_from_slice(scope);
            self.append_and_ingest(K_FORGET_SCOPE, &body)?;
            n
        };
        if self.sync_writes && !self.flusher {
            self.sync()?;
        }
        Ok(n)
    }

    /// Forgets one memory.
    pub fn forget(&self, id: u64) -> Result<()> {
        {
            let _g = self.wlock.lock();
            self.ord_of(id).ok_or(Error::NotFound)?;
            let mut body = Vec::new();
            ans::put_varint(&mut body, id);
            self.append_and_ingest(K_FORGET_ONE, &body)?;
        }
        if self.sync_writes && !self.flusher {
            self.sync()?;
        }
        Ok(())
    }

    /// Adds a summary of a scope and settles everything before it: older
    /// memories stay in `deep` recall, normal answers use the summary.
    pub fn settle(&self, scope: &[u8], summary: &[u8]) -> Result<u64> {
        let id = self.remember(scope, summary, RememberOptions { subject: Some(b"summary"), time: None })?;
        {
            let _g = self.wlock.lock();
            let n = self.nlanes.load(Acquire);
            let mut body = Vec::new();
            ans::put_varint(&mut body, n as u64);
            for l in 0..n {
                ans::put_varint(&mut body, if l == self.me { off_of(id) } else { self.lane(l).end.load(Acquire) });
            }
            body.extend_from_slice(scope);
            self.append_and_ingest(K_SETTLE, &body)?;
        }
        if self.sync_writes && !self.flusher {
            self.sync()?;
        }
        Ok(id)
    }

    // --------------------------------------------------------------- reads

    pub fn get(&self, id: u64) -> Result<Option<Memory>> {
        self.maybe_refresh()?;
        let _r = self.readers.enter();
        let Some(ord) = self.ord_of(id) else { return Ok(None) };
        self.load(ord)
    }

    /// The `n` memories most recently written to one scope, newest first.
    pub fn recent(&self, scope: &[u8], n: usize) -> Result<Vec<Memory>> {
        self.recent_filtered(scope, n, false)
    }

    fn recent_filtered(&self, scope: &[u8], n: usize, skip_buried: bool) -> Result<Vec<Memory>> {
        self.maybe_refresh()?;
        let _r = self.readers.enter();
        let mut out = Vec::new();
        let Some(sid) = self.scope_id(scope) else { return Ok(out) };
        out.reserve(n);
        let mut p = self.scope_posts(sid);
        while out.len() < n {
            let Some(ord) = self.posts_next(&mut p) else { break };
            if skip_buried && self.is_buried(ord) {
                continue;
            }
            if let Some(m) = self.load(ord)? {
                out.push(m);
            }
        }
        Ok(out)
    }

    /// The current memory for a subject in a scope.
    pub fn current(&self, scope: &[u8], subject: &[u8]) -> Result<Option<Memory>> {
        self.maybe_refresh()?;
        let _r = self.readers.enter();
        let Some(sid) = self.scope_id(scope) else { return Ok(None) };
        let Some(c) = self.subjects.get(Self::subject_key(sid, subject)) else { return Ok(None) };
        let head = ld32(unsafe { addr_of_mut!((*self.cells.at(c as usize)).head) });
        self.load(head)
    }

    // -------------------------------------------------------------- recall

    /// Facts ranked by how well any of their versions matches `about`,
    /// answered with each fact's newest version.
    pub fn recall(&self, q: &Query) -> Result<Vec<Hit>> {
        self.maybe_refresh()?;
        let _r = self.readers.enter();
        let limit = q.limit.max(1);
        let mut hits = Vec::new();
        if self.mem_count() == 0 {
            return Ok(hits);
        }
        let Some(set) = self.scope_set(q.scope) else { return Ok(hits) };
        SEARCH.with(|cell| {
            let mut guard = cell.borrow_mut();
            let s = guard.get_or_insert_with(|| Box::new(Search::new()));
            s.reset(if q.expand { self.meaning() } else { None }, self.now_ms(), self.half_life_ms, q.since);
            self.recall_in(s, q, set, limit, &mut hits)?;
            Ok(hits)
        })
    }

    fn recall_in(&self, s: &mut Search, q: &Query, set: ScopeSet, limit: usize, hits: &mut Vec<Hit>) -> Result<()> {
        s.terms.fill(q.about);
        if s.terms.len == 0 {
            return self.newest_into(set, q, limit, hits);
        }
        let meaning = s.meaning();

        // Question words by the bits they carry. A word the store never saw
        // can only match by meaning.
        let n = self.mem_count();
        let mut cand_g: Vec<(u64, u32, f32, Option<u32>)> = Vec::with_capacity(s.terms.len);
        for word in s.terms.items() {
            let tid = self.term_id(word.key);
            let d = self.df_of(word.key);
            let mi = meaning.and_then(|m| m.index(word.key));
            if d == 0 && mi.is_none() {
                continue;
            }
            let bits = if d == 0 { ((n + 1) as f32).log2() } else { self.idf(d) };
            cand_g.push((word.key, tid, bits.min(20.0), mi));
        }
        if cand_g.is_empty() {
            return Ok(());
        }
        cand_g.sort_unstable_by(|a, b| b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal));
        s.ng = cand_g.len().min(MAX_GROUPS);
        for (i, g) in cand_g[..s.ng].iter().enumerate() {
            s.gw[i] = g.2;
            s.gmi[i] = g.3;
            s.wsum += g.2;
            s.qt.push(QTerm { key: g.0, group: i as u8, sim: 1.0 });
        }
        if let Some(m) = meaning {
            for (g, cg) in cand_g[..s.ng].iter().enumerate() {
                let mut rel = [Related { key: 0, sim: 0.0 }; MAX_RELATED];
                let k = m.related(cg.0, MIN_RELATED_SIM, &mut rel);
                for r in &rel[..k] {
                    if s.qt.iter().any(|t| t.key == r.key) {
                        continue;
                    }
                    s.qt.push(QTerm { key: r.key, group: g as u8, sim: r.sim });
                }
            }
        }

        // Posting lists of the findable words; a word too common to keep
        // postings only confirms. Rare words (short lists) first.
        let mut findable_w = 0.0f32;
        let mut have_lists = false;
        let mut rare: Vec<(usize, Posts)> = Vec::new();
        let mut common: Vec<(usize, Posts)> = Vec::new();
        let mut common_w = [0.0f32; MAX_GROUPS];
        for (qi, t) in s.qt.iter().enumerate() {
            let p = self.posts_of(t.key);
            if p.is_empty() {
                continue;
            }
            have_lists = true;
            if t.sim == 1.0 {
                findable_w += s.gw[t.group as usize];
            }
            if self.df_of(t.key) <= RARE_DF {
                rare.push((qi, p));
            } else {
                common.push((qi, p));
                let g = t.group as usize;
                common_w[g] = common_w[g].max(t.sim * s.gw[g]);
            }
        }
        let extra = if meaning.is_some() { s.wsum } else { s.wsum - findable_w };
        let posts_only = meaning.is_none() && extra <= 0.001 && have_lists;

        let mut facts: Vec<FactHit> = Vec::new();
        let mut decoded = 0usize;
        let mut scored: Vec<u32> = Vec::new();
        let mut done = false;
        if !have_lists {
            // Nothing findable: the newest memories of the scope, read whole.
            let mut cands = Vec::new();
            self.newest_ords(set, 64, &mut cands);
            self.rank(s, q, set, &cands, extra, false, limit, &mut facts, &mut decoded, &scored)?;
            done = true;
        } else if meaning.is_none() && !rare.is_empty() && !common.is_empty() {
            // Rare words first: their few memories are read whole. If they
            // fill the top results so well that a memory with only the
            // common words could not enter, the long lists are never read.
            let cw: f32 = common_w.iter().sum();
            self.collect(s, &rare);
            let cands = std::mem::take(&mut s.cands);
            self.rank(s, q, set, &cands, cw + extra, false, limit, &mut facts, &mut decoded, &scored)?;
            scored.extend(cands.iter().map(|c| c.ord));
            s.cands = cands;
            if facts.len() >= limit && s.bound(cw + extra) < kth_score(&facts, limit) {
                done = true;
            }
            scored.sort_unstable();
        }
        if !done {
            rare.extend_from_slice(&common);
            self.collect(s, &rare);
            let cands = std::mem::take(&mut s.cands);
            self.rank(s, q, set, &cands, extra, posts_only, limit, &mut facts, &mut decoded, &scored)?;
            s.cands = cands;
        }
        facts.sort_unstable_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal).then(b.ord.cmp(&a.ord)));

        // Answer with each fact's newest version.
        let mut pre: Vec<Pre> = Vec::new();
        for f in &facts {
            let mut ord = f.ord;
            if !q.deep {
                let h = self.head_of(f.ord);
                if h != f.ord && self.alive(h) {
                    ord = h;
                }
                if self.settled(ord) {
                    continue;
                }
            }
            let Some(r) = self.rec_of(self.tl_loc.get(ord as usize)) else { continue };
            if q.since > 0 && ord != f.ord && r.time < q.since {
                continue;
            }
            pre.push(Pre { ord, score: f.score, mask: f.mask, time: r.time, buried: q.deep && self.is_buried(ord) });
            if pre.len() >= limit * 2 + 4 {
                break;
            }
        }
        if !q.deep {
            sediment_hits(&mut pre);
        }
        for x in &pre {
            if hits.len() == limit {
                break;
            }
            if !q.deep && x.buried {
                continue;
            }
            let Some(m) = self.load(x.ord)? else { continue };
            hits.push(Hit { memory: m, score: x.score, buried: x.buried, matched: x.mask });
        }
        Ok(())
    }

    /// Merges posting lists (each already newest first) into candidates,
    /// each with its best match per question group, then orders them best
    /// first (newest first among equals). No liveness check here: that is
    /// done only for candidates `rank` actually reaches.
    fn collect(&self, s: &mut Search, lists: &[(usize, Posts)]) {
        s.cands.clear();
        s.heads.clear();
        for &(qi, p) in lists {
            let mut p = p;
            let budget = if s.qt[qi].sim == 1.0 { 8192 } else { 1024 };
            if let Some(o) = self.posts_next(&mut p) {
                s.heads.push(Head { cur: o, p, qi, left: budget - 1 });
            }
        }
        while !s.heads.is_empty() {
            let mut top = 0u32;
            for h in &s.heads {
                top = top.max(h.cur);
            }
            let mut gbest = [0.0f32; MAX_GROUPS];
            let mut mask = 0u8;
            let mut i = 0;
            while i < s.heads.len() {
                if s.heads[i].cur == top {
                    let t = s.qt[s.heads[i].qi];
                    let g = t.group as usize;
                    gbest[g] = gbest[g].max(t.sim);
                    if t.sim == 1.0 {
                        mask |= 1 << g;
                    }
                    let h = &mut s.heads[i];
                    let next = if h.left > 0 { self.posts_next(&mut h.p) } else { None };
                    match next {
                        Some(o) => {
                            h.cur = o;
                            h.left -= 1;
                            i += 1;
                        }
                        None => {
                            s.heads.swap_remove(i);
                        }
                    }
                } else {
                    i += 1;
                }
            }
            let mut s1 = 0.0f32;
            for g in 0..s.ng {
                s1 += gbest[g] * s.gw[g];
            }
            s.cands.push(Cand { ord: top, s1, mask });
        }
        // Best first, newest first among equals: a stable sort of a list
        // that is already newest first. Without meaning, s1 depends only on
        // the mask, so a counting sort by mask does it in one pass.
        if s.meaning.is_none() {
            let mut key_of = [0.0f32; 256];
            let mut present = [false; 256];
            for c in &s.cands {
                present[c.mask as usize] = true;
            }
            let mut masks: Vec<u8> = (0..=255u8).filter(|&m| present[m as usize]).collect();
            for &m in &masks {
                key_of[m as usize] = (0..s.ng).filter(|&g| m & (1 << g) != 0).map(|g| s.gw[g]).sum();
            }
            masks.sort_by(|a, b| key_of[*b as usize].partial_cmp(&key_of[*a as usize]).unwrap_or(std::cmp::Ordering::Equal));
            // Masks with equal sums share a bucket, so their order is by ord.
            let mut bucket_of = [0usize; 256];
            let mut nb = 0;
            let mut prev = f32::NAN;
            for &m in &masks {
                if key_of[m as usize] != prev {
                    nb += 1;
                    prev = key_of[m as usize];
                }
                bucket_of[m as usize] = nb - 1;
            }
            if nb > 1 {
                let mut counts = vec![0usize; nb + 1];
                for c in &s.cands {
                    counts[bucket_of[c.mask as usize] + 1] += 1;
                }
                for b in 1..=nb {
                    counts[b] += counts[b - 1];
                }
                s.sorted.clear();
                s.sorted.resize(s.cands.len(), Cand { ord: 0, s1: 0.0, mask: 0 });
                for c in &s.cands {
                    let b = bucket_of[c.mask as usize];
                    s.sorted[counts[b]] = *c;
                    counts[b] += 1;
                }
                std::mem::swap(&mut s.cands, &mut s.sorted);
            }
        } else {
            s.cands.sort_by(|a, b| b.s1.partial_cmp(&a.s1).unwrap_or(std::cmp::Ordering::Equal));
        }
    }

    /// Reads candidates best first; stops when no later one can enter the
    /// top `limit` facts.
    #[allow(clippy::too_many_arguments)]
    fn rank(&self, s: &mut Search, q: &Query, set: ScopeSet, cands: &[Cand], extra: f32, posts_only: bool, limit: usize, facts: &mut Vec<FactHit>, decoded: &mut usize, skip: &[u32]) -> Result<()> {
        for c in cands {
            if *decoded >= MAX_DECODE {
                break;
            }
            if facts.len() >= limit && s.bound(c.s1 + extra) < kth_score(facts, limit) {
                break;
            }
            if !self.alive(c.ord) || !set.has(self, self.sid_of(c.ord)) {
                continue;
            }
            if !skip.is_empty() && skip.binary_search(&c.ord).is_ok() {
                continue;
            }
            let sc = if posts_only { self.score_from_posts(s, c.ord, c.s1, c.mask) } else { self.score(s, c.ord) };
            let Some(sc) = sc else { continue };
            if !posts_only {
                *decoded += 1;
            }
            let cell = self.cell_of(c.ord);
            let key = if q.deep || cell == 0 { c.ord as u64 } else { (1u64 << 32) | cell as u64 };
            if let Some(f) = facts.iter_mut().find(|f| f.key == key) {
                if sc.0 > f.score {
                    f.score = sc.0;
                    f.ord = c.ord;
                    f.mask = sc.1;
                }
            } else {
                facts.push(FactHit { key, ord: c.ord, score: sc.0, mask: sc.1 });
            }
        }
        Ok(())
    }

    /// Score of a whole memory: question bits it holds, by words or by
    /// meaning, times the share of the question covered (squared), times
    /// recency.
    fn score(&self, s: &mut Search, ord: u32) -> Option<(f32, u8)> {
        let (time, subject) = self.text_of(ord, &mut s.text)?;
        if time < s.since {
            return None;
        }
        s.mterms.fill(&s.text);
        let mut m = [0.0f32; MAX_GROUPS];
        let mut mask = 0u8;
        let mut lexpos: [Option<usize>; MAX_GROUPS] = [None; MAX_GROUPS];
        for q in &s.qt {
            if let Some(i) = s.mterms.find(q.key) {
                let g = q.group as usize;
                if q.sim > m[g] {
                    m[g] = q.sim;
                }
                if q.sim == 1.0 {
                    mask |= 1 << g;
                    lexpos[g] = Some(i);
                }
            }
        }
        if let Some(mn) = s.meaning() {
            // The claim about the rarest name the question shares with
            // this memory: the words between the name and its value.
            let name = lexpos[..s.ng].iter().flatten().next().map(|&i| s.mterms.words[i]);
            let value = name.and_then(|nm| self.value_of(&s.mterms, nm, None));
            let mut best = [0.0f32; MAX_GROUPS];
            for wi in 0..s.mterms.len {
                let word = s.mterms.words[wi];
                let Some(mi) = mn.index(word.key) else { continue };
                if lexpos[..s.ng].iter().flatten().any(|&i| s.mterms.words[i].key == word.key) {
                    continue;
                }
                let wt = match name {
                    Some(nm) => span_weight(word, nm, value),
                    None => 0.5,
                };
                if wt == 0.0 {
                    continue;
                }
                let sv = s.sims(mn, mi);
                for g in 0..s.ng {
                    best[g] = best[g].max(sv[g] * wt);
                }
            }
            for g in 0..s.ng {
                if s.gmi[g].is_some() && m[g] < 1.0 {
                    m[g] = m[g].max(((best[g] - SIM_FLOOR) / (1.0 - SIM_FLOOR)).clamp(0.0, 1.0));
                }
            }
        }
        let mut base = 0.0f32;
        for g in 0..s.ng {
            base += s.gw[g] * m[g];
        }
        if base <= 0.0 {
            return None;
        }
        let cov = base / s.wsum;
        let subj = if subject { 1.1 } else { 1.0 };
        Some((base * cov * cov * s.recency(time) * subj, mask))
    }

    /// Score from the postings alone, when every question word was
    /// findable and meaning is off: only the record's time is read.
    fn score_from_posts(&self, s: &Search, ord: u32, s1: f32, mask: u8) -> Option<(f32, u8)> {
        let r = self.rec_of(self.tl_loc.get(ord as usize))?;
        if r.erased || r.time < s.since || s1 <= 0.0 {
            return None;
        }
        let cov = s1 / s.wsum;
        let subj = if !r.subject.is_empty() { 1.1 } else { 1.0 };
        Some((s1 * cov * cov * s.recency(r.time) * subj, mask))
    }

    /// The newest live ordinals in a scope set.
    fn newest_ords(&self, set: ScopeSet, max: usize, out: &mut Vec<Cand>) {
        if set.all {
            let mut o = self.mem_count();
            while o > 0 && out.len() < max {
                o -= 1;
                if self.alive(o as u32) {
                    out.push(Cand { ord: o as u32, s1: 0.0, mask: 0 });
                }
            }
            return;
        }
        let mut ids = Vec::new();
        self.subtree(set.root, &mut ids);
        let mut lists: Vec<(Posts, Option<u32>)> = ids
            .iter()
            .map(|&sid| {
                let mut p = self.scope_posts(sid);
                let h = self.posts_next(&mut p);
                (p, h)
            })
            .collect();
        while out.len() < max {
            let mut bi: Option<usize> = None;
            for (i, l) in lists.iter().enumerate() {
                if let Some(v) = l.1 {
                    if bi.is_none_or(|b| v > lists[b].1.unwrap()) {
                        bi = Some(i);
                    }
                }
            }
            let Some(i) = bi else { break };
            let o = lists[i].1.unwrap();
            let mut p = lists[i].0;
            lists[i].1 = self.posts_next(&mut p);
            lists[i].0 = p;
            if self.alive(o) {
                out.push(Cand { ord: o, s1: 0.0, mask: 0 });
            }
        }
    }

    fn newest_into(&self, set: ScopeSet, q: &Query, limit: usize, hits: &mut Vec<Hit>) -> Result<()> {
        let mut c = Vec::new();
        self.newest_ords(set, limit * 4 + 16, &mut c);
        for x in &c {
            if hits.len() == limit {
                break;
            }
            let buried = self.is_buried(x.ord);
            if buried && !q.deep {
                continue;
            }
            let Some(m) = self.load(x.ord)? else { continue };
            if m.time < q.since {
                continue;
            }
            hits.push(Hit { memory: m, score: x.ord as f32, buried, matched: 0 });
        }
        Ok(())
    }

    // --------------------------------------------------------------- brief

    /// A briefing for an agent: the facts that matter for `situation`, each
    /// in its newest version only, then the newest in the scope, never over
    /// `budget` tokens (4 bytes a token).
    pub fn brief(&self, situation: &[u8], scope: &[u8], budget: usize) -> Result<Brief> {
        let mut out: Vec<u8> = Vec::new();
        let hits = self.recall(&Query { about: situation, scope, limit: 16, ..Default::default() })?;
        let exact = {
            let _r = self.readers.enter();
            !scope.is_empty() && self.scope_id(scope).is_some()
        };
        let rec_ms = if exact { self.recent_filtered(scope, 6, true)? } else { Vec::new() };
        let mut used = 0usize;
        let mut items = 0usize;
        let mut seen: Vec<u64> = Vec::with_capacity(64);
        let now = self.now_ms();
        let rel: Vec<&Memory> = hits.iter().map(|h| &h.memory).collect();
        let recm: Vec<&Memory> = rec_ms.iter().collect();
        let sections: [(&str, &[&Memory]); 2] = [("Relevant memory", &rel), ("Recent in this scope", &recm)];
        for (title, mems) in sections {
            let mut header_done = false;
            for m in mems {
                if seen.contains(&m.id) {
                    continue;
                }
                let text = m.text();
                let snippet = &text[..text.len().min(600)];
                let cost = (snippet.len() + m.scope().len() + 40 + 3) / 4;
                if used + cost > budget {
                    continue;
                }
                if !header_done {
                    let _ = writeln!(out, "## {}", title);
                    header_done = true;
                }
                let age_s = now.saturating_sub(m.time) / 1000;
                let (v, u) = if age_s < 3600 {
                    (age_s / 60, "m")
                } else if age_s < 86400 {
                    (age_s / 3600, "h")
                } else {
                    (age_s / 86400, "d")
                };
                let _ = write!(out, "- [{}{} ago ", v, u);
                out.extend_from_slice(m.scope());
                out.extend_from_slice(b"] ");
                out.extend_from_slice(snippet);
                if snippet.len() < text.len() {
                    out.extend_from_slice(b"...");
                }
                out.push(b'\n');
                used += cost;
                items += 1;
                if seen.len() < 64 {
                    seen.push(m.id);
                }
            }
        }
        Ok(Brief { text: out, tokens: used, items, buried_skipped: 0 })
    }

    // ---------------------------------------------------------------- info

    pub fn info(&self) -> Info {
        let _r = self.readers.enter();
        let nl = self.nlanes.load(Acquire);
        let mut bytes = 0u64;
        let mut idx = self.lex.bytes() + self.fact_of.bytes() + self.subjects.bytes() + self.sc_map.bytes();
        for v in self.index_vecs() {
            idx += v.len.load(Acquire) * v.size;
        }
        let mut mb = 0usize;
        for l in 0..nl {
            let lane = self.lane(l);
            bytes += if l == self.me { self.end.load(Acquire) } else { lane.end.load(Acquire) };
            idx += lane.ords.count() * 4;
            for i in 1..=lane.nmodels.load(Acquire) {
                if let Some(m) = lane.model(i as u32) {
                    mb += m.ram_bytes();
                }
            }
        }
        let strata = self.cells.items()[1..].iter().filter(|c| c.nver > 1).count();
        Info { memories: self.mem_count() as u64, scopes: self.sc_parent.count() - 1, subjects: self.subjects.len.load(Relaxed), strata, auto_merges: self.merges.load(Relaxed), lanes: nl, file_bytes: bytes, index_bytes: idx, model_bytes: mb }
    }

    /// Calls `f(scope ++ subject ++ text, time)` for every live memory: the
    /// cost of answering without an index.
    pub fn scan_all(&self, mut f: impl FnMut(&[u8], u64)) -> Result<()> {
        let _r = self.readers.enter();
        let mut buf: Vec<u8> = Vec::new();
        for lane in 0..self.nlanes.load(Acquire) {
            let b = self.lane_bytes(lane);
            let refs = &self.lane(lane).scope_refs;
            let mut pos = DATA_START as usize;
            while pos < b.len() {
                let Some(r) = parse_rec(&b[pos..]) else { break };
                let at_pos = pos;
                pos += r.len as usize;
                if r.kind != K_MEMORY || r.erased {
                    continue;
                }
                if r.scope_ref as usize >= refs.count() {
                    continue;
                }
                let Some(ord) = self.ord_of(id_of(lane, at_pos as u64)) else { continue };
                if !self.alive(ord) {
                    continue;
                }
                buf.clear();
                buf.extend_from_slice(self.scope_name(refs.get(r.scope_ref as usize)));
                buf.extend_from_slice(r.subject);
                let at = buf.len();
                buf.resize(at + r.raw_len as usize, 0);
                if self.decode_text(lane, &r, &mut buf[at..]).is_err() {
                    continue;
                }
                if Crc32c::hash(r.text) != r.text_crc {
                    continue;
                }
                f(&buf, r.time);
            }
        }
        Ok(())
    }

    // ------------------------------------------------------------ snapshot
    //
    // Written at close: every index array, page-aligned, so opening maps
    // them straight back (copy-on-write) instead of rebuilding, then reads
    // only the records added after.

    fn write_snapshot(&self) -> Result<()> {
        // Everything the snapshot covers must be on disk first.
        self.flush_own(DATA_START, self.end.load(Acquire))?;
        let nl = self.nlanes.load(Acquire);
        for l in 0..nl {
            if l != self.me {
                self.lane(l).file.sync_all()?;
            }
        }
        // Each writer writes its own temporary file.
        let tmp = self.dir.join(format!("index-{:03}.tmp", self.me));
        let f = OpenOptions::new().read(true).write(true).create(true).truncate(true).open(&tmp)?;
        let res = (|| -> Result<()> {
            let mut sw = SnapWriter { file: &f, pos: HEAD_BYTES as u64, secs: Vec::new() };
            for v in self.index_vecs() {
                let n = v.len.load(Acquire);
                sw.add(unsafe { std::slice::from_raw_parts(v.mem, n * v.size) }, n as u64)?;
            }
            for m in [&self.lex, &self.fact_of, &self.subjects, &self.sc_map] {
                sw.add_map(m)?;
            }
            for l in 0..nl {
                let lane = self.lane(l);
                let n = lane.ords.count();
                sw.add(unsafe { std::slice::from_raw_parts(lane.ords.mem, n * 4) }, n as u64)?;
                let n = lane.scope_refs.count();
                sw.add(unsafe { std::slice::from_raw_parts(lane.scope_refs.mem, n * 4) }, n as u64)?;
                let offs = unsafe { &*lane.model_offs.get() };
                sw.add(as_bytes(offs), offs.len() as u64)?;
            }
            // Pad to a whole page so the last section maps.
            f.set_len(sw.pos)?;
            let mut hb = vec![0u8; HEAD_BYTES];
            hb[0..8].copy_from_slice(SNAP_MAGIC);
            hb[8..12].copy_from_slice(&SNAP_VERSION.to_le_bytes());
            hb[12..16].copy_from_slice(&(nl as u32).to_le_bytes());
            hb[16..24].copy_from_slice(&self.ws().total_terms.to_le_bytes());
            hb[24..32].copy_from_slice(&self.merges.load(Relaxed).to_le_bytes());
            for l in 0..nl {
                let e = if l == self.me { self.end.load(Acquire) } else { self.lane(l).end.load(Acquire) };
                hb[32 + l * 8..40 + l * 8].copy_from_slice(&e.to_le_bytes());
            }
            hb[SH_NSEC..SH_NSEC + 4].copy_from_slice(&(sw.secs.len() as u32).to_le_bytes());
            for (i, s) in sw.secs.iter().enumerate() {
                let o = SH_SIZE + i * 24;
                hb[o..o + 8].copy_from_slice(&s.0.to_le_bytes());
                hb[o + 8..o + 16].copy_from_slice(&s.1.to_le_bytes());
                hb[o + 16..o + 24].copy_from_slice(&s.2.to_le_bytes());
            }
            let crc = Crc32c::hash(&hb[..SH_CRC]) ^ Crc32c::hash(&hb[SH_SIZE..SH_SIZE + sw.secs.len() * 24]);
            hb[SH_CRC..SH_CRC + 4].copy_from_slice(&crc.to_le_bytes());
            f.write_all_at(&hb, 0)?;
            f.sync_data()?;
            std::fs::rename(&tmp, self.dir.join(SNAP_NAME))?;
            Ok(())
        })();
        if res.is_err() {
            let _ = std::fs::remove_file(&tmp);
        } else {
            self.ws().dirty = false;
        }
        res
    }

    /// Maps the snapshot back. Returns each lane's covered end, or None when
    /// there is none. Only the checksummed header and section table are
    /// checked here; entries are bounds-checked when used (fix 3).
    fn load_snapshot(&self) -> Result<Option<[u64; MAX_LANES]>> {
        let f = match File::open(self.dir.join(SNAP_NAME)) {
            Ok(f) => f,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        };
        let flen = f.metadata()?.len();
        let mut hb = vec![0u8; HEAD_BYTES];
        if flen < HEAD_BYTES as u64 {
            return Err(Error::Corrupt);
        }
        f.read_exact_at(&mut hb, 0)?;
        let u32at = |o: usize| u32::from_le_bytes(hb[o..o + 4].try_into().unwrap());
        let u64at = |o: usize| u64::from_le_bytes(hb[o..o + 8].try_into().unwrap());
        if &hb[0..8] != SNAP_MAGIC || u32at(8) != SNAP_VERSION {
            return Err(Error::Corrupt);
        }
        let nlanes = u32at(12) as usize;
        let ns = u32at(SH_NSEC) as usize;
        if ns > MAX_SECTIONS || nlanes > self.nlanes.load(Acquire) || SH_SIZE + ns * 24 > HEAD_BYTES {
            return Err(Error::Corrupt);
        }
        let crc = Crc32c::hash(&hb[..SH_CRC]) ^ Crc32c::hash(&hb[SH_SIZE..SH_SIZE + ns * 24]);
        if crc != u32at(SH_CRC) {
            return Err(Error::Corrupt);
        }
        let secs: Vec<(u64, u64, u64)> = (0..ns).map(|i| (u64at(SH_SIZE + i * 24), u64at(SH_SIZE + i * 24 + 8), u64at(SH_SIZE + i * 24 + 16))).collect();
        for s in &secs {
            if s.0 % PAGE as u64 != 0 || s.0 + align_up(s.1, PAGE as u64) > flen {
                return Err(Error::Corrupt);
            }
        }
        let mut ends = [DATA_START; MAX_LANES];
        for (l, e) in ends.iter_mut().enumerate().take(nlanes) {
            *e = u64at(32 + l * 8);
            if *e > self.lane(l).file.metadata()?.len() {
                return Err(Error::Corrupt);
            }
        }
        if ns != 20 + 4 * 2 + nlanes * 3 {
            return Err(Error::Corrupt);
        }
        self.reset_index()?;
        let r = (|| -> Result<()> {
            let mut k = 0;
            for v in self.index_vecs() {
                map_section(&f, secs[k], v)?;
                k += 1;
            }
            for m in [&self.lex, &self.fact_of, &self.subjects, &self.sc_map] {
                read_map(&f, secs[k], secs[k + 1], m)?;
                k += 2;
            }
            // Refs into our lane are ours alone: the snapshot's writer had
            // its own.
            self.own_ref.items_mut().fill(0);
            for l in 0..nlanes {
                let lane = self.lane(l);
                map_section(&f, secs[k], lane.ords.any())?;
                map_section(&f, secs[k + 1], lane.scope_refs.any())?;
                let offs: Vec<u64> = read_list(&f, secs[k + 2])?;
                k += 3;
                lane.end.store(ends[l], Release);
                for o in offs {
                    if o < DATA_START || o >= ends[l] {
                        return Err(Error::Corrupt);
                    }
                    let b = unsafe { std::slice::from_raw_parts(lane.map, ends[l] as usize) };
                    let r = parse_rec(&b[o as usize..]).ok_or(Error::Corrupt)?;
                    if r.kind != K_MODEL {
                        return Err(Error::Corrupt);
                    }
                    lane.add_model(ans::parse(r.body)?, o)?;
                }
                let nsc = self.own_ref.count() as u32;
                for (rf, &sid) in lane.scope_refs.items().iter().enumerate() {
                    if sid >= nsc {
                        return Err(Error::Corrupt);
                    }
                    if l == self.me {
                        unsafe { *self.own_ref.at(sid as usize) = rf as u32 + 1 };
                    }
                }
            }
            self.ws().total_terms = u64at(16);
            self.merges.store(u64at(24), Relaxed);
            Ok(())
        })();
        if let Err(e) = r {
            let _ = self.reset_index();
            return Err(e);
        }
        Ok(Some(ends))
    }
}

impl Drop for Crystal {
    fn drop(&mut self) {
        self.shutdown();
    }
}

const SNAP_NAME: &str = "index.cx";
const SNAP_MAGIC: &[u8; 8] = b"CRYSIDX2";
const SNAP_VERSION: u32 = 1;
const MAX_SECTIONS: usize = 256;
const HEAD_BYTES: usize = 4 * PAGE;
// Header: magic 8, version 4, nlanes 4, total_terms 8, merges 8,
// ends 64 x 8, nsections 4, crc 4; then the section table.
const SH_NSEC: usize = 32 + MAX_LANES * 8;
const SH_CRC: usize = SH_NSEC + 4;
const SH_SIZE: usize = SH_CRC + 4;

struct SnapWriter<'a> {
    file: &'a File,
    pos: u64,
    secs: Vec<(u64, u64, u64)>,
}

impl SnapWriter<'_> {
    fn add(&mut self, bytes: &[u8], count: u64) -> Result<()> {
        if self.secs.len() == MAX_SECTIONS {
            return Err(Error::Corrupt);
        }
        self.file.write_all_at(bytes, self.pos)?;
        // Start writing it out now, so the final flush has less to wait for.
        if bytes.len() >= 1 << 20 {
            unsafe { libc::sync_file_range(self.file.as_raw_fd(), self.pos as i64, bytes.len() as i64, libc::SYNC_FILE_RANGE_WRITE) };
        }
        self.secs.push((self.pos, bytes.len() as u64, count));
        self.pos = align_up(self.pos + bytes.len() as u64, PAGE as u64);
        Ok(())
    }
    fn add_map(&mut self, m: &Map) -> Result<()> {
        let t = m.table.load(Acquire);
        if t.is_null() {
            self.add(&[], 0)?;
        } else {
            let t = unsafe { &*t };
            self.add(unsafe { std::slice::from_raw_parts(t.mem, t.cap * 16) }, t.cap as u64)?;
        }
        let len = m.len.load(Relaxed) as u64;
        self.add(&len.to_le_bytes(), 1)
    }
}

fn as_bytes(v: &[u64]) -> &[u8] {
    unsafe { std::slice::from_raw_parts(v.as_ptr() as *const u8, v.len() * 8) }
}

fn map_section(f: &File, s: (u64, u64, u64), v: AnyVec) -> Result<()> {
    if s.2 * v.size as u64 != s.1 || s.1 as usize > v.bytes {
        return Err(Error::Corrupt);
    }
    if s.1 > 0 {
        let len = align_up(s.1, PAGE as u64) as usize;
        let m = unsafe { libc::mmap(v.mem as *mut libc::c_void, len, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_PRIVATE | libc::MAP_FIXED, f.as_raw_fd(), s.0 as i64) };
        if m == libc::MAP_FAILED {
            return Err(os_err());
        }
    }
    v.len.store(s.2 as usize, Release);
    Ok(())
}

fn read_list(f: &File, s: (u64, u64, u64)) -> Result<Vec<u64>> {
    if s.2 * 8 != s.1 {
        return Err(Error::Corrupt);
    }
    let mut b = vec![0u8; s.1 as usize];
    f.read_exact_at(&mut b, s.0)?;
    Ok(b.chunks_exact(8).map(|c| u64::from_le_bytes(c.try_into().unwrap())).collect())
}

/// Maps a table back from the snapshot (copy-on-write).
fn read_map(f: &File, ts: (u64, u64, u64), ls: (u64, u64, u64), m: &Map) -> Result<()> {
    if ls.2 != 1 {
        return Err(Error::Corrupt);
    }
    let mut lb = [0u8; 8];
    f.read_exact_at(&mut lb, ls.0)?;
    m.clear();
    if ts.2 == 0 {
        return Ok(());
    }
    if !ts.2.is_power_of_two() || ts.1 != ts.2 * 16 {
        return Err(Error::Corrupt);
    }
    let len = align_up(ts.1, PAGE as u64) as usize;
    let mem = unsafe { libc::mmap(ptr::null_mut(), len, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_PRIVATE, f.as_raw_fd(), ts.0 as i64) };
    if mem == libc::MAP_FAILED {
        return Err(os_err());
    }
    let cap = ts.2 as usize;
    let t = Box::into_raw(Box::new(Table { shift: 64 - cap.trailing_zeros(), cap, mem: mem as *mut u8, bytes: len }));
    m.len.store(u64::from_le_bytes(lb) as usize, Relaxed);
    m.table.store(t, SeqCst);
    Ok(())
}

/// Reads a vector of lane ends: varint count, then the ends.
fn read_vc(b: &[u8], p: &mut usize) -> Result<[u64; VC_LEN]> {
    let n = ans::get_varint(b, p)?;
    if n > VC_LEN as u64 {
        return Err(Error::Corrupt);
    }
    let mut out = [0u64; VC_LEN];
    for o in out.iter_mut().take(n as usize) {
        *o = ans::get_varint(b, p)?;
    }
    Ok(out)
}

fn validate(scope: &[u8], subject: &[u8], body: &[u8]) -> Result<()> {
    if scope.is_empty() || scope.len() > 1024 {
        return Err(Error::InvalidScope);
    }
    if subject.len() > 1024 {
        return Err(Error::InvalidSubject);
    }
    if body.len() > MAX_TEXT as usize {
        return Err(Error::TooLarge);
    }
    Ok(())
}

fn struct_limit(n: usize) -> u32 {
    (n >> 10).max(1024) as u32
}

/// A lexicon value with this bit holds the one memory of a word seen once
/// (its ordinal), instead of a term id.
const ONCE_BIT: u64 = 1 << 63;

#[derive(Clone, Copy)]
struct Posts {
    blk: u32,
    i: u32,
    p0: u32,
}
impl Posts {
    const EMPTY: Posts = Posts { blk: 0, i: 0, p0: 0 };
    fn is_empty(&self) -> bool {
        self.blk == 0 && self.p0 == 0
    }
}

#[derive(Clone, Copy)]
struct ScopeSet {
    all: bool,
    root: u32,
}
impl ScopeSet {
    #[inline]
    fn has(&self, w: &Crystal, sid: u32) -> bool {
        self.all || w.under_scope(sid, self.root)
    }
}

struct MemFields<'a> {
    sid: u32,
    subject: &'a [u8],
    link: u64,
    erased: bool,
}

// --------------------------------------------------------------- per thread

struct Scratch {
    terms: Box<Terms>,
    ft: Box<Terms>,
    syms: Vec<u16>,
    enc: Vec<u8>,
    text: Vec<u8>,
}

thread_local! {
    static TL: RefCell<Scratch> = RefCell::new(Scratch { terms: Terms::boxed(), ft: Terms::boxed(), syms: Vec::new(), enc: Vec::new(), text: Vec::new() });
    static SEARCH: RefCell<Option<Box<Search>>> = const { RefCell::new(None) };
}

// ------------------------------------------------------------------ lineage

#[derive(Clone, Copy)]
struct Claim {
    keys: [u64; 64],
    wts: [f32; 64],
    mi: [Option<u32>; 64],
    n: usize,
}
impl Default for Claim {
    fn default() -> Self {
        Claim { keys: [0; 64], wts: [0.0; 64], mi: [None; 64], n: 0 }
    }
}

fn abs_diff(a: u16, b: u16) -> u16 {
    a.abs_diff(b)
}

/// How much a word belongs to the claim a memory makes about a name.
fn span_weight(word: Word, name: Word, value: Option<Word>) -> f32 {
    if word.sent != name.sent {
        return 0.0;
    }
    if let Some(v) = value {
        if v.sent == name.sent {
            let lo = name.pos.min(v.pos);
            let hi = name.pos.max(v.pos);
            if word.pos >= lo && word.pos <= hi {
                return 1.0;
            }
            let d = if word.pos < lo { lo - word.pos } else { word.pos - hi };
            return if d <= 2 { 0.6 } else { 0.15 };
        }
    }
    let d = abs_diff(word.pos, name.pos);
    if d <= 3 {
        1.0
    } else if d <= 6 {
        0.5
    } else {
        0.15
    }
}

fn word_sim(meaning: Option<&Meaning>, ka: u64, ma: Option<u32>, kb: u64, mb: Option<u32>) -> f32 {
    if ka == kb {
        return 1.0;
    }
    match (meaning, ma, mb) {
        (Some(m), Some(a), Some(b)) => m.similarity(a, b).max(0.0),
        _ => 0.0,
    }
}

/// How much of claim `a` claim `b` covers, by words and meaning.
fn cover_of(meaning: Option<&Meaning>, a: &Claim, b: &Claim) -> f32 {
    let mut num = 0.0;
    let mut den = 0.0;
    for i in 0..a.n {
        let mut best: f32 = 0.0;
        for j in 0..b.n {
            best = best.max(word_sim(meaning, a.keys[i], a.mi[i], b.keys[j], b.mi[j]));
        }
        num += a.wts[i] * best;
        den += a.wts[i];
    }
    if den > 0.0 {
        num / den
    } else {
        0.0
    }
}

// ------------------------------------------------------------------- recall

const MAX_GROUPS: usize = 8;
const MAX_RELATED: usize = 4;
const MIN_RELATED_SIM: f32 = 0.45;
const SIM_FLOOR: f32 = 0.15;
const MAX_DECODE: usize = 256;
/// Words in at most this many memories find candidates first.
const RARE_DF: u32 = 64;

#[derive(Clone, Copy)]
struct QTerm {
    key: u64,
    group: u8,
    sim: f32,
}

#[derive(Clone, Copy)]
struct Cand {
    ord: u32,
    s1: f32,
    mask: u8,
}

#[derive(Clone, Copy)]
struct Head {
    cur: u32,
    p: Posts,
    qi: usize,
    left: usize,
}

struct FactHit {
    key: u64,
    ord: u32,
    score: f32,
    mask: u8,
}

struct Pre {
    ord: u32,
    score: f32,
    mask: u8,
    time: u64,
    buried: bool,
}

/// Per-thread search state, reused across queries.
struct Search {
    meaning: Option<*const Meaning>,
    qt: Vec<QTerm>,
    gw: [f32; MAX_GROUPS],
    gmi: [Option<u32>; MAX_GROUPS],
    ng: usize,
    wsum: f32,
    now: u64,
    half_life: f32,
    since: u64,
    terms: Box<Terms>,
    mterms: Box<Terms>,
    text: Vec<u8>,
    cands: Vec<Cand>,
    sorted: Vec<Cand>,
    heads: Vec<Head>,
    /// Meaning index -> similarity to each group, for this question.
    memo_key: Box<[u32; 1024]>,
    memo_sim: Box<[[f32; MAX_GROUPS]; 1024]>,
}

impl Search {
    fn new() -> Self {
        Search { meaning: None, qt: Vec::with_capacity(40), gw: [0.0; MAX_GROUPS], gmi: [None; MAX_GROUPS], ng: 0, wsum: 0.0, now: 0, half_life: 1.0, since: 0, terms: Terms::boxed(), mterms: Terms::boxed(), text: Vec::new(), cands: Vec::new(), sorted: Vec::new(), heads: Vec::new(), memo_key: Box::new([u32::MAX; 1024]), memo_sim: Box::new([[0.0; MAX_GROUPS]; 1024]) }
    }

    fn reset(&mut self, meaning: Option<&Meaning>, now: u64, half_life_ms: u64, since: u64) {
        self.meaning = meaning.map(|m| m as *const Meaning);
        self.qt.clear();
        self.gw = [0.0; MAX_GROUPS];
        self.gmi = [None; MAX_GROUPS];
        self.ng = 0;
        self.wsum = 0.0;
        self.now = now;
        self.half_life = half_life_ms.max(1) as f32;
        self.since = since;
        if meaning.is_some() {
            self.memo_key.fill(u32::MAX);
        }
    }

    fn meaning<'a>(&self) -> Option<&'a Meaning> {
        // SAFETY: the meaning table outlives the query (the store holds it).
        self.meaning.map(|p| unsafe { &*p })
    }

    fn recency(&self, t: u64) -> f32 {
        let age = self.now.saturating_sub(t) as f32;
        0.85 + 0.15 * (-age / self.half_life).exp2()
    }

    fn sims(&mut self, m: &Meaning, mi: u32) -> [f32; MAX_GROUPS] {
        let slot = ((mi as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15) >> 54) as usize;
        if self.memo_key[slot] != mi {
            self.memo_key[slot] = mi;
            for g in 0..self.ng {
                self.memo_sim[slot][g] = match self.gmi[g] {
                    Some(gi) => m.similarity(gi, mi),
                    None => 0.0,
                };
            }
        }
        self.memo_sim[slot]
    }

    fn bound(&self, base: f32) -> f32 {
        let b = base.min(self.wsum);
        let cov = b / self.wsum;
        b * cov * cov * 1.1
    }
}

fn kth_score(fs: &[FactHit], k: usize) -> f32 {
    let mut top = [-1.0f32; 64];
    let kk = k.min(64);
    for f in fs {
        if f.score <= top[kk - 1] {
            continue;
        }
        let mut i = kk - 1;
        while i > 0 && top[i - 1] < f.score {
            top[i] = top[i - 1];
            i -= 1;
        }
        top[i] = f.score;
    }
    top[kk - 1]
}

/// Versions the store could not link when written: among hits that match
/// the same question words (two or more) about equally well, the newest
/// comes first and the older ones are buried.
fn sediment_hits(hits: &mut [Pre]) {
    let mut changed = true;
    let mut rounds = 0;
    while changed && rounds < hits.len() {
        changed = false;
        for i in 0..hits.len() {
            for j in i + 1..hits.len() {
                if same_fact(&hits[i], &hits[j]) && hits[j].time > hits[i].time {
                    hits.swap(i, j);
                    changed = true;
                }
            }
        }
        rounds += 1;
    }
    for j in 0..hits.len() {
        for i in 0..j {
            if same_fact(&hits[i], &hits[j]) && hits[i].time > hits[j].time {
                hits[j].buried = true;
                break;
            }
        }
    }
}

fn same_fact(a: &Pre, b: &Pre) -> bool {
    a.mask == b.mask && a.mask.count_ones() >= 2 && b.score >= a.score * 0.9 && a.score >= b.score * 0.9
}

// ---------------------------------------------------------------- public types

#[derive(Clone, Copy, Default)]
pub struct RememberOptions<'a> {
    /// A newer memory with the same subject in the same scope is a newer
    /// version of the same fact.
    pub subject: Option<&'a [u8]>,
    /// Milliseconds since the epoch. None: now.
    pub time: Option<u64>,
}

#[derive(Clone, Copy)]
pub struct Item<'a> {
    pub scope: &'a [u8],
    pub text: &'a [u8],
    pub subject: Option<&'a [u8]>,
    pub time: Option<u64>,
}

pub struct Memory {
    pub id: u64,
    pub time: u64,
    scope_len: usize,
    subject_len: usize,
    raw: Vec<u8>,
}

impl Memory {
    pub fn scope(&self) -> &[u8] {
        &self.raw[..self.scope_len]
    }
    pub fn subject(&self) -> &[u8] {
        &self.raw[self.scope_len..self.scope_len + self.subject_len]
    }
    pub fn text(&self) -> &[u8] {
        &self.raw[self.scope_len + self.subject_len..]
    }
}

#[derive(Clone, Copy)]
pub struct Query<'a> {
    /// What to look for. Empty: newest first.
    pub about: &'a [u8],
    /// Only memories in this scope or below it.
    pub scope: &'a [u8],
    /// Only memories at or after this time (ms).
    pub since: u64,
    pub limit: usize,
    /// Every version of every fact, not just the newest.
    pub deep: bool,
    /// Use word meanings, when the store has them.
    pub expand: bool,
}

impl Default for Query<'_> {
    fn default() -> Self {
        Query { about: b"", scope: b"", since: 0, limit: 10, deep: false, expand: true }
    }
}

pub struct Hit {
    pub memory: Memory,
    pub score: f32,
    /// An older version (only with `deep`) or settled.
    pub buried: bool,
    /// Which question words it contains (bit per word group).
    pub matched: u8,
}

pub struct Brief {
    pub text: Vec<u8>,
    pub tokens: usize,
    pub items: usize,
    pub buried_skipped: usize,
}

#[derive(Debug, Clone, Copy)]
pub struct Info {
    pub memories: u64,
    pub scopes: usize,
    pub subjects: usize,
    /// Facts with more than one version.
    pub strata: usize,
    /// Versions linked by the shape of their claim rather than a subject.
    pub auto_merges: u64,
    pub lanes: usize,
    pub file_bytes: u64,
    /// Bytes of the index arrays and tables.
    pub index_bytes: usize,
    /// Word models of all lanes.
    pub model_bytes: usize,
}
