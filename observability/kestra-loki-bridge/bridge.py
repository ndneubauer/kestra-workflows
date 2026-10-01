"""Poll Kestra's global logs index and re-emit to stdout for Promtail/Loki.

Design (v2):
- Poll GET /api/v1/main/logs/search?sort=timestamp:desc&page=&size= directly.
  This returns the newest log entries across ALL executions (total ~129k and
  growing), so no executions-search round-trip is needed and recent 5-minute
  poller runs are always on page 1.
- Keep a high-watermark timestamp; each cycle, page until an already-seen
  entry appears, then emit everything new oldest-first.
- Stdlib only. State is in-memory; on startup the first page is emitted
  (bounded duplicates after a restart are preferable to gaps).
- Bridge's own chatter is quiet by default: per-cycle "polled" lines are
  only logged when something was shipped, plus a heartbeat every
  HEARTBEAT_CYCLES cycles. Set BRIDGE_LOG_LEVEL=DEBUG for full verbosity.

Output line format (unchanged, matches the existing Promtail pipeline which
parses LEVEL into the `lvl` label — no Promtail/Loki changes needed):
    2026-09-17 01:30:00,123 INFO [kestra.task.<flow>.<task>] (<execution>) msg
"""
import base64
import json
import logging
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

logging.basicConfig(
    level=os.environ.get("BRIDGE_LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s [bridge] %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("bridge")

KESTRA_URL = os.environ.get("KESTRA_URL", "http://kestra:8080").rstrip("/")
KESTRA_USERNAME = os.environ.get("KESTRA_USERNAME", "").strip()
KESTRA_PASSWORD = os.environ.get("KESTRA_PASSWORD", "")
KESTRA_API_TOKEN = os.environ.get("KESTRA_API_TOKEN", "").strip()
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "30"))
PAGE_SIZE = int(os.environ.get("PAGE_SIZE", "300"))
MAX_PAGES = int(os.environ.get("MAX_PAGES", "10"))
MAX_TRACKED_KEYS = int(os.environ.get("MAX_TRACKED_KEYS", "20000"))
HEARTBEAT_CYCLES = int(os.environ.get("HEARTBEAT_CYCLES", "12"))
TENANT = os.environ.get("KESTRA_TENANT", "main")


def api(path):
    url = KESTRA_URL + path
    headers = {"Accept": "application/json"}
    if KESTRA_API_TOKEN:
        headers["Authorization"] = f"Bearer {KESTRA_API_TOKEN}"
    elif KESTRA_USERNAME:
        creds = base64.b64encode(f"{KESTRA_USERNAME}:{KESTRA_PASSWORD}".encode()).decode()
        headers["Authorization"] = f"Basic {creds}"
    req = urllib.request.Request(url, method="GET", headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def fetch_logs_page(page):
    qs = urllib.parse.urlencode({"page": page, "size": PAGE_SIZE, "sort": "timestamp:desc"})
    try:
        payload = api(f"/api/v1/{TENANT}/logs/search?{qs}")
    except urllib.error.HTTPError as exc:
        try:
            detail = exc.read().decode("utf-8", errors="replace")[:500]
        except Exception:
            detail = ""
        log.warning("logs search failed: HTTP %s: %s", exc.code, detail)
        return []
    except Exception as exc:
        log.warning("logs search failed: %s", exc)
        return []
    if isinstance(payload, dict):
        for key in ("results", "hits", "content"):
            if isinstance(payload.get(key), list):
                return payload[key]
        return []
    return payload if isinstance(payload, list) else []


def entry_key(entry):
    return (
        str(entry.get("executionId") or ""),
        str(entry.get("taskRunId") or ""),
        str(entry.get("taskId") or ""),
        str(entry.get("attemptNumber") or entry.get("attempt") or ""),
        str(entry.get("timestamp") or ""),
        str(entry.get("message") or "")[:200],
    )


def entry_ts(entry):
    # Kestra returns ISO-8601 Zulu strings; lexicographic == chronological.
    return str(entry.get("timestamp") or "")


def emit(entry):
    level = str(entry.get("level") or "INFO").upper()
    if level not in ("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL", "WARN", "TRACE"):
        level = "INFO"
    if level == "WARN":
        level = "WARNING"
    if level == "TRACE":
        level = "DEBUG"
    flow = entry.get("flowId") or "?"
    task = entry.get("taskId") or "?"
    ts = entry_ts(entry).replace("T", " ")[:23]
    msg = str(entry.get("message") or "").replace("\n", " | ")[:2000]
    # Bypass the bridge logger deliberately: print a real level token so
    # promtail extracts the lvl label.
    print(f"{ts} {level} [kestra.task.{flow}.{task}] (exec={entry.get('executionId') or ''}) {msg}", flush=True)


def main():
    auth = "basic" if KESTRA_USERNAME else ("token" if KESTRA_API_TOKEN else "none")
    log.info("bridge start kestra=%s poll_s=%d page_size=%d auth=%s", KESTRA_URL, POLL_SECONDS, PAGE_SIZE, auth)
    seen = {}  # entry_key -> timestamp string (ordered dict, for bounded prune)
    watermark = ""  # max timestamp shipped so far
    cycle = 0
    while True:
        cycle += 1
        try:
            fresh = []
            stop = False
            for page in range(1, MAX_PAGES + 1):
                entries = fetch_logs_page(page)
                if not entries:
                    break
                for entry in entries:
                    if not isinstance(entry, dict):
                        continue
                    key = entry_key(entry)
                    if key in seen or entry_ts(entry) < watermark:
                        stop = True
                    else:
                        fresh.append(entry)
                if stop:
                    break
            fresh.sort(key=entry_ts)  # oldest-first across the whole batch
            for entry in fresh:
                emit(entry)
                seen[entry_key(entry)] = entry_ts(entry)
            if fresh:
                watermark = max(watermark, max(entry_ts(e) for e in fresh))
                log.info("shipped=%d watermark=%s", len(fresh), watermark)
            elif cycle % HEARTBEAT_CYCLES == 0:
                log.info("heartbeat watermark=%s tracked=%d", watermark, len(seen))
            # Bounded prune: drop keys older than the watermark.
            if len(seen) > MAX_TRACKED_KEYS:
                old = len(seen)
                for key, ts in list(seen.items()):
                    if ts < watermark:
                        del seen[key]
                    if len(seen) <= MAX_TRACKED_KEYS // 2:
                        break
                log.info("pruned tracked keys %d -> %d", old, len(seen))
        except Exception as exc:  # never exit the loop on transient errors
            log.warning("poll cycle failed: %s", exc)
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
