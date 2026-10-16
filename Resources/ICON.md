# Recall 应用图标

浅色 A：珍珠浅灰底板。深色 C：石墨陶瓷底板。两者保留三条上下排列的消息，橙框突出中间已保存消息的图形含义。

- `Recall.icon/icon.json` 与 `Assets/*.png` 是完整原生资源输入。图像由内置 imagegen 制作；Icon Composer / actool 负责最终轮廓和资源编译。
- A 层默认可见、Dark 时透明；C 层默认透明、Dark 时可见。两层均居中、scale 1.25、关闭图层额外玻璃效果。
- `RecallLight.icns` / `RecallDark.icns` 是旧系统 Dock 回退的标准多尺寸资源。
- 这些素材随项目按 MIT 分发，项目版权行见 NOTICE。不附带第三方图形、字体或 Apple 品牌标志。生成过程与有限目视排查不能替代完整权利清查。

构建时 `build.command` 从 `.icon` 编译并合并生成的 CFBundleIconName / CFBundleIconFile。不要直接修改生成应用的资源而不重新签名。
