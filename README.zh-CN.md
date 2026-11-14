# arowser（中文简介）

**面向 agent 可编程的 macOS 网页窗口**：一条命令把 URL 放进可自由摆放的无边框小窗，CLI 专为编码 agent 驱动设计——窗口按稳定 id 寻址、多 agent 互不干扰、登录态跨重启保留。

名字由来：**arowser** = **browser** 的 b 换成 **a**（a 代表 agent）——一个主要用户是你的编码 agent 的浏览器，由 agent 开窗给你看。它脱胎于作者自己的日常 agent 工作流（真实工作会话里 agent 弹出看板、报告和通知卡片），且不碰系统里其他浏览器的设置与数据。

## 安装

需要 macOS 12+ 与 Swift（Xcode Command Line Tools），无其他依赖：

```bash
git clone https://github.com/HankMonster/arowser.git
cd arowser
./build.sh
```

产物：`~/Applications/arowser.app`、`~/.local/bin/arowser`、`~/.local/bin/arowser-watch`（确保 `~/.local/bin` 在 PATH）。重建前先 `arowser quit --all`。

## 快速上手

```bash
id=$(arowser open https://example.com --title demo)   # 打印唯一窗口 id
arowser show "$id" https://example.org                # 只导航这个窗口
arowser show "$id"                                    # 置前/取消隐藏，不重载
arowser close "$id"
```

窗口无标题栏：顶部 28pt 拖动条（或 ⌥+任意位置拖动）移动、边缘缩放、⌘W 关闭。

## 核心概念

- **窗口 id**：每次 `open` 生成唯一 id，`show/hide/close/reload` 只作用于该 id；多窗口、多 agent 天然隔离
- **owner**：窗口记录创建者，跨 owner 操作被拒（退出码 3）；Claude Code 会话自动携带，其他 agent 设 `AROWSER_OWNER`
- **profile / private**：默认 cookie 仓库共享持久；`--profile NAME` 按账号隔离（持久）；`--private` 关窗即清。内建 cookie 镜像让会话 cookie 登录态也跨冷重启保留
- **serve**：本地目录挂到内建静态服务（`file://` 页面 fetch 被 WebKit 拦截，按需取数页面用它），URL 跨重启稳定，仅 127.0.0.1、无鉴权

## Agent 技能

[`skills/`](skills/) 内置三个技能，复制到你的 agent 技能目录即可：`arowser`（完整用法手册）、`notify-user`（任务完成/需要配合的置顶通知卡）、`show-info`（表格/图表/长输出渲染成展示窗）。

## 更多

完整命令参考、功能细节（会话恢复、窗口历史、热键、watch 热刷新）、测试方法与边界，见 [English README](README.md)。

---

如果 arowser 融入了你的日常工作流，欢迎点个 star，帮其他 agent（和它们的人类）找到它。
