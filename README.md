
# Requirements for ALL backup jobs

- AWS S3 Credentials. Regardless of whether you backup google team drives or github repos, you will need these environment variables to be set:

```zsh
export AWS_DEFAULT_REGION=us-west-2 # must be the same region as the bucket
export S3_BUCKET_NAME="bucket-name"
export AWS_ACCESS_KEY_ID=XXXXXXXXXXXXXXXXXXXXX 
export AWS_SECRET_ACCESS_KEY=XXXXXXXXXXXXXXXXXXXXX
```

# GitHub Organization backups

Following variables must be set

```zsh
export GITHUB_ORG_TO_BACKUP="GlueOps" # Set this to the organization you want to backup. The GITHUB_TOKEN must have read access to all the repos in this organization.
export GITHUB_TOKEN="" # GitH needs to have read access to all repositories within the organization. We use the fine grained access tokens (beta feature)
```

- To create a GITHUB_TOKEN use the newer fine grained tokens:

<img width="823" alt="image" src="https://github.com/GlueOps/backup-tools/assets/6570292/52599edf-100b-4f9a-987d-de5505d603b8">

- Example backup

```zsh
docker build . -t backup && docker run -it backup
# Export ALL the variables required as mentioned in this README.md and then run:
backup-github
```

# Google Drive Shared Drive Backups

## note this only works for shared team drives. we do not have anything to backup personal drives

- First the drive needs to be shared to our service account: `rclone@glueops.dev` with `Contributor" access
- The team drive ID can be found from the URL. Example: https://drive.google.com/drive/folders/0ZZH9DD53YuyEaYU7sqb would have a team drive ID of: `0ZZH9DD53YuyEaYU7sqb`

Following variables must be set

```zsh
export RCLONE_DRIVE_SERVICE_ACCOUNT_CREDENTIALS='<<json-without \n (newlines)>>' # Get this from the IAM user in the rclone google cloud service account project and remove all newlines \n
export RCLONE_DRIVE_TEAM_DRIVE="XXXXXXXXXXXXXX" # team drive id ex. `0ZZH9DD53YuyEaYU7sqb`
```

- Example to run a download of the team drive to local
  
```zsh
docker build . -t backup && docker run -it backup
# Export ALL the variables required as mentioned in this README.md and then run:
./gdrive-backup.sh
```
