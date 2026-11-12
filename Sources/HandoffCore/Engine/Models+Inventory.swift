// The options inventory and the cloud inventory read.
@dynamicMemberLookup
struct InventoryOptions {
    let raw: Value
    init(_ raw: Value) { self.raw = raw }
    var artifactLimit: Value { raw["artifactLimit"] }
    var automatic: Value { raw["automatic"] }
    var budgetRetry: Value { raw["budgetRetry"] }
    var check: Value { raw["check"] }
    var cloud: Value { raw["cloud"] }
    var cloudBridgeIds: Value { raw["cloudBridgeIds"] }
    var cloudCutoff: Value { raw["cloudCutoff"] }
    var cloudError: Value { raw["cloudError"] }
    var cloudExcludedIds: Value { raw["cloudExcludedIds"] }
    var cloudRequested: Value { raw["cloudRequested"] }
    var cloudSessionIds: Value { raw["cloudSessionIds"] }
    var cloudTargetOnly: Value { raw["cloudTargetOnly"] }
    var inspect: Value { raw["inspect"] }
    var processes: Value { raw["processes"] }
    var requestedAt: Value { raw["requestedAt"] }
    var serial: Value { raw["serial"] }
    var writeCache: Value { raw["writeCache"] }

    @available(*, unavailable, message: "declare the field on InventoryOptions")
    subscript(dynamicMember name: String) -> Value { raw[name] }
}
