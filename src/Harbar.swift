// SPDX-License-Identifier: MIT
// Harbar — tiny native menu bar app for the agent harbor.
// reads ~/.harbar/sessions/*.json (written by ~/.harbar/harbar-hook.py), groups
// by status/kind, shows a count badge in the menu bar, and a grouped dropdown.
// click a session to focus its terminal via ~/.harbar/focus.sh.
// run with --dump to print the menu to stdout (for testing, no GUI).
import AppKit
import Foundation
import Darwin
import Carbon.HIToolbox

// a session driven by /loop — written by the hook from the UserPromptSubmit
// stream (initial '/loop [Nm] <task>' + each wakeup re-submitting the task).
struct LoopInfo {
    let n: Int            // cycles so far
    let every: Double?    // fixed interval parsed from '/loop 5m …' (nil = self-paced)
    let avg: Double?      // measured mean gap between cycles
    let last: Double      // epoch of the latest cycle start
    let nextAt: Double?   // exact next fire (from ScheduleWakeup), dynamic loops only
}

struct Session {
    let agent: String
    let sessionId: String
    let project: String
    let cwd: String
    let terminal: String
    let status: String
    let kind: String?
    let note: String?
    let branch: String?
    let label: String?
    let activity: String?
    let loop: LoopInfo?
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

// a section header you can click to fold/unfold its group. a plain NSMenuItem
// click would close the whole menu — a view-backed item handles the click
// itself and asks the controller to rebuild the open menu in place.
final class FoldHeaderView: NSView {
    let key: String
    weak var controller: HarbarController?

    init(key: String, title: String, controller: HarbarController) {
        self.key = key
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        autoresizingMask = [.width]
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 14, y: 2, width: 600, height: 16)
        label.autoresizingMask = [.width]
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    override func mouseUp(with event: NSEvent) {
        controller?.toggleFold(key)
    }
}

final class HarbarController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".harbar/sessions")
    let recentDir = (NSHomeDirectory() as NSString).appendingPathComponent(".harbar/recent")
    let focusScript = (NSHomeDirectory() as NSString).appendingPathComponent(".harbar/focus.sh")
    let resumeScript = (NSHomeDirectory() as NSString).appendingPathComponent(".harbar/resume.sh")
    // snooze state: {"<agent>-<sid>": "<kind>"} — a session is muted while it stays
    // in that kind; reminders resume (and the snooze clears) once the kind changes.
    let snoozePath = (NSHomeDirectory() as NSString).appendingPathComponent(".harbar/snoozed.json")
    // pinned projects: ["project", …] — their sessions sort first, wear 📌, and
    // stay at top level when the idle section folds.
    let pinnedPath = (NSHomeDirectory() as NSString).appendingPathComponent(".harbar/pinned.json")
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

    // reminders: a still-blocked session fires no new hook events, so the app
    // re-reminds on an interval until it's unblocked (the hook owns the first ping
    // at 0m). the interval is configurable PER KIND from the menu, persisted in
    // UserDefaults under "remind.<kind>" (0 = off). the legacy global "renagSeconds"
    // (shipped in 1.2.0) is still honored as the fallback for any untuned kind.
    // power users: defaults write com.harbar.app "remind.permission_prompt" 600
    let remindPresets: [(String, Double)] = [
        ("off", 0), ("1 min", 60), ("2 min", 120), ("5 min", 300),
        ("10 min", 600), ("15 min", 900), ("30 min", 1800),
    ]
    // per-kind defaults: prompts are less urgent than permission/approval gates.
    let remindDefaults: [String: Double] = [
        "permission_prompt": 300, "codex_approval": 300,
        "elicitation_dialog": 300, "idle_prompt": 900,
    ]
    let remindKindName: [String: String] = [
        "permission_prompt": "permission", "codex_approval": "codex approval",
        "elicitation_dialog": "form", "idle_prompt": "idle prompt",
    ]
    // interval for a kind: its own setting, else the legacy global, else the default.
    func remindInterval(for kind: String) -> Double {
        if let v = UserDefaults.standard.object(forKey: "remind.\(kind)") as? Double { return v }
        if let g = UserDefaults.standard.object(forKey: "renagSeconds") as? Double { return g }
        return remindDefaults[kind] ?? 300
    }
    var lastReminded: [String: Date] = [:]                // "agent-sid" -> last reminder

    func loadSnoozed() -> [String: String] {
        guard let d = FileManager.default.contents(atPath: snoozePath),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: String]
        else { return [:] }
        return o
    }
    func saveSnoozed(_ m: [String: String]) {
        if let d = try? JSONSerialization.data(withJSONObject: m) {
            try? d.write(to: URL(fileURLWithPath: snoozePath))
        }
    }
    func sessionKey(_ s: Session) -> String { "\(s.agent)-\(s.sessionId)" }
    // two snooze flavors: a blocked row snoozes kind-scoped (auto-clears when the
    // group changes); any other row snoozes "*" — fully muted, incl. the hook's
    // first ping, until manually resumed (or the session ends).
    func isSnoozed(_ s: Session) -> Bool {
        let v = loadSnoozed()[sessionKey(s)]
        return v == "*" || v == kindOf(s)
    }

    func loadPinned() -> Set<String> {
        guard let d = FileManager.default.contents(atPath: pinnedPath),
              let a = (try? JSONSerialization.jsonObject(with: d)) as? [String]
        else { return [] }
        return Set(a)
    }
    func savePinned(_ p: Set<String>) {
        if let d = try? JSONSerialization.data(withJSONObject: Array(p).sorted()) {
            try? d.write(to: URL(fileURLWithPath: pinnedPath))
        }
    }
    func isPinned(_ s: Session) -> Bool { loadPinned().contains(s.project) }
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

    func parseSession(_ obj: [String: Any], lastKey: String = "last_activity") -> Session {
        var loop: LoopInfo? = nil
        if let lo = obj["loop"] as? [String: Any] {
            loop = LoopInfo(
                n: (lo["n"] as? NSNumber)?.intValue ?? 1,
                every: (lo["every"] as? NSNumber)?.doubleValue,
                avg: (lo["avg"] as? NSNumber)?.doubleValue,
                last: (lo["last"] as? NSNumber)?.doubleValue ?? 0,
                nextAt: (lo["next_at"] as? NSNumber)?.doubleValue)
        }
        return Session(
            agent: obj["agent"] as? String ?? "?",
            sessionId: obj["session_id"] as? String ?? "",
            project: obj["project"] as? String ?? "?",
            cwd: obj["cwd"] as? String ?? "",
            terminal: obj["terminal"] as? String ?? "?",
            status: obj["status"] as? String ?? "idle",
            kind: obj["kind"] as? String,
            note: obj["note"] as? String,
            branch: obj["branch"] as? String,
            label: obj["label"] as? String,
            activity: obj["activity"] as? String,
            loop: loop,
            lastActivity: (obj[lastKey] as? Double) ?? 0)
    }

    func loadSessions() -> [Session] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        let now = Date().timeIntervalSince1970
        var out: [Session] = []
        for f in files where f.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(f)
            guard let data = fm.contents(atPath: path),
                  var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            var pid = obj["agent_pid"] as? Int
            if pid == nil, let d = obj["agent_pid"] as? Double { pid = Int(d) }
            let last = (obj["last_activity"] as? Double) ?? 0
            if now - last > 86400 {                            // stale: drop entirely
                try? fm.removeItem(atPath: path)
                continue
            }
            if !isAlive(pid ?? -1) {                           // dead: retire to recent
                obj["status"] = "ended"
                obj["ended_at"] = now
                obj.removeValue(forKey: "kind"); obj.removeValue(forKey: "note")
                obj.removeValue(forKey: "activity")
                try? fm.createDirectory(atPath: recentDir, withIntermediateDirectories: true)
                if let d = try? JSONSerialization.data(withJSONObject: obj) {
                    try? d.write(to: URL(fileURLWithPath: (recentDir as NSString).appendingPathComponent(f)))
                }
                try? fm.removeItem(atPath: path)
                continue
            }
            out.append(parseSession(obj))
        }
        return out
    }

    // ended sessions the hook/prune retired — offered for `--resume`, newest first
    func loadRecent(limit: Int = 8) -> [Session] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: recentDir) else { return [] }
        let now = Date().timeIntervalSince1970
        var out: [Session] = []
        for f in files where f.hasSuffix(".json") {
            let path = (recentDir as NSString).appendingPathComponent(f)
            guard let data = fm.contents(atPath: path),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            let ended = (obj["ended_at"] as? Double) ?? 0
            if now - ended > 7 * 86400 {                       // a week is no longer "recent"
                try? fm.removeItem(atPath: path)
                continue
            }
            out.append(parseSession(obj, lastKey: "ended_at"))
        }
        return Array(out.sorted { $0.lastActivity > $1.lastActivity }.prefix(limit))
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

    // MARK: loop sessions (/loop)
    // cancelling a loop (ctrl-c) fires no hook event, so a loop whose next cycle
    // never came is dead — stale it out after ~2.5 missed periods. an explicit
    // next_at (ScheduleWakeup) extends the window for slow dynamic loops.
    func loopActive(_ s: Session) -> Bool {
        guard let l = s.loop else { return false }
        let now = Date().timeIntervalSince1970
        if let nx = l.nextAt, now < nx + 120 { return true }
        let period = l.every ?? l.avg ?? 600
        return now - l.last < 2.5 * period + 60
    }

    // "×6 · every 1m · ▸ editing x" while a cycle runs, "×6 · every 1m · ⏲ next ~40s"
    // while it sleeps. cadence: parsed interval for fixed loops, measured avg for
    // dynamic ones (avg is honest about wandering self-paced delays).
    func loopStr(_ s: Session) -> String {
        guard let l = s.loop else { return "" }
        var parts = ["×\(l.n)"]
        if let e = l.every { parts.append("every \(durStr(e))") }
        else if let a = l.avg { parts.append("avg ~\(durStr(a))") }
        if s.status == "working" {
            if let act = s.activity, !act.isEmpty { parts.append("▸ \(act)") }
        } else {
            let now = Date().timeIntervalSince1970
            let nx = l.nextAt ?? l.last + (l.every ?? l.avg ?? 0)
            if nx > now { parts.append("⏲ next ~\(durStr(nx - now))") }
        }
        return parts.joined(separator: " · ")
    }

    func durStr(_ secs: Double) -> String {
        let v = Int(secs.rounded())
        if v >= 3600 && v % 3600 == 0 { return "\(v / 3600)h" }     // whole units first:
        if v >= 60 && v % 60 == 0 { return "\(v / 60)m" }           // 'every 1m', not 'every 60s'
        if v < 100 { return "\(v)s" }
        if v < 5400 { return "\((v + 30) / 60)m" }
        return "\((v + 1800) / 3600)h"
    }

    // the loop is a flag, not a state: rows stay in their natural status section
    // (working / idle / blocked kind) and just carry the 🔁 mark + loop detail.
    func loopDetail(_ s: Session) -> Bool {
        loopActive(s) && (s.status == "working" || s.status == "idle")
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
        // recent (ended) sessions are background info — folded unless opened
        UserDefaults.standard.register(defaults: ["fold.recent": true])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        registerHotkey()
        tick()
        timer = Timer.scheduledTimer(timeInterval: 2, target: self,
                                     selector: #selector(tick), userInfo: nil, repeats: true)
    }

    @objc func tick() {
        let sessions = loadSessions()
        statusItem.button?.title = titleString(sessions)
        checkReminders(sessions)
    }

    // MARK: keyboard triage — a global hotkey (default ⌃⌥J) jumps to the
    // longest-blocked session; mashing it cycles through the whole blocked queue.
    // Carbon RegisterEventHotKey needs no Accessibility/Input-Monitoring grant.
    // remap: defaults write com.harbar.app hotkeyKeyCode 38; hotkeyModifiers 6144
    // (Carbon masks: ctrl 4096, opt 2048, shift 512, cmd 256; 0 keycode = disable)
    var hotKeyRef: EventHotKeyRef?
    var triageIdx = 0

    func registerHotkey() {
        let d = UserDefaults.standard
        let keyCode = UInt32(d.object(forKey: "hotkeyKeyCode") as? Int ?? kVK_ANSI_J)
        let mods = UInt32(d.object(forKey: "hotkeyModifiers") as? Int ?? (controlKey | optionKey))
        if keyCode == 0 { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            Unmanaged<HarbarController>.fromOpaque(userData!).takeUnretainedValue().triageNext()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x48425252), id: 1)   // 'HBRR'
        RegisterEventHotKey(keyCode, mods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    @objc func triageNext() {
        // longest-waiting first; snoozed ones go to the back of the cycle
        let blocked = loadSessions().filter { $0.status == "needs_input" }
        let queue = sorted(blocked.filter { !isSnoozed($0) }, byWait: true)
                  + sorted(blocked.filter { isSnoozed($0) }, byWait: true)
        guard !queue.isEmpty else { return }
        let s = queue[triageIdx % queue.count]
        triageIdx += 1
        runFocus(s.agent, s.sessionId)
    }

    func runFocus(_ agent: String, _ sid: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [focusScript, agent, sid]
        try? p.run()
    }

    // remind on every still-blocked session on its kind's interval; reuse the hook's
    // notification group per session so the banner updates in place (no stacking)
    // and stays clickable -> focus.sh jumps to that terminal.
    func checkReminders(_ sessions: [Session]) {
        let now = Date()
        let epoch = now.timeIntervalSince1970
        var snoozed = loadSnoozed()
        var snoozeChanged = false
        var live = Set<String>()
        var blocked = Set<String>()
        for s in sessions where s.status == "needs_input" {
            let kind = kindOf(s)
            let key = "\(s.agent)-\(s.sessionId)"
            blocked.insert(key)
            // a kind-scoped snooze only holds while the session stays in that kind;
            // once the group changes, drop it (the hook already re-notified for the
            // new kind). a "*" snooze is a full manual mute and survives changes.
            if let sk = snoozed[key], sk != "*", sk != kind { snoozed.removeValue(forKey: key); snoozeChanged = true }
            let interval = remindInterval(for: kind)
            if interval <= 0 { continue }                          // reminders off for this kind
            if snoozed[key] != nil { continue }                    // snoozed -> stay quiet
            live.insert(key)
            let waited = epoch - s.lastActivity
            if waited < interval { continue }                      // hook owns the first ping
            if let last = lastReminded[key], now.timeIntervalSince(last) < interval { continue }
            let friendly = kindMessage[kind] ?? "needs your input"
            notify(title: "⏳ still waiting · \(s.project) · \(s.terminal)",
                   message: "\(friendly) — \(Int(waited / 60))m",
                   agent: s.agent, sid: s.sessionId)
            lastReminded[key] = now
        }
        lastReminded = lastReminded.filter { live.contains($0.key) }   // forget unblocked sessions
        // prune: kind-scoped snoozes drop once the session is unblocked (a fresh
        // block re-notifies); "*" mutes stick until their session is gone entirely.
        let allKeys = Set(sessions.map { sessionKey($0) })
        for (k, v) in snoozed where (v == "*" ? !allKeys.contains(k) : !blocked.contains(k)) {
            snoozed.removeValue(forKey: k); snoozeChanged = true
        }
        if snoozeChanged { saveSnoozed(snoozed) }
    }

    func notify(title: String, message: String, agent: String, sid: String) {
        // opt-in debug trail (off by default): set HARBAR_REMIND_LOG=1 to append every
        // fired reminder to ~/.harbar/remind-debug.log — makes the timing testable.
        if ProcessInfo.processInfo.environment["HARBAR_REMIND_LOG"] != nil {
            let line = "\(Int(Date().timeIntervalSince1970)) \(agent)-\(sid) :: \(title) — \(message)\n"
            let lp = (NSHomeDirectory() as NSString).appendingPathComponent(".harbar/remind-debug.log")
            if let d = line.data(using: .utf8) {
                if let fh = FileHandle(forWritingAtPath: lp) {
                    fh.seekToEndOfFile(); fh.write(d); try? fh.close()
                } else { FileManager.default.createFile(atPath: lp, contents: d) }
            }
        }
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
            addSection(menu, k, "\(kindEmoji[k] ?? "⏳") \(kindLabel[k] ?? k.uppercased())", byKind[k]!, snoozable: true)
        }
        if !needs.isEmpty {
            let hint = NSMenuItem(title: "   hold ⌥ to snooze a row · ⇧ to pin its project", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        addIf(menu, "working", "▸ WORKING", sessions.filter { $0.status == "working" })
        addIf(menu, "error", "⚠ ERROR", sessions.filter { $0.status == "error" })
        addIf(menu, "idle", "✓ IDLE", sessions.filter { $0.status == "idle" })
        addRecent(menu, loadRecent())

        menu.addItem(.separator())

        // Reminders ▸ one submenu per needs-input kind, each with the interval presets
        let reminders = NSMenuItem(title: "Reminders", action: nil, keyEquivalent: "")
        let rsub = NSMenu()
        for (key, emoji, _) in kinds {
            let cur = remindInterval(for: key)
            let name = remindKindName[key] ?? key
            let kindItem = NSMenuItem(title: "\(emoji) \(name): \(remindLabel(cur))", action: nil, keyEquivalent: "")
            let ksub = NSMenu()
            var matched = false
            for (label, secs) in remindPresets {
                let mi = NSMenuItem(title: label, action: #selector(setReminder(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = ["kind": key, "secs": secs] as [String: Any]
                if abs(secs - cur) < 0.5 { mi.state = .on; matched = true }
                ksub.addItem(mi)
            }
            if !matched {           // a custom value set via `defaults write`
                let mi = NSMenuItem(title: "custom: \(remindLabel(cur))", action: nil, keyEquivalent: "")
                mi.state = .on; mi.isEnabled = false
                ksub.addItem(mi)
            }
            kindItem.submenu = ksub
            rsub.addItem(kindItem)
        }
        reminders.submenu = rsub
        menu.addItem(reminders)

        triageIdx = 0      // opening the menu restarts the hotkey cycle from the top
        // nil action = auto-disabled by NSMenu when nothing is blocked
        let j = NSMenuItem(title: "Jump to longest-blocked   ⌃⌥J",
                           action: needs.isEmpty ? nil : #selector(triageNext), keyEquivalent: "")
        j.target = self
        menu.addItem(j)

        let r = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)
        let q = NSMenuItem(title: "Quit Harbar", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    func addIf(_ menu: NSMenu, _ key: String, _ header: String, _ rows: [Session]) {
        if !rows.isEmpty { addSection(menu, key, header, rows) }
    }

    // MARK: fold state — any group collapses on a header click, persisted per
    // section in UserDefaults ("fold.<key>"). pinned rows stay visible regardless.
    func isFolded(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: "fold.\(key)") }

    func toggleFold(_ key: String) {
        UserDefaults.standard.set(!isFolded(key), forKey: "fold.\(key)")
        if let menu = statusItem.menu { menuNeedsUpdate(menu) }   // refresh in place, menu stays open
    }

    // blocked rows sort longest-waiting first (the ago IS the blocked time — no
    // hook event fires while a session sits on a prompt) and wear a ⏳ so the
    // most neglected session is always the top row of its section. elsewhere,
    // pinned projects sort first (neglect order outranks pins on blocked rows).
    func sorted(_ rows: [Session], byWait: Bool) -> [Session] {
        if byWait { return rows.sorted { $0.lastActivity < $1.lastActivity } }
        let p = loadPinned()
        return rows.sorted {
            let a = p.contains($0.project), b = p.contains($1.project)
            if a != b { return a }
            return $0.displayName < $1.displayName
        }
    }

    func agoSuffix(_ s: Session, waiting: Bool) -> String {
        waiting ? "⏳ \(agoStr(s.lastActivity))" : agoStr(s.lastActivity)
    }

    func addSection(_ menu: NSMenu, _ key: String, _ header: String, _ rows: [Session], snoozable: Bool = false) {
        let folded = isFolded(key)
        let title = "\(folded ? "▶" : "▼") \(header) (\(rows.count))"
        let h = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        h.view = FoldHeaderView(key: key, title: title, controller: self)
        menu.addItem(h)
        // folded: pinned rows stay visible (that's what a pin is for)
        addRows(menu, folded ? rows.filter { isPinned($0) } : rows, snoozable: snoozable)
    }

    func rowMark(_ s: Session) -> String {
        // an active loop is marked 🔁 wherever the row sits — on a blocked row
        // it tells you approving resumes a loop, not a one-off.
        (isSnoozed(s) ? "😴 " : "") + (loopActive(s) ? "🔁 " : "") + (isPinned(s) ? "📌 " : "")
    }

    func rowTitle(_ s: Session, waiting: Bool) -> String {
        let detail = loopDetail(s) ? "  ·  \(loopStr(s))" : detailStr(s)
        return "  \(rowMark(s))\(tag[s.agent] ?? "?") \(s.displayName)"
             + "  ·  \(s.terminal)\(detail)  ·  \(agoSuffix(s, waiting: waiting))"
    }

    func addRows(_ menu: NSMenu, _ rows: [Session], snoozable: Bool) {
        for s in sorted(rows, byWait: snoozable) {
            // primary row: a single click always focuses the terminal.
            // two stacked alternates on every row: ⌥ snooze · ⇧ pin.
            let it = NSMenuItem(title: rowTitle(s, waiting: snoozable),
                                action: #selector(focus(_:)), keyEquivalent: "")
            it.target = self
            it.keyEquivalentModifierMask = []
            it.representedObject = [s.agent, s.sessionId]
            menu.addItem(it)
            let snoozed = isSnoozed(s)
            let snoozeTitle = snoozed
                ? "  🔔 \(s.displayName) — resume notifications"
                : (s.status == "needs_input"
                    ? "  😴 \(s.displayName) — snooze until it changes group"
                    : "  😴 \(s.displayName) — mute this session")
            for (title, sel, mask) in [
                (snoozeTitle, #selector(toggleSnooze(_:)), NSEvent.ModifierFlags.option),
                (isPinned(s) ? "  📌 \(s.displayName) — unpin \(s.project)"
                             : "  📌 \(s.displayName) — pin \(s.project) to top",
                 #selector(togglePin(_:)), NSEvent.ModifierFlags.shift),
            ] {
                let alt = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                alt.target = self
                alt.isAlternate = true
                alt.keyEquivalentModifierMask = mask
                alt.representedObject = [s.agent, s.sessionId]
                menu.addItem(alt)
            }
        }
    }


    // ended sessions, click to resume the conversation in a fresh terminal tab
    func addRecent(_ menu: NSMenu, _ rows: [Session]) {
        guard !rows.isEmpty else { return }
        let folded = isFolded("recent")
        let title = "\(folded ? "▶" : "▼") ↻ RECENT (\(rows.count))"
        let h = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        h.view = FoldHeaderView(key: "recent", title: title, controller: self)
        menu.addItem(h)
        if folded { return }
        for s in rows {
            let it = NSMenuItem(
                title: "  \(tag[s.agent] ?? "?") \(s.displayName)  ·  ended \(agoStr(s.lastActivity)) ago — click to resume",
                action: #selector(resumeSession(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = [s.agent, s.sessionId, s.cwd]
            menu.addItem(it)
        }
    }

    @objc func resumeSession(_ sender: NSMenuItem) {
        guard let arr = sender.representedObject as? [String], arr.count == 3 else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [resumeScript, arr[0], arr[1], arr[2]]
        try? p.run()
    }

    @objc func focus(_ sender: NSMenuItem) {
        guard let arr = sender.representedObject as? [String], arr.count == 2 else { return }
        runFocus(arr[0], arr[1])
    }

    @objc func togglePin(_ sender: NSMenuItem) {
        guard let arr = sender.representedObject as? [String], arr.count == 2,
              let s = loadSessions().first(where: { $0.agent == arr[0] && $0.sessionId == arr[1] })
        else { return }
        var p = loadPinned()
        if p.contains(s.project) { p.remove(s.project) } else { p.insert(s.project) }
        savePinned(p)
    }

    @objc func toggleSnooze(_ sender: NSMenuItem) {
        guard let arr = sender.representedObject as? [String], arr.count == 2,
              let s = loadSessions().first(where: { $0.agent == arr[0] && $0.sessionId == arr[1] })
        else { return }
        let key = sessionKey(s)
        var snoozed = loadSnoozed()
        if snoozed[key] != nil {
            snoozed.removeValue(forKey: key)              // resume (either flavor)
        } else {
            // blocked row: kind-scoped (auto-clears on group change);
            // anything else: "*" = fully muted until manually resumed
            snoozed[key] = s.status == "needs_input" ? kindOf(s) : "*"
            lastReminded.removeValue(forKey: key)
        }
        saveSnoozed(snoozed)
    }

    @objc func setReminder(_ sender: NSMenuItem) {
        guard let o = sender.representedObject as? [String: Any],
              let kind = o["kind"] as? String, let secs = o["secs"] as? Double else { return }
        UserDefaults.standard.set(secs, forKey: "remind.\(kind)")
        lastReminded.removeAll()      // restart the cadence from the new setting
    }

    func remindLabel(_ s: Double) -> String {
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
        func sect(_ key: String, _ header: String, _ rows: [Session], waiting: Bool = false) {
            let folded = isFolded(key)
            print("\(folded ? "▶" : "▼") \(header) (\(rows.count))")
            for s in sorted(folded ? rows.filter { isPinned($0) } : rows, byWait: waiting) {
                print(rowTitle(s, waiting: waiting))
            }
        }
        if sessions.isEmpty { print("no sessions") }
        for k in orderedNeedsKinds(byKind) { sect(k, "\(kindEmoji[k] ?? "⏳") \(kindLabel[k] ?? k.uppercased())", byKind[k]!, waiting: true) }
        let working = sessions.filter { $0.status == "working" }
        let errored = sessions.filter { $0.status == "error" }
        let idle = sessions.filter { $0.status == "idle" }
        if !working.isEmpty { sect("working", "▸ WORKING", working) }
        if !errored.isEmpty { sect("error", "⚠ ERROR", errored) }
        if !idle.isEmpty { sect("idle", "✓ IDLE", idle) }
        let recent = loadRecent()
        if !recent.isEmpty {
            print("↻ RECENT (\(recent.count))")
            for s in recent {
                print("  \(tag[s.agent] ?? "?") \(s.displayName)  ·  ended \(agoStr(s.lastActivity)) ago")
            }
        }
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
