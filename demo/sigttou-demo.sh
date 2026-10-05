#!/usr/bin/env bash
#
# 演示:终端开启 TOSTOP 时,后台进程组尝试写控制终端会被 SIGTTOU 停掉。
# 用法:在一个交互式终端里执行 ./sigttou-demo.sh
set -u
set -m

saved=$(stty -g)
trap 'stty "$saved"' EXIT

pid=$$
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
tty=$(ps -o tty= -p "$pid")
echo "== shell 信息: pid=$pid pgid=$pgid tty=$tty =="

stty tostop   # 默认多数终端是 -tostop,这里手动打开
echo_pid=""
/bin/echo "hello from background" &
echo_pid=$!
sleep 0.5

echo
echo "== echo 进程状态:后台写终端 + TOSTOP => STAT=T =="
ps -o pid,ppid,pgid,tpgid,tty,stat,command -p "$echo_pid"
echo "(注意:上一条 hello 并没有真正打到终端上,写动作被 SIGTTOU 拦下了)"

stty -tostop   # 先关掉 TOSTOP,否则 kill -CONT 后它写终端会立刻再被停住
kill -CONT "$echo_pid" 2>/dev/null
sleep 0.3
kill -TERM "$echo_pid" 2>/dev/null
wait "$echo_pid" 2>/dev/null
echo "== done(刚才那句 hello 现在应该已经出现在终端上了) =="
