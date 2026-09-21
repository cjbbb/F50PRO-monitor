import XCTest
import CryptoKit
@testable import F50Core

final class F50ResponseParserTests: XCTestCase {
    func testDefaultsUseAdminForBothCredentials() {
        XCTAssertEqual(F50Configuration.defaultCredential, "admin")
    }

    func testParsesNumericValuesFromRouterPayloads() {
        XCTAssertEqual(F50ResponseParser.parseInt("bars: 5"), 5)
        XCTAssertEqual(F50ResponseParser.parseDouble("61.5℃"), 61.5)
        XCTAssertEqual(F50ResponseParser.parseUInt64("12345 bytes"), 12345)
        XCTAssertEqual(F50ResponseParser.parseUInt64(NSNumber(value: 9876543210 as UInt64)), 9876543210)
        XCTAssertEqual(F50ResponseParser.parseUInt64("0x1000"), 4096)
        XCTAssertEqual(F50ResponseParser.parseUInt64(123.456), 123)
    }

    func testParsesZTEV50MU3351HardwareMetrics() {
        var status = F50Status()
        status.mergeHardwareMetrics(from: [
            "temperature": "48.296",
            "cpu_utility": "4.2039827204720215",
            "mem_utility": "71.86852960745176"
        ])

        XCTAssertEqual(status.temperature, 48.296, accuracy: 0.001)
        XCTAssertEqual(status.cpuUsage, 4.2039827204720215, accuracy: 0.001)
        XCTAssertEqual(status.memUsage, 71.86852960745176, accuracy: 0.001)
    }

    // MARK: - UFI-TOOLS 签名（用真实设备抓包验证过的向量，防止回归）

    func testSha256OfAdminIsLowercaseUFIToken() {
        // UFI authorization 头 = SHA256(口令) 小写 hex
        let digest = SHA256.hash(data: Data("admin".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "8c6976e5b5410415bde908bd4dee15dfb167a9c873fc4bb8a81f6f2ab448a918")
    }

    func testParseDoubleStripsSignalUnits() {
        XCTAssertEqual(F50ResponseParser.parseDouble("-85 dBm"), -85)
        XCTAssertEqual(F50ResponseParser.parseDouble("-8 dB"), -8)
        XCTAssertEqual(F50ResponseParser.parseDouble("14.5 dB"), 14.5)
        XCTAssertEqual(F50ResponseParser.parseDouble(NSNull()), 0)
    }

    func testFirstValidSignalValueSkipsNullAndZeroPlaceholdersInLeadingKeys() {
        // 设备在 NSA/4G 等状态下会把不适用的 nr_* 字段置为 null 或 "0"，
        // 真实值在 Z5g_* / 5g_* / lte_* 中 —— 不能被前置的无效值短路掉
        let dict: [String: Any] = [
            "nr_rsrp": NSNull(),
            "Z5g_rsrp": "-85",
            "nr_rsrq": "0",
            "5g_rsrq": "-9",
            "Nr_snr": NSNull(),
            "lte_snr": "12"
        ]
        XCTAssertEqual(
            F50ResponseParser.firstValidSignalValue(
                in: dict,
                keys: ["nr_rsrp", "Z5g_rsrp", "5g_rsrp", "lte_rsrp"]
            ), -85
        )
        XCTAssertEqual(
            F50ResponseParser.firstValidSignalValue(
                in: dict,
                keys: ["nr_rsrq", "Z5g_rsrq", "5g_rsrq", "lte_rsrq"]
            ), -9
        )
        XCTAssertEqual(
            F50ResponseParser.firstValidSignalValue(
                in: dict,
                keys: ["Nr_snr", "nr_snr", "Z5g_snr", "5g_snr", "lte_snr"]
            ), 12
        )
        XCTAssertNil(
            F50ResponseParser.firstValidSignalValue(
                in: dict,
                keys: ["Nr_snr", "5g_snr"]
            )
        )
    }

    func testFirstValidSignalValueIsCaseInsensitive() {
        // 部分固件返回 5G_rsrp / nr_snr 等大小写变体
        let dict: [String: Any] = [
            "5G_rsrp": "-90",
            "nr_snr": "14",
            "LTE_SNR": "8"
        ]
        XCTAssertEqual(
            F50ResponseParser.firstValidSignalValue(
                in: dict,
                keys: ["nr_rsrp", "Z5g_rsrp", "5g_rsrp", "lte_rsrp"]
            ), -90
        )
        XCTAssertEqual(
            F50ResponseParser.firstValidSignalValue(in: dict, keys: ["Nr_snr", "5g_snr", "lte_snr"]),
            14
        )
        XCTAssertEqual(
            F50ResponseParser.firstValidSignalValue(in: dict, keys: ["lte_snr"]),
            8
        )
    }

    func testFirstValidSignalValueParsesValuesWithUnits() {
        let dict: [String: Any] = [
            "nr_rsrp": "-85 dBm",
            "nr_rsrq": "-8 dB",
            "Nr_snr": "14 dB"
        ]
        XCTAssertEqual(F50ResponseParser.firstValidSignalValue(in: dict, keys: ["nr_rsrp"]), -85)
        XCTAssertEqual(F50ResponseParser.firstValidSignalValue(in: dict, keys: ["nr_rsrq"]), -8)
        XCTAssertEqual(F50ResponseParser.firstValidSignalValue(in: dict, keys: ["Nr_snr"]), 14)
    }

    func testFirstValidSignalValuePrefersNrOverLteWhenBothPresent() {
        // SA 模式下 nr_* 优先于 lte_*（与设备实际状态一致）
        let dict: [String: Any] = [
            "nr_rsrp": "-82",
            "lte_rsrp": "-100"
        ]
        XCTAssertEqual(
            F50ResponseParser.firstValidSignalValue(
                in: dict,
                keys: ["nr_rsrp", "Z5g_rsrp", "5g_rsrp", "lte_rsrp"]
            ), -82
        )
    }

    func testParsesBase64EncodedSMSMessages() {
        let payload: [String: Any] = [
            "messages": [[
                "id": 42,
                "number": "10086",
                "content": Data("验证码 123456".utf8).base64EncodedString(),
                "date": "2026,08,13,14,25,09,+08",
                "tag": "1"
            ]]
        ]

        XCTAssertEqual(
            F50ResponseParser.parseSMSMessages(payload),
            [F50SMSMessage(
                id: "42",
                number: "10086",
                content: "验证码 123456",
                dateText: "2026-08-13 14:25:09",
                tag: "1"
            )]
        )
    }

    func testParsesTrafficLimitFromRouterPayload() {
        XCTAssertEqual(
            F50ResponseParser.parseTrafficLimit(size: "1536_1", unit: "data"),
            1536 * 1024 * 1024
        )
        XCTAssertEqual(
            F50ResponseParser.parseTrafficLimit(size: "100_1024", unit: "0"),
            100 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(
            F50ResponseParser.parseTrafficLimit(size: "10", unit: "GB"),
            10 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(
            F50ResponseParser.parseTrafficLimit(size: "500", unit: "MB"),
            500 * 1024 * 1024
        )
        XCTAssertEqual(F50ResponseParser.parseTrafficLimit(size: "0", unit: "data"), 0)
    }

    func testF50StatusTrafficTotals() {
        var status = F50Status()
        status.monthlyRx = 1000
        status.monthlyTx = 500
        status.realtimeRx = 200
        status.realtimeTx = 100
        status.trackedDaily = 400

        XCTAssertEqual(status.monthlyTotal, 1500)
        XCTAssertEqual(status.sessionTotal, 300)
        XCTAssertEqual(status.dailyTotal, 400)

        status.dailyRx = 250
        status.dailyTx = 250
        XCTAssertEqual(status.dailyTotal, 500)
    }

    func testExtractsResetDayFromDayKeysUsedByZTERouter() {
        XCTAssertEqual(F50ResponseParser.extractFirstValidResetDay(from: ["data_volume_clear_day": "16"]), 16)
        XCTAssertEqual(F50ResponseParser.extractFirstValidResetDay(from: ["monthly_clear_day": "1"]), 1)
        XCTAssertEqual(F50ResponseParser.extractFirstValidResetDay(from: ["clear_day": 25]), 25)
        XCTAssertEqual(F50ResponseParser.extractFirstValidResetDay(from: ["billing_day": "31"]), 31)
        XCTAssertEqual(F50ResponseParser.extractFirstValidResetDay(from: ["data_volume_clear_day": "0"]), 0)
        XCTAssertEqual(F50ResponseParser.extractFirstValidResetDay(from: [:]), 0)
    }

    func testExtractsResetDayFromFullDateValues() {
        XCTAssertEqual(
            F50ResponseParser.extractFirstValidResetDay(from: ["data_volume_clear_date": "2026-08-16"]), 16)
        XCTAssertEqual(
            F50ResponseParser.extractFirstValidResetDay(from: ["clear_date": "2026/8/16"]), 16)
        XCTAssertEqual(
            F50ResponseParser.extractFirstValidResetDay(from: ["billing_date": "2026年8月16日"]), 16)
        // 无效/占位值应被忽略
        XCTAssertEqual(
            F50ResponseParser.extractFirstValidResetDay(from: ["data_volume_clear_date": "0"]), 0)
        XCTAssertEqual(
            F50ResponseParser.extractFirstValidResetDay(from: ["clear_date": NSNull()]), 0)
    }

    func testExtractsResetDayFromTrafficClearDateField() {
        // F50 设备（80/2333 后台）实际使用的字段
        XCTAssertEqual(F50ResponseParser.extractFirstValidResetDay(from: ["traffic_clear_date": "18"]), 18)
        XCTAssertEqual(F50ResponseParser.extractFirstValidResetDay(from: ["traffic_clear_date": 18]), 18)
        XCTAssertEqual(F50ResponseParser.extractFirstValidResetDay(from: ["traffic_clear_date": "2026-08-18"]), 18)
        XCTAssertEqual(
            F50ResponseParser.extractFirstValidResetDay(from: ["traffic_clear_date": "0"]), 0)
    }

    func testDaysUntilResetIsNilWhenResetDayUnknown() {
        let status = F50Status() // trafficResetDay == 0（未知）
        XCTAssertNil(status.daysUntilReset)
    }

    func testDaysUntilResetMatchesExplicitResetDay() {
        var status = F50Status()
        status.trafficResetDay = 16
        guard let days = status.daysUntilReset else {
            XCTFail("显式设置清零日后应返回天数")
            return
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let currentDay = calendar.component(.day, from: today)
        let resetDay = 16

        let target: Date
        if currentDay < resetDay {
            var comps = calendar.dateComponents([.year, .month], from: today)
            let range = calendar.range(of: .day, in: .month, for: today) ?? 1..<31
            comps.day = min(resetDay, range.count)
            target = calendar.date(from: comps) ?? today
        } else {
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: today) else {
                XCTFail("无法计算下月日期")
                return
            }
            var comps = calendar.dateComponents([.year, .month], from: nextMonth)
            let range = calendar.range(of: .day, in: .month, for: nextMonth) ?? 1..<31
            comps.day = min(resetDay, range.count)
            target = calendar.date(from: comps) ?? today
        }
        let expected = max(0, calendar.dateComponents([.day], from: today, to: target).day ?? 0)
        XCTAssertEqual(days, expected)
    }

    func testFormatsTerabytes() {
        XCTAssertEqual(F50Status.formatBytes(1536 * 1024 * 1024 * 1024), "1.50 TB")
    }

    func testGSMEncodeMatchesUFIUTF16BEHex() {
        // UFI-TOOLS 短信编码 = UTF-16BE 的 hex（非 GSM 7-bit）
        XCTAssertEqual(F50ResponseParser.gsmEncode("A"), "0041")
        XCTAssertEqual(F50ResponseParser.gsmEncode("hello"), "00680065006c006c006f")
        // 中文“测” U+6D4B
        XCTAssertEqual(F50ResponseParser.gsmEncode("测"), "6d4b")
        // 混合：测=6D4B 试=8BD5 空格=0020 hello
        XCTAssertEqual(F50ResponseParser.gsmEncode("测试 hello"), "6d4b8bd5002000680065006c006c006f")
        // 完整对照 python 验证值（与 UFI 后台一致）
        XCTAssertEqual(
            F50ResponseParser.gsmEncode("测试短信 hello"),
            "6d4b8bd577ed4fe1002000680065006c006c006f"
        )
        XCTAssertEqual(F50ResponseParser.gsmEncode(""), "")
    }

    func testParsesCurrentBandsForNetworkType() {
        let payload: [String: Any] = [
            "wan_active_band": "LTE BAND 3",
            "nr5g_action_band": "n78"
        ]

        XCTAssertEqual(F50ResponseParser.parseCurrentBands(from: payload, networkType: "5G NSA"), "B3 + n78")
        XCTAssertEqual(F50ResponseParser.parseCurrentBands(from: payload, networkType: "5G SA"), "n78")
        XCTAssertEqual(F50ResponseParser.parseCurrentBands(from: payload, networkType: "4G LTE"), "B3")

        XCTAssertEqual(
            F50ResponseParser.parseCurrentBands(
                from: ["ZCELLINFO_band": "78"],
                networkType: "5G SA"
            ),
            "n78"
        )
    }

    func testParsesCurrentBandsFromNetworkInformationDump() {
        // F50 不返回 nr5g_action_band 等字段，频段来自 network_information dump 的 Nr_bands
        let payload: [String: Any] = [
            "Nr_bands": 41,
            "Nr_fcn": 504990
        ]
        XCTAssertEqual(F50ResponseParser.parseCurrentBands(from: payload, networkType: "5G SA"), "n41")
        XCTAssertEqual(F50ResponseParser.parseCurrentBands(from: payload, networkType: "5G"), "n41")
        // Nr_bands 不适用于 NSA/LTE 的 LTE 主载波判断
        XCTAssertEqual(F50ResponseParser.parseCurrentBands(from: payload, networkType: "4G LTE"), "")
    }

    func testBaseRefreshKeepsExistingHardwareMetricsWhenPayloadHasNoValidValues() {
        var status = F50Status()
        status.cpuUsage = 32
        status.memUsage = 60
        status.temperature = 61.4

        status.mergeHardwareMetrics(from: [
            "cpu_utility": 0,
            "mem_utility": "0",
            "ic_temp": NSNull()
        ])

        XCTAssertEqual(status.cpuUsage, 32)
        XCTAssertEqual(status.memUsage, 60)
        XCTAssertEqual(status.temperature, 61.4)
    }

    func testBaseRefreshUpdatesHardwareMetricsWhenPayloadHasValidValues() {
        var status = F50Status()
        status.cpuUsage = 32
        status.memUsage = 60
        status.temperature = 61.4

        status.mergeHardwareMetrics(from: [
            "cpu_utility": 41,
            "mem_utility": "72.5",
            "ic_temp": "63.2℃"
        ])

        XCTAssertEqual(status.cpuUsage, 41)
        XCTAssertEqual(status.memUsage, 72.5)
        XCTAssertEqual(status.temperature, 63.2)
    }

    func testConfigurationChangeClearsHardwareMetrics() {
        var status = F50Status()
        status.cpuUsage = 32
        status.memUsage = 60
        status.temperature = 61.4

        status.clearHardwareMetrics()

        XCTAssertEqual(status.cpuUsage, 0)
        XCTAssertEqual(status.memUsage, 0)
        XCTAssertEqual(status.temperature, 0)
    }

    func testMonthlyTotalClampsHugeValuesWithoutCrash() {
        var status = F50Status()
        // 设备脏数据：UInt64.max + 非零值，普通加法会溢出 trap
        status.monthlyRx = UInt64.max
        status.monthlyTx = 5
        _ = status.monthlyTotal
        _ = status.trafficUsageRatio
    }

    func testTrafficUsageRatioClampsToRange() {
        var status = F50Status()
        status.monthlyRx = 30 * 1024 * 1024 * 1024
        status.trafficLimit = 20 * 1024 * 1024 * 1024
        XCTAssertEqual(status.trafficUsageRatio, 1.0)
        XCTAssertEqual(F50Status().trafficUsageRatio, 0.0)
    }

    func testFormatSMSTime() {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 18
        components.hour = 12
        components.minute = 30
        components.second = 45
        guard let timeZone = TimeZone(secondsFromGMT: 8 * 3600),
              let date = calendar.date(from: components) else {
            XCTFail("Date construction failed")
            return
        }

        let formatted = F50ResponseParser.formatSMSTime(date: date, timeZone: timeZone)
        XCTAssertEqual(formatted, "26;08;18;12;30;45;+8")
    }

    func testBuildSMSRequestBodyEncodesProperly() {
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 18
        components.hour = 12
        components.minute = 30
        components.second = 45
        guard let timeZone = TimeZone(secondsFromGMT: 8 * 3600),
              let date = calendar.date(from: components) else {
            XCTFail("Date construction failed")
            return
        }

        let body = F50ResponseParser.buildSMSRequestBody(
            number: "+86 138-0013-8000",
            content: "测试 Hello",
            ad: "SAMPLEAD123",
            date: date,
            timeZone: timeZone
        )

        XCTAssertTrue(body.contains("goformId=SEND_SMS"))
        XCTAssertTrue(body.contains("isTest=false"))
        XCTAssertTrue(body.contains("notCallback=true"))
        XCTAssertTrue(body.contains("Number=%2B8613800138000"))
        XCTAssertTrue(body.contains("sms_time=26%3B08%3B18%3B12%3B30%3B45%3B%2B8"))
        XCTAssertTrue(body.contains("MessageBody=6d4b8bd5002000480065006c006c006f"))
        XCTAssertTrue(body.contains("ID=-1"))
        XCTAssertTrue(body.contains("encode_type=UNICODE"))
        XCTAssertTrue(body.contains("AD=SAMPLEAD123"))
    }

    // MARK: - Address & Endpoint Resolution Tests (Domain / Intranet Penetration Support)

    func testIsValidAddressForIPAndDomain() {
        // Valid IP addresses
        XCTAssertTrue(F50Configuration.isValidAddress("192.168.0.1"))
        XCTAssertTrue(F50Configuration.isValidAddress("10.0.0.1"))
        XCTAssertTrue(F50Configuration.isValidAddress("192.168.0.1:2333"))
        XCTAssertTrue(F50Configuration.isValidAddress("http://192.168.0.1"))

        // Invalid IP addresses
        XCTAssertFalse(F50Configuration.isValidAddress("999.999.999.999"))
        XCTAssertFalse(F50Configuration.isValidAddress("192.168.0.300"))
        XCTAssertFalse(F50Configuration.isValidAddress("192.168.1"))

        // Valid Domain names
        XCTAssertTrue(F50Configuration.isValidAddress("f50.example.com"))
        XCTAssertTrue(F50Configuration.isValidAddress("https://f50.example.com"))
        XCTAssertTrue(F50Configuration.isValidAddress("my-f50.frp.tunnel.xyz:8443"))
        XCTAssertTrue(F50Configuration.isValidAddress("localhost"))

        // Invalid hostnames / strings
        XCTAssertFalse(F50Configuration.isValidAddress(""))
        XCTAssertFalse(F50Configuration.isValidAddress("   "))
        XCTAssertFalse(F50Configuration.isValidAddress("has space.com"))
        XCTAssertFalse(F50Configuration.isValidAddress("invalid/path"))
        XCTAssertFalse(F50Configuration.isValidAddress(".invalid.com"))
    }

    func testDisplayAddress() {
        XCTAssertEqual(F50Configuration.displayAddress(from: "http://192.168.0.1:2333"), "192.168.0.1")
        XCTAssertEqual(F50Configuration.displayAddress(from: "http://192.168.0.1"), "192.168.0.1")
        XCTAssertEqual(F50Configuration.displayAddress(from: "http://f50.example.com"), "f50.example.com")
        XCTAssertEqual(F50Configuration.displayAddress(from: "https://f50.example.com"), "f50.example.com")
        XCTAssertEqual(F50Configuration.displayAddress(from: "http://f50.example.com:8443"), "f50.example.com")
    }

    func testNormalizeBaseURL() {
        XCTAssertEqual(F50Configuration.normalizeBaseURL("192.168.0.1"), "http://192.168.0.1")
        XCTAssertEqual(F50Configuration.normalizeBaseURL("f50.example.com"), "http://f50.example.com")
        XCTAssertEqual(F50Configuration.normalizeBaseURL("https://f50.example.com"), "https://f50.example.com")
        XCTAssertEqual(F50Configuration.normalizeBaseURL("f50.example.com:8443"), "http://f50.example.com")
    }

    func testMergeHardwareMetricsFromRouterAndUFIAliases() {
        var status = F50Status()
        let payload: [String: Any] = [
            "internal_temperature": "54.2",
            "cpu_percent": "28.4",
            "mem_percent": "45.0"
        ]
        status.mergeHardwareMetrics(from: payload)
        XCTAssertEqual(status.temperature, 54.2)
        XCTAssertEqual(status.cpuUsage, 28.4)
        XCTAssertEqual(status.memUsage, 45.0)
    }

    func testTrafficLimitFallsBackToFluxPrefixedKeys() {
        // F50 Pro (MU3356 B22) 只返回 flux_ 前缀的套餐键
        let fluxOnly: [String: Any] = [
            "flux_data_volume_limit_size": "50_1024",
            "flux_data_volume_limit_unit": "data",
            "flux_clear_date": "1"
        ]
        XCTAssertEqual(F50ResponseParser.parseTrafficLimit(from: fluxOnly), 50 * 1024 * 1024 * 1024)
        XCTAssertEqual(F50ResponseParser.extractFirstValidResetDay(from: fluxOnly), 1)

        // 旧固件的无前缀键优先；空串视为缺失
        let legacy: [String: Any] = [
            "data_volume_limit_size": "10",
            "data_volume_limit_unit": "GB",
            "flux_data_volume_limit_size": ""
        ]
        XCTAssertEqual(F50ResponseParser.parseTrafficLimit(from: legacy), 10 * 1024 * 1024 * 1024)

        let emptyLegacy: [String: Any] = [
            "data_volume_limit_size": "",
            "flux_data_volume_limit_size": "50_1024"
        ]
        XCTAssertEqual(F50ResponseParser.parseTrafficLimit(from: emptyLegacy), 50 * 1024 * 1024 * 1024)
        XCTAssertEqual(F50ResponseParser.parseTrafficLimit(from: [:]), 0)
    }

    func testResetDayIgnoredWhenRouterAutoClearIsOff() {
        // 固定流量包：路由器「自动清零」关闭时，flux_clear_date 只是未生效的默认值
        let fixedPackage: [String: Any] = [
            "flux_clear_date": "1",
            "flux_auto_clear_flow_data_switch": "off"
        ]
        XCTAssertTrue(F50ResponseParser.isAutoTrafficClearDisabled(fixedPackage))
        XCTAssertEqual(F50ResponseParser.extractFirstValidResetDay(from: fixedPackage), 0)

        let monthlyPackage: [String: Any] = [
            "flux_clear_date": "5",
            "flux_auto_clear_flow_data_switch": "on"
        ]
        XCTAssertFalse(F50ResponseParser.isAutoTrafficClearDisabled(monthlyPackage))
        XCTAssertEqual(F50ResponseParser.extractFirstValidResetDay(from: monthlyPackage), 5)

        // 旧固件不返回该开关（或为空串）：保持原有行为
        XCTAssertFalse(F50ResponseParser.isAutoTrafficClearDisabled(["flux_auto_clear_flow_data_switch": ""]))
        XCTAssertEqual(F50ResponseParser.extractFirstValidResetDay(from: ["traffic_clear_date": "8"]), 8)
    }

    func testRoamingStateFromRawRoamStatus() {
        var status = F50Status()
        XCTAssertEqual(status.roamingState, .unknown)

        status.rawRoamStatus = "International"
        XCTAssertEqual(status.roamingState, .international)
        status.rawRoamStatus = " internal "
        XCTAssertEqual(status.roamingState, .domestic)
        status.rawRoamStatus = "Home"
        XCTAssertEqual(status.roamingState, .home)
        status.rawRoamStatus = "whatever"
        XCTAssertEqual(status.roamingState, .unknown)

        XCTAssertEqual(F50ResponseParser.parseRoamStatus(["network_simcard_roam": "", "simcard_roam": "Internal"]), "Internal")
        XCTAssertEqual(F50ResponseParser.parseRoamStatus(["network_simcard_roam": "Home", "simcard_roam": "Internal"]), "Home")
        XCTAssertEqual(F50ResponseParser.parseRoamStatus([:]), "")
    }

    func testDailyBaselineUsesRecentLastSeenTotalAcrossMidnight() {
        // Mac 23:00 睡眠、次日 08:00 唤醒：用睡前累计值作基线，夜间其他设备的用量计入今日
        XCTAssertEqual(F50ResponseParser.dailyBaseline(current: 5_000, lastSeen: 4_200, lastSeenAge: 9 * 3600), 4_200)
        // 太久没见过（关机多日）、从未见过、或计数器被清零过：退回当前值
        XCTAssertEqual(F50ResponseParser.dailyBaseline(current: 5_000, lastSeen: 4_200, lastSeenAge: 40 * 3600), 5_000)
        XCTAssertEqual(F50ResponseParser.dailyBaseline(current: 5_000, lastSeen: 0, lastSeenAge: 60), 5_000)
        XCTAssertEqual(F50ResponseParser.dailyBaseline(current: 100, lastSeen: 4_200, lastSeenAge: 60), 100)
    }

    func testTemperatureSkipsEmptyKeysAndReadsCpuTemperature() {
        // F50 Pro B22：其他温度键都返回空串，只有 cpu_temperature 有值
        var status = F50Status()
        status.mergeHardwareMetrics(from: [
            "cpu_temp": "", "temperature": "", "ic_temp": "", "internal_temperature": "",
            "cpu_temperature": "38"
        ])
        XCTAssertEqual(status.temperature, 38)
    }

    func testParsesADBShellHardwareMetrics() {
        let first = """
        battery:32000
        soc-thmzone:61190
        nr0-thmzone:58000
        cpu 1000 0 500 8000 500 0 0 0 0 0
        MemTotal:        2000000 kB
        MemFree:          200000 kB
        MemAvailable:     500000 kB
        """
        let r1 = F50ResponseParser.parseLinuxShellMetrics(first, previousCPU: nil)
        XCTAssertNil(r1.metrics["cpu_utility"], "首轮没有上一次采样，不能算占用率")
        XCTAssertEqual(r1.metrics["mem_utility"] as? Double ?? 0, 75.0, accuracy: 0.01)
        XCTAssertEqual(r1.metrics["cpu_temp"] as? Double ?? 0, 61.19, accuracy: 0.01)
        XCTAssertEqual(r1.cpu?.total, 10_000)

        // 第二轮：总量 +1000，其中 idle+iowait +600 → 占用 40%
        let r2 = F50ResponseParser.parseLinuxShellMetrics("cpu 1300 0 600 8500 600 0 0 0 0 0", previousCPU: r1.cpu)
        XCTAssertEqual(r2.metrics["cpu_utility"] as? Double ?? 0, 40.0, accuracy: 0.01)

        // 无 MemAvailable 的旧内核：Free + Buffers + Cached
        let legacy = F50ResponseParser.parseLinuxShellMetrics("MemTotal: 1000 kB\nMemFree: 100 kB\nBuffers: 50 kB\nCached: 150 kB", previousCPU: nil)
        XCTAssertEqual(legacy.metrics["mem_utility"] as? Double ?? 0, 70.0, accuracy: 0.01)
    }

    func testMobileDataStateFromRawPppStatus() {
        var status = F50Status()

        for raw in ["ipv4_ipv6_connected", "ppp_connected", "ipv6_connected", " PPP_Connected ", "connected", "1"] {
            status.rawPppStatus = raw
            XCTAssertTrue(status.isMobileDataOn, raw)
            XCTAssertFalse(status.isMobileDataTransitioning, raw)
        }

        for raw in ["ppp_disconnected", "disconnected", "0", ""] {
            status.rawPppStatus = raw
            XCTAssertFalse(status.isMobileDataOn, raw)
            XCTAssertFalse(status.isMobileDataTransitioning, raw)
        }

        for raw in ["ppp_connecting", "ppp_disconnecting"] {
            status.rawPppStatus = raw
            XCTAssertFalse(status.isMobileDataOn, raw)
            XCTAssertTrue(status.isMobileDataTransitioning, raw)
        }
    }

    // 以下两个向量由 F50 Pro B22 固件自带的 js/util.js（SHA256 输出大写十六进制）在 node 中生成。
    // 内层哈希必须保持大写再拼接，否则路由器会判为密码错误，几次后锁定账户。
    func testLoginPasswordHashMatchesRouterFirmwareVector() {
        XCTAssertEqual(
            F50ResponseParser.loginPasswordHash(password: "admin", ld: "A1B2C3D4E5F6"),
            "46D47EC11BDFAF8241C5A2AD5B5A13718A10B2CED7AD10ED391F77BCB34A4A15"
        )
    }

    func testAuthADMatchesRouterFirmwareVector() {
        XCTAssertEqual(
            F50ResponseParser.authAD(
                waInnerVersion: "F50ProV1.0.0B22",
                crVersion: "MU3356V1.0.0B22",
                rd: "1sck80ax2cuc37yr8bf50otdc"
            ),
            "0E4721FDDFD7441E6669DB527D4631559B009B1ACD10228C2B5DD154CB2B9164"
        )
    }

    func testLoginResultParsing() {
        // result 为字符串："0"/"4" 成功；"1" 失败、"2" 重复登录、"3" 密码错误
        XCTAssertTrue(F50ResponseParser.isLoginSuccess(Data(#"{"result":"0"}"#.utf8)))
        XCTAssertTrue(F50ResponseParser.isLoginSuccess(Data(#"{"result":"4"}"#.utf8)))
        XCTAssertTrue(F50ResponseParser.isLoginSuccess(Data(#"{"result":0}"#.utf8)))
        XCTAssertFalse(F50ResponseParser.isLoginSuccess(Data(#"{"result":"3"}"#.utf8)))
        XCTAssertFalse(F50ResponseParser.isLoginSuccess(Data(#"{"result":"1"}"#.utf8)))
        XCTAssertFalse(F50ResponseParser.isLoginSuccess(Data()))
    }

    func testLoginIsOnlyAttemptedWithAmpleRemainingTries() {
        // psw_fail_num_str 是「剩余可尝试次数」，login_lock_time 是锁定剩余秒数
        XCTAssertTrue(F50ResponseParser.isLoginAttemptSafe(["psw_fail_num_str": "5", "login_lock_time": "0"]))
        XCTAssertTrue(F50ResponseParser.isLoginAttemptSafe(["psw_fail_num_str": "", "login_lock_time": ""]))
        XCTAssertFalse(F50ResponseParser.isLoginAttemptSafe(["psw_fail_num_str": "2", "login_lock_time": "0"]))
        XCTAssertFalse(F50ResponseParser.isLoginAttemptSafe(["psw_fail_num_str": "0", "login_lock_time": "247"]))
        XCTAssertFalse(F50ResponseParser.isLoginAttemptSafe(["psw_fail_num_str": "5", "login_lock_time": "120"]))
    }

    func testMobileDataRequestBody() {
        XCTAssertEqual(
            F50ResponseParser.buildMobileDataRequestBody(enabled: true, ad: "AD1"),
            "isTest=false&goformId=CONNECT_NETWORK&notCallback=true&AD=AD1"
        )
        XCTAssertEqual(
            F50ResponseParser.buildMobileDataRequestBody(enabled: false, ad: "AD2"),
            "isTest=false&goformId=DISCONNECT_NETWORK&notCallback=true&AD=AD2"
        )
    }

    func testGoformSetSuccessDetection() {
        XCTAssertTrue(F50ResponseParser.isGoformSetSuccess(Data(#"{"result":"success"}"#.utf8)))
        XCTAssertFalse(F50ResponseParser.isGoformSetSuccess(Data(#"{"result":"failure"}"#.utf8)))
        XCTAssertFalse(F50ResponseParser.isGoformSetSuccess(Data()))
    }
}
