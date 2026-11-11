import Foundation
import Testing
@testable import HandoffCore

extension Engine {
    @Suite("cloud")
    struct Cloud {
        // A callback argument the engine may not pass.
        static func arg(_ args: [Value], _ i: Int) -> Value { i < args.count ? args[i] : .undefined }

        // accounts() rows keyed by account uuid; the last row for an account wins.
        static func byAccount(_ all: Value) -> Value {
            let out = Value.newObject()
            for row in all.elements { out[row.account.str] = row }
            return out
        }

        // A JSON response body in the chunked form the memory budget reads.
        static func json(_ value: Value) -> Value { ["body": [Value(Data(JSON.text(value).utf8))]] }

        // A /bin/ps line for the identity fixture's Desktop: lstart is "Fri Sep 04 18:00:00 2026".
        static func desktopListing(_ identity: IdentityFixture) -> String {
            let lstart = re(#"^(\w+ \w+ \d+) (\d+) ([\d:]+).*$"#).replace(dateString(identity.started), "$1 $3 $2")
            return "500 1 \(lstart) /Applications/Claude.app/Contents/MacOS/Claude\n"
        }

        @Test("same-login cleanup addresses the recorded source organization in either direction without switching Desktop")
        func sameLoginCleanup() throws {
            for (sourceOrg, activeOrg) in [("P", "T"), ("T", "P")] {
                let f = try pendingOrganizations(orgs: [sourceOrg], to: activeOrg), h = f.h, identity = f.identity, row = f.rows[0]
                try identity.write(identity.`init`(1, h.acct.P, h.org[activeOrg]))
                let desktop = try readData(h.paths.desktop.str), logs = try readData(path.join(h.paths.logs.str, "main.log"))
                var requests: [(endpoint: String, method: String, org: Value)] = []
                mockFetch { url, options in
                    let endpoint = url.path
                    requests.append((endpoint, options.method.nullish ? "GET" : options.method.str, options.headers["x-organization-uuid"]))
                    if endpoint == "/api/account" { return response(["uuid": Value(h.acct.P)]) }
                    if endpoint == "/api/organizations" { return response([["uuid": Value(h.org.P)], ["uuid": Value(h.org.T)]]) }
                    eq(options.headers["x-organization-uuid"], Value(row.org))
                    let headers: Value = ["anthropic-organization-id": Value(row.org)]
                    if endpoint == "/v1/code/sessions" {
                        return response(["data": [remoteSession(["id": Value(row.remote), "title": "Organization 0", "status": Value(row.status)]), remoteSession(["id": "cse_unselected"])]], headers: headers)
                    }
                    ok(endpoint.hasPrefix("/v1/code/sessions/session_org0"))
                    if endpoint.hasSuffix("/events") { return response(["data": remoteRows(row.entries)], headers: headers) }
                    if options.method == "POST" {
                        ok(endpoint.hasSuffix("/archive") || endpoint.hasSuffix("/unarchive"))
                        row.status = endpoint.hasSuffix("/unarchive") ? "active" : "archived"
                    }
                    return response(remoteState(row.status), headers: headers)
                }
                let cloud = fn { args in
                    deq(args[0], ["account": Value(h.acct.P), "org": Value(row.org), "label": f.from[0].label])
                    return try cloudClient(h.paths, args[0], [
                        "active": try signedIn(h.paths, identity.processes),
                        "cookies": .newMap([(Value("sessionKey"), Value("fixture")), (Value("lastActiveOrg"), Value(h.org[activeOrg]))]),
                        "userAgent": "fixture",
                    ])
                }
                let listing = Cloud.desktopListing(identity)
                let shown = cli(h.root, ["accounts", "--json"]) { processSetup(list: listing, commands: listing) }
                eq(shown.code, 0, shown.stderr)
                let pending = try JSON.parse(shown.stdout).find { $0.account.str == h.acct.P && $0.org.str == row.org }
                eq(pending.signedIn, true)
                eq(pending.active, false)
                eq(pending.pendingAction, "wait")
                let finished = try sweep(h.paths, ["cloud": cloud, "processes": identity.processes])
                eq(finished.result.file, f.moved.file)
                eq(finished.result.complete, true)
                eq(row.status, "archived")
                ok(try undo(h.paths, ["cloud": cloud, "processes": identity.processes]).dest)
                eq(row.status, "active")
                #expect(requests.filter { $0.method == "POST" }.map { $0.endpoint.components(separatedBy: "/").last! } == ["archive", "unarchive"])
                #expect(try readData(h.paths.desktop.str) == desktop)
                #expect(try readData(path.join(h.paths.logs.str, "main.log")) == logs)
                deq(try fixtureSnapshot(h, [h.paths.records.str, h.paths.pool.str]), f.before)
            }
        }
    }
}
