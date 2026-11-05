#!/usr/bin/env python3
"""从 doc/design-tokens.json 和 doc/icons.json 生成两端的常量文件。

    python3 tools/gen_design.py

生成（图标另读 doc/icon-map.json 与 icons-material/）：
  ios/Shared/Design/Generated/Tokens.swift、Icons.swift
  android/app/src/main/java/com/zhibeifw/app/design/generated/Tokens.kt、Icons.kt
生成的文件不要手改；改数值只改 JSON，再运行本脚本。只用 Python 标准库。
"""
import json
import math
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC = os.path.join(ROOT, 'doc')
IOS_OUT = os.path.join(ROOT, 'ios', 'Shared', 'Design', 'Generated')
AND_OUT = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'java', 'com', 'zhibeifw', 'app', 'design', 'generated')
HEADER = '自动生成，不要手改。来源：doc/{src}，生成脚本：tools/gen_design.py'


def cap(s):
    return s[0].upper() + s[1:]


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def num(v):
    if isinstance(v, int) or float(v).is_integer():
        return str(int(v))
    return repr(float(v))


def hex_rgba(s):
    """#RRGGBB 或 #RRGGBBAA → (r, g, b, a) 0–255。"""
    m = re.fullmatch(r'#([0-9A-Fa-f]{6})([0-9A-Fa-f]{2})?', s)
    if not m:
        raise ValueError('颜色格式不对：' + s)
    rgb = int(m.group(1), 16)
    a = int(m.group(2), 16) if m.group(2) else 255
    return (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255, a


def argb(s):
    r, g, b, a = hex_rgba(s)
    return '0x%02X%02X%02X%02X' % (a, r, g, b)


def is_hex_color(v):
    """单个颜色（深浅模式同一个）。"""
    return isinstance(v, str) and re.fullmatch(r'#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?', v) is not None


def is_color_pair(v):
    return isinstance(v, dict) and isinstance(v.get('light'), str) and isinstance(v.get('dark'), str) and v['light'].startswith('#')


# ---------------- 令牌 ----------------

def swift_group(name, obj, ind):
    out = []
    pad = '    ' * ind
    out.append(f'{pad}enum {cap(name)} {{')
    for k, v in obj.items():
        if k.startswith('_'):
            continue
        p2 = '    ' * (ind + 1)
        if isinstance(v, bool):
            out.append(f'{p2}static let {k} = {"true" if v else "false"}')
        elif is_color_pair(v):
            out.append(f'{p2}static let {k} = ZColor(light: {argb(v["light"])}, dark: {argb(v["dark"])})')
        elif is_num(v):
            out.append(f'{p2}static let {k}: CGFloat = {num(v)}')
        elif is_hex_color(v):
            out.append(f'{p2}static let {k} = ZColor(both: {argb(v)})')
        elif isinstance(v, str):
            out.append(f'{p2}static let {k} = {json.dumps(v, ensure_ascii=False)}')
        elif isinstance(v, list) and all(is_num(x) for x in v):
            out.append(f'{p2}static let {k}: [CGFloat] = [{", ".join(num(x) for x in v)}]')
        elif isinstance(v, list) and all(isinstance(x, str) and x.startswith('#') for x in v):
            out.append(f'{p2}static let {k}: [ZColor] = [{", ".join(f"ZColor(both: {argb(x)})" for x in v)}]')
        elif isinstance(v, list) and all(isinstance(x, str) for x in v):
            out.append(f'{p2}static let {k}: [String] = [{", ".join(json.dumps(x, ensure_ascii=False) for x in v)}]')
        elif isinstance(v, dict) and 'size' in v and 'weight' in v and 'lineHeight' in v and 'weightSelected' not in v:
            out.append(f'{p2}static let {k} = ZTextStyle(size: {num(v["size"])}, weight: {num(v["weight"])}, lineHeight: {num(v["lineHeight"])})')
        elif isinstance(v, dict):
            out.extend(swift_group(k, v, ind + 1))
        else:
            raise ValueError(f'不认识的令牌：{name}.{k}')
    out.append(f'{pad}}}')
    return out


def kotlin_group(name, obj, ind):
    out = []
    pad = '    ' * ind
    out.append(f'{pad}object {cap(name)} {{')
    for k, v in obj.items():
        if k.startswith('_'):
            continue
        p2 = '    ' * (ind + 1)
        if isinstance(v, bool):
            out.append(f'{p2}const val {k}: Boolean = {"true" if v else "false"}')
        elif is_color_pair(v):
            out.append(f'{p2}val {k} = ZColor(light = {argb(v["light"])}, dark = {argb(v["dark"])})')
        elif is_num(v):
            out.append(f'{p2}const val {k}: Float = {num(v)}f')
        elif is_hex_color(v):
            out.append(f'{p2}val {k} = ZColor.both({argb(v)})')
        elif isinstance(v, str):
            out.append(f'{p2}const val {k}: String = {json.dumps(v, ensure_ascii=False)}')
        elif isinstance(v, list) and all(is_num(x) for x in v):
            out.append(f'{p2}val {k}: List<Float> = listOf({", ".join(num(x) + "f" for x in v)})')
        elif isinstance(v, list) and all(isinstance(x, str) and x.startswith('#') for x in v):
            out.append(f'{p2}val {k}: List<ZColor> = listOf({", ".join(f"ZColor.both({argb(x)})" for x in v)})')
        elif isinstance(v, list) and all(isinstance(x, str) for x in v):
            out.append(f'{p2}val {k}: List<String> = listOf({", ".join(json.dumps(x, ensure_ascii=False) for x in v)})')
        elif isinstance(v, dict) and 'size' in v and 'weight' in v and 'lineHeight' in v and 'weightSelected' not in v:
            out.append(f'{p2}val {k} = ZTextStyle(size = {num(v["size"])}f, weight = {num(v["weight"])}, lineHeight = {num(v["lineHeight"])}f)')
        elif isinstance(v, dict):
            out.extend(kotlin_group(k, v, ind + 1))
        else:
            raise ValueError(f'不认识的令牌：{name}.{k}')
    out.append(f'{pad}}}')
    return out


def gen_tokens(tokens):
    body = {k: v for k, v in tokens.items() if not k.startswith('_')}
    sw = [f'// {HEADER.format(src="design-tokens.json")}', 'import CoreGraphics', '', '// swiftlint:disable all']
    sw += swift_group('Tok', body, 0)
    kt = [f'// {HEADER.format(src="design-tokens.json")}', 'package com.zhibeifw.app.design.generated', '',
          'import com.zhibeifw.app.design.ZColor', 'import com.zhibeifw.app.design.ZTextStyle', '']
    kt += kotlin_group('Tok', body, 0)
    return '\n'.join(sw) + '\n', '\n'.join(kt) + '\n'


# ---------------- 图标：SVG 路径 → 绝对坐标的 M/L/C/Z ----------------

TOKEN_RE = re.compile(r'[MmLlHhVvCcSsQqTtAaZz]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?')


def arc_to_cubics(x1, y1, rx, ry, phi, large, sweep, x2, y2):
    """SVG 椭圆弧转三次贝塞尔（W3C SVG 附录 F.6 的中心参数化）。"""
    if (x1, y1) == (x2, y2):
        return []
    if rx == 0 or ry == 0:
        return [(x1, y1, x2, y2, x2, y2)]
    rx, ry = abs(rx), abs(ry)
    cphi, sphi = math.cos(math.radians(phi)), math.sin(math.radians(phi))
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p = cphi * dx + sphi * dy
    y1p = -sphi * dx + cphi * dy
    lam = (x1p ** 2) / (rx ** 2) + (y1p ** 2) / (ry ** 2)
    if lam > 1:
        s = math.sqrt(lam)
        rx, ry = rx * s, ry * s
    num_ = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    coef = math.sqrt(max(0.0, num_ / den)) if den else 0.0
    if large == sweep:
        coef = -coef
    cxp = coef * rx * y1p / ry
    cyp = -coef * ry * x1p / rx
    cx = cphi * cxp - sphi * cyp + (x1 + x2) / 2
    cy = sphi * cxp + cphi * cyp + (y1 + y2) / 2

    def ang(ux, uy, vx, vy):
        a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a

    t1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dt = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dt > 0:
        dt -= 2 * math.pi
    elif sweep and dt < 0:
        dt += 2 * math.pi
    n = max(1, int(math.ceil(abs(dt) / (math.pi / 2) - 1e-9)))
    d = dt / n
    k = 4 / 3 * math.tan(d / 4)
    out = []
    t = t1
    for _ in range(n):
        c1, s1 = math.cos(t), math.sin(t)
        c2, s2 = math.cos(t + d), math.sin(t + d)
        p1 = (c1 - k * s1, s1 + k * c1)
        p2 = (c2 + k * s2, s2 - k * c2)
        p3 = (c2, s2)

        def tr(p):
            return (cx + rx * cphi * p[0] - ry * sphi * p[1], cy + rx * sphi * p[0] + ry * cphi * p[1])
        a, b, c = tr(p1), tr(p2), tr(p3)
        out.append((a[0], a[1], b[0], b[1], c[0], c[1]))
        t += d
    return out


def parse_path(d):
    toks = TOKEN_RE.findall(d)
    i = 0
    ops = []
    cx = cy = sx = sy = 0.0
    last_ctrl = None
    last_q = None  # 上一个二次曲线的控制点（T 命令要用它的对称点）
    cmd = None

    def nums(n):
        nonlocal i
        vals = [float(x) for x in toks[i:i + n]]
        if len(vals) != n:
            raise ValueError('路径参数不够：' + d)
        i += n
        return vals

    while i < len(toks):
        if re.fullmatch(r'[A-Za-z]', toks[i]):
            cmd = toks[i]
            i += 1
        elif cmd is None:
            raise ValueError('路径要以命令开头：' + d)
        rel = cmd.islower()
        c = cmd.upper()
        ox, oy = (cx, cy) if rel else (0.0, 0.0)
        if c == 'M':
            x, y = nums(2)
            cx, cy = x + ox, y + oy
            sx, sy = cx, cy
            ops.append(('M', cx, cy))
            cmd = 'l' if rel else 'L'
            last_ctrl = None
        elif c == 'L':
            x, y = nums(2)
            cx, cy = x + ox, y + oy
            ops.append(('L', cx, cy))
            last_ctrl = None
        elif c == 'H':
            (x,) = nums(1)
            cx = x + ox
            ops.append(('L', cx, cy))
            last_ctrl = None
        elif c == 'V':
            (y,) = nums(1)
            cy = y + (cy if rel else 0.0)
            ops.append(('L', cx, cy))
            last_ctrl = None
        elif c == 'C':
            a = nums(6)
            x1, y1, x2, y2, x, y = a[0] + ox, a[1] + oy, a[2] + ox, a[3] + oy, a[4] + ox, a[5] + oy
            ops.append(('C', x1, y1, x2, y2, x, y))
            cx, cy = x, y
            last_ctrl = (x2, y2)
        elif c == 'S':
            a = nums(4)
            x1, y1 = (2 * cx - last_ctrl[0], 2 * cy - last_ctrl[1]) if last_ctrl else (cx, cy)
            x2, y2, x, y = a[0] + ox, a[1] + oy, a[2] + ox, a[3] + oy
            ops.append(('C', x1, y1, x2, y2, x, y))
            cx, cy = x, y
            last_ctrl = (x2, y2)
        elif c in ('Q', 'T'):
            if c == 'Q':
                a = nums(4)
                qx, qy, x, y = a[0] + ox, a[1] + oy, a[2] + ox, a[3] + oy
            else:
                a = nums(2)
                qx, qy = (2 * cx - last_q[0], 2 * cy - last_q[1]) if last_q else (cx, cy)
                x, y = a[0] + ox, a[1] + oy
            ops.append(('C', cx + 2 / 3 * (qx - cx), cy + 2 / 3 * (qy - cy), x + 2 / 3 * (qx - x), y + 2 / 3 * (qy - y), x, y))
            cx, cy = x, y
            last_ctrl = None
            last_q = (qx, qy)
            continue
        elif c == 'A':
            rx, ry, phi, large, sweep, x, y = nums(7)
            x, y = x + ox, y + oy
            for seg in arc_to_cubics(cx, cy, rx, ry, phi, int(large), int(sweep), x, y):
                ops.append(('C',) + seg)
            cx, cy = x, y
            last_ctrl = None
        elif c == 'Z':
            ops.append(('Z',))
            cx, cy = sx, sy
            last_ctrl = None
        else:
            raise ValueError('不支持的路径命令：' + cmd)
        last_q = None
    return ops


def flat(ops):
    """编码：0 x y＝移到；1 x y＝直线；2 x1 y1 x2 y2 x y＝三次曲线；3＝闭合。"""
    out = []
    for op in ops:
        code = {'M': 0, 'L': 1, 'C': 2, 'Z': 3}[op[0]]
        out.append(code)
        out.extend(round(v, 3) for v in op[1:])
    return out


def fnum(v):
    s = ('%.3f' % v).rstrip('0').rstrip('.')
    return s if s not in ('-0', '') else '0'


def material_elements(icon_map):
    """Android 用的 Google Material Symbols：doc/icons-material/ 里的 SVG（viewBox 0 -960 960 960）缩放到 24 网格，实心填充。"""
    out = {}
    for name, v in icon_map['icons'].items():
        fn = f"{v['material']}{'_fill1' if v['fill'] else ''}_24px.svg"
        svg = open(os.path.join(DOC, 'icons-material', fn), encoding='utf-8').read()
        d = re.search(r'<path[^>]* d="([^"]+)"', svg).group(1)
        out[name] = [{'fill': True, 'material': d}]
    return out


def scale_material(ops):
    """Material Symbols 坐标（x 0..960，y -960..0）→ 24 网格。"""
    k = 24 / 960
    res = []
    for op in ops:
        kind, pts = op[0], op[1:]
        res.append((kind,) + tuple(p * k if i % 2 == 0 else (p + 960) * k for i, p in enumerate(pts)))
    return res


def gen_icons(icons, icon_map=None):
    default_w = icons.get('defaultStroke', 1.6)
    # 只在系统图标对照表里有、自绘数据里没有的名字（如“stop”），Android 也照样生成
    names = sorted(set(icons['icons'].keys()) | set((icon_map or {}).get('icons', {}).keys()))
    sw = [f'// {HEADER.format(src="icons.json")}', 'import CoreGraphics', '', '// swiftlint:disable all',
          'enum IconData {', '    static let all: [String: [IconElement]] = [']
    kt = [f'// {HEADER.format(src="icons.json")}', 'package com.zhibeifw.app.design.generated', '',
          'import com.zhibeifw.app.design.IconElement', '', 'object IconData {', '    val names: List<String> = listOf(' +
          ', '.join(json.dumps(n) for n in names) + ')', '',
          '    // 每个图标一个函数，避免一个超大的方法（JVM 方法体有 64KB 上限）',
          '    fun get(name: String): List<IconElement>? = when (name) {']
    kt_funcs = []
    material = material_elements(icon_map) if icon_map else {}
    for n in names:
        els = icons['icons'].get(n, [])
        sw_els = []
        kt_els = []
        for e in els:
            data = flat(parse_path(e['d']))
            fill = 'true' if e.get('fill') else 'false'
            eo = 'true' if e.get('evenOdd') else 'false'
            w = e.get('w', default_w)
            arr = ', '.join(fnum(v) for v in data)
            sw_els.append(f'IconElement(fill: {fill}, evenOdd: {eo}, width: {fnum(w)}, ops: [{arr}])')
            if n not in material:
                kt_els.append(f'IconElement(fill = {fill}, evenOdd = {eo}, width = {fnum(w)}f, ops = floatArrayOf({", ".join(fnum(v) + "f" for v in data)}))')
        # Android：有 Material Symbols 的用它（Google 系统图标风格，实心填充、非零环绕）
        for e in material.get(n, []):
            data = flat(scale_material(parse_path(e['material'])))
            kt_els.append(f'IconElement(fill = true, evenOdd = false, width = 0f, ops = floatArrayOf({", ".join(fnum(v) + "f" for v in data)}))')
        sw.append(f'        "{n}": [' + ', '.join(sw_els) + '],')
        fn = 'i_' + re.sub(r'[^a-zA-Z0-9]', '_', n)
        kt.append(f'        "{n}" -> {fn}()')
        kt_funcs.append(f'    private fun {fn}() = listOf(' + ', '.join(kt_els) + ')')
    sw += ['    ]', '}']
    kt += ['        else -> null', '    }', ''] + kt_funcs + ['}']
    return '\n'.join(sw) + '\n', '\n'.join(kt) + '\n'


def main():
    tokens = json.load(open(os.path.join(DOC, 'design-tokens.json'), encoding='utf-8'))
    icons = json.load(open(os.path.join(DOC, 'icons.json'), encoding='utf-8'))
    os.makedirs(IOS_OUT, exist_ok=True)
    os.makedirs(AND_OUT, exist_ok=True)
    sw, kt = gen_tokens(tokens)
    open(os.path.join(IOS_OUT, 'Tokens.swift'), 'w', encoding='utf-8').write(sw)
    open(os.path.join(AND_OUT, 'Tokens.kt'), 'w', encoding='utf-8').write(kt)
    icon_map = json.load(open(os.path.join(DOC, 'icon-map.json'), encoding='utf-8'))
    sw, kt = gen_icons(icons, icon_map)
    # iOS：图标名 → 苹果系统图标（SF Symbols）
    sw += '\n/// 图标名 → SF Symbols（来源：doc/icon-map.json）。\nenum SymbolName {\n    static let all: [String: String] = [\n'
    sw += ''.join(f'        "{k}": "{v["sf"]}",\n' for k, v in sorted(icon_map['icons'].items()))
    sw += '    ]\n}\n'
    open(os.path.join(IOS_OUT, 'Icons.swift'), 'w', encoding='utf-8').write(sw)
    open(os.path.join(AND_OUT, 'Icons.kt'), 'w', encoding='utf-8').write(kt)
    print('已生成：', IOS_OUT, AND_OUT, sep='\n  ')


if __name__ == '__main__':
    sys.exit(main())
