#!/usr/bin/env python3
"""
Разовый импорт архива дайджестов из telegra.ph в data/digests/*.json.

Нужен, только чтобы перенести выпуски, опубликованные ботом до появления сайта.
Дальше бот пишет JSON сам (см. README, часть про автопубликацию).

    TELEGRAPH_TOKEN=... python3 scripts/import-telegraph.py 2026-08-01
"""
import json
import os
import re
import subprocess
import sys
import urllib.parse
from datetime import date
from pathlib import Path

API = "https://api.telegra.ph"
OUT = Path(__file__).resolve().parent.parent / "data" / "digests"

MONTHS = {
    "января": 1, "февраля": 2, "марта": 3, "апреля": 4, "мая": 5, "июня": 6,
    "июля": 7, "августа": 8, "сентября": 9, "октября": 10, "ноября": 11, "декабря": 12,
}
TITLE_RE = re.compile(r"Дайджест за (\d{1,2}) (\w+) (\d{4})")
EM_RE = re.compile(r"^(.*?)\s*·\s*(\d+)\s*/\s*10\s*$")


def api(method, **params):
    """Через curl, а не urllib: в сетях с TLS-перехватом Python не доверяет корню, curl доверяет."""
    params["access_token"] = os.environ["TELEGRAPH_TOKEN"]
    url = f"{API}/{method}?" + urllib.parse.urlencode(params)
    out = subprocess.run(["curl", "-sSf", "--max-time", "30", url],
                         capture_output=True, check=True).stdout
    data = json.loads(out)
    if not data.get("ok"):
        raise RuntimeError(data)
    return data["result"]


def text_of(node):
    """Плоский текст из дерева нод telegra.ph."""
    if isinstance(node, str):
        return node
    return "".join(text_of(c) for c in node.get("children") or [])


def links_of(node):
    out = []
    for c in node.get("children") or []:
        if isinstance(c, dict) and c.get("tag") == "a":
            out.append({"title": text_of(c) or c["attrs"]["href"], "url": c["attrs"]["href"]})
    return out


def img_urls(node):
    """Адреса картинок внутри figure/img."""
    out = []
    if isinstance(node, dict):
        if node.get("tag") == "img":
            src = (node.get("attrs") or {}).get("src")
            if src:
                out.append(src)
        for c in node.get("children") or []:
            out += img_urls(c)
    return out


def parse(content):
    """Ноды telegra.ph -> announce, items[]."""
    announce, items, category, cur = "", [], "", None

    def flush():
        nonlocal cur
        if cur:
            items.append(cur)
            cur = None

    expect_takeaways = False
    for n in content:
        if isinstance(n, str):
            continue
        tag = n.get("tag")
        txt = text_of(n).strip()

        if tag == "h3":
            category = txt
        elif tag == "h4":
            flush()
            cur = {"title": txt, "category": category}
        elif tag == "ul" and expect_takeaways and cur is not None:
            cur["takeaways"] = [text_of(li).strip() for li in n.get("children") or []]
            expect_takeaways = False
        elif tag == "figure" and cur is not None:
            # картинка стояла в потоке между абзацами – сохраняем это место
            for url in img_urls(n):
                cur.setdefault("blocks", []).append({"type": "image", "url": url})
        elif tag == "blockquote" and cur is not None:
            cur["quote"] = txt
        elif tag == "p":
            if txt.startswith("Выводы автора"):
                expect_takeaways = True
            elif txt.startswith("Оригиналы") and cur is not None:
                cur["links"] = links_of(n)
            elif cur is None and not announce and txt:
                announce = txt
            elif cur is not None:
                m = EM_RE.match(txt)
                if m:
                    # "Habr <noreply@habr.com> · 7/10"
                    src = re.sub(r"\s*<[^>]*>", "", m.group(1)).strip()
                    cur["source"] = src
                    cur["score"] = int(m.group(2))
                elif txt:
                    cur["blocks"] = cur.get("blocks", []) + [{"type": "text", "text": txt}]
                    cur["summary"] = (cur["summary"] + "\n\n" + txt) if cur.get("summary") else txt
    flush()
    return announce, items


def main():
    since = date.fromisoformat(sys.argv[1]) if len(sys.argv) > 1 else date(1970, 1, 1)
    pages = api("getPageList", limit=200)["pages"]

    seen = set()
    written = 0
    for p in pages:  # список отдаётся от новых к старым
        m = TITLE_RE.search(p["title"])
        if not m or m.group(2) not in MONTHS:
            continue
        d = date(int(m.group(3)), MONTHS[m.group(2)], int(m.group(1)))
        if d < since or d in seen:
            continue  # для одной даты берём самую свежую публикацию
        seen.add(d)

        page = api("getPage", path=p["path"], return_content="true")
        announce, items = parse(page["content"])
        if not items:
            print(f"  {d}: пусто, пропускаю")
            continue

        doc = {
            "version": 2,
            "date": d.isoformat(),
            "title": f"Дайджест за {m.group(1)} {m.group(2)} {m.group(3)}",
            "announce": announce,
            "stats": {"total": len(items)},
            "top": [i["title"] for i in items[:5]],
            "items": items,
            "source_url": page["url"],
        }
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / f"{d.isoformat()}.json").write_text(
            json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8"
        )
        written += 1
        print(f"  {d}: {len(items)} материалов")

    print(f"записано выпусков: {written}")


if __name__ == "__main__":
    main()
