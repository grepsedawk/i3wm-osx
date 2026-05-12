import CoreLocation
import CoreWLAN
import Foundation

/// Polls the current Wi-Fi SSID and writes it to a file for the status bar
/// to read. macOS Sequoia (15+) redacts SSIDs from every non-privileged
/// command-line tool; the only way to read the real SSID is via CoreWLAN
/// from a process that has been granted Location Services.
final class SSIDProvider: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var timer: DispatchSourceTimer?
    private let outputPath: String

    override init() {
        let uid = getuid()
        self.outputPath = "/tmp/i3wm-osx-ssid.\(uid)"
        super.init()
        locationManager.delegate = self
    }

    func start() {
        locationManager.requestWhenInUseAuthorization()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 15)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    private func refresh() {
        let iface = CWWiFiClient.shared().interface()
        let ssid = iface?.ssid() ?? ""
        let bssid = iface?.bssid() ?? ""
        // iPhones' Personal Hotspot AP advertises a locally-administered MAC
        // (the second-least-significant bit of the first octet is set).
        // Regular routers use OUI-assigned MACs with that bit clear.
        let isHotspot: Bool = {
            guard let firstOctet = bssid.split(separator: ":").first,
                  let byte = UInt8(firstOctet, radix: 16) else { return false }
            return (byte & 0x02) != 0
        }()
        let payload = "\(ssid)\t\(isHotspot ? "hotspot" : "wifi")\n"
        let tmp = outputPath + ".tmp"
        try? payload.write(toFile: tmp, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(
            URL(fileURLWithPath: outputPath),
            withItemAt: URL(fileURLWithPath: tmp))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refresh()
    }
}
