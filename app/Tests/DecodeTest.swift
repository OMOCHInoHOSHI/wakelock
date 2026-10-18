import Foundation
import AppKit

@main
struct DecodeTest {
    static func main() {
        let samples: [(String, String)] = [
            ("稼働中", #"""
            {"auto":true,"sleepDisabled":1,"guard":{"running":true,"pid":26968},"enabledSince":1787943711,
             "enabledForSeconds":142,
             "arms":[{"id":"run-4821","pid":4821,"label":"claude","expiry":1787946373,"remaining":2699}],
             "holds":[{"id":"demo-session","pid":3957,"label":"claude"}],"now":1787943853}
            """#),
            ("空", #"""
            {"auto":false,"sleepDisabled":0,"guard":{"running":false,"pid":null},"enabledSince":null,
             "enabledForSeconds":null,"arms":[],"holds":[],"now":1787943853}
            """#),
            ("無期限arm", #"""
            {"auto":true,"sleepDisabled":1,"guard":{"running":true,"pid":1},"enabledSince":1,"enabledForSeconds":9999,
             "arms":[{"id":"run-1","pid":1,"label":"opencode","expiry":0,"remaining":null}],
             "holds":[],"now":10000}
            """#),
        ]

        var failed = 0
        for (name, json) in samples {
            do {
                let s = try JSONDecoder().decode(WakelockStatus.self, from: Data(json.utf8))
                print("  PASS  \(name): sleepDisabled=\(s.sleepDisabled) guard.running=\(s.guard.running) arms=\(s.arms.count) holds=\(s.holds.count)")
                if let r = s.arms.first?.remaining {
                    print("        残り表示: \(formatDuration(r))")
                }
                if let e = s.enabledForSeconds {
                    print("        連続稼働: \(formatDuration(e))  警告閾値超え: \(e >= 1800)")
                }
            } catch {
                print("  FAIL  \(name): \(error)")
                failed += 1
            }
        }
        // 90 分が「1時間」と誤表示された不具合の再発防止
        print("\n分ラベルの検証:")
        let labels: [(Int, String)] = [(30, "30分"), (60, "1時間"), (90, "1時間30分"), (180, "3時間"), (480, "8時間"), (45, "45分")]
        for (minutes, expected) in labels {
            let actual = durationLabel(minutes: minutes)
            if actual == expected {
                print("  PASS  \(minutes)分 -> \(actual)")
            } else {
                print("  FAIL  \(minutes)分 -> \(actual) (期待 \(expected))")
                failed += 1
            }
        }

        // 手動で有効化した hold (pid 0) を「作業中」に数えない
        print("\n作業中の抽出:")
        let mixed = #"""
        {"auto":true,"sleepDisabled":1,"guard":{"running":true,"pid":1},"enabledSince":1,
         "enabledForSeconds":10,
         "arms":[{"id":"manual","pid":0,"label":"manual","expiry":0,"remaining":null}],
         "holds":[{"id":"sess","pid":3957,"label":"claude"},
                  {"id":"manual","pid":0,"label":"manual"}],"now":11}
        """#
        if let s = try? JSONDecoder().decode(WakelockStatus.self, from: Data(mixed.utf8)) {
            if s.holds.count == 2 && s.agentHolds.count == 1 && s.agentHolds.first?.label == "claude" {
                print("  PASS  hold 2 件のうち手動 1 件を除外し claude だけを作業中とする")
                print("  PASS  除外しても hasIndefiniteManualArm は維持: \(s.arms.contains { $0.pid == 0 && $0.expiry == 0 })")
            } else {
                print("  FAIL  holds=\(s.holds.count) agentHolds=\(s.agentHolds.count)")
                failed += 1
            }
        } else {
            print("  FAIL  デコードできない")
            failed += 1
        }

        // メニューバーで見分けが付くよう、3 状態はすべて別の記号にする
        print("\nアイコンの検証:")
        func status(sleepDisabled: Int, armed: Bool, auto: Bool = false) -> WakelockStatus? {
            let arms = armed
                ? #"[{"id":"a","pid":0,"label":"manual","expiry":0,"remaining":null}]"#
                : "[]"
            let json = """
            {"auto":\(auto),"sleepDisabled":\(sleepDisabled),"guard":{"running":true,"pid":1},
             "enabledSince":null,"enabledForSeconds":null,
             "arms":\(arms),"holds":[],"now":1}
            """
            return try? JSONDecoder().decode(WakelockStatus.self, from: Data(json.utf8))
        }
        let iconCases: [(Int, Bool, Bool, String, String)] = [
            (1, true,  false, "bolt.fill",  "蓋を閉じても動く"),
            (0, true,  false, "bolt.slash", "arm あり・作業なし"),
            (0, false, true,  "bolt.slash", "自動モードで待機中（arm 前）"),
            (0, false, false, "moon.zzz",   "通常のスリープ設定"),
        ]
        var seen = Set<String>()
        for (sd, armed, auto, expected, desc) in iconCases {
            let actual = status(sleepDisabled: sd, armed: armed, auto: auto)?.iconName ?? "nil"
            seen.insert(actual)
            if actual == expected {
                print("  PASS  \(desc) -> \(actual)")
            } else {
                print("  FAIL  \(desc) -> \(actual) (期待 \(expected))")
                failed += 1
            }
        }
        if seen.count == 3 {
            print("  PASS  3 種類の記号がすべて使い分けられている")
        } else {
            print("  FAIL  記号の種類が 3 つでない: \(seen)")
            failed += 1
        }

        print("\n表示ラベルの検証:")
        let labelCases: [(String, String)] = [
            ("manual", "手動で有効化"), ("hook", "エージェント"),
            ("claude", "claude"), ("opencode", "opencode"), ("", "不明"),
        ]
        for (raw, expected) in labelCases {
            let actual = displayLabel(raw)
            if actual == expected {
                print("  PASS  \"\(raw)\" -> \(actual)")
            } else {
                print("  FAIL  \"\(raw)\" -> \(actual) (期待 \(expected))")
                failed += 1
            }
        }

        // 外部からの SleepDisabled 上書きの警告
        print("\n上書き警告の検証:")
        func overrideStatus(_ overrides: String?) -> WakelockStatus? {
            let extra = overrides.map { ",\"overrides\":\($0)" } ?? ""
            let json = """
            {"auto":false,"sleepDisabled":1,"guard":{"running":true,"pid":1},
             "enabledSince":null,"enabledForSeconds":null,
             "arms":[],"holds":[],"now":1\(extra)}
            """
            return try? JSONDecoder().decode(WakelockStatus.self, from: Data(json.utf8))
        }
        func check(_ ok: Bool, _ desc: String) {
            if ok { print("  PASS  \(desc)") } else { print("  FAIL  \(desc)"); failed += 1 }
        }
        let jst = TimeZone(identifier: "Asia/Tokyo")!
        let utc = TimeZone(identifier: "UTC")!
        // 1792328715 = 2026-10-18 13:05:15 UTC = 22:05:15 JST
        let withOv = overrideStatus(#"{"last":1792328715,"lastHour":2}"#)
        check(withOv?.overrides?.last == 1792328715 && withOv?.overrides?.lastHour == 2,
              "overrides の last と lastHour を読める")
        check(withOv?.shouldWarnOverride == true, "lastHour が 2 なら警告する")
        let text = withOv?.overrideWarningText(timeZone: jst) ?? ""
        check(text.contains("直近 1 時間に 2 回") && text.contains("最終 22:05"), "文言に回数と時刻(JST)が入る: \(text)")
        check(withOv?.overrideWarningText(timeZone: utc).contains("最終 13:05") == true, "時刻はタイムゾーンに従う(UTC)")
        let legacy = overrideStatus(nil)
        check(legacy != nil && legacy?.overrides == nil && legacy?.shouldWarnOverride == false,
              "overrides が無い古い CLI の JSON でもデコードでき、警告しない")
        let zero = overrideStatus(#"{"last":1792328715,"lastHour":0}"#)
        check(zero?.shouldWarnOverride == false, "lastHour が 0 なら警告しない")
        let never = overrideStatus(#"{"last":null,"lastHour":0}"#)
        check(never != nil && never?.shouldWarnOverride == false, "last が null でもデコードでき、警告しない")
        let noLast = overrideStatus(#"{"last":null,"lastHour":1}"#)
        check(noLast?.overrideWarningText(timeZone: jst).contains("最終") == false, "last が null なら時刻を出さない")
        check(formatClock(0, timeZone: utc) == "00:00" && formatClock(1792328715, timeZone: jst) == "22:05",
              "formatClock は HH:mm")
        check(NSImage(systemSymbolName: WakelockStatus.overrideWarningSymbol, accessibilityDescription: nil) != nil,
              "SF Symbol \(WakelockStatus.overrideWarningSymbol) が実在する")
        check(WakelockStatus.overrideWarningSymbol != "exclamationmark.triangle.fill", "排熱警告とは別の記号")

        print(failed == 0 ? "\n検証: 全件成功" : "\n失敗 \(failed) 件")
        exit(failed == 0 ? 0 : 1)
    }
}
