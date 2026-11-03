import AccountCore
import AppKit
import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let a = model.active, a.usage?.isLimited == true { limitBanner(a) }
            accounts
            if let m = model.message {
                Text(m).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { model.menuOpened() }
    }

    private var header: some View {
        HStack {
            Text("Claude Accounts").font(.headline)
            Spacer()
            if model.refreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).accessibilityLabel("Refreshing")
                    Text("Refreshing").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh usage")
                    .accessibilityLabel("Refresh usage")
            }
        }
    }

    private func limitBanner(_ a: AccountRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(a.title) is at its limit").font(.callout.weight(.semibold))
                if let r = a.usage?.limitResetsAt {
                    Text("Resets \(r.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var accounts: some View {
        if model.records.isEmpty && !model.loadedOnce {
            VStack(spacing: 10) { SkeletonRow(); SkeletonRow() }
        } else if model.records.isEmpty {
            Text("No accounts yet. Sign in to Claude Code, or use Add Account.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.records) { r in
                        AccountRow(record: r, isActive: r.id == model.activeID,
                                   isSwitching: model.switchingID == r.id,
                                   switchDisabled: model.switchingID != nil,
                                   onSwitch: { Task { await model.switchTo(r.id) } },
                                   onRemove: { model.remove(r.id) })
                    }
                }
            }
            .frame(maxHeight: 480)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { model.addAccount() } label: { Label("Add Account…", systemImage: "plus.circle") }
                .buttonStyle(.borderless)
            Toggle("Open at login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
            Toggle("Notify when the active account hits its limit", isOn: $model.notifyAtLimit)
            HStack {
                Button("Usage page") { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
        }
        .toggleStyle(.checkbox)
        .font(.callout)
    }
}

struct AccountRow: View {
    let record: AccountRecord
    let isActive: Bool
    let isSwitching: Bool
    let switchDisabled: Bool
    let onSwitch: () -> Void
    let onRemove: () -> Void
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(String(record.title.prefix(1)).uppercased())
                    .font(.headline).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(isActive ? Color.accentColor : Color.gray))
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.title).font(.body.weight(.semibold)).lineLimit(1)
                    if let e = record.email, e != record.title {
                        Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(record.planName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                trailing
            }
            details
            if let u = record.usage {
                UsageBar(title: "Session (5 h)", window: u.five_hour)
                UsageBar(title: "Week", window: u.seven_day)
                if u.seven_day_opus?.utilization != nil { UsageBar(title: "Week, Opus", window: u.seven_day_opus) }
                if u.seven_day_sonnet?.utilization != nil { UsageBar(title: "Week, Sonnet", window: u.seven_day_sonnet) }
            } else if record.lastError == nil {
                SkeletonBar(); SkeletonBar()
            }
            if record.needsLogin {
                Label("Signed out. Use Add Account to sign in again.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
            } else if let err = record.lastError {
                Label(err, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(isActive ? 0.08 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isActive ? Color.accentColor.opacity(0.6) : .clear))
        .contextMenu {
            if let e = record.email {
                Button("Copy email") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(e, forType: .string)
                }
            }
            Button("Remove from list…", role: .destructive) { confirmRemove = true }
        }
        .confirmationDialog("Remove \(record.title)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive, action: onRemove)
        } message: {
            Text("Its saved login is deleted from this app. Claude Code itself is not signed out.")
        }
    }

    @ViewBuilder private var trailing: some View {
        if isActive {
            Text("Active").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
        } else if isSwitching {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small).accessibilityLabel("Switching")
                Text("Switching").font(.caption)
            }
        } else {
            Button("Switch", action: onSwitch)
                .controlSize(.small)
                .disabled(switchDisabled || record.needsLogin)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let s = record.subscriptionStatus {
                    Label(s.capitalized, systemImage: s == "active" ? "checkmark.seal.fill" : "exclamationmark.triangle")
                        .foregroundStyle(s == "active" ? .green : .orange)
                }
                if let x = record.extraUsageEnabled {
                    Text(x ? "Extra usage on" : "Extra usage off").foregroundStyle(.secondary)
                }
            }
            if let org = record.organizationName { Text(org).foregroundStyle(.secondary).lineLimit(1) }
            HStack(spacing: 6) {
                if let since = record.subscriptionCreatedAt.flatMap(Self.date) {
                    Text("Subscribed since \(since.formatted(date: .abbreviated, time: .omitted))")
                }
                if let at = record.usageFetchedAt {
                    Text("· updated \(at.formatted(.relative(presentation: .named)))")
                }
            }
            .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

struct UsageBar: View {
    let title: String
    let window: UsageWindow?

    var body: some View {
        let pct = min(max(window?.utilization ?? 0, 0), 100)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(pct))%").monospacedDigit().fontWeight(.semibold)
                if let r = window?.resetsAt {
                    Text("· resets \(Self.resetText(r))").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            ProgressView(value: pct, total: 100)
                .tint(pct >= 100 ? .red : pct >= 80 ? .orange : .accentColor)
                .accessibilityLabel("\(title) \(Int(pct)) percent used")
        }
    }

    static func resetText(_ d: Date) -> String {
        Calendar.current.isDateInToday(d)
            ? d.formatted(date: .omitted, time: .shortened)
            : d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// Shimmer placeholder in the shape of an account row, shown before the first fetch.
struct SkeletonRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 3).frame(width: 140, height: 10)
                    RoundedRectangle(cornerRadius: 3).frame(width: 90, height: 8)
                }
                Spacer()
            }
            SkeletonBar(); SkeletonBar()
        }
        .padding(10)
        .foregroundStyle(Color.primary.opacity(0.08))
        .shimmer()
    }
}

struct SkeletonBar: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)).frame(height: 18).shimmer()
    }
}

private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white.opacity(0.25), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.5)
                            .offset(x: phase * g.size.width * 1.5)
                    }
                    .mask(content)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}
