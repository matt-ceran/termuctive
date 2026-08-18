import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let termuctiveTerminalSpace = UTType(
        exportedAs: "com.mattceran.termuctive.terminal-space",
        conformingTo: .data
    )
}

struct TerminalSpaceDragPayload: Codable, Hashable, Transferable {
    enum Origin: String, Codable {
        case sidebar
        case tab
    }

    let spaceID: UUID
    let origin: Origin

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .termuctiveTerminalSpace)
    }
}

enum TerminalSpaceTabDropPlacement {
    static func anchorID(
        leading anchorID: UUID,
        trailing nextAnchorID: UUID?,
        locationX: CGFloat,
        targetWidth: CGFloat
    ) -> UUID? {
        locationX > targetWidth / 2 ? nextAnchorID : anchorID
    }
}

struct TerminalSpaceTabStrip: View {
    @ObservedObject var store: WorkspaceStore
    let agentActivity: AgentActivityRegistry
    let selectTab: (UUID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 3) {
                    ForEach(store.openNoteTabs) { tab in
                        NoteSpaceTab(tab: tab, store: store)
                            .id(tab.id)
                    }

                    ForEach(store.openTerminalSpaceTabs) { tab in
                        TerminalSpaceTab(
                            tab: tab,
                            store: store,
                            agentActivity: agentActivity,
                            selectTab: selectTab
                        )
                        .id(tab.id)
                    }

                    if store.openTerminalSpaceTabs.isEmpty,
                        store.openNoteTabs.isEmpty
                    {
                        Text(isDropTargeted ? "Drop terminal space here" : "No terminal tabs open")
                            .font(.system(size: 11))
                            .foregroundStyle(isDropTargeted ? .secondary : .tertiary)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 2)
                .frame(height: 34)
            }
            .scrollIndicators(.hidden)
            .contentShape(Rectangle())
            .dropDestination(for: TerminalSpaceDragPayload.self) { payloads, _ in
                guard let payload = payloads.first else {
                    return false
                }
                isDropTargeted = false
                return place(payload, before: nil)
            } isTargeted: {
                isDropTargeted = $0
            }
            .onAppear {
                scrollToSelectedTab(using: proxy, animated: false)
            }
            .onChange(of: store.document.selectedSpaceID) { _, _ in
                scrollToSelectedTab(using: proxy, animated: !reduceMotion)
            }
            .onChange(of: store.document.selectedItemID) { _, _ in
                scrollToSelectedTab(using: proxy, animated: !reduceMotion)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace tabs")
    }

    private func scrollToSelectedTab(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let selectedItemID = store.document.selectedItemID,
            store.document.openTerminalSpaceIDs.contains(selectedItemID)
                || store.document.openNoteIDs.contains(selectedItemID)
        else {
            return
        }
        if animated {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(selectedItemID, anchor: .center)
            }
        } else {
            proxy.scrollTo(selectedItemID, anchor: .center)
        }
    }

    private func place(_ payload: TerminalSpaceDragPayload, before anchorID: UUID?) -> Bool {
        guard store.document.space(withID: payload.spaceID) != nil else {
            return false
        }
        let update = {
            if payload.origin == .tab,
                store.document.openTerminalSpaceIDs.contains(payload.spaceID)
            {
                store.reorderTerminalSpaceTab(withID: payload.spaceID, before: anchorID)
            } else {
                store.placeTerminalSpaceTab(withID: payload.spaceID, before: anchorID)
            }
        }
        if reduceMotion {
            update()
        } else {
            withAnimation(.snappy(duration: 0.2), update)
        }
        return true
    }
}

private struct NoteSpaceTab: View {
    let tab: NoteSpaceTabDescriptor
    @ObservedObject var store: WorkspaceStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isDropTargeted = false

    private var isSelected: Bool {
        store.document.selectedNote?.id == tab.id
    }

    private var tabWidth: CGFloat {
        let characterCount = tab.projectName.count + tab.noteName.count + 3
        return min(max(CGFloat(characterCount) * 5.5 + 54, 112), 220)
    }

    var body: some View {
        GeometryReader { geometry in
            Button {
                store.selectNoteTab(withID: tab.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "note.text")
                        .font(.system(size: 10.5, weight: .medium))
                        .frame(width: 12)
                    Text("\(tab.projectName) / \(tab.noteName)")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear
                        .frame(width: 20, height: 20)
                }
                .padding(.leading, 8)
                .padding(.trailing, 5)
                .frame(width: geometry.size.width, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(tabBackground)
            .overlay(alignment: .trailing) {
                Button {
                    store.closeNoteTab(withID: tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(isSelected || isHovered ? 1 : 0)
                .allowsHitTesting(isSelected || isHovered)
                .padding(.trailing, 5)
                .help("Close tab - note stays saved")
                .accessibilityLabel("Close \(tab.noteName) tab")
            }
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 1)
                        .padding(.horizontal, 6)
                }
            }
            .scaleEffect(isDropTargeted && !reduceMotion ? 1.015 : 1)
            .shadow(
                color: Color.accentColor.opacity(isDropTargeted ? 0.22 : 0),
                radius: isDropTargeted ? 5 : 0
            )
            .onHover { isHovered = $0 }
            .dropDestination(for: TerminalSpaceDragPayload.self) { payloads, _ in
                guard let payload = payloads.first else {
                    return false
                }
                isDropTargeted = false
                return placeTerminalTab(payload, before: store.document.openTerminalSpaceIDs.first)
            } isTargeted: {
                isDropTargeted = $0
            }
            .contextMenu {
                Button("Close Tab") {
                    store.closeNoteTab(withID: tab.id)
                }
            }
            .help(tab.path)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(tab.noteName), note tab in \(tab.projectName)")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
        .frame(width: tabWidth, height: 30)
    }

    private var tabBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(
                isSelected
                    ? Color(nsColor: .textBackgroundColor)
                    : Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.9 : 0.48)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        isDropTargeted
                            ? Color.accentColor.opacity(0.9)
                            : Color(nsColor: .separatorColor).opacity(isSelected ? 0.7 : 0.35),
                        lineWidth: isDropTargeted ? 1.5 : 1
                    )
            }
    }

    private func placeTerminalTab(
        _ payload: TerminalSpaceDragPayload,
        before anchorID: UUID?
    ) -> Bool {
        guard store.document.space(withID: payload.spaceID) != nil else {
            return false
        }
        let update = {
            if payload.origin == .tab,
                store.document.openTerminalSpaceIDs.contains(payload.spaceID)
            {
                store.reorderTerminalSpaceTab(withID: payload.spaceID, before: anchorID)
            } else {
                store.placeTerminalSpaceTab(withID: payload.spaceID, before: anchorID)
            }
        }
        if reduceMotion {
            update()
        } else {
            withAnimation(.snappy(duration: 0.2), update)
        }
        return true
    }
}

private struct TerminalSpaceTab: View {
    let tab: TerminalSpaceTabDescriptor
    @ObservedObject var store: WorkspaceStore
    let agentActivity: AgentActivityRegistry
    let selectTab: (UUID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isDropTargeted = false

    private var isSelected: Bool {
        store.document.selectedSpaceID == tab.id
    }

    private var tabWidth: CGFloat {
        let characterCount = tab.projectName.count + tab.spaceName.count + 3
        return min(max(CGFloat(characterCount) * 5.5 + 64, 112), 220)
    }

    var body: some View {
        GeometryReader { geometry in
            AgentActivityAccessibleRow(
                registry: agentActivity,
                scope: .space(tab.id),
                isPresented: true
            ) {
                Button {
                    selectTab(tab.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle")
                            .font(.system(size: 10.5, weight: .medium))
                            .frame(width: 12)
                        Text("\(tab.projectName) / \(tab.spaceName)")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        AgentActivityStatusSlot(
                            registry: agentActivity,
                            scope: .space(tab.id),
                            isPresented: true,
                            isVisible: true,
                            selected: isSelected
                        )
                        .fixedSize()
                        .layoutPriority(1)
                        Color.clear
                            .frame(width: 20, height: 20)
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 5)
                    .frame(width: geometry.size.width, height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(tabBackground)
                .overlay(alignment: .trailing) {
                    Button {
                        store.closeTerminalSpaceTab(withID: tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(isSelected || isHovered ? 1 : 0)
                    .allowsHitTesting(isSelected || isHovered)
                    .padding(.trailing, 5)
                    .help("Close tab - terminal keeps running")
                    .accessibilityLabel("Close \(tab.spaceName) tab")
                }
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 1)
                            .padding(.horizontal, 6)
                    }
                }
                .scaleEffect(isDropTargeted && !reduceMotion ? 1.015 : 1)
                .shadow(
                    color: Color.accentColor.opacity(isDropTargeted ? 0.22 : 0),
                    radius: isDropTargeted ? 5 : 0
                )
                .onHover { isHovered = $0 }
                .draggable(TerminalSpaceDragPayload(spaceID: tab.id, origin: .tab)) {
                    dragPreview
                }
                .dropDestination(for: TerminalSpaceDragPayload.self) { payloads, location in
                    guard let payload = payloads.first else {
                        return false
                    }
                    let anchorID = TerminalSpaceTabDropPlacement.anchorID(
                        leading: tab.id,
                        trailing: nextTabID(after: tab.id),
                        locationX: location.x,
                        targetWidth: geometry.size.width
                    )
                    isDropTargeted = false
                    return place(payload, before: anchorID)
                } isTargeted: {
                    isDropTargeted = $0
                }
                .contextMenu {
                    Button("Close Tab") {
                        store.closeTerminalSpaceTab(withID: tab.id)
                    }
                    Divider()
                    Button("Move Left") {
                        store.moveTerminalSpaceTab(withID: tab.id, offset: -1)
                    }
                    .disabled(store.document.openTerminalSpaceIDs.first == tab.id)
                    Button("Move Right") {
                        store.moveTerminalSpaceTab(withID: tab.id, offset: 1)
                    }
                    .disabled(store.document.openTerminalSpaceIDs.last == tab.id)
                }
                .help(tab.path)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(tab.spaceName), terminal tab in \(tab.projectName)")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityAction(named: "Move Left") {
                    store.moveTerminalSpaceTab(withID: tab.id, offset: -1)
                }
                .accessibilityAction(named: "Move Right") {
                    store.moveTerminalSpaceTab(withID: tab.id, offset: 1)
                }
            }
        }
        .frame(width: tabWidth, height: 30)
    }

    private var tabBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(
                isSelected
                    ? Color(nsColor: .textBackgroundColor)
                    : Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.9 : 0.48)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        isDropTargeted
                            ? Color.accentColor.opacity(0.9)
                            : Color(nsColor: .separatorColor).opacity(isSelected ? 0.7 : 0.35),
                        lineWidth: isDropTargeted ? 1.5 : 1
                    )
            }
    }

    private var dragPreview: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle")
                .font(.system(size: 10.5, weight: .medium))
                .frame(width: 12)
            Text("\(tab.projectName) / \(tab.spaceName)")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(width: tabWidth, height: 30)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        }
    }

    private func nextTabID(after id: UUID) -> UUID? {
        guard let index = store.document.openTerminalSpaceIDs.firstIndex(of: id),
            index + 1 < store.document.openTerminalSpaceIDs.count
        else {
            return nil
        }
        return store.document.openTerminalSpaceIDs[index + 1]
    }

    private func place(_ payload: TerminalSpaceDragPayload, before anchorID: UUID?) -> Bool {
        guard store.document.space(withID: payload.spaceID) != nil else {
            return false
        }
        let update = {
            if payload.origin == .tab,
                store.document.openTerminalSpaceIDs.contains(payload.spaceID)
            {
                store.reorderTerminalSpaceTab(withID: payload.spaceID, before: anchorID)
            } else {
                store.placeTerminalSpaceTab(withID: payload.spaceID, before: anchorID)
            }
        }
        if reduceMotion {
            update()
        } else {
            withAnimation(.snappy(duration: 0.2), update)
        }
        return true
    }
}
