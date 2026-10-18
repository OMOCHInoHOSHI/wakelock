#!/usr/bin/env bash
# wakelock の中核ロジックを、実際の pmset を叩かずに検証する。
# pmset と sudo をスタブに差し替え、SleepDisabled の遷移をファイルで観測する。

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'pkill -f "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

SLEEP_STATE="$WORK/sleepdisabled"
echo 0 >"$SLEEP_STATE"

# 本物の pmset は SleepDisabled が 0 のとき行自体を出さないことがある。
# その挙動まで含めて再現する。
cat >"$WORK/pmset" <<PMSET_EOF
#!/usr/bin/env bash
# broken フラグがあると何も出力しない (pmset の読み取り失敗を再現する)
[ -f "$WORK/pmset_broken" ] && exit 0
if [ "\${1:-}" = "-g" ]; then
  echo " sleep                1"
  [ "\$(cat "$SLEEP_STATE")" = "1" ] && echo " SleepDisabled        1"
fi
exit 0
PMSET_EOF

cat >"$WORK/helper" <<HELPER_EOF
#!/usr/bin/env bash
echo "\$1" >"$SLEEP_STATE"
HELPER_EOF

chmod +x "$WORK/pmset" "$WORK/helper"

export WAKELOCK_STATE_DIR="$WORK/state"
export WAKELOCK_PMSET="$WORK/pmset"
export WAKELOCK_HELPER="$WORK/helper"
export WAKELOCK_SUDO=""          # スタブは sudo なしで直接実行する
export WAKELOCK_GUARD_INTERVAL=1

WL="$ROOT/bin/wakelock"

PASS=0
FAIL=0

check() {
  local want="$1" desc="$2" got
  got="$(cat "$SLEEP_STATE")"
  if [ "$got" = "$want" ]; then
    printf '  \033[32mPASS\033[0m  %s (SleepDisabled=%s)\n' "$desc" "$got"
    PASS=$((PASS + 1))
  else
    printf '  \033[31mFAIL\033[0m  %s (期待 %s / 実際 %s)\n' "$desc" "$want" "$got"
    FAIL=$((FAIL + 1))
  fi
}

# 固定の sleep はガードの起動タイミング次第で揺れるため、条件が満たされるまで待つ
wait_for() {
  local want="$1" limit="${2:-10}" i=0
  while [ "$(cat "$SLEEP_STATE")" != "$want" ] && [ "$i" -lt $((limit * 10)) ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

check_holds() {
  local want="$1" desc="$2" got
  got="$(ls "$WAKELOCK_STATE_DIR/hold" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$got" = "$want" ]; then
    printf '  \033[32mPASS\033[0m  %s (hold=%s)\n' "$desc" "$got"
    PASS=$((PASS + 1))
  else
    printf '  \033[31mFAIL\033[0m  %s (期待 %s / 実際 %s)\n' "$desc" "$want" "$got"
    FAIL=$((FAIL + 1))
  fi
}

echo
echo "1. arm していないセッションからの acquire は無視される (opt-in の担保)"
"$WL" acquire session-x --label test >/dev/null 2>&1
check_holds 0 "hold が作られない"
check 0 "スリープ無効化されない"

echo
echo "2. hooked モードで arm すると、arm だけではまだ無効化しない"
"$WL" on --hooked 10m >/dev/null 2>&1
check 0 "arm のみではスリープ可のまま"

echo
echo "3. acquire で作業開始 → 蓋閉じ有効"
"$WL" acquire session-x --label test >/dev/null 2>&1
check_holds 1 "hold が 1 つ"
check 1 "スリープ無効化される"

echo
echo "4. release で承認待ち → 通常のスリープ設定に戻る (要件2)"
"$WL" release session-x >/dev/null 2>&1
check 0 "承認待ちではスリープ可に戻る"

echo
echo "5. 承認後の再 acquire で復帰"
"$WL" acquire session-x --label test >/dev/null 2>&1
check 1 "再び無効化される"

echo
echo "6. off ですべて解除"
"$WL" off >/dev/null 2>&1
check 0 "解除される"
check_holds 0 "hold が消える"

echo
echo "7. always モードの run はコマンド実行中だけ有効化し、終了時に解除する"
echo 0 >"$SLEEP_STATE"
"$WL" run --always -- bash -c "cat '$SLEEP_STATE' > '$WORK/during'" >/dev/null 2>&1
printf '  実行中の値: %s\n' "$(cat "$WORK/during")"
if [ "$(cat "$WORK/during")" = "1" ]; then
  printf '  \033[32mPASS\033[0m  実行中は無効化されている\n'; PASS=$((PASS + 1))
else
  printf '  \033[31mFAIL\033[0m  実行中に無効化されていない\n'; FAIL=$((FAIL + 1))
fi
check 0 "コマンド終了で自動解除される (要件4)"

echo
echo "8. コマンドが異常終了しても解除される"
echo 0 >"$SLEEP_STATE"
"$WL" run --always -- bash -c "exit 3" >/dev/null 2>&1
printf '  終了コード: %s\n' "$?"
check 0 "異常終了でも解除される"

echo
echo "9. 期限切れの arm はガードが失効させる"
# 期限は acquire が終わるまで確実に生きている長さにする。
# 1s だとプロセス起動と祖先 PID 走査の間に切れてテストが揺れる。
"$WL" on --hooked 5s >/dev/null 2>&1
"$WL" acquire session-y --label test >/dev/null 2>&1
check 1 "有効化された"
wait_for 0 15
check 0 "期限切れで自動解除される"

echo
echo "10. 自動モードなら run を打たなくても hooks だけで完結する"
echo 0 >"$SLEEP_STATE"
"$WL" off >/dev/null 2>&1
"$WL" acquire auto-test --pid $$ --label claude >/dev/null 2>&1
check 0 "自動モード無効なら acquire は無視される"

"$WL" auto on >/dev/null 2>&1
"$WL" acquire auto-test --pid $$ --label claude >/dev/null 2>&1
check 1 "自動モード有効なら acquire だけで蓋閉じが有効になる"
arms_now="$(ls "$WAKELOCK_STATE_DIR/arm" 2>/dev/null | tr '\n' ' ')"
printf '  自動生成された arm: %s\n' "$arms_now"
if printf '%s' "$arms_now" | grep -q "auto-$$"; then
  printf '  \033[32mPASS\033[0m  呼び出し元 PID に束縛された arm が作られる\n'; PASS=$((PASS + 1))
else
  printf '  \033[31mFAIL\033[0m  arm が作られていない\n'; FAIL=$((FAIL + 1))
fi

"$WL" release auto-test >/dev/null 2>&1
check 0 "承認待ちでは解除される (自動モードでも要件2は維持)"

"$WL" acquire auto-test --pid $$ --label claude >/dev/null 2>&1
check 1 "再開で復帰する"

echo
echo "11. 自動モードを切ると自動生成された arm も取り下げられる"
"$WL" auto off >/dev/null 2>&1
check 0 "解除される"
if [ -z "$(ls "$WAKELOCK_STATE_DIR/arm" 2>/dev/null)" ]; then
  printf '  \033[32mPASS\033[0m  自動生成の arm が消える\n'; PASS=$((PASS + 1))
else
  printf '  \033[31mFAIL\033[0m  arm が残っている\n'; FAIL=$((FAIL + 1))
fi

echo
echo "12. 手動の無期限は期限で失効しない"
"$WL" off >/dev/null 2>&1
"$WL" auto off >/dev/null 2>&1
echo 0 >"$SLEEP_STATE"
"$WL" on 0 >/dev/null 2>&1
check 1 "無期限で有効化される"
expiry="$("$WL" status --json | jq -r '.arms[0].expiry')"
remaining="$("$WL" status --json | jq -r '.arms[0].remaining')"
if [ "$expiry" = "0" ] && [ "$remaining" = "null" ]; then
  printf '  \033[32mPASS\033[0m  expiry=0 / remaining=null (無期限)\n'; PASS=$((PASS + 1))
else
  printf '  \033[31mFAIL\033[0m  expiry=%s remaining=%s\n' "$expiry" "$remaining"; FAIL=$((FAIL + 1))
fi
sleep 3
check 1 "時間が経っても失効しない"

echo
echo "13. 解除しても自動モードなら次の作業で arm が復活する"
"$WL" auto on >/dev/null 2>&1
"$WL" acquire revive-test --pid $$ --label claude >/dev/null 2>&1
check 1 "自動 arm で有効化"
"$WL" off >/dev/null 2>&1
check 0 "解除された"
if [ -z "$(ls "$WAKELOCK_STATE_DIR/arm" 2>/dev/null)" ]; then
  printf '  \033[32mPASS\033[0m  arm が消えている\n'; PASS=$((PASS + 1))
else
  printf '  \033[31mFAIL\033[0m  arm が残っている\n'; FAIL=$((FAIL + 1))
fi
"$WL" acquire revive-test --pid $$ --label claude >/dev/null 2>&1
check 1 "次の acquire で自動的に復活する"
"$WL" auto off >/dev/null 2>&1
"$WL" off >/dev/null 2>&1

echo
echo "14. pmset が読めなくても適用は行われ、偽の状態遷移をログに残さない"
"$WL" off >/dev/null 2>&1
echo 0 >"$SLEEP_STATE"
# この節で書かれた行だけを見たいのでログを空にする
: >"$WAKELOCK_STATE_DIR/log"
: >"$WORK/pmset_broken"
"$WL" on 30m >/dev/null 2>&1
check 1 "読み取り失敗でも有効化される"
if grep -q "適用前の値は読み取れず" "$WAKELOCK_STATE_DIR/log" 2>/dev/null; then
  printf '  \033[32mPASS\033[0m  読み取り失敗として記録される\n'; PASS=$((PASS + 1))
else
  printf '  \033[31mFAIL\033[0m  読み取り失敗が記録されていない\n'; FAIL=$((FAIL + 1))
fi
if grep -q "SleepDisabled 0 -> 1" "$WAKELOCK_STATE_DIR/log" 2>/dev/null; then
  printf '  \033[31mFAIL\033[0m  偽の状態遷移が記録されている\n'; FAIL=$((FAIL + 1))
else
  printf '  \033[32mPASS\033[0m  偽の状態遷移は記録されない\n'; PASS=$((PASS + 1))
fi
rm -f "$WORK/pmset_broken"
"$WL" off >/dev/null 2>&1

echo
echo "15. run の arm はラベル一致の acquire だけを、子孫でないプロセスからも受け付ける"
"$WL" auto off >/dev/null 2>&1
"$WL" off >/dev/null 2>&1
echo 0 >"$SLEEP_STATE"
rm -f "$WORK/opencode_done"
# basename が opencode になる偽コマンド。合図のファイルができるか、一定時間で終わる
cat >"$WORK/opencode" <<'FAKE_EOF'
#!/usr/bin/env bash
i=0
while [ ! -f "$(dirname "$0")/opencode_done" ] && [ "$i" -lt 300 ]; do
  sleep 0.1
  i=$((i + 1))
done
FAKE_EOF
chmod +x "$WORK/opencode"
"$WL" run "$WORK/opencode" >/dev/null 2>&1 &
RUN_PID=$!
i=0
while ! ls "$WAKELOCK_STATE_DIR/arm"/run-* >/dev/null 2>&1 && [ "$i" -lt 100 ]; do
  sleep 0.1
  i=$((i + 1))
done
# テストのシェルはラッパーの親なので、--pid $$ の祖先にラッパーは含まれない
"$WL" acquire opencode-s1 --pid $$ --label opencode >/dev/null 2>&1
check_holds 0 "--match-label なしは無視される"
check 0 "スリープ無効化されない (match-label なし)"
"$WL" acquire opencode-s1 --pid $$ --label claude --match-label >/dev/null 2>&1
check_holds 0 "ラベル不一致は無視される"
check 0 "スリープ無効化されない (ラベル不一致)"
"$WL" acquire opencode-s1 --pid $$ --label opencode --match-label >/dev/null 2>&1
check_holds 1 "ラベル一致なら hold が作られる"
wait_for 1 5
check 1 "スリープ無効化される (ラベル一致)"
touch "$WORK/opencode_done"
wait "$RUN_PID" 2>/dev/null
wait_for 0 15
check 0 "ラッパー終了で run の arm が消え、スリープ可に戻る"
"$WL" release opencode-s1 >/dev/null 2>&1
"$WL" off >/dev/null 2>&1
rm -f "$WORK/opencode_done"

echo
printf '結果: \033[32m%d PASS\033[0m / \033[31m%d FAIL\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
