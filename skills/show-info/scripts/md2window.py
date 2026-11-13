"""show-info 渲染脚本：markdown -> HTML -> arowser 置顶浮窗。"""
import argparse
import html as html_mod
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import markdown2

ASSETS = Path(__file__).resolve().parents[1] / "assets"

ECharts_BLOCK_RE = re.compile(r"^```echarts[ \t\r]*\n(.*?)\n```[ \t\r]*$", re.MULTILINE | re.DOTALL)
IMAGE_RE = re.compile(r"!\[([^\]]*)\]\(([^)\s]+)\)")
NON_LOCAL_PREFIXES = ("http://", "https://", "data:")


def extract_echarts(md: str) -> tuple[str, list[dict]]:
    """提取 ```echarts 块为占位 div，返回 (替换后的 md, 按序 option 列表)。"""
    options: list[dict] = []

    def _sub(m: re.Match) -> str:
        try:
            opt = json.loads(m.group(1))
        except json.JSONDecodeError as e:
            raise ValueError(f"echarts 第 {len(options) + 1} 块 JSON 非法: {e}") from e
        options.append(opt)
        return f'<div class="echart" id="ec-{len(options)}"></div>'

    out = ECharts_BLOCK_RE.sub(_sub, md)
    return out, options


def echarts_init_html(options: list[dict]) -> str:
    """生成 echarts.min.js 引用与初始化脚本；`<` 转义防提前闭合 script 标签。"""
    payload = json.dumps(options, ensure_ascii=False).replace("<", "\\u003c").replace(">", "\\u003e")
    return (
        '<script src="echarts.min.js"></script>\n'
        "<script>\n"
        f"const EC_OPTS = {payload};\n"
        "EC_OPTS.forEach((o, i) => { echarts.init(document.getElementById('ec-' + (i + 1))).setOption(o); });\n"
        "window.addEventListener('resize', () => EC_OPTS.forEach((o, i) => { "
        "echarts.getInstanceByDom(document.getElementById('ec-' + (i + 1))).resize(); }));\n"
        "</script>"
    )


def collect_images(md: str, out_dir: Path) -> str:
    """把 md 引用的本地图片复制进 out_dir 并重写引用为文件名；非本地/不存在路径原样保留。"""
    counter = {"n": 1}

    def _sub(m: re.Match) -> str:
        alt, path = m.group(1), m.group(2)
        if path.startswith(NON_LOCAL_PREFIXES):
            return m.group(0)
        src = Path(path).expanduser()
        if not src.is_file():
            return m.group(0)
        target = src.name
        if (out_dir / target).exists():
            counter["n"] += 1
            target = f"img-{counter['n']}-{src.name}"
        shutil.copy2(src, out_dir / target)
        return f"![{alt}]({target})"

    return IMAGE_RE.sub(_sub, md)


def pick_title(md: str) -> str:
    """取首个 H1 文本作窗口标题，无则「结果」。"""
    for line in md.splitlines():
        s = line.strip()
        if s.startswith("# ") and s[1:].strip():
            return s[1:].strip()
    return "结果"


def build_meta_line(env: dict | None = None) -> str:
    """溯源行：<项目名> · <会话标识> · <MM-dd HH:mm>；无会话环境回退 no-session。"""
    env = os.environ if env is None else env
    try:
        root = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True
        ).stdout.strip()
    except OSError:
        root = ""
    project = Path(root).name if root else Path.cwd().name
    session = env.get("CLAUDE_CODE_SESSION_ID") or ""
    session_id = f"cc-{session[:8]}" if session else "no-session"
    return f"{project} · {session_id} · {datetime.now().strftime('%m-%d %H:%M')}"


def estimate_height(md: str, n_echarts: int) -> int:
    """按行数与图表数估窗口高，夹逼 [320, 1400]。"""
    raw = 170 + 26 * len(md.splitlines()) + 340 * n_echarts
    return max(320, min(1400, raw))


def build_html(md_text: str, title: str, meta: str, out_dir: Path, raw: bool = False) -> Path:
    """渲染 markdown 产出 out_dir/index.html（资源同目录相对引用），返回其路径。"""
    out_dir.mkdir(parents=True, exist_ok=True)
    options: list[dict] = []
    if raw:
        body = md_text
    else:
        md2, options = extract_echarts(md_text)
        md2 = collect_images(md2, out_dir)
        body = markdown2.markdown(md2, extras=("tables", "fenced-code-blocks", "strike"))
    echarts_html = echarts_init_html(options) if options else ""
    shutil.copy2(ASSETS / "style.css", out_dir / "style.css")
    if options:
        shutil.copy2(ASSETS / "echarts.min.js", out_dir / "echarts.min.js")
    index = out_dir / "index.html"
    index.write_text(
        f"""<!doctype html><html><head><meta charset="utf-8"><title>{html_mod.escape(title)}</title>
<link rel="stylesheet" href="style.css"></head><body>
<h1 class="page-title">{html_mod.escape(title)}</h1>
{body}
{echarts_html}
<div class="meta">{html_mod.escape(meta)}</div>
</body></html>"""
    )
    return index


def main(argv: list[str] | None = None) -> int:
    """CLI：md2window.py <file.md | -> [--title T] [--id ID] [--w N] [--h N] [--raw]。"""
    parser = argparse.ArgumentParser(description="markdown -> arowser 置顶展示窗")
    parser.add_argument("input", help="markdown 文件路径或 -（stdin）")
    parser.add_argument("--title", help="窗口标题，缺省取首个 H1 或「结果」")
    parser.add_argument("--id", help="窗口 id，缺省 info-<HHMMSS>（传入则复用更新）")
    parser.add_argument("--w", type=int, default=460)
    parser.add_argument("--h", type=int, help="窗口高，缺省按内容估算")
    parser.add_argument("--raw", action="store_true", help="输入已是完整 HTML，直通不渲染")
    args = parser.parse_args(argv)

    if args.input == "-":
        text = sys.stdin.read()
    else:
        text = Path(args.input).expanduser().read_text()
    title = args.title or pick_title(text)
    win_id = args.id or f"info-{datetime.now().strftime('%H%M%S')}"
    if args.h is None:
        _, opts = (extract_echarts(text) if not args.raw else ("", []))
        args.h = estimate_height(text, len(opts))

    out_dir = Path("/tmp/show-info") / win_id
    index = build_html(text, title, build_meta_line(), out_dir, raw=args.raw)
    try:
        proc = subprocess.run(
            [
                "arowser", "open", str(index),
                "--id", win_id, "--title", title,
                "--w", str(args.w), "--h", str(args.h),
            ],
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        print("arowser 不可用：先按 arowser skill 重建（build.sh），或 command -v arowser 检查 PATH", file=sys.stderr)
        return 127
    if proc.returncode == 0:
        print(proc.stdout.strip())
    else:
        print(proc.stderr.strip(), file=sys.stderr)
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
