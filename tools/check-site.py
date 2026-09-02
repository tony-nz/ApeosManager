#!/usr/bin/env python3
"""Structural check on the documentation site, before it is pushed.

Balanced tags, live in-page anchors, images that exist, alt text on every one. None of
this is caught by looking at the page in a browser -- a stray </div> reflows silently,
and a dead anchor only shows up when somebody clicks it.

    python3 tools/check-site.py          # exits non-zero if anything is wrong
"""
import pathlib
import sys
from html.parser import HTMLParser

VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
        'link', 'meta', 'source', 'track', 'wbr'}

DOCS = pathlib.Path(__file__).resolve().parent.parent / 'docs'


class Check(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.errors = [], []
        self.ids, self.hrefs, self.imgs = set(), [], []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if 'id' in a:
            self.ids.add(a['id'])
        if tag == 'a' and 'href' in a:
            self.hrefs.append(a['href'])
        if tag == 'img':
            self.imgs.append(a.get('src'))
            if not a.get('alt', '').strip():
                self.errors.append(f'img without alt text: {a.get("src")}')
        if tag not in VOID:
            self.stack.append((tag, self.getpos()))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID and self.stack:
            self.stack.pop()

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if not self.stack:
            self.errors.append(f'</{tag}> with nothing open at {self.getpos()}')
            return
        open_tag, pos = self.stack.pop()
        if open_tag != tag:
            self.errors.append(
                f'</{tag}> at {self.getpos()} closes <{open_tag}> opened at {pos}')


def main():
    failed = False
    pages = sorted(DOCS.glob('*.html'))
    if not pages:
        print(f'no pages under {DOCS}')
        return 1

    for page in pages:
        c = Check()
        c.feed(page.read_text(encoding='utf-8'))
        print(f'--- {page.name} ---')

        problems = list(c.errors)
        if c.stack:
            problems.append('unclosed: ' + ', '.join(t for t, _ in c.stack))
        for href in c.hrefs:
            if href.startswith('#') and href[1:] not in c.ids:
                problems.append(f'dead anchor {href}')
            elif not href.startswith(('#', 'http:', 'https:', 'mailto:')):
                target = (DOCS / href.split('#')[0]).resolve()
                if not target.exists():
                    problems.append(f'dead link {href}')
        for src in c.imgs:
            if src and not (DOCS / src).exists():
                problems.append(f'missing image {src}')

        if problems:
            failed = True
            for p in problems:
                print('  ERROR', p)
        else:
            print('  structure ok'
                  f' ({len(c.imgs)} images, {len(c.hrefs)} links, {len(c.ids)} anchors)')

    # Every screenshot on disk should be used by something, or it is dead weight.
    used = set()
    for page in pages:
        c = Check()
        c.feed(page.read_text(encoding='utf-8'))
        used.update(s for s in c.imgs if s)
    for shot in sorted((DOCS / 'screenshots').glob('*.png')):
        rel = f'screenshots/{shot.name}'
        if rel not in used:
            print(f'  NOTE  {rel} is not referenced by any page')

    if not (DOCS / '.nojekyll').exists():
        print('  ERROR docs/.nojekyll is missing; GitHub will run Jekyll over the site')
        failed = True

    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
