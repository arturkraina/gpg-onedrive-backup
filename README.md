# GPG Backup to OneDrive via YubiKey

Two POSIX shell scripts for encrypted off-site backup using GPG and a YubiKey.
Files are encrypted locally before being stored in OneDrive, so the cloud
provider never has access to plaintext data.


## What it does

encrypt-to-onedrive.sh walks your local directories, encrypts every file with
your GPG public key, and writes the result to OneDrive with a .gpg extension.
Only files that changed since the last run are re-encrypted (incremental).

decrypt-from-onedrive.sh selectively pulls chosen directories back from
OneDrive, decrypts them using the private key on your YubiKey, and restores
the original file tree locally.


## Requirements

- macOS or any POSIX-compatible system
- gpg (GNU Privacy Guard)
- jq (brew install jq)
- YubiKey with a GPG key loaded, or any other GPG smart card


## Quick start

1. Clone the repository.

        git clone https://github.com/YOUR_USERNAME/YOUR_REPO.git
        cd YOUR_REPO

2. Install dependencies.

        brew install gnupg jq

3. Edit the configuration files to match your environment.

        encrypt-config.json   set source_dirs, dest_dir, gpg_recipient
        decrypt-config.json   set source_dir, dest_dir, included_dirs

4. Make the scripts executable.

        chmod +x encrypt-to-onedrive.sh decrypt-from-onedrive.sh

5. Insert your YubiKey and run.

        ./encrypt-to-onedrive.sh
        ./decrypt-from-onedrive.sh


## Configuration

Each script reads its own JSON config file from the same directory.
See encrypt.md and decrypt.md for a full description of every option.

encrypt-config.json controls which local directories are encrypted and where
in OneDrive the output goes.

decrypt-config.json controls which directories inside OneDrive are pulled back
and where they are restored locally.


## Features

- Incremental: skips files that have not changed since the last run
- Selective decrypt: choose exactly which folders to restore
- Copy-only mode: directories already encrypted (e.g. a pass password store)
  are copied verbatim without double-encryption
- Exclusion lists: skip build artifacts, temp files, and system junk
- Colour-coded terminal output
- Append-only log file with timestamps for every session
- macOS Files On Demand: after decryption the local OneDrive copy is evicted
  to save disk space


## File overview

    encrypt-to-onedrive.sh    Encrypt and upload to OneDrive
    decrypt-from-onedrive.sh  Download and decrypt from OneDrive
    encrypt-config.json       Configuration for encryption
    decrypt-config.json       Configuration for decryption
    encrypt.md                Full usage guide for encryption
    decrypt.md                Full usage guide for decryption


## License

MIT
