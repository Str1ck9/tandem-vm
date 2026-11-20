import Foundation
import TandemControl

/// Plain-text answers for people; `--json` prints the result itself.
enum Output {
    static func pad(_ s: String, _ width: Int) -> String { s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count) }

    static func human(_ op: ControlOp, _ r: JSON) -> String {
        switch op {
        case .status:
            return """
            Tandem \(r["version"]?.string ?? "")
            library:  \(r["library"]?.string ?? "")
            VMs:      \(r["vms"]?.int ?? 0), \(r["running"]?.int ?? 0) running
            AI tools: \(r["allowAITools"]?.bool == true ? "allowed" : "not allowed")

            """
        case .list:
            let rows = r.array ?? []
            if rows.isEmpty { return "No virtual machines.\n" }
            var out = pad("ID", 10) + pad("NAME", 26) + pad("OS", 14) + pad("STATE", 22) + "IP\n"
            for vm in rows {
                out += pad(String((vm["id"]?.string ?? "").prefix(8)).lowercased(), 10) + pad(vm["name"]?.string ?? "", 26)
                    + pad(vm["os"]?.string ?? "", 14) + pad(vm["status"]?.string ?? "", 22) + (vm["ip"]?.string ?? "-") + "\n"
            }
            return out
        case .info:
            var lines = [
                "\(r["name"]?.string ?? "")  (\(r["id"]?.string ?? ""))",
                "state:     \(r["status"]?.string ?? "")",
                "system:    \(r["os"]?.string ?? "") on \(r["engine"]?.string ?? ""), \(r["cpus"]?.int ?? 0) CPUs, \(r["memoryMiB"]?.int ?? 0) MiB, \(r["diskGiB"]?.int ?? 0) GiB disk",
                "tools:     \(r["tools"]?["connected"]?.bool == true ? "connected, version \(r["tools"]?["version"]?.string ?? "?")" : "not connected")",
            ]
            if let guest = r["guest"] {
                lines.append("guest:     \(guest["hostname"]?.string ?? "") \(guest["os"]?.string ?? "")")
                lines.append("addresses: \((guest["addresses"]?.array ?? []).compactMap(\.string).joined(separator: ", "))")
            }
            lines.append("commands:  \(r["commands"]?.string ?? "")")
            lines.append("snapshots: \(r["snapshots"]?.int ?? 0)")
            if let error = r["error"]?.string { lines.append("error:     \(error)") }
            lines.append("bundle:    \(r["bundle"]?.string ?? "")")
            return lines.joined(separator: "\n") + "\n"
        case .ip:
            return (r["addresses"]?.array ?? []).compactMap(\.string).joined(separator: "\n") + "\n"
        case .start, .stop, .suspend, .resume, .pause, .restart, .reset:
            return "\(r["name"]?.string ?? ""): \(r["status"]?.string ?? "")\n"
        case .snapshotList:
            let rows = r.array ?? []
            if rows.isEmpty { return "No snapshots.\n" }
            return rows.map { s in
                "\(s["current"]?.bool == true ? "*" : " ") \(String((s["id"]?.string ?? "").prefix(8)).lowercased())  \(pad(s["name"]?.string ?? "", 30))\(s["created"]?.string ?? "")\(s["includesRunningState"]?.bool == true ? "  (with memory)" : "")"
            }.joined(separator: "\n") + "\n"
        case .snapshotTake: return "Took snapshot “\(r["name"]?.string ?? "")”.\n"
        case .clone:
            let mib = (r["bytesUsed"]?.int ?? 0) / 1_048_576
            let identity = r["identity"]?.string == "kept" ? "same identity (do not run both at once)" : "new machine identity"
            return "Cloned as “\(r["name"]?.string ?? "")” (\(identity)); about \(mib) MiB of disk used so far.\n"
        case .snapshotRevert: return "Went back to “\(r["reverted"]?.string ?? "")”; the VM is \(r["state"]?.string ?? "").\n"
        case .snapshotDelete: return "Deleted snapshot “\(r["deleted"]?.string ?? "")”.\n"
        case .sharing, .share, .unshare:
            return (r["summary"]?.array ?? []).compactMap(\.string).joined(separator: "\n") + "\n"
        case .services:
            let rows = r.array ?? []
            if rows.isEmpty { return "No published services.\n" }
            return rows.map { s in
                "\(pad(s["name"]?.string ?? "", 20)) guest \(s["guestPort"]?.int ?? 0) -> Mac \(s["hostPort"]?.int ?? 0)  \(s["scope"]?.string ?? "")  \(s["listening"]?.bool == true ? "listening" : (s["error"]?.string ?? "not running"))"
            }.joined(separator: "\n") + "\n"
        case .keepAwake: return "Keep Awake is \(r["keepAwake"]?.bool == true ? "on" : "off").\n"
        case .programs:
            return (r.array ?? []).compactMap { $0["name"]?.string }.joined(separator: "\n") + "\n"
        case .launch: return "Started \(r["launched"]?.string ?? "").\n"
        case .exec:
            var out = r["stdout"]?.string ?? ""
            if let err = r["stderr"]?.string, !err.isEmpty { FileHandle.standardError.write(Data(err.utf8)) }
            if r["stdoutTruncated"]?.bool == true { out += "\n[output cut short]\n" }
            return out
        case .screenshot: return ""
        }
    }
}
