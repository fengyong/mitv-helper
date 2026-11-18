#!/bin/bash
# MiTV Helper · FTP 引擎端到端测试（ARCHITECTURE.md §5 E2E）
#
# 服务器：pyftpdlib（pip3 install --user）@ 127.0.0.1:2122，匿名读写，允许 DELE/RNFR/RNTO/MKD。
# 关键配置：handler.encoding = "gbk" —— 模拟电视端（SwiFTP）行为：
#   引擎按 GBK 发命令 → 服务器按 GBK 解码 → 落盘自动转 UTF-8 存储 → LIST 再按 GBK 编码返回。
#   （本机 APFS 拒绝非 UTF-8 字节文件名，GBK 落盘必须经服务端转码；这与电视端"GBK 通道+自有存储"等价。）
# 工作目录：/tmp/mitv-e2e-<pid>/（remote=服务器根，local=客户端素材）
# 退出码：0 = 全部通过；1 = 有失败。临时目录记录于 docs/DELETE_PENDING_A.md。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTL="$ROOT/build/mitvctl"
WORK="/tmp/mitv-e2e-$$"
REMOTE="$WORK/remote"
LOCAL="$WORK/local"
PORT=2122
PASS=0
FAIL=0
SERVER_PID=""

# 工作目录先行创建（pip 日志等在此之前就有重定向写入）
mkdir -p "$WORK"

ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
ng()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
# check <说明> <命令...>
check() {
  local desc="$1"; shift
  if "$@" >"$WORK/last.out" 2>"$WORK/last.err"; then
    ok "$desc"
  else
    ng "$desc  [rc=$?] out=$(tail -c 200 "$WORK/last.out" | tr '\n' ' ') err=$(tail -c 200 "$WORK/last.err" | tr '\n' ' ')"
  fi
}
check_fail() {
  local desc="$1"; shift
  if "$@" >"$WORK/last.out" 2>"$WORK/last.err"; then
    ng "$desc  [预期失败但 rc=0]"
  else
    ok "$desc"
  fi
}

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
}
trap cleanup EXIT

echo "── 1. 依赖与构建 ─────────────────────────────"
if ! python3 -c "import pyftpdlib" >/dev/null 2>&1; then
  echo "  安装 pyftpdlib（--user，官方 PyPI 源）..."
  pip3 install --user --index-url https://pypi.org/simple pyftpdlib >"$WORK/pip.log" 2>&1 || {
    echo "  ❌ pyftpdlib 安装失败"; cat "$WORK/pip.log"; exit 1
  }
fi
mkdir -p "$REMOTE/Movies" "$REMOTE/Pictures" "$LOCAL"
echo "  ✅ pyftpdlib 可用"

make -C "$ROOT" cli >"$WORK/make.log" 2>&1 || { echo "  ❌ make cli 失败"; tail -20 "$WORK/make.log"; exit 1; }
echo "  ✅ make cli"

echo "── 2. 准备素材与服务器 ───────────────────────"
# 端口占用硬校验：防残留旧服务器干扰本轮结果
if python3 -c "import socket; socket.create_connection(('127.0.0.1',$PORT),0.5).close()" 2>/dev/null; then
  echo "  ❌ 端口 $PORT 已被占用（疑似残留 FTP 服务器，先清理再跑）"; exit 1
fi
# 预置远端中文名文件（服务器根，GBK 通道可见）
printf '预置内容-电视已有文件\n' > "$REMOTE/测试文件.txt"
# 客户端素材：1MB 随机 + 其中前 512KB 作为半程文件（APPE 续传模拟）
head -c 1048576 /dev/urandom > "$LOCAL/周岁生日 [高清].mp4"
head -c 524288 "$LOCAL/周岁生日 [高清].mp4" > "$LOCAL/half.bin"

cat > "$WORK/server.py" <<EOF
import sys
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import FTPServer
auth = DummyAuthorizer()
auth.add_anonymous(sys.argv[1], perm="elradfmwMT")
h = FTPHandler
h.authorizer = auth
h.encoding = "gbk"            # 模拟电视端 GBK 控制通道
h.unicode_errors = "replace"
h.passive_ports = range(41000, 41100)
h.log_line = False
FTPServer(("127.0.0.1", $PORT), h).serve_forever()
EOF
python3 "$WORK/server.py" "$REMOTE" >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
for i in $(seq 1 50); do
  python3 -c "import socket; socket.create_connection(('127.0.0.1',$PORT),0.2).close()" 2>/dev/null && break
  sleep 0.1
done
python3 -c "import socket; socket.create_connection(('127.0.0.1',$PORT),0.5).close()" 2>/dev/null \
  && echo "  ✅ FTP 服务器就绪 127.0.0.1:$PORT" \
  || { echo "  ❌ FTP 服务器未能启动"; tail -5 "$WORK/server.log"; exit 1; }

echo "── 3. ping / probe ───────────────────────────"
check "ping 连通"            "$CTL" ping --host 127.0.0.1 --port $PORT
check "probe 能力矩阵"       "$CTL" probe --host 127.0.0.1 --port $PORT
$CTL probe --host 127.0.0.1 --port $PORT > "$WORK/probe.json" 2>/dev/null
grep -q '"mkdir" : true'       "$WORK/probe.json" && ok "probe: mkdir=true"        || ng "probe: mkdir"
grep -q '"rename" : true'      "$WORK/probe.json" && ok "probe: rename=true"       || ng "probe: rename"
grep -q '"deleteFile" : true'  "$WORK/probe.json" && ok "probe: deleteFile=true"   || ng "probe: deleteFile"
grep -q '"appeResume" : true'  "$WORK/probe.json" && ok "probe: appeResume=true"   || ng "probe: appeResume"
grep -q '"mlsd" : true'        "$WORK/probe.json" && ok "probe: mlsd=true"         || ng "probe: mlsd"
grep -q '"sizeCommand" : true' "$WORK/probe.json" && ok "probe: sizeCommand=true"  || ng "probe: sizeCommand"
grep -q '"utf8Filenames" : true' "$WORK/probe.json" && ok "probe: utf8Filenames=true" || ng "probe: utf8Filenames"

echo "── 4. list（预置中文名可见）─────────────────"
check "list 根目录"           "$CTL" list --host 127.0.0.1 --port $PORT --path /
$CTL list --host 127.0.0.1 --port $PORT --path / > "$WORK/list.out" 2>/dev/null
grep -q "测试文件.txt" "$WORK/list.out" && ok "预置中文名出现在列表" || ng "预置中文名未出现"
grep -q "Movies" "$WORK/list.out" && ok "预置目录出现在列表" || ng "预置目录未出现"

echo "── 5. upload（中文名，GBK 发送）──────────────"
check "upload 中文名"         "$CTL" upload --host 127.0.0.1 --port $PORT --file "$LOCAL/周岁生日 [高清].mp4" --to "/周岁生日 [高清].mp4"
# pyftpdlib(gbk) 已按 GBK 解码并转 UTF-8 落盘 → 按原始名字字节在磁盘验证存在
python3 - "$REMOTE" <<'EOF' && ok "磁盘上存在中文名文件（服务端字节路径验证）" || ng "中文名落盘验证失败"
import os, sys
names = os.listdir(sys.argv[1].encode())
sys.exit(0 if "周岁生日 [高清].mp4".encode() in names else 1)
EOF
SRC_SIZE=$(wc -c < "$LOCAL/周岁生日 [高清].mp4")
DST_SIZE=$(wc -c < "$REMOTE/周岁生日 [高清].mp4" 2>/dev/null || echo -1)
[ "$SRC_SIZE" = "$DST_SIZE" ] && ok "落盘字节数一致（${DST_SIZE}）" || ng "落盘字节数不一致 $SRC_SIZE vs $DST_SIZE"
# curl 一次读回名字一致性验证（ARCHITECTURE §5 要求）
curl -s "ftp://127.0.0.1:$PORT/" -o "$WORK/nlst.bin" 2>/dev/null
python3 - "$WORK/nlst.bin" <<'EOF' && ok "curl NLST 读回名字含 GBK 字节序列" || ng "curl 读回名字验证失败"
import sys
data = open(sys.argv[1], 'rb').read()
sys.exit(0 if "周岁生日 [高清].mp4".encode("gbk") in data else 1)
EOF

echo "── 6. download（GBK 名字往返 diff）───────────"
check "download 中文名"       "$CTL" download --host 127.0.0.1 --port $PORT --from "/周岁生日 [高清].mp4" --to "$LOCAL/roundtrip.mp4"
if cmp -s "$LOCAL/周岁生日 [高清].mp4" "$LOCAL/roundtrip.mp4"; then ok "往返内容 diff 一致"; else ng "往返内容不一致"; fi

echo "── 7. APPE 续传模拟（STOR 一半 → resume 补齐）"
check "upload 半程文件"       "$CTL" upload --host 127.0.0.1 --port $PORT --file "$LOCAL/half.bin" --to "/resume-e2e.bin"
check "upload --resume 续传"  "$CTL" upload --host 127.0.0.1 --port $PORT --file "$LOCAL/周岁生日 [高清].mp4" --to "/resume-e2e.bin" --resume
if cmp -s "$LOCAL/周岁生日 [高清].mp4" "$REMOTE/resume-e2e.bin"; then ok "续传结果与原文件 diff 一致"; else ng "续传结果不一致"; fi

echo "── 8. delete / move / mkdir ──────────────────"
check "mkdir 新目录"          "$CTL" mkdir --host 127.0.0.1 --port $PORT --path "/e2e新目录"
[ -d "$REMOTE/e2e新目录" ] && ok "新目录落盘存在" || ng "新目录不存在"
check_fail "mkdir 已存在目录（预期失败）" "$CTL" mkdir --host 127.0.0.1 --port $PORT --path "/e2e新目录"

check "upload 待删文件"       "$CTL" upload --host 127.0.0.1 --port $PORT --file "$LOCAL/half.bin" --to "/todelete.bin"
check "delete 文件"           "$CTL" delete --host 127.0.0.1 --port $PORT --path "/todelete.bin"
[ ! -e "$REMOTE/todelete.bin" ] && ok "文件已从磁盘消失" || ng "文件仍存在"
check_fail "delete 不存在文件（预期失败）" "$CTL" delete --host 127.0.0.1 --port $PORT --path "/todelete.bin"

check "move 同目录改名"       "$CTL" move --host 127.0.0.1 --port $PORT --from "/resume-e2e.bin" --to "/moved.bin"
[ -f "$REMOTE/moved.bin" ] && ok "改名后落盘存在" || ng "改名后文件缺失"
check "move 跨目录"           "$CTL" move --host 127.0.0.1 --port $PORT --from "/moved.bin" --to "/Movies/moved.bin"
[ -f "$REMOTE/Movies/moved.bin" ] && ok "跨目录后落盘存在" || ng "跨目录后文件缺失"
if cmp -s "$LOCAL/周岁生日 [高清].mp4" "$REMOTE/Movies/moved.bin"; then ok "移动后内容不变"; else ng "移动后内容损坏"; fi

echo "── 9. 探针无残留 ─────────────────────────────"
LEFT=$(python3 -c "
import os,sys
n = os.listdir('$REMOTE'.encode())
bad = [x for x in n if x.startswith(b'mitv-probe-')]
print(len(bad))
")
[ "$LEFT" = "0" ] && ok "远端根无 mitv-probe-* 残留" || ng "探针残留 $LEFT 项"

echo "───────────────────────────────────────────────"
echo "E2E 结果：PASS=$PASS FAIL=$FAIL  （工作目录 ${WORK}）"
if [ "$FAIL" -eq 0 ]; then
  echo "ALL GREEN"
  rm -rf "$WORK"
  exit 0
else
  echo "FAILED（目录保留供排查：${WORK}）"
  exit 1
fi
