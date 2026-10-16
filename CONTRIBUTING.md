# 参与开发

本版保持 Apple Silicon、Codex 桌面端、整条文字消息和本地保存的范围。修改前请先说明具体问题与验证方法；较大功能变更适合先讨论。

## 环境与检查

使用 Apple Silicon Mac、包含 actool 的完整 Xcode 和 Python 3.8+。已验证 Xcode 27.0 / Swift 6.4；其他工具链版本未验收。在仓库根目录运行：

```sh
./test.command
./build.command
```

`RECALL_PYTHON` 可以指定 Python 3 可执行文件；测试服务会直接使用这一已选定解释器，未指定时从 PATH 查找 python3。全部构建产物、测试二进制、模块缓存及临时数据位于被忽略的 `build/`。测试只启动虚构 stdio 服务和独立命名剪贴板，不需要真实 Codex 或辅助功能授权。

若从源码启动应用进行手工测试，请使用单独的本地数据目录，并避免与正在使用的 Recall 实例同时运行。相同 bundle ID 的不同构建可能影响系统授权识别；不要为开发而覆盖自己的日常安装。

先退出日常版本，再从终端启动隔离数据目录的开发构建，例如：

```sh
RECALL_DESKTOP_DATA_DIR="$PWD/build/manual-test-data" "./build/Recall Desktop.app/Contents/MacOS/RecallDesktop"
```

该变量只隔离标记文件，不隔离系统授权或快捷键身份。GitHub Actions 使用官方 `xcode-27` arm64 runner；该镜像目前为公开预览，工作流尚未在 GitHub 实际执行。其可用性和默认工具链可能变化，应检查工作流日志。见 [GitHub runner 文档](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。

## 本地签名

默认构建使用临时开发签名。若你已有可用于代码签名的本地身份，可以设置：

```sh
RECALL_SIGNING_IDENTITY='你的已有签名身份名称' ./build.command
```

非默认钥匙串可另设 `RECALL_SIGNING_KEYCHAIN`。脚本不创建证书、导入私钥、修改系统信任、自动授权或保存密码；指定身份失败时构建停止，不静默退回临时签名。不要提交身份文件或密码。正式分发要求见 [发布检查](docs/release-checklist.md)。

## 必须保留的行为

- 不能用缓存历史替代当次完整来源证明，不能以局部段落冒充整条消息。
- 不允许模糊定位、静默跳到相似消息或仅打开对话就显示成功。
- 不读取认证凭证，不访问宿主私有数据库，不接云端上传或模型调用。
- 采集、返回、取消及剪贴板清理均要遵守当前窗口、前台及操作所有权。
- 存储失败保留输入；恢复或并发修改不能静默覆盖数据。

新增检查应覆盖真实失败模式，使用虚构消息和临时目录。真实宿主人工验证与自动检查分开记录，不把虚构窗口结果描述为完整宿主兼容性。

## 提交修改

说明用户触发条件、前后行为、验证及剩余限制。不要把真实标记、备份、宿主日志、认证资料或私人路径写入提交、截图或 Issue。贡献需有权以本项目 MIT 条款分发；不要求转让版权。

## 图标资源

`Resources/Recall.icon/` 是可编辑的浅深色原生工程；两层分别为 A 与 C，通过外观不透明度选择。`build.command` 每次从工程编译 Assets.car 与兼容 ICNS，并合并编译器生成的图标声明。`RecallLight.icns` / `RecallDark.icns` 是较旧系统运行中 Dock 切换所用的导出资源。不要修改辅助功能或消息定位代码来更新图标。

## 可选正式签名配置

默认构建仍使用 ad-hoc 开发签名。已有 Developer ID Application 身份时，可设置 `RECALL_DISTRIBUTION=1` 和 `RECALL_SIGNING_IDENTITY` 再构建；该模式启用 hardened runtime 与安全时间戳，并拒绝 ad-hoc/普通开发身份。签名不等于公证，构建脚本不会上传任何内容，仍需开发者另行完成 Apple 公证与实际下载验收。没有 Developer Program 资格时使用明确标注的未公证测试版，不伪造信任或修改 Gatekeeper。参考 [Apple Developer ID](https://developer.apple.com/developer-id/)。
