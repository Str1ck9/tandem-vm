import AppKit
import Foundation
import GuestLink
import Provisioning
import VMCore

/// Self-test for the Windows display: which sizes the display driver accepts while running (plain display and
/// 3D) and what the guest's display scale does.
///
///   TANDEM_SNAPSHOT_WIN3D_DISPLAY=<vm>     a stopped Windows VM with the guest tools: for the plain display, then for
///                                          3D (the driver is installed by Tandem as for TANDEM_SNAPSHOT_WIN3D):
///                                          list the sizes the guest offers, ask for several sizes the way the VM
///                                          window does and report what Windows ends up at, then set the display
///                                          scale for a Retina-sized screen and read the applied DPI back.
extension SelfTest {
    private static func w3dDisplayLog(_ text: String) { print("selftest-win3d-display: \(text)") }
    private static func w3dDisplayWait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    /// Lists the display modes the guest offers and the current one, and the applied DPI.
    private static let modesScript = """
    Add-Type -TypeDefinition @'
    using System; using System.Runtime.InteropServices;
    public class Modes {
      [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
      public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields;
        public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
      }
      [DllImport("user32.dll", CharSet = CharSet.Ansi)] public static extern bool EnumDisplaySettings(string d, int i, ref DEVMODE m);
      public static string List() {
        var seen = new System.Collections.Generic.SortedSet<string>();
        var m = new DEVMODE(); m.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        for (int i = 0; EnumDisplaySettings(null, i, ref m) && i < 4096; i++) seen.Add(m.dmPelsWidth + "x" + m.dmPelsHeight);
        var cur = new DEVMODE(); cur.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        EnumDisplaySettings(null, -1, ref cur);
        return "current=" + cur.dmPelsWidth + "x" + cur.dmPelsHeight + " count=" + seen.Count + " modes=" + string.Join(",", seen);
      }
    }
    '@
    [Modes]::List()
    $m = Get-ItemProperty 'HKCU:\\Control Panel\\Desktop\\WindowMetrics' -ErrorAction SilentlyContinue
    'AppliedDPI=' + $m.AppliedDPI
    Get-CimInstance Win32_VideoController | ForEach-Object { 'adapter=' + $_.Name + ' / ' + $_.DriverVersion }
    """

    private static func w3dDisplayQuery(_ session: VMSession) async -> String {
        do {
            let result = try await session.link.exec(GuestExecRequest(command: Windows3DDriver.powerShell(modesScript), timeoutSeconds: 90))
            return String(decoding: result.stdout + result.stderr, as: UTF8.self).split(whereSeparator: \.isNewline).joined(separator: " | ")
        } catch { return "query failed: \(error)" }
    }

    private static func w3dDisplayPicture(_ session: VMSession, tag: String) {
        guard let image = session.guestImage(), let directory, let data = VMSession.png(image, maxWidth: 1600) else { return }
        try? data.write(to: directory.appendingPathComponent("\(tag).png"))
    }

    private static func w3dDisplayReady(_ session: VMSession, seconds: Int) async -> Bool {
        for _ in 0..<seconds {
            if session.state == .running, session.agent != nil, session.busy == nil, session.screen != nil { return true }
            await w3dDisplayWait(1)
        }
        return false
    }

    /// Asks for a size the way the VM window does (the display server first, then the guest tools) and waits.
    private static func w3dDisplayAsk(_ session: VMSession, width: Int, height: Int, tag: String) async {
        session.screen?.requestDesktopSize(width: width, height: height)
        await w3dDisplayWait(1.2)
        session.link.requestDisplayResize(width: width, height: height)
        await w3dDisplayWait(5)
        let report = session.displayReport.map { "report \($0.width)x\($0.height) result=\($0.result)" } ?? "no report"
        let picture = session.screen.map { "framebuffer \(Int($0.size.width))x\(Int($0.size.height))" } ?? "no screen"
        w3dDisplayLog("\(tag): asked \(width)x\(height) -> \(report), \(picture)")
    }

    private static func w3dDisplaySizes(_ session: VMSession, tag: String) async {
        w3dDisplayLog("\(tag): " + (await w3dDisplayQuery(session)))
        for (w, h) in [(1512, 870), (1920, 1200), (2560, 1440), (3024, 1740), (3024, 1890), (1700, 900)] {
            await w3dDisplayAsk(session, width: w, height: h, tag: tag)
        }
        w3dDisplayLog("\(tag): after: " + (await w3dDisplayQuery(session)))
    }

    private static func w3dDisplayScale(_ session: VMSession, tag: String) async {
        // A Retina-sized screen in a window of half as many points: the scale should become 200%.
        let size = session.screen.map { CGSize(width: $0.size.width / 2, height: $0.size.height / 2) } ?? CGSize(width: 1512, height: 870)
        session.viewPointSize = size
        w3dDisplayLog("\(tag): scale before: " + (await w3dDisplayQuery(session)))
        w3dDisplayPicture(session, tag: "\(tag)-scale-before")
        session.adjustGuestScale(after: 0.2)
        await w3dDisplayWait(8)
        w3dDisplayLog("\(tag): scale after (window \(Int(size.width))x\(Int(size.height)) pt, requested=\(String(describing: session.retinaScaleRequested))): " + (await w3dDisplayQuery(session)))
        w3dDisplayPicture(session, tag: "\(tag)-scale-after")
        // Back: a window as wide as the screen puts the guest's own scale back.
        session.viewPointSize = session.screen.map { CGSize(width: $0.size.width, height: $0.size.height) } ?? size
        session.adjustGuestScale(after: 0.2)
        await w3dDisplayWait(8)
        w3dDisplayLog("\(tag): scale restored (requested=\(String(describing: session.retinaScaleRequested))): " + (await w3dDisplayQuery(session)))
    }

    static func windows3DDisplayTrial(_ model: AppModel, vm name: String) async {
        guard let session = model.sessions.first(where: { $0.config.name == name }) else { return w3dDisplayLog("no VM named \(name)") }
        let began = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(began)) }

        // 1. The plain display.
        session.start()
        let ready = await w3dDisplayReady(session, seconds: 900)
        await w3dDisplayWait(20)
        w3dDisplayLog("plain: tools=\(ready) agent caps=\(String(describing: session.agent?.capabilities)) at \(elapsed()) s")
        guard ready else { await session.forceStopAndWait(); return }
        w3dDisplayPicture(session, tag: "plain-start")
        await w3dDisplaySizes(session, tag: "plain")
        await w3dDisplayScale(session, tag: "plain")
        session.stop()
        for _ in 0..<240 where session.state.isActive { await w3dDisplayWait(1) }
        if session.state.isActive { await session.forceStopAndWait() }

        // 2. 3D: turn it on and let Tandem install the driver, as TANDEM_SNAPSHOT_WIN3D does.
        var config = session.config
        config.display.accelerated3D = true
        do { try session.apply(config) } catch { return w3dDisplayLog("apply failed: \(error)") }
        session.start()
        for _ in 0..<1500 {
            if session.config.display.windows3DDriver != nil || session.config.display.accelerated3D != true || session.state == .error { break }
            await w3dDisplayWait(1)
        }
        w3dDisplayLog("3D: driver=\(String(describing: session.config.display.windows3DDriver?.version)) error=\(session.errorMessage ?? "none") at \(elapsed()) s")
        guard session.config.display.windows3DDriver != nil else { await session.forceStopAndWait(); return }
        // Tandem restarts Windows after the install.
        for _ in 0..<600 where session.agent != nil { await w3dDisplayWait(0.2) }
        let ready3D = await w3dDisplayReady(session, seconds: 600)
        await w3dDisplayWait(25)
        w3dDisplayLog("3D: tools=\(ready3D) screen=\(session.screen.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none") at \(elapsed()) s")
        if ready3D {
            w3dDisplayPicture(session, tag: "3d-start")
            await w3dDisplaySizes(session, tag: "3d")
            await w3dDisplayScale(session, tag: "3d")
        }
        session.stop()
        for _ in 0..<240 where session.state.isActive { await w3dDisplayWait(1) }
        if session.state.isActive { await session.forceStopAndWait() }
        w3dDisplayLog("final state=\(session.state.rawValue) at \(elapsed()) s")
    }

    /// TANDEM_SNAPSHOT_WIN3D_RETINA=<vm>: the VM as it is configured (plain or 3D display): size the window the way
    /// the VM window does (1512 x 870 points; TANDEM_SNAPSHOT_RETINA_POINTS "WxH" overrides), once without and once
    /// with "Use Retina resolution", and report the guest's size, its display scale and a picture each time.
    static func windowsRetinaTrial(_ model: AppModel, vm name: String) async {
        let env = ProcessInfo.processInfo.environment
        guard let session = model.sessions.first(where: { $0.config.name == name }) else { return w3dDisplayLog("no VM named \(name)") }
        let pointsSpec = (env["TANDEM_SNAPSHOT_RETINA_POINTS"] ?? "1512x870").split(separator: "x").compactMap { Double($0) }
        let points = CGSize(width: pointsSpec.first ?? 1512, height: pointsSpec.last ?? 870)

        // Settings are fixed while the VM runs: TANDEM_SNAPSHOT_RETINA_MODE on|off sets "Use Retina resolution", and
        // TANDEM_SNAPSHOT_RETINA_3D off turns 3D acceleration off (the driver is removed at the start).
        var config = session.config
        config.display.retinaResolution = env["TANDEM_SNAPSHOT_RETINA_MODE"] == "on" ? true : nil
        if env["TANDEM_SNAPSHOT_RETINA_3D"] == "off" { config.display.accelerated3D = nil }
        do { try session.apply(config) } catch { return w3dDisplayLog("apply failed: \(error)") }
        let removeDriver = session.config.display.accelerated3D != true && session.config.display.windows3DDriver != nil

        session.start()
        if removeDriver {
            // Tandem removes the 3D driver and restarts Windows.
            for _ in 0..<600 where session.config.display.windows3DDriver != nil { await w3dDisplayWait(1) }
            for _ in 0..<600 where session.agent != nil { await w3dDisplayWait(0.2) }
        }
        let ready = await w3dDisplayReady(session, seconds: 900)
        await w3dDisplayWait(25)
        let mode = (session.config.display.accelerated3D == true ? "3D" : "plain") + (session.config.display.useRetinaResolution ? "-retina" : "")
        w3dDisplayLog("retina[\(mode)]: tools=\(ready) backing scale=\(VMSession.windowBackingScale) start size=\(session.screen.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none")")
        guard ready else { await session.forceStopAndWait(); return }

        func report(_ tag: String) async {
            await w3dDisplayWait(14)
            let reported = session.displayReport.map { "\($0.width)x\($0.height) result=\($0.result)" } ?? "none"
            let framebuffer = session.screen.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none"
            w3dDisplayLog("retina[\(mode)] \(tag): guest \(reported), framebuffer \(framebuffer), scale requested=\(String(describing: session.retinaScaleRequested))")
            w3dDisplayPicture(session, tag: "retina-\(mode)-\(tag)")
        }

        // The window opens at a size, then the user drags it a little larger.
        session.windowResized(to: CGSize(width: points.width - 80, height: points.height - 40))
        await w3dDisplayWait(3)
        session.windowResized(to: points)
        await report("window \(Int(points.width))x\(Int(points.height)) pt")

        // Back to a smaller window: the scale must go back too.
        session.windowResized(to: CGSize(width: 1000, height: 700))
        await report("window 1000x700 pt")

        session.stop()
        for _ in 0..<240 where session.state.isActive { await w3dDisplayWait(1) }
        if session.state.isActive { await session.forceStopAndWait() }
        w3dDisplayLog("retina[\(mode)]: final state=\(session.state.rawValue)")
    }
}
