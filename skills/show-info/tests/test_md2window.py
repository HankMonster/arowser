import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

from md2window import (
    build_html,
    build_meta_line,
    collect_images,
    echarts_init_html,
    estimate_height,
    extract_echarts,
    pick_title,
)


class ExtractEchartsTest(unittest.TestCase):
    def test_extracts_and_replaces_with_placeholders(self):
        md = "# t\n\n```echarts\n{\"xAxis\":{},\"yAxis\":{}}\n```\n\ntail"
        out, opts = extract_echarts(md)
        self.assertEqual(len(opts), 1)
        self.assertIn('<div class="echart" id="ec-1"></div>', out)
        self.assertNotIn("```echarts", out)

    def test_two_blocks_numbered_in_order(self):
        md = "```echarts\n{}\n```\n\ntext\n\n```echarts\n{\"a\":1}\n```"
        out, opts = extract_echarts(md)
        self.assertEqual(len(opts), 2)
        self.assertIn('id="ec-1"', out)
        self.assertIn('id="ec-2"', out)

    def test_no_blocks_returns_unchanged(self):
        md = "# plain\n\n```python\ncode\n```\n"
        out, opts = extract_echarts(md)
        self.assertEqual(opts, [])
        self.assertEqual(out, md)

    def test_invalid_json_raises_with_block_number(self):
        with self.assertRaises(ValueError) as ctx:
            extract_echarts("```echarts\nnot json\n```")
        self.assertIn("1", str(ctx.exception))

    def test_invalid_json_second_block_reports_two(self):
        md = "```echarts\n{}\n```\n\n```echarts\nnot json\n```"
        with self.assertRaises(ValueError) as ctx:
            extract_echarts(md)
        self.assertIn("2", str(ctx.exception))

    def test_crlf_block_extracted(self):
        md = "```echarts\r\n{}\r\n```"
        out, opts = extract_echarts(md)
        self.assertEqual(len(opts), 1)
        self.assertNotIn("```echarts", out)


class EchartsInitHtmlTest(unittest.TestCase):
    def test_contains_script_tag_and_options(self):
        html = echarts_init_html([{"series": [1]}])
        self.assertIn('<script src="echarts.min.js"></script>', html)
        self.assertIn('"series"', html)
        self.assertIn("setOption", html)

    def test_escapes_closing_script_tag_in_option(self):
        evil = [{"tooltip": {"formatter": "</script><script>alert(1)</script>"}}]
        html = echarts_init_html(evil)
        self.assertNotIn("</script><script>alert(1)</script>", html)
        self.assertIn("\\u003c/script\\u003e", html)


class CollectImagesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.out = self.tmp / "out"
        self.out.mkdir()
        (self.tmp / "a").mkdir()
        (self.tmp / "b").mkdir()
        (self.tmp / "a" / "pic.png").write_bytes(b"PNG-A")
        (self.tmp / "b" / "pic.png").write_bytes(b"PNG-B")

    def test_copies_local_image_and_rewrites_ref(self):
        md = f"![图]({self.tmp / 'a' / 'pic.png'})"
        out = collect_images(md, self.out)
        self.assertEqual(out, "![图](pic.png)")
        self.assertEqual((self.out / "pic.png").read_bytes(), b"PNG-A")

    def test_collect_images_same_basename(self):
        md = f"![一]({self.tmp / 'a' / 'pic.png'}) ![二]({self.tmp / 'b' / 'pic.png'})"
        out = collect_images(md, self.out)
        self.assertNotEqual(out, md)
        self.assertIn("pic.png", out)
        names = sorted(p.name for p in self.out.iterdir())
        self.assertEqual(len(names), 2)

    def test_collect_images_skips_nonlocal(self):
        md = "![网](https://x.com/a.png) ![数据](data:image/png;base64,AAAA) ![缺](/no/such.png)"
        out = collect_images(md, self.out)
        self.assertEqual(out, md)
        self.assertEqual(list(self.out.iterdir()), [])


class PickTitleTest(unittest.TestCase):
    def test_first_h1(self):
        self.assertEqual(pick_title("intro\n\n# 报表\n\nbody"), "报表")

    def test_default_when_no_h1(self):
        self.assertEqual(pick_title("no heading"), "结果")


class MetaLineTest(unittest.TestCase):
    def test_contains_project_and_time(self):
        line = build_meta_line()
        self.assertIn("·", line)

    def test_meta_line_session_fallback(self):
        env = os.environ.copy()
        env.pop("CLAUDE_CODE_SESSION_ID", None)
        self.assertIn("no-session", build_meta_line(env))


class EstimateHeightTest(unittest.TestCase):
    def test_estimate_height_bounds(self):
        self.assertEqual(estimate_height("x", 0), 320)
        self.assertEqual(estimate_height("\n" * 5000, 0), 1400)
        self.assertEqual(estimate_height("\n" * 100, 5), 1400)
        mid = estimate_height("\n" * 10, 0)
        self.assertTrue(320 <= mid <= 1400)


class BuildHtmlTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.out = self.tmp / "out"

    def test_full_render(self):
        md = "# 标题\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```echarts\n{}\n```\n"
        path = build_html(md, "标题", "proj · cc-abc · 11-11 12:00", self.out)
        html = path.read_text()
        self.assertEqual(path.name, "index.html")
        self.assertIn("<table>", html)
        self.assertIn('id="ec-1"', html)
        self.assertIn("echarts.min.js", html)
        self.assertIn("proj · cc-abc · 11-11 12:00", html)
        self.assertIn("style.css", html)
        for name in ("style.css", "echarts.min.js"):
            self.assertTrue((self.out / name).exists(), name)
        css = (self.out / "style.css").read_text(encoding="utf-8")
        self.assertIn(".echart", css)
        self.assertIn("height:320px", css)

    def test_sticky_page_title(self):
        md = "# 正文自己的标题\n\n内容"
        path = build_html(md, "窗口标题", "m", self.out)
        html = path.read_text(encoding="utf-8")
        self.assertIn('<h1 class="page-title">窗口标题</h1>', html)
        css = (self.out / "style.css").read_text(encoding="utf-8")
        self.assertIn(".page-title", css)
        self.assertIn("position:sticky", css)
        self.assertIn("z-index", css)  # 盖过 echarts canvas

    def test_no_echarts_skips_echarts_asset(self):
        path = build_html("# t\n\n正文", "t", "m", self.out)
        self.assertFalse((self.out / "echarts.min.js").exists())

    def test_raw_passthrough(self):
        path = build_html("<b>直接</b>", "t", "m", self.out, raw=True)
        self.assertIn("<b>直接</b>", path.read_text())

    def test_title_is_escaped(self):
        path = build_html("body", "<script>x</script>", "m", self.out)
        self.assertNotIn("<script>x</script>", path.read_text().split("<body>")[1].split("</h1>")[0])


class MainNoArowserTest(unittest.TestCase):
    def test_missing_arowser_clean_error(self):
        import io
        import tempfile as tf
        from unittest import mock

        import md2window

        tmp = Path(tf.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        md_file = tmp / "x.md"
        md_file.write_text("# t\n\n正文", encoding="utf-8")
        with mock.patch.object(md2window.subprocess, "run", side_effect=FileNotFoundError("arowser")):
            with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
                rc = md2window.main([str(md_file), "--title", "t"])
        self.assertEqual(rc, 127)
        self.assertIn("arowser", err.getvalue())
