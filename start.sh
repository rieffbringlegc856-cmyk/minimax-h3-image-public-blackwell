#!/bin/bash

echo "=== Setting up models directory ==="

if [ -d "/runpod-volume/ComfyUI/models" ]; then
    echo "Found models in /runpod-volume/ComfyUI/models. Creating symlink..."
    rm -rf /workspace/ComfyUI/models
    ln -s /runpod-volume/ComfyUI/models /workspace/ComfyUI/models
elif [ -d "/runpod-volume/models" ]; then
    echo "Found models in /runpod-volume/models. Creating symlink..."
    rm -rf /workspace/ComfyUI/models
    ln -s /runpod-volume/models /workspace/ComfyUI/models
else
    echo "WARNING: Models directory not found in /runpod-volume!"
fi

echo "Models linked status:"
ls -la /workspace/ComfyUI/models || true

# Автоопределение архитектуры GPU (sm89 Ada, sm90 Hopper, sm120 Blackwell)
GPU_ARCH=$(python3 -c 'import torch; c=torch.cuda.get_device_capability(); print(f"{c[0]}.{c[1]}")' 2>/dev/null || echo "12.0")
GPU_SM=$(echo "$GPU_ARCH" | tr -d '.')

export TORCH_CUDA_ARCH_LIST="8.9;9.0;12.0"
export CUDA_ARCH="$GPU_SM"
export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"

echo "Detected GPU Architecture: $GPU_ARCH (sm${GPU_SM})"

python3 -c "
path = '/workspace/ComfyUI/custom_nodes/ComfyUI-KJNodes/nodes/ltxv_nodes.py'
try:
    with open(path, 'r', encoding='utf-8') as f:
        code = f.read()
    code = code.replace('if _cuda_archs is None:', 'if False:')
    code = code.replace('_cuda_archs[0]', '\"sm${GPU_SM}\"')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(code)
    print('Successfully patched Kijai SageAttention for sm${GPU_SM}!')
except Exception as e:
    print(f'Patch warning: {e}')
" || true

# Безопасный обход int8_attention в comfy_kitchen на нативный PyTorch SDPA
python3 -c '
kitchen_sage = "/usr/local/lib/python3.11/dist-packages/comfy_kitchen/sage_attention.py"
try:
    with open(kitchen_sage, "r", encoding="utf-8") as f:
        code = f.read()

    attn_override = (
        "def int8_attention(query, key, value, *args, **kwargs):\n"
        "    import torch.nn.functional as F\n"
        "    return F.scaled_dot_product_attention(query, key, value)\n\n"
        "def _orig_int8_attention("
    )

    if "def int8_attention(" in code and "_orig_int8_attention" not in code:
        code = code.replace("def int8_attention(", attn_override)
        print("Successfully bypassed int8_attention to PyTorch SDPA in start.sh!")

    with open(kitchen_sage, "w", encoding="utf-8") as f:
        f.write(code)
except Exception as e:
    print(f"Kitchen Sage patch warning: {e}")
' || true

# Запуск ComfyUI в фоне (96GB VRAM Blackwell позволяет держать все модели без выгрузки)
cd /workspace/ComfyUI
python -u main.py --listen 127.0.0.1 --port 8188 > /workspace/comfyui.log 2>&1 &
COMFY_PID=$!

echo "Waiting for ComfyUI and custom nodes to initialize (PID: $COMFY_PID)..."
while true; do
    if ! kill -0 $COMFY_PID 2>/dev/null; then
        echo "=========================================="
        echo "ERROR: ComfyUI crashed! Dumping log:"
        echo "=========================================="
        cat /workspace/comfyui.log
        echo "=========================================="
        sleep 60
        exit 1
    fi

    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8188/object_info/easy%20seed")
    if [ "$STATUS" -eq 200 ]; then
        echo "ComfyUI and ComfyUI-Easy-Use are fully loaded and ready on sm${GPU_SM}!"
        break
    fi
    sleep 2
done

# Выводим в консоль предупреждения и ошибки импорта кастомных нод
echo "=== Checking ComfyUI log for custom node errors ==="
grep -iE "error|failed|cannot import|traceback" /workspace/comfyui.log || echo "No critical import errors found."
echo "==================================================="

# Запуск RunPod Serverless Handler
python -u rp_handler.py
