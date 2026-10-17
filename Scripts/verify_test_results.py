#!/usr/bin/env python3
"""Independent ZIP CRC, WAV headers, exact timing log and exported manifest validation."""
from pathlib import Path
import json, zipfile, wave
base=Path(__file__).resolve().parent.parent/'work/test-results'
with zipfile.ZipFile(base/'verified-session.zip') as z:
    assert z.testzip() is None, 'ZIP CRC failure'
    metadata=json.loads(z.read(next(n for n in z.namelist() if n.endswith('/metadata.json'))))
    assert metadata['system_audio']['duration_seconds'] > 600
    assert metadata['microphone_audio']['duration_seconds'] > 600
    for n in z.namelist():
        if n.endswith('.wav'):
            with z.open(n) as stream, wave.open(stream) as wav:
                assert wav.getsampwidth()==2
                assert wav.getnframes()>0
        elif n.endswith('.jsonl'):
            for line in z.read(n).splitlines(): json.loads(line)
    records=[json.loads(line) for line in z.read(next(n for n in z.namelist() if n.endswith('/timestamps.jsonl'))).splitlines()]
    totals={stream: sum(r['frame_count'] for r in records if r['stream']==stream) for stream in ['system','microphone','video']}
    assert totals['system']==metadata['system_audio']['written_frames']
    assert totals['microphone']==metadata['microphone_audio']['written_frames']
    assert totals['video']==metadata['video']['written_frames']
    for stream in ['system','microphone']:
        next_offset={}
        for row in (r for r in records if r['stream']==stream):
            assert row['file_frame_offset']==next_offset.get(row['filename'],0)
            next_offset[row['filename']]=row['file_frame_offset']+row['frame_count']
    print(f"PASS: independent Python ZIP CRC / PCM16 WAV / JSONL / exact sample offsets ({len(records)} timing records)")
