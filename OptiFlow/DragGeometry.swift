// OptiFlow — VonKleistL
import Foundation

struct DragGeometry: Sendable {
    let initialFrame: CGRect
    let initialCursor: CGPoint
    let resizing: Bool
    let left: Bool
    let right: Bool
    let top: Bool
    let bottom: Bool

    init(frame: CGRect, cursor: CGPoint, resizing: Bool) {
        initialFrame = frame
        initialCursor = cursor
        self.resizing = resizing
        left = resizing && cursor.x < frame.minX + frame.width / 3
        right = resizing && cursor.x > frame.minX + 2 * frame.width / 3
        top = resizing && cursor.y < frame.minY + frame.height / 3
        bottom = resizing && cursor.y > frame.minY + 2 * frame.height / 3
    }

    func frame(at cursor: CGPoint) -> CGRect {
        let dx = cursor.x - initialCursor.x, dy = cursor.y - initialCursor.y
        var result = initialFrame
        if !resizing { return result.offsetBy(dx: dx, dy: dy) }
        if left {
            result.size.width = max(1, initialFrame.width - dx)
            result.origin.x = initialFrame.maxX - result.width
        } else if right { result.size.width = max(1, initialFrame.width + dx) }
        if top {
            result.size.height = max(1, initialFrame.height - dy)
            result.origin.y = initialFrame.maxY - result.height
        } else if bottom { result.size.height = max(1, initialFrame.height + dy) }
        return result
    }
}
