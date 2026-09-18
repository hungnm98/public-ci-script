import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CACHE_KEY = "sts/project deploy/cache-id"
AWS_STUB = r'''
import json, os, sys
with open(os.environ["AWS_CALLS"], "a") as calls:
    calls.write(json.dumps(sys.argv[1:]) + "\n")
if sys.argv[1:3] == ["s3api", "list-objects-v2"]:
    status = int(os.environ.get("LIST_STATUS", "0"))
    if status:
        print("S3 listing failed", file=sys.stderr)
    else:
        print(os.environ.get("OBJECT_COUNT", "1"))
    sys.exit(status)
if sys.argv[1:3] == ["s3", "rm"]:
    status = int(os.environ.get("REMOVE_STATUS", "0"))
    if status:
        print("S3 removal failed", file=sys.stderr)
    sys.exit(status)
sys.exit(99)
'''


class ClearCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        stub = self.work / "aws"
        stub.write_text(f"#!{sys.executable}\n" + AWS_STUB)
        stub.chmod(0o755)
        self.calls_file = self.work / "calls.jsonl"

    def run_script(self, *args, **env):
        self.calls_file.write_text("")
        result = subprocess.run(
            ["bash", str(ROOT / "aws_s3_clear_cache"), *args],
            env={
                **os.environ,
                "PATH": f"{self.work}:{os.environ['PATH']}",
                "S3_BUCKET": "test-bucket",
                "S3_ACCESS_KEY_ID": "test-key",
                "S3_SECRET_ACCESS_KEY": "test-secret",
                "AWS_CALLS": str(self.calls_file),
                **env,
            },
            capture_output=True, text=True,
        )
        calls = [json.loads(line) for line in self.calls_file.read_text().splitlines()]
        return result, calls

    def test_existing_cache_is_removed_under_exact_key_prefix(self):
        result, calls = self.run_script(CACHE_KEY)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [
            ["s3api", "list-objects-v2", "--bucket", "test-bucket",
             "--prefix", f"cache_folders/{CACHE_KEY}/", "--max-keys", "1",
             "--no-paginate", "--query", "KeyCount", "--output", "text"],
            ["s3", "rm", f"s3://test-bucket/cache_folders/{CACHE_KEY}/", "--recursive"],
        ])
        self.assertIn("Cache cleared", result.stdout)

    def test_missing_cache_is_successful_without_delete(self):
        result, calls = self.run_script(CACHE_KEY, OBJECT_COUNT="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Cache not found", result.stdout)
        self.assertEqual(len(calls), 1)

    def test_missing_or_empty_key_is_successful_without_aws_calls(self):
        for args in ((), ("",)):
            with self.subTest(args=args):
                result, calls = self.run_script(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("No cache key provided", result.stdout)
                self.assertEqual(calls, [])

    def test_missing_bucket_does_not_call_aws(self):
        result, calls = self.run_script(CACHE_KEY, S3_BUCKET="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("S3_BUCKET is required", result.stderr)
        self.assertEqual(calls, [])

    def test_listing_failure_is_not_reported_as_cache_miss(self):
        result, calls = self.run_script(CACHE_KEY, LIST_STATUS="254")
        self.assertEqual(result.returncode, 254)
        self.assertIn("S3 listing failed", result.stderr)
        self.assertNotIn("Cache not found", result.stdout)
        self.assertEqual(len(calls), 1)

    def test_removal_failure_is_not_reported_as_success(self):
        result, calls = self.run_script(CACHE_KEY, REMOVE_STATUS="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("S3 removal failed", result.stderr)
        self.assertNotIn("Cache cleared", result.stdout)
        self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main()
