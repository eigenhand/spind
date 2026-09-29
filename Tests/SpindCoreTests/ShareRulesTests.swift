// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import SpindCore

final class ShareRulesTests: XCTestCase {
    private let noon = Date(timeIntervalSince1970: 1_758_456_000) // 2025-09-21 12:00 UTC

    func testExpiryIsStartOfDayAfterValidity() {
        let expiry = ShareRules.expiry(validFor: 30, from: noon)
        XCTAssertEqual(ShareRules.labels(expiresOn: expiry), ["spind-expires-on": "2025-10-21"])
        XCTAssertEqual(expiry, Date(timeIntervalSince1970: 1_761_004_800)) // 2025-10-21 00:00 UTC
        XCTAssertNil(ShareRules.expiry(validFor: nil, from: noon))
    }

    func testLabelRoundTrip() {
        let expiry = ShareRules.expiry(validFor: 90, from: noon)
        let labels = ShareRules.labels(expiresOn: expiry)
        XCTAssertEqual(ShareRules.expiryDate(fromLabels: labels), expiry)
        XCTAssertNil(ShareRules.expiryDate(fromLabels: [:]))
        XCTAssertNil(ShareRules.expiryDate(fromLabels: ["spind-expires-on": "someday"]))
        XCTAssertEqual(ShareRules.labels(expiresOn: nil), [:])
    }

    func testExpiredExactlyAtStartOfDay() {
        let expiry = ShareRules.expiry(validFor: 1, from: noon)!
        XCTAssertFalse(ShareRules.isExpired(expiry, now: expiry.addingTimeInterval(-1)))
        XCTAssertTrue(ShareRules.isExpired(expiry, now: expiry))
        XCTAssertFalse(ShareRules.isExpired(nil, now: .distantFuture))
    }

    func testReSharingOnlyExtends() {
        let sooner = ShareRules.expiry(validFor: 30, from: noon)
        let later = ShareRules.expiry(validFor: 90, from: noon)
        XCTAssertEqual(ShareRules.extended(current: later, requested: sooner), later)
        XCTAssertEqual(ShareRules.extended(current: sooner, requested: later), later)
        XCTAssertNil(ShareRules.extended(current: nil, requested: sooner))
        XCTAssertNil(ShareRules.extended(current: sooner, requested: nil))
    }

    func testRemainingSlots() {
        XCTAssertEqual(ShareRules.remainingSlots(used: 0), 100)
        XCTAssertEqual(ShareRules.remainingSlots(used: 99), 1)
        XCTAssertEqual(ShareRules.remainingSlots(used: 100), 0)
        XCTAssertEqual(ShareRules.remainingSlots(used: 130), 0)
    }

    func testCredentialsFromSharePage() {
        let encoded = Data("u123456-sub7:Ab.c-D3fgh~ijKLm".utf8).base64EncodedString()
        let html = "<script>\nlet x = 1;\nconst AUTH = \"Basic \(encoded)\";\nconst y = 2;</script>"
        let found = ShareRules.credentials(fromSharePage: html)
        XCTAssertEqual(found?.username, "u123456-sub7")
        XCTAssertEqual(found?.password, "Ab.c-D3fgh~ijKLm")
    }

    func testCredentialsAbsentOrBroken() {
        XCTAssertNil(ShareRules.credentials(fromSharePage: "const AUTH = \"\";"))
        XCTAssertNil(ShareRules.credentials(fromSharePage: "const AUTH = \"Basic !!!\";"))
        let noColon = Data("justauser".utf8).base64EncodedString()
        XCTAssertNil(ShareRules.credentials(fromSharePage: "const AUTH = \"Basic \(noColon)\";"))
    }
}
