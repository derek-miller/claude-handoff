import Foundation

// One Desktop restart attempt: when it started, the Desktop process and held sessions it covers, and how it ended
// (closing, quit-timeout, quit-not-confirmed, quit-failed, moving, move-failed, reopening, reopened, reopen-failed).
// Saved in the receipt as `restart` and handed to the work it wraps.
@dynamicMemberLookup
struct RestartAttempt {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var at: Value {
        get { raw["at"] }
        nonmutating set { raw["at"] = newValue }
    }
    var attemptId: Value {
        get { raw["attemptId"] }
        nonmutating set { raw["attemptId"] = newValue }
    }
    var requestedAt: Value {
        get { raw["requestedAt"] }
        nonmutating set { raw["requestedAt"] = newValue }
    }
    var app: Value {
        get { raw["app"] }
        nonmutating set { raw["app"] = newValue }
    }
    var desktop: Value {
        get { raw["desktop"] }
        nonmutating set { raw["desktop"] = newValue }
    }
    var held: Value {
        get { raw["held"] }
        nonmutating set { raw["held"] = newValue }
    }
    var outcome: Value {
        get { raw["outcome"] }
        nonmutating set { raw["outcome"] = newValue }
    }
    var error: Value {
        get { raw["error"] }
        nonmutating set { raw["error"] = newValue }
    }
    var exitedAt: Value {
        get { raw["exitedAt"] }
        nonmutating set { raw["exitedAt"] = newValue }
    }
    var outcomeBeforeReopen: Value {
        get { raw["outcomeBeforeReopen"] }
        nonmutating set { raw["outcomeBeforeReopen"] = newValue }
    }
    var reopenedAt: Value {
        get { raw["reopenedAt"] }
        nonmutating set { raw["reopenedAt"] = newValue }
    }

    @available(*, unavailable, message: "declare the field on RestartAttempt")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}

// A restart plan (restart-plan.json): the Desktop process, the workers and held sessions it would close, and the
// move or Undo it was approved for.
@dynamicMemberLookup
struct RestartPlan {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var affected: Value {
        get { raw["affected"] }
        nonmutating set { raw["affected"] = newValue }
    }
    var app: Value {
        get { raw["app"] }
        nonmutating set { raw["app"] = newValue }
    }
    var desktop: Value {
        get { raw["desktop"] }
        nonmutating set { raw["desktop"] = newValue }
    }
    var fingerprint: Value {
        get { raw["fingerprint"] }
        nonmutating set { raw["fingerprint"] = newValue }
    }
    var held: Value {
        get { raw["held"] }
        nonmutating set { raw["held"] = newValue }
    }
    var kind: Value {
        get { raw["kind"] }
        nonmutating set { raw["kind"] = newValue }
    }
    var members: Value {
        get { raw["members"] }
        nonmutating set { raw["members"] = newValue }
    }
    var nonce: Value {
        get { raw["nonce"] }
        nonmutating set { raw["nonce"] = newValue }
    }
    var receiptFile: Value {
        get { raw["receiptFile"] }
        nonmutating set { raw["receiptFile"] = newValue }
    }
    var resume: Value {
        get { raw["resume"] }
        nonmutating set { raw["resume"] = newValue }
    }
    var selection: Value {
        get { raw["selection"] }
        nonmutating set { raw["selection"] = newValue }
    }

    @available(*, unavailable, message: "declare the field on RestartPlan")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}
