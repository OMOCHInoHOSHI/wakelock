# wakelock

Mac の蓋を閉じたまま Claude Code / opencode を走らせるためのスリープ制御ツール。

作業中だけスリープを無効化し、承認待ちで放置されたら通常のスリープ設定に戻す。

## 解決したい問題

`caffeinate` はアイドルスリープしか止められない。蓋を閉じるとハードウェア起因でスリープに入るため、
`caffeinate` のアサーションでは防げない。蓋を閉じても動かすには `pmset -a disablesleep 1` が必要だが、
これはシステム全体の設定なので、解除し忘れると Mac が一切スリープしなくなる。

wakelock はこの `disablesleep` を、CLI エージェントの作業状態に連動させて自動で 0 / 1 する。

## 設計

二段構えのロックを持つ。

| 種類 | 意味 | 作る主体 |
|---|---|---|
| `arm` | このセッションは蓋閉じ運用したい、という意思表示 | `wakelock run` / `wakelock on` |
| `hold` | 今まさに作業中 | Claude の hooks / opencode のプラグイン |

`SleepDisabled=1` にするのは **arm と hold が両方存在するときだけ**。

* arm がない = そもそも opt-in していないセッション → hooks からの `acquire` は黙って無視される。
  プラグインや hooks を常設しても、素の `claude` / `opencode` の挙動は変わらない。
* arm はあるが hold がない = 承認待ちなど → 通常のスリープ設定に戻る。

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

`wakelock run` の途中でターミナルを強制終了しても、ガードが検知して解除する。

## 特権の扱い

`pmset -a disablesleep` の実行には root が要る。パスワード入力なしで動かすため、
引数を `0` と `1` だけに限定した最小の helper を経由する。

```
/usr/local/libexec/wakelock-helper          root:wheel 0755
/etc/sudoers.d/wakelock                     root:wheel 0440
  <user> ALL=(root) NOPASSWD: /usr/local/libexec/wakelock-helper 0, /usr/local/libexec/wakelock-helper 1
```

root 権限で動くコードはこの helper だけで、`pmset` 以外は何もしない。
引数は sudoers 側と helper 側の 二段で検証している。
sudoers は設置前に `visudo -cf` で必ず検証する（壊すとログインできなくなるため）。

`wakelock doctor` で前提条件をまとめて確認できる。

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


## 使い方

```sh
wakelock run claude              # 作業中だけ蓋閉じ有効。終了で自動解除
wakelock run opencode            # 同上
wakelock run --for 3h -- npm run build   # hooks のないコマンドは実行中ずっと有効

wakelock on 90m                  # 実行中のセッションに後から有効化（90分で自動失効）
wakelock on --hooked 90m         # arm だけ張り、hold は hooks に任せる
wakelock off                     # すぐに解除
wakelock status                  # 現在の状態
wakelock doctor                  # 前提条件の確認
```

`run` のモードはコマンド名から自動判定する。`claude` / `opencode` は `--hooked`、
それ以外は `--always`。`--hooked` / `--always` で明示的に上書きできる。

期間の書式は `90m` / `2h` / `45s` / `30`（数値のみは分）。
`wakelock on` に期間を渡さない場合は 2 時間で自動失効する。

## GUI（メニューバーアプリ）

状態の確認と操作の両方ができる常駐アプリ。Xcode は不要で、
Command Line Tools の `swiftc` だけでビルドできる。

```sh
cd app
make            # ビルド
make run        # ビルドして起動
make install    # /Applications へ配置
make test       # JSON デコードの検証
```

メニューバーのアイコンが 3 状態を表す。

| アイコン | 意味 |
|---|---|
| `bolt.fill` | 蓋を閉じても動作中（`SleepDisabled=1`） |
| `bolt` | arm 済みだが待機中（承認待ちなど。通常のスリープ設定） |
| `zzz` | 通常のスリープ設定 |

クリックすると開くパネルでできること:

* arm / hold の一覧と、arm の残り時間
* 30分 / 90分 / 3時間 の手動有効化
* 今すぐ解除
* ガードの稼働状態
* 30 分以上連続で有効なときの排熱警告

アプリは CLI のロジックを持たない。3 秒ごとに `wakelock status --json` を読み、
操作は `wakelock on` / `wakelock off` を呼ぶだけ。判断の出所は CLI 側に一本化してある。

`Info.plist` に `LSUIElement=1` を入れてあるので Dock には出ない。

## アダプタ

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

opencode 側は `permission.replied` イベントがあるため、ツール呼び出しごとの監視が不要。

## テスト

```sh
./test/smoke.sh      # CLI の状態遷移（14 項目）
make -C app test     # GUI の JSON デコード（3 パターン）
```

`test/smoke.sh` は `pmset` と sudo helper をスタブに差し替え、
実際のスリープ設定を変えずに状態遷移を検証する。
承認待ちで解除されること、承認後に復帰すること、
コマンドの正常終了・異常終了の両方で解除されること、
期限切れをガードが失効させることを確認している。

## 注意

蓋を閉じたまま CPU を回すと排熱が塞がれる。ファンレスの MacBook Air では特に不利なので、
**カバンに入れた状態での長時間実行は避けること**。

`wakelock status` で現在 `SleepDisabled` がどうなっているかをいつでも確認できる。
