# 第三方与运行依赖

本候选使用 Apple 提供的 SwiftUI、AppKit、Foundation、CryptoKit、ApplicationServices、Carbon 及系统类型框架；这些是平台 SDK/系统运行依赖，不作为本项目源码的一部分重新授权或捆绑。

界面使用系统符号。Recall A/C 图标使用本项目生成的栅格素材，经 Icon Composer 整理；项目可授权的素材按 MIT 分发，原生工程及图像输入均在 Resources 中提供。制作时没有导入从其他应用提取的图标或字体文件；生成结果尚未经过完整的图形近似与商标权利清查，本说明不保证不存在第三方权利冲突。Apple 图标编译器只作为构建工具使用，不随应用捆绑。Python 仅运行标准库虚构测试服务，不打包进应用。Codex 是用户自行安装的独立宿主，名称仅用于兼容性说明。

`LICENSE` 采用标准 MIT License 文本，署名为 Copyright (c) 2026 BigFat-Dev；完整授权条件及免责条款保留。项目声明见 `NOTICE`。标准文本参见 [Open Source Initiative](https://opensource.org/license/mit)。

GitHub Actions 中引用的 `actions/checkout` 按其自身许可运行，不将 action 源码复制到本项目。未来引入外部代码或素材时，应先核实许可证并更新本文件。
