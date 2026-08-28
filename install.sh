#!/usr/bin/env bash
# wakelock のインストーラ
#
#   ./install.sh                 すべて導入する
#   ./install.sh --dry-run       何をするか表示するだけ
#   ./install.sh --keep-legacy   旧 sleep-toggle-menu の残骸を残す
#   ./install.sh --uninstall     導入したものを取り除く
#
# 特権が要るのは helper と sudoers の設置だけ。パスワードを聞かれる。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN_SRC="$ROOT/bin/wakelock"
PLUGIN_SRC="$ROOT/adapters/opencode/wakelock.js"
HOOKS_SRC="$ROOT/adapters/claude/hooks.json"
HELPER_SRC="$ROOT/helper/wakelock-helper"
SUDOERS_SRC="$ROOT/helper/wakelock.sudoers"

BIN_DEST="${WAKELOCK_BIN_DEST:-/opt/homebrew/bin/wakelock}"
HELPER_DEST="/usr/local/libexec/wakelock-helper"
SUDOERS_DEST="/etc/sudoers.d/wakelock"
OPENCODE_PLUGIN_DIR="$HOME/.config/opencode/plugin"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

LEGACY_HELPER="/usr/local/libexec/sleep-toggle-helper"
LEGACY_SUDOERS="/etc/sudoers.d/sleep-toggle-menu"

DRY_RUN=0
UNINSTALL=0
KEEP_LEGACY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=1 ;;
    --uninstall)   UNINSTALL=1 ;;
    --keep-legacy) KEEP_LEGACY=1 ;;
    *) echo "不明なオプション: $arg" >&2; exit 64 ;;
  esac
done

say()  { printf '  %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
run()  { if [ "$DRY_RUN" = 1 ]; then say "(dry-run) $*"; else eval "$@"; fi; }

CLAUDE_HOOK_STRIP='
  .hooks |= with_entries(
    .value |= (
      map(.hooks |= map(select((.command // "") | test("wakelock hook") | not)))
      | map(select((.hooks | length) > 0))
    )
  )
'

# ---------------------------------------------------------------- アンインストール

if [ "$UNINSTALL" = 1 ]; then
  step "1. スリープ設定を元に戻します"
  [ -x "$BIN_SRC" ] && run "'$BIN_SRC' off >/dev/null 2>&1 || true" && say "解除しました"

  step "2. GUI アプリを取り除きます"
  run "pkill -x Wakelock 2>/dev/null || true"
  [ -d /Applications/Wakelock.app ] && run "rm -rf /Applications/Wakelock.app" && say "削除: /Applications/Wakelock.app"

  step "3. コマンドとプラグインを削除します"
  [ -L "$BIN_DEST" ] && run "rm -f '$BIN_DEST'" && say "削除: $BIN_DEST"
  [ -e "$OPENCODE_PLUGIN_DIR/wakelock.js" ] && run "rm -f '$OPENCODE_PLUGIN_DIR/wakelock.js'" \
    && say "削除: $OPENCODE_PLUGIN_DIR/wakelock.js"

  step "4. Claude Code の hooks を取り除きます"
  if [ -f "$CLAUDE_SETTINGS" ]; then
    run "cp '$CLAUDE_SETTINGS' '$CLAUDE_SETTINGS.bak.\$(date +%Y%m%d%H%M%S)'"
    run "jq 'if .hooks then $CLAUDE_HOOK_STRIP
        | .hooks |= with_entries(select((.value | length) > 0))
        | if (.hooks | length) == 0 then del(.hooks) else . end
      else . end' '$CLAUDE_SETTINGS' > '$CLAUDE_SETTINGS.tmp' && mv '$CLAUDE_SETTINGS.tmp' '$CLAUDE_SETTINGS'"
    say "wakelock の hooks を除去しました"
  fi

  step "5. 特権部分を削除します (パスワードを聞かれます)"
  run "sudo rm -f '$HELPER_DEST' '$SUDOERS_DEST'"
  say "削除: $HELPER_DEST"
  say "削除: $SUDOERS_DEST"

  printf '\n\033[32mアンインストールが完了しました\033[0m\n'
  exit 0
fi

# ---------------------------------------------------------------- 事前確認

step "0. 前提条件を確認します"
[ -x "$BIN_SRC" ]    || { echo "wakelock 本体が実行可能ではありません: $BIN_SRC" >&2; exit 1; }
[ -f "$HELPER_SRC" ] || { echo "helper が見つかりません: $HELPER_SRC" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq が必要です" >&2; exit 1; }
say "必要なファイルが揃っています"

# ---------------------------------------------------------------- 1. 特権部分

step "1. helper と sudoers を設置します (パスワードを聞かれます)"
run "sudo install -d -o root -g wheel -m 0755 /usr/local/libexec"
run "sudo install -o root -g wheel -m 0755 '$HELPER_SRC' '$HELPER_DEST'"
say "設置: $HELPER_DEST"

# sudoers は壊すとログインできなくなるため、必ず検証してから設置する
if [ "$DRY_RUN" = 1 ]; then
  say "(dry-run) $SUDOERS_DEST を検証して設置します"
else
  TMP_SUDOERS="$(mktemp)"
  sed "s|__USER__|$(id -un)|" "$SUDOERS_SRC" > "$TMP_SUDOERS"
  if sudo visudo -cf "$TMP_SUDOERS" >/dev/null 2>&1; then
    sudo install -o root -g wheel -m 0440 "$TMP_SUDOERS" "$SUDOERS_DEST"
    say "設置: $SUDOERS_DEST (visudo で検証済み)"
  else
    rm -f "$TMP_SUDOERS"
    echo "sudoers の検証に失敗しました。設置を中止します。" >&2
    exit 1
  fi
  rm -f "$TMP_SUDOERS"
fi

# ---------------------------------------------------------------- 2. 旧環境の掃除

step "2. 旧 sleep-toggle-menu の残骸を確認します"
if [ "$KEEP_LEGACY" = 1 ]; then
  say "--keep-legacy が指定されたため残します"
elif [ -e "$LEGACY_HELPER" ] || [ -e "$LEGACY_SUDOERS" ]; then
  say "アンインストール済みアプリの特権ファイルが残っています。削除します。"
  run "sudo rm -f '$LEGACY_HELPER' '$LEGACY_SUDOERS'"
  say "削除: $LEGACY_HELPER"
  say "削除: $LEGACY_SUDOERS"
else
  say "残骸はありません"
fi

# ---------------------------------------------------------------- 3. コマンド

step "3. wakelock コマンドを配置します"
[ -d "$(dirname "$BIN_DEST")" ] || { echo "配置先がありません: $(dirname "$BIN_DEST")" >&2; exit 1; }
run "ln -sfn '$BIN_SRC' '$BIN_DEST'"
say "$BIN_DEST -> $BIN_SRC"

# ---------------------------------------------------------------- 4. opencode

step "4. opencode プラグインを配置します"
if [ -d "$HOME/.config/opencode" ]; then
  run "mkdir -p '$OPENCODE_PLUGIN_DIR'"
  run "ln -sfn '$PLUGIN_SRC' '$OPENCODE_PLUGIN_DIR/wakelock.js'"
  say "$OPENCODE_PLUGIN_DIR/wakelock.js -> $PLUGIN_SRC"
else
  say "opencode の設定ディレクトリが見つからないため省略します"
fi

# ---------------------------------------------------------------- 5. Claude Code

step "5. Claude Code の hooks を設定します"
run "mkdir -p '$(dirname "$CLAUDE_SETTINGS")'"
[ -f "$CLAUDE_SETTINGS" ] || run "echo '{}' > '$CLAUDE_SETTINGS'"

# 既存設定を壊さないようイベントごとに配列へ追記する。
# 再実行で重複しないよう、先に wakelock 由来のエントリを除去してから足す。
MERGE_PROGRAM="
  (\$add[0].hooks) as \$new
  | .hooks = (
      (.hooks // {})
      | with_entries(
          .value |= (
            map(.hooks |= map(select((.command // \"\") | test(\"wakelock hook\") | not)))
            | map(select((.hooks | length) > 0))
          )
        )
      | reduce (\$new | keys_unsorted[]) as \$k (.; .[\$k] = ((.[\$k] // []) + \$new[\$k]))
    )
"

if [ "$DRY_RUN" = 1 ]; then
  say "(dry-run) $CLAUDE_SETTINGS へ hooks をマージします"
else
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  TMP_HOOKS="$(mktemp)"
  sed "s|__WAKELOCK_BIN__|$BIN_DEST|g" "$HOOKS_SRC" > "$TMP_HOOKS"
  jq --slurpfile add "$TMP_HOOKS" "$MERGE_PROGRAM" "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp"
  mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
  rm -f "$TMP_HOOKS"
  say "hooks をマージしました (バックアップを同ディレクトリに保存しました)"
fi

# ---------------------------------------------------------------- 6. GUI

step "6. メニューバーアプリをビルドして配置します"
if command -v swiftc >/dev/null; then
  run "make -C '$ROOT/app' install"
  if [ "$DRY_RUN" = 0 ]; then
    run "open /Applications/Wakelock.app"
    say "メニューバーに常駐しました"
  fi
else
  say "swiftc がないため GUI は省略します (CLI のみ導入されました)"
fi

# ---------------------------------------------------------------- 7. 確認

step "7. 動作確認"
[ "$DRY_RUN" = 0 ] && "$BIN_DEST" doctor || true

cat <<'DONE'

導入が完了しました。

  wakelock run claude       蓋を閉じても claude を走らせる
  wakelock run opencode     同上
  wakelock status           現在の状態を見る
  wakelock off              すぐに解除する

メニューバーのアイコンで状態を確認でき、そこから直接 有効化 / 解除 もできます。
Claude Code は再起動すると hooks が読み込まれます。
DONE
