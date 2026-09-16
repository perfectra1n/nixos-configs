function fixvolsyncrestic --description "Fix a Restic repo that has been locked."
    set APP $argv[1]
    restic --repo s3://$RESTIC_S3_ENDPOINT/volsync-backups/apps/$APP unlock --remove-all
    restic --repo s3://$RESTIC_S3_ENDPOINT/volsync-backups/apps/$APP cache --cleanup
    restic --repo s3://$RESTIC_S3_ENDPOINT/volsync-backups/apps/$APP prune
end
