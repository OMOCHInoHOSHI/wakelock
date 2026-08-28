import Foundation

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
        let labels: [(Int, String)] = [(30, "30分"), (60, "1時間"), (90, "1時間30分"), (180, "3時間"), (45, "45分")]
        for (minutes, expected) in labels {
            let actual = durationLabel(minutes: minutes)
            if actual == expected {
                print("  PASS  \(minutes)分 -> \(actual)")
            } else {
                print("  FAIL  \(minutes)分 -> \(actual) (期待 \(expected))")
                failed += 1
            }
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

        print(failed == 0 ? "\n検証: 全件成功" : "\n失敗 \(failed) 件")
        exit(failed == 0 ? 0 : 1)
    }
}
