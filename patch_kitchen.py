import glob
import os
import re

# Находим путь к comfy_kitchen динамически под любую версию Python (3.10 или 3.11)
base_search = glob.glob("/usr/local/lib/python3.*/dist-packages/comfy_kitchen")
if not base_search:
    base_search = glob.glob("/usr/lib/python3.*/dist-packages/comfy_kitchen")
base_dir = base_search[0] if base_search else ""

if base_dir and os.path.exists(base_dir):
    print(f"Found comfy_kitchen at: {base_dir}")

    # 1. Исправление типизации list[...]
    files = glob.glob(f"{base_dir}/**/*.py", recursive=True)
    pattern = re.compile(r"\blist\[(int|bool|float|str)\]")

    for file_path in files:
        with open(file_path, "r", encoding="utf-8") as f:
            content = f.read()

        if pattern.search(content):
            content = pattern.sub(r"typing.Sequence[\1]", content)

            if "from __future__ import annotations" in content:
                if "import typing" not in content:
                    content = content.replace(
                        "from __future__ import annotations",
                        "from __future__ import annotations\nimport typing",
                    )
            else:
                if "import typing" not in content:
                    content = "import typing\n" + content

            with open(file_path, "w", encoding="utf-8") as f:
                f.write(content)

    print("comfy_kitchen typing successfully patched!")

    # 2. Полный перехват int8_attention и prequantize в comfy_kitchen (нативный MXFP8 не трогаем)
    kitchen_sage = os.path.join(base_dir, "sage_attention.py")
    if os.path.exists(kitchen_sage):
        with open(kitchen_sage, "r", encoding="utf-8") as f:
            sage_code = f.read()

        attn_override = (
            "def int8_attention(query, key, value, *args, **kwargs):\n"
            "    import torch.nn.functional as F\n"
            "    return F.scaled_dot_product_attention(query, key, value)\n\n"
            "def _orig_int8_attention("
        )

        if "def int8_attention(" in sage_code and "_orig_int8_attention" not in sage_code:
            sage_code = sage_code.replace("def int8_attention(", attn_override)
            print("comfy_kitchen int8_attention redirected to PyTorch SDPA!")

        bypass_func = (
            "def prequantize_int8_attention(q, k, v, *args, **kwargs):\n"
            "    return q, k, v, None, None, None\n\n"
            "def _orig_prequantize_int8_attention("
        )

        if "def prequantize_int8_attention(" in sage_code and "_orig_prequantize_int8_attention" not in sage_code:
            sage_code = sage_code.replace("def prequantize_int8_attention(", bypass_func)
            print("comfy_kitchen prequantize_int8_attention bypassed!")

        with open(kitchen_sage, "w", encoding="utf-8") as f:
            f.write(sage_code)
else:
    print("Warning: comfy_kitchen directory not found during build patch, skipping...")
