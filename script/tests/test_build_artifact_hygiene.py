"""Regression checks for preventing Spotlight-visible SwiftShot build copies."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BuildArtifactHygieneTests(unittest.TestCase):
    def test_project_policy_names_the_single_canonical_app(self):
        policy = (ROOT / "AGENTS.md").read_text()
        self.assertIn("/Applications/SwiftShot.app", policy)
        self.assertIn("ending in `.noindex`", policy)
        self.assertIn("Do not leave `SwiftShot.app` in `dist/`", policy)

    def test_session_instructions_use_the_guarded_build_script(self):
        instructions = (ROOT / "SKILLS.md").read_text()
        self.assertIn("./script/build_and_run.sh --build", instructions)
        self.assertNotIn("-derivedDataPath build clean build", instructions)
        self.assertNotIn("cp -R build/Build/Products/Release/SwiftShot.app dist/", instructions)

    def test_release_script_uses_noindex_and_removes_disposable_product(self):
        script = (ROOT / "script" / "build_and_run.sh").read_text()
        self.assertIn('DERIVED_DATA="$ROOT_DIR/build/release.noindex"', script)
        self.assertIn('"$LSREGISTER" -u "$PRODUCT"', script)
        self.assertIn('rm -rf "$PRODUCT"', script)


if __name__ == "__main__":
    unittest.main()
