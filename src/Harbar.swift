// SPDX-License-Identifier: MIT
// Harbar — tiny native menu bar app for the agent harbor.
// reads ~/.harbar/sessions/*.json (written by ~/.harbar/harbar-hook.py), groups
// by status/kind, shows a count badge in the menu bar, and a grouped dropdown.
// click a session to focus its terminal via ~/.harbar/focus.sh.
// run with --dump to print the menu to stdout (for testing, no GUI).
import AppKit
import Foundation
import Darwin

struct Session {
    let agent: String
    let sessionId: String
    let project: String
    let terminal: String
    let status: String
    let kind: String?
    let note: String?
    let branch: String?
    let label: String?
    let lastActivity: Double

    var displayName: String {
        var name = project
        if let b = branch, !b.isEmpty { name += "@\(b)" }
        if let t = label, !t.isEmpty { name += " · \(t)" }
        return name
    }
}

func isAlive(_ pid: Int) -> Bool {
    if pid <= 0 { return false }
    if kill(pid_t(pid), 0) == 0 { return true }
    return errno == EPERM        // exists but owned by another user
}

final class HarbarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".harbar/sessions")
    let focusScript = (NSHomeDirectory() as NSString).appendingPathComponent(".harbar/focus.sh")
    var statusItem: NSStatusItem!
    var timer: Timer?

    let tag = ["claude": "◆", "codex": "☁\u{FE0E}"]   // U+FE0E = text (monochrome) presentation
    // needs-input kinds, each its own section + emoji, in display order
    let kinds: [(String, String, String)] = [
        ("permission_prompt", "🔐", "PERMISSION (claude)"),
        ("codex_approval", "🛑", "APPROVAL (codex)"),
        ("elicitation_dialog", "📝", "INTERVIEW / FORM"),
        ("idle_prompt", "💤", "IDLE PROMPT (waiting on you)"),
    ]
    var kindEmoji: [String: String] { Dictionary(uniqueKeysWithValues: kinds.map { ($0.0, $0.1) }) }
    var kindLabel: [String: String] { Dictionary(uniqueKeysWithValues: kinds.map { ($0.0, $0.2) }) }
    var kindOrder: [String: Int] { Dictionary(uniqueKeysWithValues: kinds.enumerated().map { ($1.0, $0) }) }

    func loadSessions() -> [Session] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        let now = Date().timeIntervalSince1970
        var out: [Session] = []
        for f in files where f.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(f)
            guard let data = fm.contents(atPath: path),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            var pid = obj["agent_pid"] as? Int
            if pid == nil, let d = obj["agent_pid"] as? Double { pid = Int(d) }
            let last = (obj["last_activity"] as? Double) ?? 0
            if !isAlive(pid ?? -1) || now - last > 86400 {     // prune dead / stale
                try? fm.removeItem(atPath: path)
                continue
            }
            out.append(Session(
                agent: obj["agent"] as? String ?? "?",
                sessionId: obj["session_id"] as? String ?? "",
                project: obj["project"] as? String ?? "?",
                terminal: obj["terminal"] as? String ?? "?",
                status: obj["status"] as? String ?? "idle",
                kind: obj["kind"] as? String,
                note: obj["note"] as? String,
                branch: obj["branch"] as? String,
                label: obj["label"] as? String,
                lastActivity: last))
        }
        return out
    }

    func kindOf(_ s: Session) -> String {
        if let k = s.kind, !k.isEmpty { return k }
        if s.agent == "codex" { return "codex_approval" }       // backward-compat
        return (s.note?.isEmpty == false) ? s.note! : "other"
    }

    func agoStr(_ t: Double) -> String {
        let s = Int(max(0, Date().timeIntervalSince1970 - t))
        if s < 90 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }

    func orderedNeedsKinds(_ byKind: [String: [Session]]) -> [String] {
        byKind.keys.sorted { (kindOrder[$0] ?? 99, $0) < (kindOrder[$1] ?? 99, $1) }
    }

    func titleString(_ sessions: [Session]) -> String {
        let needs = sessions.filter { $0.status == "needs_input" }
        var counts: [String: Int] = [:]
        for s in needs { counts[kindOf(s), default: 0] += 1 }
        var parts: [String] = []
        for k in counts.keys.sorted(by: { (kindOrder[$0] ?? 99, $0) < (kindOrder[$1] ?? 99, $1) }) {
            parts.append("\(kindEmoji[k] ?? "⏳")\(counts[k]!)")
        }
        let working = sessions.filter { $0.status == "working" }.count
        let idle = sessions.filter { $0.status == "idle" }.count
        if working > 0 { parts.append("▸\(working)") }
        parts.append("✓\(idle)")
        return parts.joined(separator: " ")
    }

    // MARK: lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        tick()
        timer = Timer.scheduledTimer(timeInterval: 2, target: self,
                                     selector: #selector(tick), userInfo: nil, repeats: true)
    }

    @objc func tick() {
        statusItem.button?.title = titleString(loadSessions())
    }

    // MARK: menu (rebuilt lazily on open so it never disrupts an open menu)
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let sessions = loadSessions()
        statusItem.button?.title = titleString(sessions)

        let needs = sessions.filter { $0.status == "needs_input" }
        var byKind: [String: [Session]] = [:]
        for s in needs { byKind[kindOf(s), default: []].append(s) }

        if sessions.isEmpty {
            let it = NSMenuItem(title: "no sessions", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        }
        for k in orderedNeedsKinds(byKind) {
            addSection(menu, "\(kindEmoji[k] ?? "⏳") \(kindLabel[k] ?? k.uppercased())", byKind[k]!)
        }
        addIf(menu, "▸ WORKING", sessions.filter { $0.status == "working" })
        addIf(menu, "⚠ ERROR", sessions.filter { $0.status == "error" })
        addIf(menu, "✓ IDLE", sessions.filter { $0.status == "idle" })

        menu.addItem(.separator())
        let r = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)
        let q = NSMenuItem(title: "Quit Harbar", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    func addIf(_ menu: NSMenu, _ header: String, _ rows: [Session]) {
        if !rows.isEmpty { addSection(menu, header, rows) }
    }

    func addSection(_ menu: NSMenu, _ header: String, _ rows: [Session]) {
        let h = NSMenuItem(title: "\(header) (\(rows.count))", action: nil, keyEquivalent: "")
        h.isEnabled = false
        menu.addItem(h)
        for s in rows.sorted(by: { $0.displayName < $1.displayName }) {
            let note = (s.note?.isEmpty == false) ? "  ·  \(s.note!)" : ""
            let title = "  \(tag[s.agent] ?? "?") \(s.displayName)  ·  \(s.terminal)\(note)  ·  \(agoStr(s.lastActivity))"
            let it = NSMenuItem(title: title, action: #selector(focus(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = [s.agent, s.sessionId]
            menu.addItem(it)
        }
    }

    @objc func focus(_ sender: NSMenuItem) {
        guard let arr = sender.representedObject as? [String], arr.count == 2 else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [focusScript, arr[0], arr[1]]
        try? p.run()
    }

    @objc func refreshNow() { tick() }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: cli dump (testing, no GUI)
    func dump() {
        let sessions = loadSessions()
        print(titleString(sessions))
        print("---")
        let needs = sessions.filter { $0.status == "needs_input" }
        var byKind: [String: [Session]] = [:]
        for s in needs { byKind[kindOf(s), default: []].append(s) }
        func sect(_ header: String, _ rows: [Session]) {
            print("\(header) (\(rows.count))")
            for s in rows.sorted(by: { $0.displayName < $1.displayName }) {
                let note = (s.note?.isEmpty == false) ? "  ·  \(s.note!)" : ""
                print("  \(tag[s.agent] ?? "?") \(s.displayName)  ·  \(s.terminal)\(note)  ·  \(agoStr(s.lastActivity))")
            }
        }
        if sessions.isEmpty { print("no sessions") }
        for k in orderedNeedsKinds(byKind) { sect("\(kindEmoji[k] ?? "⏳") \(kindLabel[k] ?? k.uppercased())", byKind[k]!) }
        let working = sessions.filter { $0.status == "working" }
        let errored = sessions.filter { $0.status == "error" }
        let idle = sessions.filter { $0.status == "idle" }
        if !working.isEmpty { sect("▸ WORKING", working) }
        if !errored.isEmpty { sect("⚠ ERROR", errored) }
        if !idle.isEmpty { sect("✓ IDLE", idle) }
    }
}

// entry point
if CommandLine.arguments.contains("--dump") {
    HarbarController().dump()
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)        // menu bar only, no dock icon
let controller = HarbarController()
app.delegate = controller
app.run()
