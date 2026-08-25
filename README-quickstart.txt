gost-ecmp-pathlock quick start

生产环境推荐保存并使用单文件 standalone-install.sh；无参数运行即打开统一管理菜单。
克隆项目进行开发/调试时，根目录 install.sh 是源码安装入口。
CN 和 Remote 目录下没有、也不需要单独的安装脚本。

Standalone：

  Remote：
    curl -fsSL https://raw.githubusercontent.com/zcp1997/gost-ecmp-pathlock/main/standalone-install.sh -o /root/standalone-install.sh

  CN（中国大陆，走 ghfast）：
    curl -fsSL https://ghfast.top/raw.githubusercontent.com/zcp1997/gost-ecmp-pathlock/main/standalone-install.sh -o /root/standalone-install.sh

  打开菜单：
    bash /root/standalone-install.sh

  主菜单：
    1) 全新安装 CN 端 / Remote 端
    2) 列出已有配置和端口路径
    3) 选择一个 CN 线路，增删端口转发
    4) 查看线路 JSONL 日志
    5) 删除一个 CN 线路实例（会重启共享 GOST，让剩余线路重连）
    6) 完全卸载全部 PathLock 运行组件、配置、JSONL 日志和 systemd 单元

多线路会直接显示编号选择器，不需要手动设置 CN_INSTANCE。
也可直接执行：bash standalone-install.sh instance remove jp
完全卸载：bash standalone-install.sh uninstall（需输入 DELETE ALL 确认）。

建议顺序：
  1. 先安装 Remote，设置鉴权密码并记录公网 IPv4、MTCP 端口和密码
  2. 再安装中国大陆 CN，输入同一个鉴权密码

下载项目：

  CN（中国大陆，走 ghfast）：
    git clone https://ghfast.top/https://github.com/zcp1997/gost-ecmp-pathlock.git

  Remote（境外，直连 GitHub）：
    git clone https://github.com/zcp1997/gost-ecmp-pathlock.git

两台服务器进入项目根目录后执行：

  cd /root/gost-ecmp-pathlock
  bash install.sh

在源码安装向导中根据当前服务器选择：

  1) CN      中国大陆入口 / 路径优选端
  2) Remote  境外 Relay 端

也可以直接指定：

  bash install.sh remote
  bash install.sh cn

Remote 默认监听 6600/tcp，并强制设置 12-128 位 MTCP Relay 鉴权密码。
CN 安装时会询问同一鉴权密码、主业务入口的 Remote 后端地址/端口和 RTT 快路准入阈值。
后端地址直接回车默认 127.0.0.1，后端端口必须明确设置；不会再自动指向 127.0.0.1:2345。
RTT 默认 40ms，可自定义。鉴权凭据保存在权限为 0600 的 mtcp.auth 文件中，不写入 YAML。
CN 全机只启动一个共享 gost-mtcp.service；每条线路保留独立的轻量 Watchdog 与 Anchor。
新增线路或 Relay 会重建 runtime.yaml 并短暂重启共享 GOST，因此影响所有线路。
检测到活跃业务时，菜单会显示连接数并要求再次确认；直接命令需使用 CN_FORCE_RESTART=1。
CN 安装 GOST 时默认通过 ghfast.top 下载，Remote 默认直连 GitHub。
如需让 CN 强制直连：GITHUB_PROXY_PREFIX= bash install.sh cn
自动化安装可在两端传入相同的 MTCP_AUTH_PASSWORD（不要写入 shell 历史或日志）。
de、us 是 Remote 节点/线路别名，不是 CN 地区。
多条 Remote 线路必须使用不同的 CN 业务端口、Anchor 端口以及 Remote IP:port。

别名 de 的事件日志：
  tail -n 30 /root/gost-ecmp-pathlock/cn/instances/de/state/events.jsonl

不要 enable CN 的 Anchor unit，它必须由 Prewarm/Watchdog 控制。
详细说明见 README.md。
