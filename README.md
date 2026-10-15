# ClearZip · 干净压缩

一个原生 macOS ZIP 压缩工具，通过 Finder 右键生成不含 macOS 附加元数据的 ZIP。支持后台静默压缩，也提供拖入与文件选择窗口；无需第三方运行时，不联网、不改动原文件。

## 使用

从 [Releases](https://github.com/LJjayyy/ClearZip/releases) 下载与你的处理器架构对应的 DMG；也可本地构建后使用 `build/ClearZip-<版本号>.dmg`。双击打开，把 ClearZip.app 拖到旁边的 Applications（应用程序）文件夹，复制完成后弹出磁盘映像，再从“应用程序”打开。

1. 将 DMG 中的 ClearZip.app 拖到“应用程序”文件夹，打开一次。
2. 点击应用中的“访达扩展…”，在系统设置中启用 ClearZip。
3. 在访达选中文件或文件夹，右键 → **干净压缩“项目名称”**。多选时显示 **干净压缩 N 个项目**。
4. 后台静默压缩，ZIP 出现在原目录，不弹出 ClearZip 主窗口。访达仍在前台时会选中结果；已切换到其他应用时不抢焦点。失败时仅显示错误提示。

也可打开应用，将一个或多个文件拖进窗口，或点击“压缩…”。多选来源不同时，ZIP 放在第一个有效所选项目的父目录。

手动打开应用仍显示窗口，可查看进度和取消窗口中的任务。Finder 右键扩展启动内置的后台压缩程序，任务完成后自动退出；主应用窗口不参与这一流程。备用 Services 入口也在后台执行。

Finder 扩展仅将选中文件的路径写入自身私有缓存，由后台程序领取后删除；超过 10 分钟的请求会被拒绝。缓存目录和请求文件只允许当前用户访问，并通过文件锁避免并发重复消费。扩展无需读取源文件，也不改动用户剪贴板。应用不再注册或执行 `clearzip://` 链接；旧链接、非法参数，以及混合文件和网页 URL 的打开请求都会被拒绝。本机程序仍可使用命令行入口，这不提供 Finder 来源认证。

也保留“服务 → 干净压缩”作为备用入口。该服务若未出现，可在“系统设置 → 键盘 → 键盘快捷键 → 服务 → 文件和文件夹”勾选“干净压缩”。

App 图标采用原创几何绘制的绿色折叠 Z 与银灰底板，由 `Scripts/make-icon.swift` 生成，不包含 SF Symbols 素材。窗口和 Finder 扩展菜单中的功能图标使用系统 `doc.zipper`。动态名称由 [Finder Sync 菜单接口](https://developer.apple.com/documentation/findersync/fifindersyncprotocol/menu(for:)) 根据当前选区生成；窗口标题也显示 `干净压缩“项目名称”`。

Finder 管理扩展菜单在主菜单中的插入位置。公开接口不支持指定“放在系统压缩命令下面”；当前入口显示在系统安排的扩展区域。备用 Services 菜单仍使用固定文字，无法带入文件名。

## 过滤范围

| 内容 | 处理 |
| --- | --- |
| macOS 资源分叉、Finder 信息、扩展属性、ACL、隔离标记 | 不写入 ZIP |
| `.DS_Store`、名称以 `._` 开头的项目、`__MACOSX` 目录 | 递归过滤 |
| `.gitignore`、`.env` 等其他隐藏文件 | 保留 |
| 中文、空格、特殊字符文件名、空文件夹 | 保留 |
| 符号链接 | 保存链接本身，不跟随目标 |
| 普通文件执行权限和修改时间 | 保留 |

保留标准 ZIP 文件属性和目录结构。“干净”指去除 macOS 附加元数据，不是删除文件内嵌的 EXIF、Office 作者等信息。以资源分叉存储内容的旧式 Mac 文件、依赖扩展属性或 ACL 的内容，不适合用此格式备份。

## 命名与失败处理

- 一个项目：`项目原名.zip`；多个项目：`归档.zip`。
- 重名依次编号 `名称 2.zip`、`名称 3.zip`，原子保存，不覆盖现有文件或符号链接。
- 同时选择父文件夹和其内部文件时只打包一次。
- 不同目录的同名项目会在 ZIP 中添加 ` (2)` 等后缀，避免丢失内容。
- 失败和取消时删除临时数据，不留下半成品 ZIP。单个大文件准备过程中，取消会在当前复制操作返回后生效。
- 不压缩设备、管道、套接字等特殊文件；遇到错误会中止整个任务并提示。

## 本地开发

要求 macOS 13+、Xcode Command Line Tools 与 Python 3（用于测试）。构建产物的架构与构建机器一致，当前尚未提供通用二进制安装包。

```sh
bash Scripts/build.sh
open build/ClearZip.app
bash Scripts/test.sh
bash Scripts/package-dmg.sh
```

重新生成原创 App 图标（16–1024 像素的完整尺寸集）：

```sh
mkdir -p build/icon-generation
xcrun swift -module-cache-path build/module-cache Scripts/make-icon.swift build/icon-generation/AppIcon.iconset
iconutil -c icns build/icon-generation/AppIcon.iconset -o Resources/AppIcon.icns
```

命令行复用相同归档逻辑：

```sh
build/ClearZip.app/Contents/MacOS/ClearZip --compress -- /path/to/folder /path/to/file
build/ClearZip.app/Contents/MacOS/ClearZip --compress --output-directory /path/to/output -- /path/to/file
```

输出目录不能位于要压缩的目录内部。准备目录创建在输出位置，优先通过 APFS 克隆文件；不支持克隆时系统回退到复制，因此需要额外临时空间。压缩期间请避免修改源文件；本工具不提供整个目录的事务快照。

## 实现

AppKit 窗口和 Services 接收文件 URL。归档引擎逐项筛选，通过目录描述符和 `openat(O_NOFOLLOW)` 读取源内容，并用 `fstatat` / `fstat` 校验文件身份，避免目录被替换后跟随到选区外；检测到替换会中止并清理临时内容。在私有临时目录准备内容后，调用系统 `/usr/bin/ditto -c -k --norsrc --noextattr --noacl --noqtn`。按 [ZIP 格式规范](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) 补齐本地和中央目录的 UTF-8 文件名标记，兼容 ZIP64。最后用 `renamex_np(RENAME_EXCL)` 原子发布。任务结束统一清理临时目录。

构建脚本使用本地 ad hoc 签名。`package-dmg.sh` 生成包含应用、Applications 快捷入口和安装说明的只读压缩 DMG，并校验映像。应用尚未通过 Apple 公证，未使用 Developer ID 证书；macOS 可能阻止首次打开。确认来源后，按 [Apple 官方说明](https://support.apple.com/zh-cn/102445) 在“系统设置 → 隐私与安全性”中为该应用选择“仍要打开”。

## 目录结构

| 目录 | 内容 |
| --- | --- |
| `Sources/ClearZip` | 应用窗口、后台任务和归档引擎 |
| `Sources/ClearZipFinder` | Finder 扩展与动态右键菜单 |
| `Sources/ClearZipWorker` | 领取私有任务并执行后台压缩 |
| `Sources/Shared` | 应用与扩展共享的压缩请求协议 |
| `Resources` | Info.plist、扩展权限、图标和安装说明 |
| `Scripts` | 构建、测试和 DMG 打包 |
| `Tests` | ZIP 内容、取消、ZIP64 和请求协议回归检查 |

## 版本管理与分发

源码、资源、测试和构建脚本进入 Git。`build/` 下的 app、DMG、ZIP 及测试产物不提交；后续安装包通过 GitHub Releases 分发。

GitHub Actions 在推送 `main` 或发起 PR 后自动构建、测试和生成 DMG，临时构建产物保留 7 天；首次云端构建已通过。

推送 `v1.0.0` 这样的版本标签会运行独立的 `Release DMG` 工作流。也可在 Actions → Release DMG → Run workflow 中选择分支并填写版本标签。测试通过后，自动创建包含 DMG 和 SHA-256 校验值的 Release，更新说明来自 CHANGELOG；不会覆盖已有 Release。手动运行会在本次构建的准确提交上创建缺失的标签，已有标签必须指向相同提交。

构建已成功、只有发布任务失败时，可选择 **Re-run failed jobs**，发布任务会按构建任务返回的产物 ID 下载原安装包，不受重跑次数变化影响。构建产物保留 7 天；若已过期、被删除或缺少 ID，请选择 **Re-run all jobs** 重新构建。已有 Release 仍不会被覆盖。

发布前需要让两个 Info.plist 的 `CFBundleShortVersionString`、CHANGELOG 中的版本标题与标签一致，递增两个 `CFBundleVersion`，并填写更新记录。构建任务只有读取权限，独立发布任务具有创建 Release 所需的 `contents: write` 权限；不需要配置个人访问令牌。当前不执行 Developer ID 签名或 Apple 公证。

版本变化见 [CHANGELOG](CHANGELOG.md)，开发说明见 [CONTRIBUTING](CONTRIBUTING.md)。项目代码和原创 App 图标采用 [MIT 许可证](LICENSE)，应用与 DMG 随附许可声明。运行时调用的系统 SF Symbols 属于 Apple 系统资源，按其使用条款提供。
