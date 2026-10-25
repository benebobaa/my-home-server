---
name: scraping-toolkit
description: "Use when web_extract misses data: JS-rendered listings, bot walls, numbers in images. Installed Python scraping stack + headless Chromium + OCR."
version: 1.0.0
author: homelab (services/hermes)
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [scraping, playwright, curl_cffi, beautifulsoup, ocr, tesseract, phonenumbers]
    category: web
    related_skills: [blocked-page-recovery, housing-rental-search]
---

# Scraping toolkit (installed on this machine)

This container has a ready scraping stack. `python3` and `pip` in the
terminal ARE the toolkit venv (`~/.venvs/scrape`, Python 3.13); `pip
install <pkg>` adds to it. There is no browser *tool* here: drive the browser
from Python with Playwright.

| Need | Use |
|---|---|
| Article / main text | `web_extract` tool first; else `trafilatura` |
| Static HTML, fast | `curl_cffi` (`impersonate="chrome"`) + `lxml` / `beautifulsoup4` |
| Async / many URLs | `httpx` (`AsyncClient`), or `curl_cffi.requests.AsyncSession` |
| Retries with backoff | `tenacity` |
| Cloudflare "Just a moment" (old v1 challenge) | `cloudscraper`; if it fails, Playwright |
| JS-rendered pages, infinite scroll, app data | `playwright` (Chromium, headless) |
| Numbers / text only inside images | `pytesseract` + `pillow`, `lang="ind+eng"` |
| Indonesian phone numbers | `phonenumbers` (region `"ID"`) |
| Excel deliverable | `openpyxl`; also `csv`, `sqlite3` (CLI and module), `jq` |

## Ladder for a site that won't give its data

1. `web_extract` (cheap). Empty or missing fields → the page is JS-rendered.
2. **Find the site's own JSON first.** Load the page in Playwright and capture
   XHR/fetch responses (snippet below). Listing sites (99.co, Mamikos) load
   their data from APIs; the JSON is cleaner than the DOM. Then call that API
   directly with `curl_cffi` + the same headers.
3. DOM via Playwright: wait for a selector, scroll for lazy loading, read
   `page.content()` and parse with lxml.
4. Blocked (403/429, captcha, login wall): stop and follow
   `blocked-page-recovery`. Never try to solve captchas or get past logins
   or paywalls.

## Snippets

```python
# Static page with a browser TLS fingerprint
from curl_cffi import requests
from lxml import html
r = requests.get(url, impersonate="chrome", timeout=30)
r.raise_for_status()
tree = html.fromstring(r.text)
```

```python
# JS page: capture the JSON the page loads, plus the rendered HTML
import json
from playwright.sync_api import sync_playwright

found = []
with sync_playwright() as p:
    browser = p.chromium.launch()            # headless
    page = browser.new_page(locale="id-ID")
    # Skip heavy assets unless you need images (OCR)
    page.route("**/*.{png,jpg,jpeg,webp,gif,woff,woff2,mp4}", lambda r: r.abort())
    page.on("response", lambda resp: found.append(resp.url)
            if "json" in (resp.headers.get("content-type") or "") else None)
    page.goto(url, wait_until="domcontentloaded", timeout=60000)
    page.wait_for_timeout(3000)              # or page.wait_for_selector("...")
    for _ in range(5):                       # lazy-loaded lists
        page.mouse.wheel(0, 4000); page.wait_for_timeout(1000)
    rendered = page.content()
    browser.close()
print("\n".join(found))                      # then fetch the useful ones directly
```

```python
# Number inside an image: OCR, then validate — never guess digits
import io, pytesseract, phonenumbers
from PIL import Image, ImageOps
img = ImageOps.grayscale(Image.open(io.BytesIO(image_bytes)))
img = img.resize((img.width * 2, img.height * 2))
text = pytesseract.image_to_string(img, lang="ind+eng", config="--psm 6")
for m in phonenumbers.PhoneNumberMatcher(text, "ID"):
    e164 = phonenumbers.format_number(m.number, phonenumbers.PhoneNumberFormat.E164)
    wa = "https://wa.me/" + e164.lstrip("+")
```

OCR output is a lead, not a fact: keep only numbers that `phonenumbers`
validates, and label them "from image (OCR)" in the deliverable. Masked
numbers (`+62xx****6171`) stay masked.

## Limits of this machine

- **2 GB RAM**: one browser at a time, at most 3 pages open, always
  `browser.close()` (use `with`). Block images unless you need them.
- **10 GB disk**: save work under `~/data/<topic>/`; delete downloaded images
  after OCR. Send deliverables back with `MEDIA:/path`.
- No GPU, no display (headless only), internet only (no access to the
  owner's lab).

## Manners

- 1–3 s between requests to one site, retry 429/5xx with backoff
  (`tenacity`), at most a few parallel requests per site.
- Respect robots.txt and the site's terms; stop when a site clearly blocks
  you instead of escalating.
- Personal data (phone numbers, names) is for the owner's own use: keep it in
  the deliverable, don't publish or resell it.
