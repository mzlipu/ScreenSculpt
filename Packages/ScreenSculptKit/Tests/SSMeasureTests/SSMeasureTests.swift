// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Testing

@testable import SSMeasure

@Suite("SSMeasure")
struct SSMeasureTests {
    @Test("Module is linked and reachable")
    func placeholder() {
        #expect(SSMeasure.moduleName == "SSMeasure")
    }
}
