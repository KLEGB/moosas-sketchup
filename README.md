# moosas-sketchup

`moosas-sketchup` 是面向公开分发的被动式构建仓库。它不提供常规的开发者安装流程；发布时由 `setup/toSketchUp.nsi` 编译出的 `moosas-sketchup-builder.exe` 在本仓库根目录自动准备构建环境，并生成 SketchUp 扩展包（RBZ）。

## 构建方式

将发布的构建器放在仓库根目录并运行。构建器会执行以下工作：

1. 解压其随附的构建引导文件；
2. 下载隔离的 Python 3.11 运行时，并安装构建所需依赖；
3. 读取仓库中的 `MoosasPy` 与 `skp` 源码，组装 SketchUp 插件目录；
4. 校验运行时并输出 `dist/moosas-sketchup.rbz`。

临时文件、下载内容和构建日志位于 `dist/.build`；构建成功后临时目录会自动清理。若构建失败，请查看 `dist/.build/logs/build.log`。

## 仓库约定

- `setup/toSketchUp.nsi`：NSIS 构建器定义，编译后得到自动化 RBZ 构建器。
- `setup/build_rbz.py`：构建器实际执行的打包脚本。
- `skp/`：SketchUp Ruby 侧代码。
- `MoosasPy/`：随 RBZ 一同打包的 Python 代码（如存在于发布源码中）。
- `dist/moosas-sketchup.rbz`：构建产物，不作为源码维护入口。

此仓库以自动化发布构建为中心。需要 RBZ 时，请使用由 `toSketchUp.nsi` 编译的 EXE，而不是手工拼装插件目录。

## 许可证

本项目采用 [MIT License](LICENSE)。
