// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Testing

@testable import SSImaging

@Suite("SSImaging")
struct SSImagingTests {
    @Test("Module is linked and reachable")
    func placeholder() {
        #expect(SSImaging.moduleName == "SSImaging")
    }
}
