import CoreGraphics
import Foundation

// x1 y1 x2 y2 in global display coordinates.
let a = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard a.count == 4 else { print("need 4 numbers"); exit(1) }
let from = CGPoint(x: a[0], y: a[1]), to = CGPoint(x: a[2], y: a[3])

func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p,
            mouseButton: .left)?.post(tap: .cghidEventTap)
}
CGWarpMouseCursorPosition(from)
usleep(150_000)
post(.leftMouseDown, from)
let steps = 24
for i in 1...steps {
    let t = Double(i) / Double(steps)
    post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t,
                                    y: from.y + (to.y - from.y) * t))
    usleep(18_000)
}
usleep(120_000)
post(.leftMouseUp, to)
print("dragged \(from) → \(to)")
