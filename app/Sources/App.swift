import SwiftUI

@main
struct WakelockApp: App {
    @StateObject private var model = WakelockModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
                .onAppear { model.refresh() }
        } label: {
            Image(systemName: model.iconName)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    @ObservedObject var model: WakelockModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.cliMissing {
                missingCLI
            } else {
                Divider()
                sessions
                if model.shouldWarnThermal { thermalWarning }
                Divider()
                controls
            }

            footer
        }
        .padding(14)
        .frame(width: 330)
        .onAppear { model.start() }
    }

    // MARK: 見出し

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.iconName)
                .font(.title2)
                .foregroundStyle(model.status?.isLidCloseActive == true ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.headline)
                    .font(.headline)
                if let seconds = model.status?.enabledForSeconds {
                    Text("有効化から \(formatDuration(seconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var missingCLI: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("wakelock コマンドが見つかりません")
                .foregroundStyle(.red)
            Text("install.sh を実行してください")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: セッション一覧

    @ViewBuilder
    private var sessions: some View {
        if let status = model.status {
            if status.arms.isEmpty {
                Text("蓋閉じ運用中のセッションはありません")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    section(
                        title: "蓋閉じ運用中",
                        rows: status.arms.map { arm in
                            Row(
                                id: arm.id,
                                primary: arm.label.isEmpty ? arm.id : arm.label,
                                secondary: arm.remaining.map { "残り \(formatDuration($0))" } ?? "無期限"
                            )
                        }
                    )

                    section(
                        title: "作業中",
                        rows: status.holds.map { hold in
                            Row(
                                id: hold.id,
                                primary: hold.label.isEmpty ? hold.id : hold.label,
                                secondary: hold.id
                            )
                        },
                        emptyText: "承認待ち / 待機中"
                    )
                }
            }
        }
    }

    private struct Row: Identifiable {
        let id: String
        let primary: String
        let secondary: String
    }

    @ViewBuilder
    private func section(title: String, rows: [Row], emptyText: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if rows.isEmpty {
                Text(emptyText ?? "なし")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack {
                        Text(row.primary).font(.callout)
                        Spacer()
                        Text(row.secondary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: 排熱の警告

    private var thermalWarning: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("長時間スリープを無効にしています。カバンに入れたままだと排熱できません。")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: 操作

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手動で有効化")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach([30, 60, 180], id: \.self) { minutes in
                    Button(durationLabel(minutes: minutes)) {
                        model.enable(minutes: minutes)
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            }

            Button {
                model.disable()
            } label: {
                Label("今すぐ解除", systemImage: "moon.zzz")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.status?.isArmed != true)
        }
    }

    // MARK: フッタ

    private var footer: some View {
        HStack {
            if let running = model.status?.guard.running {
                Circle()
                    .fill(running ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(running ? "ガード稼働中" : "待機中")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("終了") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
