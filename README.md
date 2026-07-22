# AnnoyO

AnnoyO 是一个原生 macOS 菜单栏 Bilibili 纯音频播放器。它只解析 DASH 音轨，不加载视频画面，适合把长视频、播客和音乐列表放在后台连续播放。

> [!IMPORTANT]
> AnnoyO 是非官方社区项目，与哔哩哔哩无隶属或合作关系。请遵守平台条款、内容版权和所在地区的法律法规。

## 核心能力

- 原生 SwiftUI 菜单栏界面，紧凑的循环滚筒列表支持搜索、分页和播放列表管理。
- 手机扫码登录；登录 Cookie 仅保存在系统 Cookie 容器中。
- 列表循环、单曲循环和随机播放，以及多分 P 连续播放。
- 内置“漫游”列表，根据当前视频维护上一首、当前和下一首推荐。
- 可持久化的播放队列、列表和恢复位置。
- 基于 Range 请求的 2 GB LRU 音频缓存，并在播放稳定后预取下一首的前 1 MiB。
- 由真实 PCM 频带能量驱动的播放动画。
- macOS 媒体键与“正在播放”信息集成。

## 要求

- macOS 13 或更高版本
- Swift 6.2 或更高版本
- 与当前 macOS SDK 匹配的 Xcode 或 Command Line Tools

项目没有第三方包依赖。

## 快速开始

```bash
swift run AnnoyO
```

启动后点击菜单栏中的号角图标。

## 构建应用

```bash
./scripts/build-app.sh
open dist/AnnoyO.app
```

脚本生成 ad-hoc 签名的 `dist/AnnoyO.app`，适合本机运行。公开分发仍需要 Apple Developer 签名与公证。

## 开发与验证

```bash
./scripts/format.sh
./scripts/check.sh
swift build --configuration release
```

`check.sh` 默认完全离线。只有排查远端接口兼容性时才运行联网检查：

```bash
ANNOYO_LIVE_TESTS=1 ./scripts/check.sh
```

模块职责、状态所有权和并发约束见 [`docs/architecture.md`](docs/architecture.md)。参与开发前请阅读 [`CONTRIBUTING.md`](CONTRIBUTING.md)；安全问题请按 [`SECURITY.md`](SECURITY.md) 私下报告。

## 数据与隐私

- 播放列表和恢复位置保存在 `~/Library/Application Support/AnnoyO/`。
- 音频缓存保存在 `~/Library/Caches/AnnoyO/Audio/`，可在应用内清除。
- 登录 Cookie 由系统 `HTTPCookieStorage` 保存；退出账号会删除本机 Bilibili Cookie。
- 应用不提供音频文件导出功能。

Bilibili 的匿名网页接口和 WBI 签名可能随时变化。会员、付费、地区限制或仅登录可播放的内容不保证可用。

## License

AnnoyO 使用 [MIT License](LICENSE)。
