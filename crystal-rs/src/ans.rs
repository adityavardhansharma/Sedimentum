//! rANS text coding with a per-lane learned word model.
//!
//! A model holds 256 byte symbols plus up to 3840 tokens (a word, or a
//! word with its trailing space). Frequencies sum to 2^16. Text is coded
//! backwards into a byte stream that starts with the 4-byte final state.

use crate::words;
use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};

pub const SCALE_BITS: u32 = 16;
const M: u32 = 1 << SCALE_BITS;
const L: u32 = 1 << 23;
pub const MAX_TOKENS: usize = 3840;
pub const MAX_TOKEN_LEN: usize = words::MAX_WORD + 1;

#[derive(Debug)]
pub struct Corrupt;

pub fn bound(n: usize) -> usize {
    2 * n + 16
}

pub struct Model {
    pub nsym: u32,
    pub freq: Vec<u32>,
    pub cum: Vec<u32>,
    slot: Vec<u16>,
    tok_off: Vec<u32>,
    tok_len: Vec<u8>,
    tok_bytes: Vec<u8>,
    enc: Vec<u32>,
}

fn hash_of(b: &[u8]) -> u64 {
    crate::hash::hash(0xa115, b)
}

impl Model {
    #[inline]
    pub fn token(&self, s: u32) -> &[u8] {
        let i = (s - 256) as usize;
        let o = self.tok_off[i] as usize;
        &self.tok_bytes[o..o + self.tok_len[i] as usize]
    }

    #[inline]
    pub fn find(&self, b: &[u8]) -> Option<u32> {
        if self.enc.is_empty() {
            return None;
        }
        let mask = self.enc.len() - 1;
        let mut i = (hash_of(b) as usize) & mask;
        loop {
            let e = self.enc[i];
            if e == 0 {
                return None;
            }
            let t = self.token(e - 1);
            // Short tokens: a byte loop beats a call to memcmp.
            if t.len() == b.len() && t.iter().zip(b).all(|(x, y)| x == y) {
                return Some(e - 1);
            }
            i = (i + 1) & mask;
        }
    }

    pub fn ram_bytes(&self) -> usize {
        self.freq.len() * 8 + self.slot.len() * 2 + self.tok_off.len() * 5 + self.tok_bytes.len() + self.enc.len() * 4
    }
}

pub fn build(toks: &[&[u8]], counts: &[u64], byte_counts: &[u64; 256]) -> Box<Model> {
    let ntok = toks.len().min(MAX_TOKENS);
    let nsym = 256 + ntok;
    let mut raw = vec![0u64; nsym];
    for b in 0..256 {
        raw[b] = byte_counts[b] + 1;
    }
    for i in 0..ntok {
        raw[256 + i] = counts[i].max(1);
    }
    let tok_bytes_len: usize = toks[..ntok].iter().map(|t| t.len()).sum();
    let mut cap = 16usize;
    while cap < ntok * 2 {
        cap <<= 1;
    }
    let mut m = Box::new(Model {
        nsym: nsym as u32,
        freq: vec![0; nsym],
        cum: vec![0; nsym],
        slot: vec![0; M as usize],
        tok_off: vec![0; ntok],
        tok_len: vec![0; ntok],
        tok_bytes: Vec::with_capacity(tok_bytes_len + 32),
        enc: vec![0; if ntok == 0 { 0 } else { cap }],
    });
    quantize(&raw, &mut m.freq);
    let mut o = 0u32;
    for (i, t) in toks[..ntok].iter().enumerate() {
        m.tok_off[i] = o;
        m.tok_len[i] = t.len() as u8;
        m.tok_bytes.extend_from_slice(t);
        o += t.len() as u32;
    }
    // Padding, so decode can copy a whole 32 bytes for any token.
    m.tok_bytes.extend_from_slice(&[0u8; 32]);
    finish(&mut m);
    m
}

fn quantize(raw: &[u64], freq: &mut [u32]) {
    let total: u64 = raw.iter().sum();
    let mut sum: i64 = 0;
    for (r, f) in raw.iter().zip(freq.iter_mut()) {
        *f = ((r * M as u64) / total).max(1) as u32;
        sum += *f as i64;
    }
    let mut diff: i64 = M as i64 - sum;
    let argmax = |freq: &[u32]| {
        let mut best = 0;
        for (i, &f) in freq.iter().enumerate() {
            if f > freq[best] {
                best = i;
            }
        }
        best
    };
    while diff < 0 {
        let best = argmax(freq);
        let take = (-diff).min(((freq[best] as i64) / 4).max(1));
        freq[best] -= take as u32;
        diff += take;
    }
    if diff > 0 {
        let best = argmax(freq);
        freq[best] += diff as u32;
    }
}

fn finish(m: &mut Model) {
    let mut c = 0u32;
    for s in 0..m.freq.len() {
        let f = m.freq[s];
        m.cum[s] = c;
        m.slot[c as usize..(c + f) as usize].fill(s as u16);
        c += f;
    }
    debug_assert_eq!(c, M);
    m.enc.fill(0);
    if m.enc.is_empty() {
        return;
    }
    let mask = m.enc.len() - 1;
    for i in 0..m.tok_off.len() {
        let s = 256 + i as u32;
        let mut k = (hash_of(m.token(s)) as usize) & mask;
        while m.enc[k] != 0 {
            k = (k + 1) & mask;
        }
        m.enc[k] = s + 1;
    }
}

pub fn serialize(m: &Model, out: &mut Vec<u8>) {
    let ntok = m.nsym - 256;
    out.extend_from_slice(&(ntok as u16).to_le_bytes());
    for &f in &m.freq {
        put_varint(out, f as u64);
    }
    for i in 0..ntok {
        let t = m.token(256 + i);
        out.push(t.len() as u8);
        out.extend_from_slice(t);
    }
}

pub fn parse(bytes: &[u8]) -> Result<Box<Model>, Corrupt> {
    if bytes.len() < 2 {
        return Err(Corrupt);
    }
    let ntok = u16::from_le_bytes([bytes[0], bytes[1]]) as usize;
    if ntok > MAX_TOKENS {
        return Err(Corrupt);
    }
    let nsym = 256 + ntok;
    let mut p = 2usize;
    let mut freq = vec![0u32; nsym];
    let mut sum: u64 = 0;
    for f in freq.iter_mut() {
        let v = get_varint(bytes, &mut p)?;
        if v == 0 || v > M as u64 {
            return Err(Corrupt);
        }
        *f = v as u32;
        sum += v;
    }
    if sum != M as u64 {
        return Err(Corrupt);
    }
    let mut toks: Vec<&[u8]> = Vec::with_capacity(ntok);
    for _ in 0..ntok {
        if p >= bytes.len() {
            return Err(Corrupt);
        }
        let l = bytes[p] as usize;
        p += 1;
        if l == 0 || l > MAX_TOKEN_LEN || p + l > bytes.len() {
            return Err(Corrupt);
        }
        toks.push(&bytes[p..p + l]);
        p += l;
    }
    let counts = vec![1u64; ntok];
    let bc = [0u64; 256];
    let mut m = build(&toks, &counts, &bc);
    m.freq.copy_from_slice(&freq);
    finish(&mut m);
    Ok(m)
}

#[inline]
pub fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v as u8) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

#[inline]
pub fn get_varint(b: &[u8], p: &mut usize) -> Result<u64, Corrupt> {
    let mut v: u64 = 0;
    let mut shift = 0u32;
    loop {
        if *p >= b.len() {
            return Err(Corrupt);
        }
        let c = b[*p];
        *p += 1;
        v |= ((c & 0x7f) as u64) << shift;
        if c < 0x80 {
            return Ok(v);
        }
        if shift >= 56 {
            return Err(Corrupt);
        }
        shift += 7;
    }
}

fn symbols(m: &Model, text: &[u8], out: &mut [u16]) -> usize {
    let mut n = 0;
    let mut i = 0;
    let len = text.len();
    while i < len {
        let c = text[i];
        if words::is_word_byte(c) && (i == 0 || !words::is_word_byte(text[i - 1])) {
            let mut j = i + 1;
            while j < len && words::is_word_byte(text[j]) {
                j += 1;
            }
            if j - i < MAX_TOKEN_LEN {
                if j < len && text[j] == b' ' {
                    if let Some(s) = m.find(&text[i..j + 1]) {
                        out[n] = s as u16;
                        n += 1;
                        i = j + 1;
                        continue;
                    }
                }
                if let Some(s) = m.find(&text[i..j]) {
                    out[n] = s as u16;
                    n += 1;
                    i = j;
                    continue;
                }
            }
            for &b in &text[i..j] {
                out[n] = b as u16;
                n += 1;
            }
            i = j;
            continue;
        }
        out[n] = c as u16;
        n += 1;
        i += 1;
    }
    n
}

/// Codes `text`; `scratch` holds at least text.len() symbols and `out` at
/// least `bound(text.len())` bytes. Returns the coded length (at the front
/// of `out`).
pub fn encode(m: &Model, text: &[u8], scratch: &mut [u16], out: &mut [u8]) -> usize {
    let ns = symbols(m, text, scratch);
    let mut p = out.len();
    let mut x: u32 = L;
    for k in (0..ns).rev() {
        let s = scratch[k] as usize;
        let f = m.freq[s];
        let x_max = ((L >> SCALE_BITS) << 8) * f;
        while x >= x_max {
            p -= 1;
            out[p] = x as u8;
            x >>= 8;
        }
        x = ((x / f) << SCALE_BITS) + (x % f) + m.cum[s];
    }
    p -= 4;
    out[p..p + 4].copy_from_slice(&x.to_le_bytes());
    let len = out.len() - p;
    out.copy_within(p.., 0);
    len
}

pub fn decode(m: &Model, enc: &[u8], out: &mut [u8]) -> Result<(), Corrupt> {
    if enc.len() < 4 {
        return Err(Corrupt);
    }
    let mut x = u32::from_le_bytes(enc[0..4].try_into().unwrap());
    let mut p = 4usize;
    let mut o = 0usize;
    let mask = M - 1;
    let n = out.len();
    let nsym = m.nsym as usize;
    debug_assert!(m.slot.len() == M as usize && m.freq.len() == nsym && m.cum.len() == nsym);
    while o < n {
        let sl = x & mask;
        // SAFETY: sl < M = slot.len(), and every slot holds a symbol < nsym
        // (built by `finish`).
        let s = unsafe { *m.slot.get_unchecked(sl as usize) } as usize;
        let (f, c) = unsafe { (*m.freq.get_unchecked(s), *m.cum.get_unchecked(s)) };
        x = f * (x >> SCALE_BITS) + sl - c;
        while x < L {
            if p >= enc.len() {
                return Err(Corrupt);
            }
            x = (x << 8) | unsafe { *enc.get_unchecked(p) } as u32;
            p += 1;
        }
        if s < 256 {
            unsafe { *out.get_unchecked_mut(o) = s as u8 };
            o += 1;
        } else {
            let i = s - 256;
            let to = m.tok_off[i] as usize;
            let tl = m.tok_len[i] as usize;
            if o + tl > n {
                return Err(Corrupt);
            }
            if o + 32 <= n {
                // SAFETY: tok_bytes has 32 bytes of padding after every token,
                // and out has 32 bytes from o; the extra bytes are overwritten
                // by what follows (or were never part of the text).
                unsafe { std::ptr::copy_nonoverlapping(m.tok_bytes.as_ptr().add(to), out.as_mut_ptr().add(o), 32) };
            } else {
                out[o..o + tl].copy_from_slice(&m.tok_bytes[to..to + tl]);
            }
            o += tl;
        }
    }
    Ok(())
}

/// A fast hasher for token keys.
#[derive(Default)]
pub struct TokHasher(u64);
impl Hasher for TokHasher {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write(&mut self, b: &[u8]) {
        self.0 = crate::hash::hash(self.0 ^ 0x70c, b);
    }
}

/// Counts tokens of the texts a writer saves, for its next model.
pub struct Counter {
    counts: HashMap<Box<[u8]>, u64, BuildHasherDefault<TokHasher>>,
    bytes: [u64; 256],
}

const MAX_DISTINCT: usize = 1 << 16;

impl Default for Counter {
    fn default() -> Self {
        Self::new()
    }
}

impl Counter {
    pub fn new() -> Self {
        Counter { counts: HashMap::default(), bytes: [0; 256] }
    }

    pub fn reset(&mut self) {
        self.counts = HashMap::default();
        self.bytes = [0; 256];
    }

    fn see(&mut self, tok: &[u8]) {
        if let Some(n) = self.counts.get_mut(tok) {
            *n += 1;
            return;
        }
        for &b in tok {
            self.bytes[b as usize] += 1;
        }
        if self.counts.len() >= MAX_DISTINCT {
            return;
        }
        self.counts.insert(tok.into(), 1);
    }

    pub fn add(&mut self, text: &[u8]) {
        let mut i = 0;
        let len = text.len();
        while i < len {
            let ch = text[i];
            if words::is_word_byte(ch) {
                let mut j = i + 1;
                while j < len && words::is_word_byte(text[j]) {
                    j += 1;
                }
                if j - i < MAX_TOKEN_LEN {
                    let with_space = j < len && text[j] == b' ';
                    let e = if with_space { j + 1 } else { j };
                    self.see(&text[i..e]);
                    i = e;
                } else {
                    for &b in &text[i..j] {
                        self.bytes[b as usize] += 1;
                    }
                    i = j;
                }
                continue;
            }
            self.bytes[ch as usize] += 1;
            i += 1;
        }
    }

    pub fn model(&self) -> Box<Model> {
        let mut es: Vec<(&[u8], u64)> = self.counts.iter().filter(|(_, &n)| n >= 2).map(|(t, &n)| (&t[..], n)).collect();
        es.sort_unstable_by(|a, b| {
            let sa = a.1 * a.0.len() as u64;
            let sb = b.1 * b.0.len() as u64;
            sb.cmp(&sa).then_with(|| a.0.cmp(b.0))
        });
        let n = es.len().min(MAX_TOKENS);
        let toks: Vec<&[u8]> = es[..n].iter().map(|e| e.0).collect();
        let counts: Vec<u64> = es[..n].iter().map(|e| e.1).collect();
        let mut bc = self.bytes;
        for e in &es[n..] {
            for &b in e.0 {
                bc[b as usize] += e.1 - 1;
            }
        }
        build(&toks, &counts, &bc)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rans_round_trips_text_through_a_learned_model() {
        let mut c = Counter::new();
        let sample = b"the user wants to deploy the service on friday because tests pass and billing is late ";
        for _ in 0..50 {
            c.add(sample);
        }
        let m = c.model();
        let texts: [&[u8]; 4] = [sample, b"Totally new words: zebra, quokka! 42 times.", b"", b"\x00\xff binary \x01 bytes"];
        for t in texts {
            let mut sym = vec![0u16; t.len()];
            let mut out = vec![0u8; bound(t.len())];
            let n = encode(&m, t, &mut sym, &mut out);
            let mut dec = vec![0u8; t.len()];
            decode(&m, &out[..n], &mut dec).unwrap();
            assert_eq!(&dec[..], t);
        }
        let mut sym = vec![0u16; sample.len()];
        let mut out = vec![0u8; bound(sample.len())];
        let n = encode(&m, sample, &mut sym, &mut out);
        assert!(n < sample.len() / 3, "coded {} of {}", n, sample.len());
        let mut ser = Vec::new();
        serialize(&m, &mut ser);
        let m2 = parse(&ser).unwrap();
        let mut dec = vec![0u8; sample.len()];
        decode(&m2, &out[..n], &mut dec).unwrap();
        assert_eq!(&dec[..], &sample[..]);
    }
}
