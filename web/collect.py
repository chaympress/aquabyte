#!/usr/bin/env python3
"""Aquabyte — compute today's usage quickly (called every 0.5s).

Incremental: remember the last read offset per file and parse only new lines.
Cache: ~/.aquabyte-cache.json

Water/power estimates: 0.32 ml and 0.34 Wh per 1,000 weighted tokens
"""
import json, os, glob, sqlite3, datetime, collections, urllib.request, time

HOME = os.path.expanduser("~")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "live.js")
CACHE = os.path.join(HOME, ".aquabyte-cache.json")

W = {"input": 1.0, "cache_read": 0.1, "cache_write": 1.25, "output": 5.0}
KEYS = ("input", "output", "cache_read", "cache_write")


def day_start():
    return datetime.datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()


def parse_iso(s):
    try:
        return datetime.datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def fresh():
    return {"date": datetime.date.today().isoformat(), "files": {},
            "acc": {k: 0 for k in KEYS}, "hermes": None, "hermes_at": 0, "active_until": 0}


def load_cache():
    try:
        with open(CACHE) as f:
            c = json.load(f)
        if c.get("date") != datetime.date.today().isoformat():
            return fresh()
        c.setdefault("files", {})
        acc = c.get("acc") or {}
        c["acc"] = {k: int(acc.get(k, 0)) for k in KEYS}
        return c
    except Exception:
        return fresh()


def save_cache(c):
    try:
        with open(CACHE, "w") as f:
            json.dump(c, f)
    except Exception:
        pass


def scan_claude(since, cache):
    """Read only newly appended lines (per-file offset)."""
    acc = cache["acc"]
    for f in glob.glob(os.path.join(HOME, ".claude", "projects", "**", "*.jsonl"), recursive=True):
        try:
            st = os.stat(f)
        except OSError:
            continue
        prev = cache["files"].get(f)
        off = prev["off"] if (prev and prev.get("size", 0) <= st.st_size) else 0
        if st.st_size <= off:
            continue
        try:
            fh = open(f, errors="ignore")
        except OSError:
            continue
        with fh:
            fh.seek(off)
            for line in fh:
                if '"usage"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                t = parse_iso(o.get("timestamp"))
                if not t or t < since:
                    continue
                m = o.get("message") or {}
                u = m.get("usage") or {}
                if not isinstance(u, dict):
                    continue
                acc["input"] += u.get("input_tokens") or 0
                acc["output"] += u.get("output_tokens") or 0
                acc["cache_read"] += u.get("cache_read_input_tokens") or 0
                acc["cache_write"] += u.get("cache_creation_input_tokens") or 0
            off = fh.tell()
        if prev and off > prev.get("off", 0):
            cache["active_until"] = time.time() + 3.5   # file is growing: the AI is working
        cache["files"][f] = {"off": off, "size": st.st_size}


def codex(since):
    acc = collections.Counter()
    for f in glob.glob(os.path.join(HOME, ".codex", "sessions", "**", "*.jsonl"), recursive=True):
        try:
            if os.path.getmtime(f) < since - 86400:
                continue
        except OSError:
            continue
        with open(f, errors="ignore") as fh:
            for line in fh:
                if "token" not in line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if (parse_iso(o.get("timestamp")) or 0) < since:
                    continue
                blob = o.get("payload") or o
                info = blob.get("info") or blob
                use = info.get("last_token_usage") or info.get("total_token_usage") or {}
                acc["input"] += use.get("input_tokens") or 0
                acc["output"] += use.get("output_tokens") or 0
                acc["cache_read"] += use.get("cached_input_tokens") or 0
    return acc


def _remote(url):
    try:
        with urllib.request.urlopen(url, timeout=4) as r:
            d = json.loads(r.read().decode())
        return {"input": int(d.get("input") or 0), "output": int(d.get("output") or 0)}
    except Exception:
        return None


def hermese(cache):
    """Query the remote endpoint at most once every 5 seconds."""
    url = None
    try:
        cfg = os.path.join(HOME, ".aquabyte.json")
        if not os.path.exists(cfg):
            cfg = os.path.join(HOME, ".ai-bottle.json")   # backward compatibility
        with open(cfg) as f:
            url = (json.load(f) or {}).get("hermes_api")
    except Exception:
        pass
    if url:
        now = datetime.datetime.now().timestamp()
        if cache.get("hermes") is None or now - (cache.get("hermes_at") or 0) > 5:
            got = _remote(url)
            if got is not None:
                cache["hermes"] = got
            cache["hermes_at"] = now
        h = cache.get("hermes") or {}
        return collections.Counter({"input": int(h.get("input", 0)), "output": int(h.get("output", 0))})

    acc = collections.Counter()
    db = os.path.join(HOME, ".hermes", "state.db")
    if not os.path.exists(db):
        return acc
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=3)
        i, o = con.execute(
            "select coalesce(sum(input_tokens),0), coalesce(sum(output_tokens),0) "
            "from sessions where last_activity_at >= ?", (day_start(),)).fetchone()
        con.close()
        acc["input"] += int(i)
        acc["output"] += int(o)
    except Exception:
        pass
    return acc


def main():
    since = day_start()
    cache = load_cache()
    scan_claude(since, cache)
    acc = collections.Counter(cache["acc"])
    cx = codex(since)
    acc.update(cx)
    h = hermese(cache)
    acc.update(h)
    save_cache(cache)

    weighted = (acc["input"] * W["input"] + acc["cache_read"] * W["cache_read"]
                + acc["cache_write"] * W["cache_write"] + acc["output"] * W["output"])
    ml = weighted / 1000 * 0.32
    wh = weighted / 1000 * 0.34
    cc = (acc["input"] + acc["output"] + acc["cache_read"] + acc["cache_write"]
          - h["input"] - h["output"] - cx["input"] - cx["output"] - cx["cache_read"])
    payload = {
        "ts": datetime.datetime.now().timestamp(),
        "date": datetime.datetime.now().strftime("%m-%d %H:%M:%S"),
        "tokens": int(weighted),
        "raw_tokens": int(sum(acc.values())),
        "ml": round(ml, 1),
        "wh": round(wh, 1),
        "bottles": round(ml / 500, 2),
        "coffee": round(wh / 30, 1),
        "ramen": round(wh / 51, 1),
        "boil1L": round(wh / 93, 1),
        "phone": round(wh / 12, 0),
        "sauna": round(wh / 3000, 2),
        "active": time.time() < (cache.get("active_until") or 0),
        "parts": {
            "claude_code": max(0, int(cc)),
            "codex": int(cx["input"] + cx["output"] + cx["cache_read"]),
            "hermes": int(h["input"] + h["output"]),
        },
    }
    with open(OUT, "w") as f:
        f.write("window.LIVE = " + json.dumps(payload, ensure_ascii=False) + ";\n")
    print(json.dumps(payload, ensure_ascii=False))


if __name__ == "__main__":
    import sys, time
    if "--watch" in sys.argv:
        # watch mode: compute every 0.5s and stream one JSON line per tick
        while True:
            try:
                main()
                sys.stdout.flush()
            except Exception:
                pass
            time.sleep(0.5)
    else:
        main()
