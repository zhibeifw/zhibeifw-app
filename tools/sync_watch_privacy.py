# 使用：python3 tools/sync_watch_privacy.py ../zhibeifw-web/privacy.html
from html.parser import HTMLParser
from pathlib import Path
import sys

class Policy(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.depth = 0
        self.tag = None
        self.text = []
        self.blocks = []
    def handle_starttag(self, tag, attrs):
        if tag == 'div':
            if dict(attrs).get('id') == 'zh' or self.depth:
                self.depth += 1
        if self.depth and (tag in ('h1','h2','p','li') or (tag == 'div' and dict(attrs).get('class') == 'subtitle')):
            self.tag = tag
            self.text = []
    def handle_data(self, data):
        if self.depth and self.tag:
            self.text.append(data)
    def handle_endtag(self, tag):
        if self.depth and tag == self.tag:
            text = ''.join(self.text).strip()
            if tag == 'li': text = '• ' + text
            if text: self.blocks.append(text)
            self.tag = None
        if tag == 'div' and self.depth: self.depth -= 1

def parse(text):
    p = Policy(); p.feed(text); return p.blocks
source = Path(sys.argv[1])
blocks = parse(source.read_text())
assert len([s for s in blocks if '、 ' in s and len(s) < 30]) == 10, '缺少完整隐私政策章节'
body = '\n\n'.join(blocks)
output = Path('ios/ZhibeiFWWatch/WatchPrivacyPolicy.swift')
output.write_text('// 由 tools/sync_watch_privacy.py 从官网隐私政策生成，勿手改。\nimport Foundation\n\nenum WatchPrivacyPolicy {\n    static let text = """\n'+''.join(('        '+line if line else '')+'\n' for line in body.splitlines())+'        """\n}\n')
print(f'内置{len(blocks)}个段落，含全部10节，{len(body)}字。')
