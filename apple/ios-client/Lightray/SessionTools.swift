import LightrayCore
import SwiftUI

/// The session's controls, in a floating Liquid Glass button that expands into a list. Drag the
/// button to another corner when it covers something on the remote display.
struct SessionTools: View {
    static let cornerKey = "sessionToolsCorner"

    enum Corner: String {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        init(top: Bool, leading: Bool) {
            switch (top, leading) {
            case (true, true): self = .topLeading
            case (true, false): self = .topTrailing
            case (false, true): self = .bottomLeading
            case (false, false): self = .bottomTrailing
            }
        }

        var isTop: Bool { self == .topLeading || self == .topTrailing }
        var isLeading: Bool { self == .topLeading || self == .bottomLeading }

        var alignment: Alignment {
            switch self {
            case .topLeading: .topLeading
            case .topTrailing: .topTrailing
            case .bottomLeading: .bottomLeading
            case .bottomTrailing: .bottomTrailing
            }
        }
    }

    private enum Tool: Hashable { case keyboard, displays, wholeDisplay, more, disconnect }

    @Bindable var session: ClientSession
    @Binding var expanded: Bool
    @Binding var showingKeyboard: Bool
    var keyboardAvailable: Bool
    var isZoomed: Bool
    var resetZoom: () -> Void

    @AppStorage(SessionTools.cornerKey) private var corner = Corner.topTrailing
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var dragOffset = CGSize.zero
    @Namespace private var glass
    private static let space = "sessionTools"

    var body: some View {
        GeometryReader { proxy in
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    // The list grows away from the corner, so the main button stays in it.
                    if corner.isTop { mainButton(in: proxy.size) }
                    if expanded {
                        ForEach(corner.isTop ? tools : tools.reversed(), id: \.self, content: view(for:))
                    }
                    if !corner.isTop { mainButton(in: proxy.size) }
                }
            }
            .tint(.primary)
            .padding(16)
            .offset(dragOffset)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: corner.alignment)
        }
        .coordinateSpace(.named(Self.space))
    }

    private var tools: [Tool] {
        isZoomed ? [.keyboard, .displays, .wholeDisplay, .more, .disconnect]
                 : [.keyboard, .displays, .more, .disconnect]
    }

    private func mainButton(in size: CGSize) -> some View {
        Button {
            withAnimation(.bouncy) { expanded.toggle() }
        } label: {
            icon(expanded ? "Hide session tools" : "Session tools", systemImage: expanded ? "xmark" : "ellipsis")
        }
        .buttonStyle(.plain)
        .glass(id: "main", in: glass)
        .highPriorityGesture(move(in: size))
        .help("Session tools")
        .accessibilityIdentifier("sessionTools")
    }

    /// Drags the button and lets it settle in the nearest corner, which is remembered.
    private func move(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.space))
            .onChanged { dragOffset = $0.translation }
            .onEnded { value in
                let end = value.predictedEndLocation
                let left = end.x < size.width / 2
                withAnimation(.bouncy) {
                    corner = Corner(top: end.y < size.height / 2, leading: left == (layoutDirection == .leftToRight))
                    dragOffset = .zero
                }
            }
    }

    @ViewBuilder
    private func view(for tool: Tool) -> some View {
        switch tool {
        case .keyboard:
            toolButton(showingKeyboard ? "Hide keyboard" : "Show keyboard",
                       systemImage: showingKeyboard ? "keyboard.chevron.compact.down" : "keyboard", id: tool) {
                showingKeyboard.toggle()
            }
            .disabled(!keyboardAvailable)
            .accessibilityIdentifier("toggleKeyboard")
        case .displays:
            Menu {
                ForEach(session.displays, id: \.id) { display in
                    Button {
                        session.selectDisplay(display.id)
                        collapse()
                    } label: {
                        Label("\(display.name) · \(display.width) × \(display.height)",
                              systemImage: session.selectedDisplay == display.id ? "checkmark" : "display")
                    }
                }
            } label: {
                icon("Displays", systemImage: "display.2")
            }
            .disabled(session.displays.isEmpty || session.phase != .connected)
            .glass(id: tool, in: glass)
            .help("Displays")
        case .wholeDisplay:
            toolButton("Show whole display", systemImage: "arrow.down.right.and.arrow.up.left", id: tool) {
                resetZoom()
            }
        case .more:
            Menu {
                Section(session.activeHost?.name ?? "Session") {
                    Toggle("Statistics", systemImage: "chart.bar", isOn: $session.showStatistics)
                    Toggle("Control computer", systemImage: "cursorarrow", isOn: $session.inputEnabled)
                }
                Section {
                    Button("Send Escape") { session.sendKey(0x29); collapse() }
                        .disabled(!session.canSendInput)
                    Button("Send Tab") { session.sendKey(0x2B); collapse() }
                        .disabled(!session.canSendInput)
                    Button("Release all keys", systemImage: "keyboard") { session.releaseInput(); collapse() }
                    Button("Reconnect", systemImage: "arrow.clockwise") { session.reconnect(); collapse() }
                }
            } label: {
                icon("Session", systemImage: "slider.horizontal.3")
            }
            .glass(id: tool, in: glass)
            .help("Session")
        case .disconnect:
            toolButton("Disconnect", systemImage: "power", id: tool) { session.disconnect() }
                .foregroundStyle(.red)
        }
    }

    private func toolButton(_ title: String, systemImage: String, id: Tool,
                            action: @escaping () -> Void) -> some View {
        Button {
            action()
            collapse()
        } label: {
            icon(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .glass(id: id, in: glass)
        .help(title)
    }

    private func icon(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.title3.weight(.medium))
            .frame(width: 48, height: 48)
            .contentShape(.circle)
    }

    private func collapse() {
        withAnimation(.bouncy) { expanded = false }
    }
}

private extension View {
    func glass(id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View {
        glassEffect(.regular.interactive(), in: .circle)
            .glassEffectID(id, in: namespace)
    }
}
