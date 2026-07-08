import SwiftUI

/// Defers building `Content` until the view is actually rendered. A `List`'s closure-based
/// `NavigationLink { Destination() }` eagerly constructs every row's destination on each render; when the
/// destination is heavy (e.g. carries `@Query`), building N of them per render churns SwiftData
/// observation and can spin the main thread in an infinite re-render loop. Wrapping the destination in
/// `LazyView` builds it only when navigated to.
struct LazyView<Content: View>: View {
    private let build: () -> Content
    init(_ build: @autoclosure @escaping () -> Content) { self.build = build }
    var body: Content { build() }
}
