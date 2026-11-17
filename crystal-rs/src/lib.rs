//! Crystal: agent memory that keeps what is true, built from first principles.
//! A Rust port of the Zig engine in `crystal/`, with the same design and
//! file format ideas, plus the fixes listed in the README.

pub mod ans;
pub mod crystal;
pub mod hash;
pub mod meaning;
pub mod words;

pub use crate::crystal::{Brief, Crystal, Error, Hit, Info, Item, Memory, Options, Query, RememberOptions, Result};
pub use crate::meaning::Meaning;
