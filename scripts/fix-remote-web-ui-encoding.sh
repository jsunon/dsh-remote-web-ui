#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fix-remote-web-ui-encoding.sh
#
# 修复 @linxin666/dsh-remote-web-ui 经公网中继访问时「整页乱码」的问题。
#
# 病因：dsh-market.com 的中继 worker 会按客户端协商的算法再压一层，
#       却透传 origin 原本的 Content-Encoding 头。于是 Safari 拿到
#       「头说 zstd、正文其实是 gzip」的响应，解码失败 → 满屏符号。
#
# 修法：bridgeUpstreamHeaders() 剔除 accept-encoding，强制向本机 origin
#       要 identity 明文，压缩只由 Cloudflare 边缘做一次、头由边缘自己写，
#       天然一致。
#
# 用法：
#   bash fix-remote-web-ui-encoding.sh              # 修补默认 profile
#   bash fix-remote-web-ui-encoding.sh <profile名>   # 指定 profile
#   DRY_RUN=1 bash fix-remote-web-ui-encoding.sh    # 只检查不写入
#
# 特性：幂等（已打过就跳过）、带锚点校验（结构变了直接报错退出，不乱改）、
#       写前自动备份为 index.js.bak-encfix。
# ---------------------------------------------------------------------------
set -euo pipefail

PROFILE="${1:-desktop}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
TARGET="$DSH_HOME/profiles/$PROFILE/node_modules/@linxin666/dsh-remote-web-ui/lib/index.js"
BACKUP="$TARGET.bak-encfix"
MARKER="LOCAL PATCH (encoding fix)"
ANCHOR_FN='function bridgeUpstreamHeaders(frameHeaders, host) {'
ANCHOR_LOOP='if (BRIDGE_HOP_BY_HOP.has(name.toLowerCase())) continue;'
ANCHOR_HOST='headers.host = host;'

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

echo "目标文件: $TARGET"

if [ ! -f "$TARGET" ]; then
  red "✗ 找不到 index.js。profile「$PROFILE」里没装这个插件？"
  echo "  先确认：ls $DSH_HOME/profiles/$PROFILE/node_modules/@linxin666/"
  exit 1
fi

# --- 幂等检查 -------------------------------------------------------------
if grep -qF "$MARKER" "$TARGET"; then
  green "✓ 已经打过补丁，无需重复操作。"
  exit 0
fi

# --- 锚点校验：三个锚点必须各出现一次，否则宁可不动 -----------------------
for pair in "函数定义|$ANCHOR_FN" "循环内跳过|$ANCHOR_LOOP" "host 赋值|$ANCHOR_HOST"; do
  label="${pair%%|*}"
  anchor="${pair#*|}"
  count=$(grep -cF "$anchor" "$TARGET" || true)
  if [ "$count" -ne 1 ]; then
    red "✗ 锚点「$label」预期出现 1 次，实际 $count 次。"
    red "  插件结构已变，脚本不敢乱改。请人工核对 bridgeUpstreamHeaders()。"
    exit 2
  fi
done
echo "锚点校验通过（3/3）"

# --- 构造补丁后的文件 -----------------------------------------------------
# 不用 mktemp：在 Git Bash 下它可能返回 "C:\...\Temp/tmp.xxx" 这种混合路径，
# 清理阶段会被 safe-delete 守卫拒绝。改为在目标文件旁边建临时文件，同盘同目录。
TMP="${TARGET}.patched.tmp"
trap 'rm -f "$TMP" 2>/dev/null || true' EXIT

# 用 awk 做精确插入：锚点行之后追加对应代码，其余内容逐字节保留
awk -v loop="$ANCHOR_LOOP" -v host="$ANCHOR_HOST" -v marker="$MARKER" '
  {
    line = $0
    sub(/\r$/, "", line)          # 去掉 CRLF 的 CR
    sub(/^[ \t]+/, "", line)      # 去掉行首缩进后比较
    print
  }
  line == loop && !done_loop {
    print "\t\tif (name.toLowerCase() === \"accept-encoding\") continue;"
    done_loop = 1
    next
  }
  line == host {
    if (!done_host) {
      print "\t// " marker ": the relay worker re-compresses the bridged"
      print "\t// body with the client'"'"'s negotiated algorithm while forwarding the origin'"'"'s"
      print "\t// own Content-Encoding, so a gzip origin body reaches a br/zstd browser as"
      print "\t// double-compressed noise. Asking the local origin for an identity body"
      print "\t// leaves exactly one compression step, performed by the edge, which writes"
      print "\t// the matching header itself."
      print "\theaders[\"accept-encoding\"] = \"identity\";"
      done_host = 1
    }
  }
  END {
    if (!done_loop) { print "MISSING_LOOP_ANCHOR" > "/dev/stderr"; exit 3 }
    if (!done_host) { print "MISSING_HOST_ANCHOR" > "/dev/stderr"; exit 3 }
  }
' "$TARGET" > "$TMP"

# --- 写入前复核：行数只应增加 8 行 ----------------------------------------
before=$(wc -l < "$TARGET")
after=$(wc -l < "$TMP")
delta=$((after - before))
echo "行数变化: $before → $after（+$delta）"
if [ "$delta" -ne 8 ]; then
  red "✗ 预期增加 8 行，实际 $delta 行。已中止，原文件未改动。"
  exit 4
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  yellow "DRY_RUN=1：检查通过，未写入。"
  echo "--- 补丁片段预览 ---"
  grep -n -A2 -B2 'accept-encoding' "$TMP" | head -20
  exit 0
fi

# --- 备份并写入 -----------------------------------------------------------
if [ -f "$TARGET" ] && [ ! -f "$BACKUP" ]; then
  cp -p "$TARGET" "$BACKUP"
  echo "已备份: $BACKUP"
elif [ -f "$BACKUP" ]; then
  yellow "备份已存在，保留更早的原件: $BACKUP"
fi

cat "$TMP" > "$TARGET"
green "✓ 补丁已写入"

echo
echo "接下来：重启 DSH 让补丁加载（或插件面板里重载），然后验证："
echo "  curl -s -D- -o /tmp/b.bin https://<你的publicUrl>/pair-app -H 'Accept-Encoding: gzip, deflate, br, zstd'"
echo "  看响应头 Content-Encoding 与正文魔数是否一致："
echo "    zstd → 28 b5 2f fd     gzip → 1f 8b     identity → 3c 21 64 6f (<!do)"
