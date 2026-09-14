// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Testing

@testable import SSAnnotations

@Suite("SSAnnotations")
struct SSAnnotationsTests {
    @Test("Module is linked and reachable")
    func placeholder() {
        #expect(SSAnnotations.moduleName == "SSAnnotations")
    }
}
