import Foundation
import Combine

// MARK: - wakelock status --json の写し

struct WakelockStatus: Decodable {
    struct GuardInfo: Decodable {
        let running: Bool
        let pid: Int?
    }

    struct Arm: Decodable, Identifiable {
        let id: String
        let pid: Int
        let label: String
        let expiry: Int
        /// 期限までの残り秒。無期限のときは nil。
        let remaining: Int?
    }

    struct Hold: Decodable, Identifiable {
        let id: String
        let pid: Int
        let label: String
    }

    /// 外部からの SleepDisabled 上書きの検出結果。
    struct Overrides: Decodable {
        /// 最後に検出した時刻（epoch 秒）。一度もなければ nil。
        let last: Int?
        /// 直近 1 時間の検出回数。
        let lastHour: Int
    }

    /// 自動モード。有効なら claude / opencode を起動するだけで作業中に蓋閉じが効く。
    let auto: Bool
    let sleepDisabled: Int
    let `guard`: GuardInfo
    let enabledSince: Int?
    /// 蓋閉じ有効が連続している秒数。排熱の警告に使う。
    let enabledForSeconds: Int?
    let arms: [Arm]
    let holds: [Hold]
    let now: Int
    /// 他のアプリによる SleepDisabled の書き換え。古い CLI の JSON には無いので Optional。
    let overrides: Overrides?

    /// 上書きの警告に使うアイコン。排熱の三角とは別の記号にして、警告の種類を見分けられるようにする。
    static let overrideWarningSymbol = "exclamationmark.arrow.triangle.2.circlepath"

    /// 直近 1 時間に 1 回以上、他のアプリに書き換えられたら警告する。
    var shouldWarnOverride: Bool { (overrides?.lastHour ?? 0) >= 1 }

    /// 警告の文言。時刻はローカル時刻の HH:mm（テストでは timeZone を固定できる）。
    func overrideWarningText(timeZone: TimeZone = .current) -> String {
        let count = overrides?.lastHour ?? 0
        var when = ""
        if let last = overrides?.last {
            when = "、最終 \(formatClock(last, timeZone: timeZone))"
        }
        return "他のアプリが蓋閉じの設定を書き換えています（直近 1 時間に \(count) 回\(when)）。"
            + "蓋を閉じると寝てしまうことがあります。詳しくは wakelock doctor を参照してください。"
    }

    var isLidCloseActive: Bool { sleepDisabled == 1 }
    var isArmed: Bool { !arms.isEmpty }
    var isWorking: Bool { !holds.isEmpty }

    /// 実際にエージェントが作業している hold だけを返す。
    /// pid 0 は手動で有効化した印であって作業ではないので、「作業中」には数えない。
    /// 手動分は arm 側に「手動で有効化 / 無期限」として出るため、情報は失われない。
    var agentHolds: [Hold] { holds.filter { $0.pid > 0 } }

    /// メニューバーのアイコン。
    /// 「今この瞬間、蓋を閉じて平気か」が一目で分かることを最優先にする。
    /// bolt.fill と bolt は 16pt だと見分けが付かなかったため、塗りの違いではなく
    /// 形の違う記号を使う。
    ///
    /// 自動モードも「運用中」に数える。arm が立つのはエージェントが最初に
    /// 作業を始めた後なので、それだけを見ると「自動モードで待機している」状態が
    /// 通常時と区別できなくなるため。
    var iconName: String {
        if isLidCloseActive { return "bolt.fill" }      // 閉じても動く
        if isArmed || auto { return "bolt.slash" }      // 運用中だが今は寝る
        return "moon.zzz"                               // 通常のスリープ設定
    }
}

// MARK: - CLI 呼び出し

enum WakelockCLI {
    /// インストール先の候補を順に探す。
    static let searchPaths: [String] = [
        "/opt/homebrew/bin/wakelock",
        "/usr/local/bin/wakelock",
        NSHomeDirectory() + "/Coding/wakelock/bin/wakelock",
    ]

    static var executablePath: String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// wakelock を同期実行して標準出力を返す。失敗時は nil。
    @discardableResult
    static func run(_ arguments: [String]) -> Data? {
        guard let path = executablePath else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    static func status() -> WakelockStatus? {
        guard let data = run(["status", "--json"]), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(WakelockStatus.self, from: data)
    }

    static func enable(minutes: Int) {
        run(["on", "\(minutes)m"])
    }

    /// 期限なしで有効化する。自動失効もプロセス束縛もないので解除は明示操作のみ。
    static func enableForever() {
        run(["on", "0"])
    }

    static func disable() {
        run(["off"])
    }

    static func setAuto(_ enabled: Bool) {
        run(["auto", enabled ? "on" : "off"])
    }
}

// MARK: - 画面の状態

final class WakelockModel: ObservableObject {
    @Published private(set) var status: WakelockStatus?
    @Published private(set) var cliMissing: Bool = false

    private var timer: Timer?
    private let pollInterval: TimeInterval = 3

    /// 排熱を警告し始めるまでの連続稼働時間
    static let thermalWarningThreshold = 30 * 60

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// CLI 実行でメニューが固まらないよう、取得はバックグラウンドで行う。
    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let missing = WakelockCLI.executablePath == nil
            let fetched = missing ? nil : WakelockCLI.status()
            DispatchQueue.main.async {
                guard let self else { return }
                self.cliMissing = missing
                if let fetched { self.status = fetched }
            }
        }
    }

    /// 操作は即座に状態へ反映したいので、実行後すぐ再取得する。
    private func perform(_ action: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            action()
            let fetched = WakelockCLI.status()
            DispatchQueue.main.async {
                if let fetched { self?.status = fetched }
            }
        }
    }

    func enable(minutes: Int) {
        perform { WakelockCLI.enable(minutes: minutes) }
    }

    func enableForever() {
        perform { WakelockCLI.enableForever() }
    }

    func disable() {
        perform { WakelockCLI.disable() }
    }

    func setAuto(_ enabled: Bool) {
        perform { WakelockCLI.setAuto(enabled) }
    }

    var autoEnabled: Bool { status?.auto ?? false }

    // MARK: 表示用の導出値

    var iconName: String { status?.iconName ?? "questionmark" }

    var headline: String {
        guard let status else { return "状態を取得できません" }
        if status.isLidCloseActive { return "蓋を閉じても動作します" }
        if status.isArmed { return "待機中（通常のスリープ設定）" }
        if status.auto { return "自動モードで待機中" }
        return "通常のスリープ設定"
    }

    /// 手動で張られた無期限の arm。PID にも期限にも紐付かないため自動では消えない。
    var hasIndefiniteManualArm: Bool {
        status?.arms.contains { $0.pid == 0 && $0.expiry == 0 } ?? false
    }

    var shouldWarnThermal: Bool {
        guard let status, status.isLidCloseActive else { return false }
        // 無期限は自動解除が効かないので、経過時間によらず注意を出し続ける
        if hasIndefiniteManualArm { return true }
        guard let seconds = status.enabledForSeconds else { return false }
        return seconds >= Self.thermalWarningThreshold
    }

    var shouldWarnOverride: Bool { status?.shouldWarnOverride ?? false }

    var overrideWarningText: String { status?.overrideWarningText() ?? "" }

    var thermalWarningText: String {
        hasIndefiniteManualArm
            ? "無期限で有効化しています。自動では解除されません。カバンに入れたままだと排熱できません。"
            : "長時間スリープを無効にしています。カバンに入れたままだと排熱できません。"
    }
}

// MARK: - 表示ヘルパ

/// 状態ファイルのラベルを表示用の日本語にする。
/// ファイル側は機械可読なまま（他ツールから読めるように）、変換は表示側だけで行う。
func displayLabel(_ raw: String) -> String {
    switch raw {
    case "manual": return "手動で有効化"
    case "hook":   return "エージェント"
    case "":       return "不明"
    default:       return raw   // claude / opencode などはそのまま出す
    }
}

/// 分をボタン用のラベルにする。
/// 整数除算で端数を落とすと 90 分が「1時間」と誤表示されるため、余りも必ず出す。
func durationLabel(minutes: Int) -> String {
    let hours = minutes / 60
    let mins = minutes % 60
    if hours == 0 { return "\(mins)分" }
    if mins == 0 { return "\(hours)時間" }
    return "\(hours)時間\(mins)分"
}

func formatDuration(_ seconds: Int) -> String {
    let total = max(0, seconds)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours > 0 { return "\(hours)時間\(minutes)分" }
    if minutes > 0 { return "\(minutes)分" }
    return "\(total)秒"
}

/// epoch 秒を HH:mm にする。タイムゾーンはテストで固定できるよう引数にする。
func formatClock(_ epoch: Int, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
}
