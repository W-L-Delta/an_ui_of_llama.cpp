"""本地模型的工具执行器（照 DSH 的权限分级做的简化版）。

分级：
    off   关闭
    read  只读：list / read / glob / grep
    write 工作区写入：+ write / edit / delete（路径必须在工作区内）
    full  完全访问：+ shell 命令，且允许访问工作区外的路径

所有写操作与命令执行在对话程序里都会先弹审批框，用户点了才真正执行。
"""
from __future__ import annotations

import fnmatch
import html as html_mod
import ipaddress
import os
import re
import socket
import subprocess
import time
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path

LEVELS = {"off": 0, "read": 1, "write": 2, "full": 3}
CREATE_NO_WINDOW = 0x08000000

MAX_OUTPUT = 12000
MAX_READ_BYTES = 400_000
MAX_GREP_HITS = 200

# name, required level, approval, description, JSON schema
TOOLS = [
    {
        "name": "list",
        "level": "read",
        "approval": False,
        "desc": "列出目录里的文件和子目录（相对工作区）",
        "params": {
            "type": "object",
            "properties": {"path": {"type": "string", "description": "相对工作区的目录，默认 ."}},
        },
    },
    {
        "name": "read",
        "level": "read",
        "approval": False,
        "desc": "读取文本文件内容，可按行范围截取",
        "params": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "相对工作区的文件路径"},
                "offset": {"type": "integer", "description": "起始行，从 1 开始"},
                "limit": {"type": "integer", "description": "最多返回多少行，默认 400"},
            },
            "required": ["path"],
        },
    },
    {
        "name": "glob",
        "level": "read",
        "approval": False,
        "desc": "按通配符查找文件，例如 **/*.py",
        "params": {
            "type": "object",
            "properties": {"pattern": {"type": "string"}, "path": {"type": "string"}},
            "required": ["pattern"],
        },
    },
    {
        "name": "grep",
        "level": "read",
        "approval": False,
        "desc": "在文件内容里做正则搜索，返回命中的行",
        "params": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string"},
                "path": {"type": "string", "description": "搜索起点，默认工作区根"},
                "include": {"type": "string", "description": "文件名过滤，例如 *.py"},
            },
            "required": ["pattern"],
        },
    },
    {
        "name": "write",
        "level": "write",
        "approval": True,
        "desc": "写入或覆盖一个文件（需要批准）",
        "params": {
            "type": "object",
            "properties": {"path": {"type": "string"}, "content": {"type": "string"}},
            "required": ["path", "content"],
        },
    },
    {
        "name": "edit",
        "level": "write",
        "approval": True,
        "desc": "把文件里的一段文本替换成新文本（需要批准）",
        "params": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "old": {"type": "string", "description": "要替换的原文本，必须唯一匹配"},
                "new": {"type": "string"},
            },
            "required": ["path", "old", "new"],
        },
    },
    {
        "name": "delete",
        "level": "write",
        "approval": True,
        "desc": "删除一个文件（需要批准）",
        "params": {
            "type": "object",
            "properties": {"path": {"type": "string"}},
            "required": ["path"],
        },
    },
    {
        "name": "web_search",
        "level": "read",
        "approval": False,
        "web": True,
        "desc": "联网搜索（Bing），返回若干条标题+链接+摘要。中文查询请用空格分隔关键词、去掉年份和口语词，例如「北京 天气」；长句或不加空格容易搜不到",
        "params": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "搜索关键词"},
                "count": {"type": "integer", "description": "返回条数，默认 5，最多 8"},
            },
            "required": ["query"],
        },
    },
    {
        "name": "web_fetch",
        "level": "read",
        "approval": False,
        "web": True,
        "desc": "抓取一个网页并提取正文（纯文本）",
        "params": {
            "type": "object",
            "properties": {"url": {"type": "string", "description": "http/https 链接"}},
            "required": ["url"],
        },
    },
    {
        "name": "shell",
        "level": "full",
        "approval": True,
        "desc": "在本机执行一条 PowerShell 命令（需要批准）",
        "params": {
            "type": "object",
            "properties": {"command": {"type": "string"}},
            "required": ["command"],
        },
    },
]

BY_NAME = {t["name"]: t for t in TOOLS}

# 联网配置由 app.py 从 [web] 段注入
WEB = {
    "enabled": False,
    "engine": "bing",
    "fallback": "360",   # Bing 搜不到时用哪个兜底引擎（360 / none）
    "max_results": 5,      # 最终交给模型几条
    "scan_pages": 3,       # 扫描几页结果（每页 10 条）
    "fetch_pages": 2,      # 抓取前几条的正文
    "fetch_chars": 1600,   # 每条正文摘录上限
    "max_chars": 8000,
    "timeout": 15,
    "block_private": True,
}


def set_web_config(cfg: dict) -> None:
    WEB.update({k: v for k, v in (cfg or {}).items() if k in WEB})


def _tool_available(t: dict) -> bool:
    if t.get("web") and not WEB.get("enabled"):
        return False
    return True


def level_of(name: str) -> int:
    return LEVELS.get((name or "").strip().lower(), 0)


def tools_for(level: str) -> list[dict]:
    """当前等级下允许使用的工具（OpenAI tools 格式）。"""
    cur = level_of(level)
    out = []
    for t in TOOLS:
        if not _tool_available(t):
            continue
        if level_of(t["level"]) <= cur:
            out.append({
                "type": "function",
                "function": {
                    "name": t["name"],
                    "description": t["desc"],
                    "parameters": t["params"],
                },
            })
    return out


def catalog(level: str) -> list[dict]:
    cur = level_of(level)
    return [{
        "name": t["name"],
        "level": t["level"],
        "approval": t["approval"],
        "desc": t["desc"],
        "parameters": t["params"],
        "enabled": _tool_available(t) and level_of(t["level"]) <= cur,
    } for t in TOOLS]


def _inside(root: Path, target: Path) -> bool:
    try:
        target.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def _resolve(workspace: str, rel: str, level: str) -> Path:
    root = Path(workspace or ".").expanduser()
    raw = (rel or ".").strip().strip('"')
    p = Path(raw)
    target = p if p.is_absolute() else (root / raw)
    if level_of(level) < LEVELS["full"] and not _inside(root, target):
        raise PermissionError(f"路径越界：{raw} 不在工作区 {root} 内")
    return target


def _clip(text: str, limit: int = MAX_OUTPUT) -> str:
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n…（已截断，共 {len(text)} 字符）"


def run(name: str, args: dict, level: str, workspace: str) -> dict:
    meta = BY_NAME.get(name)
    if not meta:
        return {"ok": False, "error": f"未知工具：{name}"}
    if level_of(meta["level"]) > level_of(level):
        return {"ok": False, "error": f"权限不足：{name} 需要 {meta['level']} 级别，当前 {level}"}

    args = args or {}
    t0 = time.time()
    try:
        if name == "list":
            target = _resolve(workspace, args.get("path") or ".", level)
            if not target.is_dir():
                return {"ok": False, "error": f"不是目录：{target}"}
            lines = []
            for entry in sorted(target.iterdir(), key=lambda x: (x.is_file(), x.name.lower()))[:400]:
                if entry.is_dir():
                    lines.append(f"[dir]  {entry.name}/")
                else:
                    lines.append(f"[file] {entry.name}  ({entry.stat().st_size} B)")
            out = "\n".join(lines) or "（空目录）"

        elif name == "read":
            target = _resolve(workspace, args.get("path") or "", level)
            if not target.is_file():
                return {"ok": False, "error": f"文件不存在：{target}"}
            if target.stat().st_size > MAX_READ_BYTES:
                return {"ok": False, "error": f"文件太大（{target.stat().st_size} B），请用 grep 或分段读"}
            text = target.read_text(encoding="utf-8", errors="replace")
            offset = max(1, int(args.get("offset") or 1))
            limit = max(1, int(args.get("limit") or 400))
            rows = text.splitlines()
            chunk = rows[offset - 1: offset - 1 + limit]
            head = f"{target.name}（第 {offset}-{offset + len(chunk) - 1} 行，共 {len(rows)} 行）\n"
            out = head + "\n".join(f"{offset + i:>5}| {ln}" for i, ln in enumerate(chunk))

        elif name == "glob":
            root = _resolve(workspace, args.get("path") or ".", level)
            pattern = args.get("pattern") or "*"
            hits = [str(p.relative_to(root)).replace("\\", "/") for p in root.rglob(pattern) if p.is_file()]
            out = "\n".join(sorted(hits)[:400]) or "（没有匹配）"

        elif name == "grep":
            root = _resolve(workspace, args.get("path") or ".", level)
            pattern = args.get("pattern") or ""
            include = args.get("include") or "*"
            try:
                rx = re.compile(pattern)
            except re.error as exc:
                return {"ok": False, "error": f"正则写错了：{exc}"}
            hits, scanned = [], 0
            for path in root.rglob("*"):
                if not path.is_file():
                    continue
                if not fnmatch.fnmatch(path.name, include):
                    continue
                scanned += 1
                if scanned > 3000:
                    break
                try:
                    for n, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                        if rx.search(line):
                            rel = str(path.relative_to(root)).replace("\\", "/")
                            hits.append(f"{rel}:{n}: {line.strip()[:200]}")
                            if len(hits) >= MAX_GREP_HITS:
                                break
                except OSError:
                    continue
                if len(hits) >= MAX_GREP_HITS:
                    break
            out = "\n".join(hits) or "（没有命中）"

        elif name == "write":
            target = _resolve(workspace, args.get("path") or "", level)
            target.parent.mkdir(parents=True, exist_ok=True)
            content = args.get("content") or ""
            target.write_text(content, encoding="utf-8")
            out = f"已写入 {target}（{len(content)} 字符）"

        elif name == "edit":
            target = _resolve(workspace, args.get("path") or "", level)
            if not target.is_file():
                return {"ok": False, "error": f"文件不存在：{target}"}
            text = target.read_text(encoding="utf-8", errors="replace")
            old = args.get("old") or ""
            new = args.get("new") or ""
            if not old or text.count(old) != 1:
                return {"ok": False, "error": f"原文本需要唯一匹配，实际命中 {text.count(old)} 次"}
            target.write_text(text.replace(old, new, 1), encoding="utf-8")
            out = f"已修改 {target}"

        elif name == "delete":
            target = _resolve(workspace, args.get("path") or "", level)
            if not target.is_file():
                return {"ok": False, "error": f"只删文件，且必须存在：{target}"}
            target.unlink()
            out = f"已删除 {target}"

        elif name == "web_search":
            if not WEB.get("enabled"):
                return {"ok": False, "error": "联网未开启（[web] enabled = false）"}
            out = web_search(args.get("query") or "", args.get("count") or 5)

        elif name == "web_fetch":
            if not WEB.get("enabled"):
                return {"ok": False, "error": "联网未开启（[web] enabled = false）"}
            out = web_fetch(args.get("url") or "")

        elif name == "shell":
            cmd = args.get("command") or ""
            proc = subprocess.run(
                ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", cmd],
                capture_output=True, timeout=60, creationflags=CREATE_NO_WINDOW,
                cwd=workspace or None,
            )
            out = (proc.stdout or b"").decode("utf-8", "replace")
            err = (proc.stderr or b"").decode("utf-8", "replace")
            if err.strip():
                out += ("\n[stderr]\n" + err)
            out = f"exit={proc.returncode}\n" + out.strip()
        else:
            return {"ok": False, "error": f"未实现：{name}"}

        return {"ok": True, "output": _clip(out), "elapsed": round(time.time() - t0, 2)}

    except PermissionError as exc:
        return {"ok": False, "error": str(exc)}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "命令超时（60 秒）"}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"{type(exc).__name__}: {exc}"}

# ---------------- 联网：安全护栏 ----------------
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")
MAX_BYTES = 2 * 1024 * 1024
MAX_REDIRECTS = 5
BLOCK_HOSTS = ("localhost", "localhost.localdomain")


class _TextExtractor(HTMLParser):
    SKIP = {"script", "style", "noscript", "svg", "iframe", "template", "canvas"}
    BLOCK = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6",
             "section", "article", "header", "footer", "pre", "blockquote",
             "table", "ul", "ol", "dl", "dt", "dd", "figure", "figcaption"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skip += 1
        elif tag in self.BLOCK:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in self.SKIP:
            if self.skip:
                self.skip -= 1
        elif tag in self.BLOCK:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)


class _MainTextParser(HTMLParser):
    """按容器打分找正文：文本越长、链接占比越低，越可能是正文。"""
    SKIP = {"script", "style", "noscript", "svg", "iframe", "template",
            "nav", "header", "footer", "aside", "form", "select"}
    CAND = {"article", "main", "section", "div", "td", "ul", "ol"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack: list[dict] = []
        self.skip = 0
        self.link = 0
        self.everything: list[str] = []
        self.best_text: list[str] = []
        self.best_score = 0.0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skip += 1
            return
        if tag in self.CAND:
            self.stack.append({"tag": tag, "parts": [], "len": 0, "llen": 0})
        if tag == "a":
            self.link += 1

    def handle_endtag(self, tag):
        if tag in self.SKIP:
            self.skip = max(0, self.skip - 1)
            return
        if tag == "a":
            self.link = max(0, self.link - 1)
        if tag in self.CAND and self.stack:
            node = self.stack.pop()
            n = node["len"]
            if n < 200:
                return
            text = "".join(node["parts"])
            # 只按「像段落的行」计分：导航条那种一两个词的短行不计入
            body_len = sum(len(ln.strip()) for ln in text.splitlines() if len(ln.strip()) >= 30)
            link_ratio = node["llen"] / n if n else 1.0
            score = body_len * (1.0 - link_ratio) ** 2
            if score > self.best_score:
                self.best_score = score
                self.best_text = node["parts"]

    def handle_data(self, data):
        if self.skip or not data:
            return
        self.everything.append(data)
        if not self.stack:
            return
        for node in self.stack:
            node["parts"].append(data)
            node["len"] += len(data)
            if self.link:
                node["llen"] += len(data)


def _tidy_lines(text: str) -> str:
    text = re.sub(r"[ \t\r\f\v]+", " ", text)
    text = re.sub(r"\n\s*\n\s*\n+", "\n\n", text)
    lines = []
    for line in (x.strip() for x in text.splitlines()):
        if not line:
            continue
        toks = line.split(" ")
        # 丢掉「很多短词拼一行」的导航行
        if len(toks) >= 8 and sum(1 for t in toks if len(t) <= 4) / len(toks) > 0.7:
            continue
        # 丢掉导航按钮式的碎词：又短、又没有标点
        if len(line) < 12 and not re.search(r"[。！？，、；：\"\']", line):
            continue
        # 页脚/模板残留
        if line.startswith(("责任编辑", "海量资讯", "原标题", "免责声明", "版权所有")) or "@@" in line:
            continue
        lines.append(line)
    return "\n".join(lines).strip()


def extract_main_text(markup: str) -> str:
    """优先取正文容器，取不到就退回全文。"""
    parser = _MainTextParser()
    try:
        parser.feed(markup)
        parser.close()
    except Exception:  # noqa: BLE001
        return _tidy_lines(html_to_text(markup))
    src = parser.best_text if parser.best_score > 0 else parser.everything
    return _tidy_lines("".join(src))


def html_to_text(markup: str) -> str:
    parser = _TextExtractor()
    try:
        parser.feed(markup)
        parser.close()
    except Exception:  # noqa: BLE001
        pass
    text = "".join(parser.parts)
    text = re.sub(r"[ \t\r\f\v]+", " ", text)
    text = re.sub(r"\n\s*\n\s*\n+", "\n\n", text)
    text = "\n".join(line.strip() for line in text.splitlines())
    return text.strip()


def _ip_blocked(ip: ipaddress._BaseAddress) -> bool:
    return (
        ip.is_private or ip.is_loopback or ip.is_link_local
        or ip.is_reserved or ip.is_multicast or ip.is_unspecified
    )


def safe_url(url: str) -> str:
    """校验 URL：只允许 http/https，禁止内网/回环地址（防 SSRF）。"""
    url = (url or "").strip()
    if not url:
        raise ValueError("URL 为空")
    if not re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", url):
        url = "https://" + url
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in ("http", "https"):
        raise ValueError("只允许 http / https")
    host = (parsed.hostname or "").lower()
    if not host:
        raise ValueError("URL 缺少主机名")
    if host in BLOCK_HOSTS or host.endswith(".local") or host.endswith(".internal"):
        raise ValueError(f"禁止访问本机/内网主机：{host}")

    if WEB.get("block_private", True):
        try:
            infos = socket.getaddrinfo(host, parsed.port or (443 if parsed.scheme == "https" else 80),
                                       proto=socket.IPPROTO_TCP)
        except socket.gaierror as exc:
            raise ValueError(f"域名解析失败：{host}（{exc}）")
        for info in infos:
            addr = info[4][0]
            try:
                ip = ipaddress.ip_address(addr.split("%")[0])
            except ValueError:
                continue
            if _ip_blocked(ip):
                raise ValueError(f"禁止访问内网地址：{host} -> {addr}")
    return parsed.geturl()


def _http_get(url: str) -> tuple[str, str, str]:
    """带逐跳校验的 GET（手动跟随重定向）。返回 (final_url, content_type, body_text)。"""
    cur = safe_url(url)
    timeout = float(WEB.get("timeout", 15))
    for _ in range(MAX_REDIRECTS + 1):
        req = urllib.request.Request(cur, headers={
            "User-Agent": UA,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        })
        opener = urllib.request.build_opener(_NoRedirect())
        try:
            resp = opener.open(req, timeout=timeout)
        except urllib.error.HTTPError as exc:
            if exc.code in (301, 302, 303, 307, 308):
                loc = exc.headers.get("Location") or ""
                if not loc:
                    raise ValueError(f"HTTP {exc.code} 但缺少 Location")
                cur = safe_url(urllib.parse.urljoin(cur, loc))
                continue
            raise ValueError(f"HTTP {exc.code}：{cur}")
        raw = resp.read(MAX_BYTES)
        ctype = resp.headers.get("Content-Type", "")
        final = resp.geturl() or cur
        charset = resp.headers.get_content_charset()
        text = _decode(raw, charset)
        return final, ctype, text
    raise ValueError("重定向次数过多")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _decode(raw: bytes, charset: str | None) -> str:
    for enc in (charset, "utf-8", "gb18030"):
        if not enc:
            continue
        try:
            return raw.decode(enc)
        except (UnicodeDecodeError, LookupError):
            continue
    return raw.decode("utf-8", "replace")


def _clean_snippet(text: str) -> str:
    text = html_mod.unescape(text or "")
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("\u2002", " ").replace("\u2003", " ")
    return re.sub(r"\s+", " ", text).strip()


_SEARCH_CACHE: dict[str, tuple[float, str]] = {}


def clear_search_cache() -> None:
    _SEARCH_CACHE.clear()
SEARCH_CACHE_TTL = 600          # 同一查询 10 分钟内复用，减少被限流
RELEVANCE_FLOOR = 0.34          # 低于此值认为结果不可信


def _query_tokens(query: str) -> set[str]:
    tokens = {w.lower() for w in re.findall(r"[a-z0-9_.+#-]{2,}", query.lower())}
    for run in re.findall(r"[\u4e00-\u9fff]+", query):
        if len(run) == 1:
            tokens.add(run)
        for i in range(max(1, len(run) - 1)):
            tokens.add(run[i:i + 2])
    return tokens


def _row_score(query: str, row: tuple[str, str, str]) -> float:
    tokens = _query_tokens(query)
    if not tokens:
        return 1.0
    blob = " ".join(row).lower()
    return sum(1 for t in tokens if t in blob) / len(tokens)


def _filter_rows(query: str, rows: list[tuple[str, str, str]]) -> list[tuple[str, str, str]]:
    """丢掉与该行内容无关的条目，同一域名最多留 2 条。"""
    scored = [(_row_score(query, r), i, r) for i, r in enumerate(rows)]
    keep = [x for x in scored if x[0] >= 0.25]
    if not keep:                      # 一条都不达标，宁可全丢
        return []
    keep.sort(key=lambda x: (-x[0], x[1]))
    seen: dict[str, int] = {}
    out = []
    for _score, _i, r in keep:
        try:
            host = urllib.parse.urlsplit(r[1]).netloc.split(":")[0]
        except Exception:  # noqa: BLE001
            host = ""
        if seen.get(host, 0) >= 2:
            continue
        seen[host] = seen.get(host, 0) + 1
        out.append(r)
    return out


def _relevance(query: str, rows: list[tuple[str, str, str]]) -> float:
    tokens = _query_tokens(query)
    if not tokens or not rows:
        return 0.0
    blob = " ".join(f"{t} {u} {s}" for t, u, s in rows).lower()
    hit = sum(1 for t in tokens if t in blob)
    return hit / len(tokens)


def _parse_rss(body: str, n: int) -> list[tuple[str, str, str]]:
    rows = []
    for it in re.findall(r"<item>(.*?)</item>", body, re.S):
        t = re.search(r"<title>(.*?)</title>", it, re.S)
        l = re.search(r"<link>(.*?)</link>", it, re.S)
        d = re.search(r"<description>(.*?)</description>", it, re.S)
        title = _clean_snippet(t.group(1)) if t else ""
        link = (l.group(1) if l else "").strip()
        desc = _clean_snippet(d.group(1)) if d else ""
        if title and link.startswith("http"):
            rows.append((title, link, desc))
        if len(rows) >= n:
            break
    return rows


def _parse_html(body: str, n: int) -> list[tuple[str, str, str]]:
    rows = []
    for b in re.findall(r'<li class="b_algo".*?</li>', body, re.S):
        h2 = re.search(r"<h2[^>]*>(.*?)</h2>", b, re.S)
        if not h2:
            continue
        a = re.search(r'<a[^>]+href="([^"]+)"', h2.group(1), re.S)
        title = _clean_snippet(h2.group(1))
        link = a.group(1) if a else ""
        p = re.search(r"<p[^>]*>(.*?)</p>", b, re.S)
        desc = _clean_snippet(p.group(1)) if p else ""
        if title and link.startswith("http"):
            rows.append((title, link, desc))
        if len(rows) >= n:
            break
    return rows


CN_STOP = ("请问", "帮我", "查一下", "搜一下", "搜索", "一下", "怎么样", "怎么办",
           "为什么", "什么", "如何", "是否", "最新", "相关", "消息", "新闻")


YEAR_RE = re.compile(r"(?:19|20)\d{2}\s*年?|\d{2,4}\s*年")


def _variants(q: str) -> list[str]:
    """把长查询拆成更容易命中的短关键词组合。"""
    out: list[str] = []

    # 1) 去年份（含「2026年」这种紧跟中文的写法）
    v = YEAR_RE.sub(" ", q)
    v = re.sub(r"\s+", " ", v).strip(" ，,。.!?、")
    if v and v != q:
        out.append(v)

    # 2) 去掉疑问词/口语词
    v2 = v or q
    for w in CN_STOP:
        v2 = v2.replace(w, " ")
    v2 = re.sub(r"\s+", " ", v2).strip()
    if v2 and v2 not in out:
        out.append(v2)

    # 3) 长中文串：取「头 3 字 + 尾 3 字」，例如 北京大学计算机系 -> 北京大学 计算机系
    src = v2 or q
    made = []
    for run in re.findall(r"[\u4e00-\u9fff]{5,}", src):
        made.append(run[:3] + " " + run[-3:])
    if made:
        v3 = src
        for run in re.findall(r"[\u4e00-\u9fff]{5,}", src):
            v3 = v3.replace(run, run[:3] + " " + run[-3:])
        v3 = re.sub(r"\s+", " ", v3).strip()
        if v3 and v3 not in out:
            out.append(v3)
    parts = src.split()
    if len(parts) > 3:
        v3 = " ".join(parts[:3])
        if v3 not in out:
            out.append(v3)
    if len(parts) > 2:
        v4 = " ".join(parts[:2])
        if v4 not in out:
            out.append(v4)

    return [x for x in out if x and x != q][:4]


def _parse_360(body: str, n: int) -> list[tuple[str, str, str]]:
    rows = []
    for b in re.findall(r'<li class="res-list.*?</li>', body, re.S):
        t = re.search(r"<h3[^>]*>(.*?)</h3>", b, re.S)
        u = re.search(r'data-mdurl="([^"]+)"', b)
        if not (t and u):
            continue
        title = _clean_snippet(t.group(1))
        link = u.group(1).strip()
        d = re.search(r'class="res-desc"[^>]*>(.*?)</(?:p|div|span)>', b, re.S)
        desc = _clean_snippet(d.group(1)) if d else ""
        if title and link.startswith("http"):
            rows.append((title, link, desc))
        if len(rows) >= n:
            break
    return rows


def _fetch_360_pool(query: str, pages: int) -> tuple[list[tuple[str, str, str]], str]:
    q = urllib.parse.quote(query)
    seen: set[str] = set()
    pool: list[tuple[str, str, str]] = []
    final = ""
    for idx in range(max(1, int(pages))):
        url = f"https://www.so.com/s?q={q}&pn={idx + 1}"
        try:
            final_url, _ctype, body = _http_get(url)
        except Exception:  # noqa: BLE001
            continue
        if not final:
            final = final_url
        for row in _parse_360(body, 10):
            key = row[1].split("#")[0].split("?")[0]
            if key in seen:
                continue
            seen.add(key)
            pool.append(row)
    return pool, final


def _fetch_pool(query: str, pages: int, engine: str | None = None) -> tuple[list[tuple[str, str, str]], str]:
    """按引擎翻多页抓候选（每页 10 条），按 URL 去重。"""
    eng = (engine or WEB.get("engine") or "bing").lower()
    if eng == "360":
        return _fetch_360_pool(query, pages)
    q = urllib.parse.quote(query)
    seen: set[str] = set()
    pool: list[tuple[str, str, str]] = []
    final = ""
    for idx in range(max(1, int(pages))):
        url = f"https://cn.bing.com/search?format=rss&q={q}&first={1 + idx * 10}"
        try:
            final_url, _ctype, body = _http_get(url)
        except Exception:  # noqa: BLE001
            continue
        if not final:
            final = final_url
        for row in _parse_rss(body, 10):
            key = row[1].split("#")[0]
            if key in seen:
                continue
            seen.add(key)
            pool.append(row)
    return pool, final


def _fetch_rows(query: str, n: int) -> tuple[list[tuple[str, str, str]], str]:
    """先试 RSS，再试 HTML；两个市场各一次。返回 (rows, 最终 URL)。"""
    q = urllib.parse.quote(query)
    attempts = [
        ("https://cn.bing.com/search?format=rss&q=" + q, "rss"),
        ("https://www.bing.com/search?format=rss&q=" + q, "rss"),
        ("https://cn.bing.com/search?q=" + q + "&count=" + str(n + 3), "html"),
    ]
    best: tuple[list[tuple[str, str, str]], str] = ([], "")
    for url, kind in attempts:
        try:
            final, _ctype, body = _http_get(url)
        except Exception:  # noqa: BLE001
            continue
        rows = _parse_rss(body, n) if kind == "rss" else _parse_html(body, n)
        if rows and (not best[0] or len(rows) > len(best[0])):
            best = (rows, final)
        if rows and _relevance(query, rows) >= RELEVANCE_FLOOR:
            return rows, final
    return best


def _excerpt(url: str, limit: int) -> str:
    """抓一页正文并截断，失败返回空串。"""
    try:
        final, ctype, body = _http_get(url)
    except Exception as exc:  # noqa: BLE001
        return f"（抓取失败：{type(exc).__name__}）"
    is_html = "html" in (ctype or "").lower() or "<html" in body[:2000].lower()
    text = extract_main_text(body) if is_html else body
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    if len(text) > limit:
        text = text[:limit] + "…"
    return text


def _pick_excerpts(picked, want: int, limit: int) -> list[str]:
    """正文摘录：优先不同域名，避免全是同一篇文章的转载。"""
    out: list[str] = []
    used: dict[str, int] = {}
    for title, link, _desc in picked:
        if len(out) >= want:
            break
        try:
            host = urllib.parse.urlsplit(link).netloc.split(":")[0].lower()
        except Exception:  # noqa: BLE001
            host = ""
        if used.get(host, 0) >= 1:      # 同一域名只抓一篇
            continue
        body = _excerpt(link, limit)
        if not body or body.startswith("（抓取失败"):
            continue
        used[host] = used.get(host, 0) + 1
        out.append(f"— {title}\n  {link}\n{body}")
    return out


def web_search(query: str, count: int = 5) -> str:
    q = (query or "").strip()
    if not q:
        raise ValueError("搜索词为空")
    n = max(1, min(int(count or 5), int(WEB.get("max_results", 5))))
    pages = max(1, int(WEB.get("scan_pages", 3)))

    cache_key = f"{WEB.get('engine', 'bing')}|{q}"
    cached = _SEARCH_CACHE.get(cache_key)
    if cached and time.time() - cached[0] < SEARCH_CACHE_TTL:
        return cached[1]

    engines = [WEB.get("engine", "bing").lower()]
    fb = (WEB.get("fallback") or "").lower()
    if fb and fb not in ("none", "off") and fb not in engines:
        engines.append(fb)

    best = {"rows": [], "final": "", "score": 0.0, "engine": "", "query": q, "pool": 0}
    tried_queries: list[str] = []

    for engine in engines:
        if best["score"] >= RELEVANCE_FLOOR:
            break
        # 每个引擎：主查询 + 若干关键词变体
        for k, alt in enumerate([q] + _variants(q)):
            if best["score"] >= RELEVANCE_FLOOR:
                break
            if k:
                time.sleep(0.6)
            tried_queries.append(alt)
            try:
                pool, final = _fetch_pool(alt, pages if not k else max(1, pages - 1), engine)
            except Exception:  # noqa: BLE001
                continue
            kept = _filter_rows(alt, pool)
            sc = _relevance(alt, kept) if kept else 0.0
            if kept and sc > best["score"]:
                best = {"rows": kept, "final": final, "score": sc, "engine": engine,
                        "query": alt, "pool": len(pool)}

    if not best["rows"] or best["score"] < RELEVANCE_FLOOR:
        tried = "、".join(dict.fromkeys(tried_queries))
        text = (f"搜索：{q}\n"
                f"（已尝试「{tried}」，两个引擎都没有足够相关的内容；结果已丢弃，不是网络故障。"
                f"建议换「主体 事件」两个词再试，或直接说明无法核实）")
        _SEARCH_CACHE[cache_key] = (time.time(), text)
        return text

    picked = best["rows"][:n]
    engine_label = "Bing" if best["engine"] == "bing" else "360"
    lines = []
    if best["query"] != q:
        lines.append(f"（原查询「{q}」相关性不足，已自动改用「{best['query']}」重试）")
    if best["engine"] != engines[0]:
        lines.append(f"（{engines[0]} 无可用结果，已自动切到 {engine_label}）")
    lines.append(f"搜索：{best['query']}（{engine_label}，扫描 {best['pool']} 条，采用 {len(picked)} 条）")
    lines.append(f"来源：{best['final']}")
    lines.append("")
    for i, (title, link, desc) in enumerate(picked, 1):
        lines.append(f"{i}. {title}")
        lines.append(f"   {link}")
        if desc:
            lines.append(f"   {desc[:220]}")

    want = max(0, min(int(WEB.get("fetch_pages", 2)), len(picked)))
    if want:
        excerpts = _pick_excerpts(picked, want, int(WEB.get("fetch_chars", 1600)))
        if excerpts:
            lines.append("")
            lines.append("【正文摘录】")
            lines.extend(excerpts)
            lines.append("")

    text = "\n".join(lines).rstrip()
    _SEARCH_CACHE[cache_key] = (time.time(), text)
    return text


def web_fetch(url: str) -> str:
    final, ctype, body = _http_get(url)
    limit = int(WEB.get("max_chars", 8000))
    low = (ctype or "").lower()
    if "html" in low or "<html" in body[:2000].lower():
        text = extract_main_text(body)
    else:
        text = body
    text = text.strip()
    if len(text) > limit:
        text = text[:limit] + f"\n…（已截断，原文共 {len(text)} 字符）"
    header = f"抓取：{final}\n类型：{ctype or '未知'}\n" + "-" * 40 + "\n"
    return header + (text or "（没有提取到正文）")
