---
name: web-research
description: Research topics using the web via curl. Use when the user asks to look something up, find current information, or research a topic online.
metadata:
  shelllm:
    requires:
      bins: ["curl", "jq"]
---

# web-research

## When to use

User asks you to look something up, find current information, research a topic, or answer a question that needs knowledge newer than your context.

## Search first: Parallel Search, RSS feeds as the no-key fallback

Order of operations, re-verified 2026-11-22: **Parallel Search first** if the key file exists, **news RSS** if it does not, **Wikipedia** for concepts, and curl the publisher page only when the excerpts are not enough to answer.

### Parallel Search

Paid, about $0.001 per fast search. Key lives in `/root/.headlong/app/.identities/ada/secrets/parallel_api_key` (mode 600, gitignored). Read it, never echo it, never paste it into a request URL.

Five things the API charges you for getting wrong, checked 2026-11-22 against Parallel's own `parallel-api` skill:

- the field is `search_queries`, a list. `queries` does not exist on `/v1` and returns 422. A body copied from the v1beta docs returns 422 too.
- `mode` must be sent explicitly, or it defaults to `advanced` at five times the fast price.
- each query is 3 to 6 keyword words, no sentences, no `site:`. The full question goes in `objective`.
- excerpts come back long (0.7k to 6k chars), so read them before spending an Extract call.
- read `.warnings[]` too. Search reports adjusted inputs there and still returns 200, so a silently narrowed query looks like success.

```bash
KEY=$(cat /root/.headlong/app/.identities/ada/secrets/parallel_api_key)
curl -s --max-time 40 -X POST https://api.parallel.ai/v1/search \
  -H "x-api-key: $KEY" -H 'content-type: application/json' \
  -d '{"mode":"fast","objective":"what is driving mango prices in India this season","search_queries":["mango price India arrivals","India mango crop loss","Kesar Alphonso harvest decline"]}' \
  -o /tmp/psearch.json -w 'http=%{http_code} t=%{time_total}\n'
```

Then read it, checking the error shape before the results. No nested heredocs; keep it one line so it survives being pasted into a step:

```bash
jq -r 'if .error then ("ERROR " + (.error|tostring)) else (.results[:8][] | "- \(.title) | \(.publish_date) | \(.url)\n  " + ((.excerpts[0] // "")[:300])) end' /tmp/psearch.json
```

The response is `{search_id, session_id, results[], warnings, usage, metadata}`. Each result is `{url, title, publish_date, excerpts[]}`. `publish_date` is sometimes `null` on trader and mandi pages. `usage` reports `sku_search` count so you can see what one call cost.

`mode` choices, per Parallel's spec ($ per 1,000 requests): `fast` about 700 ms at $1, the default for most agent lookups and what the example above uses; `turbo` about 200 ms at $1 for high-volume simple English or Japanese lookups; `basic` about 1 s at $5 for longer excerpts; `advanced` about 3 s at $5 for multi-hop background work. Before jumping to `basic` or `advanced` for more text, try the two cheaper dials: `advanced_settings.max_results` (default 10, each extra result $1/1k) and `advanced_settings.excerpt_settings.max_chars_per_result`.

Keep `session_id` from the search and pass it to the Extract call on the same question, so the two calls share one session instead of starting cold.

### Parallel Extract (page text when excerpts are not enough)

Verified 2026-11-22 with six live calls. Extract does **not** return the whole page. It returns, per URL, one excerpt chosen for relevance to the `objective` you pass, plus a `full_content` field that came back `null` on every URL I tried (news, paywalled news, stats page, plain HTML). Treat it as a sharper excerpt, not as a way to read a long page or a table.

```bash
KEY=$(cat /root/.headlong/app/.identities/ada/secrets/parallel_api_key)
curl -s --max-time 60 -X POST https://api.parallel.ai/v1/extract \
  -H "x-api-key: $KEY" -H 'content-type: application/json' \
  -d '{"urls":["https://example.com/a","https://example.com/b"],"objective":"what the piece says about why rubber prices rose"}' \
  -o /tmp/pextract.json -w 'http=%{http_code} t=%{time_total}\n'
jq -r '(.results[] | "- \(.title|gsub("\\s+";" ")|.[0:80]) [\(.excerpts|length)x\(.excerpts[0]|length)] " + (.excerpts[0][:400])), (.errors[]? | "ERROR \(.error_type) \(.http_status_code) \(.url)")' /tmp/pextract.json
```

What the calls actually showed:

- **Reuse the `session_id` from the Search call.** Pass `"session_id":"<id from the search response>"` in the Extract body when the URLs came from that search, so the excerpt is chosen with the search's context.
- **Always pass `objective`.** Without it every call still returns 200 but adds a warning (`Neither objective nor search_queries were provided...`) and the excerpt is just the top of the page, which on a news site means cookie banners and login chrome. With an objective the excerpt starts at the substance. `search_queries` (1-3 short keyword strings) is the optional second dial.
- **Excerpt size with an objective** ran 515 to 2,997 characters across the calls here. For a question that needs one number or one quote that is usually enough; for a whole table it is not.
- **Batch up to at least 6 URLs per call.** Six URLs returned six results in 0.98s.
- **Failures are per URL, not per call.** A 404 page and a nonexistent domain both came back inside a 200 response, in a top-level `errors[]` array shaped `{url, error_type, http_status_code, content}`, with `error_type` of `http_error` (404) or `connect_error` (unresolvable host). Good URLs land in `results[]` in the same response. Always read `.errors[]` too, or a bad URL looks like silence.
- **Billing is per successful URL.** `usage` was `[{"name":"sku_extract_excerpts","count":N}]` where N counted only the URLs that returned text; a 2-URL call with one 404 billed 1. About $0.001 per URL.
- Timings 0.2 to 1.4s per call including the 6-URL batch.

Rule of thumb: Search first and read its excerpts, which are often longer (0.7k-6k chars). Reach for Extract when Search surfaced the right page but the excerpt missed the part you need, or when you have publisher URLs from RSS and want them read in one call. If you need truly complete text, curl the page and parse it, as the publisher-page section below describes.


### News RSS (fallback when there is no key)

The general search engines block this host (see the blocked list at the bottom, checked 2026-11-22). What did work, first try, on every query I gave it, are the two news RSS endpoints. Re-verified from a cold start 2026-11-22 with a query I had not used before (soil moisture sensors irrigation scheduling): both feeds returned on-topic titles, the Bing wrapper resolved to the publisher, and that page fetched and parsed. They take any query, not just news topics, and return recent coverage with titles, links and summaries.

```bash
q="factors affecting mango prices"
enc=$(printf '%s' "$q" | jq -sRr @uri)
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

# Bing News: each link is a bing.com redirect wrapper that 302s to the publisher
curl -sL --max-time 15 -A "$UA" "https://www.bing.com/news/search?q=$enc&format=rss" \
  | grep -oP '<title>\K[^<]+' | head -10

# Google News: bigger index, but article links bounce to a consent page
curl -sL --max-time 15 -A "$UA" "https://news.google.com/rss/search?q=$enc&hl=en-US&gl=US&ceid=US:en" \
  | grep -oP '<title>\K[^<]+' | head -10
```

To get the links and snippets, not just titles:

```bash
curl -sL --max-time 15 -A "$UA" "https://www.bing.com/news/search?q=$enc&format=rss" -o /tmp/rss.xml
python3 - <<'PY'
import re, html
t = open('/tmp/rss.xml', encoding='utf-8', errors='replace').read()
for it in re.findall(r'<item>(.*?)</item>', t, re.S)[:8]:
    ti = re.search(r'<title>(.*?)</title>', it, re.S)
    li = re.search(r'<link>(.*?)</link>', it, re.S)
    de = re.search(r'<description>(.*?)</description>', it, re.S)
    print(html.unescape(ti.group(1)) if ti else '?')
    print('   link:', html.unescape(li.group(1)) if li else '?')
    print('   ', html.unescape(re.sub(r'<[^>]+>', '', de.group(1))).strip()[:220] if de else '')
PY
```

Google News article links do not open with curl: they land on google.com/sorry. Take the title and snippet from that feed, then fetch the publisher's own page directly (or take the link from the Bing News feed).

The raw `<link>` in the Bing feed is not the publisher URL. It looks like `bing.com/news/apiclick.aspx?...&url=<encoded>`. Two ways through it, both tested 2026-11-22:

```bash
# 1. just decode it, no request at all
python3 -c 'import sys,urllib.parse as u; print(u.parse_qs(u.urlparse(sys.argv[1]).query).get("url",[""])[0])' "$link"

# 2. or follow it; curl -L lands on the publisher and returns the full page
curl -sL --max-time 20 -A "$UA" "$link" -o /tmp/page.html -w '%{url_effective} %{http_code}\n'
```

## Fetch a page and read it

```bash
curl -sL --max-time 20 -A "$UA" "$url" -o /tmp/page.html
python3 - <<'PY'
import re, html
t = open('/tmp/page.html', encoding='utf-8', errors='replace').read()
t = re.sub(r'<script.*?</script>|<style.*?</style>', ' ', t, flags=re.S | re.I)
t = html.unescape(re.sub(r'<[^>]+>', ' ', t))
print(re.sub(r'[ \t]+', ' ', t).strip()[:4000])
PY
```

Rough and quick version, no python: `sed 's/<[^>]*>/ /g' /tmp/page.html | tr -s ' \n' ' \n' | grep -v '^\s*$' | head -60`

## Wikipedia, when the topic is a thing rather than an event

```bash
curl -s "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=mango+price&format=json&srlimit=3" | jq -r '.query.search[].title'
curl -s "https://en.wikipedia.org/api/rest_v1/page/summary/Mango" | jq -r '.extract'
```

## Blocked from this host (checked 2026-11-22)

Do not spend a minute on any of these; they cost me twenty last time.

- DuckDuckGo html and lite: 202 plus a bot challenge, sometimes an image captcha.
- Bing web results: page returns 200 but the results are unrelated to the query (it served Tekken pages for a mango query), and the links are base64 redirects. The News RSS endpoint above is fine.
- Brave search: 429, and it stays 429 for at least several minutes.
- Google web: 200 but a JavaScript redirect, or google.com/sorry.
- Startpage: JavaScript proof of work challenge. Ecosia: 403. Mojeek: captcha.
- Yandex: SmartCaptcha. Qwant API: 403. Yep API: 403. Stract: 404.
- Public SearXNG instances (searx.be, inetol, baresearch, and others): antibot pages or 429. 4get: 401.

## Tips

- Always `-s` and `-L`, and give curl a `--max-time` so a hang does not eat the step.
- Send a real desktop User-Agent. It does not defeat the captchas, but some sites serve nothing without it.
- Read the title of what came back before trusting it. Every one of the failures above returned HTTP 200 with a captcha page inside.
- One engine failing is not the web failing. Go to a publisher's own site when you already know who covers the topic.
- Rate-limit: do not loop a blocked engine hoping it opens up.
