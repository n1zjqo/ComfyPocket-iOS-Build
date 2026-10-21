# 来源与许可

依据 ComfyUI HTTP / WebSocket 协议独立编写 Swift / SwiftUI 客户端，没有移植 Kotlin UI 或加入 Android 二进制。

研究对象：Mimikkoro1/comfy-workbench-android，commit 5aa7e44d5efad3d1a86b4b163d362ab5f404ef85（0.3.0），上游 GPL-3.0。源码分析报告位于相邻的 comfy-workbench-android-source-review.md。

本项目源代码按 GNU GPL version 3 或之后版本提供。完整文本见 LICENSE；发布 IPA 时应同时提供对应源码和构建说明，保留第三方许可。

核验来源：Comfy-Org/ComfyUI 的 server.py（HTTP 与进度接口）；opa334/TrollStore 的 README（IPA 安装和签名说明）；Apple SwiftUI / Foundation / UIKit / AVKit / Photos 系统 SDK。没有复制或调用漏洞利用实现。

XcodeGen 和 GitHub Actions 不打包进 App。无广告、遥测或第三方云账户 SDK。图标由确定性绘图脚本生成，无外部图片素材。
