# 第三方声明

OneMd 的项目代码沿用 [MIT 许可证](LICENSE)。分发源码或应用时，应一并保留本文件及下列许可原文。

| 组件 | 用途与来源 | 许可 |
|---|---|---|
| MarkView | [Paul Kang 的 macOS 应用](https://github.com/paulhkang94/markview)；基座 commit `523804c76a60de8f36012c187fa8efe65b6ee070`，保留原目录及部分命名 | [MIT](LICENSE)，Copyright (c) 2026 Paul Kang |
| swift-cmark 0.9.0 | [Markdown／GFM 解析](https://github.com/swiftlang/swift-cmark)，锁定 revision `08ddb528923cc1a6527e02b7a1aee9e516ca749a` | [完整 COPYING](docs/licenses/swift-cmark-COPYING.txt)，含 BSD 及所纳入代码的声明 |
| Prism 1.29.0 | [代码高亮](https://github.com/PrismJS/prism/tree/v1.29.0)，本地内嵌 JavaScript | [MIT](docs/licenses/Prism-MIT.txt)，Copyright (c) 2012 Lea Verou |
| 应用图标 | 沿用 [MarkView](https://github.com/paulhkang94/markview) 随源码提供的 `AppIcon.icns` | 随 MarkView 项目 MIT 分发，未另声明独占品牌权利 |

应用包的 `Contents/Resources/` 中附带 `LICENSE`、本文件及 `Licenses/` 原文。应用内文件引用以源码仓库为基准，离线查看许可请直接打开 `Licenses/`。

Prism 内嵌文件包含一处本地修正：在 source map 注释与后续语言定义之间补换行，避免语言定义被当作注释。

Dark／Light 的配色参考 Warp；Dracula、Nord、One Dark、Tokyo Night、Catppuccin Mocha、Solarized Light 是外观选项的说明名称。应用仅包含项目中的配色值，未捆绑这些主题项目的程序。名称和商标归各自权利人所有，不代表认可或关联。

系统字体及 SF Symbols 由 macOS 提供，不随安装包分发。
