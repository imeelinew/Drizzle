# Drizzle

Drizzle 是一个轻量的 macOS 菜单栏额度查看器，支持 Codex、Claude、Cursor、z.ai、OpenRouter、OpenCode Go 和 DeepSeek

## 本地构建

需要 macOS 15 或更新版本，以及安装了 macOS SDK 的 Xcode

```sh
xcodebuild -project Drizzle.xcodeproj -scheme Drizzle -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

## 设置

点击菜单中的“配置文件...”会用 [CotEditor](https://coteditor.com) 打开 `~/Library/Application Support/Drizzle/config.toml`，未安装时使用系统默认的 TOML 编辑器，没有文件关联时使用 TextEdit，Drizzle 不创建设置窗口

第一次启动会创建配置文件，里面带着全部字段和注释，删除任意一行就会恢复该项的默认值，保存后自动生效，无需重启，完整示例见 [docs/config.example.toml](docs/config.example.toml)

从旧版本升级时，如果只有原来的 `config.json`，第一次启动会读取其中的设置和凭据写出 `config.toml`，然后删除旧的 `config.json`，之后以 `config.toml` 为准

- `launchAtLogin`：是否登录时启动
- `refreshIntervalSeconds`：刷新间隔，支持 `0`（手动）、`60`、`300`、`900`、`1800`
- `refreshOnOpen`：是否打开菜单时刷新
- `enabledProviders`：开启的供应商，空数组表示全部关闭，列表顺序不影响菜单中的既有顺序
- `providerOrder`：供应商在菜单中从上到下的排列顺序，切换标签与额度卡片都按这个顺序显示；未列出的已开启供应商按默认顺序排在后面，列出的未开启供应商会被忽略
- `menuBar.provider`：菜单栏显示哪个供应商
- `menuBar.metric`：显示该供应商的哪项额度，取值见下表
- `menuBar.percentMode`：`remaining`（剩余）或 `used`（已使用），余额显示不受此项影响
- `credentials`：API key 与 Cursor Cookie，z.ai 区域支持 `global` 和 `bigmodel-cn`

Codex 和 Claude 继续读取本地登录，Cursor Cookie 留空时读取 Cursor 本地登录，OpenCode Go 和 DeepSeek 的 API key 留空时继续读取原来支持的环境变量，z.ai 和 OpenRouter 需要在文件中填写 API key

OpenCode Go 支持两种认证方式，额度请求与解析移植自 CodexBar（`664311fc8`）：

- API：填写 `credentials.openCodeGoKey`，留空时读取 `OPENCODE_API_KEY`，显示 API 返回的 5 小时、周和月额度。
- Console：填写 `credentials.openCodeGoCookie`，支持 Cookie 请求头或浏览器复制的 cURL 请求，必须包含 `__Host-console_session`。此项非空时优先使用 Console，失效时会显示错误，请重新登录 [OpenCode Console](https://opencode.ai/console) 并更新 Cookie。
- `credentials.openCodeGoWorkspaceID`：可选的 `org_…` 或 `wrk_…` 工作区 ID，留空时与 CodexBar 一样使用工作区列表中的第一个；多工作区账号建议明确填写订阅所在工作区。

Console 路径读取账户实时额度，月额度重置时间在接口未提供时使用订阅周期结束时间。只显示接口实际提供的额度窗口，不读取本地用量或费用历史。

| 供应商 | `menuBar.metric` |
| --- | --- |
| `codex`、`claude`、`zai` | `session`、`weekly` |
| `cursor` | `total`、`cursor`、`thirdParty`、`grokBot` |
| `openrouter` | `keyLimit` |
| `opencodego` | `session`、`weekly`、`monthly` |
| `deepseek` | `balance` |

配置使用 TOML，支持 `#` 注释、`[配置段]`、多行数组和尾随逗号，字符串可以用 `"…"`、`'…'` 或 `"""…"""`（粘贴 cURL 时很有用）。解析器只实现配置需要的语法，行内表、数组表、浮点数和日期都会报错并指出行号。遗漏字段使用默认值，未知字段会被忽略，并在菜单里提示行号；值类型或取值错误会拒绝加载，运行期间写错时继续使用上一次有效配置，并在菜单中显示错误，修正保存后自动恢复

配置文件包含凭据，创建时目录权限为 `700`，文件权限为 `600`，仅当前用户可访问，应用不会在错误信息中输出凭据

## 更新与发布

Drizzle 使用 Sparkle 2 和 EdDSA 签名更新，更新源位于 [docs/appcast.xml](docs/appcast.xml)

发布者在有 Apple Development 证书的 Mac 上运行 `scripts/release.sh <版本> <构建号>`，脚本会构建、验证并上传一个应用 ZIP，Release 发布后 GitHub Actions 会签名归档并更新 appcast

Sparkle 更新签名不需要付费 Apple Developer Program 会员，但 Developer ID 签名与公证需要付费会员，未公证应用的首次下载可能被 macOS Gatekeeper 警告或拦截，EdDSA 只保护后续更新

## 第三方项目

Drizzle 使用了 [CodexBar](https://github.com/steipete/CodexBar) 的部分实现和资源，并集成了 [Sparkle](https://github.com/sparkle-project/Sparkle)，许可与来源见 [NOTICE](NOTICE) 和 [Sparkle 许可](THIRD_PARTY_LICENSES/Sparkle-LICENSE)

服务商名称和标志仅用于标识所支持的服务，Drizzle 与这些服务商没有隶属关系
