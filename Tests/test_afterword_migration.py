import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("migration", Path(__file__).resolve().parents[1] / "Scripts/migrate-afterword-data.py")
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.pairs = []
        for folder in ("Application Support", "Caches"):
            source = self.home / "Library" / folder / "Call Recorder"
            source.mkdir(parents=True, mode=0o700)
            (source / "fixture").write_bytes(b"existing model or database")
            self.pairs.append((source, source.with_name("Afterword")))

    def test_move_preserves_data_and_can_be_repeated(self):
        inodes = [(source / "fixture").stat().st_ino for source, _ in self.pairs]
        self.assertEqual(len(migration.move_directories(self.pairs)), 2)
        for (_, destination), inode in zip(self.pairs, inodes):
            self.assertEqual((destination / "fixture").stat().st_ino, inode)
            self.assertEqual((destination / "fixture").read_bytes(), b"existing model or database")
            self.assertEqual(destination.stat().st_mode & 0o777, 0o700)
        self.assertEqual(migration.move_directories(self.pairs), [])

    def test_conflict_is_detected_before_any_directory_moves(self):
        self.pairs[1][1].mkdir()
        with self.assertRaisesRegex(RuntimeError, "leaving both untouched"):
            migration.move_directories(self.pairs)
        self.assertTrue(all(source.exists() for source, _ in self.pairs))

    def test_symlink_is_rejected(self):
        self.pairs[0][1].symlink_to(self.pairs[0][0], target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "symbolic-link"):
            migration.move_directories(self.pairs)
        self.assertTrue(all(source.exists() for source, _ in self.pairs))

    def test_failed_second_move_rolls_back_first(self):
        original = Path.rename
        def rename(path, destination):
            if path == self.pairs[1][0]:
                raise OSError("fixture move failure")
            return original(path, destination)
        with patch.object(Path, "rename", rename), self.assertRaises(OSError):
            migration.move_directories(self.pairs)
        self.assertTrue(all(source.exists() and not destination.exists() for source, destination in self.pairs))

    def test_preferences_keep_new_values_and_status_item_position(self):
        legacy = {"microphone": "old", "NSStatusItem Preferred Position CallRecorderStatusItem": 19}
        current = {"microphone": "new"}
        with patch.object(Path, "home", return_value=self.home), \
             patch.object(migration.subprocess, "check_output", return_value=""), \
             patch.object(migration, "read_preferences", side_effect=[legacy, current]), \
             patch.object(migration, "write_preferences") as write:
            migration.main()
        write.assert_called_once_with("io.local.afterword", {"microphone": "new", "NSStatusItem Preferred Position AfterwordStatusItem": 19})

    def test_failed_preferences_import_restores_directories(self):
        with patch.object(Path, "home", return_value=self.home), \
             patch.object(migration.subprocess, "check_output", return_value=""), \
             patch.object(migration, "read_preferences", side_effect=[{"microphone": "old"}, {}]), \
             patch.object(migration, "write_preferences", side_effect=OSError("fixture import failure")), \
             self.assertRaises(OSError):
            migration.main()
        self.assertTrue(all(source.exists() and not destination.exists() for source, destination in self.pairs))

    def test_running_legacy_mcp_prevents_migration(self):
        with patch.object(migration.subprocess, "check_output", return_value="42 /path/Call Recorder.app/Contents/Helpers/CallRecorderMCP\n"), \
             patch.object(migration, "read_preferences") as read, \
             self.assertRaisesRegex(RuntimeError, "PID 42"):
            migration.main()
        read.assert_not_called()


if __name__ == "__main__":
    unittest.main()
