#!/usr/bin/env python3
"""扫描单个文件里形如 AK/SK 的字面量赋值，输出命中的片段（不含完整值）。

供 framework/tests/provision_test.sh 的「凭据卫生」用例调用。
返回 0 且无输出 = 干净；有输出 = 命中。
"""
import pathlib
import re
import sys

PLACEHOLDERS = {
    "your-ak", "your-sk", "yourkey", "your-key", "placeholder",
    "fake", "xxxx", "test", "changeme", "redacted",
}

# 字段名 + 可选引号 + 分隔符 + 16 位以上的类密钥值
PAT = re.compile(
    r"""(accessKey|secretKey|access_key|secret_key|apiKey|api_key)"""
    r"""["']?\s*[:=]\s*["']?([A-Za-z0-9/+_\-]{16,})""",
    re.IGNORECASE,
)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: scan_secrets.py <file>", file=sys.stderr)
        return 2
    p = pathlib.Path(sys.argv[1])
    if not p.is_file():
        return 0
    hits = []
    for i, line in enumerate(p.read_text(errors="ignore").splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue  # 注释里的示例不算
        for m in PAT.finditer(line):
            val = m.group(2)
            if val.lower() in PLACEHOLDERS:
                continue
            # 只回显掩码，避免把疑似密钥写进日志
            masked = val[:3] + "***" + val[-2:] if len(val) > 6 else "***"
            hits.append(f"L{i} {m.group(1)}={masked}")
    if hits:
        print("; ".join(hits))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
