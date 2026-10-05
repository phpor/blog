# 为什么 `nohup pnpm dev` 会停在 T 状态:SIGTTIN 与终端前台进程组

## 现象

用下面的命令在交互式终端里启动了一个前端 dev server:

```bash
nohup pnpm dev &> console.nohup.log &
```

过了一阵子去看,进程一直处于 stop 状态:

```text
$ ps axo pid,ppid,pgid,tpgid,tty,stat,command | grep pnpm
  PID  PPID  PGID  TPGID TTY      STAT COMMAND
37301 45328 37301 45328 ttys000  T    node /usr/local/bin/pnpm dev
37344 37301 37301 45328 ttys000  T    node .../pnpm.cjs dev
37365 37344 37301 45328 ttys000  T    node .../vite.js
37371 37365 37301 45328 ttys000  T    .../esbuild --service=0.21.5 --ping
```

而且可以确认:没有人执行过 `kill -18`(macOS 上 18 号信号是 `SIGTSTP`,
也就是 Ctrl+Z 发的那个),也没有人在终端里按过 Ctrl+Z。

进程是 19:24:38 启动的,日志的修改时间是 19:24:39——刚写完启动横幅就再也没动过。

## 先读懂 ps 的几列

- `PGID`:进程组 ID。交互式 bash 开启了 job control,用 `&` 启动的作业会被
  放进一个**独立的进程组**,这里整棵进程树的 PGID 都是 37301。
- `TPGID`:该控制终端当前的**前台进程组** ID。这里是 45328,也就是启动它的
  那个交互式 bash 自己。
- `STAT` 里的 `T`:stopped,被 job control 信号(`SIGTSTP`/`SIGTTIN`/`SIGTTOU`/
  `SIGSTOP`)或调试器停住。

`PGID=37301` 而 `TPGID=45328`,说明这组进程相对终端 ttys000 是**后台作业**。
这就是一切问题的起点。

## 内核的终端规则

每个控制终端都维护着一个"前台进程组"。POSIX 终端驱动对后台进程组访问终端
有明确的处置规则:

| 动作 | 条件 | 结果 |
| --- | --- | --- |
| 后台进程组 `read()` 终端 | 无条件 | 内核向该进程组发 `SIGTTIN`,默认动作是停住 |
| 后台进程组 `write()` 终端 | 线路规则 `TOSTOP` 开启 | 内核向该进程组发 `SIGTTOU` |
| 后台进程组 `tcsetattr()` 等修改终端属性 | 无条件 | 内核向该进程组发 `SIGTTOU` |

两个细节:

1. `SIGTTIN` 无法通过 `nohup` 之类的手段规避,它不在任何"忽略清单"里。
   `SIGTSTP` 可以被捕获,`SIGTTIN` 也可以,但默认动作就是 stop。
2. 如果这组进程已经成了**孤儿进程组**(会话内没有进程能接管终端),或者
   `SIGTTIN` 被显式忽略,内核不再发信号,`read()` 直接以 `EIO` 失败。

顺带澄清一个常见误解:`SIGTTIN` 和**系统休眠**没有任何关系。它不是睡眠唤醒
机制,而是终端驱动执行 job control 规则的产物。进程状态里的 `S`(sleeping)
也只是"进程自己在等某个事件"的正常阻塞态;机器休眠既不给进程发信号,也不把
进程变成 `T` 状态。

## 回到这个案例:是谁去读了终端

拆开那条启动命令:

- `nohup` 只做一件事:把 `SIGHUP` 设为忽略,防止终端关闭时被连带杀掉。
  它**不管** `SIGTTIN`。
- `&>` 只重定向了 stdout 和 stderr,`console.nohup.log` 接住了所有输出。
  但 **stdin 依然连着终端 ttys000**。

而 vite 的 dev server 有一个交互特性:检测到 `stdin` 是 TTY(且不是 CI 环境)
时,会通过 readline 监听键盘快捷键——按 `r` 手动重载、按 `o` 打开浏览器、
按 `c` 清屏等等。监听快捷键,意味着它要去 `read()` 那个终端。

于是完整时间线是:

1. `19:24:38`,pnpm dev 启动,整个进程树进入后台进程组 37301;
2. vite 初始化,把启动横幅写进 `console.nohup.log`(写的是重定向后的文件,
   不碰终端,所以安然无恙);
3. `19:24:39`,vite 第一次尝试 `read()` stdin(也就是 ttys000);
4. 终端驱动发现读它的进程组 37301 不是前台进程组 45328,向整组发送
   `SIGTTIN`,默认动作 stop——pnpm、vite、esbuild 全部进入 `T` 状态。

终端的 `TOSTOP` 当时是关闭的(`stty -a` 可见 `-tostop`),所以连后台写终端都
不会停它;能把它停住的只有那次后台读。这也反过来印证了 `SIGTTIN` 就是元凶。

## 可复现的 Demo

不需要 vite,一个 `cat` 就能复现。仓库里的 [demo/sigttin-demo.sh](../demo/sigttin-demo.sh)
做了同样的事:

```bash
#!/usr/bin/env bash
set -m   # 关键:非交互 shell 默认关 job control,必须打开

cat > /dev/null &   # stdin 还是终端,stdout 已重定向
sleep 0.5
ps -o pid,pgid,tpgid,tty,stat,command -p $!
```

在交互式终端里运行,会看到 `cat` 已经变成 `T` 状态:

```text
== cat 进程状态:STAT=T,且 PGID 与 TPGID 不同 ==
  PID  PPID  PGID  TPGID TTY      STAT COMMAND
54321 54320 54321 54320 ttys000  T    cat
```

两个容易踩的坑:

- 脚本里必须 `set -m`。非交互 shell 默认关闭 job control,后台作业不会获得
  独立进程组,PGID 和 TPGID 相同,`SIGTTIN` 根本不会触发。
- `kill -CONT` 也救不了它:恢复后 `cat` 立刻再次去读终端。Linux 上会再次被
  `SIGTTIN` 停住;macOS 上这次 `read()` 会以 `EINTR` 失败,`cat` 报一句
  `stdin: Interrupted system call` 后退出。Demo 脚本里演示了这一点。

[demo/sigttou-demo.sh](../demo/sigttou-demo.sh) 则复现了另一条规则:
`stty tostop` 之后,后台进程组往终端写一行字,会被 `SIGTTOU` 停住,而且那行字
根本打不出来。

## 正确的姿势

关键只有一个:让后台进程的 **stdin 不是终端**。

```bash
# stdin 指向 /dev/null,vite 检测不到 TTY,自动禁用键盘快捷键监听
nohup pnpm dev </dev/null &> console.nohup.log &
```

或者直接放进终端复用器里,那里有稳定的前台进程组,交互快捷键还能正常用:

```bash
tmux new -d -s dev 'pnpm dev'   # 之后 tmux attach -t dev 看日志、按快捷键
```

Linux 上还有 `setsid pnpm dev &`,让进程脱离控制终端(macOS 没有自带 setsid)。

最后一个小知识:想清理一个处于 `T` 状态的进程树,直接 `kill -TERM` 是不生效
的——停止状态的进程不处理普通信号,必须先 `kill -CONT`,或者干脆 `kill -9`
(`SIGKILL` 是唯一例外,立即生效)。

## 信号速查

| 信号 | 典型来源 | 默认动作 | 编号(macOS / Linux) |
| --- | --- | --- | --- |
| `SIGTTIN` | 后台进程组读控制终端 | stop | 21 / 21 |
| `SIGTTOU` | 后台进程组写终端(`TOSTOP` 开启)或修改终端属性 | stop | 22 / 22 |
| `SIGTSTP` | 终端 Ctrl+Z | stop,可捕获 | 18 / 20 |
| `SIGSTOP` | `kill -STOP`,不可捕获 | stop | 17 / 19 |
| `SIGCONT` | `kill -CONT` | 恢复运行 | 19 / 18 |

## 参考

- [termios(4),POSIX 终端接口规范](https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap11.html)
- [GNU libc 手册:Signals Related to a Controlling Terminal](https://www.gnu.org/software/libc/manual/html_node/Initial-Signal-Actions.html)
- [Vite CLI:Keyboard Shortcuts](https://cn.vitejs.dev/guide/cli.html#command-line-interface)
- Bash 参考手册 [Job Control](https://www.gnu.org/software/bash/manual/html_node/Job-Control-Basics.html)
