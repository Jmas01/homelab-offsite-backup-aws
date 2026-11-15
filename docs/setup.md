# Setup

How the pieces were put in place. The bucket, IAM user and lifecycle rules were created in the AWS console. The JSON files in `aws/` are the equivalent configuration, so the same setup can be reproduced with the AWS CLI.

## 1. Bucket

- Region: us-east-1.
- **Block Public Access:** all four settings on.
- **Object Ownership:** bucket owner enforced (ACLs disabled).
- **Versioning:** enabled.
- **Default encryption:** SSE-S3.
- **Object Lock:** off (see "Known limits" in the README).
- **Tag:** `project=homelab-backup`, so the cost shows separately in Cost Explorer.

## 2. Upload-only IAM user

1. Create a customer-managed policy from [`aws/iam-policy.json`](../aws/iam-policy.json), with your bucket name in place of `<your-bucket>`.
2. Create an IAM user with **no console access** and attach the policy directly.
3. Create one access key for "application running outside AWS". Store it in a password manager.

Check that it's least privilege: listing all buckets with this key must fail with `AccessDenied` on `s3:ListAllMyBuckets`, and listing your one bucket must work.

## 3. Lifecycle rules

```bash
aws s3api put-bucket-lifecycle-configuration --bucket <your-bucket> \
  --lifecycle-configuration file://aws/lifecycle.json
```

New lifecycle configurations don't move objects under 128 KB to another storage class (the S3 default since 2024).

## 4. rclone remotes on the backup host

The example uses rclone 1.53 from Debian's apt. Type the secrets at hidden prompts, so they never appear in shell history:

```bash
read -rsp "Access key ID: " AK; echo
read -rsp "Secret access key: " SK; echo
rclone config create aws-s3 s3 provider AWS env_auth false \
  access_key_id "$AK" secret_access_key "$SK" region us-east-1 acl private no_check_bucket true > /dev/null

read -rsp "Crypt password: " CP; echo
rclone config create aws-crypt crypt remote aws-s3:<your-bucket> \
  filename_encryption off password "$CP" --obscure > /dev/null
unset AK SK CP
chmod 600 ~/.config/rclone/rclone.conf
```

- `no_check_bucket true`: rclone doesn't try to create or check the bucket, which the upload-only key isn't allowed to do.
- `filename_encryption off`: file contents are encrypted but names stay readable, so the lifecycle prefixes `daily/`, `weekly/` and `photos/` keep working. Encrypted files get a `.bin` suffix.
- **Save the crypt password in a password manager before the first upload.** Without it the backups can't be decrypted, by anyone.

## 5. Script and timers

```bash
install -m 700 scripts/s3-offsite-backup.sh /usr/local/sbin/
install -m 644 systemd/* /etc/systemd/system/
systemctl daemon-reload

# check what would be uploaded, without uploading
/usr/local/sbin/s3-offsite-backup.sh daily --dry-run

# first real run (the photo seed can take hours), then turn the schedule on
systemctl start --no-block s3-offsite-backup-{daily,weekly,photos}.service
systemctl enable --now s3-offsite-backup-{daily,weekly,photos}.timer
```

The services call `notify-backup-failure@%n.service` when they fail. That's a small existing unit on my host that posts the last log lines to Discord. Replace it with your own alerting, or remove the `OnFailure=` line.
