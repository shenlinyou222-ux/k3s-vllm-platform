#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scripts/ci/bench-jm.py —— jm 命名空间没有性能门槛，直接通过。

保留这个文件是为了让 verify.sh 的 --layer=bench 在 TARGET=jm 时
有一致的入口，而不是特判跳过。
"""
print("jm 服务无性能门槛（jm-downloader / komga 是功能性服务）")
print("✅ bench-jm 跳过")
