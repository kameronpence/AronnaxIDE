import SwiftUI

/// Orientation of a workspace split.
enum SplitAxis {
    case horizontal   // panes side by side (second pane on the right)
    case vertical     // panes stacked (second pane on the bottom)
}

/// A two-pane split laid out with pure SwiftUI — deliberately NOT AppKit's
/// `HSplitView` / `VSplitView` (`NSSplitView`), which froze the app when the second
/// pane was removed live. The primary pane is always present and keeps its identity
/// whether or not the secondary is shown, so toggling the split never tears down the
/// live primary session. A draggable divider resizes the two panes.
struct SplitContainer<Primary: View, Secondary: View>: View {
    let axis: SplitAxis
    let showsSecondary: Bool
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var secondary: () -> Secondary

    @State private var fraction: CGFloat = 0.6
    @State private var dragStart: CGFloat?

    private let dividerThickness: CGFloat = 8
    private let minFraction: CGFloat = 0.2
    private let maxFraction: CGFloat = 0.8

    var body: some View {
        GeometryReader { geo in
            let isH = axis == .horizontal
            let total = isH ? geo.size.width : geo.size.height
            let usable = max(total - dividerThickness, 1)
            let clamped = min(max(fraction, minFraction), maxFraction)
            let primaryExtent = showsSecondary ? usable * clamped : total

            // AnyLayout swaps the H/V arrangement while keeping the SAME child views,
            // so switching orientation doesn't tear down (and reconnect) the live panes.
            let layout = isH ? AnyLayout(HStackLayout(spacing: 0))
                             : AnyLayout(VStackLayout(spacing: 0))
            layout {
                primary()
                    .frame(width: isH ? primaryExtent : nil,
                           height: isH ? nil : primaryExtent)
                if showsSecondary {
                    divider(isHorizontal: isH, usable: usable)
                    secondary()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// A 1pt visible line inside a thicker transparent hit area, draggable to resize.
    private func divider(isHorizontal: Bool, usable: CGFloat) -> some View {
        Color.clear
            .frame(width: isHorizontal ? dividerThickness : nil,
                   height: isHorizontal ? nil : dividerThickness)
            .overlay(
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: isHorizontal ? 1 : nil,
                           height: isHorizontal ? nil : 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = dragStart ?? fraction
                        if dragStart == nil { dragStart = fraction }
                        let move = isHorizontal ? value.translation.width : value.translation.height
                        fraction = min(max(start + move / usable, minFraction), maxFraction)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}
