# 开发与贡献

项目采用 [MIT 许可证](LICENSE)，使用 GitHub 管理代码和发布版本。

## 环境与验证

使用 macOS 13+、Xcode Command Line Tools 和 Python 3。无需安装第三方运行时依赖。

```sh
bash Scripts/build.sh
bash Scripts/test.sh
bash Scripts/package-dmg.sh
```

构建输出位于 `build/`，架构与构建机器一致。请不要将 app、DMG、ZIP、模块缓存、测试产物或签名证书提交到源码仓库。

归档逻辑变更需要覆盖实际 ZIP 内容与原文件保持不变的检查；Finder 或启动流程变更还需要手动验证：

- 应用未打开时，右键压缩不弹主窗口。
- 应用已打开时，后台任务不修改手动窗口状态。
- 手动打开应用仍可选择文件、拖入和取消任务。
- 失败提示与临时文件清理正常。

构建后，可在已解锁的桌面运行真实沙箱交接测试（不适用于无桌面的 CI）：

```sh
python3 Tests/InstalledFinderHandoffTests.py
```

该测试以 App Sandbox 权限运行生产交接代码，验证私有任务交接到后台程序后实际生成干净 ZIP。测试不替代上面的 Finder 菜单和窗口验收。

## 提交范围

每次提交围绕一个明确变更，提交说明解释结果与验证方式。排查问题时优先提供系统版本、处理器架构、操作步骤和不含私人内容的最小复现文件。

内部开发记录与本机验收截图保留在本地，不进入 Git。项目功能、限制和版本变化分别维护在 README 与 CHANGELOG 中。
