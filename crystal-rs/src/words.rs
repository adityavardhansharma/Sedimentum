//! Words as numbers.
//!
//! A word of up to 12 letters or digits is stored as its own base-37
//! number in a u64: exact, reversible, never colliding, and in the same
//! order as the words sort. Longer words (rare) are hashed into the upper
//! half of the u64 range, which packed words never reach.
//!
//! Terms are lowercase, with a short stopword list and light suffix
//! stripping ("deploying", "deployed" -> "deploy"), the same stemming the
//! word-meaning table was built with.

use std::sync::LazyLock;

pub const MAX_WORD: usize = 32;
pub const MAX_PACKED: usize = 12;
pub const HASHED_BIT: u64 = 1 << 63;

/// 0 for separators, 1..10 for digits, 11..36 for letters (any case).
static CODE: [u8; 256] = {
    let mut t = [0u8; 256];
    let mut c = b'0';
    while c <= b'9' {
        t[c as usize] = c - b'0' + 1;
        c += 1;
    }
    let mut c = b'a';
    while c <= b'z' {
        t[c as usize] = c - b'a' + 11;
        t[(c - 32) as usize] = c - b'a' + 11;
        c += 1;
    }
    t
};

static LOWER: [u8; 256] = {
    let mut t = [0u8; 256];
    let mut c = b'a';
    while c <= b'z' {
        t[c as usize] = c;
        t[(c - 32) as usize] = c;
        c += 1;
    }
    let mut c = b'0';
    while c <= b'9' {
        t[c as usize] = c;
        c += 1;
    }
    t
};

#[inline(always)]
pub fn is_word_byte(c: u8) -> bool {
    CODE[c as usize] != 0
}

/// A lowercase word as a number. Never 0.
#[inline]
pub fn pack(w: &[u8]) -> u64 {
    if w.len() > MAX_PACKED {
        return crate::hash::hash(0xc4157a1, w) | HASHED_BIT;
    }
    let mut v: u64 = 0;
    for i in 0..MAX_PACKED {
        v = v * 37 + if i < w.len() { CODE[w[i] as usize] as u64 } else { 0 };
    }
    v
}

/// The word a packed number stands for (not for hashed words).
pub fn unpack(v: u64) -> String {
    const ALPHABET: &[u8] = b"?0123456789abcdefghijklmnopqrstuvwxyz";
    let mut x = v;
    let mut tmp = [0u8; MAX_PACKED];
    for i in (0..MAX_PACKED).rev() {
        tmp[i] = ALPHABET[(x % 37) as usize];
        x /= 37;
    }
    let n = tmp.iter().position(|&c| c == b'?').unwrap_or(MAX_PACKED);
    String::from_utf8_lossy(&tmp[..n]).into_owned()
}

const STOPWORDS: [&str; 70] = [
    "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "did", "do", "does", "for", "from", "had", "has", "have", "he", "her", "his", "how", "i", "if", "in", "into", "is", "it", "its", "me", "my", "no", "not", "of", "on", "or", "our", "she", "so", "that", "the", "their", "them", "then", "there", "these", "they", "this", "to", "too", "us", "was", "we", "were", "what", "when", "where", "which", "who", "why", "will", "with", "would", "you", "your", "should", "could", "about", "please", "just",
];

static STOP_KEYS: LazyLock<Vec<u64>> = LazyLock::new(|| {
    let mut ks: Vec<u64> = STOPWORDS.iter().map(|w| pack(w.as_bytes())).collect();
    ks.sort_unstable();
    ks
});

#[inline]
pub fn is_stop(key: u64) -> bool {
    STOP_KEYS.binary_search(&key).is_ok()
}

const CUE_WORDS: [&str; 56] = [
    "now", "changed", "change", "moved", "move", "migrated", "migrate", "switched", "switch", "became", "become", "updated", "update", "replaced", "replace", "renamed", "raised", "lowered", "bumped", "cut", "increased", "reduced", "decreased", "tightened", "loosened", "slipped", "pushed", "delayed", "postponed", "ported", "rewritten", "rewrote", "upgraded", "downgraded", "transferred", "shifted", "swapped", "reassigned", "revised", "adjusted", "set", "reset", "converted", "relocated", "instead", "anymore", "longer", "dropped", "extended", "shortened", "retired", "deprecated", "promoted", "demoted", "takes", "took",
];

static CUE_KEYS: LazyLock<Vec<u64>> = LazyLock::new(|| {
    let mut ks: Vec<u64> = CUE_WORDS
        .iter()
        .map(|w| {
            let mut b = w.as_bytes().to_vec();
            let n = stem(&mut b);
            pack(&b[..n])
        })
        .collect();
    ks.sort_unstable();
    ks
});

#[inline]
pub fn is_cue(key: u64) -> bool {
    CUE_KEYS.binary_search(&key).is_ok()
}

/// Strips common English endings in place; returns the new length.
#[inline]
pub fn stem(w: &mut [u8]) -> usize {
    let n = w.len();
    if n > 5 && w.ends_with(b"ing") {
        n - 3
    } else if n > 4 && w.ends_with(b"ies") {
        w[n - 3] = b'y';
        n - 2
    } else if n > 4 && w.ends_with(b"ed") {
        n - 2
    } else if n > 3 && w[n - 1] == b's' && w[n - 2] != b's' && w[n - 2] != b'u' && w[n - 2] != b'i' {
        n - 1
    } else {
        n
    }
}

/// One word of a text, as the indexer sees it.
#[derive(Clone, Copy, Default, Debug)]
pub struct Word {
    pub key: u64,
    /// Word number in the text (stopwords count).
    pub pos: u16,
    /// Sentence number in the text.
    pub sent: u16,
    /// All digits.
    pub number: bool,
}

/// Calls `sink(Word)` for every term of `text` (stopwords and one-letter
/// words are skipped but still advance `pos`).
#[inline]
pub fn for_each(text: &[u8], mut sink: impl FnMut(Word)) {
    let mut buf = [0u8; MAX_WORD];
    let mut n = 0usize;
    let mut too_long = false;
    let mut digits = true;
    let mut pos: u16 = 0;
    let mut sent: u16 = 0;
    let len = text.len();
    let mut i = 0;
    while i <= len {
        let c0 = if i < len { text[i] } else { b' ' };
        let c = LOWER[c0 as usize];
        if c != 0 {
            if n < MAX_WORD {
                buf[n] = c;
                n += 1;
            } else {
                too_long = true;
            }
            if c > b'9' {
                digits = false;
            }
            i += 1;
            continue;
        }
        if n > 0 {
            if !too_long && n >= 2 {
                let raw = pack(&buf[..n]);
                if !(n <= 6 && is_stop(raw)) {
                    let st = stem(&mut buf[..n]);
                    sink(Word { key: if st == n { raw } else { pack(&buf[..st]) }, pos, sent, number: digits });
                }
            }
            pos = pos.saturating_add(1);
            n = 0;
            too_long = false;
            digits = true;
        }
        if matches!(c0, b'.' | b'!' | b'?' | b';' | b'\n') {
            sent = sent.saturating_add(1);
        }
        i += 1;
    }
}

pub const TERMS_CAP: usize = 512;
const SLOTS: usize = 1024;

/// Unique terms of one text, first occurrence kept, in text order.
pub struct Terms {
    pub words: [Word; TERMS_CAP],
    pub tf: [u16; TERMS_CAP],
    pub len: usize,
    pub total: usize,
    table: [u16; SLOTS],
}

impl Default for Terms {
    fn default() -> Self {
        Self::new()
    }
}

impl Terms {
    pub fn new() -> Self {
        Terms { words: [Word::default(); TERMS_CAP], tf: [0; TERMS_CAP], len: 0, total: 0, table: [0; SLOTS] }
    }

    pub fn boxed() -> Box<Terms> {
        Box::new(Self::new())
    }

    #[inline]
    fn slot(key: u64) -> usize {
        (key.wrapping_mul(0x9E37_79B9_7F4A_7C15) >> 54) as usize
    }

    #[inline]
    pub fn add(&mut self, w: Word) {
        self.total += 1;
        let mut i = Self::slot(w.key);
        loop {
            let e = self.table[i];
            if e == 0 {
                break;
            }
            if self.words[e as usize - 1].key == w.key {
                self.tf[e as usize - 1] = self.tf[e as usize - 1].saturating_add(1);
                return;
            }
            i = (i + 1) & (SLOTS - 1);
        }
        if self.len == TERMS_CAP {
            return;
        }
        self.words[self.len] = w;
        self.tf[self.len] = 1;
        self.len += 1;
        self.table[i] = self.len as u16;
    }

    pub fn fill(&mut self, text: &[u8]) {
        // Only the slots in use need clearing.
        if self.len * 8 < SLOTS {
            for k in 0..self.len {
                let mut i = Self::slot(self.words[k].key);
                while self.table[i] != 0 {
                    self.table[i] = 0;
                    i = (i + 1) & (SLOTS - 1);
                }
            }
        } else {
            self.table = [0; SLOTS];
        }
        self.len = 0;
        self.total = 0;
        for_each(text, |w| self.add(w));
    }

    #[inline]
    pub fn find(&self, key: u64) -> Option<usize> {
        let mut i = Self::slot(key);
        loop {
            let e = self.table[i];
            if e == 0 {
                return None;
            }
            if self.words[e as usize - 1].key == key {
                return Some(e as usize - 1);
            }
            i = (i + 1) & (SLOTS - 1);
        }
    }

    #[inline]
    pub fn items(&self) -> &[Word] {
        &self.words[..self.len]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packed_words_are_exact_ordered_reversible() {
        assert_ne!(pack(b"a"), 0);
        assert!(pack(b"abc") < pack(b"abd"));
        assert!(pack(b"ab") < pack(b"abc"));
        assert!(pack(b"zzzzzzzzzzzz") < HASHED_BIT);
        assert_ne!(pack(b"abcdefghijklm") & HASHED_BIT, 0);
        assert_eq!(unpack(pack(b"deploy42")), "deploy42");
        assert_eq!(pack(b"Deploy"), pack(b"deploy"));
    }

    #[test]
    fn terms_skip_stopwords_stem_keep_positions() {
        let mut t = Terms::new();
        t.fill(b"We moved the Deploying to Friday. Deployed again!");
        let ws = t.items();
        assert_eq!(ws.len(), 4);
        assert_eq!(ws[0].key, pack(b"mov"));
        assert!(is_cue(ws[0].key));
        assert_eq!(ws[1].key, pack(b"deploy"));
        assert_eq!(ws[1].pos, 3);
        assert_eq!(ws[2].key, pack(b"friday"));
        assert_eq!(t.tf[1], 2);
        assert_eq!(ws[3].sent, 1);
        assert!(is_stop(pack(b"the")));
        assert!(!is_stop(pack(b"region")));
        // Refill clears the table.
        t.fill(b"region region");
        assert_eq!(t.len, 1);
        assert!(t.find(pack(b"friday")).is_none());
    }
}
