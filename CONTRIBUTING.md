# 参与贡献

感谢你愿意改进 AnnoyO。提交改动前，请先确认它与“原生 macOS 菜单栏纯音频播放器”的范围一致。

## 开发环境

- macOS 13 或更高版本
- Swift 6.2 或更高版本
- 与当前 macOS SDK 匹配的 Xcode 或 Command Line Tools

首次拉取后无需安装第三方依赖：

```bash
swift run AnnoyO
```

## 修改流程

1. 为行为变化补充离线检查，避免依赖真实账号、网络或本机私有文件。
2. 运行 `./scripts/format.sh` 统一 Swift 格式。
3. 运行 `./scripts/check.sh` 执行格式、行为和关键界面契约检查。
4. 运行 `swift build --configuration release` 验证完整应用目标。

只有排查 Bilibili 接口兼容性时才运行联网检查：

```bash
ANNOYO_LIVE_TESTS=1 ./scripts/check.sh
```

## 代码约定

- UI 与播放状态留在 `@MainActor`；网络状态放在 actor；共享缓存状态必须串行化或加锁。
- 优先把复杂行为藏在小而稳定的模块接口后，不为单一实现引入抽象层。
- 取消任务后不得继续产生持久化副作用。
- 测试描述可观察行为，不依赖私有实现细节。
- 不提交 Cookie、账号数据、构建产物、缓存或真实媒体文件。

模块职责和关键并发约束见 [`docs/architecture.md`](docs/architecture.md)。

## Pull Request

请在说明中写清：

- 用户可见的行为变化；
- 主要实现取舍；
- 已运行的验证命令；
- 涉及 UI 时附上截图或录屏。
