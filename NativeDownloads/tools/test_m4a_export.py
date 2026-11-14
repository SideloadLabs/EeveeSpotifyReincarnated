#!/usr/bin/env python3
"""Real Apple AAC/M4A regression tests, inspected independently with ffmpeg."""
import array
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]
class M4AExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="pixie-m4a-")
        cls.work = Path(cls.temp.name)
        cls.binary = cls.work / "m4a-export"
        assert (ROOT / "src/Export/M4AExport.m").exists(), "Native M4A exporter is missing"
        subprocess.run(["clang", "-O2", "-fobjc-arc", "-fblocks", "-Wno-deprecated-declarations", "-I"+str(ROOT/"src/Export"), str(ROOT/"tests/m4a_export.m"), str(ROOT/"src/Export/M4AExport.m"), str(ROOT/"src/Export/OggExport.c"), "-framework", "Foundation", "-framework", "AVFoundation", "-framework", "AudioToolbox", "-framework", "CoreMedia", "-o", str(cls.binary)], check=True)
        cls.source=ROOT/"tests/fixtures/export-tone-10s.ogg"
        cls.cover=cls.work/"cover.jpg"
        subprocess.run(["ffmpeg","-v","error","-f","lavfi","-i","testsrc=size=2048x2048","-frames:v","1",str(cls.cover)],check=True)
    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()
    def convert(self, source, name, mode="", env=None):
        output=self.work/name
        result=subprocess.run([str(self.binary),str(source),str(output),mode,str(self.cover)],capture_output=True,env=env)
        return result,output
    def inspect(self, path):
        return json.loads(subprocess.check_output(["ffprobe","-v","error","-show_format","-show_streams","-of","json",str(path)]))
    def test_genuine_aac_lc_with_unicode_tags_and_jpeg_in_m4a(self):
        result,output=self.convert(self.source,"tone.m4a")
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        info=self.inspect(output); audio=next(s for s in info["streams"] if s["codec_type"]=="audio")
        self.assertEqual(audio["codec_name"],"aac");self.assertEqual(audio["profile"],"LC")
        self.assertEqual(audio["sample_rate"],"44100");self.assertEqual(audio["channels"],2)
        self.assertGreater(int(audio["bit_rate"]),280000)
        self.assertAlmostEqual(float(info["format"]["duration"]),10,delta=.1)
        tags=info["format"]["tags"]
        for key,value in {"title":"Пісня – 日本語","artist":"Виконавець","album":"Альбом","track":"3/12","date":"2026"}.items(): self.assertEqual(tags[key],value)
        extracted=subprocess.check_output(["ffmpeg","-v","error","-i",str(output),"-map","0:v:0","-c","copy","-f","image2pipe","-"])
        self.assertEqual(extracted,self.cover.read_bytes())
        pcm=subprocess.check_output(["ffmpeg","-v","error","-i",str(output),"-map","0:a:0","-f","s16le","-"])
        self.assertGreater(max(abs(v) for v in array.array("h",pcm)),1000)
        self.assertAlmostEqual(len(pcm)/(2*2*44100),10,delta=.05)
    def test_long_unicode_title(self):
        title="Довга назва 日本語 "*200
        result,out=self.convert(self.source,"long.m4a",env={**os.environ,"M4A_EXPORT_TEST_TITLE":title})
        self.assertEqual(result.returncode,0,result.stdout+result.stderr);self.assertEqual(self.inspect(out)["format"]["tags"]["title"],title)
    def test_mono_and_unusual_sample_rates(self):
        for rate in [22050,37800,48000]:
            source=ROOT/f"tests/fixtures/export-mono-{rate}.ogg"
            result,out=self.convert(source,f"mono-{rate}.m4a")
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            audio=next(s for s in self.inspect(out)["streams"] if s["codec_type"]=="audio")
            self.assertEqual(audio["channels"],1);self.assertEqual(audio["sample_rate"],str(rate if rate!=37800 else 44100))
    def test_cancel_cleans_partial_output(self):
        result,out=self.convert(self.source,"cancel.m4a","cancel");self.assertEqual(result.returncode,2);self.assertFalse(out.exists())
        self.assertFalse(list(self.work.glob(".sap-m4a-*")))
    def test_truncation_and_corruption_rejected(self):
        for kind in ["truncated","corrupt"]:
            data=bytearray(self.source.read_bytes())
            if kind=="truncated": del data[-100:]
            else: data[-200]^=64
            source=self.work/(kind+".ogg");source.write_bytes(data)
            result,out=self.convert(source,kind+".m4a");self.assertEqual(result.returncode,3);self.assertFalse(out.exists())
    def test_existing_output_is_preserved(self):
        output=self.work/"existing.m4a";output.write_bytes(b"previous export")
        result,_=self.convert(self.source,output.name);self.assertEqual(result.returncode,7);self.assertEqual(output.read_bytes(),b"previous export")
if __name__=="__main__":unittest.main()
