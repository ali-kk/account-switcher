import AccountCore
import AppKit
import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel
    @Namespace private var cards
    @Environment(\.snapshotMode) private var snapshotMode
    @State private var showSettings = false

    private var others: [AccountRecord] { model.records.filter { $0.id != model.activeID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            if let m = model.message { Toast(text: m) { withAnimation(Theme.spring) { model.message = nil } } }
            footer
        }
        .padding(16)
        .frame(width: 392)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .tint(Theme.clay)
        .motion(value: model.activeID)
        .motion(value: model.records.map(\.id))
        .motion(value: model.message)
        .motion(value: showSettings)
        .onAppear { model.menuOpened() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ClaudeMark(spinning: model.refreshing || model.switchingID != nil)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Accounts").font(.system(size: 15, weight: .semibold, design: .serif))
                Text(subtitle).font(.caption).foregroundStyle(Theme.secondary).contentTransition(.opacity)
            }
            Spacer()
            IconButton(systemName: "arrow.clockwise", label: "Refresh usage", spinning: model.refreshing) {
                Task { await model.refresh() }
            }
            .disabled(model.refreshing)
        }
    }

    private var subtitle: String {
        let n = model.records.count
        if n == 0 { return "No accounts yet" }
        let auto = model.autoSwitch ? "auto-switch on" : "auto-switch off"
        return "\(n) account\(n == 1 ? "" : "s") · \(auto)"
    }

    // MARK: Accounts

    @ViewBuilder private var content: some View {
        if model.records.isEmpty && !model.loadedOnce {
            VStack(spacing: 10) { SkeletonCard(height: 168); SkeletonCard(height: 64) }
        } else if model.records.isEmpty {
            EmptyState { model.addAccount() }
        } else {
            ScrollIfNeeded(enabled: !snapshotMode) {
                VStack(alignment: .leading, spacing: 10) {
                    if let a = model.active {
                        ActiveCard(record: a, isMain: a.id == model.mainID, onToggleMain: { toggleMain(a.id) })
                            .matchedGeometryEffect(id: a.id, in: cards)
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                    if !others.isEmpty {
                        Text("OTHER ACCOUNTS").font(.caption2.weight(.semibold)).kerning(0.8)
                            .foregroundStyle(Theme.secondary).padding(.top, 4)
                    }
                    ForEach(others) { r in
                        AccountRow(record: r, isMain: r.id == model.mainID,
                                   isSwitching: model.switchingID == r.id,
                                   switchDisabled: model.switchingID != nil,
                                   onSwitch: { Task { await model.switchTo(r.id) } },
                                   onToggleMain: { toggleMain(r.id) },
                                   onRemove: { model.remove(r.id) })
                            .matchedGeometryEffect(id: r.id, in: cards)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
    }

    private func toggleMain(_ id: String) { model.setMain(model.mainID == id ? nil : id) }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PillButton(title: "Add Account", systemImage: "plus", prominent: true) { model.addAccount() }
                PillButton(title: "Settings", systemImage: showSettings ? "chevron.up" : "slider.horizontal.3", prominent: false) {
                    showSettings.toggle()
                }
                Spacer()
                IconButton(systemName: "chart.bar.xaxis", label: "Open the usage page on claude.ai") {
                    NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
                }
                IconButton(systemName: "power", label: "Quit Claude Accounts") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            if showSettings {
                VStack(spacing: 0) {
                    SettingRow(title: "Switch automatically", detail: "Main account first; others when it runs out",
                               isOn: $model.autoSwitch)
                    Divider().overlay(Theme.border)
                    SettingRow(title: "Keep sessions going", detail: "Running sessions wait at a limit and continue on the new account",
                               isOn: Binding(get: { model.keepsSessionsGoing }, set: { model.setKeepsSessionsGoing($0) }))
                    Divider().overlay(Theme.border)
                    SettingRow(title: "Resume at reset", detail: "Reopen sessions that stopped at a limit when it resets, even with one account",
                               isOn: $model.resumeAtReset)
                    Divider().overlay(Theme.border)
                    SettingRow(title: "Notifications", detail: "When an account hits its limit or the app switches",
                               isOn: $model.notifyAtLimit)
                    Divider().overlay(Theme.border)
                    SettingRow(title: "Open at login", detail: nil,
                               isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
                }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

/// Scrolls in the app; lays out flat when rendered by `--snapshot` (ImageRenderer draws no ScrollView).
struct ScrollIfNeeded<Content: View>: View {
    let enabled: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if enabled {
            ScrollView { content }
                .scrollIndicators(.never)
                .frame(maxHeight: 520)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    @Entry var snapshotMode = false
}

// MARK: - Active account

struct ActiveCard: View {
    let record: AccountRecord
    let isMain: Bool
    let onToggleMain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Avatar(title: record.title, size: 36, inverted: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if let e = record.email, e != record.title {
                        Text(e).font(.caption).opacity(0.85).lineLimit(1)
                    }
                }
                Spacer()
                MainStar(isMain: isMain, onLight: true, action: onToggleMain)
            }
            HStack(spacing: 6) {
                Chip(text: "ACTIVE", onLight: true, pulsing: true)
                Chip(text: record.planName.uppercased(), onLight: true)
                if isMain { Chip(text: "MAIN", onLight: true) }
            }
            if let u = record.usage {
                HStack(spacing: 18) {
                    RingGauge(title: "Session", window: u.five_hour)
                    RingGauge(title: "Week", window: u.seven_day)
                    if u.seven_day_opus?.utilization != nil { RingGauge(title: "Opus", window: u.seven_day_opus) }
                    Spacer(minLength: 0)
                }
                if u.isLimited, let r = u.limitResetsAt {
                    Label("Limit reached · resets \(r.formatted(.relative(presentation: .named)))", systemImage: "hourglass")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.18)))
                }
            } else {
                HStack(spacing: 18) { SkeletonRing(); SkeletonRing() }
            }
            AccountFacts(record: record, onLight: true)
        }
        .padding(16)
        .foregroundStyle(.white)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Theme.clay, Theme.clayDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: Theme.clay.opacity(0.35), radius: 12, y: 6)
        )
    }
}

// MARK: - Other accounts

struct AccountRow: View {
    let record: AccountRecord
    let isMain: Bool
    let isSwitching: Bool
    let switchDisabled: Bool
    let onSwitch: () -> Void
    let onToggleMain: () -> Void
    let onRemove: () -> Void
    @State private var expanded = false
    @State private var hovering = false
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Avatar(title: record.title, size: 30, inverted: false)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(record.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Chip(text: record.planName.uppercased(), onLight: false)
                    }
                    Text(statusLine).font(.caption).foregroundStyle(statusColor).lineLimit(1)
                }
                Spacer(minLength: 4)
                MainStar(isMain: isMain, onLight: false, action: onToggleMain)
                switchButton
            }
            if let u = record.usage {
                VStack(spacing: 6) {
                    UsageBar(title: "Session", window: u.five_hour)
                    UsageBar(title: "Week", window: u.seven_day)
                }
            } else if record.lastError == nil {
                VStack(spacing: 6) { SkeletonBar(); SkeletonBar() }
            }
            if expanded {
                AccountFacts(record: record, onLight: false)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hovering ? Theme.cardHover : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isMain ? Theme.clay.opacity(0.5) : Theme.border))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { expanded.toggle() }
        .motion(.easeOut(duration: 0.15), value: hovering)
        .motion(value: expanded)
        .contextMenu {
            Button(isMain ? "Stop using as main account" : "Make main account", action: onToggleMain)
            if let e = record.email {
                Button("Copy email") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(e, forType: .string)
                }
            }
            Divider()
            Button("Remove from list…", role: .destructive) { confirmRemove = true }
        }
        .confirmationDialog("Remove \(record.title)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive, action: onRemove)
        } message: {
            Text("Its saved login is deleted from this app. Claude Code itself is not signed out.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint("Click to show details")
    }

    private var statusLine: String {
        if record.needsLogin { return "Signed out · use Add Account to sign in again" }
        if let e = record.lastError { return e }
        if let u = record.usage, u.isLimited, let r = u.limitResetsAt {
            return "At its limit · resets \(r.formatted(.relative(presentation: .named)))"
        }
        if let u = record.usage { return "\(Int(100 - u.pressure))% left" + (isMain ? " · main account" : "") }
        return record.email ?? ""
    }

    private var statusColor: Color {
        if record.needsLogin || record.lastError != nil { return Theme.danger }
        if record.usage?.isLimited == true { return Theme.warn }
        return Theme.secondary
    }

    @ViewBuilder private var switchButton: some View {
        if isSwitching {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).accessibilityLabel("Switching")
                Text("Switching").font(.caption.weight(.medium)).foregroundStyle(Theme.secondary)
            }
        } else {
            PillButton(title: "Switch", systemImage: nil, prominent: true, compact: true, action: onSwitch)
                .disabled(switchDisabled || record.needsLogin)
        }
    }
}

/// Status, organisation, subscription date, extra usage, last update.
struct AccountFacts: View {
    let record: AccountRecord
    let onLight: Bool

    var body: some View {
        let secondary = onLight ? Color.white.opacity(0.85) : Theme.secondary
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let s = record.subscriptionStatus {
                    Label(s.capitalized, systemImage: s == "active" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(onLight ? .white : (s == "active" ? Theme.good : Theme.warn))
                }
                if let x = record.extraUsageEnabled {
                    Label(x ? "Extra usage on" : "Extra usage off", systemImage: "plus.circle")
                }
            }
            if let org = record.organizationName { Label(org, systemImage: "building.2").lineLimit(1) }
            HStack(spacing: 10) {
                if let since = record.subscriptionCreatedAt.flatMap(Self.date) {
                    Label("Since \(since.formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar")
                }
                if let at = record.usageFetchedAt {
                    Label(at.formatted(.relative(presentation: .named)), systemImage: "clock")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(secondary)
        .labelStyle(CompactLabel())
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

// MARK: - Gauges

struct RingGauge: View {
    let title: String
    let window: UsageWindow?
    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.snapshotMode) private var snapshotMode

    private var pct: Double { min(max(window?.utilization ?? 0, 0), 100) }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: shown / 100)
                    .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(shown))")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: shown))
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                if let r = window?.resetsAt {
                    Text("resets \(UsageBar.resetText(r))").font(.caption2).opacity(0.85)
                }
            }
        }
        .onAppear { animate(to: pct) }
        .onChange(of: pct) { _, new in animate(to: new) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(Int(pct)) percent used")
    }

    private func animate(to value: Double) {
        if reduceMotion || snapshotMode { shown = value } else { withAnimation(.spring(response: 0.9, dampingFraction: 0.85)) { shown = value } }
    }
}

struct UsageBar: View {
    let title: String
    let window: UsageWindow?
    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.snapshotMode) private var snapshotMode

    private var pct: Double { min(max(window?.utilization ?? 0, 0), 100) }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(Theme.secondary).frame(width: 50, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(Theme.usageColor(pct)).frame(width: max(6, g.size.width * shown / 100))
                }
            }
            .frame(height: 6)
            Text("\(Int(pct))%").font(.caption.weight(.semibold)).monospacedDigit().frame(width: 36, alignment: .trailing)
            if let r = window?.resetsAt {
                Text(Self.resetText(r)).font(.caption2).foregroundStyle(Theme.secondary).frame(width: 64, alignment: .trailing)
            }
        }
        .onAppear { animate(to: pct) }
        .onChange(of: pct) { _, new in animate(to: new) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(Int(pct)) percent used")
    }

    private func animate(to value: Double) {
        if reduceMotion || snapshotMode { shown = value } else { withAnimation(.spring(response: 0.8, dampingFraction: 0.85)) { shown = value } }
    }

    static func resetText(_ d: Date) -> String {
        Calendar.current.isDateInToday(d)
            ? d.formatted(date: .omitted, time: .shortened)
            : d.formatted(.dateTime.weekday(.abbreviated).hour())
    }
}

// MARK: - Small parts

/// Claude-style spark; turns while the app is busy.
struct ClaudeMark: View {
    let spinning: Bool
    @State private var angle: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "asterisk")
            .font(.system(size: 15, weight: .black))
            .foregroundStyle(.white)
            .rotationEffect(.degrees(angle))
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.clay))
            .onChange(of: spinning) { _, on in spin(on) }
            .onAppear { spin(spinning) }
            .accessibilityHidden(true)
    }

    private func spin(_ on: Bool) {
        guard !reduceMotion else { return }
        if on {
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { angle += 360 }
        } else {
            withAnimation(.spring) { angle = (angle / 360).rounded() * 360 }
        }
    }
}

struct Avatar: View {
    let title: String
    let size: CGFloat
    let inverted: Bool

    var body: some View {
        Text(String(title.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .bold, design: .serif))
            .foregroundStyle(inverted ? Theme.clay : .white)
            .frame(width: size, height: size)
            .background(Circle().fill(inverted ? Color.white : Theme.clay))
            .accessibilityHidden(true)
    }
}

struct Chip: View {
    let text: String
    let onLight: Bool
    var pulsing = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            if pulsing {
                Circle().fill(onLight ? Color.white : Theme.good).frame(width: 6, height: 6)
                    .scaleEffect(pulse ? 1.4 : 0.9).opacity(pulse ? 0.6 : 1)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 1).repeatForever()) { pulse = true }
                    }
            }
            Text(text).font(.system(size: 9.5, weight: .bold)).kerning(0.6)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .foregroundStyle(onLight ? Color.white : Theme.clayDeep)
        .background(Capsule().fill(onLight ? Color.white.opacity(0.2) : Theme.claySoft))
    }
}

struct MainStar: View {
    let isMain: Bool
    let onLight: Bool
    let action: () -> Void
    @State private var bounce = 0

    var body: some View {
        Button {
            bounce += 1
            action()
        } label: {
            Image(systemName: isMain ? "star.fill" : "star")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(onLight ? Color.white : (isMain ? Theme.clay : Theme.secondary))
                .symbolEffect(.bounce, value: bounce)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isMain ? "Main account: used whenever it has usage left" : "Make this the main account")
        .accessibilityLabel(isMain ? "Main account" : "Make main account")
    }
}

struct PillButton: View {
    let title: String
    let systemImage: String?
    let prominent: Bool
    var compact = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .bold)) }
                Text(title).font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
            }
            .padding(.horizontal, compact ? 11 : 13)
            .padding(.vertical, compact ? 5 : 7)
            .foregroundStyle(prominent ? Color.white : Theme.text)
            .background(Capsule().fill(prominent ? (hovering ? Theme.clayDeep : Theme.clay) : (hovering ? Theme.cardHover : Theme.card)))
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : Theme.border))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(hovering && enabled ? 1.03 : 1)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .motion(.easeOut(duration: 0.15), value: hovering)
    }
}

struct IconButton: View {
    let systemName: String
    let label: String
    var spinning = false
    let action: () -> Void
    @State private var hovering = false
    @State private var angle: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .rotationEffect(.degrees(angle))
                .frame(width: 28, height: 28)
                .foregroundStyle(hovering ? Theme.clay : Theme.secondary)
                .background(Circle().fill(hovering ? Theme.claySoft : Color.clear))
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .onChange(of: spinning) { _, on in
            guard !reduceMotion else { return }
            if on { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { angle += 360 } }
            else { withAnimation(.spring) { angle = (angle / 360).rounded() * 360 } }
        }
        .motion(.easeOut(duration: 0.15), value: hovering)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct SettingRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                if let detail { Text(detail).font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.vertical, 9)
    }
}

struct Toast: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(Theme.clay)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.secondary).accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.claySoft))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct EmptyState: View {
    let add: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2.circle").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.clay)
            Text("No accounts yet").font(.system(size: 14, weight: .semibold, design: .serif))
            Text("Sign in to Claude Code, or add an account here.").font(.caption).foregroundStyle(Theme.secondary)
            PillButton(title: "Add Account", systemImage: "plus", prominent: true, action: add)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }
}

struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.imageScale(.small); configuration.title }
    }
}

// MARK: - Skeletons (shimmer in the shape of what is coming)

struct SkeletonCard: View {
    let height: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card).frame(height: height).shimmer()
    }
}

struct SkeletonBar: View {
    var body: some View { Capsule().fill(Theme.track).frame(height: 6).shimmer() }
}

struct SkeletonRing: View {
    var body: some View { Circle().stroke(.white.opacity(0.25), lineWidth: 6).frame(width: 48, height: 48).shimmer() }
}

private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.5)
                            .offset(x: phase * g.size.width * 1.5)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}
