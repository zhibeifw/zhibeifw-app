# 设计令牌和图标

| 文件 | 内容 |
|---|---|
| `design-tokens.json` | 设计令牌：颜色、字号、间距、圆角、尺寸、动画参数。两端界面只用这里的数值，改了以后运行 `python3 tools/gen_design.py` 生成两端的常量文件 |
| `icons.json`、`icon-map.json`、`icons-material/` | 图标：自绘图标的矢量路径；图标名到 iOS SF Symbols、Android Material Symbols 的对照；Android 用的 Material Symbols SVG |
