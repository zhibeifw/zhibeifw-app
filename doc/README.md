# 设计令牌和图标

| 文件 | 内容 |
|---|---|
| `design-tokens.json` | 设计令牌：颜色、字号、间距、圆角、尺寸、动画参数。两端界面只用这里的数值，改了以后运行 `python3 tools/gen_design.py` 生成两端的常量文件 |
| `icons.json`、`icon-map.json`、`icons-material/` | 图标：自绘图标的矢量路径；图标名到 iOS SF Symbols、Android Material Symbols 的对照；Android 用的 Material Symbols SVG |
| `test-vectors/*.json` | 两端单元测试共用的测试数据（版本比较、ID 与路径校验、线路域名、本机文件名、时间和文字处理）。两端测试都读这一份，加用例只改这里 |
