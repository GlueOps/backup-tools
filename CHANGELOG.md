# Changelog

## [2.17.0](https://github.com/GlueOps/backup-tools/compare/v2.16.0...v2.17.0) (2026-08-04)


### Features

* validate and support all restic backends, not just S3 ([#264](https://github.com/GlueOps/backup-tools/issues/264)) ([7ef4dd1](https://github.com/GlueOps/backup-tools/commit/7ef4dd17cd1ef0946b3eaed43e24b74a69507b18))


### Bug Fixes

* preflight rejected valid configurations and leaked passwords ([#265](https://github.com/GlueOps/backup-tools/issues/265)) ([d1606ca](https://github.com/GlueOps/backup-tools/commit/d1606ca00519917db6cb5f2206b82c8e79a4e616))
* restore resolved 'latest' to its own pre-restore snapshot ([#266](https://github.com/GlueOps/backup-tools/issues/266)) ([ad74540](https://github.com/GlueOps/backup-tools/commit/ad74540409412f555c93f2640b39f8be6a6e8749))


### Miscellaneous Chores

* **fallback:** update actions/checkout ([#262](https://github.com/GlueOps/backup-tools/issues/262)) ([9b18041](https://github.com/GlueOps/backup-tools/commit/9b1804102329fa41cde8e6ea266c0e96ff3d9da5))

## [2.16.0](https://github.com/GlueOps/backup-tools/compare/v2.15.0...v2.16.0) (2026-08-04)


### Features

* add restic-based NFS backup and restore ([#261](https://github.com/GlueOps/backup-tools/issues/261)) ([32ebf19](https://github.com/GlueOps/backup-tools/commit/32ebf19f8a7555541991ff5df03051f65db6f932))
* update aws/aws-cli to 2.35.15 #minor ([#245](https://github.com/GlueOps/backup-tools/issues/245)) ([f18bac7](https://github.com/GlueOps/backup-tools/commit/f18bac7cd6cd26eb4cbbccd2100c543746b14345))
* update cli/cli to v2.96.0 #minor ([#258](https://github.com/GlueOps/backup-tools/issues/258)) ([acae048](https://github.com/GlueOps/backup-tools/commit/acae048954c8166c7a7897de6a4ed612211211fc))
* update docker/build-push-action to v7.3.0 #minor ([#254](https://github.com/GlueOps/backup-tools/issues/254)) ([5ce62b6](https://github.com/GlueOps/backup-tools/commit/5ce62b67f4a9bce7e31082947e2d0ed5a4d2055b))
* update docker/login-action to v4.3.0 #minor ([#255](https://github.com/GlueOps/backup-tools/issues/255)) ([25704bc](https://github.com/GlueOps/backup-tools/commit/25704bc83ff695c19a697bed4a158e671c77b948))
* update docker/login-action to v4.4.0 #minor ([#259](https://github.com/GlueOps/backup-tools/issues/259)) ([5153c38](https://github.com/GlueOps/backup-tools/commit/5153c383608c3519fe9f7b7edd0cfd5804618ca8))
* update docker/metadata-action to v6.2.0 #minor ([#256](https://github.com/GlueOps/backup-tools/issues/256)) ([0a3a3f5](https://github.com/GlueOps/backup-tools/commit/0a3a3f51b9b7486100c1dadec67e83462629f111))
* update docker/setup-buildx-action to v4.2.0 #minor ([#257](https://github.com/GlueOps/backup-tools/issues/257)) ([92ff600](https://github.com/GlueOps/backup-tools/commit/92ff600587ecd0646da32ba5aa5a127247f150f9))
* update docker/setup-qemu-action to v4.2.0 #minor ([#253](https://github.com/GlueOps/backup-tools/issues/253)) ([ed55bce](https://github.com/GlueOps/backup-tools/commit/ed55bce2764b2bbb6cc3c9713790df4e7ade0e87))


### Miscellaneous Chores

* add Apache-2.0 LICENSE ([#252](https://github.com/GlueOps/backup-tools/issues/252)) ([2fe6abd](https://github.com/GlueOps/backup-tools/commit/2fe6abd66358cd4dc4b6e40fe3aaebc8ad8b7460))
* **fallback:** update actions/checkout ([#250](https://github.com/GlueOps/backup-tools/issues/250)) ([99aa5fb](https://github.com/GlueOps/backup-tools/commit/99aa5fb0cbc1032ce94ecb5ba72663be52871ef4))
* **fallback:** update ubuntu ([#242](https://github.com/GlueOps/backup-tools/issues/242)) ([0535409](https://github.com/GlueOps/backup-tools/commit/05354094a9621afa8c64e73d72035b37e261cea5))
* **patch:** update dataaxiom/ghcr-cleanup-action to v1.2.2 #patch ([#243](https://github.com/GlueOps/backup-tools/issues/243)) ([ea444b0](https://github.com/GlueOps/backup-tools/commit/ea444b0344c688c5f81fe864c46ddf51771691ef))
* **patch:** update openbao/openbao to v2.5.5 #patch ([#247](https://github.com/GlueOps/backup-tools/issues/247)) ([c3fcdde](https://github.com/GlueOps/backup-tools/commit/c3fcddeee0f2351821425ef22f33f273a66a5e0f))

## [2.15.0](https://github.com/GlueOps/backup-tools/compare/v2.14.2...v2.15.0) (2026-06-30)


### Features

* consolidate dependency updates ([#238](https://github.com/GlueOps/backup-tools/issues/238)) ([24c4970](https://github.com/GlueOps/backup-tools/commit/24c4970892d823a4f3f9cce0129058d1b8e9946e))


### Continuous Integration

* bring release-please config up to GlueOps convention ([#240](https://github.com/GlueOps/backup-tools/issues/240)) ([ae0b779](https://github.com/GlueOps/backup-tools/commit/ae0b779f0cf50f6875f1723e744373129c7cfb2b))

## [2.14.2](https://github.com/GlueOps/backup-tools/compare/v2.14.1...v2.14.2) (2026-06-29)


### Bug Fixes

* authenticate release-please via GitHub App token ([#236](https://github.com/GlueOps/backup-tools/issues/236)) ([ce2f6ab](https://github.com/GlueOps/backup-tools/commit/ce2f6ab97eae9667ca7a11b9910c266442457591))
