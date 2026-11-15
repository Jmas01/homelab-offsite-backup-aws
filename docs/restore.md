# Restore

The design assumption: the backup host and the NAS are both gone. All you have is a sign-in to the AWS account and the crypt password from the password manager.

## A database dump or config archive (S3 Standard, minutes)

1. In the S3 console, open `daily/` (or `weekly/`), select the `.bin` file and click **Download**.
2. Put it in an empty folder, e.g. `restore-test\enc`. Keep the file name unchanged.
3. Decrypt it with rclone and a one-off crypt remote. Nothing gets saved to the rclone config.

**Windows PowerShell:**

```powershell
$d = "$env:USERPROFILE\Downloads\restore-test"
$s = Read-Host "Paste the crypt password" -AsSecureString
$ob = [System.Net.NetworkCredential]::new('', $s).Password | rclone obscure -
rclone copy :crypt: "$d\out" --crypt-remote "$d\enc" --crypt-filename-encryption off --crypt-password $ob
(Get-FileHash "$d\out\<file name without .bin>").Hash
```

**Linux:**

```bash
read -rsp "Crypt password: " CP; echo
OB=$(printf '%s' "$CP" | rclone obscure -); unset CP
rclone copy :crypt: ./out --crypt-remote ./enc --crypt-filename-encryption off --crypt-password "$OB"
sha256sum ./out/*
```

The password is read without echoing and piped to `rclone obscure`, so it never appears on screen or in shell history.

4. Compare the checksum with the original, if it still exists. Delete the restored copy when you're done: it's a readable copy of your data.

**Tested 2026-11-14:**
- 114 MB database dump downloaded in under a minute.
- Decrypted on a different machine in 0.3 s.
- SHA-256 identical to the original.

## Photos (Glacier Deep Archive, up to 48 hours)

Objects in Deep Archive can't be downloaded directly. They have to be restored to a temporary readable copy first. The upload-only key has no `s3:RestoreObject` permission, so do this as an admin.

**One file, in the console:** select the object, then **Actions → Initiate restore**. Pick **Bulk** retrieval (cheapest, up to 48 hours) and keep the copy for a few days. When the object shows *Restoration complete*, download and decrypt it as above.

**Many files, with the AWS CLI:**

```bash
aws s3api restore-object --bucket <your-bucket> --key "photos/upload/<path>.jpg.bin" \
  --restore-request '{"Days":7,"GlacierJobParameters":{"Tier":"Bulk"}}'
```

**What a full restore costs (us-east-1, 2026 prices):**
- Bulk retrieval: $0.0025 per GB.
- Download: the first 100 GB a month is free, then $0.09 per GB.
- About **$14** for all ~243 GB, almost all of it download fees.

The single-photo restore test is still pending (see the README).
