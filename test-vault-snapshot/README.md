## Requirements

- Assumes you already built the docker image and/or are referencing the one in ghcr.
- You have a snapshot to test, the keys to unseal it, and the root token to login with AND it's hosted on a public URL that is ideally secured with some level of authenticated. https://docs.aws.amazon.com/AmazonS3/latest/userguide/ShareObjectPreSignedURL.html


## Overview

To test the vault snapshot from another cluster, you first need to start a vault server that is running in raft mode. This requires we start a vault server with a raft config, initialize it and then unseal it and then login into it with the token we got from the initialization. After this is completed, you need to restore the snapshot from the old server/backup and then unseal it *again* using the unseal keys meant fo the backup/snapshot, and then login using the applicable root token from the backup/snapshot server.

## Note:

If you make an error in the process then it's recommended to delete everything, restart your containers and just try again. Otherwise your environment will likely be in a weird state.


### Let's get started.

#### Open a terminal

Start the container with:

```bash
docker run -it -p 8200:8200 -v `pwd`/data:/data backup bash
```

Run the following script to:

- Create a peers.json
- Start vault server
- Initialize vault
- Unseal vault
- Login to vault with the root token
  
```bash
mkdir -p /data/raft
cat > /data/raft/peers.json << EOF
[
  {
    "id": "node1",
    "address": "127.0.0.1:8201",
    "non_voter": false
  }
]
EOF

vault server -config=/data/config.hcl &
sleep 30;
export VAULT_ADDR=http://127.0.0.1:8200
vault_data=`vault operator init -key-shares=1 -key-threshold=1 --format=json`
root_token=`echo $vault_data | jq -r .root_token`
unseal_token=`echo $vault_data | jq -r .unseal_keys_b64[0]`
vault operator unseal $unseal_token
sleep 10;
vault login $root_token


```

# Restore the snapshot

Create an S3 PRESIGNED URL to the backup that we want to restore. Limit the time to 10mins or whatever you feel is appropriate. And then export the url as a variable in the same terminal session from above.

```bash
S3_PRESIGNED_DOWNLOAD_URL="https://time-sensitive-and-authenticated-url-to-download-backup-from-s3"
curl -o backup_to_restore.snap $S3_PRESIGNED_DOWNLOAD_URL
vault operator raft snapshot restore -force backup_to_restore.snap
```

# In the same terminal session unseal with the unseal token for the backup you just restored

```bash
vault operator unseal 55ebb6859b269cd1ce501989ebba821baf84076c28d84008474aa3fddc0a24b3
```

# In the same terminal session, login with the root token for the backup you unsealed/restored.

```bash
vault login hvs.fm0DOOSsPTwqB7rFFNbJgCle
```

# If you want to access from the web UI from codespaces

- Go to the `PORTS` tab
- `Add Port` 8200 and then click on the web icon 🌐 to load upt he preview url in codespaces. When prompted for the login, click `other`, select `token` and use the root token for the backup you restored.
