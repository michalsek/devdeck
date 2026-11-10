import Darwin
import Foundation

/// Process data read from the kernel (sysctl and libproc), so the scans that run every few
/// seconds don't start `ps` and `lsof`. Like those tools, it sees sockets and working
/// directories of the user's own processes only.
enum LibProc {
    /// Every process, from one KERN_PROC_ALL sysctl (what `ps` reads). The command line is
    /// argv joined with spaces; another user's process gets its executable's path.
    static func processTable() -> [Int32: ServerScanner.ProcessRow] {
        var table: [Int32: ServerScanner.ProcessRow] = [:]
        var buffer = [CChar](repeating: 0, count: argumentsMax)
        for process in kernelProcesses() {
            let pid = process.kp_proc.p_pid
            guard pid > 0 else { continue }
            let start = process.kp_proc.p_starttime
            let started = start.tv_sec > 0
                ? Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1e6) : nil
            table[pid] = ServerScanner.ProcessRow(
                pid: pid, ppid: process.kp_eproc.e_ppid, started: started,
                command: arguments(pid, &buffer) ?? path(pid) ?? name(process))
        }
        return table
    }

    private static func kernelProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
            // Room for processes started between the two calls.
            size += 64 * MemoryLayout<kinfo_proc>.stride
            var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            if sysctl(&mib, 3, &processes, &size, nil, 0) == 0 {
                return Array(processes.prefix(size / MemoryLayout<kinfo_proc>.stride))
            }
            guard errno == ENOMEM else { return [] }
        }
        return []
    }

    private static let argumentsMax: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.argmax", &value, &size, nil, 0) == 0 ? Int(value) : 1 << 20
    }()

    /// From KERN_PROCARGS2: argc, the executable path, padding, then argv. Like `ps`,
    /// newlines show as `\012` and trailing spaces are dropped.
    private static func arguments(_ pid: Int32, _ buffer: inout [CChar]) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        return buffer.withUnsafeBytes { raw -> String? in
            let argc = raw.load(as: Int32.self)
            var index = MemoryLayout<Int32>.size
            while index < size, raw[index] != 0 { index += 1 }
            while index < size, raw[index] == 0 { index += 1 }
            var args: [String] = []
            while args.count < argc, index < size {
                let start = index
                while index < size, raw[index] != 0 { index += 1 }
                args.append(String(decoding: raw[start..<index], as: UTF8.self))
                index += 1
            }
            guard !args.isEmpty else { return nil }
            var line = args.joined(separator: " ").replacingOccurrences(of: "\n", with: "\\012")
            while line.last == " " { line.removeLast() }
            return line
        }
    }

    private static func path(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func name(_ process: kinfo_proc) -> String {
        withUnsafeBytes(of: process.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    // MARK: - Sockets

    /// pid → TCP ports it listens on.
    static func listeningPorts(_ pids: some Sequence<Int32>) -> [Int32: Set<Int>] {
        var ports: [Int32: Set<Int>] = [:]
        forEachTCPSocket(pids) { pid, tcp in
            if tcp.tcpsi_state == TSI_S_LISTEN { ports[pid, default: []].insert(port(tcp.tcpsi_ini.insi_lport)) }
        }
        return ports
    }

    /// pid → the given ports on this Mac (127.0.0.1 or ::1) it has a connection to.
    static func connections(_ pids: some Sequence<Int32>, to wanted: Set<Int>) -> [Int32: Set<Int>] {
        var connections: [Int32: Set<Int>] = [:]
        forEachTCPSocket(pids) { pid, tcp in
            let remote = port(tcp.tcpsi_ini.insi_fport)
            if tcp.tcpsi_state == TSI_S_ESTABLISHED, wanted.contains(remote), isLoopback(tcp.tcpsi_ini) {
                connections[pid, default: []].insert(remote)
            }
        }
        return connections
    }

    private static func forEachTCPSocket(_ pids: some Sequence<Int32>, _ body: (Int32, tcp_sockinfo) -> Void) {
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        for pid in pids {
            for fd in fileDescriptors(pid) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                      info.psi.soi_kind == SOCKINFO_TCP
                else { continue }
                body(pid, info.psi.soi_proto.pri_tcp)
            }
        }
    }

    private static func fileDescriptors(_ pid: Int32) -> [proc_fdinfo] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        return filled > 0 ? Array(fds.prefix(Int(filled) / stride)) : []
    }

    /// Ports are stored in network byte order in the low 16 bits.
    private static func port(_ raw: Int32) -> Int {
        Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: raw)))
    }

    /// 127.0.0.1, ::1 or ::ffff:127.0.0.1 at the other end.
    private static func isLoopback(_ ini: in_sockinfo) -> Bool {
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            return UInt32(bigEndian: ini.insi_faddr.ina_46.i46a_addr4.s_addr) == 0x7F00_0001
        }
        let bytes = withUnsafeBytes(of: ini.insi_faddr.ina_6) { Array($0) }
        let mapped: [UInt8] = Array(repeating: 0, count: 10) + [0xFF, 0xFF, 127, 0, 0, 1]
        return bytes == Array(repeating: 0, count: 15) + [1] || bytes == mapped
    }

    // MARK: - Working directories

    static func workingDirectories(_ pids: [Int32]) -> [Int32: String] {
        var cwds: [Int32: String] = [:]
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        for pid in pids {
            var info = proc_vnodepathinfo()
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if !path.isEmpty { cwds[pid] = path }
        }
        return cwds
    }
}
