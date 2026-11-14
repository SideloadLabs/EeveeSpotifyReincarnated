"""Host tests execute native packaging and validate ZIP with an independent reader."""
import pathlib, subprocess, tempfile, unittest, zipfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
class OfflineLibraryPackageTests(unittest.TestCase):
    def test_native_snapshot_and_zip(self):
        source=ROOT/'src/Library/OfflineLibraryPackage.m'
        self.assertTrue(source.exists(), 'Native offline package implementation is missing')
        with tempfile.TemporaryDirectory(prefix='offline-package-host-') as temp:
            temp=pathlib.Path(temp); executable=temp/'package-test'; archive=temp/'library.zip'; single=temp/'single.zip'
            subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-Wno-unused-parameter','-I'+str(source.parent),str(ROOT/'tests/offline_library_package.m'),str(source),'-framework','Foundation','-lz','-o',str(executable)],check=True)
            subprocess.run([str(executable),str(archive),str(single)],check=True)
            with zipfile.ZipFile(archive) as z:
                self.assertIsNone(z.testzip())
                self.assertEqual(len(z.infolist()),4)
                self.assertIn('Björk/Albums/作品/Intro.m4a',z.namelist())
                for entry in z.infolist():
                    self.assertTrue(entry.flag_bits&0x800)
                    self.assertEqual(entry.compress_type,zipfile.ZIP_STORED)
                    self.assertEqual(z.read(entry),b'fake M4A / Ogg bytes are retained, not transcoded')
            with zipfile.ZipFile(single) as z:
                self.assertIsNone(z.testzip())
                self.assertEqual(z.namelist(), ['First.m4a', 'Second.ogg'])
                for entry in z.infolist():
                    self.assertEqual(z.read(entry), b'fake M4A / Ogg bytes are retained, not transcoded')
    def test_sandboxed_source_access(self):
        with tempfile.TemporaryDirectory(prefix='offline-sandbox-host-') as temp:
            executable=pathlib.Path(temp)/'sandbox-test'
            subprocess.run(['xcrun','clang','-fobjc-arc','-Wno-deprecated-declarations','-DNSHomeDirectory=SAPFixtureHome','-I'+str(ROOT/'src/Library'),str(ROOT/'tests/offline_library_sandbox.m'),str(ROOT/'src/Library/OfflineLibraryPackage.m'),'-framework','Foundation','-lz','-o',str(executable)],check=True)
            subprocess.run([str(executable)],check=True)
    def test_zip64_entry_count(self):
        with tempfile.TemporaryDirectory(prefix='offline-zip64-host-') as temp:
            temp=pathlib.Path(temp); executable=temp/'zip64-test'; archive=temp/'many.zip'
            subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror',str(ROOT/'tests/offline_library_zip64.m'),'-framework','Foundation','-lz','-o',str(executable)],check=True)
            subprocess.run([str(executable),str(archive)],check=True)
            with zipfile.ZipFile(archive) as z:
                self.assertEqual(len(z.infolist()),65536)
                self.assertEqual(z.read(z.infolist()[0]),b'')
                self.assertEqual(z.read(z.infolist()[-1]),b'')
                self.assertIsNone(z.testzip())
if __name__=='__main__':unittest.main()
