import Foundation

/// One attached client's reported grid + whether it is the focused (typing) one.
/// `clientID` is the daemon's per-connection id; only used for deterministic tiebreaks.
public struct MirrorClient: Equatable {
    public let clientID: Int
    public let focused: Bool
    public let cols: Int
    public let rows: Int
    public init(clientID: Int, focused: Bool, cols: Int, rows: Int) {
        self.clientID = clientID; self.focused = focused; self.cols = cols; self.rows = rows
    }
}

/// Choose the PTY grid for a session given every attached client.
/// Policy (beats tmux's smallest-wins): follow the FOCUSED client; idle mirrors
/// letterbox to this grid on their side. If multiple clients are focused
/// (focus races during handoff), pick the SMALLEST focused grid so no focused
/// client is ever clipped, breaking ties by lowest clientID for determinism.
/// If NO client is focused (all idle), fall back to the smallest grid of all so
/// nobody is clipped. Returns nil when there are no clients (session detached).
public func arbitrateSize(_ clients: [MirrorClient]) -> (cols: Int, rows: Int)? {
    guard !clients.isEmpty else { return nil }
    let focused = clients.filter { $0.focused }
    let pool = focused.isEmpty ? clients : focused
    // smallest area, tiebreak on (cols, rows, clientID) for a total order
    let chosen = pool.min { a, b in
        let aa = a.cols * a.rows, ba = b.cols * b.rows
        if aa != ba { return aa < ba }
        if a.cols != b.cols { return a.cols < b.cols }
        if a.rows != b.rows { return a.rows < b.rows }
        return a.clientID < b.clientID
    }!
    return (chosen.cols, chosen.rows)
}

public func sizeArbitrationSelfCheck() {
    // No clients → nil (session detached).
    assert(arbitrateSize([]) == nil, "no clients -> nil")

    // Single client → its own grid.
    assert(arbitrateSize([MirrorClient(clientID: 0, focused: true, cols: 100, rows: 40)])
           .map { [$0.cols, $0.rows] } == [100, 40], "single client uses its grid")

    // Focused beats a larger idle mirror (idle letterboxes, focused is authoritative).
    let r1 = arbitrateSize([
        MirrorClient(clientID: 0, focused: true,  cols: 80,  rows: 24),
        MirrorClient(clientID: 1, focused: false, cols: 200, rows: 60),
    ])!
    assert(r1.cols == 80 && r1.rows == 24, "focused client wins over larger idle")

    // Focused beats a SMALLER idle mirror too (we don't shrink to the idle one).
    let r2 = arbitrateSize([
        MirrorClient(clientID: 0, focused: true,  cols: 120, rows: 50),
        MirrorClient(clientID: 1, focused: false, cols: 40,  rows: 12),
    ])!
    assert(r2.cols == 120 && r2.rows == 50, "focused client wins over smaller idle")

    // Two focused (focus race) → smallest focused grid, so neither is clipped.
    let r3 = arbitrateSize([
        MirrorClient(clientID: 0, focused: true, cols: 100, rows: 40),
        MirrorClient(clientID: 1, focused: true, cols: 80,  rows: 30),
    ])!
    assert(r3.cols == 80 && r3.rows == 30, "two focused -> smallest focused")

    // All idle (nobody focused) → smallest of all, so nobody is clipped.
    let r4 = arbitrateSize([
        MirrorClient(clientID: 0, focused: false, cols: 100, rows: 40),
        MirrorClient(clientID: 1, focused: false, cols: 80,  rows: 30),
    ])!
    assert(r4.cols == 80 && r4.rows == 30, "all idle -> smallest of all")

    // Equal-area focused tie → deterministic lowest clientID.
    let r5 = arbitrateSize([
        MirrorClient(clientID: 7, focused: true, cols: 60, rows: 20),
        MirrorClient(clientID: 3, focused: true, cols: 60, rows: 20),
    ])!
    assert(r5.cols == 60 && r5.rows == 20, "equal grids resolve deterministically")

    print("sizeArbitrationSelfCheck ok")
}
