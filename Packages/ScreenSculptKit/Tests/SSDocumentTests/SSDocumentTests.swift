// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Testing

@testable import SSDocument

@Suite("SSDocument")
struct SSDocumentTests {
    @Test("Module is linked and reachable")
    func placeholder() {
        #expect(SSDocument.moduleName == "SSDocument")
    }
}
