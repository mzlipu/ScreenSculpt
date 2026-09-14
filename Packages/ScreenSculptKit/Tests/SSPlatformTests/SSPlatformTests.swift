// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Testing

@testable import SSPlatform

@Suite("SSPlatform")
struct SSPlatformTests {
    @Test("Module is linked and reachable")
    func placeholder() {
        #expect(SSPlatform.moduleName == "SSPlatform")
    }
}
