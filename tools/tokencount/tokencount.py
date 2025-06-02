#!/usr/bin/env python3

import os;
import sys;
import hashlib

script_dir = os.path.dirname(os.path.abspath(__file__))
cache_dir = os.path.join(script_dir, "cache")
os.makedirs(cache_dir, exist_ok=True)
os.environ["TIKTOKEN_CACHE_DIR"] = cache_dir

blobpath = "https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken"
cache_key = hashlib.sha1(blobpath.encode()).hexdigest()

link_path = os.path.join(cache_dir, cache_key)
target_path = "./cl100k_base.tiktoken"

if not os.path.exists(link_path):
  os.symlink(target_path, link_path)

import tiktoken;

print(len(tiktoken.get_encoding('cl100k_base').encode(sys.stdin.read())))
