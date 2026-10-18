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
# broken フラグがあると失敗する (helper の実行失敗を再現する)
[ -f "$WORK/helper_broken" ] && exit 1
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
echo "16. 手動の有効化が期限切れになると hold も消え、自動モードの承認待ちで起き続けない"
"$WL" auto off >/dev/null 2>&1
"$WL" off >/dev/null 2>&1
echo 0 >"$SLEEP_STATE"
# この節で書かれた行だけを見たいのでログを空にする
: >"$WAKELOCK_STATE_DIR/log"
"$WL" on 5s >/dev/null 2>&1
check 1 "手動の有効化で無効化される"
check_holds 1 "手動の hold が作られる"
wait_for 0 15
check 0 "期限切れで自動解除される"
check_holds 0 "手動の hold も一緒に消える"
if grep -q "手動の有効化が終了" "$WAKELOCK_STATE_DIR/log" 2>/dev/null; then
  printf '  \033[32mPASS\033[0m  hold の失効が記録される\n'; PASS=$((PASS + 1))
else
  printf '  \033[31mFAIL\033[0m  hold の失効が記録されていない\n'; FAIL=$((FAIL + 1))
fi

"$WL" auto on >/dev/null 2>&1
"$WL" acquire s16 --pid $$ --label claude >/dev/null 2>&1
check 1 "自動モードのエージェントが作業を始めると有効になる"
"$WL" release s16 >/dev/null 2>&1
check 0 "承認待ちで解除され、残った手動の hold で起き続けない"
"$WL" auto off >/dev/null 2>&1
"$WL" off >/dev/null 2>&1

"$WL" on 1h >/dev/null 2>&1
# ガード (GUARD_INTERVAL=1) が何周か回る時間を待つ
sleep 3
check_holds 1 "手動の arm が生きている間は手動の hold を消さない"
check 1 "手動の arm が生きている間は有効のまま"
"$WL" auto off >/dev/null 2>&1
"$WL" off >/dev/null 2>&1

echo
echo "17. 外部からの SleepDisabled の上書きを検出して戻し、有効中は短い間隔で見張る"
"$WL" auto off >/dev/null 2>&1
"$WL" off >/dev/null 2>&1
rm -f "$WAKELOCK_STATE_DIR/overrides"
: >"$WAKELOCK_STATE_DIR/log"
echo 0 >"$SLEEP_STATE"

# ガードの終了を条件待ちする
wait_guard_gone() {
  local i=0
  while [ -f "$WAKELOCK_STATE_DIR/guard.pid" ] && [ "$i" -lt 150 ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

# 通常の遷移は上書きに数えない
"$WL" on 10m >/dev/null 2>&1
"$WL" off >/dev/null 2>&1
"$WL" on 10m >/dev/null 2>&1
got="$("$WL" status --json 2>/dev/null | jq -c '[.overrides.lastHour, .overrides.last]')"
if [ "$got" = "[0,null]" ]; then
  printf '  \033[32mPASS\033[0m  通常の遷移は上書きに数えない (%s)\n' "$got"; PASS=$((PASS + 1))
else
  printf '  \033[31mFAIL\033[0m  通常の遷移が上書きに数えられた (期待 [0,null] / 実際 %s)\n' "$got"; FAIL=$((FAIL + 1))
fi

# 外部から 0 に戻されると検出して戻す
echo 0 >"$SLEEP_STATE"
wait_for 1 5
check 1 "外部から 0 にされても 1 に戻される"
n="$(grep -c "外部による上書きを検出" "$WAKELOCK_STATE_DIR/log" 2>/dev/null)"
if [ "$n" = "1" ]; then
  printf '  \033[32mPASS\033[0m  ログに上書きの検出が 1 行ある\n'; PASS=$((PASS + 1))
else
  printf '  \033[31mFAIL\033[0m  ログの検出行 (期待 1 / 実際 %s)\n' "$n"; FAIL=$((FAIL + 1))
fi
got="$("$WL" status --json 2>/dev/null | jq -r '.overrides.lastHour')"
if [ "$got" = "1" ]; then
  printf '  \033[32mPASS\033[0m  status --json の lastHour が 1\n'; PASS=$((PASS + 1))
else
  printf '  \033[31mFAIL\033[0m  lastHour (期待 1 / 実際 %s)\n' "$got"; FAIL=$((FAIL + 1))
fi
out="$("$WL" status 2>/dev/null)"
if printf '%s' "$out" | grep -q "外部の上書き"; then
  printf '  \033[32mPASS\033[0m  status に「外部の上書き」が出る\n'; PASS=$((PASS + 1))
else
  printf '  \033[31mFAIL\033[0m  status に「外部の上書き」が出ない\n'; FAIL=$((FAIL + 1))
fi
out="$("$WL" doctor 2>&1)"
if printf '%s' "$out" | grep -q "\[警告\]"; then
  printf '  \033[32mPASS\033[0m  doctor が警告を出す\n'; PASS=$((PASS + 1))
else
  printf '  \033[31mFAIL\033[0m  doctor が警告を出さない\n'; FAIL=$((FAIL + 1))
fi

# 有効中は短い間隔で見張る
"$WL" off >/dev/null 2>&1
wait_guard_gone
WAKELOCK_GUARD_INTERVAL=6 WAKELOCK_GUARD_WATCH_INTERVAL=1 "$WL" on 10m >/dev/null 2>&1
sleep 1.5
echo 0 >"$SLEEP_STATE"
wait_for 1 3
check 1 "通常の間隔 (6 秒) より短い 3 秒以内に戻される"
"$WL" off >/dev/null 2>&1
wait_guard_gone
if [ -f "$WAKELOCK_STATE_DIR/guard.pid" ]; then
  printf '  \033[31mFAIL\033[0m  ガードが終了していない\n'; FAIL=$((FAIL + 1))
else
  printf '  \033[32mPASS\033[0m  ガードが終了している\n'; PASS=$((PASS + 1))
fi

echo
echo "18. 見張りは有効にした直後から働き、適用の失敗や読み取り失敗では空回りしない"
"$WL" auto off >/dev/null 2>&1
"$WL" off >/dev/null 2>&1
wait_guard_gone
rm -f "$WAKELOCK_STATE_DIR/overrides" "$WORK/helper_broken" "$WORK/pmset_broken"
: >"$WAKELOCK_STATE_DIR/log"
echo 0 >"$SLEEP_STATE"

lasthour() { "$WL" status --json 2>/dev/null | jq -r '.overrides.lastHour'; }

# arm だけの状態 (まだ無効) でガードを起動し、後から acquire で有効にする。
# hooks がプロンプトごとに有効にする流れと同じ
WAKELOCK_GUARD_INTERVAL=6 WAKELOCK_GUARD_WATCH_INTERVAL=1 "$WL" on --hooked 10m >/dev/null 2>&1
sleep 1.5
"$WL" acquire s18 --pid $$ --label claude >/dev/null 2>&1
check 1 "acquire で有効になる"
echo 0 >"$SLEEP_STATE"
wait_for 1 3
check 1 "有効にした直後でも、通常の間隔 (6 秒) より短い 3 秒以内に戻される"

# 適用に失敗し続けても、上書きとして数え続けない
rm -f "$WAKELOCK_STATE_DIR/overrides"
: >"$WORK/helper_broken"
echo 0 >"$SLEEP_STATE"
sleep 8   # 見張り (1 秒) と巡回 (6 秒) を何度か回す
got="$(lasthour)"
if [ "$got" = "1" ]; then
  printf '  \033[32mPASS\033[0m  helper が失敗し続けても上書きは 1 回だけ数える\n'; PASS=$((PASS + 1))
else
  printf '  \033[31mFAIL\033[0m  helper の失敗中の上書きの回数 (期待 1 / 実際 %s)\n' "$got"; FAIL=$((FAIL + 1))
fi
rm -f "$WORK/helper_broken"
wait_for 1 8
check 1 "helper が直ると巡回で 1 に戻る"
got="$(lasthour)"
if [ "$got" = "1" ]; then
  printf '  \033[32mPASS\033[0m  復旧は上書きに数えない\n'; PASS=$((PASS + 1))
else
  printf '  \033[31mFAIL\033[0m  復旧が上書きに数えられた (期待 1 / 実際 %s)\n' "$got"; FAIL=$((FAIL + 1))
fi

# pmset が読めない間は、見張りが再計算を起こさない (巡回の分は起きてよい)
sleep 1
: >"$WAKELOCK_STATE_DIR/log"
: >"$WORK/pmset_broken"
sleep 3.5
rm -f "$WORK/pmset_broken"
n="$(grep -c "読み取れず" "$WAKELOCK_STATE_DIR/log" 2>/dev/null)"
if [ "${n:-0}" -le 1 ]; then
  printf '  \033[32mPASS\033[0m  pmset が読めない間、見張りは再計算を起こさない (%s 回)\n' "${n:-0}"; PASS=$((PASS + 1))
else
  printf '  \033[31mFAIL\033[0m  pmset が読めない間に再計算が続いた (期待 1 回以下 / 実際 %s 回)\n' "$n"; FAIL=$((FAIL + 1))
fi

"$WL" release s18 >/dev/null 2>&1
"$WL" off >/dev/null 2>&1
wait_guard_gone

echo
echo "19. 作業中にガードが落ちても、次の acquire (高速パス) で起動し直す"
"$WL" auto off >/dev/null 2>&1
"$WL" off >/dev/null 2>&1
wait_guard_gone
: >"$WAKELOCK_STATE_DIR/log"
echo 0 >"$SLEEP_STATE"

guard_running() {
  local g
  g="$(cat "$WAKELOCK_STATE_DIR/guard.pid" 2>/dev/null)"
  [ -n "$g" ] && kill -0 "$g" 2>/dev/null
}

"$WL" on --hooked 10m >/dev/null 2>&1
"$WL" acquire s19 --pid $$ --label claude >/dev/null 2>&1
check 1 "作業中で有効"
old_guard="$(cat "$WAKELOCK_STATE_DIR/guard.pid" 2>/dev/null)"

# 同じ hold への acquire はガードが生きていれば高速パスで返り、ガードを増やさない
"$WL" acquire s19 --pid $$ --label claude >/dev/null 2>&1
n="$(grep -c "ガード起動" "$WAKELOCK_STATE_DIR/log" 2>/dev/null)"
if [ "$n" = "1" ]; then
  printf '  \033[32mPASS\033[0m  ガードが生きていれば高速パスのまま (ガード起動 %s 回)\n' "$n"; PASS=$((PASS + 1))
else
  printf '  \033[31mFAIL\033[0m  ガードの起動回数 (期待 1 / 実際 %s)\n' "$n"; FAIL=$((FAIL + 1))
fi

# ガードを落とす (クラッシュを模す)。guard.pid は古い PID のまま残る
kill "$old_guard" 2>/dev/null
i=0
while kill -0 "$old_guard" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done

"$WL" acquire s19 --pid $$ --label claude >/dev/null 2>&1
if guard_running && [ "$(cat "$WAKELOCK_STATE_DIR/guard.pid")" != "$old_guard" ]; then
  printf '  \033[32mPASS\033[0m  落ちたガードを次の acquire で起動し直す\n'; PASS=$((PASS + 1))
else
  printf '  \033[31mFAIL\033[0m  ガードが起動し直されていない\n'; FAIL=$((FAIL + 1))
fi
check 1 "起動し直しても有効のまま"

"$WL" release s19 >/dev/null 2>&1
"$WL" off >/dev/null 2>&1
wait_guard_gone

echo
printf '結果: \033[32m%d PASS\033[0m / \033[31m%d FAIL\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
