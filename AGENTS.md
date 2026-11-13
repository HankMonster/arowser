# arowser 维护约定

arowser：面向 agent 的 macOS 网页窗口（单文件 Swift app + CLI）。本文件只放维护约定；使用方法以 [README.md](README.md) 为权威。

## 结构

- `Arowser.swift`：单文件 Swift 应用（AppKit + WKWebView），窗口与控制面逻辑全在此
- `bin/arowser`：bash CLI；`bin/arowser-watch`：本地 HTML 监控自动刷新（python3，无第三方依赖）
- `build.sh`：编译安装到 `~/Applications/arowser.app`，链接 `~/.local/bin/arowser` 与 `~/.local/bin/arowser-watch`
- `assets/icon/`：应用图标与菜单栏 glyph（模板图）
- `zh-Hans.lproj/`：简体中文 UI 翻译，英文原文作为键和默认回退
- `tests/`：UI 本地化键覆盖与资源语法测试（Python unittest + macOS plutil）
- `skills/`：三个 agent 技能（arowser 用法 / notify-user 通知卡 / show-info 结果展示），对外发布的一部分
- `docs/`：设计决策与交接记录

## 维护约定

- 重建前先 `arowser quit --all`，否则旧实例继续占用 `arowser://` scheme；从仓库根目录调用 `build.sh`（内部按相对路径取资源），重装后 `ls ~/Applications/arowser.app/Contents/Resources` 核对图标资源在位
- 行为改动按 README「How it's tested」的方法实测关键路径（窗口隔离、owner、本地 HTML、弹窗、缩放、刷新、cookie 镜像），不以编译通过代替验证；新验证结论回写 README 对应小节
- 架构与设计决策背景追加 `docs/`，命名 `YYYYMMDD_HHMM-<kebab-case>.md`
- 本地化：UI 文案用英文原文键经 `L()`/`LF()` 读取；同步维护 `zh-Hans.lproj/Localizable.strings`，中文值保留原文。查找条以 JSON 编码后的 Swift 插值注入 JS，原生错误卡直接用 `L()`；变更后跑 `python3 -m unittest discover -s tests`，重建核验双语错误卡与查找条，菜单和 ⌘Q 弹窗留真人验证。
- 技能维护：`description` 按能力面系统更新（新能力升正文小节，不钉触发词补丁）；个人/私有工作流约定（具体通知渠道、业务配色等）不进入公开技能
- 发布（commit/推送公开）前跑脱敏审计，全仓零命中为通过；**模式清单不在公开仓维护**（内部标识名本身不外泄），权威清单与豁免说明见私有侧 arowser 内部参考文档：

```bash
grep -rnIE '<desensitization-pattern-list>' . --exclude-dir=.build --exclude-dir=.git | grep -v 'com.hank.arowser'
```

（`com.hank.arowser` 为 bundle id，保留不改）
