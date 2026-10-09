#!/usr/bin/env python3
"""
proxy_mongo.py —— vLLM 审计代理（写入 MongoDB）

架构：
  ① 反向代理 vLLM（记录请求+响应）
  ② 审计数据 → MongoDB（主通道）
  ③ 运维日志 → stdout（kubectl logs）
  ④ 降级：MongoDB 不可用时写本地 JSONL 兜底

MongoDB 文档 schema:
  {
    seq_in_proc, rid, ts, ms, model, temperature, max_tokens, n_messages,
    messages: [{role, content}],
    reply, usage: {prompt_tokens, completion_tokens, total_tokens},
    foreign_chars: [...],   # 违规字符（mask 应该保证为空）
    error, mask_applied
  }
"""
import json, os, sys, time, uuid, threading, re, atexit
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import urllib.request, urllib.error

# ══════════ 配置 ══════════
TARGET = os.environ.get("TARGET", "http://127.0.0.1:8000")
MONGO_URI = os.environ.get("MONGO_URI", "mongodb://mongodb:27017")
MONGO_DB = os.environ.get("MONGO_DB", "vllm_audit")
MONGO_COL = os.environ.get("MONGO_COL", "requests")
FALLBACK_DIR = os.environ.get("FALLBACK_DIR", "/audit")
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "1"))       # 1 = 立即写
FLUSH_SEC = float(os.environ.get("FLUSH_SEC", "2.0"))
RECONNECT_SEC = float(os.environ.get("RECONNECT_SEC", "30"))   # 断连后每多少秒试一次重连

_foreign = re.compile(r'[\u0600-\u06FF\u0400-\u04FF\uAC00-\uD7AF\u3040-\u30FF'
                      r'\u0590-\u05FF\u0E00-\u0E7F\u0900-\u097F\U0001F300-\U0001FAFF]')

# ══════════ MongoDB 连接 ══════════
_mongo = {"client": None, "col": None, "ok": False, "err": None, "last_reconnect": 0.0}
_buf = []
_buf_lock = threading.Lock()
_n = {"i": 0, "written": 0, "failed": 0}   # i 是【进程内】计数，重启归零


def init_mongo():
    try:
        from pymongo import MongoClient, ASCENDING
        c = MongoClient(MONGO_URI, serverSelectionTimeoutMS=5000, connectTimeoutMS=5000)
        c.admin.command("ping")
        col = c[MONGO_DB][MONGO_COL]
        # 索引
        col.create_index([("ts", ASCENDING)])
        col.create_index([("rid", ASCENDING)], unique=True, sparse=True)
        col.create_index([("model", ASCENDING), ("ts", ASCENDING)])
        col.create_index([("ms", ASCENDING)])
        col.create_index([("foreign_chars", ASCENDING)], sparse=True)
        _mongo.update(client=c, col=col, ok=True)
        print(f"[mongo] connected: {MONGO_URI} / {MONGO_DB}.{MONGO_COL}", flush=True)
        print(f"[mongo] indexes ready", flush=True)
        return True
    except Exception as e:
        _mongo["err"] = str(e)
        print(f"[mongo] connect failed: {e}", flush=True)
        print(f"[mongo] fallback → {FALLBACK_DIR}/requests.jsonl", flush=True)
        return False


def write_fallback(rec):
    """MongoDB 不可用时的兜底"""
    try:
        os.makedirs(FALLBACK_DIR, exist_ok=True)
        with open(os.path.join(FALLBACK_DIR, "requests.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception as e:
        print(f"[fallback] err: {e}", flush=True)


def flush_buf():
    """把缓冲写进 MongoDB"""
    with _buf_lock:
        if not _buf:
            return
        batch = list(_buf)
        _buf.clear()
    if not _mongo["ok"]:
        # 周期性重连（2026-10-06 加）：原来只在启动时重试 30 次(300s) 就永久放弃，
        # 之后即使 mongo 恢复也继续写兜底文件，且【不报错】—— 静默降级。
        now = time.time()
        if now - _mongo["last_reconnect"] >= RECONNECT_SEC:
            _mongo["last_reconnect"] = now
            if init_mongo():
                print("[mongo] reconnected (periodic retry)", flush=True)
        if not _mongo["ok"]:
            # 重连【仍然失败】→ 才走兜底
            for r in batch:
                write_fallback(r)
            _n["failed"] += len(batch)
            return
        # 重连【成功】→ 不 return，继续往下走正常写 Mongo（避免这批被误送兜底）
    try:
        _mongo["col"].insert_many(batch, ordered=False)
        _n["written"] += len(batch)
    except Exception as e:
        # 重连一次
        print(f"[mongo] insert failed: {str(e)[:100]}", flush=True)
        if init_mongo():
            try:
                _mongo["col"].insert_many(batch, ordered=False)
                _n["written"] += len(batch)
                return
            except Exception as e2:
                print(f"[mongo] retry failed: {str(e2)[:100]}", flush=True)
        for r in batch:
            write_fallback(r)
        _n["failed"] += len(batch)


def enqueue(rec):
    with _buf_lock:
        _buf.append(rec)
        n = len(_buf)
    if n >= BATCH_SIZE:
        flush_buf()


def _flusher():
    while True:
        time.sleep(FLUSH_SEC)
        flush_buf()


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _p(self, method):
        ln = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(ln) if ln else b""
        rid = uuid.uuid4().hex[:12]
        rj = None
        if body:
            try:
                rj = json.loads(body)
            except Exception:
                pass

        t0 = time.time()
        hdrs = {k: v for k, v in self.headers.items()
                if k.lower() not in ("host", "content-length", "connection")}
        hdrs["Content-Length"] = str(len(body))
        # ★ 关联键（2026-10-06 加）：把我们的 rid 作为 X-Request-Id 转发给 vLLM。
        #   vLLM 会把它包成 "chatcmpl-<rid>" 打进容器日志：
        #     [request_logger.py:63] Received request chatcmpl-<rid>: params: ...
        #   于是 vLLM 日志与审计记录（rec.rid）可以【精确】互查，不用猜时间戳。
        #   依据：vllm/entrypoints/serve/middleware/x_request_id.py:34
        #   实测：传 X-Request-Id: my-custom-rid-123 → 日志出现 chatcmpl-my-custom-rid-123
        #   注意：客户端若自带 X-Request-Id 会被这里覆盖（urllib 会把键规范化，
        #         同名键后写入者胜出），这正是我们要的确定性。
        hdrs["X-Request-Id"] = rid
        req = urllib.request.Request(TARGET + self.path, data=body or None,
                                     headers=hdrs, method=method)
        try:
            with urllib.request.urlopen(req, timeout=600) as r:
                rb, st, rh = r.read(), r.status, dict(r.headers)
        except urllib.error.HTTPError as e:
            rb, st, rh = e.read(), e.code, dict(e.headers)
        except Exception as e:
            rb, st, rh = json.dumps({"error": str(e)}).encode(), 502, {"Content-Type": "application/json"}
        dt = round((time.time() - t0) * 1000)
        try:
            rj2 = json.loads(rb)
        except Exception:
            rj2 = None

        if rj and "messages" in rj:
            _n["i"] += 1
            seq = _n["i"]        # 进程内序号；重启从 1 重来，【不是】唯一键（排序请用 ts_epoch）
            rec = {
                "seq_in_proc": seq,
                "rid": rid,
                "ts": time.strftime("%Y-%m-%d %H:%M:%S"),
                "ts_epoch": time.time(),
                "ms": dt,
                "model": rj.get("model"),
                "temperature": rj.get("temperature"),
                "max_tokens": rj.get("max_tokens"),
                "n_messages": len(rj["messages"]),
                "messages": rj["messages"],
                "client": self.headers.get("User-Agent", "")[:120],
            }
            # 把 vLLM 侧的请求 id 也存进审计记录（就是日志里那个 chatcmpl-xxx）。
            # 这样两个方向都能查：DB 里搜 rid 拿到 vllm_req_id → 去日志 grep；
            # 或在日志里看到 chatcmpl-xxx → 回 DB 搜 vllm_req_id。
            if rj2:
                rec["vllm_req_id"] = rj2.get("id")
            if rj2 and "choices" in rj2:
                rep = rj2["choices"][0]["message"]["content"]
                rec["reply"] = rep
                rec["reply_len"] = len(rep)
                rec["finish_reason"] = rj2["choices"][0].get("finish_reason")
                rec["usage"] = rj2.get("usage")
                f = _foreign.findall(rep)
                if f:
                    rec["foreign_chars"] = f
                    print(f"[{seq:>5}] {rid} {dt:>5}ms ⚠️ 外来字符 {f}", flush=True)
                else:
                    print(f"[{seq:>5}] {rid} {dt:>5}ms {len(rj['messages'])}msgs → {rep[:44]}", flush=True)
            elif rj2 and "error" in rj2:
                rec["error"] = str(rj2["error"])[:500]
                print(f"[{seq:>5}] {rid} {dt:>5}ms ❌ {rec['error'][:70]}", flush=True)
            enqueue(rec)

        self.send_response(st)
        for k, v in rh.items():
            if k.lower() in ("content-length", "transfer-encoding", "connection"):
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(rb)))
        self.end_headers()
        self.wfile.write(rb)

    def do_POST(self):
        self._p("POST")

    def do_GET(self):
        self._p("GET")


def shutdown():
    flush_buf()
    if _mongo["ok"]:
        try:
            _mongo["client"].close()
        except Exception:
            pass
    print(f"[shutdown] written={_n['written']} failed={_n['failed']}", flush=True)


if __name__ == "__main__":
    atexit.register(shutdown)
    print(f"proxy: 0.0.0.0:8001 → {TARGET}", flush=True)
    ok = init_mongo()
    if not ok:
        # 后台重试
        def retry():
            for i in range(30):
                time.sleep(10)
                if init_mongo():
                    print(f"[mongo] reconnected after {(i+1)*10}s", flush=True)
                    return
        threading.Thread(target=retry, daemon=True).start()
    threading.Thread(target=_flusher, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", 8001), H).serve_forever()
