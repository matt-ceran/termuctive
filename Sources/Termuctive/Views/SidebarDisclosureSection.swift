import SwiftUI

enum SidebarMotion {
    static let panelDuration: TimeInterval = 0.22

    static var disclosure: Animation {
        .smooth(duration: 0.2)
    }

    static var panel: Animation {
        .smooth(duration: panelDuration)
    }

    @MainActor
    static func setSidebarVisible(
        _ isVisible: Bool,
        store: WorkspaceStore,
        sessions: TerminalSessionPool
    ) {
        guard store.isSidebarVisible != isVisible else {
            return
        }
        let transitionID = sessions.beginAnimatedLayoutTransition()
        withAnimation(panel, completionCriteria: .logicallyComplete) {
            store.isSidebarVisible = isVisible
        } completion: {
            sessions.finishAnimatedLayoutTransition(transitionID)
        }
    }
}

struct SidebarDisclosureSection<Content: View>: View {
    let isExpanded: Bool
    let contentHeight: CGFloat
    private let content: Content

    init(
        isExpanded: Bool,
        contentHeight: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.isExpanded = isExpanded
        self.contentHeight = contentHeight
        self.content = content()
    }

    var body: some View {
        Group {
            if isExpanded {
                content
                    .modifier(
                        SidebarDisclosureHeightModifier(
                            height: contentHeight
                        )
                    )
                    .transition(
                        .modifier(
                            active: SidebarDisclosureHeightModifier(height: 0),
                            identity: SidebarDisclosureHeightModifier(
                                height: contentHeight
                            )
                        )
                    )
            }
        }
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
    }
}

private struct SidebarDisclosureHeightModifier: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(height: max(height, 0), alignment: .top)
            .clipped()
    }
}
