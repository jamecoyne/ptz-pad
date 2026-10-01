import Combine
import Darwin
import Foundation
import Network

/// One IPv4 interface on this Mac.
struct LocalInterface: Equatable {
    let name: String
    let address: UInt32       // host byte order
    let mask: UInt32

    var prefix: Int { mask.nonzeroBitCount }
    var network: UInt32 { address & mask }
    var cidr: String { "\(IPv4.string(address))/\(prefix)" }

    func contains(_ ip: UInt32) -> Bool { ip & mask == network }

    /// Active, non-loopback IPv4 interfaces (Wi-Fi, Ethernet, USB adapters…).
    static func all() -> [LocalInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var out: [LocalInterface] = []
        for p in sequence(first: head, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = ifa.ifa_netmask else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // Self-assigned 169.254 addresses mean "no DHCP here", not a real network.
            guard a >> 16 != 0xA9FE else { continue }
            out.append(LocalInterface(name: String(cString: ifa.ifa_name), address: a, mask: m))
        }
        return out
    }
}

enum IPv4 {
    static func parse(_ s: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    static func string(_ ip: UInt32) -> String {
        "\(ip >> 24).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)"
    }
}

/// The camera's address is on a network this Mac isn't on.
struct SubnetWarning: Equatable {
    let cameraIP: String
    let localNetworks: String
    let interface: String
    /// A spare address on the camera's /24 for a temporary alias.
    let aliasIP: String

    var aliasCommand: String { "sudo ifconfig \(interface) alias \(aliasIP) 255.255.255.0" }
    var removeCommand: String { "sudo ifconfig \(interface) -alias \(aliasIP)" }
}

struct ScanHit: Identifiable, Equatable {
    let ip: String
    let ndiName: String?
    var id: String { ip }
}

/// Keeps track of the camera when it changes networks:
///
/// 1. **Follow by NDI name.** Once the camera answers VISCA at an address that's also
///    announcing an NDI source, that source's name is remembered. If the camera stops
///    answering and the same NDI name shows up at a different IP, the VISCA host moves
///    there. NDI announcements travel over mDNS, so this works anywhere on the local link.
/// 2. **Subnet check.** A camera with a fixed IP from another network can still be seen
///    (mDNS reaches it over the same switch) but not talked to. That case gets a warning
///    with the fixes.
/// 3. **Scan.** A VISCA position inquiry to every address on this Mac's networks, for when
///    NDI is off.
final class CameraLocator: ObservableObject {
    static let shared = CameraLocator()

    @Published var followNDI: Bool { didSet { defaults.set(followNDI, forKey: "followCameraNDI"); evaluate() } }
    @Published private(set) var cameraNDIName: String? { didSet { defaults.set(cameraNDIName, forKey: "cameraNDIName") } }
    @Published private(set) var subnetWarning: SubnetWarning?
    @Published private(set) var scanning = false
    @Published private(set) var scanResults: [ScanHit] = []
    @Published private(set) var scanSummary: String?

    private let defaults = UserDefaults.standard
    private var cancellables: Set<AnyCancellable> = []
    private let pathMonitor = NWPathMonitor()
    private var lastFollowedAt = Date.distantPast
    private let scanQueue = DispatchQueue(label: "ptzpad.scan")

    private var camera: CameraController { .shared }
    private var video: VideoController { .shared }

    private init() {
        followNDI = defaults.object(forKey: "followCameraNDI") as? Bool ?? true
        cameraNDIName = defaults.string(forKey: "cameraNDIName")
    }

    func start() {
        // Main-queue receive: each trigger fires after the property has actually changed.
        // Following only reacts to the camera going quiet or NDI sources changing — never to
        // the Host field, which changes on every keystroke while someone is typing an IP.
        video.$sources.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }.store(in: &cancellables)
        camera.$cameraResponding.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }.store(in: &cancellables)
        camera.$host.debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateSubnetWarning() }.store(in: &cancellables)
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.updateSubnetWarning() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "ptzpad.path"))
    }

    func forgetNDIName() {
        cameraNDIName = nil
    }

    /// Point VISCA at an address (from a scan hit) and connect.
    func use(_ ip: String) {
        guard ip != camera.host || !camera.socketReady else { return }
        camera.appendLog("Camera host set to \(ip)")
        camera.host = ip
        camera.connect()
    }

    // MARK: Follow + subnet check

    private func evaluate() {
        let sources = video.sources

        // Learn: the camera answers at this IP, and an NDI source lives there too.
        if camera.cameraResponding,
           let source = sources.first(where: { $0.host == camera.host }),
           source.name != cameraNDIName {
            cameraNDIName = source.name
            camera.appendLog("Camera's NDI name is \"\(source.name)\" — will follow it if its IP changes")
        }

        // Follow: the camera has gone quiet and its NDI name is announced somewhere else.
        // Rate-limited so two sources fighting over one name can't make it flap.
        if followNDI, !camera.cameraResponding,
           let name = cameraNDIName,
           let source = sources.first(where: { $0.name == name }),
           IPv4.parse(source.host) != nil, source.host != camera.host,
           Date().timeIntervalSince(lastFollowedAt) > 5 {
            lastFollowedAt = Date()
            camera.appendLog("Camera moved: \(camera.host) → \(source.host) (found via NDI \"\(name)\")")
            camera.host = source.host
            camera.connect()
        }

        updateSubnetWarning()
    }

    private func updateSubnetWarning() {
        let interfaces = LocalInterface.all()
        guard let ip = IPv4.parse(camera.host), ip >> 24 != 127, !interfaces.isEmpty,
              !interfaces.contains(where: { $0.contains(ip) }) else {
            if subnetWarning != nil { subnetWarning = nil }
            return
        }
        // Alias on the interface carrying the default route if there is one, else the first.
        let iface = interfaces.first(where: { $0.name == "en0" }) ?? interfaces[0]
        let base = ip & 0xFFFF_FF00
        let last = ip & 0xFF
        let alias = base | (last == 250 ? 251 : 250)
        let warning = SubnetWarning(
            cameraIP: camera.host,
            localNetworks: interfaces.map { "\($0.name) \($0.cidr)" }.joined(separator: ", "),
            interface: iface.name,
            aliasIP: IPv4.string(alias))
        if warning != subnetWarning {
            subnetWarning = warning
            camera.appendLog("Camera \(camera.host) isn't on this Mac's networks (\(warning.localNetworks))")
        }
    }

    // MARK: Scan

    /// Sends a VISCA pan/tilt inquiry to every address on this Mac's networks and lists
    /// whatever answers. Networks bigger than a /22 are limited to the /24 around this
    /// Mac's own address.
    func scan() {
        guard !scanning else { return }
        let interfaces = LocalInterface.all()
        guard !interfaces.isEmpty else {
            scanSummary = "No network connection"
            return
        }
        scanning = true
        scanResults = []
        scanSummary = nil
        let port = UInt16(clamping: camera.port)
        let ndi = Dictionary(video.sources.map { ($0.host, $0.name) }, uniquingKeysWith: { a, _ in a })

        var targets: [UInt32] = []
        var described: [String] = []
        for iface in interfaces {
            let mask = iface.prefix < 22 ? 0xFFFF_FF00 : iface.mask
            let network = iface.address & mask
            let broadcast = network | ~mask
            guard broadcast > network + 1 else { continue }
            targets += (network + 1)..<broadcast
            described.append("\(IPv4.string(network))/\(mask.nonzeroBitCount)")
        }
        targets = Array(Set(targets))
        camera.appendLog("Scanning \(described.joined(separator: ", ")) for VISCA on port \(port)…")

        scanQueue.async { [weak self] in
            let found = CameraLocator.probe(targets, port: port)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanResults = found.sorted { $0 < $1 }.map {
                    ScanHit(ip: IPv4.string($0), ndiName: ndi[IPv4.string($0)])
                }
                self.scanning = false
                self.scanSummary = found.isEmpty
                    ? "Nothing answered on \(described.joined(separator: ", "))"
                    : "\(found.count) found on \(described.joined(separator: ", "))"
                self.camera.appendLog("Scan: \(self.scanResults.map(\.ip).joined(separator: ", ").ifEmpty("no VISCA replies"))")
            }
        }
    }

    /// Blocking; runs on `scanQueue`. Two rounds of inquiries — the first one to an address
    /// may be swallowed while ARP resolves it — then collects replies until things go quiet.
    private static func probe(_ targets: [UInt32], port: UInt16) -> Set<UInt32> {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var found = Set<UInt32>()
        let inquiry = Visca.panTiltPosInq

        func send(to ip: UInt32) {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = ip.bigEndian
            _ = inquiry.withUnsafeBytes { bytes in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        func drain(for seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            var buffer = [UInt8](repeating: 0, count: 64)
            while Date() < deadline {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, 50) > 0 else { continue }
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, &buffer, buffer.count, 0, $0, &len)
                    }
                }
                // A VISCA reply starts with the camera's reply address (0x90 for camera 1)
                // and ends with 0xFF.
                if n >= 3, buffer[0] & 0xF0 >= 0x90, buffer[Int(n) - 1] == 0xFF {
                    found.insert(UInt32(bigEndian: from.sin_addr.s_addr))
                }
            }
        }

        for round in 0..<2 {
            for (i, ip) in targets.enumerated() where !found.contains(ip) {
                send(to: ip)
                // Pace the burst so the interface queue and ARP table keep up.
                if i % 32 == 31 { drain(for: 0.01) }
            }
            drain(for: round == 0 ? 1.0 : 1.5)
        }
        return found
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
