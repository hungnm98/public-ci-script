import datetime
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ("aws_s3_load_cache", "aws_s3_save_cache", "cache/v1/aws_s3_save_cache")
CACHE_KEY = "sts/project-deploy-v1/cache-id"
TAR_FILE = "test-cache.tgz"
S3_KEY = f"cache_folders/{CACHE_KEY}/{TAR_FILE}"
S3_URI = f"s3://test-bucket/{S3_KEY}"

AWS_STUB = r'''
import json, os, shutil, sys
with open(os.environ["AWS_CALLS"], "a") as calls:
    calls.write(json.dumps(sys.argv[1:]) + "\n")
if sys.argv[1:3] == ["s3api", "head-object"]:
    status = int(os.environ["HEAD_STATUS"])
    if status:
        print(os.environ["HEAD_ERROR"], file=sys.stderr)
    else:
        print(json.dumps({"LastModified": os.environ["LAST_MODIFIED"]}))
    sys.exit(status)
if sys.argv[1:3] == ["s3", "cp"]:
    status = int(os.environ.get("COPY_STATUS", "0"))
    if status:
        print("S3 transfer failed", file=sys.stderr)
    elif sys.argv[3].startswith("s3://"):
        shutil.copyfile(os.environ["ARCHIVE"], sys.argv[4])
    else:
        shutil.copyfile(sys.argv[3], os.environ["UPLOADED_ARCHIVE"])
    sys.exit(status)
print("Unexpected AWS operation", file=sys.stderr)
sys.exit(99)
'''


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.folder = self.work / "input folder"
        self.folder.mkdir()
        (self.folder / "deploy.env").write_text("DEPLOY_VERSION=123\n")
        stub = self.work / "aws"
        stub.write_text(f"#!{sys.executable}\n" + AWS_STUB)
        stub.chmod(0o755)
        self.archive = self.work / "download.tgz"
        with tarfile.open(self.archive, "w:gz") as archive:
            content = b"DEPLOY_VERSION=456\n"
            entry = tarfile.TarInfo("restored.env")
            entry.size = len(content)
            archive.addfile(entry, io.BytesIO(content))
        self.calls_file = self.work / "calls.jsonl"
        self.env = {
            **os.environ,
            "PATH": f"{self.work}:{os.environ['PATH']}",
            "S3_ACCESS_KEY_ID": "test-key",
            "S3_SECRET_ACCESS_KEY": "test-secret",
            "S3_BUCKET": "test-bucket",
            "S3_TMP_DIR": str(self.work),
            "CIRCLE_NODE_INDEX": "0",
            "OVERRIDE_CACHED": "0",
            "SAVE_CACHE_EXPIRE_HOURS": "72",
            "AWS_CALLS": str(self.calls_file),
            "ARCHIVE": str(self.archive),
            "UPLOADED_ARCHIVE": str(self.work / "uploaded.tgz"),
            "HEAD_STATUS": "0",
            "HEAD_ERROR": "",
            "LAST_MODIFIED": datetime.datetime.now(datetime.timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%S%z"
            ),
        }

    def run_script(self, script, **env):
        self.calls_file.write_text("")
        result = subprocess.run(
            ["sh" if script.startswith("cache/") else "bash", str(ROOT / script),
             str(self.folder), CACHE_KEY, "test-cache"],
            env={**self.env, **env}, capture_output=True, text=True,
        )
        calls = [json.loads(line) for line in self.calls_file.read_text().splitlines()]
        if calls:
            self.assertEqual(calls[0], [
                "s3api", "head-object", "--bucket", "test-bucket", "--key", S3_KEY,
            ])
        return result, calls

    def test_check_errors_are_visible_and_stop_all_scripts(self):
        for script in SCRIPTS:
            for status, error in (
                (254, "An error occurred (403) when calling the HeadObject operation: Forbidden"),
                (254, "An error occurred (ExpiredToken) when calling the HeadObject operation: expired"),
                (255, "Could not connect to the endpoint URL: https://s3.example.test"),
                (253, "Unable to locate credentials"),
            ):
                with self.subTest(script=script, error=error):
                    result, calls = self.run_script(
                        script, HEAD_STATUS=str(status), HEAD_ERROR=error, OVERRIDE_CACHED="1",
                    )
                    self.assertEqual(result.returncode, status)
                    self.assertIn(error, result.stderr)
                    self.assertNotIn("File not found", result.stdout)
                    self.assertNotIn("DONE", result.stdout)
                    self.assertEqual(len(calls), 1)

    def test_missing_object_is_a_normal_cache_miss(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                result, calls = self.run_script(
                    script, HEAD_STATUS="254",
                    HEAD_ERROR="An error occurred (404) when calling the HeadObject operation: Not Found",
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                if script == SCRIPTS[0]:
                    self.assertIn("File not found", result.stdout)
                    self.assertEqual(len(calls), 1)
                else:
                    self.assertEqual(calls[1][1:], ["cp", str(self.work / "save-cache" / TAR_FILE), S3_URI])
                    with tarfile.open(self.work / "uploaded.tgz") as archive:
                        self.assertEqual(archive.extractfile("./deploy.env").read(), b"DEPLOY_VERSION=123\n")

    def test_existing_object_restores_or_skips_save(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                result, calls = self.run_script(script)
                self.assertEqual(result.returncode, 0, result.stderr)
                if script == SCRIPTS[0]:
                    self.assertEqual(calls[1], ["s3", "cp", S3_URI, str(self.work / "load-cache" / TAR_FILE)])
                    self.assertEqual((self.folder / "restored.env").read_text(), "DEPLOY_VERSION=456\n")
                else:
                    self.assertEqual(len(calls), 1)

    def test_versioned_save_overwrites_forced_or_expired_cache(self):
        for env in ({"OVERRIDE_CACHED": "1"}, {"LAST_MODIFIED": "2000-01-01T00:00:00+0000"}):
            with self.subTest(env=env):
                result, calls = self.run_script(SCRIPTS[2], **env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(calls), 2)
                self.assertIn("DONE", result.stdout)

    def test_transfer_errors_do_not_report_success(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                env = {} if script == SCRIPTS[0] else {
                    "HEAD_STATUS": "254",
                    "HEAD_ERROR": "An error occurred (404) when calling the HeadObject operation: Not Found",
                }
                result, calls = self.run_script(script, COPY_STATUS="1", **env)
                self.assertEqual(result.returncode, 1)
                self.assertIn("S3 transfer failed", result.stderr)
                self.assertNotIn("DONE", result.stdout)
                if script == SCRIPTS[0]:
                    self.assertNotIn("done ", result.stdout)
                self.assertEqual(len(calls), 2)

    def test_invalid_archive_does_not_report_success(self):
        self.archive.write_text("invalid archive")
        result, _ = self.run_script(SCRIPTS[0])
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("done ", result.stdout)

    def test_archive_creation_failure_does_not_upload(self):
        self.folder = self.work / "missing-folder"
        for script in SCRIPTS[1:]:
            with self.subTest(script=script):
                result, calls = self.run_script(
                    script, HEAD_STATUS="254",
                    HEAD_ERROR="An error occurred (404) when calling the HeadObject operation: Not Found",
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(calls), 1)
                self.assertNotIn("DONE", result.stdout)


if __name__ == "__main__":
    unittest.main()
