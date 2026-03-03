# decrypt-from-onedrive.sh

A POSIX shell script that selectively decrypts GPG-encrypted files from an
OneDrive folder back to the local filesystem.  Decryption uses the private
key stored on a YubiKey (or any GPG smart card accessible via gpg-agent).


## How it works

1. Reads decrypt-config.json from the same directory as the script.
2. Checks that a YubiKey is connected and recognised by gpg-agent.
3. For each path listed in included_dirs, walks the OneDrive source folder
   recursively and decrypts every .gpg file it finds.
4. Writes the decrypted files into the local destination tree, preserving
   the original relative directory structure.
5. Skips any file whose decrypted counterpart already exists locally.
6. On macOS, optionally evicts the local OneDrive copy of each .gpg file
   after a successful decrypt (Files On Demand / brctl).


## Requirements

- gpg (GNU Privacy Guard)
- jq  (brew install jq)
- A YubiKey or other GPG smart card with the private key loaded


## Files

    decrypt-from-onedrive.sh   The script itself.
    decrypt-config.json     Configuration (paths and directories to decrypt).
    logs/decrypt.log        Append-only session log (created automatically).


## Configuration (decrypt-config.json)

    source_dir      Full path to the encrypted folder inside OneDrive.
                    Use ~ for the home directory.
                    Example: "~/OneDrive - YOUR_ORG/Documents"

    dest_dir        Root of the local directory tree where decrypted files
                    will be written.
                    Example: "~/Documents"

    log_dir         Directory where decrypt.log will be written.
                    Example: "~/Documents/_encrypt/logs"

    log_file        Name of the log file.
                    Example: "decrypt.log"

    included_dirs   Array of relative paths inside source_dir to decrypt.
                    Each entry can be a directory (processed recursively) or
                    a single .gpg file.
                    Example: ["Work/invoices", "Personal/notes"]

Example decrypt-config.json:

    {
      "source_dir": "~/OneDrive - YOUR_ORG/Documents",
      "dest_dir": "~/Documents",
      "log_dir": "~/Documents/_encrypt/logs",
      "log_file": "decrypt.log",
      "included_dirs": [
        "Work/invoices",
        "Personal/notes"
      ]
    }


## Setup

1. Install dependencies.

        brew install gnupg jq

2. Import or confirm that your GPG public key is in the local keyring.

        gpg --list-keys

3. Copy decrypt-config.json to the same folder as decrypt-from-onedrive.sh
   and adjust the values for your environment.

4. Make the script executable.

        chmod +x decrypt-from-onedrive.sh


## Usage

Insert your YubiKey, then run:

    ./decrypt-from-onedrive.sh

The script will print colour-coded progress lines and write a full log to
the path configured in log_dir/log_file.


## Output legend

    [INFO]   Informational step (loading config, detecting YubiKey, etc.)
    [OK]     File successfully decrypted.
    [SKIP]   File already exists locally; no action taken.
    [ERROR]  Decryption failed; details written to the log file.


## Summary

At the end of each run the script prints a summary:

    Files decrypted:  N
    Files skipped:    N
    Errors:           N


## Troubleshooting

YubiKey not detected
    Make sure the YubiKey is inserted and gpg --card-status returns output
    without error.

Source directory not found
    Confirm that OneDrive is mounted and the folder path in source_dir
    matches the actual path on disk.

gpg: decryption failed: No secret key
    The private key on the YubiKey does not match the key used to encrypt
    the files.  Verify that the correct key is loaded on the card.

jq: command not found
    Install jq with: brew install jq

File already exists (skipped unexpectedly)
    The destination file exists from a previous run.  Delete it manually if
    you need to re-decrypt with a different key or recover a newer version.


## Notes

- The script never deletes source .gpg files from OneDrive.
- On macOS, after a successful decrypt it calls brctl evict on the source
  .gpg file so OneDrive can remove the local copy and save disk space.
  This step is silently skipped on non-macOS systems.
- All operations are logged with timestamps so you can audit exactly which
  files were processed and when.
