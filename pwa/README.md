# 智悲佛网 PWA

原生 HTML、CSS、JavaScript 模块，不依赖框架或第三方运行库。在线课程数据、封面、音频沿用 App 的公开服务。没有账号、统计或音频下载。

## 本地运行

在仓库根目录执行：

```sh
python3 pwa/build.py
python3 -m http.server 4173 --bind 127.0.0.1 --directory pwa/dist
```

打开 http://127.0.0.1:4173 。Service Worker 需要 localhost 或 HTTPS；手机不能通过普通局域网 HTTP 验证安装功能。

## 测试与打包

```sh
python3 pwa/build.py
node --test pwa/tests/*.test.mjs
```

输出 `pwa/dist/`，可作为静态站点部署到 Cloudflare Pages 或其他 HTTPS 托管。所有资源使用相对路径，支持部署在子目录。无服务器代理、无密钥。发布前按项目流程递增根目录构建号；页面版本由 `Version.xcconfig` 生成。没有自动提交、上传或部署步骤。

`prepare.py` 从共用设计令牌及官方 Material 图标生成网页资源。样式改 `style.template.css`，尺寸和配色改 `doc/design-tokens.json` 中 `_pwa`，然后重新生成。Logo 与 App 图标随 `pwa/assets` 提供。Material SVG 来自 `doc/icons-material`，许可证和来源见根目录 NOTICE。
