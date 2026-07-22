# 架构说明

AnnoyO 是单进程 SwiftUI 菜单栏应用。仓库没有第三方包依赖，核心模块按状态所有权划分。

## 模块

- `AnnoyOApp`：应用入口和菜单栏生命周期。
- `MenuBarView`、`AccountView`：界面、手势和展示状态，不直接访问远端接口。
- `PlayerController`：主线程上的播放编排模块，拥有当前播放意图，并协调队列、音频解析、预取和系统媒体命令。
- `PlaybackQueue`、`SavedPlaylistStore`：播放队列与列表持久化，JSON 文件使用原子写入。
- `BilibiliService`：actor 隔离的远端接口模块，负责 Cookie、WBI 签名和响应解码。
- `AudioCache`：音频缓存接口；内部包含加锁的 LRU 存储和串行的 AVAsset Range 加载实现。
- `AudioReactiveLevel`：从真实 PCM 提取频带能量，驱动播放动画。

## 主要数据流

```text
SwiftUI action
    -> PlayerController (@MainActor)
        -> BilibiliService (actor)
        -> AudioCache (thread-safe)
        -> PlaybackQueue / SavedPlaylistStore
        -> AVPlayer / MediaPlayer
```

`PlayerController` 是播放行为的唯一所有者。视图通过它表达意图，不直接组合网络请求或修改 AVPlayer。

## 并发约束

- 所有可观察的播放和界面状态都在主 actor 上修改。
- `BilibiliService` 的 Cookie、设备指纹和 WBI 密钥由 actor 隔离。
- `AudioCacheStore` 的索引和文件写入由同一把锁保护。
- `AudioResourceLoader` 在单一串行队列上处理 AVFoundation 与 URLSession 回调，同一音轨最多保留一个源站 Range 请求。
- 预取是可取消的尽力而为操作；取消后不会提交尚未完成的数据。

## 本地数据

- 播放列表与恢复位置：`~/Library/Application Support/AnnoyO/`
- 音频缓存：`~/Library/Caches/AnnoyO/Audio/`
- Bilibili 登录 Cookie：系统 `HTTPCookieStorage`

清除音频缓存不会删除播放列表或登录状态。退出账号只删除本机 Bilibili Cookie。

## 验证

`scripts/check.sh` 编译并运行不访问公网的行为检查，同时守护少量难以从无障碍树稳定断言的界面契约。完整 UI 目标由 Swift Package 的 release build 验证；联网检查默认关闭。
