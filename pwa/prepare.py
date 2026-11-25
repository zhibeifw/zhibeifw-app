"""生成网页设计常量及官方 Material 图标，不下载课程或音频。"""
from pathlib import Path
import hashlib,json,shutil,re
root=Path(__file__).resolve().parent.parent
out=root/'pwa/assets';out.mkdir(exist_ok=True)
t=json.loads((root/'doc/design-tokens.json').read_text());icons=json.loads((root/'doc/icon-map.json').read_text())['icons']
css='/* 自动生成：doc/design-tokens.json */\n'
for theme in ['light','dark']:
 rules=':root{' if theme=='light' else '@media(prefers-color-scheme:dark){:root{'
 for k,v in t['color'].items():
  if isinstance(v,dict) and theme in v:rules+=f'--{k}:{v[theme]};'
 css+=rules+'}'+('}' if theme=='dark' else '')+'\n'
(out/'theme.css').write_text(css)
(out/'design.mjs').write_text('export const palette='+json.dumps(t['contentPalette'])+';\nexport const icons='+json.dumps(icons)+';\n')
for p in (root/'doc/icons-material').glob('*.svg'):shutil.copyfile(p,out/p.name)

style=(root/'pwa/style.template.css').read_text()
base_px = float(t['_pwa']['dimensions']['size17px'].removesuffix('px'))
style = style.replace('{{baseFontPercent}}', f'{base_px / 16 * 100:g}%')
for key,value in t['_pwa']['dimensions'].items():style=style.replace('{{'+key+'}}',value)
style=style.replace('{{accent}}',t['_pwa']['accent'])
(root/'pwa/style.css').write_text('/* 自动生成：style.template.css 与 doc/design-tokens.json */\n'+style)

version=(root/'Version.xcconfig').read_text()
marketing=re.search(r'^MARKETING_VERSION = (.+)$',version,re.M).group(1)
build=re.search(r'^CURRENT_PROJECT_VERSION = (.+)$',version,re.M).group(1)
(out/'version.mjs').write_text('export const version='+json.dumps(marketing)+';\nexport const build='+json.dumps(build)+';\n')

# 安装时一次备齐所有页面的图标，安装用 PNG 在浏览器需要时单独缓存。
pwa = root / 'pwa'
files = ['index.html', 'manifest.webmanifest', 'style.css']
files += sorted(p.name for p in pwa.glob('*.mjs'))
files += sorted(str(p.relative_to(pwa)) for p in out.iterdir() if p.suffix in {'.css', '.svg', '.mjs'})
template = (pwa / 'sw.template.js').read_text()
digest = hashlib.sha256(template.encode())
for name in files + sorted(str(p.relative_to(pwa)) for p in out.glob('*.png')):
    digest.update(name.encode())
    digest.update((pwa / name).read_bytes())
worker = template.replace('{{files}}', json.dumps(files, indent=2)).replace('{{revision}}', digest.hexdigest()[:16])
(pwa / 'sw.js').write_text('// 自动生成：sw.template.js 与界面资源\n' + worker)
