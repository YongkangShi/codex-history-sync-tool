from __future__ import annotations

import errno
import json
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from unittest import mock

from sync_backend import (
    get_status,
    make_backup,
    replace_first_line,
    resolve_paths,
    restore_backup,
    sync_session_records,
    sync_to_current_provider,
)


def write_config(codex_home, provider: str = "new_provider", model: str = "gpt-new") -> None:
    (codex_home / "config.toml").write_text(
        f'model_provider = "{provider}"\nmodel = "{model}"\n',
        encoding="utf-8",
    )


def create_threads_db(codex_home, *, with_model: bool = True) -> None:
    conn = sqlite3.connect(codex_home / "state_5.sqlite")
    if with_model:
        conn.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL, model TEXT)")
        conn.executemany(
            "INSERT INTO threads (id, model_provider, model) VALUES (?, ?, ?)",
            [
                ("old-provider-old-model", "old_provider", "gpt-old"),
                ("new-provider-old-model", "new_provider", "gpt-old"),
                ("already-current", "new_provider", "gpt-new"),
            ],
        )
    else:
        conn.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL)")
        conn.executemany(
            "INSERT INTO threads (id, model_provider) VALUES (?, ?)",
            [
                ("old-provider", "old_provider"),
                ("already-current", "new_provider"),
            ],
        )
    conn.commit()
    conn.close()


class SyncBackendTests(unittest.TestCase):
    def test_replace_first_line_shorter_preserves_remainder(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "rollout.jsonl"
            old_first_line = '{"type":"session_meta","payload":{"model_provider":"openai"}}'
            new_first_line = '{"type":"session_meta","payload":{"model_provider":"gpt"}}'
            path.write_text(old_first_line + "\n" + '{"type":"event","payload":"keep"}\n', encoding="utf-8")
            old_size = path.stat().st_size

            replace_first_line(path, new_first_line)

            content = path.read_text(encoding="utf-8")
            first_line, second_line = content.splitlines()[:2]
            self.assertEqual(old_size, path.stat().st_size)
            self.assertEqual(json.loads(first_line), json.loads(new_first_line))
            self.assertEqual(second_line, '{"type":"event","payload":"keep"}')

    def test_sync_session_records_skips_file_when_temp_rewrite_has_no_space(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            sessions_dir = codex_home / "sessions" / "2026" / "06" / "06"
            sessions_dir.mkdir(parents=True)
            session_path = (
                sessions_dir
                / "rollout-2026-06-06T00-00-00-019e9b38-bb1d-7362-af68-3dcac8ae93ea.jsonl"
            )
            first_line = (
                '{"type":"session_meta","payload":{"id":"019e9b38-bb1d-7362-af68-3dcac8ae93ea",'
                '"model_provider":"old"}}'
            )
            session_path.write_text(first_line + "\n" + '{"type":"event","payload":"keep"}\n', encoding="utf-8")
            paths = resolve_paths(str(codex_home))

            with mock.patch("sync_backend.can_rewrite_session_file", return_value=(False, 1, 10**12)):
                result = sync_session_records(paths, "new_provider", "gpt-new")

            self.assertEqual(result["updated_session_files"], 0)
            self.assertEqual(result["skipped_session_file_count"], 1)
            self.assertEqual(session_path.read_text(encoding="utf-8").splitlines()[0], first_line)

    def test_sync_session_records_skips_file_when_temp_write_runs_out_of_space(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            sessions_dir = codex_home / "sessions" / "2026" / "06" / "06"
            sessions_dir.mkdir(parents=True)
            session_path = (
                sessions_dir
                / "rollout-2026-06-06T00-00-00-019e9b38-bb1d-7362-af68-3dcac8ae93ea.jsonl"
            )
            first_line = (
                '{"type":"session_meta","payload":{"id":"019e9b38-bb1d-7362-af68-3dcac8ae93ea",'
                '"model_provider":"old"}}'
            )
            session_path.write_text(first_line + "\n" + '{"type":"event","payload":"keep"}\n', encoding="utf-8")
            paths = resolve_paths(str(codex_home))

            with (
                mock.patch("sync_backend.first_line_can_be_replaced_in_place", return_value=False),
                mock.patch("sync_backend.can_rewrite_session_file", return_value=(True, 10**12, 1)),
                mock.patch("sync_backend.replace_first_line", side_effect=OSError(errno.ENOSPC, "No space left")),
            ):
                result = sync_session_records(paths, "new_provider", "gpt-new")

            self.assertEqual(result["updated_session_files"], 0)
            self.assertEqual(result["skipped_session_file_count"], 1)
            self.assertEqual(
                result["skipped_session_files"][0]["reason"],
                "insufficient_disk_space_during_temp_rewrite",
            )

    def test_sync_session_records_skips_file_when_file_is_busy(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            sessions_dir = codex_home / "sessions" / "2026" / "06" / "06"
            sessions_dir.mkdir(parents=True)
            session_path = (
                sessions_dir
                / "rollout-2026-06-06T12-37-26-019e9b38-bb1d-7362-af68-3dcac8ae93ea.jsonl"
            )
            first_line = (
                '{"type":"session_meta","payload":{"id":"019e9b38-bb1d-7362-af68-3dcac8ae93ea",'
                '"model_provider":"old"}}'
            )
            session_path.write_text(first_line + "\n" + '{"type":"event","payload":"keep"}\n', encoding="utf-8")
            paths = resolve_paths(str(codex_home))

            with (
                mock.patch("sync_backend.can_rewrite_session_file", return_value=(True, 10**12, 1)),
                mock.patch(
                    "sync_backend.replace_first_line",
                    side_effect=RuntimeError(f"File is busy and could not be replaced: {session_path}"),
                ),
            ):
                result = sync_session_records(paths, "new_provider", "gpt-new")

            self.assertEqual(result["updated_session_files"], 0)
            self.assertEqual(result["skipped_session_file_count"], 1)
            self.assertEqual(result["skipped_session_files"][0]["reason"], "file_busy_during_rewrite")

    def test_sync_excludes_database_row_when_session_file_is_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home, provider="new_provider", model="gpt-new")
            conn = sqlite3.connect(codex_home / "state_5.sqlite")
            conn.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL, model TEXT)")
            conn.execute(
                "INSERT INTO threads (id, model_provider, model) VALUES (?, ?, ?)",
                ("019e9b38-bb1d-7362-af68-3dcac8ae93ea", "old", "gpt-old"),
            )
            conn.commit()
            conn.close()

            sessions_dir = codex_home / "sessions" / "2026" / "06" / "06"
            sessions_dir.mkdir(parents=True)
            session_path = (
                sessions_dir
                / "rollout-2026-06-06T00-00-00-019e9b38-bb1d-7362-af68-3dcac8ae93ea.jsonl"
            )
            first_line = (
                '{"type":"session_meta","payload":{"id":"019e9b38-bb1d-7362-af68-3dcac8ae93ea",'
                '"model_provider":"old"}}'
            )
            session_path.write_text(first_line + "\n" + '{"type":"event","payload":"keep"}\n', encoding="utf-8")
            paths = resolve_paths(str(codex_home))

            with mock.patch("sync_backend.can_rewrite_session_file", return_value=(False, 1, 10**12)):
                result = sync_to_current_provider(paths, include_model=True)

            self.assertEqual(result["skipped_session_file_count"], 1)
            self.assertEqual(result["excluded_database_thread_count"], 1)
            skipped_report_path = Path(str(result["skipped_session_report_path"]))
            self.assertEqual(skipped_report_path.parent.name, "skipped_sessions")
            self.assertTrue(skipped_report_path.exists())
            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as conn:
                row = conn.execute(
                    "SELECT model_provider, model FROM threads WHERE id = ?",
                    ("019e9b38-bb1d-7362-af68-3dcac8ae93ea",),
                ).fetchone()
            self.assertEqual(row, ("old", "gpt-old"))

    def test_sync_updates_provider_only_by_default_for_newer_codex_schema(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))

            status = get_status(paths)

            self.assertEqual(status["provider_movable_threads"], 1)
            self.assertEqual(status["model_movable_threads"], 2)
            self.assertEqual(status["movable_threads"], 1)

            result = sync_to_current_provider(paths)

            self.assertEqual(result["synced_fields"], ["model_provider"])
            self.assertEqual(result["updated_rows"], 1)

            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as conn:
                rows = conn.execute(
                    "SELECT model_provider, model, COUNT(*) FROM threads GROUP BY model_provider, model"
                ).fetchall()

            self.assertEqual(rows, [("new_provider", "gpt-new", 1), ("new_provider", "gpt-old", 2)])

    def test_status_defaults_to_openai_when_model_provider_is_omitted(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            (codex_home / "config.toml").write_text('model = "gpt-5.5"\n', encoding="utf-8")
            conn = sqlite3.connect(codex_home / "state_5.sqlite")
            conn.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL, model TEXT)")
            conn.executemany(
                "INSERT INTO threads (id, model_provider, model) VALUES (?, ?, ?)",
                [
                    ("already-openai", "openai", "gpt-5.5"),
                    ("custom-provider", "gpt", "gpt-5.5"),
                ],
            )
            conn.commit()
            conn.close()
            paths = resolve_paths(str(codex_home))

            status = get_status(paths)

            self.assertEqual(status["current_provider"], "openai")
            self.assertEqual(status["provider_movable_threads"], 1)

    def test_sync_can_include_model_for_newer_codex_schema(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))

            status = get_status(paths, include_model=True)

            self.assertEqual(status["provider_movable_threads"], 1)
            self.assertEqual(status["model_movable_threads"], 2)
            self.assertEqual(status["movable_threads"], 2)

            result = sync_to_current_provider(paths, include_model=True)

            self.assertEqual(result["synced_fields"], ["model_provider", "model"])
            self.assertEqual(result["updated_rows"], 2)

            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as conn:
                rows = conn.execute(
                    "SELECT model_provider, model, COUNT(*) FROM threads GROUP BY model_provider, model"
                ).fetchall()

            self.assertEqual(rows, [("new_provider", "gpt-new", 3)])

    def test_sync_still_supports_legacy_schema_without_model_column(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=False)
            paths = resolve_paths(str(codex_home))

            status = get_status(paths)

            self.assertEqual(status["provider_movable_threads"], 1)
            self.assertIsNone(status["model_movable_threads"])
            self.assertEqual(status["movable_threads"], 1)

            result = sync_to_current_provider(paths)

            self.assertEqual(result["synced_fields"], ["model_provider"])
            self.assertEqual(result["updated_rows"], 1)

            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as conn:
                rows = conn.execute("SELECT model_provider, COUNT(*) FROM threads GROUP BY model_provider").fetchall()

            self.assertEqual(rows, [("new_provider", 2)])

    def test_restore_backup_restores_previous_database_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))
            backup_path = make_backup(paths, "manual")

            sync_to_current_provider(paths)
            result = restore_backup(paths, str(backup_path))

            self.assertEqual(result["restored_from"], str(backup_path))
            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as conn:
                rows = conn.execute(
                    "SELECT model_provider, model, COUNT(*) FROM threads GROUP BY model_provider, model ORDER BY model_provider, model"
                ).fetchall()

            self.assertEqual(
                rows,
                [
                    ("new_provider", "gpt-new", 1),
                    ("new_provider", "gpt-old", 1),
                    ("old_provider", "gpt-old", 1),
                ],
            )


if __name__ == "__main__":
    unittest.main()
