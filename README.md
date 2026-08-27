<h1 align="center">GOST ECMP PathLock</h1>

<p align="center">
  <strong>TCP ECMP-aware path selection, persistent flow locking and automatic self-healing over GOST MTCP.</strong>
</p>

<p align="center">
  基于 GOST MTCP 的 TCP ECMP 路径优选、持久锁定与自动自愈方案
</p>

<p align="center">
  <img alt="License" src="https://img.shields.io/badge/License-MIT-green">
  <img alt="Platform" src="https://img.shields.io/badge/Platform-Linux%20%2B%20systemd-blue">
</p>

---

本项目源于一个真实线路问题: 上海 9929 → 软银日本存在明显的 TCP per-flow ECMP 路径分化, 同一个目的地址的不同 TCP 连接可能被哈希到不同物理路径, 实测大致是快路 ~33 ms、慢路 ~51 ms。普通 TCP 代理每建一条新连接都要重新参与一次 ECMP 哈希, 所以延迟会在快慢路径之间随机跳。

这个项目的目标不是让线路本身变快, 而是:

> 先抽到一条低延迟的 TCP 路径, 再用 GOST MTCP 把后续业务长期复用在这一条 outer TCP 上, 让它们不用再重新参与 ECMP。

早期想法是抽到慢路就用 `ss -K` 踢掉重连, 但这个思路不适合长期跑: `ss -K` 杀的是整条 MTCP outer, 上面挂着的所有业务 logical stream 会跟着一起断流; 而且重连依然要重新过一次 ECMP, 不保证能抽到快路, 容易陷入反复 kill/reconnect。所以最终改成了**只在启动或真正故障时重新选路, 正常运行期间不去碰已经选好的 outer**。方案演进的完整过程(为什么用 `minrtt` 而不是实时 `rtt`、Anchor 中间踩过的坑等)记在 `DESIGN-archive.md` 里。

已经实测覆盖三种故障场景并能自动恢复: Remote 整体不可达、outer 消失、TCP 还显示 `ESTAB` 但 MTCP 数据面其实已经失效。

## ECMP 实测依据

我们选择 GreenCloud 官方数据中心页面列出的 [Tokyo Datacenter (Softbank) NTT](https://greencloudvps.com/data-centers.php), 以测试 IPv4 `103.201.131.7` 的 TCP `22` 端口作为测试对象。测试脚本每次建立一条全新的 TCP flow, 通过当前 FD 的 socket inode 找到它实际使用的源端点和目的端点, 等待 `0.15` 秒后再按完整 TCP 四元组从 Linux `TCP_INFO` 读取该 flow 的 `minrtt`, 随后主动关闭连接并继续下一次采样。这样即使机器上同时存在其他到相同目标端口的连接, 也不会串读它们的测量结果。执行命令:

```bash
./ecmp-test.sh 1000
```

在 1000 次连接尝试中得到 970 个有效样本, 实测结果如下:

```text
==============================
 ECMP minRTT distribution
==============================
 33 ms :   257   26.49%
 34 ms :   218   22.47%
 35 ms :     3    0.31%
 36 ms :     1    0.10%
 50 ms :   291   30.00%
 51 ms :   173   17.84%
 52 ms :    26    2.68%
 56 ms :     1    0.10%

Average minrtt: 42.139 ms

Valid samples: 970 / 1000
```

有效样本呈明显双峰: `33-36 ms` 共 479 个(49.38%), `50-56 ms` 共 491 个(50.62%), 平均 `minrtt` 为 `42.139 ms`。这说明同一目标、同一端口的新建 TCP flow 大致各有一半落入快路和慢路, 正是本项目通过 Prewarm 先选中快路, 再让业务复用唯一 MTCP outer 的现实依据。

完整测试脚本见 [`ecmp-test.sh`](ecmp-test.sh)。

## 怎么工作的

系统由四部分组成:

- **Prewarm** 负责选路。启动或故障恢复时建一条候选 outer, 读 TCP 的 `minrtt`(不是实时 rtt——后者容易被排队、重传、突发流量干扰, `minrtt` 才能反映这条连接真正走的是哪条基础路径), 够快就留下, 不够快就废弃重抽, 直到抽中快路(或者额度用完, 先保证业务能连上)。
- **Anchor** 负责锁路。它在选中的路径上维持一个很轻的 logical stream, 不承载业务, 唯一作用是防止这条 outer 因为暂时没有业务流量被 GOST 回收。
- **Data-plane Probe** 负责验证"这条 outer 是不是真的能用"。`ESTAB` 只说明 socket 还在, 不代表数据面真通; 探测靠一次真实的 payload 收发来确认。
- **Watchdog** 是最终的控制器。正常状态下它什么都不干, 只有真正探测到故障(GOST crash、outer 消失、outer 变成假活、Remote 整体不可达等)时才出手清理、重建、重新选路。

另外几条原则: 运行中的实时 RTT 只用来告警, 不会因为一次瞬时拥塞就把正在用的连接踢掉; Remote 整体联系不上时安静等待, 不会疯狂重启 GOST 或反复重抽; **每条 Remote 线路**只保留一条 MTCP outer TCP，该线路的所有业务共享它。多条线路则在同一个 GOST 进程内各自维护一条 outer。

一句话总结整个设计:

> 启动时积极选路, 正常时绝不折腾, 故障时彻底重建。

它不是一个持续切换线路的负载均衡器, 而是针对 TCP ECMP 场景的**长期路径锁定 + 自动自愈系统**。

## 架构

![GOST ECMP PathLock 架构图](assets/design_picture.jpg)

```text
+----------------+           +------------------------------------+    selected MTCP outer    +--------------------------------+
| Business       |    TCP    | CN GOST                            | ========================> | Remote GOST                    |
| clients        | --------> | business :12000 + relays           |                           | MTCP listener :6600            |
|                |           | anchor/probe 127.0.0.1:12001       |                           | per-stream TCP relay           |
|                |           | shared chain-mtcp / connector      |                           |                                |
+----------------+           +------------------+-----------------+                           +----------------+---------------+
                                                ^                                                              |
                                                | manages / observes                                           v
                             +------------------------------------+                           +--------------------------------+
                             | CN recovery control                |                           | requested stream targets       |
                             | Prewarm : draw ECMP by minrtt      |                           | configured business backends   |
                             | Anchor  : hold logical stream      |                           | probe echo :12346              |
                             | Watchdog: PID/outer/RTT/Remote     |                           +--------------------------------+
                             | Probe   : 1-byte payload echo      |
                             +------------------------------------+
```

单条线路的业务入口(`:12000` 及后续 Relay 端口)统一走该线路的 `chain-mtcp-<线路>`，共享同一个 MTCP connector 和唯一 outer，每个 logical stream 各自带 Remote 目标。不同线路的 service/chain 名称彼此隔离，但都装在同一个 GOST 进程。Anchor 本机入口是 `127.0.0.1:12001`，打到 Remote 的 echo endpoint `127.0.0.1:12346`。Data Plane Probe 默认每 15 秒沿同一条线路发送并收回 1 字节。Remote 收到 logical stream 后先校验 Relay 凭据，再转发到业务后端或探测 endpoint。

## 快速安装

**推荐: 单文件安装器(不用克隆项目)**

```bash
# Remote 服务器：下载后打开菜单，选择 1 -> Remote
curl -fsSL https://raw.githubusercontent.com/zcp1997/gost-ecmp-pathlock/main/standalone-install.sh \
  -o /root/standalone-install.sh
bash /root/standalone-install.sh

# CN 服务器：国内使用 ghfast 下载，打开菜单后选择 1 -> CN
curl -fsSL https://ghfast.top/raw.githubusercontent.com/zcp1997/gost-ecmp-pathlock/main/standalone-install.sh \
  -o /root/standalone-install.sh
bash /root/standalone-install.sh
```

无参数运行就是统一管理菜单：

```text
[1]  安装 / 新增线路
[2]  查看线路与端口
[3]  管理端口转发
[4]  运行状态 / 日志
[5]  删除 CN 线路实例
[6]  完全卸载 PathLock
[Q]  退出
```

交互菜单会显示 CN/Remote 服务、线路状态和 endpoint 摘要；操作完成后按 Enter 返回，输入错误只中止当前操作，不会退出整个管理器。无效菜单项会直接重新提示；实时日志中的 `Ctrl-C` 只停止跟踪并返回状态菜单。颜色仅在交互 TTY 中启用，设置 `NO_COLOR=1` 可强制关闭。安装后继续运行同一条 `bash /root/standalone-install.sh` 即可管理，不需要设置 `CN_INSTANCE`。自动化场景仍可使用 `bash standalone-install.sh remote|cn|relay|instance|uninstall`，其退出码与 fatal error 行为不变。`GOST_VERSION=v3.2.6` 里的 `v` 只是 Release tag 用的，安装器会自动去掉它寻找对应资产文件。

**传统方式(开发/调试用, 能看到完整代码)**

```bash
# Remote 服务器（先安装并设置鉴权密码）
git clone https://github.com/zcp1997/gost-ecmp-pathlock.git
cd gost-ecmp-pathlock
bash install.sh remote

# CN 服务器（输入 Remote 上设置的同一密码）
git clone https://ghfast.top/https://github.com/zcp1997/gost-ecmp-pathlock.git
cd gost-ecmp-pathlock
bash install.sh cn
```

### MTCP Relay 鉴权

安装器强制要求一个 12-128 位的密码，并在 Remote 的 Relay handler 与 CN 的 Relay connector 之间校验。GOST v3.2.6 的 MTCP listener/dialer 本身不会消费 `listener.auth`/`dialer.auth`，所以鉴权必须放在 Relay 协议层；密码错误或未提供凭据的 logical stream 会被 Remote 拒绝，不能再把 MTCP 端口当成公开 Relay 使用。

凭据不会写进 YAML：安装器使用固定用户名 `mtcp`，把两端凭据分别写入权限为 `0600` 的 `mtcp.auth` 文件。Standalone 默认位置是：

- Remote：`/opt/gost-mtcp/remote/mtcp.auth`
- CN：`/opt/gost-mtcp/cn/instances/<线路别名>/mtcp.auth`

交互安装会隐藏输入并要求确认。自动化部署可在 Remote 与 CN 安装进程中传入相同的 `MTCP_AUTH_PASSWORD`；避免把它直接写进 shell 历史或日志。已有部署升级时，应先停止对应 unit，再用同一个新密码依次重装 Remote 和所有 CN 线路。

## 系统要求

| 组件 | 要求 |
|------|------|
| **OS** | Linux + systemd |
| **权限** | root |
| **通用依赖** | bash, curl, tar, awk, grep, flock (util-linux), systemctl, sha256sum/shasum |
| **CN 额外** | ss (iproute2), timeout (coreutils) |
| **Remote 额外** | socat |

Debian/Ubuntu 装依赖:

```bash
# 通用
apt-get install -y curl tar coreutils grep gawk systemd util-linux

# CN 端
apt-get install -y iproute2

# Remote 端
apt-get install -y socat
```

## 安装后验证

**Remote:**

```bash
systemctl status gost-mtcp-remote.service
ss -lntp | grep ':6600'
```

**CN(假设线路别名是 jp):**

```bash
# 全机唯一的 CN GOST 进程
systemctl status gost-mtcp.service

# jp 线路自己的轻量 Watchdog
systemctl status gost-mtcp-jp-watchdog.service

# 查看状态
cat /opt/gost-mtcp/cn/instances/jp/state/status.json

# 查看事件日志
tail -f /opt/gost-mtcp/cn/instances/jp/state/events.jsonl

# 查看 outer 连接(替换实际 IP 和端口)
ss -tin state established 'dst <REMOTE_IP> dport = :6600'
```

正常状态长这样: `state: FAST`、`outer_count: 1`(唯一一条 outer)、`minrtt_ms < 40`(快路)、`data_plane_reachable: yes`(数据面真的通)、`data_probe_failures: 0`、`data_probe_breaker: closed`、`process_breaker: closed`、`anchor_state: up`。

## 常见配置

安装 CN 线路时，向导会要求配置主业务入口对应的 Remote 后端端口，并单独询问后端地址；地址直接回车默认使用 Remote 本机 `127.0.0.1`。安装器不会再静默生成指向 `127.0.0.1:2345` 的转发。

**修改已有 CN 后端地址** —— CN 的 `forwarder.nodes[0].addr` 就是 Remote 最终要连的那个 TCP 目标:

```bash
# 单文件安装器默认路径
nano /opt/gost-mtcp/cn/instances/jp/cn.yaml

# 或传统方式路径（传统入口同样使用 instances 布局）
nano /root/gost-ecmp-pathlock/cn/instances/jp/cn.yaml

# 修改后端地址
forwarder:
  nodes:
  - name: backend
    addr: 127.0.0.1:8080  # 改成实际地址

# 确认所有线路连接都允许中断后，重新生成聚合配置并受控重启
CN_DIR=/opt/gost-mtcp/cn  # 传统方式改为 /root/gost-ecmp-pathlock/cn
"$CN_DIR/compile-config.sh" "$CN_DIR/runtime.yaml" "$CN_DIR"/instances/*/cn.yaml
"$CN_DIR/gost" -C "$CN_DIR/runtime.yaml" -O yaml >/dev/null
systemctl restart gost-mtcp.service
systemctl restart 'gost-mtcp-*-watchdog.service'
```

**修改 RTT 阈值:**

```bash
nano /opt/gost-mtcp/cn/instances/jp/mtcp.conf

# 修改阈值
ACCEPT_RTT_MS=35

# 重启 Watchdog
systemctl restart gost-mtcp-jp-watchdog.service
```

### 数据面探测与 stale outer 恢复

Watchdog 默认每 15 秒经本地 Anchor 入口收发 1 字节验证数据面。连续失败 3 次后, 会额外单独建一条 TCP 去探测 Remote 的 MTCP 端口:

- Remote TCP 不可达 → 判定整条线路真断了, 安静等待, 不循环重启 GOST 也不循环重抽
- Remote TCP 可达 → 判定该线路当前 outer 是 stale 的, 只关闭该 `DST:PORT` 对应的 outer 并重新 Prewarm；不会重启共享 GOST，也不会碰其他线路

```bash
# mtcp.conf 默认值
DATA_PROBE_ENABLED=yes
DATA_PROBE_INTERVAL_SEC=15
DATA_PROBE_TIMEOUT_SEC=3
DATA_PROBE_FAIL_THRESHOLD=3
DATA_PROBE_RESTART_WINDOW_SEC=600
DATA_PROBE_RESTART_MAX=3
DATA_PROBE_BREAKER_OPEN_SEC=600
```

把 `DATA_PROBE_ENABLED` 改成 `no` 可以退回旧版行为, 只看 outer 的 TCP 状态。如果探测 endpoint 配错了或者一直失败, 10 分钟内线路 outer 重置满 3 次就会进 `FAULT/DATA_PROBE_BREAKER`, 停 10 分钟不再重置; 之后只放一次 half-open 试探, 数据面探测成功了才会关闭熔断。

GOST 触发 systemd 的 `StartLimit` 后, Watchdog 会低频做 `reset-failed + restart`, 默认 10 分钟最多 3 次, 再多就进 `FAULT/PROCESS_BREAKER`。PROCESS breaker 是共享 GOST 的全局状态：所有线路通过 `/run/gost-ecmp-pathlock/gost-mtcp.process-recovery.lock` 串行读改写同一份 `/run/gost-ecmp-pathlock/gost-mtcp.process-recovery.state`，共同使用一套恢复预算，而不是每条线路各算 3 次。只有同一个 MainPID 连续健康 60 秒后熔断器才会关闭；PID 换代会立即重置健康计时。所有实例的 `PROCESS_RECOVERY_GRACE_SEC`、`PROCESS_RECOVERY_INTERVAL_SEC`、`PROCESS_RECOVERY_WINDOW_SEC`、`PROCESS_RECOVERY_MAX` 和 `PROCESS_BREAKER_OPEN_SEC` 必须一致，CN 安装、升级及 Relay 配置事务发现参数漂移时会 fail closed。

### 故障恢复路径(均已实测)

**Remote 整体不可达**(在 Remote 端用 nftables `DROP` 掉 MTCP 端口验证过):

```
OUTER_DISAPPEARED → REMOTE_TCP_DOWN → DOWN/REMOTE(安静等待)
  → [解除 DROP] → REMOTE_TCP_UP → RECOVERY_SELECT
  → PREWARM_SUCCESS(约 33.5ms) → ANCHOR_BOUND → FAST
```

期间不会循环重启 GOST、循环 Prewarm 或高频刷恢复日志; 解除封禁后能自动重新选路, 恢复到约 33.5ms 的 `FAST` 状态。

**TCP 显示 ESTAB, 但 MTCP 数据面已经死了**(只丢弃当前 outer 的四元组, 同时保留 Remote 新连接的可达性来验证):

```
outer_count=1; TCP=ESTAB; payload=FAIL → DATA_PROBE_FAILED 1/3 → 2/3 → 3/3
  → STALE_OUTER_CONFIRMED(remote_tcp=up) → RESET_ROUTE_OUTER
  → RECOVERY_SELECT → PREWARM_SUCCESS → ANCHOR_BOUND
  → FAST(data_plane_reachable=yes, failures=0)
```

旧版曾通过重启单线路 GOST 验证过这条恢复路径。共享进程架构保留相同的 stale 判定，但恢复动作改为按当前 PID、Remote `DST:PORT` 和 sport 精确关闭该线路 outer；GOST PID 与其他线路保持不变。

这两条路径合起来覆盖了 Remote 真断、outer 消失、outer 还在但数据面已死三种情况。要注意的是: hard failure 发生时已有的业务 TCP 连接没法无缝迁移, 恢复目标是让**后续新连接**尽快可用, 不是保住老连接。

### 多线路部署

同一台 CN 可以接多个 Remote, 每次执行 `standalone-install.sh cn` 时输入不同的线路别名就行:

```bash
# 第一条线路
bash standalone-install.sh cn
# 别名: jp, 业务端口: 12000, Anchor: 12001

# 第二条线路
bash standalone-install.sh cn
# 别名: us, 业务端口: 12002, Anchor: 12003
```

CN 全机只运行一个 `gost-mtcp.service`。每条线路保留独立的 fragment、鉴权、状态、Anchor 和 Watchdog；`compile-config.sh` 将所有线路 fragment 合成唯一的 `runtime.yaml`：

```text
/opt/gost-mtcp/cn/
├── gost, compile-config.sh
├── runtime.yaml                         # 唯一 GOST 进程读取的聚合配置
├── mtcp-lib.sh, mtcp-prewarm.sh, mtcp-watchdog.sh
└── instances/
    ├── jp/  -> cn.yaml, mtcp.conf, mtcp.auth, state/
    └── us/  -> cn.yaml, mtcp.conf, mtcp.auth, state/
```

聚合配置中的对象名按线路隔离，例如 `tcp-entry-jp`、`mtcp-anchor-jp`、`chain-mtcp-jp`。每条线路必须使用唯一的 Remote `IP:port`；否则同一 PID 下无法可靠判断某条 outer 属于哪条线路，安装器和编译器都会拒绝。编译器还会 fail closed 校验 fragment ownership：`jp` fragment 必须定义 `chain-mtcp-jp` 和 `mtcp-anchor-jp`，其中每个 service 只能引用 `chain-mtcp-jp`，不能借用聚合文件中另一条线路的 chain。

新增/重装线路会先在隔离 staging 中准备并校验候选 GOST binary、`mtcp-lib.sh`、`mtcp-prewarm.sh`、`mtcp-watchdog.sh`、`compile-config.sh`、`runtime.yaml`、线路文件和 units；全部通过后才停止各线路 Anchor/Watchdog，并把这些 shared artifacts 纳入同一个备份、提交和回滚事务，然后只重启一次共享 GOST。Standalone 的 Remote 重装也会先用候选 GOST 校验候选 YAML，再事务提交 binary、配置、凭据和 units；`daemon-reload`、`enable`、`restart` 或健康检查失败都会恢复旧 artifacts 与原 enable 状态。这个管理动作会中断所有线路的现有连接；菜单检测到活跃业务时会显示连接数并要求再次明确确认，直接命令或自动化则默认拒绝，需设置 `CN_FORCE_RESTART=1`。运行期间的慢路重抽、stale outer 和单线路恢复只重置对应 Remote endpoint，不重启共享进程。

当前管理策略是“已安装线路即受管且 Watchdog 常开”：CN 配置事务结束时会重新 enable/restart 所有已安装线路的 Watchdog。手工 `disable --now` 不是持久 maintenance 状态，后续配置变更会重新启用；如需线路维护模式，应先实现显式的 route enable/disable 状态再改变这一策略。

从旧版多 GOST 部署升级时，逐条停止旧线路并重新执行 `standalone-install.sh cn`。已迁移线路进入共享进程；尚未迁移的旧 fragment 暂不纳入 `runtime.yaml`，直到该线路完成重装。

### 管理 CN 额外端口 Relay

不用手改 YAML, standalone 安装器自带列出/新增/删除业务入口的功能。新增的 Relay 会和主入口共用目标线路自己的 chain（例如 `chain-mtcp-jp`）和唯一 outer:

```bash
# 推荐：进入统一菜单，选择 3，再从编号列表选择线路
bash standalone-install.sh

# 也可直接进入线路选择器
bash standalone-install.sh relay

# 自动化兼容命令；多线路且未指定线路时同样会显示选择器
bash standalone-install.sh relay list
bash standalone-install.sh relay add
bash standalone-install.sh relay remove relay-jp-12002
```

比如 `relay add` 后输入:

```text
新增 CN 监听端口: 12002
Remote 后端地址 [127.0.0.1]: （回车使用默认值）
Remote 后端端口: 2347
Relay 服务名 [relay-jp-12002]: （回车使用默认值）
```

就会生成 `:12002 → chain-mtcp-jp → 127.0.0.1:2347`, 同时把 `12002` 写进 `BUSINESS_PORTS`。新增转发和初始主业务入口使用同一套输入规则：后端主机默认 `127.0.0.1`，后端端口必须明确设置。线路 `cn.yaml`、`mtcp.conf` 和聚合 `runtime.yaml` 会一起备份、一起替换；共享 GOST 没能正常恢复时三者一起回滚。Relay 候选在确认前记录源 fragment 签名，拿到锁后会再次校验；若另一个管理器已经修改同一线路，本次操作会要求重新执行，而不是覆盖并发更新。Watchdog 会统计该线路所有业务端口，慢路重抽前 Prewarm 还会再确认业务是否真正空闲。主业务端口和 Anchor 端口不能删除或覆盖。

如果安装目录不是默认的 `/opt/gost-mtcp`, 管理时带上同样的环境变量:

```bash
INSTALL_BASE=/root/mtcpjpv22 bash standalone-install.sh relay
```

只有一条线路时直接命令会自动识别；多条线路并存时菜单会列出别名、Remote endpoint、业务端口和当前状态，按编号选择即可。`CN_INSTANCE`、`CN_YAML_PATH` 和 `CN_MTCP_CONFIG_PATH` 仅保留给无人值守脚本使用。

旧版 `$INSTALL_BASE/cn/cn.yaml` 平铺布局会在首次重装线路时迁移并归档。共享 `runtime.yaml` 始终由编译器生成，不能直接手改。

### 删除线路实例与完全卸载

主菜单的 `[5]` 可以永久删除一个新版 `cn/instances/<线路>` 实例，也可以直接执行：

```bash
bash standalone-install.sh instance remove jp
```

删除前会展示 Remote、业务端口、实例目录、活跃连接数和剩余线路数，并要求再次确认。操作会删除该实例的 fragment、鉴权文件、状态、JSONL 日志、Anchor/Watchdog unit 和 `/run/gost-ecmp-pathlock/` 中对应的锁文件。还有其他线路时，安装器会先生成并校验不含目标实例的新 `runtime.yaml`，再重启共享 GOST，让剩余线路重新建连；提交或重启失败会恢复实例、聚合配置与 units。删除最后一条线路时，会一并停止、disable 并删除共享 `gost-mtcp.service`。

主菜单的 `[6]` 用于完全卸载，也可直接执行：

```bash
bash standalone-install.sh uninstall
# 自动化环境必须显式确认
PATHLOCK_UNINSTALL_CONFIRM=DELETE_ALL bash standalone-install.sh uninstall
```

完全卸载会先列出并确认所有项目服务已经停止，再删除 standalone 与传统安装方式产生的 PathLock systemd units、enable 链接、CN/Remote 运行组件、配置、凭据、状态、JSONL 日志及 `/run/gost-ecmp-pathlock/` 运行状态。unit 名称只用于发现候选；必须由 unit 内容引用当前安装目录，或由 `Description`/内容携带明确的 `GOST ECMP PathLock` 标记，才会被认定为项目所有。即使名称恰好是 `gost-mtcp.service` 或匹配 `gost-mtcp-*-watchdog.service`，缺少 ownership 证据也不会删除；确认后还会在锁内复核 unit 名称与内容签名。Standalone 管理器内的安装、CN/Relay 配置、实例删除与完全卸载会先串行获取同一个 `/run/gost-ecmp-pathlock/manager.lock` lifecycle lock，再按固定顺序获取 CN config lock，避免不同维护事务互撞。若 `INSTALL_BASE` 是源码仓库，只清除安装产物并恢复 canonical 模板，不删除仓库和安装脚本；普通 `/opt/gost-mtcp` 部署会删除整个 `cn/`、`remote/` 运行目录。源码方式管理时需和安装时一样指定仓库的规范绝对路径，例如 `INSTALL_BASE=/root/gost-ecmp-pathlock bash standalone-install.sh uninstall`；为防止路径穿越，实例删除和完全卸载都会拒绝根目录、过宽目录、符号链接、`..` 和带尾斜杠的 `INSTALL_BASE`，并要求 `SYSTEMD_DIR` 同样是无符号链接的规范绝对路径。systemd journal 使用全机共享文件，安装器不会为了删除某个项目的历史记录而执行会波及其他服务的全局 vacuum；用户自行配置的防火墙规则以及系统级 `socat` 等软件包也不会被修改。

## 重要注意事项

⚠️ **Remote 防火墙仍然必须配好** —— 安装器现在会在 Relay 层校验密码，但鉴权不能替代网络层访问控制。防火墙里仍只放行 CN 的公网 IP 访问 MTCP 端口，以减少未授权连接和资源消耗:

```bash
# UFW 示例
ufw allow from <CN_IP> to any port 6600 proto tcp
```

⚠️ **别手动 enable CN 的 Anchor unit** —— Anchor 必须由 Prewarm/Watchdog 控制, 不要自己启动或 enable 它:

```bash
# ❌ 错误
systemctl enable gost-mtcp-jp-anchor.service

# ✓ 正确（安装器已经自动配置好了）
systemctl enable gost-mtcp.service
systemctl enable gost-mtcp-jp-watchdog.service
```

⚠️ **hard failure 没法无缝续传** —— 如果 outer TCP 真断了、GOST 被 kill, 或者 Remote 失联, 已有的业务 TCP 连接没法迁移到新 outer, 得等客户端自己重连。Watchdog 保证的是让新连接尽快恢复, 不是保住老连接。

单文件安装器适合生产部署或批量安装(下载快、不用装 Git、一行命令); 想边看代码边调试、了解完整设计的话用传统方式(`git clone` 后跑 `install.sh`)。

## 状态说明

| 状态 | 含义 |
|------|------|
| `FAST` | 唯一 outer、Anchor 正常、路径满足阈值 |
| `DEGRADED` | 连接可用但没达到最佳(路径慢、Anchor 异常、数据面探测暂时失败等) |
| `DOWN` | GOST/outer/Remote 不可用 |
| `FAULT` | outer 数量异常、stale outer, 或者优选过程本身出故障 |

## 故障排查

```bash
# 查看服务日志
journalctl -u gost-mtcp.service -n 100
journalctl -u gost-mtcp-jp-watchdog.service -n 100

# 查看状态
cat /opt/gost-mtcp/cn/instances/jp/state/status.json | jq

# 查看事件历史（也可从 standalone 主菜单选择 4）
tail -n 50 /opt/gost-mtcp/cn/instances/jp/state/events.jsonl

# 检查 Remote 连通性
timeout 2 bash -c "exec 3<>/dev/tcp/<REMOTE_IP>/6600" && echo "OK" || echo "FAIL"

# 检查当前 MTCP 数据面(替换实际 Anchor 端口)
timeout 3 bash -c '
exec 3<>/dev/tcp/127.0.0.1/12001 || exit 1
printf P >&3
IFS= read -r -n 1 reply <&3 || exit 1
[[ "$reply" == P ]]
' && echo "MTCP DATA OK" || echo "MTCP DATA FAIL"
```

## 目录结构

```
gost-ecmp-pathlock/
├── standalone-install.sh      # 单文件自包含安装器
├── install.sh                  # 传统安装器(需要完整项目)
├── scripts/
│   └── generate-standalone.sh # 从 canonical 文件生成 standalone 嵌入区
├── tests/
│   └── run.sh                 # shell 语法、生成一致性和关键保护回归检查
├── cn/                         # CN 端 canonical 模板与共享脚本
│   ├── cn.yaml                 # 单线路 fragment 模板
│   ├── mtcp.conf               # 单线路 Watchdog 配置模板
│   ├── compile-config.sh       # 合并所有线路为 runtime.yaml
│   ├── mtcp-lib.sh
│   ├── mtcp-prewarm.sh
│   ├── mtcp-watchdog.sh
│   └── *.service
└── remote/                     # Remote 端配置
    ├── remote.yaml
    ├── mtcp.auth               # 安装时生成的 0600 凭据文件（不提交）
    └── *.service
```

`cn/` 和 `remote/` 是运行配置、脚本和 systemd 的唯一来源。改了这些 canonical 文件之后记得跑一下 `scripts/generate-standalone.sh`; CI 或本地想确认 standalone 有没有跟着漂移, 用 `scripts/generate-standalone.sh --check`。

更详细的设计背景和原始方案讨论见 `DESIGN-archive.md`。

## 许可证

MIT
