import CoreGraphics

/// Maps a horizontal drag translation to a month step for the Goals screen: +1 (swipe left → next month),
/// -1 (swipe right → previous), or nil when the swipe is too small or too vertical (so the List keeps
/// scrolling). Pure, so it's unit-testable without a gesture.
enum MonthSwipe {
    static func step(_ translation: CGSize, threshold: CGFloat = 60) -> Int? {
        guard abs(translation.width) > threshold,
              abs(translation.width) > abs(translation.height) * 1.5 else { return nil }
        return translation.width < 0 ? 1 : -1
    }
}
