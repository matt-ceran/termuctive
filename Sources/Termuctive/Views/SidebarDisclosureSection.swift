import SwiftUI

enum SidebarMotion {
    static let panelDuration: TimeInterval = 0.22

    static var disclosure: Animation {
        .smooth(duration: 0.2)
    }

    static var panel: Animation {
        .smooth(duration: panelDuration)
    }
}

struct SidebarDisclosureSection<Content: View>: View {
    let isExpanded: Bool
    private let content: Content

    @State private var measuredHeight: CGFloat = 0

    init(
        isExpanded: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: SidebarDisclosureHeightKey.self,
                        value: geometry.size.height
                    )
                }
            }
            .frame(
                height: isExpanded ? measuredHeight : 0,
                alignment: .top
            )
            .clipped()
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
            .onPreferenceChange(SidebarDisclosureHeightKey.self) { height in
                measuredHeight = height
            }
    }
}

private struct SidebarDisclosureHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
