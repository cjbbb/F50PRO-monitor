import Foundation
import XCTest
@testable import F50Core

private struct RouterReply {
    var status = 200
    var headers: [String: String] = [:]
    var payload: [String: Any] = [:]
    var delay: TimeInterval = 0
    var error: URLError? = nil
}

private final class RouterFixture {
    let lock = NSLock()
    var mode = "WL_AND_5G"
    var rejectLogin = false
    var rejectStatus = false
    var requireStatusLogin = false
    var delayLockReply = false
    var dropModeWriteResponse = false
    var ignoreModeWrite = false
    var rejectModeWrite = false
    var expireNextModeWriteSession = false
    var delayNextStatusReply: TimeInterval = 0
    var bandReplyDelay: TimeInterval = 0
    var statusExtras: [String: Any] = [:]
    var bandExtras: [String: Any] = [:]
    private var statusReads = 0
    private var bandReads = 0
    private var modeReads = 0
    private var forms: [[String: String]] = []
    private var lockReads = 0

    var postedForms: [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return forms
    }
    var lockReadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return lockReads
    }

    var statusReadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return statusReads
    }
    var bandReadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return bandReads
    }
    var modeReadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return modeReads
    }

    func reply(to request: URLRequest) -> RouterReply {
        lock.lock(); defer { lock.unlock() }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let command = query.first { $0.name == "cmd" }?.value ?? ""
        if request.httpMethod == "POST" {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            let items = URLComponents(string: "http://fixture.test/?\(body)")?.queryItems ?? []
            let form = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
            forms.append(form)
            switch form["goformId"] {
            case "LOGIN":
                return RouterReply(headers: ["Set-Cookie": "stok=fixture-session; Path=/"], payload: ["result": rejectLogin ? "3" : "0"])
            case "SET_BEARER_PREFERENCE":
                if expireNextModeWriteSession {
                    expireNextModeWriteSession = false
                    return RouterReply(status: 401, payload: ["Error": "none secure connection"])
                }
                if rejectModeWrite { return RouterReply(payload: ["result": "failure"]) }
                guard request.value(forHTTPHeaderField: "Cookie")?.contains("stok=fixture-session") == true else {
                    return RouterReply(payload: ["result": "failure"])
                }
                if !ignoreModeWrite { mode = form["BearerPreference"] ?? mode }
                if dropModeWriteResponse { return RouterReply(error: URLError(.networkConnectionLost)) }
                return RouterReply(payload: ["result": "success"])
            default: return RouterReply(payload: ["result": "failure"])
            }
        }
        if command.contains("psw_fail_num_str") {
            lockReads += 1
            return RouterReply(payload: ["psw_fail_num_str": "5", "login_lock_time": "0"], delay: delayLockReply ? 0.3 : 0)
        }
        if command == "LD" { return RouterReply(payload: ["LD": "fixture-ld"]) }
        if command == "RD" { return RouterReply(payload: ["RD": "fixture-rd"]) }
        if command.contains("sms_data_total") { return RouterReply(payload: ["messages": []]) }
        if command == "network_net_select" {
            modeReads += 1
            return RouterReply(payload: ["network_net_select": mode])
        }
        if command.contains("wan_active_band") {
            bandReads += 1
            return RouterReply(payload: bandExtras, delay: bandReplyDelay)
        }
        if command.contains("realtime_rx_thrpt") {
            statusReads += 1
            if requireStatusLogin,
               request.value(forHTTPHeaderField: "Cookie")?.contains("stok=fixture-session") != true {
                return RouterReply(status: 401, payload: ["Error": "none secure connection"])
            }
        }
        if rejectStatus { return RouterReply(status: 401, payload: ["Error": "none secure connection"]) }
        var payload: [String: Any] = [
            "network_net_select": mode, "network_type": "4G", "ppp_status": "ipv4_ipv6_connected",
            "wa_inner_version": "F50ProV1.0.0B28", "cr_version": "MU3356V1.0.0B28",
            "cpu_utility": "10", "mem_utility": "20", "cpu_temperature": "40"
        ]
        payload.merge(statusExtras) { _, new in new }
        let delay = command.contains("realtime_rx_thrpt") ? delayNextStatusReply : 0
        if command.contains("realtime_rx_thrpt") { delayNextStatusReply = 0 }
        return RouterReply(payload: payload, delay: delay)
    }
}

private final class RouterURLProtocol: URLProtocol {
    // Tests use an ephemeral session with this protocol; no requests reach a real device.
    static var fixture: RouterFixture!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.fixture.reply(to: request)
        let respond = { [self] in
            if let error = reply.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: reply.payload))
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: respond)
        } else {
            respond()
        }
    }
    override func stopLoading() {}
}

@MainActor
final class F50NetworkModeFetcherTests: XCTestCase {
    private func makeFetcher(_ fixture: RouterFixture, automaticallyRefresh: Bool = false,
                             load: @escaping () -> String = { "saved-password" },
                             save: @escaping (String) -> Void = { _ in }) -> F50Fetcher {
        RouterURLProtocol.fixture = fixture
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouterURLProtocol.self]
        return F50Fetcher(session: URLSession(configuration: config), automaticallyRefresh: automaticallyRefresh,
                          loadPassword: load, savePassword: save)
    }

    func testStartupLoadsSavedPasswordAndUsesItForAutomaticLogin() async {
        let fixture = RouterFixture()
        fixture.rejectStatus = true
        var loads = 0
        let fetcher = makeFetcher(fixture, automaticallyRefresh: true, load: { loads += 1; return "saved" })
        await fetcher.fetchDataAsync()
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(fetcher.password, "saved")
        XCTAssertEqual(fixture.postedForms.compactMap { $0["goformId"] }, ["LOGIN"])
    }

    func testLoadingSavedPasswordPreservesModeAndTrafficWithoutSavingAgain() async {
        let fixture = RouterFixture()
        var loads = 0
        var saves = 0
        let fetcher = makeFetcher(fixture, load: { loads += 1; return "saved" }, save: { _ in saves += 1 })
        await fetcher.fetchDataAsync()
        fetcher.status.monthlyRx = 12345
        XCTAssertEqual(fetcher.password, "saved")
        XCTAssertEqual(fetcher.networkMode, .automatic)
        XCTAssertEqual(fetcher.status.monthlyRx, 12345)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(saves, 0)
        XCTAssertTrue(fixture.postedForms.isEmpty)
    }

    func testLoginThenSwitchConfirmsConfigurationAndReusesSession() async throws {
        let fixture = RouterFixture()
        let fetcher = makeFetcher(fixture)
        await fetcher.fetchDataAsync()
        try await fetcher.setNetworkMode(.lteOnly)
        XCTAssertEqual(fetcher.networkMode, .lteOnly)
        XCTAssertEqual(fixture.postedForms.compactMap { $0["goformId"] }, ["LOGIN", "SET_BEARER_PREFERENCE"])
        XCTAssertEqual(fixture.postedForms.last?["BearerPreference"], "Only_LTE")
        XCTAssertFalse(fetcher.isSwitchingNetworkMode)
    }

    func testRejectedPasswordIsNotRetriedByPollingOrSwitchAttempts() async {
        let fixture = RouterFixture()
        fixture.rejectLogin = true
        let fetcher = makeFetcher(fixture)
        await fetcher.fetchDataAsync()
        for _ in 0..<2 {
            do {
                try await fetcher.setNetworkMode(.lteOnly)
                XCTFail("Expected login failure")
            } catch F50MobileDataError.loginFailed {
                // Expected: the second submission must not consume another login attempt.
            } catch { XCTFail("Unexpected error: \(error)") }
            await fetcher.fetchDataAsync()
        }
        XCTAssertEqual(fixture.postedForms.compactMap { $0["goformId"] }, ["LOGIN"])
    }

    func testChangedPasswordCancelsSwitchLoginAndBlocksConcurrentDataToggle() async throws {
        let fixture = RouterFixture()
        let fetcher = makeFetcher(fixture)
        fetcher.password = "first-password"
        await fetcher.fetchDataAsync()
        fixture.delayLockReply = true
        let switching = Task { try await fetcher.setNetworkMode(.lteOnly) }
        for _ in 0..<100 where fixture.lockReadCount == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(fetcher.isSwitchingNetworkMode)
        do {
            try await fetcher.setMobileData(enabled: false)
            XCTFail("Expected busy error")
        } catch F50NetworkModeError.busy {} catch { XCTFail("Unexpected error: \(error)") }
        fetcher.password = "changed-password"
        do {
            try await switching.value
            XCTFail("Expected cancellation after configuration change")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(fixture.postedForms.isEmpty)
        XCTAssertFalse(fetcher.isSwitchingNetworkMode)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for router request")
    }

    func testPollingAndSwitchShareRejectedLoginAttempt() async throws {
        let fixture = RouterFixture()
        let fetcher = makeFetcher(fixture)
        await fetcher.fetchDataAsync()
        fixture.delayLockReply = true
        fixture.rejectLogin = true
        let switching = Task { try await fetcher.setNetworkMode(.lteOnly) }
        try await waitUntil { fixture.lockReadCount == 1 }
        fixture.rejectStatus = true
        await fetcher.fetchDataAsync()
        do {
            try await switching.value
            XCTFail("Expected rejected password")
        } catch F50MobileDataError.loginFailed {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(fixture.lockReadCount, 1)
        XCTAssertEqual(fixture.postedForms.compactMap { $0["goformId"] }, ["LOGIN"])
    }

    func testPollingAndSwitchShareSuccessfulLoginAndSession() async throws {
        let fixture = RouterFixture()
        let fetcher = makeFetcher(fixture)
        await fetcher.fetchDataAsync()
        fixture.delayLockReply = true
        let switching = Task { try await fetcher.setNetworkMode(.lteOnly) }
        try await waitUntil { fixture.lockReadCount == 1 }
        fixture.requireStatusLogin = true
        await fetcher.fetchDataAsync()
        try await switching.value
        XCTAssertEqual(fetcher.networkMode, .lteOnly)
        XCTAssertTrue(fetcher.status.isOnline)
        XCTAssertEqual(fixture.lockReadCount, 1)
        XCTAssertEqual(fixture.postedForms.compactMap { $0["goformId"] }, ["LOGIN", "SET_BEARER_PREFERENCE"])
    }

    func testLostFirstSwitchResponseIsAlsoConfirmed() async throws {
        let fixture = RouterFixture()
        fixture.dropModeWriteResponse = true
        let fetcher = makeFetcher(fixture)
        await fetcher.fetchDataAsync()
        try await fetcher.setNetworkMode(.lteOnly)
        XCTAssertEqual(fetcher.networkMode, .lteOnly)
        XCTAssertEqual(fixture.modeReadCount, 1)
        XCTAssertEqual(fixture.postedForms.compactMap { $0["goformId"] }, ["LOGIN", "SET_BEARER_PREFERENCE"])
    }

    func testLostUnappliedSwitchWaitsForConfirmationAndCanBeCancelled() async throws {
        let fixture = RouterFixture()
        fixture.dropModeWriteResponse = true
        fixture.ignoreModeWrite = true
        let fetcher = makeFetcher(fixture)
        await fetcher.fetchDataAsync()
        let switching = Task { try await fetcher.setNetworkMode(.lteOnly) }
        try await waitUntil { fixture.modeReadCount > 0 }
        XCTAssertTrue(fetcher.isSwitchingNetworkMode)
        XCTAssertEqual(fetcher.networkMode, .automatic)
        switching.cancel()
        do {
            try await switching.value
            XCTFail("Expected cancellation while waiting for confirmation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(fetcher.isSwitchingNetworkMode)
        XCTAssertEqual(fixture.postedForms.compactMap { $0["goformId"] }, ["LOGIN", "SET_BEARER_PREFERENCE"])
    }

    func testLostSwitchResponseIsConfirmedWithoutResending() async throws {
        let fixture = RouterFixture()
        let fetcher = makeFetcher(fixture)
        await fetcher.fetchDataAsync()
        // Establish a reusable session, then lose the next write response.
        try await fetcher.setNetworkMode(.lteOnly)
        fixture.dropModeWriteResponse = true
        try await fetcher.setNetworkMode(.automatic)
        XCTAssertEqual(fetcher.networkMode, .automatic)
        XCTAssertEqual(fixture.modeReadCount, 2)
        XCTAssertEqual(fixture.postedForms.compactMap { $0["goformId"] },
                       ["LOGIN", "SET_BEARER_PREFERENCE", "SET_BEARER_PREFERENCE"])
        XCTAssertFalse(fetcher.isSwitchingNetworkMode)
    }

    func testExplicitWriteFailureDoesNotLoginAndResend() async throws {
        let fixture = RouterFixture()
        let fetcher = makeFetcher(fixture)
        await fetcher.fetchDataAsync()
        try await fetcher.setNetworkMode(.lteOnly)
        fixture.rejectModeWrite = true
        do {
            try await fetcher.setNetworkMode(.automatic)
            XCTFail("Expected rejected mode change")
        } catch F50NetworkModeError.requestFailed {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(fetcher.networkMode, .lteOnly)
        XCTAssertEqual(fixture.postedForms.compactMap { $0["goformId"] },
                       ["LOGIN", "SET_BEARER_PREFERENCE", "SET_BEARER_PREFERENCE"])
    }

    func testExpiredSessionStillRelogsAndRetriesOnce() async throws {
        let fixture = RouterFixture()
        let fetcher = makeFetcher(fixture)
        await fetcher.fetchDataAsync()
        try await fetcher.setNetworkMode(.lteOnly)
        fixture.expireNextModeWriteSession = true
        try await fetcher.setNetworkMode(.automatic)
        XCTAssertEqual(fetcher.networkMode, .automatic)
        XCTAssertEqual(fixture.postedForms.compactMap { $0["goformId"] },
                       ["LOGIN", "SET_BEARER_PREFERENCE", "SET_BEARER_PREFERENCE", "LOGIN", "SET_BEARER_PREFERENCE"])
    }

    func testOldStatusResponseCannotOverwriteConfirmedMode() async throws {
        let fixture = RouterFixture()
        let fetcher = makeFetcher(fixture)
        await fetcher.fetchDataAsync()
        let previousReads = fixture.statusReadCount
        fixture.delayNextStatusReply = 0.5
        fetcher.fetchData()
        try await waitUntil { fixture.statusReadCount > previousReads }
        try await fetcher.setNetworkMode(.lteOnly)
        XCTAssertEqual(fetcher.networkMode, .lteOnly)
        XCTAssertEqual(fixture.mode, "Only_LTE")
        XCTAssertTrue(fixture.statusReadCount >= previousReads + 2)
        XCTAssertFalse(fetcher.isSwitchingNetworkMode)
    }

    func testNetworkTypeChangeClearsOldBandAndIgnoresDelayedBandReply() async throws {
        let fixture = RouterFixture()
        fixture.statusExtras = ["network_type": "5G SA", "Nr_bands": 41]
        fixture.bandExtras = ["nr5g_action_band": "n41"]
        fixture.bandReplyDelay = 0.6
        let fetcher = makeFetcher(fixture)
        await fetcher.fetchDataAsync()
        XCTAssertEqual(fetcher.status.currentBands, "n41")
        try await waitUntil { fixture.bandReadCount > 0 }
        fixture.statusExtras = ["network_type": "4G"]
        fixture.bandExtras = [:]
        fixture.bandReplyDelay = 0
        await fetcher.fetchDataAsync()
        XCTAssertEqual(fetcher.status.networkType, "4G LTE")
        XCTAssertEqual(fetcher.status.currentBands, "")
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertEqual(fetcher.status.currentBands, "")
    }

    func testTrackedDailyDoesNotIncludePreviousDaySessionTraffic() async {
        let fixture = RouterFixture()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let defaults = UserDefaults.standard
        let keys = ["F50_DailyTrafficDate", "F50_DailyTrafficStartBytes", "F50_DailyTrafficLastSeenBytes", "F50_DailyTrafficLastSeenAt"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(formatter.string(from: Date()), forKey: keys[0])
        defaults.set("100000", forKey: keys[1])
        fixture.statusExtras = ["monthly_rx_bytes": "101024", "realtime_rx_bytes": "100000"]
        let fetcher = makeFetcher(fixture)
        await fetcher.fetchDataAsync()
        XCTAssertEqual(fetcher.status.trackedDaily, 1024)
        XCTAssertEqual(fetcher.status.dailyTotal, 1024)
        XCTAssertEqual(fetcher.status.sessionTotal, 100000)
    }
}
