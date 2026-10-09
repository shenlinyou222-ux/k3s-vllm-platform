# SPDX-License-Identifier: Apache-2.0
"""cn_mask.py —— 屏蔽裁剪词表里残留的 472 个非中文 token

背景（2026-10-06）：
  模型词表已从 248,320 裁剪到 54,818。裁剪时保留了 merge 祖先闭包
  （+469 个中间产物），否则 BPE 无法从字节构建出中文。

  但闭包里混进了：
    · 472 个 merge 中间产物（解码为 \ufffd 垃圾）
    · 若干单字母（'a' 'e' 'i' 'm' 'n' 'r' 's' 't' 'u' 'y'）
      —— 它们是 system/user/assistant 等模板 token 的祖先，输入需要，
         但输出必须禁止

  所以需要这个 processor 把 472 个 id 的 logit 置为 -inf。

  与原来 chinese_only.py 的区别：
    原来要屏蔽 190,420 个 id（掩码 244 KB，首次启动要枚举 24.8 万 token）
    现在只需屏蔽 472 个 id（名单 5.4 KB，加载即用）

用法：
  --logits-processors cn_mask:CnMask
  名单文件路径由环境变量 CN_BANNED_IDS 指定（默认 /plugins/output_banned_ids.pt）
"""
import os

import torch

from vllm.v1.sample.logits_processor.interface import BatchUpdate, LogitsProcessor


class CnMask(LogitsProcessor):
    """把名单里的 token id 的 logit 置为 -inf"""

    def __init__(self, vllm_config, device, is_pin_memory):
        path = os.environ.get("CN_BANNED_IDS", "/plugins/output_banned_ids.pt")
        banned = torch.load(path, map_location="cpu").long()
        self.banned = banned.to(device)
        self.n_banned = int(banned.numel())
        vocab = vllm_config.model_config.get_vocab_size()
        assert self.banned.max().item() < vocab, (
            f"名单里的 id 超出词表：max={self.banned.max().item()} vocab={vocab}"
        )

    def apply(self, logits: torch.Tensor) -> torch.Tensor:
        logits[..., self.banned] = float("-inf")
        return logits

    def is_argmax_invariant(self) -> bool:
        # 会改变 argmax
        return False

    def update_state(self, batch_update: "BatchUpdate | None") -> None:
        # 无状态
        return None
