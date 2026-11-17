//! Word meanings: a table of word vectors and nearest neighbours
//! (the `HOLOWV1` format: stems, int8 vectors, neighbour lists).
//!
//! Crystal looks words up by their packed number, so the table is an
//! open-addressing array of packed words, probed by a multiply-shift.

use crate::words;

pub const MAX_DIMS: usize = 320;
const NONE: u16 = 0xffff;

pub struct Meaning {
    pub count: u32,
    pub dims: u16,
    pub nbrs: u16,
    vectors: Vec<i8>,
    /// count x nbrs x (u16 index, u8 similarity * 255)
    neighbours: Vec<u8>,
    keys: Vec<u64>,
    /// Slot -> index + 1.
    slots: Vec<u32>,
    shift: u32,
}

#[derive(Clone, Copy, Debug)]
pub struct Related {
    pub key: u64,
    pub sim: f32,
}

#[derive(Debug)]
pub struct BadModel;

impl Meaning {
    pub fn load(bytes: &[u8]) -> Result<Meaning, BadModel> {
        if bytes.len() < 16 || &bytes[0..8] != b"HOLOWV1\x00" {
            return Err(BadModel);
        }
        let count = u32::from_le_bytes(bytes[8..12].try_into().unwrap());
        let dims = u16::from_le_bytes(bytes[12..14].try_into().unwrap());
        let nbrs = u16::from_le_bytes(bytes[14..16].try_into().unwrap());
        if dims == 0 || dims as usize > MAX_DIMS || count == 0 || count >= NONE as u32 {
            return Err(BadModel);
        }
        let mut keys = Vec::with_capacity(count as usize);
        let mut p = 16usize;
        for _ in 0..count {
            if p >= bytes.len() {
                return Err(BadModel);
            }
            let l = bytes[p] as usize;
            p += 1;
            if p + l > bytes.len() || l == 0 {
                return Err(BadModel);
            }
            keys.push(words::pack(&bytes[p..p + l]));
            p += l;
        }
        let vlen = count as usize * dims as usize;
        let nlen = count as usize * nbrs as usize * 3;
        if p + vlen + nlen != bytes.len() {
            return Err(BadModel);
        }
        let vectors: Vec<i8> = bytes[p..p + vlen].iter().map(|&b| b as i8).collect();
        let neighbours = bytes[p + vlen..].to_vec();
        for k in (0..nlen).step_by(3) {
            let j = u16::from_le_bytes([neighbours[k], neighbours[k + 1]]);
            if j != NONE && j as u32 >= count {
                return Err(BadModel);
            }
        }
        let mut bits = 1u32;
        while (1usize << bits) < count as usize * 2 {
            bits += 1;
        }
        let mut m = Meaning { count, dims, nbrs, vectors, neighbours, keys, slots: vec![0; 1 << bits], shift: 64 - bits };
        let mask = m.slots.len() - 1;
        for i in 0..count as usize {
            let key = m.keys[i];
            let mut s = m.slot_of(key);
            loop {
                let e = m.slots[s];
                if e == 0 {
                    m.slots[s] = i as u32 + 1;
                    break;
                }
                // Two stems that pack the same (a long word hashed): first wins.
                if m.keys[e as usize - 1] == key {
                    break;
                }
                s = (s + 1) & mask;
            }
        }
        Ok(m)
    }

    #[inline]
    fn slot_of(&self, key: u64) -> usize {
        (key.wrapping_mul(0x9E37_79B9_7F4A_7C15) >> self.shift) as usize
    }

    #[inline]
    pub fn index(&self, key: u64) -> Option<u32> {
        let mask = self.slots.len() - 1;
        let mut s = self.slot_of(key);
        loop {
            let e = self.slots[s];
            if e == 0 {
                return None;
            }
            if self.keys[e as usize - 1] == key {
                return Some(e - 1);
            }
            s = (s + 1) & mask;
        }
    }

    /// Up to `out.len()` related words with similarity at least `min_sim`.
    pub fn related(&self, key: u64, min_sim: f32, out: &mut [Related]) -> usize {
        let Some(i) = self.index(key) else { return 0 };
        let nb = self.nbrs as usize;
        let row = &self.neighbours[i as usize * nb * 3..(i as usize + 1) * nb * 3];
        let mut n = 0;
        for k in 0..nb {
            if n == out.len() {
                break;
            }
            let j = u16::from_le_bytes([row[k * 3], row[k * 3 + 1]]);
            if j == NONE {
                break;
            }
            let sim = row[k * 3 + 2] as f32 / 255.0;
            if sim < min_sim {
                break;
            }
            out[n] = Related { key: self.keys[j as usize], sim };
            n += 1;
        }
        n
    }

    /// Cosine similarity of two words by index (vectors are unit length,
    /// scaled to int8). The loop compiles to SIMD multiply-adds.
    #[inline]
    pub fn similarity(&self, a: u32, b: u32) -> f32 {
        let d = self.dims as usize;
        let va = &self.vectors[a as usize * d..a as usize * d + d];
        let vb = &self.vectors[b as usize * d..b as usize * d + d];
        let mut acc = [0i32; 16];
        let mut ca = va.chunks_exact(16);
        let mut cb = vb.chunks_exact(16);
        for (x, y) in (&mut ca).zip(&mut cb) {
            for k in 0..16 {
                acc[k] += x[k] as i16 as i32 * y[k] as i16 as i32;
            }
        }
        let mut dot: i32 = acc.iter().sum();
        for (x, y) in ca.remainder().iter().zip(cb.remainder()) {
            dot += *x as i32 * *y as i32;
        }
        dot as f32 / (127.0 * 127.0)
    }
}
