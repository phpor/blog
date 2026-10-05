#!/usr/bin/env bash
#
# 演示:后台进程组尝试读控制终端时,内核会发 SIGTTIN 并停掉整个进程组。
# 用法:在一个交互式终端里执行 ./sigttin-demo.sh
set -u

# 非交互 shell 默认关闭 job control,后台作业不会拥有独立进程组,
# 也就不会触发 SIGTTIN。set -m 打开它,复现才成立。
set -m

pid=$$
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
tty=$(ps -o tty= -p "$pid")
echo "== shell 信息: pid=$pid pgid=$pgid tty=$tty =="

cat > /dev/null &
cat_pid=$!

# 等内核把 SIGTTIN 送到位(最多等 2 秒)
for _ in $(seq 1 20); do
  stat=$(ps -o stat= -p "$cat_pid" 2>/dev/null)
  [[ $stat == T* ]] && break
  sleep 0.1
done

echo
echo "== cat 进程状态:STAT=T,且 PGID 与 TPGID 不同 =="
ps -o pid,ppid,pgid,tpgid,tty,stat,command -p "$cat_pid"

echo
echo "== kill -CONT 之后:要么再次被停,要么 read 报错退出 =="
kill -CONT "$cat_pid"
sleep 0.5
ps -o pid,stat,command -p "$cat_pid"
echo "(若上面 ps 无输出,说明 cat 已经因 read 失败而退出了)"

echo
echo "== 清理(先 CONT,让它有机会响应 SIGTERM) =="
kill -CONT "$cat_pid" 2>/dev/null
kill -TERM "$cat_pid" 2>/dev/null
wait "$cat_pid" 2>/dev/null
echo "== done =="
