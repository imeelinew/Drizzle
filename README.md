# Drizzle

Drizzle 是一个轻量的 macOS 菜单栏额度查看器，支持 Codex、Claude、Cursor、z.ai 和 OpenRouter

## 本地构建

需要 macOS 15 或更新版本，以及安装了 macOS SDK 的 Xcode

```sh
xcodebuild -project Drizzle.xcodeproj -scheme Drizzle -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

## 更新与发布

Drizzle 使用 Sparkle 2 和 EdDSA 签名更新，更新源位于 [docs/appcast.xml](docs/appcast.xml)

发布者在有 Apple Development 证书的 Mac 上运行 `scripts/release.sh <版本> <构建号>`，脚本会构建、验证并上传一个应用 ZIP，Release 发布后 GitHub Actions 会签名归档并更新 appcast

Sparkle 更新签名不需要付费 Apple Developer Program 会员，但 Developer ID 签名与公证需要付费会员，未公证应用的首次下载可能被 macOS Gatekeeper 警告或拦截，EdDSA 只保护后续更新

## 第三方项目

Drizzle 使用了 [CodexBar](https://github.com/steipete/CodexBar) 的部分实现和资源，并集成了 [Sparkle](https://github.com/sparkle-project/Sparkle)，许可与来源见 [NOTICE](NOTICE) 和 [Sparkle 许可](THIRD_PARTY_LICENSES/Sparkle-LICENSE)

服务商名称和标志仅用于标识所支持的服务，Drizzle 与这些服务商没有隶属关系
