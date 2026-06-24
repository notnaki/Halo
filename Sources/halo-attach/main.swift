import Foundation
import HaloMux
#if canImport(Darwin)
import Darwin
#endif

// argv[1] = paneID.
let args = CommandLine.arguments
guard args.count >= 2 else { FileHandle.standardError.write(Data("usage: halo-attach <paneID>\n".utf8)); exit(2) }
let paneID = args[1]

// ── lazy-spawn the daemon if its socket is absent ────────────────────────────
func socketAlive(_ path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0); if fd < 0 { return false }
    defer { close(fd) }
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for i in 0..<min(bytes.count, raw.count - 1) { raw[i] = bytes[i] }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
    }
}
func spawnDaemon() {
    let exe = Bundle.main.executableURL?.deletingLastPathComponent()
        .appendingPathComponent("halod").path
        ?? (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/halod"
    // setsid is not shipped on macOS; use perl's POSIX::setsid as a portable fallback.
    // On Linux, setsid(1) is available; on macOS, perl -MPOSIX=setsid is always present.
    let cmd: String
    if FileManager.default.fileExists(atPath: "/usr/bin/setsid") {
        cmd = "setsid \"\(exe)\" >/dev/null 2>&1 &"
    } else {
        cmd = "perl -MPOSIX=setsid -e 'setsid; exec @ARGV' -- \"\(exe)\" >/dev/null 2>&1 &"
    }
    let w = Process(); w.executableURL = URL(fileURLWithPath: "/bin/sh")
    w.arguments = ["-c", cmd]
    try? w.run(); w.waitUntilExit()
    for _ in 0..<100 { if socketAlive(MuxPaths.daemonSocket) { return }; usleep(20_000) }
}
if !socketAlive(MuxPaths.daemonSocket) { spawnDaemon() }

// ── connect ──────────────────────────────────────────────────────────────────
let sock = socket(AF_UNIX, SOCK_STREAM, 0)
guard sock >= 0 else { exit(1) }
var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
let pbytes = Array(MuxPaths.daemonSocket.utf8)
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    for i in 0..<min(pbytes.count, raw.count - 1) { raw[i] = pbytes[i] }
}
let slen = socklen_t(MemoryLayout<sockaddr_un>.size)
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, slen) }
}
guard connected == 0 else { FileHandle.standardError.write(Data("halo-attach: daemon unavailable\n".utf8)); exit(1) }

// ── initial winsize from our controlling tty (ghostty's PTY) ─────────────────
func currentWinsize() -> (Int, Int) {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
        return (Int(ws.ws_col), Int(ws.ws_row))
    }
    return (80, 24)
}
func send(_ f: ClientFrame) {
    let d = encode(f)
    d.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count { let n = write(sock, raw.baseAddress!.advanced(by: off), raw.count - off); if n <= 0 { break }; off += n }
    }
}
let (cols0, rows0) = currentWinsize()
send(.hello(paneID: paneID, cols: cols0, rows: rows0))

// ── SIGWINCH → resize ────────────────────────────────────────────────────────
// C signal handlers can't capture Swift state; stash the socket fd globally.
var gSock: Int32 = sock
signal(SIGWINCH) { _ in
    var ws = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
        let d = encode(ClientFrame.resize(cols: Int(ws.ws_col), rows: Int(ws.ws_row)))
        d.withUnsafeBytes { raw in _ = write(gSock, raw.baseAddress, raw.count) }
    }
}
// M4: GUI signals focus changes to this relay; forward them as focus frames.
// Mirrors the SIGWINCH handler: write directly to gSock (no dispatch run loop).
signal(SIGUSR1) { _ in   // focused
    let d = encode(ClientFrame.focus(true))
    d.withUnsafeBytes { raw in _ = write(gSock, raw.baseAddress, raw.count) }
}
signal(SIGUSR2) { _ in   // idle mirror
    let d = encode(ClientFrame.focus(false))
    d.withUnsafeBytes { raw in _ = write(gSock, raw.baseAddress, raw.count) }
}

// ── pump loop: stdin → daemon(input), daemon(server frames) → stdout ─────────
_ = fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL, 0) | O_NONBLOCK)
_ = fcntl(sock, F_SETFL, fcntl(sock, F_GETFL, 0) | O_NONBLOCK)
var inbuf = Data()
outer: while true {
    var rset = fd_set(); __darwin_fd_set(STDIN_FILENO, &rset); __darwin_fd_set(sock, &rset)
    let maxFD = max(STDIN_FILENO, sock)
    var tv = timeval(tv_sec: 30, tv_usec: 0)
    let n = select(maxFD + 1, &rset, nil, nil, &tv)
    if n < 0 { if errno == EINTR { continue }; break }    // EINTR from SIGWINCH is fine
    // stdin → input frames.
    if __darwin_fd_isset(STDIN_FILENO, &rset) != 0 {
        var tmp = [UInt8](repeating: 0, count: 65536)
        let k = read(STDIN_FILENO, &tmp, tmp.count)
        if k == 0 { break }                                 // EOF on stdin (pane closed) → detach
        if k > 0 { send(.input(Data(tmp[0..<k]))) }
    }
    // daemon → stdout (decode server frames; write output/snapshot bytes).
    if __darwin_fd_isset(sock, &rset) != 0 {
        var tmp = [UInt8](repeating: 0, count: 65536)
        let k = read(sock, &tmp, tmp.count)
        if k <= 0 { break }                                 // daemon gone → exit (shell stays under daemon)
        inbuf.append(Data(tmp[0..<k]))
        while let f = decodeServerFrame(from: &inbuf) {
            switch f {
            case let .snapshot(screen, scrollback, images):
                // Restore scrollback first, then current screen, then replay images.
                FileHandle.standardOutput.write(scrollback)
                FileHandle.standardOutput.write(screen)
                FileHandle.standardOutput.write(images)
            case let .output(bytes):
                FileHandle.standardOutput.write(bytes)
            case .exited:
                break outer                                  // shell exited → relay ends
            case .needsUpdate:
                FileHandle.standardError.write(Data("halo-attach: daemon protocol mismatch; update Halo\n".utf8))
                break outer
            case let .helloAck(version):
                // Client-side version gate: the daemon advertises its version here; if it
                // differs from ours, refuse rather than misparse a newer/older frame stream
                // (critical for remote attach, M5). The shell stays alive under the daemon.
                if version != muxProtocolVersion {
                    FileHandle.standardError.write(Data("halo-attach: daemon protocol v\(version) != client v\(muxProtocolVersion); update Halo\n".utf8))
                    break outer
                }
            case .sessions:
                break                                        // not used by the pump
            }
        }
    }
}
// EOF/quit: just close. We send a detach so the daemon drops our fd promptly,
// but the shell keeps running under halod.
send(.detach)
close(sock)
exit(0)
