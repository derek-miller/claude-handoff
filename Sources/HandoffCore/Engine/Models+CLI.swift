import Foundation

// Views over the objects the CLI parses and the results it prints. The results go out as JSON exactly as the
// workflows built them, so most fields are values passed through unchanged.

// The parsed command line.
@dynamicMemberLookup
struct CLIArgs {
    let raw: Value
    init() {
        raw = ["pair": .null, "from": [], "to": .null, "cmd": .null, "dry": false, "cloud": false, "json": false, "help": false, "version": false,
               "remove": false, "snapshot": .null, "restartApproved": .null, "moveOnly": false, "leaveChecks": []]
    }
    var pair: Value { get { raw["pair"] } nonmutating set { raw["pair"] = newValue } }
    var from: Value { raw["from"] }
    var to: Value { get { raw["to"] } nonmutating set { raw["to"] = newValue } }
    var cmd: Value { get { raw["cmd"] } nonmutating set { raw["cmd"] = newValue } }
    var dry: Value { get { raw["dry"] } nonmutating set { raw["dry"] = newValue } }
    var cloud: Value { get { raw["cloud"] } nonmutating set { raw["cloud"] = newValue } }
    var json: Value { get { raw["json"] } nonmutating set { raw["json"] = newValue } }
    var help: Value { get { raw["help"] } nonmutating set { raw["help"] = newValue } }
    var version: Value { get { raw["version"] } nonmutating set { raw["version"] = newValue } }
    var remove: Value { get { raw["remove"] } nonmutating set { raw["remove"] = newValue } }
    var snapshot: Value { get { raw["snapshot"] } nonmutating set { raw["snapshot"] = newValue } }
    var restartApproved: Value { get { raw["restartApproved"] } nonmutating set { raw["restartApproved"] = newValue } }
    var moveOnly: Value { get { raw["moveOnly"] } nonmutating set { raw["moveOnly"] = newValue } }
    var leaveChecks: Value { raw["leaveChecks"] }

    @available(*, unavailable, message: "declare the field on CLIArgs")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A restart that needs approval: what it will close and the token that approves it.
@dynamicMemberLookup
struct RestartApproval {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var kind: Value { raw["kind"] }
    var token: Value { raw["token"] }
    var resume: Value { raw["resume"] }
    var receiptFile: Value { raw["receiptFile"] }
    var remainingCount: Value { raw["remainingCount"] }
    var held: Value { raw["held"] }
    var affected: [SessionRow] { raw["affected"].elements.map(SessionRow.init) }
    // The accounts the approved move reads from and writes to, when it is a new move.
    var selection: Value { raw["selection"] }

    @available(*, unavailable, message: "declare the field on RestartApproval")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// The accounts a new move was asked to read from and write to.
@dynamicMemberLookup
struct MoveSelection {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var from: Value { raw["from"] }
    var to: AccountRef { AccountRef(raw["to"]) }

    @available(*, unavailable, message: "declare the field on MoveSelection")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// An account and org with its label, as accountRef() writes it into selections and receipts.
@dynamicMemberLookup
struct AccountRef: AccountKey {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var label: Value { raw["label"] }
    // The record files a selection reads, when the account is a move source.
    var files: Value { raw["files"] }

    @available(*, unavailable, message: "declare the field on AccountRef")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// What a move, finish, undo or restart workflow returned.
@dynamicMemberLookup
struct WorkflowResult {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var ok: Value { raw["ok"] }
    var complete: Value { raw["complete"] }
    var nothing: Value { raw["nothing"] }
    var code: Value { raw["code"] }
    var reason: Value { raw["reason"] }
    var file: Value { raw["file"] }
    var receipt: Value { raw["receipt"] }
    var summary: Value { raw["summary"] }
    var plan: Value { raw["plan"] }
    var deferred: Value { raw["deferred"] }
    var recoveryRequired: Value { raw["recoveryRequired"] }
    var reconciled: Value { raw["reconciled"] }
    var restart: Value { raw["restart"] }
    var restarted: Value { raw["restarted"] }
    var restartOutcome: Value { raw["restartOutcome"] }
    var targetChanged: Value { raw["targetChanged"] }
    var checks: Value { raw["checks"] }
    var problems: Value { raw["problems"] }
    var failed: Value { raw["failed"] }
    var notMoved: Value { raw["notMoved"] }
    var held: Value { raw["held"] }
    var added: Value { raw["added"] }
    var pendingLocal: Value { raw["pendingLocal"] }
    var pendingCloud: Value { raw["pendingCloud"] }
    var pendingLabels: Value { raw["pendingLabels"] }
    var pendingUndo: Value { raw["pendingUndo"] }
    var newerCloud: Value { raw["newerCloud"] }
    var cloudArchived: Value { raw["cloudArchived"] }
    var cloudChecked: Value { raw["cloudChecked"] }
    var remoteRestored: Value { raw["remoteRestored"] }
    var restoreProblems: Value { raw["restoreProblems"] }
    var changed: Value { raw["changed"] }
    var retained: Value { raw["retained"] }
    // The quarantine folder an undo moved the destination records to.
    var dest: Value { raw["dest"] }

    @available(*, unavailable, message: "declare the field on WorkflowResult")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// What sweep found: the workflow it finished, and the verification of the last move.
@dynamicMemberLookup
struct SweepResult {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var ok: Value { raw["ok"] }
    var complete: Value { raw["complete"] }
    var code: Value { raw["code"] }
    var error: Value { raw["error"] }
    var recovered: Value { raw["recovered"] }
    var refreshRequired: Value { raw["refreshRequired"] }
    var result: WorkflowResult { WorkflowResult(raw["result"]) }
    var verification: Verification { Verification(raw["verification"]) }

    @available(*, unavailable, message: "declare the field on SweepResult")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A check of the last move's destination records.
@dynamicMemberLookup
struct Verification {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var error: Value { raw["error"] }
    var receipt: Value { raw["receipt"] }
    var summary: Value { raw["summary"] }
    var changed: Value { raw["changed"] }
    var failed: Value { raw["failed"] }
    var notMoved: Value { raw["notMoved"] }
    var problems: Value { raw["problems"] }

    @available(*, unavailable, message: "declare the field on Verification")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// What keep-local did with the pending cloud checks and held sessions.
@dynamicMemberLookup
struct KeepLocalResult {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var ok: Value { raw["ok"] }
    var complete: Value { raw["complete"] }
    var nothing: Value { raw["nothing"] }
    var code: Value { raw["code"] }
    var reason: Value { raw["reason"] }
    var refused: Value { raw["refused"] }
    var recoveryRequired: Value { raw["recoveryRequired"] }
    var cancelled: Value { raw["cancelled"] }
    var heldCancelled: Value { raw["heldCancelled"] }
    var labels: Value { raw["labels"] }
    var summary: Value { raw["summary"] }
    var failed: Value { raw["failed"] }
    var notMoved: Value { raw["notMoved"] }
    var receipt: Receipt { Receipt(raw["receipt"]) }

    @available(*, unavailable, message: "declare the field on KeepLocalResult")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A folder tidy set aside, and the scratch folder it kept because a session still works there.
@dynamicMemberLookup
struct TidiedFolder {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var scratchKept: Value { raw["scratchKept"] }

    @available(*, unavailable, message: "declare the field on TidiedFolder")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// The folders tidy set aside.
@dynamicMemberLookup
struct TidyResult {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var moved: Value { raw["moved"] }
    var dest: Value { raw["dest"] }

    @available(*, unavailable, message: "declare the field on TidyResult")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// The newest receipt, or why it could not be read.
@dynamicMemberLookup
struct LatestReceipt {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var file: Value { raw["file"] }
    var corrupt: Value { raw["corrupt"] }
    var receipt: Receipt { Receipt(raw["receipt"]) }

    @available(*, unavailable, message: "declare the field on LatestReceipt")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A receipt whose move did not finish, which the next move reconciles first.
@dynamicMemberLookup
struct PendingRecovery {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var name: Value { raw["name"] }
    var corrupt: Value { raw["corrupt"] }
    var receipt: Receipt { Receipt(raw["receipt"]) }

    @available(*, unavailable, message: "declare the field on PendingRecovery")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A move that is waiting on cloud checks, held sessions or an undo before another can start.
@dynamicMemberLookup
struct DeferredWorkflow {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    // cloud, local or undo.
    var mode: Value { raw["mode"] }
    var sources: [PendingSource] { raw["sources"].elements.map(PendingSource.init) }
    var receipt: Receipt { Receipt(raw["receipt"]) }

    @available(*, unavailable, message: "declare the field on DeferredWorkflow")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A source account a deferred workflow is still waiting on.
@dynamicMemberLookup
struct PendingSource: AccountKey {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var label: Value { raw["label"] }
    var waiting: Value { raw["waiting"] }
    var failures: Value { raw["failures"] }

    @available(*, unavailable, message: "declare the field on PendingSource")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A session named in a result: failed, not moved, retained, reconciled or in a receipt.
@dynamicMemberLookup
struct SessionRow {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var id: Value { raw["id"] }
    var title: Value { raw["title"] }
    var error: Value { raw["error"] }
    var targetId: Value { raw["targetId"] }
    var bridgeAppend: Value { raw["bridgeAppend"] }

    @available(*, unavailable, message: "declare the field on SessionRow")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A destination check that failed after a move.
@dynamicMemberLookup
struct ProblemRow {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var id: Value { raw["id"] }
    var title: Value { raw["title"] }
    var check: Value { raw["check"] }

    @available(*, unavailable, message: "declare the field on ProblemRow")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A session held in its source account until its worker or scheduler lets go.
@dynamicMemberLookup
struct HeldRow {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    // worker, scheduler or unknown.
    var release: Value { raw["release"] }
    var sources: [AccountPair] { raw["sources"].elements.map(AccountPair.init) }

    @available(*, unavailable, message: "declare the field on HeldRow")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A receipt's cloud check for one source account.
@dynamicMemberLookup
struct CloudCheck: AccountKey {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var status: Value {
        get { raw["status"] }
        nonmutating set { raw["status"] = newValue }
    }
    var waiting: Value { raw["waiting"] }
    var checkedAt: Value { raw["checkedAt"] }

    @available(*, unavailable, message: "declare the field on CloudCheck")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// What cloudInventory planned for Remote Control sessions.
@dynamicMemberLookup
struct CloudPlan {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var matches: Value { raw["matches"] }
    var blocked: Value { raw["blocked"] }
    var waiting: Value { raw["waiting"] }
    var later: Value { raw["later"] }

    @available(*, unavailable, message: "declare the field on CloudPlan")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// An unreadable or rejected record in a plan, from the source or the destination.
@dynamicMemberLookup
struct PlanIssue {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isTarget: Bool { raw["target"].truthy }

    @available(*, unavailable, message: "declare the field on PlanIssue")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A source session and the destination record that will own it once the move verifies.
@dynamicMemberLookup
struct OwnedSource {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var source: Value { raw["s"] }
    var owner: Value { raw["owner"] }

    @available(*, unavailable, message: "declare the field on OwnedSource")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// The counts receiptSummary() reports for a receipt.
@dynamicMemberLookup
struct ReceiptSummary {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var isPresent: Bool { raw.truthy }
    var moved: Value { raw["moved"] }

    @available(*, unavailable, message: "declare the field on ReceiptSummary")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A thrown engine error as errorObject() normalizes it.
@dynamicMemberLookup
struct ThrownError {
    let raw: Value
    init(_ error: Error) { raw = errorObject(error) }
    var code: Value { raw["code"] }
    var file: Value { raw["file"] }
    var message: Value { raw["message"] }

    @available(*, unavailable, message: "declare the field on ThrownError")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

extension MovePlan {
    var total: Value { raw["total"] }
    var missing: Value { raw["missing"] }
    var twice: Value { raw["twice"] }
    var apart: Value { raw["apart"] }
    var pendingCloud: Value { raw["pendingCloud"] }
    var cloudPlan: CloudPlan { CloudPlan(raw["cloud"]) }
}

extension Account {
    var email: Value { raw["email"] }
    var signedIn: Value { raw["signedIn"] }
    var identityState: Value { raw["identityState"] }
}

extension Receipt {
    var localRecoveryBlocked: Value { localRecovery["blocked"] }
}
