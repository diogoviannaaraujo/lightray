//! Shared accounting for retained protocol buffers, including frames handed to consumers.
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug)]
pub struct MemoryBudget(Arc<Inner>);
#[derive(Debug)]
struct Inner {
    limit: usize,
    counts: Mutex<(usize, usize)>,
}
#[derive(Clone, Debug)]
pub struct MemoryReservation(Arc<Reservation>);
#[derive(Debug)]
struct Reservation {
    budget: MemoryBudget,
    bytes: usize,
}
impl MemoryBudget {
    pub fn new(limit: usize) -> Self {
        Self(Arc::new(Inner {
            limit,
            counts: Mutex::new((0, 0)),
        }))
    }
    pub fn limit(&self) -> usize {
        self.0.limit
    }
    pub fn used_bytes(&self) -> usize {
        self.0.counts.lock().unwrap_or_else(|e| e.into_inner()).0
    }
    pub fn peak_bytes(&self) -> usize {
        self.0.counts.lock().unwrap_or_else(|e| e.into_inner()).1
    }
    pub fn reserve(&self, bytes: usize) -> Option<MemoryReservation> {
        let mut counts = self.0.counts.lock().unwrap_or_else(|e| e.into_inner());
        if bytes > self.0.limit.saturating_sub(counts.0) {
            return None;
        }
        counts.0 += bytes;
        counts.1 = counts.1.max(counts.0);
        Some(MemoryReservation(Arc::new(Reservation {
            budget: self.clone(),
            bytes,
        })))
    }
}
impl MemoryReservation {
    pub fn bytes(&self) -> usize {
        self.0.bytes
    }
}
impl Drop for Reservation {
    fn drop(&mut self) {
        let mut counts = self
            .budget
            .0
            .counts
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        counts.0 -= self.bytes;
    }
}
