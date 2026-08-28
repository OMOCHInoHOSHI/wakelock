# wakelock

Mac の蓋を閉じたまま Claude Code / opencode を走らせるためのスリープ制御ツール。

エージェントが作業している間だけスリープを無効化し、承認待ちで放置されたら
通常のスリープ設定に戻す。メニューバーアプリから状態の確認と操作ができる。

## インストール

```sh
./install.sh --dry-run   # 何をするか確認
./install.sh             # 導入
./install.sh --uninstall # 取り外し
```

導入されるもの:

1. `/usr/local/libexec/wakelock-helper` と `/etc/sudoers.d/wakelock`（要パスワード）
2. `/opt/homebrew/bin/wakelock` へのシンボリックリンク
3. `~/.config/opencode/plugin/wakelock.js` へのシンボリックリンク
4. `~/.claude/settings.json` への hooks 追記（既存設定は保持。再実行しても重複しない）
5. `/Applications/Wakelock.app`（メニューバーアプリ）

hooks の追記前に `settings.json` のバックアップを同ディレクトリに作る。
Claude Code は再起動すると hooks が読み込まれる。

## 使い方

### メニューバーから操作する

日常の操作はすべてメニューバーアプリで完結する。コマンドを打つ必要はない。

アイコンが現在の状態を表す。

| アイコン | 意味 |
|---|---|
| `bolt.fill` | 蓋を閉じても動作中（`SleepDisabled=1`） |
| `bolt` | 蓋閉じ運用中だが今は待機（承認待ちなど。通常のスリープ設定） |
| `zzz` | 通常のスリープ設定 |

クリックするとパネルが開く。

```
┌────────────────────────────────┐
│ ⚡ 蓋を閉じても動作します        │
│    有効化から 12分              │
│ ────────────────────────────── │
│ 蓋閉じ運用中                    │
│   claude              無期限    │
│ 作業中                          │
│   claude            pid 3957    │
│ ────────────────────────────── │
│ 自動モード              [ ● ]   │
│ claude / opencode を起動する    │
│ だけで、作業中は蓋を閉じても    │
│ 動作します                      │
│ ────────────────────────────── │
│ 手動で有効化                    │
│ [30分] [1時間] [3時間]          │
│ [        ∞ 無期限        ]      │
│ [      今すぐ解除        ]      │
│ ● ガード稼働中           終了    │
└────────────────────────────────┘
```

**自動モード**を入れておけば、あとは `claude` / `opencode` を普通に起動するだけでよい。
hooks が作業開始を検知して自動で有効化し、承認待ちで放置されれば解除する。
これが基本の使い方で、他の操作は補助にすぎない。

**手動で有効化**は CLI と無関係に効く。ビルドやダウンロードを流しっぱなしにしたいときに使う。
指定時間で自動失効する。

**無期限**だけは性質が違う。期限にもプロセスにも紐付かないので自動失効せず、
解除は明示的な操作だけになる。焼き付きを防ぐ仕組みを外す選択なので、
ボタンの色を変えてあり、有効な間は排熱の注意を出し続ける。

**今すぐ解除**はすべての有効化を取り消す。ただし自動モードが入っていれば、
次に CLI が作業を始めた時点で再び有効になる。一度解除したら効かなくなる、ということはない。

### コマンドラインから操作する

メニューバーと同じことができる。加えて、hooks を持たない任意のコマンドを包める。

```sh
wakelock auto on                 # 自動モードを有効にする（メニューバーのスイッチと同じ）
wakelock auto off                # 自動モードを解除する
wakelock auto status             # 自動モードの状態

wakelock on 90m                  # CLI と無関係に手動で有効化（90分で自動失効）
wakelock on 0                    # 無期限で有効化（自動では解除されない）
wakelock off                     # すぐに解除

wakelock status                  # 現在の状態
wakelock status --json           # 機械可読な状態（GUI がこれを読む）
wakelock doctor                  # 前提条件の確認

wakelock run --for 3h -- npm run build   # hooks のないコマンドを包む
wakelock run claude                      # 自動モードを使わず範囲を明示する
```

期間の書式は `90m` / `2h` / `45s` / `30`（数値のみは分）/ `0`（無期限）。
`wakelock on` に期間を渡さない場合は 2 時間で自動失効する。

`run` のモードはコマンド名から自動判定する。`claude` / `opencode` は `--hooked`
（作業中だけ有効）、それ以外は `--always`（実行中ずっと有効）。
`--hooked` / `--always` で明示的に上書きできる。

## 解決したい問題

`caffeinate` はアイドルスリープしか止められない。蓋を閉じるとハードウェア起因でスリープに入るため、
`caffeinate` のアサーションでは防げない。蓋を閉じても動かすには `pmset -a disablesleep 1` が必要だが、
これはシステム全体の設定なので、解除し忘れると Mac が一切スリープしなくなる。

wakelock はこの `disablesleep` を、CLI エージェントの作業状態に連動させて自動で 0 / 1 する。

## 仕組み

二段構えのロックを持つ。

| 種類 | 意味 | 作る主体 |
|---|---|---|
| `arm` | 蓋閉じ運用したい、という意思表示 | 自動モード（hooks 自身）/ `wakelock run` / `wakelock on` |
| `hold` | 今まさに作業中 | Claude の hooks / opencode のプラグイン |

`SleepDisabled=1` にするのは **arm と hold が両方存在するときだけ**。

* arm がない → hooks からの `acquire` は黙って無視される。
  自動モードを切っておけば、プラグインや hooks を常設しても素の挙動は変わらない。
* arm はあるが hold がない → 承認待ちなど。通常のスリープ設定に戻る。

arm の作られ方は 3 通りある。

| 方法 | arm の名前 | 束縛 | 消えるとき |
|---|---|---|---|
| 自動モード | `auto-<pid>` | CLI 本体の PID | CLI の終了 |
| `wakelock run` | `run-<pid>` | ラッパーの PID | コマンドの終了 |
| 手動（GUI / `on`） | `manual` | なし（`pid 0`） | 指定期限、または明示解除 |

`pid 0` の手動 arm はすべてのセッションに効く。そのため手動で有効化している間は、
自動モードが個別の `auto-<pid>` を作らなくても hooks は hold を出し入れできる。

### 猶予時間は macOS のタイマーに任せる

承認待ちになったら即座に `disablesleep 0` に戻す。自前で猶予タイマーは持たない。
このマシンの実測値では、`powerd` が「ディスプレイが点いている間はスリープさせない」という
アサーションを常時保持しているため、実効的な猶予は以下になる。

| 状態 | ディスプレイオフまで | その後スリープまで | 合計 |
|---|---|---|---|
| 蓋オープン・バッテリー | 10 分 | 1 分 | 約 11 分 |
| 蓋オープン・AC 接続 | 0（オフにならない） | — | スリープしない |

`pmset -g assertions` で `Powerd - Prevent sleep while display is on` として確認できる。
猶予を変えたい場合は `sudo pmset -b displaysleep 15` のようにディスプレイ側を調整する
（`sleep` 単体より実効的）。

### クラッシュ耐性

常駐ガードが 20 秒ごとに以下を行う。

* プロセスが死んだ arm / hold の削除
* 期限切れ arm の失効
* 望ましい状態の再計算と適用
* arm が空になったら `disablesleep 0` にして自身も終了

CLI やターミナルを強制終了しても、ガードが検知して解除する。

なお `pmset -g` が何も返さなかった場合は `SleepDisabled=0` と混同せず「読み取れず」として扱う。
0 と誤認すると、実際には変わっていないのに状態遷移をログに残してしまうため。

## 特権の扱い

`pmset -a disablesleep` の実行には root が要る。パスワード入力なしで動かすため、
引数を `0` と `1` だけに限定した最小の helper を経由する。

```
/usr/local/libexec/wakelock-helper          root:wheel 0755
/etc/sudoers.d/wakelock                     root:wheel 0440
  <user> ALL=(root) NOPASSWD: /usr/local/libexec/wakelock-helper 0, /usr/local/libexec/wakelock-helper 1
```

root 権限で動くコードはこの helper だけで、`pmset` 以外は何もしない。
引数は sudoers 側と helper 側の二段で検証している。
sudoers は設置前に `visudo -cf` で必ず検証する（壊すとログインできなくなるため）。

`wakelock doctor` で前提条件をまとめて確認できる。

## アダプタ

hooks とプラグインは `wakelock hook acquire` / `release` を呼ぶだけで、判断は持たない。

### Claude Code

| フック | 動作 |
|---|---|
| `UserPromptSubmit` | acquire（ターン開始） |
| `PostToolUse` | acquire（承認後の再開） |
| `Notification` | release（承認待ち・アイドル） |
| `Stop` | release（応答完了） |
| `SessionEnd` | release（保険） |

### opencode

| フック | 動作 |
|---|---|
| `chat.message` | acquire（ターン開始） |
| `event: permission.replied` | acquire（承認後の再開） |
| `permission.ask` | release（承認待ち） |
| `event: session.idle` | release（応答完了） |
| `event: session.deleted` / `session.error` | release（保険） |

opencode には `permission.replied` があるため、承認後の再開をツール呼び出しごとの
監視なしに検知できる。Claude Code には該当するものがないので `PostToolUse` で代用しており、
hold が既に同じ内容なら `pmset` を叩かずに返す高速パスを入れてある。

## 開発

GUI は Xcode 不要。Command Line Tools の `swiftc` だけでビルドできる。

```sh
cd app
make            # ビルド
make run        # ビルドして起動
make install    # /Applications へ配置
make test       # デコードと表示ラベルの検証
```

アプリは CLI のロジックを持たない。3 秒ごとに `wakelock status --json` を読み、
操作は `wakelock auto` / `on` / `off` を呼ぶだけ。判断の出所は CLI 側に一本化してある。
状態ファイルのラベルは機械可読なまま（`manual` / `claude` など）で、
日本語への変換は表示側だけで行う。

`Info.plist` に `LSUIElement=1` を入れてあるので Dock には出ない。

### テスト

```sh
./test/smoke.sh      # CLI の状態遷移（31 項目）
make -C app test     # GUI のデコード 3 パターンと表示ラベル 10 項目
```

`test/smoke.sh` は `pmset` と sudo helper をスタブに差し替え、
実際のスリープ設定を変えずに状態遷移を検証する。確認している内容:

* arm のないセッションからの `acquire` が無視されること
* 承認待ちで解除され、再開で復帰すること
* コマンドの正常終了・異常終了の両方で解除されること
* 期限切れをガードが失効させること
* 自動モードで `run` なしでも完結し、切ると自動生成 arm だけが消えること
* 無期限が期限で失効しないこと
* 解除後も自動モードなら次の作業で arm が復活すること
* `pmset` が読めないときも適用され、偽の状態遷移をログに残さないこと

## 注意

蓋を閉じたまま CPU を回すと排熱が塞がれる。ファンレスの MacBook Air では特に不利なので、
**カバンに入れた状態での長時間実行は避けること**。

メニューバーは、無期限で有効化している間と、有効化から 30 分が経過した時点で
排熱の注意を表示する。`wakelock status` でも現在の状態をいつでも確認できる。
