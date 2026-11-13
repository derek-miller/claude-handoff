import Foundation

// Views over what the move, finish, sweep and Undo workflows take and pass between their steps.

// The options a workflow is called with. Workflows pass them on to the steps they run, so the object itself
// travels unchanged.
struct WorkflowOptions {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    // The token of the saved restart plan the user approved.
    var approve: Value { raw["approve"] }
    var background: Value { raw["background"] }
    var moveOnly: Value { raw["moveOnly"] }
    var recover: Value { raw["recover"] }
    var undo: Value { raw["undo"] }
    var finish: Value { raw["finish"] }
    var finishAccount: Value { raw["finishAccount"] }
    var resume: Value { raw["resume"] }
    var resumeFile: Value { raw["resumeFile"] }
    var receiptFile: Value { raw["receiptFile"] }
    var requestedAt: Value { raw["requestedAt"] }
    var cloud: Value { raw["cloud"] }
    var cloudRequested: Value { raw["cloudRequested"] }
    var cloudError: Value { raw["cloudError"] }
    var active: Value { raw["active"] }
    var check: Value { raw["check"] }
    var processes: Value { raw["processes"] }
    var io: RestartIO { RestartIO(raw["io"]) }
    var report: Value { raw["report"] }
    var summary: Value { raw["summary"] }
}

extension RestartApproval {
    var fingerprint: Value { raw["fingerprint"] }
    var requestedAt: Value { raw["requestedAt"] }
    var finishAccount: Value { raw["finishAccount"] }
    var deferredCloudSources: Value { raw["deferredCloudSources"] }
}

// A fresh inventory of the chosen accounts, and the destination account it was planned against.
struct Replan {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var inv: MovePlan { MovePlan(raw["inv"]) }
    var target: Value { raw["target"] }
}

// What withDesktopRestart() returns: the work's result and how the restart around it went.
struct RestartedWork {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var ok: Value { raw["ok"] }
    var code: Value { raw["code"] }
    var error: Value { raw["error"] }
    var result: WorkflowResult { WorkflowResult(raw["result"]) }
    var restart: RestartAttempt { RestartAttempt(raw["restart"]) }
}

extension SessionRow {
    var file: Value { raw["file"] }
}

extension WorkflowResult {
    var checkedAccount: Value { raw["checkedAccount"] }
    var pending: Value { raw["pending"] }
    var restartNeeded: Value { raw["restartNeeded"] }
}

extension RecoveryNote {
    var isPresent: Bool { raw.truthy }
    var undo: Value { raw["undo"] }
    var pendingUndo: Value { raw["pendingUndo"] }
    var remoteRestored: Value { raw["remoteRestored"] }
    var receipt: Value { raw["receipt"] }
}

extension ProgressExtra {
    var preparatory: Value { raw["preparatory"] }
    var activity: Value { raw["activity"] }
    var sessionTotal: Value { raw["sessionTotal"] }
    var remainingCount: Value { raw["remainingCount"] }
}

// The account picker: the highlighted row, the rows chosen so far, and whether the choice is made.
struct PickerState {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var cursor: Value { raw["cursor"] }
    var chosen: Value { raw["chosen"] }
    var size: Value { raw["size"] }
    var multi: Value { raw["multi"] }
    var done: Value { raw["done"] }
}
