# SPDX-License-Identifier: Apache-2.0
"""
ChineseOnlyLogitsProcessor —— 强制 mask 非中文字符的 logits

原理：
  · 启动时枚举词表，标记【解码后全由合法字符组成】的 token
  · 每次前向时把非法 token 的 logits 设为 -inf
  · 对所有请求全局生效

合法字符：中文 / 中文标点 / 全角 / 数字 / 常用符号 / 空白
禁止：英文字母 / 阿拉伯文 / 韩文 / 日文假名 / emoji / 其他语言
"""
import os, json, logging

import torch

from vllm.v1.sample.logits_processor.interface import BatchUpdate, LogitsProcessor

logger = logging.getLogger("chinese_only_lp")

# ══════════ 字符白名单 ══════════
ALLOW_RANGES = [
    (0x0020, 0x007E),   # ASCII 可打印（后面会排除字母）
    (0x2000, 0x206F),   # 常用标点
    (0x2160, 0x217F),   # 罗马数字
    (0x2460, 0x24FF),   # 带圈数字
    (0x2605, 0x2606),   # ★☆
    (0x3000, 0x303F),   # CJK 标点
    (0x3400, 0x4DBF),   # CJK 扩展A
    (0x4E00, 0x9FFF),   # CJK 统一表意
    (0xF900, 0xFAFF),   # CJK 兼容
    (0xFE30, 0xFE4F),   # CJK 兼容形式
    (0xFF00, 0xFFEF),   # 全角
    (0x00B7, 0x00B7),   # ·
]
ALLOW_CHARS = set("，。！？、；：…—～·「」『』（）《》〈〉【】“”‘’ \n")

# 排除的区间（优先级最高）
DENY_RANGES = [
    (0x0041, 0x005A),   # A-Z
    (0x0061, 0x007A),   # a-z
    (0x0600, 0x06FF),   # 阿拉伯文
    (0x0750, 0x077F),
    (0x0400, 0x04FF),   # 西里尔文
    (0x0500, 0x052F),
    (0x0590, 0x05FF),   # 希伯来文
    (0x0900, 0x097F),   # 天城文
    (0x0E00, 0x0E7F),   # 泰文
    (0x1100, 0x11FF),   # 韩文字母
    (0x3040, 0x309F),   # 平假名
    (0x30A0, 0x30FF),   # 片假名
    (0xAC00, 0xD7AF),   # 韩文音节
    (0x1F000, 0x1FAFF), # emoji / 符号
    (0x1F300, 0x1F5FF),
    (0x1F600, 0x1F64F),
    (0x1F680, 0x1F6FF),
    (0x1F900, 0x1F9FF),
]

def _is_denied(o):
    for lo, hi in DENY_RANGES:
        if lo <= o <= hi:
            return True
    return False

def _is_allowed(o):
    if o in (0x0A, 0x20):
        return True
    for lo, hi in ALLOW_RANGES:
        if lo <= o <= hi:
            return True
    return False

def _ok_char(ch):
    o = ord(ch)
    if ch in ALLOW_CHARS:
        return True
    if _is_denied(o):
        return False
    return _is_allowed(o)


class ChineseOnlyLogitsProcessor(LogitsProcessor):
    """全局 mask：只允许中文字符集"""

    def __init__(self, vllm_config, device, is_pin_memory):
        self.device = device
        model_path = vllm_config.model_config.model
        cache_path = "/cache/allowed_tokens.pt"

        allowed = None
        if os.path.exists(cache_path):
            try:
                allowed = torch.load(cache_path, map_location="cpu")
                logger.info("ChineseOnlyLP: loaded cache (%d allowed)", int(allowed.sum()))
            except Exception as e:
                logger.warning("ChineseOnlyLP: cache load failed: %s", e)

        if allowed is None:
            from transformers import AutoTokenizer
            tok = AutoTokenizer.from_pretrained(model_path, trust_remote_code=True)
            vocab = len(tok)
            allowed = torch.zeros(vocab, dtype=torch.bool)
            n_ok = 0
            for tid in range(vocab):
                try:
                    s = tok.decode([tid])
                except Exception:
                    continue
                if not s:
                    continue
                # 特殊 token 保留
                if s.startswith("<|") and s.endswith("|>"):
                    allowed[tid] = True
                    n_ok += 1
                    continue
                if all(_ok_char(c) for c in s):
                    allowed[tid] = True
                    n_ok += 1
            logger.info("ChineseOnlyLP: built mask %d/%d allowed", n_ok, vocab)
            try:
                os.makedirs(os.path.dirname(cache_path), exist_ok=True)
                torch.save(allowed, cache_path)
            except Exception as e:
                logger.warning("ChineseOnlyLP: cache save failed: %s", e)

        self.allowed = allowed.to(device)
        self.banned = ~self.allowed
        self.n_banned = int(self.banned.sum())
        logger.info("ChineseOnlyLP: ready, banned=%d", self.n_banned)

    def apply(self, logits: torch.Tensor) -> torch.Tensor:
        """mask 非法 token 的 logits。

        注意：模型 vocab（248320）可能大于 tokenizer vocab（248077），
        超出的 padding 位也必须屏蔽。
        """
        V = logits.shape[-1]
        if self.banned.numel() < V:
            pad = torch.ones(V - self.banned.numel(), dtype=torch.bool,
                             device=logits.device)
            banned = torch.cat([self.banned, pad])
        elif self.banned.numel() > V:
            banned = self.banned[:V]
        else:
            banned = self.banned
        logits[..., banned] = float("-inf")
        return logits

    def is_argmax_invariant(self) -> bool:
        # 会改变 argmax（屏蔽了部分 token）
        return False

    def update_state(self, batch_update: "BatchUpdate | None") -> None:
        # 无状态
        return None
