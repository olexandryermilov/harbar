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
    let activity: String?
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

    // re-nag: a still-blocked session fires no new hook events, so the app re-pings
    // it on this interval until it's unblocked (the hook owns the first ping at 0m).
    // configurable from the menu; persisted in UserDefaults (key "renagSeconds",
    // 0 = off). power users: `defaults write com.harbar.app renagSeconds <n>`.
    let renagPresets: [(String, Double)] = [
        ("off", 0), ("1 min", 60), ("2 min", 120), ("5 min", 300),
        ("10 min", 600), ("15 min", 900), ("30 min", 1800),
    ]
    var renagSeconds: Double {
        get { UserDefaults.standard.object(forKey: "renagSeconds") as? Double ?? 300 }
        set { UserDefaults.standard.set(newValue, forKey: "renagSeconds") }
    }
    var lastNagged: [String: Date] = [:]                  // "agent-sid" -> last re-ping
    let kindMessage: [String: String] = [
        "permission_prompt": "needs permission",
        "idle_prompt": "waiting for your input",
        "elicitation_dialog": "needs form input",
        "codex_approval": "needs approval",
    ]
    lazy var tnPath: String? = {                          // terminal-notifier, for clickable banners
        for c in ["/opt/homebrew/bin/terminal-notifier", "/usr/local/bin/terminal-notifier"]
        where FileManager.default.isExecutableFile(atPath: c) { return c }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["terminal-notifier"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }()

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
                activity: obj["activity"] as? String,
                lastActivity: last))
        }
        return out
    }

    func kindOf(_ s: Session) -> String {
        if let k = s.kind, !k.isEmpty { return k }
        if s.agent == "codex" { return "codex_approval" }       // backward-compat
        return (s.note?.isEmpty == false) ? s.note! : "other"
    }

    // trailing detail for a row: the needs-input note if any, else what a working
    // session is currently doing (PreToolUse activity).
    func detailStr(_ s: Session) -> String {
        let d = (s.note?.isEmpty == false) ? s.note! : (s.activity ?? "")
        return d.isEmpty ? "" : "  ·  \(d)"
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
        let sessions = loadSessions()
        statusItem.button?.title = titleString(sessions)
        checkRenags(sessions)
    }

    // re-ping every still-blocked session on `renagInterval`; reuse the hook's
    // notification group per session so the banner updates in place (no stacking)
    // and stays clickable -> focus.sh jumps to that terminal.
    func checkRenags(_ sessions: [Session]) {
        let interval = renagSeconds
        if interval <= 0 { lastNagged.removeAll(); return }        // re-nag disabled
        let now = Date()
        let epoch = now.timeIntervalSince1970
        var live = Set<String>()
        for s in sessions where s.status == "needs_input" {
            let key = "\(s.agent)-\(s.sessionId)"
            live.insert(key)
            let waited = epoch - s.lastActivity
            if waited < interval { continue }                      // hook owns the first ping
            if let last = lastNagged[key], now.timeIntervalSince(last) < interval { continue }
            let friendly = kindMessage[kindOf(s)] ?? "needs your input"
            notify(title: "⏳ still waiting · \(s.project) · \(s.terminal)",
                   message: "\(friendly) — \(Int(waited / 60))m",
                   agent: s.agent, sid: s.sessionId)
            lastNagged[key] = now
        }
        lastNagged = lastNagged.filter { live.contains($0.key) }   // forget unblocked sessions
    }

    func notify(title: String, message: String, agent: String, sid: String) {
        let group = "harbar-\(agent)-\(sid)"
        let p = Process()
        if let tn = tnPath {
            p.executableURL = URL(fileURLWithPath: tn)
            p.arguments = ["-title", title, "-message", message, "-sound", "Glass",
                           "-group", group, "-execute", "\(focusScript) \(agent) \(sid)"]
        } else {
            let m = message.replacingOccurrences(of: "\"", with: "'")
            let t = title.replacingOccurrences(of: "\"", with: "'")
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \"\(m)\" with title \"\(t)\" sound name \"Glass\""]
        }
        try? p.run()
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

        let cur = renagSeconds
        let renag = NSMenuItem(title: "Re-nag: \(renagLabel(cur))", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        var matched = false
        for (label, secs) in renagPresets {
            let mi = NSMenuItem(title: label, action: #selector(setRenag(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = secs
            if abs(secs - cur) < 0.5 { mi.state = .on; matched = true }
            sub.addItem(mi)
        }
        if !matched {           // a custom value set via `defaults write`
            let mi = NSMenuItem(title: "custom: \(renagLabel(cur))", action: nil, keyEquivalent: "")
            mi.state = .on; mi.isEnabled = false
            sub.addItem(mi)
        }
        renag.submenu = sub
        menu.addItem(renag)

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
            let title = "  \(tag[s.agent] ?? "?") \(s.displayName)  ·  \(s.terminal)\(detailStr(s))  ·  \(agoStr(s.lastActivity))"
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

    @objc func setRenag(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Double else { return }
        renagSeconds = s
        lastNagged.removeAll()        // restart the cadence from the new setting
    }

    func renagLabel(_ s: Double) -> String {
        if s <= 0 { return "off" }
        if s < 90 { return "\(Int(s))s" }
        let m = Int(s) / 60, rem = Int(s) % 60
        return rem == 0 ? "\(m) min" : "\(m)m\(rem)s"
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
                print("  \(tag[s.agent] ?? "?") \(s.displayName)  ·  \(s.terminal)\(detailStr(s))  ·  \(agoStr(s.lastActivity))")
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
