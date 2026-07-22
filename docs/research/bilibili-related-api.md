# Bilibili 当前视频“相关推荐”列表与 Top 1 API

日期：2026-07-21

## 结论

Bilibili 网页当前视频的“相关推荐”来自第一方但未公开承诺稳定性的接口：

```http
GET https://api.bilibili.com/x/web-interface/archive/related
```

网页把响应的 `data` 数组作为相关推荐列表，因此严格意义上的 top 1 是第一个有效元素 `data[0]`。在本次核验样本 `BV1xx411c7mD` 中：

- [视频网页](https://www.bilibili.com/video/BV1xx411c7mD/) 的 `window.__INITIAL_STATE__.related[0].bvid` 是 `BV1tx411c7ji`；
- [接口响应](https://api.bilibili.com/x/web-interface/archive/related?bvid=BV1xx411c7mD&need_operation_card=1&web_rm_repeat=1&from_spmid=333.788.0.0&spmid=333.788.0.0&from_trackid=) 的 `data[0].bvid` 也是 `BV1tx411c7ji`；
- 页面初始状态与接口响应均返回 40 个推荐项，但数量是本次观测值，不应写成客户端契约。

当前页面声明加载的第一方 [video JavaScript bundle](https://s1.hdslb.com/bfs/static/jinkela/video/video.8df4bfdc8a4ea4283f4cdb56e1d073a7750a1f3f.js) 中，`getRelated` 明确对 `/x/web-interface/archive/related` 发起 GET，请求成功后执行等价于 `setRelated(response.data.data || [])` 的逻辑。这个带 hash 的 bundle 地址会随网页发布变化；它只作为 2026-07-21 的源码快照证据。

## 请求参数

### 视频标识

接口接受以下任一种视频标识：

| 参数 | 说明 | AnnoyO 选择 |
| --- | --- | --- |
| `aid` | AV 号的数值部分 | 网页主推荐组件当前使用它 |
| `bvid` | BV 号，例如 `BV1xx411c7mD` | **推荐**；项目的 `VideoSearchResult` 已持有它，无需再查 `aid` |

本次分别使用 `aid=2` 和 `bvid=BV1xx411c7mD`，在相同网页参数下得到相同的推荐 `bvid` 顺序。两个标识都不传时，第一方接口实际返回：

```json
{
  "code": -400,
  "message": "请求错误",
  "ttl": 1
}
```

### 当前网页使用的附加参数

当前网页 bundle 的主推荐组件传入：

| 参数 | 当前值/来源 | 用途判断 |
| --- | --- | --- |
| `need_operation_card` | `1` | 请求运营推荐卡相关能力 |
| `web_rm_repeat` | `1` | 网页端去重行为 |
| `from_spmid` | URL 的 `spm_id_from`，缺省 `333.788.0.0` | 页面来源追踪上下文 |
| `spmid` | `333.788.0.0` | 当前视频详情页位置标识 |
| `from_trackid` | URL 的 `trackid`，缺省空字符串 | 推荐链路追踪上下文 |

对 AnnoyO，建议请求至少带：

```text
bvid=<当前视频 BV 号>
need_operation_card=1
web_rm_repeat=1
```

`from_spmid`、`spmid`、`from_trackid` 是网页来源/追踪上下文，不是识别视频所必需。本次实测只带 `bvid` 也成功并得到相同 top 1；不过附加网页参数后，40 项中的后续顺序与精简请求并不完全相同。若产品定义要求尽量贴近网页当前推荐顺序，应保留 `need_operation_card=1` 与 `web_rm_repeat=1`，不要假定完整列表在不同请求上下文下恒定。

### Header、登录与签名

- 本次使用普通浏览器 `User-Agent` 与当前视频 `Referer`，不带登录 Cookie、WBI 签名也得到 `code = 0`；该路径不是 `/wbi/` 接口。
- 网页源码设置了 `withCredentials: true`，所以登录用户的浏览器 Cookie 会随请求发送。AnnoyO 应继续使用现有共享 Cookie session，让已登录状态自然参与请求；不应为了匿名可用而主动去掉 Cookie。
- 推荐结果可能随时间、账号、实验分组和请求上下文变化。客户端应在需要“下一个”时实时取 `data[0]`，不应固化本次样例结果。

## 返回 JSON 结构

本次第一方响应的顶层结构是：

```json
{
  "code": 0,
  "message": "OK",
  "data": [
    {
      "aid": 11420,
      "bvid": "BV1tx411c7ji",
      "cid": 19911,
      "title": "[略鬼畜]创价之卡比",
      "desc": "sm5402092 撸了",
      "pic": "http://i2.hdslb.com/bfs/archive/b0720f2f257309e3a672b71ed9caa78308bf5a87.jpg",
      "duration": 160,
      "pubdate": 1277666242,
      "owner": {
        "mid": 0,
        "name": "",
        "face": ""
      },
      "stat": {
        "view": 439563,
        "danmaku": 11496,
        "like": 9521
      },
      "rcmd_reason": ""
    }
  ]
}
```

样例只保留了 AnnoyO 需要的字段。实际单项还包含 `videos`、`tid`、`tname`、`copyright`、`ctime`、`state`、`rights`、`dimension`、`short_link_v2`、`season_type`、`is_ogv`、`ogv_info`、`enable_vt` 等字段。完整结构应按宽松 DTO 解码：只把生成 `VideoSearchResult` 所需字段设为必要条件，其余字段忽略或可选，避免第一方添加字段时解码失败。

注意样例的 `owner.name` 确实为空，且 `pic` 是 `http://`，不是搜索接口常见的 `//...`。这两种情况都要显式兼容。

## 映射到 `VideoSearchResult`

项目模型见 [`Sources/AnnoyO/Models.swift`](../../Sources/AnnoyO/Models.swift)，现有格式化辅助逻辑见 [`Sources/AnnoyO/BilibiliService.swift`](../../Sources/AnnoyO/BilibiliService.swift)。推荐项映射如下：

| `VideoSearchResult` | Related API 字段 | 转换 |
| --- | --- | --- |
| `bvid` | `bvid` | 非空才接受；也是 `id` 与 `webURL` 的来源 |
| `title` | `title` | 可复用 `removingHTML` 做防御性清理，尽管本次返回的是纯文本 |
| `creator` | `owner.name` | 直接使用；为空时 UI 可显示统一占位文案，不要丢弃整个推荐项 |
| `description` | `desc` | 缺失时使用空字符串 |
| `coverURL` | `pic` | `//...` 补 `https:`；`http://` 升级为 `https://`；无效值映射为 `nil` |
| `durationText` | `duration` | 秒数格式化为 `m:ss`；超过一小时用 `h:mm:ss`。样例 `160` 应为 `2:40` |
| `playCountText` | `stat.view` | 复用现有 `compactCount`，样例为 `43.9万` |
| `publishedAt` | `pubdate` | Unix 秒时间戳转 `Date(timeIntervalSince1970:)` |

建议 DTO 的最小形状：

```swift
private struct RelatedResponse: Decodable, Sendable, APIResponse {
    let code: Int
    let message: String
    let data: [RelatedItem]?
}

private struct RelatedItem: Decodable, Sendable {
    let bvid: String
    let title: String?
    let desc: String?
    let pic: String?
    let duration: Int?
    let pubdate: Int?
    let owner: RelatedOwner?
    let stat: RelatedStat?
}
```

若产品要求严格 top 1，应在验证 `code == 0` 后只检查 `data.first`；仅当它的 `bvid` 非空且不是当前视频时才接受。AnnoyO 当前还保留完整的有效推荐顺序，用于“换一首”交互；默认下一首仍是列表第一项。

## 对“漫游”列表的直接含义

当当前音频变化且没有“来自搜索的置入”占据下一首时：

1. 用当前 `VideoSearchResult.bvid` 请求 related API；
2. 按返回顺序映射并保留有效推荐项；
3. 默认把第一项作为“漫游”的下一首，“换一首”沿列表向后切换；
4. 任一漫游项开始播放后，以新的当前项立即刷新一次推荐列表和下一首。

如果严格的 `data[0]` 后续无法解析音轨，产品可以选择显示错误或尝试后续推荐；但“跳过不可播放项继续寻找”已经不是字面意义上的 Bilibili top 1，应作为单独的容错策略明确决定。

## 来源与复现

所有外部事实均来自 Bilibili 第一方页面、页面声明的第一方 bundle 或第一方 API 实际响应：

- [样本视频网页及 SSR 初始状态](https://www.bilibili.com/video/BV1xx411c7mD/)
- [当前页面声明的 video JavaScript bundle](https://s1.hdslb.com/bfs/static/jinkela/video/video.8df4bfdc8a4ea4283f4cdb56e1d073a7750a1f3f.js)
- [按当前网页参数调用 related API](https://api.bilibili.com/x/web-interface/archive/related?bvid=BV1xx411c7mD&need_operation_card=1&web_rm_repeat=1&from_spmid=333.788.0.0&spmid=333.788.0.0&from_trackid=)
- [只带 bvid 的最小成功请求](https://api.bilibili.com/x/web-interface/archive/related?bvid=BV1xx411c7mD)
- [缺少视频标识的错误响应](https://api.bilibili.com/x/web-interface/archive/related)

复现时建议带：

```http
User-Agent: Mozilla/5.0 (...)
Referer: https://www.bilibili.com/video/<bvid>/
Accept: application/json, text/plain, */*
```

这是网页内部接口的当前实证，不是 Bilibili 对第三方客户端发布的稳定 API 合约；实现需要保留错误处理、可选字段与未来字段变化的容忍度。
