#!/usr/bin/env bash
# ルール判定（decide_layout）のテスト
#   偽のデバイス一覧（tests/fixtures/）を渡して、選ばれる配列を確かめる
#   実行: tests/test_decide_layout.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=bin/hotplug-layout
source bin/hotplug-layout

FIXTURES=tests/fixtures
failed=0

# check "説明" デバイス一覧 ルール 期待する配列
check() {
  local desc="$1" devices="$2" rules="$3" expected="$4" actual
  actual=$(INPUT_DEVICES="$FIXTURES/$devices" KEYBOARD_RULES="$rules" DEFAULT_LAYOUT=jp \
    decide_layout 2>/dev/null)
  if [[ "$actual" == "$expected" ]]; then
    printf 'ok    %s\n' "$desc"
  else
    printf 'FAIL  %s（期待: %s, 実際: %s）\n' "$desc" "$expected" "$actual"
    failed=1
  fi
}

check "外付けなし → 既定値"           devices-builtin-only.txt    'Keychron K2=us'                jp
check "US を接続"                     devices-with-us.txt         'Keychron K2=us'                us
check "JIS の外付けを接続"            devices-with-us-and-jis.txt 'REALFORCE=jp'                  jp
check "両方接続 → 後に繋いだ JIS"     devices-with-us-and-jis.txt 'Keychron K2=us;REALFORCE=jp'   jp
check "両方接続 → ルールの順は無関係" devices-with-us-and-jis.txt 'REALFORCE=jp;Keychron K2=us'   jp
check "両方接続 → 後に繋いだ US"      devices-with-jis-then-us.txt 'Keychron K2=us;REALFORCE=jp'  us
check "1台が複数ルールに一致 → 先のルール" devices-with-us.txt     'Keychron K2=us;Keychron=jp'    us
check "大文字小文字を区別しない"      devices-with-us.txt         'keychron k2=us'                us
check "| で複数指定"                  devices-with-us.txt         'HHKB|Keychron=us'              us
check "当てはまらない → 既定値"       devices-with-us.txt         'HHKB=us'                       jp
check "不正なルールは無視"            devices-with-us.txt         'bad;;Keychron K2=us'           us
check "ルールが空 → 既定値"           devices-with-us.txt         ''                              jp

if (( failed )); then
  echo "テストに失敗しました"
  exit 1
fi
echo "すべてのテストに成功しました"
