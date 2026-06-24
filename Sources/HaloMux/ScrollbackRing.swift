import Foundation

/// A fixed-capacity ring of scrollback lines. When full, the oldest line is
/// evicted and handed to `onSpill` (which halod appends to the on-disk session
/// log) before the new line is admitted. `lines()` returns the in-RAM window,
/// oldest first — exactly what an attach snapshot restores into native scrollback.
public final class ScrollbackRing {
    private let cap: Int
    private var buf: [Data] = []
    private let onSpill: (Data) -> Void
    public private(set) var spilledCount: Int = 0
    public init(cap: Int, onSpill: @escaping (Data) -> Void) {
        self.cap = max(0, cap); self.onSpill = onSpill
    }
    public func push(_ line: Data) {
        if cap == 0 { onSpill(line); spilledCount += 1; return }
        if buf.count >= cap {
            let evicted = buf.removeFirst()
            onSpill(evicted); spilledCount += 1
        }
        buf.append(line)
    }
    public func lines() -> [Data] { buf }
}

public func scrollbackRingSelfCheck() {
    var spilled: [Data] = []
    let ring = ScrollbackRing(cap: 3) { spilled.append($0) }
    // Below cap: nothing spills, order preserved.
    ring.push(Data([1])); ring.push(Data([2])); ring.push(Data([3]))
    assert(ring.lines() == [Data([1]), Data([2]), Data([3])], "fills to cap, oldest-first")
    assert(spilled.isEmpty, "no spill below cap")
    assert(ring.spilledCount == 0, "spilledCount 0 below cap")
    // One over cap: oldest (1) spills, RAM window slides.
    ring.push(Data([4]))
    assert(ring.lines() == [Data([2]), Data([3]), Data([4])], "window slid after eviction")
    assert(spilled == [Data([1])], "evicted line spilled exactly once")
    assert(ring.spilledCount == 1, "spilledCount tracks evictions")
    // Several more over cap: spill is in eviction order (oldest-first on disk).
    ring.push(Data([5])); ring.push(Data([6]))
    assert(ring.lines() == [Data([4]), Data([5]), Data([6])], "latest cap lines retained")
    assert(spilled == [Data([1]), Data([2]), Data([3])], "spill order = eviction order")
    assert(ring.spilledCount == 3, "three total evictions")
    // Cap of 0 is degenerate but must not crash: every push spills immediately.
    var spill0: [Data] = []
    let r0 = ScrollbackRing(cap: 0) { spill0.append($0) }
    r0.push(Data([9]))
    assert(r0.lines().isEmpty && spill0 == [Data([9])], "cap 0 spills everything")
    print("scrollbackRingSelfCheck ok")
}
