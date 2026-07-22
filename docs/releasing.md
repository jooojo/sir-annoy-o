# 发布流程

发布版本以 `Packaging/Info.plist` 中的 `CFBundleShortVersionString` 为准。tag 必须严格使用对应的 `v<version>`，例如版本 `0.1.0` 对应 `v0.1.0`。

## 发布前演练

1. 确认 `main` 的 CI 已通过。
2. 在 GitHub Actions 中手动运行 `Release` workflow。
3. 下载并检查 workflow artifact；其中应包含应用压缩包和对应的 SHA-256 文件。

手动运行只生成临时 artifact，不创建 GitHub Release。

## 正式发布

```bash
git tag -a v0.1.0 -m "AnnoyO 0.1.0"
git push origin v0.1.0
```

tag push 会重新运行离线检查、构建 `AnnoyO.app`、验证签名和压缩包，并创建带有应用压缩包及 SHA-256 文件的 GitHub Release。tag 与应用版本不一致时，workflow 会直接失败。

## 签名边界

当前公开构建使用 ad-hoc 签名，不包含 Apple Developer ID 签名或 notarization。它适合源码可审计的早期版本，但不应描述为经过 Apple 身份验证的正式分发包。接入 Developer ID 和 notarization 后，必须同步更新 workflow、README 和 Release 说明。
