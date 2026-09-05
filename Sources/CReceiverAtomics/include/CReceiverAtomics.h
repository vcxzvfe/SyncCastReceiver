#ifndef CRECEIVER_ATOMICS_H
#define CRECEIVER_ATOMICS_H

#include <stdatomic.h>
#include <stdint.h>

/// C11 atomic int64 wrapper.
///
/// Swift has no memory model of its own that is usable from a CoreAudio
/// real-time thread (no locks, no allocation, no runtime calls). The PCM ring
/// is a single-producer / single-consumer queue between the UDP receive thread
/// and the render thread, so the cursors are published with release ordering
/// and observed with acquire ordering: a reader that sees the new cursor is
/// guaranteed to see the frames written before it.
typedef struct {
    _Atomic long long value;
} SCRAtomicI64;

static inline void scr_atomic_init(SCRAtomicI64 *a, long long v) {
    atomic_init(&a->value, v);
}

static inline long long scr_atomic_load_acquire(SCRAtomicI64 *a) {
    return atomic_load_explicit(&a->value, memory_order_acquire);
}

static inline void scr_atomic_store_release(SCRAtomicI64 *a, long long v) {
    atomic_store_explicit(&a->value, v, memory_order_release);
}

static inline long long scr_atomic_add_relaxed(SCRAtomicI64 *a, long long d) {
    return atomic_fetch_add_explicit(&a->value, d, memory_order_relaxed);
}

#endif /* CRECEIVER_ATOMICS_H */
