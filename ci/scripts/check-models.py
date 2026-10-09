#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scripts/ci/check-models.py —— 模型权重校验

═══ 为什么需要它 ═══
kubectl diff 只能看见【清单里写了什么】，看不见【路径背后是什么】。所以有两种
情况流水线完全无感：

  ① 你写了一个不存在的 --model= 路径
     → vLLM 加载失败 → rollout status 要等满 900s 才判定失败
     → 这期间（strategy: Recreate）服务是完全 DOWN 的
     → 然后才自动回滚。最坏约 18 分钟中断。

  ② 你把某个模型目录里的权重【就地替换】了（路径没变）
     → kubectl diff 为空 → 流水线判「无需发布」→ 而 vLLM 还跑着旧权重。

这个脚本把这两件事都提前到【预检】阶段暴露，代价只有几秒。

═══ 做什么 ═══
  1. 从 k8s/live/*.yaml 里解析出 Deployment 声明的 --model= 路径
  2. 检查 $MODELS_DIR/<名字>/ 存在，且必需文件齐全
  3. 与 k8s/live/models.lock 里声明的 sha256 指纹比对
     → 权重被就地换掉会在这里被抓出来

═══ 用法 ═══
  python3 scripts/ci/check-models.py            # 校验（precheck.sh 会调它）
  python3 scripts/ci/check-models.py --write    # 重新生成模块指纹清单
  python3 scripts/ci/check-models.py --list     # 只列出声明了哪些模型
  CI_SKIP_MODEL_CHECK=1 ...                     # 跳过（逃生口，见 precheck.sh）
"""
import argparse
import hashlib
import json
import os
import re
import sys

# ── 路径（与 lib.sh 保持一致；可用环境变量覆盖）──
REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
LIVE_DIR = os.environ.get("CI_LIVE_DIR", os.path.join(REPO, "k8s", "live"))
MODELS_DIR = os.environ.get("CI_MODELS_DIR", "/home/user/npc-models")
LOCK_PATH = os.environ.get("CI_MODELS_LOCK", os.path.join(LIVE_DIR, "models.lock"))

# 容器里的挂载点 → 宿主路径的映射（Deployment 把 models-pvc 挂到 /models）
CONTAINER_MOUNT = "/models"

# 必需文件（缺任何一个都起不来）
REQUIRED = ["config.json"]
# 权重文件：至少有一个
WEIGHT_GLOBS = (".safetensors", ".bin", ".pt", ".gguf")
# 参与指纹计算的文件（存在才算；大文件是权重）
FINGERPRINT_EXTRA = ["tokenizer.json", "generation_config.json", "chat_template.jinja"]

CHUNK = 8 * 1024 * 1024


def human(n):
    for u in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.1f} {u}" if u != "B" else f"{n} B"
        n /= 1024
    return f"{n:.1f} TB"


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def declared_models():
    """从 k8s/live/*.yaml 里解析 Deployment 的 --model 与 --served-model-name

    ⚠️ 不要用一条大正则去扫全文 —— 注释里也出现过 --served-model-name，
       会把中文注释当成值吃进去（实测踩过）。逐行解析 + 跳过注释行。

    ⭐ 2026-10-08：支持两种写法。YAML 列表里的参数有两种排版：
       ① 参数和值写在一行（vLLM 那类）
            - "--model=/models/xxx"
            - "--served-model-name=march7v3"
       ② 参数和值分成两行（llama.cpp 那类，因为 --model=PATH 语法它不支持，
          实测报 `error: invalid argument: --model=/nonexistent.gguf`）
            - "--model"
            - "/models/qwen3-asr-1.7b/Qwen3-ASR-1.7B-Q4_K_M.gguf"
       原来只认 ①，所以 llama-asr 加进 k8s/live/ 后 --list 里根本看不到它
       → 模型完全不在预检管辖内（路径写错要等 rollout 900s 超时才暴露）。
    """
    out = []
    if not os.path.isdir(LIVE_DIR):
        return out
    for fn in sorted(os.listdir(LIVE_DIR)):
        if not fn.endswith((".yaml", ".yml")):
            continue
        p = os.path.join(LIVE_DIR, fn)
        found = []          # [{'container_path':…, 'served_as':…}]
        lines = open(p, encoding="utf-8").read().splitlines()

        def next_list_value(start):
            """从 start 行往后找第一个 YAML 列表项的值（`- "xxx"`），没有则 None"""
            for j in range(start, min(start + 4, len(lines))):
                v = lines[j].strip()
                if not v or v.startswith("#"):
                    continue
                mm = re.fullmatch(r'-\s*["\']?(.+?)["\']?', v)
                return mm.group(1) if mm else None
            return None

        for i, raw in enumerate(lines):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            # (?<![\w-]) 保证不会匹配到 --max-model-len 这类
            m = re.search(r'(?<![\w-])--model(?:=|\s+)(\S+)', line)
            if not m and re.fullmatch(r'-\s*["\']?--model["\']?', line):
                # 写法 ②：值在下一行
                v = next_list_value(i + 1)
                if v:
                    found.append({"container_path": v, "served_as": "?"})
                continue
            if m:
                found.append({"container_path": m.group(1).strip('"\''),
                              "served_as": "?"})
                continue
            n = re.search(r'(?<![\w-])--served-model-name(?:=|\s+)(\S+)', line)
            if not n and re.fullmatch(r'-\s*["\']?--served-model-name["\']?', line):
                v = next_list_value(i + 1)
                if v and found and found[-1]["served_as"] == "?":
                    found[-1]["served_as"] = v
                continue
            if n and found and found[-1]["served_as"] == "?":
                found[-1]["served_as"] = n.group(1).strip('"\'')
        for d in found:
            d["file"] = fn
            out.append(d)
    return out


def host_path(container_path):
    """ /models/XXX  →  $MODELS_DIR/XXX

    ⭐ 2026-10-08：--model 指向的东西有两种形态，都要支持：
       · 【目录】vLLM 那类：--model=/models/Qwen3.5-2B-March7-cn
       · 【文件】llama.cpp 那类：--model /models/qwen3-asr-1.7b/xxx.gguf
          （llama.cpp 不支持 --model=PATH，而且它要的是 .gguf 文件不是目录）
       两种都归一成「模型目录」返回 —— 因为指纹计算和必需文件检查都是按目录做的。
       不归一的话，llama-asr 会被判成「目录不存在」而卡住预检（实测踩过）。
    """
    if container_path.startswith(CONTAINER_MOUNT + "/"):
        rel = container_path[len(CONTAINER_MOUNT) + 1:]
    elif container_path.startswith("/"):
        rel = container_path.lstrip("/")
    else:
        rel = container_path
    hp = os.path.join(MODELS_DIR, rel)
    if os.path.isfile(hp):          # 指向文件 → 退到它的目录
        rel = os.path.dirname(rel)
        hp = os.path.dirname(hp)
    return hp, rel


def fingerprint(d):
    """返回 {文件名: {size, sha256}}（只算存在且需要盯的文件）"""
    files = []
    for r in REQUIRED + FINGERPRINT_EXTRA:
        p = os.path.join(d, r)
        if os.path.isfile(p):
            files.append(r)
    for fn in sorted(os.listdir(d)):
        if fn.endswith(WEIGHT_GLOBS):
            files.append(fn)
    # 多分片权重（model-00001-of-00002.safetensors）已经含在上面的后缀匹配里
    res = {}
    for fn in files:
        p = os.path.join(d, fn)
        res[fn] = {"size": os.path.getsize(p), "sha256": sha256(p)}
    return res


def load_lock():
    if not os.path.isfile(LOCK_PATH):
        return None
    try:
        return json.load(open(LOCK_PATH, encoding="utf-8"))
    except Exception as e:
        print(f"  ⚠️ 指纹清单无法解析（{LOCK_PATH}）: {e}")
        return None


def do_list(decls):
    if not decls:
        print("  ❌ k8s/live/ 里没有声明任何 --model=")
        return 1
    for d in decls:
        hp, rel = host_path(d["container_path"])
        print(f"  {d['file']}: 服务名={d['served_as']}  容器路径={d['container_path']}")
        print(f"      宿主路径 = {hp}  {'✅ 存在' if os.path.isdir(hp) else '❌ 不存在'}")
    return 0


def do_write(decls, prune=False):
    """生成/更新指纹清单

    ⭐ 默认【合并】：保留清单里已有的其他模型条目。
       为什么：换模型是高频操作，合并之后
         · 首次使用某个模型 → 改 --model= + --write（记下它）
         · 以后换回来     → 只改 --model= 就行，不用再 --write
         · 而且如果那个模型的权重在你不用它期间被改过，
           换回去时预检会报「内容变了」→ 提醒你重新 --write
       想只保留当前声明的模型，加 --prune。
    """
    old = load_lock() or {}
    models = {} if prune else dict(old.get("models") or {})
    lock = {"_comment": "模型权重指纹清单 —— 由 scripts/ci/check-models.py --write 生成",
            "models_dir": MODELS_DIR, "models": models}
    rc = 0
    for d in decls:
        hp, rel = host_path(d["container_path"])
        if not os.path.isdir(hp):
            print(f"  ❌ {rel}: 目录不存在（{hp}）—— 先确认路径写对了")
            rc = 1
            continue
        fp = fingerprint(hp)
        models[rel] = fp
        print(f"  ✔ {rel}: 记录了 {len(fp)} 个文件")
        for fn, v in sorted(fp.items()):
            print(f"       {fn:28} {human(v['size']):>10}  {v['sha256'][:16]}…")
    if rc == 0:
        with open(LOCK_PATH, "w", encoding="utf-8") as f:
            json.dump(lock, f, ensure_ascii=False, indent=2)
            f.write("\n")
        print(f"\n  ✅ 已写出 {LOCK_PATH}（共 {len(models)} 个模型）")
        if not prune and len(models) > len(decls):
            keep = sorted(set(models) - {host_path(d["container_path"])[1] for d in decls})
            print(f"     合并保留的其它模型: {', '.join(keep)}")
            print(f"     （想只留当前声明的，用 --write --prune）")
        print("     ⚠️ 记得 commit 它 —— 否则下次预检会说「和仓库声明不一致」")
    return rc


def do_check(decls):
    if not decls:
        print("  ❌ k8s/live/ 里没有声明任何 --model= —— 清单是不是被改坏了？")
        return 1

    lock = load_lock()
    fails = []

    for d in decls:
        hp, rel = host_path(d["container_path"])
        print(f"  声明: 服务名={d['served_as']}  容器路径={d['container_path']}")
        print(f"        宿主路径 = {hp}")

        if not os.path.isdir(hp):
            print(f"  ❌ 目录不存在！")
            print(f"     ⇒ 这会让 vLLM 加载失败，rollout 要等满 900s 才判失败，")
            print(f"        而这期间（Recreate 策略）服务是完全 DOWN 的。")
            print(f"     ⇒ 检查：路径拼写、模型是否真的在 {MODELS_DIR} 下、")
            print(f"              agent pod 有没有挂上 {MODELS_DIR}（见 k8s/jenkins-casc.yaml）")
            fails.append(f"{rel}: 目录不存在")
            continue

        # ① 必需文件
        #  ⭐ 2026-10-08：GGUF 模型（llama.cpp 那类）没有 config.json —— 它的
        #     "配置"就写在 GGUF 头部里。所以先看目录里有没有 .gguf：
        #       有 .gguf → 必需文件是那个 .gguf 本身，不再要求 config.json
        #       没有     → 按原来的规矩要 config.json（HF 格式模型）
        #     不这么改的话，任何 llama.cpp 服务一进 k8s/live/ 就会被预检拦下
        #     （实测：`❌ config.json 缺失` → 预检失败 → 发布不了）。
        ggufs = [f for f in sorted(os.listdir(hp)) if f.endswith(".gguf")]
        if ggufs:
            print("  必需文件（GGUF 格式，config.json 在文件头里，不单独存在）:")
            for g in ggufs:
                gp = os.path.join(hp, g)
                print(f"    ✅ {g:44} {human(os.path.getsize(gp))}")
            if not any("mmproj" not in g for g in ggufs):
                print("    ❌ 只有 mmproj（多模态投影），没有主模型 .gguf")
                fails.append(f"{rel}: 只有 mmproj，缺主模型")
        else:
            print("  必需文件:")
            for r in REQUIRED:
                p = os.path.join(hp, r)
                ok = os.path.isfile(p)
                print(f"    {'✅' if ok else '❌'} {r:28} {human(os.path.getsize(p)) if ok else '缺失'}")
                if not ok:
                    fails.append(f"{rel}: 缺 {r}")
        weights = [f for f in sorted(os.listdir(hp)) if f.endswith(WEIGHT_GLOBS)]
        if not weights:
            print(f"    ❌ 没有任何权重文件（{'/'.join(WEIGHT_GLOBS)}）")
            fails.append(f"{rel}: 没有权重文件")
        else:
            for w in weights:
                print(f"    ✅ {w:28} {human(os.path.getsize(os.path.join(hp, w)))}")

        # ② 指纹比对
        if lock is None:
            print("  ⚠️ 没有指纹清单（k8s/live/models.lock）→ 跳过内容比对")
            print("     生成: python3 scripts/ci/check-models.py --write")
            continue
        declared = (lock.get("models") or {}).get(rel)
        if declared is None:
            print(f"  ⚠️ 指纹清单里没有 {rel} → 跳过内容比对")
            print(f"     （换模型后要重新生成: python3 scripts/ci/check-models.py --write）")
            continue

        print("  指纹比对（对照 k8s/live/models.lock）:")
        actual = fingerprint(hp)
        for fn, want in sorted(declared.items()):
            got = actual.get(fn)
            if got is None:
                print(f"    ❌ {fn:28} 清单里有、磁盘上没有")
                fails.append(f"{rel}/{fn}: 文件消失")
            elif got["sha256"] != want["sha256"] or got["size"] != want["size"]:
                print(f"    ❌ {fn:28} 内容变了！")
                print(f"         清单: size={want['size']} sha256={want['sha256'][:16]}…")
                print(f"         实际: size={got['size']} sha256={got['sha256'][:16]}…")
                fails.append(f"{rel}/{fn}: 内容被改动")
            else:
                print(f"    ✅ {fn:28} 匹配（{human(got['size'])}）")
        for fn in sorted(set(actual) - set(declared)):
            print(f"    ⚠️ {fn:28} 磁盘上有、清单里没有（新增文件）")
            fails.append(f"{rel}/{fn}: 多出来的文件")

    print()
    if fails:
        print(f"  ❌ 模型校验不通过（{len(fails)} 项）：")
        for f in fails:
            print(f"     · {f}")
        print()
        print("  ⇒ 如果这是你【有意】换的权重，重新生成指纹并 commit：")
        print("        python3 scripts/ci/check-models.py --write")
        print("        git add k8s/live/models.lock && git commit -m 'chore: 更新模型指纹'")
        print("  ⇒ 如果是误改，把它改回去。")
        return 1

    print("  ✅ 模型校验通过")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", help="生成/更新指纹清单（默认合并，保留其它模型）")
    ap.add_argument("--prune", action="store_true", help="配合 --write：只保留当前声明的模型")
    ap.add_argument("--list", action="store_true", help="只列出声明了哪些模型")
    a = ap.parse_args()

    print(f"  MODELS_DIR = {MODELS_DIR}")
    print(f"  LIVE_DIR   = {LIVE_DIR}")
    print(f"  LOCK       = {LOCK_PATH}")
    print()

    decls = declared_models()
    if a.list:
        return do_list(decls)
    if a.write:
        return do_write(decls, prune=a.prune)
    return do_check(decls)


if __name__ == "__main__":
    sys.exit(main())
