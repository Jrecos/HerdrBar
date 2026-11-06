import HerdrBarCore
import SwiftUI

@MainActor @Observable
final class PanelSelection {
    var selected: String?
    var hovered: String?

    func move(_ step: Int, in agents: [Agent]) {
        guard !agents.isEmpty else { return }
        if let index = agents.firstIndex(where: { $0.id == selected }) {
            selected = agents[(index + step + agents.count) % agents.count].id
        } else {
            selected = (step > 0 ? agents.first : agents.last)?.id
        }
    }
}

enum Layout {
    static let width: CGFloat = 540
    static let maxHeight: CGFloat = 640
    static let header: CGFloat = 50
    static let footer: CGFloat = 38
    static let listPadding: CGFloat = 12
    static let groupHeader: CGFloat = 24
    static let groupGap: CGFloat = 14
    static let row: CGFloat = 36
    static let message: CGFloat = 48

    static func height(for snapshot: Snapshot) -> CGFloat {
        let groups = snapshot.agents.grouped()
        var list: CGFloat = listPadding * 2
        if groups.isEmpty || snapshot.failure != nil {
            list += message
        }
        for (index, group) in groups.enumerated() {
            list += groupHeader + row * CGFloat(group.agents.count) + (index > 0 ? groupGap : 0)
        }
        return min(maxHeight, header + 1 + list + 1 + footer)
    }
}

struct PanelView: View {
    let store: AgentStore
    let selection: PanelSelection
    /// False in snapshot mode, where nothing may move and the clock must be deterministic.
    let animate: Bool
    let open: (Agent) -> Void
    let openHerdr: () -> Void
    let quit: () -> Void
    let now: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var motion: Bool { animate && !reduceMotion }
    private var snapshot: Snapshot { store.snapshot }
    private var changed: Set<String> { store.changed }
    private var focusFailure: String? { store.focusFailure }

    var body: some View {
        if motion {
            // Ages and the clock only need a coarse tick; spinners, pulses and the cursor own their own timelines.
            TimelineView(.periodic(from: .now, by: 15)) { context in
                content(at: context.date)
            }
        } else {
            content(at: now)
        }
    }

    private func content(at date: Date) -> some View {
        VStack(spacing: 0) {
            header(at: date)
            Rectangle().fill(Phosphor.border).frame(height: 1)
            list(at: date)
            Rectangle().fill(Phosphor.border).frame(height: 1)
            footer
        }
        .font(Mono.font(12))
        .foregroundStyle(Phosphor.fg)
        .frame(width: Layout.width, height: Layout.height(for: snapshot))
        .background(Phosphor.panel)
        .overlay(Scanlines().opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Phosphor.border, lineWidth: 1))
    }

    private func header(at date: Date) -> some View {
        HStack(spacing: 7) {
            Text("~/agents").foregroundStyle(Phosphor.teal)
            Text("$ watch").fontWeight(.bold)
            Text("· \(snapshot.agents.count) procs").foregroundStyle(Phosphor.muted)
            Blink(motion: motion) {
                Text("▌").foregroundStyle(Phosphor.done)
            }
            Spacer()
            Text("◷ \(date.formatted(date: .omitted, time: .shortened))")
                .font(Mono.font(11))
                .foregroundStyle(Phosphor.dim)
        }
        .padding(.horizontal, 16)
        .frame(height: Layout.header)
    }

    private func list(at date: Date) -> some View {
        let groups = snapshot.agents.grouped()
        let ordered = groups.flatMap(\.agents)
        return Group {
            if animate {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) { rows(groups, ordered: ordered, at: date) }
                        .onChange(of: selection.selected) { _, id in
                            if let id { withAnimation(motion ? .easeOut(duration: 0.15) : nil) { proxy.scrollTo(id) } }
                        }
                }
            } else {
                // ImageRenderer draws nothing inside a ScrollView.
                rows(groups, ordered: ordered, at: date).frame(maxHeight: .infinity, alignment: .top).clipped()
            }
        }
    }

    private func rows(_ groups: [AgentGroup], ordered: [Agent], at date: Date) -> some View {
        VStack(alignment: .leading, spacing: Layout.groupGap) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(":: \(group.attention.groupLabel) [\(group.agents.count)]")
                        .font(Mono.font(11, weight: .semibold))
                        .foregroundStyle(group.attention.color)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 3)
                        .frame(height: Layout.groupHeader, alignment: .bottomLeading)
                    ForEach(group.agents) { agent in
                        AgentRow(
                            agent: agent,
                            index: ordered.firstIndex(of: agent) ?? 0,
                            highlighted: selection.selected == agent.id || selection.hovered == agent.id,
                            changed: changed.contains(agent.id),
                            motion: motion,
                            date: date,
                            action: { open(agent) },
                            hover: { selection.hovered = $0 ? agent.id : nil })
                            .id(agent.id)
                    }
                }
            }
            if let failure = snapshot.failure {
                message(":: herdr unavailable", failure, color: Phosphor.blocked)
            } else if let focusFailure {
                message(":: focus failed", focusFailure, color: Phosphor.blocked)
            } else if groups.isEmpty {
                message(":: idle", "no agents. the watch is quiet.", color: Phosphor.dim)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, Layout.listPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func message(_ title: String, _ body: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Mono.font(11, weight: .semibold)).foregroundStyle(color)
            Text(body).font(Mono.font(11)).foregroundStyle(Phosphor.muted).lineLimit(2)
        }
        .padding(.horizontal, 10)
        .frame(height: Layout.message, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("↵ open · ↑↓ move · esc close").foregroundStyle(Phosphor.dim)
            Spacer()
            FooterButton("open herdr ↗", action: openHerdr)
            FooterButton("quit", action: quit)
        }
        .font(Mono.font(10))
        .padding(.horizontal, 16)
        .frame(height: Layout.footer)
    }
}

private struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).foregroundStyle(hovering ? Phosphor.fg : Phosphor.muted)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct AgentRow: View {
    let agent: Agent
    let index: Int
    let highlighted: Bool
    let changed: Bool
    let motion: Bool
    let date: Date
    let action: () -> Void
    let hover: (Bool) -> Void

    @State private var appeared = false
    @State private var flash = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(highlighted ? "▸" : "$")
                        .foregroundStyle(highlighted ? agent.attention.color : Phosphor.dim)
                        .frame(width: 10)
                    Text(agent.space).fontWeight(.bold).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let machine = agent.machine {
                        Text("@\(machine)").font(Mono.font(11)).foregroundStyle(Phosphor.teal)
                    }
                    Text(agent.age(at: date)).font(Mono.font(11)).foregroundStyle(Phosphor.dim)
                    AttentionTag(attention: agent.attention, motion: motion)
                        .frame(width: 36, alignment: .trailing)
                }
                HStack(spacing: 0) {
                    Text("└─ ").foregroundStyle(Phosphor.dim)
                    Text(agent.task).foregroundStyle(Phosphor.muted).lineLimit(1).truncationMode(.tail)
                }
                .font(Mono.font(10.5))
                .padding(.leading, 18)
            }
            .padding(.horizontal, 10)
            .frame(height: Layout.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(flash ? agent.attention.color.opacity(0.18) : highlighted ? Phosphor.selected : .clear))
            .overlay(alignment: .leading) {
                if flash {
                    RoundedRectangle(cornerRadius: 1).fill(agent.attention.color).frame(width: 2).padding(.vertical, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(agent.task)
        .accessibilityIdentifier(agent.address)
        .accessibilityLabel("\(agent.space)\(agent.machine.map { " on \($0)" } ?? ""), \(agent.attention.groupLabel), \(agent.task)")
        .onHover(perform: hover)
        .animation(.easeOut(duration: 0.12), value: highlighted)
        .opacity(!motion || appeared ? 1 : 0)
        .offset(y: !motion || appeared ? 0 : 6)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(Double(index) * 0.03)) { appeared = true }
            if changed { pulse() }
        }
        .onChange(of: changed) { _, value in if value { pulse() } }
    }

    private func pulse() {
        guard motion else { return }
        flash = true
        withAnimation(.easeOut(duration: 1.4)) { flash = false }
    }
}

/// A faint CRT texture: a 1x3 pattern tiled over the panel, drawn once.
private struct Scanlines: View {
    @MainActor private static let tile: Image = {
        let image = NSImage(size: NSSize(width: 1, height: 3), flipped: false) { rect in
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: 1, height: 1).fill()
            return true
        }
        return Image(nsImage: image)
    }()

    var body: some View {
        Rectangle().fill(ImagePaint(image: Self.tile)).allowsHitTesting(false)
    }
}

/// Each animated glyph owns its clock, so a tick re-renders one `Text` instead of the whole panel.
private struct AttentionTag: View {
    let attention: Attention
    let motion: Bool
    @State private var pulsing = false

    var body: some View {
        switch attention {
        case .working where motion:
            HStack(spacing: 0) {
                Text("[")
                SpinnerGlyph(color: Phosphor.workingNS, font: Mono.nsFont(12))
                Text("]")
            }
            .foregroundStyle(attention.color)
        case .blocked where motion:
            Text(attention.tag)
                .foregroundStyle(attention.color)
                .opacity(pulsing ? 0.55 : 1)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulsing = true }
                }
        default:
            Text(attention.tag).foregroundStyle(attention.color)
        }
    }
}

private struct Blink<Content: View>: View {
    let motion: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if motion {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                content().opacity(Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0)
            }
        } else {
            content()
        }
    }
}
