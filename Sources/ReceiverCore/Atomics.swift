import Foundation
import CReceiverAtomics

/// Minimal lock-free boxes for values shared between the control threads and
/// the CoreAudio render thread. Swift's own `Synchronization.Atomic` is
/// macOS 15+, and this daemon targets macOS 14, so the C11 shim is used
/// directly.
public final class AtomicInt64: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<SCRAtomicI64>

    public init(_ initial: Int64 = 0) {
        storage = UnsafeMutablePointer<SCRAtomicI64>.allocate(capacity: 1)
        scr_atomic_init(storage, initial)
    }
    deinit { storage.deallocate() }

    public var value: Int64 {
        get { scr_atomic_load_acquire(storage) }
        set { scr_atomic_store_release(storage, newValue) }
    }

    @discardableResult
    public func add(_ delta: Int64) -> Int64 { scr_atomic_add_relaxed(storage, delta) }
}

/// A `Double` published through an atomic bit pattern.
public final class AtomicDouble: @unchecked Sendable {
    private let box: AtomicInt64
    public init(_ initial: Double = 0) { box = AtomicInt64(Int64(bitPattern: initial.bitPattern)) }
    public var value: Double {
        get { Double(bitPattern: UInt64(bitPattern: box.value)) }
        set { box.value = Int64(bitPattern: newValue.bitPattern) }
    }
}

public final class AtomicBool: @unchecked Sendable {
    private let box: AtomicInt64
    public init(_ initial: Bool = false) { box = AtomicInt64(initial ? 1 : 0) }
    public var value: Bool {
        get { box.value != 0 }
        set { box.value = newValue ? 1 : 0 }
    }
}
