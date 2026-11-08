# ============================================================================
#  browser.py — 无头浏览器任务：搜索 / 读页面
#  用法：
#    python browser.py --action search --query "deepseek" --limit 5 --out r.json
#    python browser.py --action read --url "https://..." --out r.json
#  优先用系统已装的 Edge/Chrome（channel），不需要额外下载浏览器内核
# ============================================================================
import argparse
import json
import os
import sys
import tempfile
from urllib.parse import quote

from playwright.sync_api import sync_playwright

OUT_DEFAULT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data', 'browser.json')

_TMP = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data', 'tmp')
os.makedirs(_TMP, exist_ok=True)
os.environ['TMP'] = _TMP
os.environ['TEMP'] = _TMP
os.environ['TMPDIR'] = _TMP
tempfile.tempdir = _TMP


def launch_browser(p):
    errors = []
    for channel in ('msedge', 'chrome'):
        try:
            return p.chromium.launch(channel=channel, headless=True)
        except Exception as exc:
            errors.append(f'{channel}: {exc}')
    try:
        return p.chromium.launch(headless=True)
    except Exception as exc:
        errors.append(f'bundled: {exc}')
    raise RuntimeError('没有可用的浏览器内核（Edge/Chrome）: ' + ' | '.join(errors))


def do_search(page, query, limit, engine):
    if engine == 'baidu':
        url = 'https://www.baidu.com/s?wd=' + quote(query)
    else:
        url = 'https://cn.bing.com/search?q=' + quote(query)
    page.goto(url, wait_until='domcontentloaded', timeout=30000)
    page.wait_for_timeout(900)

    results = []
    if engine == 'baidu':
        blocks = page.query_selector_all('div.result, div.c-container')
        for block in blocks:
            a = block.query_selector('h3 a')
            if not a:
                continue
            title = (a.inner_text() or '').strip()
            href = a.get_attribute('href') or ''
            sn = block.query_selector('span.content-right_1THTn, .c-abstract, .content-right')
            snippet = (sn.inner_text() if sn else '').strip()
            if title:
                results.append({'title': title, 'url': href, 'snippet': snippet[:180]})
            if len(results) >= limit:
                break
    else:
        for block in page.query_selector_all('li.b_algo')[:limit]:
            a = block.query_selector('h2 a')
            if not a:
                continue
            title = (a.inner_text() or '').strip()
            href = a.get_attribute('href') or ''
            p = block.query_selector('p')
            snippet = (p.inner_text() if p else '').strip()
            if title:
                results.append({'title': title, 'url': href, 'snippet': snippet[:180]})

    return {'engine': engine, 'search_url': url, 'results': results}


def do_read(page, url, max_chars):
    page.goto(url, wait_until='domcontentloaded', timeout=30000)
    page.wait_for_timeout(600)
    title = page.title()
    text = page.evaluate("document.body ? document.body.innerText : ''")
    text = (text or '').strip()
    return {'title': title, 'url': page.url, 'text': text[:max_chars], 'truncated': len(text) > max_chars}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--action', required=True, choices=['search', 'read'])
    ap.add_argument('--query', default='')
    ap.add_argument('--url', default='')
    ap.add_argument('--engine', default='bing', choices=['bing', 'baidu'])
    ap.add_argument('--limit', type=int, default=5)
    ap.add_argument('--max-chars', type=int, default=6000)
    ap.add_argument('--out', default=OUT_DEFAULT)
    args = ap.parse_args()

    payload = {'ok': False, 'action': args.action}
    try:
        with sync_playwright() as p:
            browser = launch_browser(p)
            page = browser.new_page(locale='zh-CN')
            if args.action == 'search':
                if not args.query:
                    raise ValueError('缺少搜索关键词')
                payload.update(do_search(page, args.query, args.limit, args.engine))
                payload['ok'] = True
            else:
                if not args.url:
                    raise ValueError('缺少网址')
                payload.update(do_read(page, args.url, args.max_chars))
                payload['ok'] = True
            browser.close()
    except Exception as exc:
        payload['error'] = str(exc)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, 'w', encoding='utf-8') as f:
        json.dump(payload, f, ensure_ascii=False)


if __name__ == '__main__':
    main()
