//! The Zig engine's tests, ported.

use crystal::{Crystal, Options, Query, RememberOptions};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

static N: AtomicU32 = AtomicU32::new(0);

fn tmp() -> PathBuf {
    let p = std::env::temp_dir().join(format!("crystal-rs-test-{}-{}", std::process::id(), N.fetch_add(1, Ordering::Relaxed)));
    let _ = std::fs::remove_dir_all(&p);
    p
}

fn open(p: &PathBuf) -> Box<Crystal> {
    Crystal::open(p, Options { sync_writes: false, ..Default::default() }).unwrap()
}

fn subj(s: &str) -> RememberOptions<'_> {
    RememberOptions { subject: Some(s.as_bytes()), time: None }
}

fn has(hay: &[u8], needle: &str) -> bool {
    hay.windows(needle.len()).any(|w| w == needle.as_bytes())
}

#[test]
fn remember_recent_current() {
    let p = tmp();
    let w = open(&p);
    w.remember(b"chat/1", b"hello there", Default::default()).unwrap();
    w.remember(b"chat/1", b"deploy is on friday", Default::default()).unwrap();
    w.remember(b"mem", b"plan A", subj("plan")).unwrap();
    w.remember(b"mem", b"plan B", subj("plan")).unwrap();
    let r = w.recent(b"chat/1", 10).unwrap();
    assert_eq!(r.len(), 2);
    assert_eq!(r[0].text(), b"deploy is on friday");
    assert_eq!(r[0].scope(), b"chat/1");
    assert_eq!(w.current(b"mem", b"plan").unwrap().unwrap().text(), b"plan B");
}

#[test]
fn text_is_coded_and_reads_back_exactly() {
    let p = tmp();
    let w = open(&p);
    let mut ids = Vec::new();
    for i in 0..3000 {
        ids.push(w.remember(b"chat/2", format!("the user wants to deploy the service on friday number {}", i).as_bytes(), Default::default()).unwrap());
    }
    assert!(w.info().model_bytes > 0);
    for i in [0usize, 63, 64, 1500, 2999] {
        let m = w.get(ids[i]).unwrap().unwrap();
        assert_eq!(m.text(), format!("the user wants to deploy the service on friday number {}", i).as_bytes());
    }
    assert!(w.info().file_bytes < 3000 * 40, "{}", w.info().file_bytes);
}

#[test]
fn an_old_wording_reaches_the_newest_version() {
    let p = tmp();
    let w = open(&p);
    w.set_clock_for_test(Some(10_000_000));
    for i in 0..2000 {
        w.remember(b"p/chat", format!("filler {} about lunch and coffee", i).as_bytes(), Default::default()).unwrap();
    }
    w.remember(b"p", b"billing runs on postgres fifteen", subj("billing-db")).unwrap();
    for i in 0..300 {
        w.remember(b"p/chat", format!("more filler {}", i).as_bytes(), Default::default()).unwrap();
    }
    w.remember(b"p", b"payments service moved to cockroach", subj("billing-db")).unwrap();
    let hits = w.recall(&Query { about: b"what does billing run on, postgres?", limit: 5, ..Default::default() }).unwrap();
    assert!(!hits.is_empty());
    assert_eq!(hits[0].memory.text(), b"payments service moved to cockroach");
    assert!(hits.iter().all(|h| !has(h.memory.text(), "fifteen")));
    let deep = w.recall(&Query { about: b"billing postgres cockroach payments", limit: 5, deep: true, ..Default::default() }).unwrap();
    assert_eq!(deep.len(), 2);
}

#[test]
fn a_new_value_for_the_same_slot_is_a_new_version() {
    let p = tmp();
    let w = open(&p);
    for i in 0..5000 {
        w.remember(b"p", format!("the team talked about the plan {} today", i).as_bytes(), Default::default()).unwrap();
    }
    w.remember(b"p", b"zorblat cache ttl is ninety seconds", Default::default()).unwrap();
    w.remember(b"p", b"zorblat owner is mallory", Default::default()).unwrap();
    w.remember(b"p", b"update: zorblat cache ttl raised to hundredtwenty", Default::default()).unwrap();
    let hits = w.recall(&Query { about: b"zorblat cache ttl", limit: 5, ..Default::default() }).unwrap();
    assert!(has(hits[0].memory.text(), "hundredtwenty"));
    assert!(hits.iter().all(|h| !has(h.memory.text(), "ninety")));
    let own = w.recall(&Query { about: b"who owns zorblat", limit: 5, ..Default::default() }).unwrap();
    assert!(own.iter().any(|h| has(h.memory.text(), "mallory")));
}

#[test]
fn forget_erases_text_and_survives_reopening() {
    let p = tmp();
    {
        let w = open(&p);
        let a = w.remember(b"chat/9", b"secret token alpha", Default::default()).unwrap();
        w.remember(b"chat/9", b"secret token beta", Default::default()).unwrap();
        w.remember(b"chat/10", b"keep this one", Default::default()).unwrap();
        w.forget(a).unwrap();
        assert_eq!(w.forget_scope(b"chat/9").unwrap(), 1);
        assert_eq!(w.recent(b"chat/9", 10).unwrap().len(), 0);
        w.sync().unwrap();
    }
    let w = open(&p);
    assert_eq!(w.recent(b"chat/9", 10).unwrap().len(), 0);
    assert_eq!(w.recent(b"chat/10", 10).unwrap().len(), 1);
    let mut found = false;
    w.scan_all(|b, _| found |= has(b, "secret")).unwrap();
    assert!(!found);
    let lane = std::fs::read(p.join("lane-000.cx")).unwrap();
    assert!(!has(&lane, "secret"));
}

#[test]
fn reopening_maps_the_snapshot_and_reads_only_what_came_after() {
    let p = tmp();
    {
        let w = open(&p);
        for i in 0..3000 {
            w.remember(b"proj/1/chat", format!("message {} about the quarterly roadmap", i).as_bytes(), Default::default()).unwrap();
        }
        w.remember(b"proj/1", b"the vendor for kestrelpay is stripe", subj("vendor")).unwrap();
    }
    {
        let w = open(&p);
        assert_eq!(w.info().memories, 3001);
        w.remember(b"proj/1", b"the vendor for kestrelpay is adyen now", subj("vendor")).unwrap();
    }
    let w = open(&p);
    let hits = w.recall(&Query { about: b"kestrelpay vendor", scope: b"proj/1", ..Default::default() }).unwrap();
    assert_eq!(hits[0].memory.text(), b"the vendor for kestrelpay is adyen now");
    let r = w.recent(b"proj/1/chat", 2).unwrap();
    assert_eq!(r[0].text(), b"message 2999 about the quarterly roadmap");
}

#[test]
fn a_torn_write_at_the_end_is_cut_off() {
    let p = tmp();
    {
        let w = open(&p);
        w.remember(b"a", b"first", Default::default()).unwrap();
        w.remember(b"a", b"second", Default::default()).unwrap();
        w.sync().unwrap();
    }
    {
        use std::os::unix::fs::FileExt;
        let f = std::fs::OpenOptions::new().read(true).write(true).open(p.join("lane-000.cx")).unwrap();
        let len = f.metadata().unwrap().len();
        f.write_all_at(&[200, 0, 0, 0, 1, 2, 3, 4, 1, 9, 9], len).unwrap();
    }
    let w = open(&p);
    w.remember(b"a", b"third", Default::default()).unwrap();
    let r = w.recent(b"a", 10).unwrap();
    assert_eq!(r.len(), 3);
    assert_eq!(r[0].text(), b"third");
}

#[test]
fn two_writers_share_a_store() {
    let p = tmp();
    let a = open(&p);
    let b = open(&p);
    a.remember(b"team", b"alpha wrote the release notes", Default::default()).unwrap();
    b.remember(b"team", b"beta reviewed the release notes", Default::default()).unwrap();
    a.sync().unwrap();
    b.sync().unwrap();
    a.refresh().unwrap();
    b.refresh().unwrap();
    assert_eq!(a.recent(b"team", 10).unwrap().len(), 2);
    assert_eq!(b.recent(b"team", 10).unwrap().len(), 2);
    b.forget_scope(b"team").unwrap();
    a.refresh().unwrap();
    assert_eq!(a.recent(b"team", 10).unwrap().len(), 0);
}

#[test]
fn promised_writes_become_durable() {
    let p = tmp();
    let w = Crystal::open(&p, Options { sync_writes: false, flusher: true, ..Default::default() }).unwrap();
    w.remember(b"a", b"promised", Default::default()).unwrap();
    let pr = w.promise();
    w.wait_durable(pr).unwrap();
    assert!(w.is_durable(pr));
}

#[test]
fn brief_holds_the_newest_version_only() {
    let p = tmp();
    let w = open(&p);
    w.remember(b"proj/7/decisions", b"decision: the cache ttl for glimmer is fiftysec", subj("glimmer/ttl")).unwrap();
    for i in 0..50 {
        w.remember(b"proj/7/chat/1", format!("chatter line {} about lunch", i).as_bytes(), Default::default()).unwrap();
    }
    w.remember(b"proj/7/decisions", b"update: the cache ttl for glimmer is ninetysec", subj("glimmer/ttl")).unwrap();
    let b = w.brief(b"what is the cache ttl for glimmer?", b"proj/7", 300).unwrap();
    assert!(has(&b.text, "ninetysec"));
    assert!(!has(&b.text, "fiftysec"));
    assert!(b.tokens <= 300);
}

#[test]
fn concurrent_durable_writers_all_land() {
    let p = tmp();
    let w = Crystal::open(&p, Options { sync_writes: true, ..Default::default() }).unwrap();
    std::thread::scope(|s| {
        for t in 0..8 {
            let w = &w;
            s.spawn(move || {
                for i in 0..300 {
                    w.remember(format!("t/{}", t).as_bytes(), format!("thread {} line {} with some words", t, i).as_bytes(), Default::default()).unwrap();
                }
            });
        }
    });
    drop(w);
    let w = open(&p);
    for t in 0..8 {
        assert_eq!(w.recent(format!("t/{}", t).as_bytes(), 1000).unwrap().len(), 300);
    }
}
