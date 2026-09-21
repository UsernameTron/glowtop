/// Fixed-capacity circular buffer. SPEC.md §6.4: it never reallocates and never grows,
/// which is what keeps history out of the RSS budget in §13.1.
public struct RingBuffer<Element>: Sendable where Element: Sendable {
    private var storage: [Element?]
    private var writeIndex = 0
    public private(set) var count = 0

    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    public mutating func append(_ element: Element) {
        storage[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity
        if count < capacity { count += 1 }
    }

    /// Oldest first, newest last.
    public var elements: [Element] {
        guard count > 0 else { return [] }
        let start = count < capacity ? 0 : writeIndex
        return (0..<count).compactMap { storage[(start + $0) % capacity] }
    }

    public var newest: Element? {
        guard count > 0 else { return nil }
        return storage[(writeIndex + capacity - 1) % capacity]
    }

    public mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        writeIndex = 0
        count = 0
    }
}
