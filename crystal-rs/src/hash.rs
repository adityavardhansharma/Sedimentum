//! Hashing and checksums.
//!
//! `hash` is a small wyhash-style hash for byte strings (word, scope and
//! subject keys). `Crc32c` is CRC-32C (Castagnoli, as in iSCSI), computed
//! with the SSE4.2 `crc32` instruction when the CPU has it: every record
//! read checks one, so this is on the hot path.

const P0: u64 = 0xa076_1d64_78bd_642f;
const P1: u64 = 0xe703_7ed1_a0b4_28db;
const P2: u64 = 0x8ebc_6af0_9c88_c6e3;

#[inline(always)]
fn mum(a: u64, b: u64) -> u64 {
    let r = (a as u128).wrapping_mul(b as u128);
    (r as u64) ^ ((r >> 64) as u64)
}

#[inline(always)]
fn read8(b: &[u8], i: usize) -> u64 {
    u64::from_le_bytes(b[i..i + 8].try_into().unwrap())
}

/// A 64-bit hash of `b` with a seed.
#[inline]
pub fn hash(seed: u64, b: &[u8]) -> u64 {
    let len = b.len();
    let mut h = seed ^ P0 ^ (len as u64).wrapping_mul(P2);
    let mut i = 0;
    while i + 16 <= len {
        h = mum(read8(b, i) ^ P1, read8(b, i + 8) ^ h);
        i += 16;
    }
    if i + 8 <= len {
        h = mum(h ^ read8(b, i), P1);
        i += 8;
    }
    if i < len {
        let mut v: u64 = 0;
        for (k, &c) in b[i..].iter().enumerate() {
            v |= (c as u64) << (k * 8);
        }
        h = mum(h ^ v, P2 ^ (len as u64));
    }
    mum(h ^ P0, P1 ^ (len as u64))
}

/// CRC-32C, incremental.
#[derive(Clone, Copy)]
pub struct Crc32c(u32);

static TABLE: [u32; 256] = {
    let mut t = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let mut c = i as u32;
        let mut k = 0;
        while k < 8 {
            c = if c & 1 != 0 { (c >> 1) ^ 0x82F6_3B78 } else { c >> 1 };
            k += 1;
        }
        t[i] = c;
        i += 1;
    }
    t
};

impl Default for Crc32c {
    fn default() -> Self {
        Self::new()
    }
}

impl Crc32c {
    pub fn new() -> Self {
        Crc32c(0xffff_ffff)
    }

    #[inline]
    pub fn update(&mut self, b: &[u8]) {
        self.0 = update(self.0, b);
    }

    pub fn finish(self) -> u32 {
        !self.0
    }

    pub fn hash(b: &[u8]) -> u32 {
        let mut c = Self::new();
        c.update(b);
        c.finish()
    }
}

#[cfg(all(target_arch = "x86_64", target_feature = "sse4.2"))]
#[inline]
fn update(mut c: u32, b: &[u8]) -> u32 {
    use std::arch::x86_64::{_mm_crc32_u64, _mm_crc32_u8};
    let mut i = 0;
    let mut c64 = c as u64;
    while i + 8 <= b.len() {
        // SAFETY: the target feature is enabled at compile time.
        c64 = unsafe { _mm_crc32_u64(c64, read8(b, i)) };
        i += 8;
    }
    c = c64 as u32;
    while i < b.len() {
        c = unsafe { _mm_crc32_u8(c, b[i]) };
        i += 1;
    }
    c
}

#[cfg(not(all(target_arch = "x86_64", target_feature = "sse4.2")))]
#[inline]
fn update(mut c: u32, b: &[u8]) -> u32 {
    for &x in b {
        c = TABLE[((c ^ x as u32) & 0xff) as usize] ^ (c >> 8);
    }
    c
}

#[allow(dead_code)]
fn update_table(mut c: u32, b: &[u8]) -> u32 {
    for &x in b {
        c = TABLE[((c ^ x as u32) & 0xff) as usize] ^ (c >> 8);
    }
    c
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc32c_known_value() {
        // The standard check value for CRC-32C.
        assert_eq!(Crc32c::hash(b"123456789"), 0xE306_9283);
        let long: Vec<u8> = (0..1000u32).map(|i| (i * 7) as u8).collect();
        assert_eq!(Crc32c::hash(&long), !update_table(0xffff_ffff, &long));
        let mut c = Crc32c::new();
        c.update(&long[..13]);
        c.update(&long[13..]);
        assert_eq!(c.finish(), Crc32c::hash(&long));
    }

    #[test]
    fn hash_spreads() {
        assert_ne!(hash(1, b"abc"), hash(1, b"abd"));
        assert_ne!(hash(1, b"abc"), hash(2, b"abc"));
        assert_ne!(hash(1, b""), hash(1, b"\0"));
        assert_ne!(hash(1, b"0123456789abcdef0"), hash(1, b"0123456789abcdef1"));
    }
}
