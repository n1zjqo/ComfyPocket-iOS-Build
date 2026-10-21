# ComfyPocket · 浮屿

独立 Swift / SwiftUI ComfyUI 客户端，最低 iOS 15。连接用户自行配置的 ComfyUI，导入 API JSON，编辑参数、生成并保存作品。不是 ComfyUI 网页的内嵌浏览器。

## 构建

在 macOS arm64 + CPython 3.12.10 + Xcode 16.4 上使用 XcodeGen 2.44.1 生成工程。最低部署版本 15.0；模拟器测试运行版本与最低部署版本不是一回事。Actions 仅允许仓库维护者手动触发。

1. 运行 scripts/install-xcodegen.sh（Actions 环境；下载文件执行固定 SHA256 校验），或自行安装同版本 XcodeGen。
2. 运行 bash scripts/start-test-server.sh，启动仅监听本机的固定版本官方 ComfyUI CPU 测试服务，自定义节点关闭。
3. 运行 bash scripts/build-ipa.sh，执行 Core / App / UI 测试，构建 arm64 Release，ad-hoc 签名并验证 IPA。
4. 审查本次 Actions 的全部结果、原生截图和 SHA256。仅成功的同一次构建可以交付；未通过的源码快照不等于可用 IPA。

此源码快照不包含私人仓库的 Git 历史、个人工作流、照片、运行日志、连接资料或签名私钥。SOURCE-SNAPSHOT.json 记录上传文件的 SHA256。测试图片是代码画布，不是扩散模型结果；双采样 JSON 是脱敏回归夹具。

## 参数和兼容性

- 支持 ComfyUI API JSON；普通 nodes/links 编辑器 JSON 需先在电脑转换。未更改节点拓扑。
- 全部节点来自实际导入图；标量字段与约束可从所选服务器 object_info 刷新。未知结构保留只读，不声称支持所有自定义节点。
- 草稿与应用值分离；取消不覆盖，应用统一校验并原子持久化，失败保留草稿。
- 种子以整数文本存储，支持统一种子或各节点独立种子。Ray 队列使用手机端统一种子展开。
- 图片保持完整画幅，右滑清屏、左滑恢复；原文件保存/分享通过系统功能完成。

没有付费服务、广告、遥测 SDK 或代管 ComfyUI。账号口令留在用户设备，不应放进公开仓库或工作流 JSON。HTTP 的局域网便利不等于传输加密；远程连接应优先 HTTPS / 可信 VPN，不要直接暴露无鉴权的 ComfyUI。

源码按 GPL-3.0-or-later 提供；发布对应 IPA 时应保留对应源码和构建说明，详见 LICENSE 与 THIRD_PARTY.md。安全边界见 SECURITY.md。

