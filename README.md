# public-ci-script

Clear all cached files for a key using the same `S3_BUCKET`, `S3_ACCESS_KEY_ID`,
and `S3_SECRET_ACCESS_KEY` environment variables as the save/load scripts:

```sh
bash aws_s3_clear_cache "your-cache-key"
```

This removes `s3://$S3_BUCKET/cache_folders/<key>/` recursively. A missing key
argument or a cache that does not exist prints a message and exits successfully.
AWS listing or deletion errors still return a nonzero exit status.
