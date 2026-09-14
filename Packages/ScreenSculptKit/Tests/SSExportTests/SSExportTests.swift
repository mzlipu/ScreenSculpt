// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Testing

@testable import SSExport

@Suite("SSExport")
struct SSExportTests {
    @Test("Module is linked and reachable")
    func placeholder() {
        #expect(SSExport.moduleName == "SSExport")
    }
}
