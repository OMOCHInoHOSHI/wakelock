#!/usr/bin/env bash
# wakelock のインストーラ
#
#   ./install.sh            すべて導入する
#   ./install.sh --dry-run  何をするか表示するだけ
#   ./install.sh --uninstall 導入したものを取り除く

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN_SRC="$ROOT/bin/wakelock"
PLUGIN_SRC="$ROOT/adapters/opencode/wakelock.js"
HOOKS_SRC="$ROOT/adapters/claude/hooks.json"

BIN_DEST="${WAKELOCK_BIN_DEST:-/opt/homebrew/bin/wakelock}"
OPENCODE_PLUGIN_DIR="$HOME/.config/opencode/plugin"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

DRY_RUN=0
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    *) echo "不明なオプション: $arg" >&2; exit 64 ;;
  esac
done

say()  { printf '  %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
run()  { if [ "$DRY_RUN" = 1 ]; then say "(dry-run) $*"; else eval "$@"; fi; }

# ---------------------------------------------------------------- アンインストール

if [ "$UNINSTALL" = 1 ]; then
  step "1. スリープ設定を元に戻します"
  if [ -x "$BIN_SRC" ]; then
    run "'$BIN_SRC' off >/dev/null 2>&1 || true"
    say "解除しました"
  fi

  step "2. コマンドを削除します"
  [ -L "$BIN_DEST" ] && run "rm -f '$BIN_DEST'" && say "削除: $BIN_DEST"

  step "3. opencode プラグインを削除します"
  [ -e "$OPENCODE_PLUGIN_DIR/wakelock.js" ] && run "rm -f '$OPENCODE_PLUGIN_DIR/wakelock.js'" \
    && say "削除: $OPENCODE_PLUGIN_DIR/wakelock.js"

  step "4. Claude Code の hooks を取り除きます"
  if [ -f "$CLAUDE_SETTINGS" ]; then
    run "cp '$CLAUDE_SETTINGS' '$CLAUDE_SETTINGS.bak.\$(date +%Y%m%d%H%M%S)'"
    run "jq '
      if .hooks then
        .hooks |= with_entries(
          .value |= (
            map(.hooks |= map(select((.command // \"\") | test(\"wakelock hook\") | not)))
            | map(select((.hooks | length) > 0))
          )
        )
        | .hooks |= with_entries(select((.value | length) > 0))
        | if (.hooks | length) == 0 then del(.hooks) else . end
      else . end
    ' '$CLAUDE_SETTINGS' > '$CLAUDE_SETTINGS.tmp' && mv '$CLAUDE_SETTINGS.tmp' '$CLAUDE_SETTINGS'"
    say "wakelock の hooks を除去しました"
  fi

  printf '\n\033[32mアンインストールが完了しました\033[0m\n'
  exit 0
fi

# ---------------------------------------------------------------- 事前確認

step "0. 前提条件を確認します"
[ -x "$BIN_SRC" ] || { echo "wakelock 本体が実行可能ではありません: $BIN_SRC" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq が必要です" >&2; exit 1; }

if sudo -n -l 2>/dev/null | grep -qF "sleep-toggle-helper"; then
  say "sudo の NOPASSWD 設定を確認しました"
else
  say "警告: sleep-toggle-helper の NOPASSWD 設定が見つかりません"
  say "      導入は続行しますが、実際のスリープ制御は失敗します"
fi

# ---------------------------------------------------------------- 1. コマンド

step "1. wakelock コマンドを配置します"
if [ -d "$(dirname "$BIN_DEST")" ]; then
  run "ln -sfn '$BIN_SRC' '$BIN_DEST'"
  say "$BIN_DEST -> $BIN_SRC"
else
  say "配置先がありません: $(dirname "$BIN_DEST")"
  exit 1
fi

# ---------------------------------------------------------------- 2. opencode

step "2. opencode プラグインを配置します"
if [ -d "$HOME/.config/opencode" ]; then
  run "mkdir -p '$OPENCODE_PLUGIN_DIR'"
  run "ln -sfn '$PLUGIN_SRC' '$OPENCODE_PLUGIN_DIR/wakelock.js'"
  say "$OPENCODE_PLUGIN_DIR/wakelock.js -> $PLUGIN_SRC"
else
  say "opencode の設定ディレクトリが見つからないため省略します"
fi

# ---------------------------------------------------------------- 3. Claude Code

step "3. Claude Code の hooks を設定します"
run "mkdir -p '$(dirname "$CLAUDE_SETTINGS")'"
[ -f "$CLAUDE_SETTINGS" ] || run "echo '{}' > '$CLAUDE_SETTINGS'"

# 既存の設定を壊さないよう、イベントごとに配列へ追記する。
# 再実行時に重複しないよう、先に wakelock 由来のエントリを除去してから足す。
MERGE_PROGRAM='
  ($add[0].hooks) as $new
  | .hooks = (
      (.hooks // {})
      | with_entries(
          .value |= (
            map(.hooks |= map(select((.command // "") | test("wakelock hook") | not)))
            | map(select((.hooks | length) > 0))
          )
        )
      | reduce ($new | keys_unsorted[]) as $k (.; .[$k] = ((.[$k] // []) + $new[$k]))
    )
'

if [ "$DRY_RUN" = 1 ]; then
  say "(dry-run) $CLAUDE_SETTINGS へ hooks をマージします"
  sed "s|__WAKELOCK_BIN__|$BIN_DEST|g" "$HOOKS_SRC" \
    | jq --slurpfile add /dev/stdin "$MERGE_PROGRAM" "$CLAUDE_SETTINGS" 2>/dev/null \
    | head -40 || true
else
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  TMP_HOOKS="$(mktemp)"
  sed "s|__WAKELOCK_BIN__|$BIN_DEST|g" "$HOOKS_SRC" > "$TMP_HOOKS"
  jq --slurpfile add "$TMP_HOOKS" "$MERGE_PROGRAM" "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp"
  mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
  rm -f "$TMP_HOOKS"
  say "hooks をマージしました (バックアップを同ディレクトリに保存しました)"
fi

# ---------------------------------------------------------------- 完了

step "4. 動作確認"
if [ "$DRY_RUN" = 0 ]; then
  "$BIN_DEST" doctor || true
fi

cat <<'DONE'

導入が完了しました。使い方:

  wakelock run claude       蓋を閉じても claude を走らせる
  wakelock run opencode     同上
  wakelock status           現在の状態を見る
  wakelock off              すぐに解除する

Claude Code は再起動すると hooks が読み込まれます。
DONE
