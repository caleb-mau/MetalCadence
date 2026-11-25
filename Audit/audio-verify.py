#!/usr/bin/env python3
"""Verify that virtual capture PCM packets reproduce the recorded stereo track.
Does not claim physical speaker/display synchronization."""
from array import array
from pathlib import Path
import mmap, struct, time, math
base=Path.home()/"Library/Application Support/MetalCadence"
pcm=array('f')
with (base/"replay.f32").open("rb") as f:pcm.frombytes(f.read())
n=len(pcm)//2
assert n>48000
left=pcm[::2];right=pcm[1::2]
start=min(5*48000,n//2);end=min(start+48000,n)
rms=lambda xs:math.sqrt(sum(x*x for x in xs)/max(1,len(xs)))
a=left[start:end];b=right[start:end]
print(f"STEREO 48k samples={n}, midtrack left RMS={rms(a):.5f}, right RMS={rms(b):.5f}, channel_difference_RMS={rms([x-y for x,y in zip(a,b)]):.5f}")
path=base/"capture.ring"
if not path.exists():raise SystemExit("No live capture ring; soundtrack verified from recording, live packet test skipped")
VC_BYTES=1920*1080*3//2
SLOT_BYTES=((36+800*2*4+VC_BYTES+7)//8)*8
with path.open('rb') as f:
 with mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ) as memory:
  matches=[]
  for attempt in range(20):
   latest=struct.unpack_from('Q',memory,8)[0]
   if latest<2:time.sleep(.02);continue
   offset=32+(latest%8)*SLOT_BYTES
   stamp,pts,arrival,tick,frames=struct.unpack_from('QddQI',memory,offset)
   if stamp != 2*latest or frames!=800:time.sleep(.02);continue
   received=array('f');received.frombytes(memory[offset+36:offset+36+800*8])
   nextstamp=struct.unpack_from('Q',memory,offset)[0]
   if stamp!=nextstamp:continue
   maxerr=max(abs(received[2*i+k]-pcm[2*((tick*800+i)%n)+k]) for i in (0,1,16,73,300,799) for k in (0,1))
   matches.append(maxerr)
   time.sleep(.03)
  if matches:
   print(f"LIVE PCM tick samples={len(matches)} max_error={max(matches):.9f}; same capture media clock for NV12 and audio timestamps")
   assert max(matches)<1e-7
  else:
   print("Live packet check unavailable; no stable ring packets observed")
