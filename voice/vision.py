# ============================================================================
#  vision.py — 本地 Qwen2.5-VL 看图片
#  用法：python vision.py --image shot.png --prompt "描述这个画面" --out r.json
# ============================================================================
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
QV = os.path.join(HERE, 'models', 'qwen-vl')
LLAMA = os.path.join(QV, 'llama', 'llama-mtmd-cli.exe')
MODEL = os.path.join(QV, 'Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf')
MMPROJ = os.path.join(QV, 'mmproj-F16.gguf')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--image', required=True)
    ap.add_argument('--prompt', default='请用简洁的中文描述这张图片的内容。')
    ap.add_argument('--out', required=True)
    ap.add_argument('--n', type=int, default=256)
    ap.add_argument('--timeout', type=int, default=180)
    args = ap.parse_args()

    payload = {'ok': False, 'seconds': 0, 'text': ''}
    start = time.time()
    try:
        for p in (LLAMA, MODEL, MMPROJ):
            if not os.path.exists(p):
                raise RuntimeError('缺少文件：' + p)
        cmd = [
            LLAMA, '-m', MODEL, '--mmproj', MMPROJ,
            '--image', args.image, '-p', args.prompt,
            '-n', str(args.n), '--temp', '0.2', '-ngl', '99',
            '--no-warmup', '--log-disable',
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True,
                              encoding='utf-8', errors='replace',
                              timeout=args.timeout)
        out = (proc.stdout or '').strip()
        err = (proc.stderr or '').strip()
        if out:
            payload['ok'] = True
            payload['text'] = out
        else:
            payload['error'] = err[-800:] or ('exit ' + str(proc.returncode))
    except Exception as exc:
        payload['error'] = str(exc)
    payload['seconds'] = round(time.time() - start, 1)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, 'w', encoding='utf-8') as f:
        json.dump(payload, f, ensure_ascii=False)


if __name__ == '__main__':
    main()
