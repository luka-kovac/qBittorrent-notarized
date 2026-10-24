import importlib.util
from pathlib import Path
import tempfile
import unittest


script = Path(__file__).resolve().parents[1] / "scripts" / "prepare_release_assets.py"
spec = importlib.util.spec_from_file_location("release_assets", script)
release_assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_assets)


class ReleaseAssetsTest(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.source = self.root / "artifacts"
        self.destination = self.root / "dist"

    def dmg(self, gui="ON", libtorrent="1.2.20", qt="6.10.3"):
        directory = self.source / f"qBittorrent-CI_macOS_GUI={gui}_libtorrent-{libtorrent}_Qt-{qt}"
        directory.mkdir(parents=True, exist_ok=True)
        product = "qbittorrent" if gui == "ON" else "qbittorrent-nox"
        dmg = directory / f"{product}.dmg"
        dmg.write_text(f"{gui}/{libtorrent}/{qt}")
        return dmg

    def prepare(self):
        return release_assets.prepare_assets(self.source, self.destination, "5.3.0")

    def test_current_six_variants_have_upstream_style_names_and_keep_their_contents(self):
        for gui in ("ON", "OFF"):
            for version in ("1.2.20", "2.0.15", "2.1.2"):
                self.dmg(gui, version)
        assets = self.prepare()
        expected = {
            f"{product}-5.3.0{suffix}_notarized.dmg"
            for product in ("qbittorrent", "qbittorrent-nox")
            for suffix in ("", "_lt20", "_lt21")
        }
        self.assertEqual(expected, {asset.name for asset in assets})
        self.assertEqual("ON/2.0.15/6.10.3", (self.destination / "qbittorrent-5.3.0_lt20_notarized.dmg").read_text())
        self.assertEqual("OFF/1.2.20/6.10.3", (self.destination / "qbittorrent-nox-5.3.0_notarized.dmg").read_text())

    def test_additional_qt_versions_remain_distinct(self):
        self.dmg(qt="6.10.3")
        self.dmg(qt="6.11.0")
        self.assertEqual({"qbittorrent-5.3.0_qt6.10.3_notarized.dmg", "qbittorrent-5.3.0_qt6.11.0_notarized.dmg"}, {asset.name for asset in self.prepare()})

    def test_additional_libtorrent_patch_versions_remain_distinct(self):
        self.dmg(libtorrent="2.0.15")
        self.dmg(libtorrent="2.0.16")
        self.assertEqual({"qbittorrent-5.3.0_lt2.0.15_notarized.dmg", "qbittorrent-5.3.0_lt2.0.16_notarized.dmg"}, {asset.name for asset in self.prepare()})

    def test_existing_assets_are_not_overwritten(self):
        self.dmg()
        self.destination.mkdir()
        existing = self.destination / "qbittorrent-5.3.0_notarized.dmg"
        existing.write_text("existing release")
        with self.assertRaisesRegex(ValueError, "overwrite"):
            self.prepare()
        self.assertEqual("existing release", existing.read_text())

    def test_missing_or_unknown_artifacts_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "No DMG"):
            self.prepare()
        self.source.mkdir()
        (self.source / "unexpected.dmg").write_text("unknown")
        with self.assertRaisesRegex(ValueError, "Unrecognized"):
            self.prepare()

    def test_mismatched_gui_and_dmg_are_rejected(self):
        dmg = self.dmg()
        dmg.rename(dmg.with_name("qbittorrent-nox.dmg"))
        with self.assertRaisesRegex(ValueError, "Unexpected DMG"):
            self.prepare()


if __name__ == "__main__":
    unittest.main()
