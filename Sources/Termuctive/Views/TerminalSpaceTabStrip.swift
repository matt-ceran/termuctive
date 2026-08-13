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
                    if let note = store.selectedNote,
                        let project = store.selectedProject
                    {
                        selectedNoteContext(note: note, project: project)
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
                        store.selectedNote == nil
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
            .onDrop(
                of: [.termuctiveTerminalSpace],
                delegate: TerminalSpaceDropDelegate(
                    store: store,
                    anchorID: nil,
                    nextAnchorID: nil,
                    targetWidth: nil,
                    isTargeted: $isDropTargeted,
                    dropEdge: nil
                )
            )
            .onAppear {
                scrollToSelectedTab(using: proxy, animated: false)
            }
            .onChange(of: store.document.selectedSpaceID) { _, _ in
                scrollToSelectedTab(using: proxy, animated: !reduceMotion)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal tabs")
    }

    private func selectedNoteContext(
        note: ProjectNote,
        project: TerminalProject
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "note.text")
                .font(.system(size: 10.5, weight: .medium))
            Text("\(project.name) / \(note.name)")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 9)
        .frame(minWidth: 112, idealWidth: 176, maxWidth: 220, minHeight: 30)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 1)
                .padding(.horizontal, 6)
        }
        .help("\(project.name) / \(note.name)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(note.name), project note in \(project.name)")
        .accessibilityAddTraits(.isSelected)
    }

    private func scrollToSelectedTab(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let selectedSpaceID = store.document.selectedSpaceID else {
            return
        }
        if animated {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(selectedSpaceID, anchor: .center)
            }
        } else {
            proxy.scrollTo(selectedSpaceID, anchor: .center)
        }
    }
}

private struct TerminalSpaceTab: View {
    let tab: TerminalSpaceTabDescriptor
    @ObservedObject var store: WorkspaceStore
    let agentActivity: AgentActivityRegistry
    let selectTab: (UUID) -> Void

    @State private var isHovered = false
    @State private var isDropTargeted = false
    @State private var dropEdge: HorizontalEdge?

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
                HStack(spacing: 0) {
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
                }
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
                .overlay(alignment: dropEdge == .trailing ? .trailing : .leading) {
                    if isDropTargeted {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2, height: 24)
                    }
                }
                .onHover { isHovered = $0 }
                .draggable(TerminalSpaceDragPayload(spaceID: tab.id, origin: .tab)) {
                    dragPreview
                }
                .onDrop(
                    of: [.termuctiveTerminalSpace],
                    delegate: TerminalSpaceDropDelegate(
                        store: store,
                        anchorID: tab.id,
                        nextAnchorID: nextTabID(after: tab.id),
                        targetWidth: geometry.size.width,
                        isTargeted: $isDropTargeted,
                        dropEdge: $dropEdge
                    )
                )
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
                        Color(nsColor: .separatorColor).opacity(isSelected ? 0.7 : 0.35),
                        lineWidth: 1
                    )
            }
    }

    private var dragPreview: some View {
        Label(tab.spaceName, systemImage: "rectangle")
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }

    private func nextTabID(after id: UUID) -> UUID? {
        guard let index = store.document.openTerminalSpaceIDs.firstIndex(of: id),
            index + 1 < store.document.openTerminalSpaceIDs.count
        else {
            return nil
        }
        return store.document.openTerminalSpaceIDs[index + 1]
    }
}

private struct TerminalSpaceDropDelegate: DropDelegate {
    let store: WorkspaceStore
    let anchorID: UUID?
    let nextAnchorID: UUID?
    let targetWidth: CGFloat?
    @Binding var isTargeted: Bool
    let dropEdge: Binding<HorizontalEdge?>?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.termuctiveTerminalSpace])
    }

    func dropEntered(info: DropInfo) {
        updateTarget(for: info)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        dropEdge?.wrappedValue = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateTarget(for: info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        dropEdge?.wrappedValue = nil
        guard let provider = info.itemProviders(for: [.termuctiveTerminalSpace]).first else {
            return false
        }
        let resolvedAnchorID: UUID?
        if let targetWidth,
            info.location.x > targetWidth / 2
        {
            resolvedAnchorID = nextAnchorID
        } else {
            resolvedAnchorID = anchorID
        }

        _ = provider.loadTransferable(type: TerminalSpaceDragPayload.self) { result in
            guard case .success(let payload) = result else {
                return
            }
            Task { @MainActor in
                guard store.document.space(withID: payload.spaceID) != nil else {
                    return
                }
                if payload.origin == .tab,
                    store.document.openTerminalSpaceIDs.contains(payload.spaceID)
                {
                    store.reorderTerminalSpaceTab(
                        withID: payload.spaceID,
                        before: resolvedAnchorID
                    )
                } else {
                    store.placeTerminalSpaceTab(
                        withID: payload.spaceID,
                        before: resolvedAnchorID
                    )
                }
            }
        }
        return true
    }

    private func updateTarget(for info: DropInfo) {
        isTargeted = true
        guard let targetWidth else {
            dropEdge?.wrappedValue = nil
            return
        }
        dropEdge?.wrappedValue = info.location.x > targetWidth / 2 ? .trailing : .leading
    }
}
