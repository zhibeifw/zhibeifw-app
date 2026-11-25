"""把静态网页打包到 dist，无运行时依赖。"""
from pathlib import Path
import runpy,shutil
root=Path(__file__).resolve().parent
runpy.run_path(str(root/'prepare.py'))
dest=root/'dist';dest.mkdir(exist_ok=True)
for name in ['index.html','style.css','app.mjs','core.mjs','network.mjs','storage.mjs','sw.js','manifest.webmanifest','_headers']:
    shutil.copyfile(root/name,dest/name)
shutil.copytree(root/'assets',dest/'assets',dirs_exist_ok=True)
print(dest)
