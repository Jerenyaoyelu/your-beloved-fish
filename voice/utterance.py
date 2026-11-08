# ============================================================================
#  utterance.py — 录音（VAD 自动断句）+ Whisper 转写
#  用法：
#    python utterance.py --out result.json [--wait 20] [--max 60] [--wav input.wav]
#  输出：{"text": "...", "seconds": 3.2, "ok": true}
# ============================================================================
import argparse
import json
import os
import sys
import time
import wave

import numpy as np
import zhconv

os.environ.setdefault('HF_HUB_OFFLINE', '1')
os.environ.setdefault('HF_ENDPOINT', 'https://hf-mirror.com')

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MODEL_DIR = os.path.join(HERE, 'models', 'whisper')
LAST = {'peak': 0.0, 'threshold': 0.0}


def write_result(path, payload):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(payload, f, ensure_ascii=False)


def record_utterance(path, wait_seconds=20, max_seconds=60, silence_ms=1800):
    import sounddevice as sd

    rate = 16000
    block = 480  # 30ms
    silence_blocks = int(silence_ms / 30)
    max_blocks = int(max_seconds * 1000 / 30)
    wait_blocks = int(wait_seconds * 1000 / 30)
    preroll = 10

    q = []
    noise = 300.0
    speaking = False
    peak = 0.0
    silent_run = 0
    speech_blocks = 0
    frames = []
    total = 0

    def rms(chunk):
        arr = np.frombuffer(chunk, dtype=np.int16).astype(np.float32)
        return float(np.sqrt(np.mean(arr * arr))) if arr.size else 0.0

    stream = sd.RawInputStream(samplerate=rate, blocksize=block, dtype='int16', channels=1)
    stream.start()
    try:
        import winsound
        winsound.Beep(880, 120)
    except Exception:
        pass
    try:
        levels = []
        for _ in range(10):
            data, _ = stream.read(block)
            q.append(bytes(data))
            levels.append(rms(bytes(data)))
        noise = float(np.median(levels)) if levels else 300.0
        threshold = min(max(noise * 2.5, 350.0), 1000.0)

        while total < max_blocks:
            data, _ = stream.read(block)
            chunk = bytes(data)
            q.append(chunk)
            if len(q) > preroll:
                q.pop(0)
            total += 1
            level = rms(chunk)
            peak = max(peak, level)

            if not speaking:
                if level > threshold:
                    speech_blocks += 1
                    if speech_blocks >= 3:
                        speaking = True
                        silent_run = 0
                        frames = list(q)
                elif total > wait_blocks:
                    break  # 等太久没人说话
            else:
                frames.append(chunk)
                if level > threshold:
                    silent_run = 0
                else:
                    silent_run += 1
                    if silent_run >= silence_blocks:
                        break
    finally:
        stream.stop()
        stream.close()

    LAST['peak'] = round(peak, 1)
    LAST['threshold'] = round(threshold, 1)
    if not speaking or not frames:
        return 0.0

    with wave.open(path, 'wb') as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        wf.writeframes(b''.join(frames))
    return len(frames) * block / rate


def transcribe(wav_path, model_size, model_dir, device='cpu'):
    from faster_whisper import WhisperModel
    model = WhisperModel(model_size, device='cpu', compute_type='int8')
    segments, info = model.transcribe(
        wav_path, language='zh', beam_size=5,
        vad_filter=False, condition_on_previous_text=False)
    text = ''.join(s.text for s in segments).strip()
    return zhconv.convert(text, 'zh-cn')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    ap.add_argument('--wav', default='')
    ap.add_argument('--wait', type=int, default=20)
    ap.add_argument('--max', type=int, default=60)
    ap.add_argument('--model', default='small')
    ap.add_argument('--model-dir', default=DEFAULT_MODEL_DIR)
    ap.add_argument('--device', default='cpu')
    ap.add_argument('--silence-ms', type=int, default=1800)
    args = ap.parse_args()

    tmp_wav = args.wav
    created = False
    try:
        if not tmp_wav:
            tmp_wav = os.path.join(os.path.dirname(args.out), 'utterance.wav')
            seconds = record_utterance(tmp_wav, args.wait, args.max, args.silence_ms)
            created = True
            if seconds <= 0:
                write_result(args.out, {'ok': True, 'text': '', 'seconds': 0, 'reason': 'no_speech', 'peak': LAST['peak'], 'threshold': LAST['threshold']})
                return
        print('transcribing', tmp_wav, flush=True)
        text = transcribe(tmp_wav, args.model, args.model_dir, args.device)
        print('done', flush=True)
        write_result(args.out, {'ok': True, 'text': text, 'seconds': 0})
    except Exception as exc:
        write_result(args.out, {'ok': False, 'text': '', 'error': str(exc)})
    finally:
        if created and os.path.exists(tmp_wav):
            try:
                os.remove(tmp_wav)
            except OSError:
                pass


if __name__ == '__main__':
    main()
