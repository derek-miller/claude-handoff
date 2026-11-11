import AppKit

struct WordingFixture: Decodable {
    let name: String
    let accounts: [Account]
    let operation: [String]
    let event: String?
    let plan: Event?
    let dialog: Bool?
    let cancel: Bool?
    let expanded: Bool?
    let background: Bool?
    let suppressed: Bool?
    let contains: [String]
    let primary: String?
    let screen: String?
    let keep: Bool?
}
enum WordingChecks {
    @MainActor static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let fixtures = try JSONDecoder().decode([WordingFixture].self, from: Data(contentsOf: root.appendingPathComponent("fixtures.json")))
        var manifest: [[String: Any]] = []
        for fixture in fixtures {
            requests = []
            restartDialogs = []
            let model = Model(demo: fixture.accounts)
            if model.pendingAccounts.isEmpty, let target = fixture.operation.firstIndex(of: "--to"), target + 1 < fixture.operation.count {
                model.selectTarget(fixture.operation[target + 1].replacingOccurrences(of: " ", with: "/"))
                let selected = Set(fixture.operation.indices.filter { fixture.operation[$0] == "--from" && $0 + 1 < fixture.operation.count }.map { fixture.operation[$0 + 1].replacingOccurrences(of: " ", with: "/") })
                for id in model.from.subtracting(selected) { model.toggle(id) }
            }
            model.checkOperation(fixture.operation)
            var text: String
            var primary: String?
            var png: Data?
            if fixture.dialog == true {
                let prompt = RestartPrompt(plan: fixture.plan!)
                text = prompt.title + "\n" + prompt.body
                primary = prompt.confirm
                let alert = prompt.alert()
                precondition(alert.buttons[0].isEnabled && alert.showsSuppressionButton)
                precondition(alert.buttons.map(\.title) == ["Restart and move", "Move the others only", "Cancel"])
                precondition(alert.suppressionButton?.title == "Don't ask again")
                png = Snapshot.dialogData(fixture.plan!)
            } else {
                if fixture.cancel == true { model.checkCancel(fixture.plan!) }
                if let line = fixture.event {
                    let event = try JSONDecoder().decode(Event.self, from: Data(line.utf8))
                    if event.swept == true || fixture.background == true {
                        model.checkSweep()
                        requests.last!.1(line)
                        if event.swept == true { requests.last!.2(event.ok == false ? 1 : 0, "") }
                    } else {
                        model.begin()
                        model.handle(line)
                        if event.live != true { model.checkFinish(event.ok == false ? 1 : 0) }
                    }
                }
                model.detailsExpanded = fixture.expanded == true
                text = ([model.visibleCompletion?.summary, model.visibleCompletion?.detail, model.statusHeadline, model.statusDetail].compactMap { $0 } + model.detailLines.map(\.1)).joined(separator: "\n")
                if model.running { precondition(model.statusHeadline == model.moveProgress.detail && model.statusDetail == nil, fixture.name + ": " + text) }
                if let screen = fixture.screen { precondition(model.screen?.rawValue == screen, fixture.name + ": " + (model.screen?.rawValue ?? "none")) }
                if ["44-login-retry", "45-memory-retry", "46-history-limit"].contains(fixture.name) {
                    precondition(model.statusHeadline == "361 sessions moved")
                    precondition(model.statusDetail != nil && !model.statusDetail!.contains("361 moved"))
                }
                primary = model.primaryTitle
                if fixture.keep == true { precondition(model.canKeepLocal, fixture.name) }
                for account in model.accounts {
                    let from = Row(account: account, radio: false, selected: false, muted: false, tag: model.sourceTag(account), action: {})
                    let to = Row(account: account, radio: true, selected: false, muted: false, tag: model.sourceTag(account), action: {})
                    precondition(to.tagLabels == (account.active == true ? ["active"] : []))
                    precondition(from.tagLabels.contains("active") == (account.active == true))
                }
                if fixture.name == "01-done" { precondition(model.visibleCompletion?.detail == "History verified") }
                if fixture.name == "11-repair" { precondition(model.detailLines.map(\.0) == ["receipt"]) }
                if fixture.name == "05-other-login" {
                    precondition(model.statusHeadline == "361 sessions moved" && model.statusDetail?.contains("Sign Claude in as home@example.test") == true)
                    precondition(!model.directActions && model.links.map(\.title) == ["Undo last move", "Keep moved sessions"] && !model.undoPending)
                }
                if fixture.name == "08-unproven" { precondition(model.detailLines.filter { $0.1.contains("Research conversation") }.count == 1 && !model.directActions && model.canMutate) }
                if fixture.name == "50-limit-and-sign-in" { precondition(model.primaryTitle == nil && !model.directActions && model.links.map(\.title) == ["Undo last move", "Keep moved sessions"] && !model.undoPending) }
                if fixture.name == "46-history-limit" { precondition(model.directActions && model.canKeepLocal && !model.undoPending && model.links.isEmpty) }
                if fixture.name == "51-recorded-result" { precondition(model.links.map(\.title) == ["Undo last move"]) }
                if fixture.name == "52-waiting-for-claude" { precondition(!text.contains("Sign Claude in") && model.sourceTag(model.pendingAccounts[0]) == "waiting" && !model.movable && model.identityLabel == "waiting for Claude") }
                if fixture.name == "53-other-login-and-unfinished-local" { precondition(!model.movable && model.links.map(\.title) == ["Undo last move", "Keep moved sessions"]) }
                if fixture.name == "12-undo-pending" || fixture.name == "26-undo-ready" {
                    precondition(model.undoPending && !text.contains("361 moved"))
                    let count = requests.count
                    model.undo()
                    precondition(requests.count == count)
                }
                if fixture.name == "09-open-chats" || fixture.name == "27-timed-open-chats" { precondition(model.sourceTag(model.pendingAccounts[0]) == "waiting") }
                if fixture.name == "49-local-partial" { precondition(model.sourceTag(model.pendingAccounts[0]) == "not moved") }
                if fixture.name == "06-clearing" {
                    precondition(model.to == "work/company" && model.from == ["work/personal"])
                }
                if fixture.name == "30-check-dismissed" { precondition(model.visibleCompletion == nil) }
                if fixture.name == "31-mixed-unreadable-and-waiting" { precondition(model.scopedChecks.isEmpty) }
                if ["04-same-login", "05-other-login", "12-undo-pending", "34-same-login-undo", "35-local-undo-recovery", "38-same-login-uncertain"].contains(fixture.name) {
                    precondition(!text.contains("Switch Claude") && !text.contains("select Personal"))
                }
                if fixture.background == true {
                    precondition(!model.running && model.badge.isEmpty && !model.moveProgress.hasProgress && model.canMutate)
                    precondition(model.sourceTag(model.accounts[0]) == "waiting")
                    precondition(model.sourceTag(model.accounts[1]) == (fixture.name == "32-one-source-clearing" ? "clearing" : "waiting"))
                }
                if fixture.name == "46-history-limit" {
                    let tokens = model.scopedChecks
                    precondition(!tokens.isEmpty)
                    model.stopHere()
                    precondition(requests.last!.0 == ["keep-local", "--json"] + tokens.flatMap { ["--leave-check", $0] })
                    model.running = false
                    model.note = ""
                    model.detailsExpanded = fixture.expanded == true
                }
                png = Snapshot.data(model)
            }
            precondition(primary == fixture.primary, fixture.name + ": " + (primary ?? "none"))
            for fragment in fixture.contains { precondition(text.contains(fragment), fixture.name + ": " + text) }
            precondition((!text.contains("15 idle minutes") || fixture.name == "27-timed-open-chats") && !text.contains("Nothing was lost"))
            let output = root.appendingPathComponent(fixture.name + ".png")
            guard let png, let bitmap = NSBitmapImageRep(data: png), bitmap.pixelsWide > 200, bitmap.pixelsHigh > 100 else { fatalError("No production snapshot for " + fixture.name) }
            try png.write(to: output)
            manifest.append(["name": fixture.name, "path": output.path, "text": text, "primary": primary ?? NSNull(), "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh])
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("manifest.json"))
        print("Rendered \(fixtures.count) production wording states at \(root.path)")
    }
}
