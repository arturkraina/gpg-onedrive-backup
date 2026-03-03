# encrypt-to-onedrive.sh

A POSIX shell script that encrypts local files with GPG and copies them to
OneDrive for off-site backup.  Encryption uses a GPG public key whose private
counterpart is stored on a YubiKey (or any GPG smart card accessible via
gpg-agent).


## How it works

1. Reads encrypt-config.json from the same directory as the script.
2. Checks that a YubiKey is connected and recognised by gpg-agent.
3. For each directory listed in source_dirs, walks it recursively and
   encrypts every eligible file with GPG, appending a .gpg extension.
4. For each directory listed in copy_only_dirs, copies files verbatim
   without encryption (intended for content that is already encrypted, such
   as a pass(1) password store).
5. Skips any file whose encrypted counterpart in the destination already
   exists and is newer than the source (incremental backup).
6. Respects excluded_dirs and excluded_files lists to avoid backing up
   build artifacts, temporary files, and other unwanted content.


## Requirements

- gpg (GNU Privacy Guard)
- jq  (brew install jq)
- A YubiKey or other GPG smart card; the corresponding public key must be
  imported in the local GPG keyring


## Files

    encrypt-to-onedrive.sh     The script itself.
    encrypt-config.json     Configuration (paths, recipient, exclusions).
    logs/encrypt.log        Append-only session log (created automatically).


## Configuration (encrypt-config.json)

    source_dirs         Array of local directories to encrypt recursively.
                        Use ~ for the home directory.
                        Example: ["~/Documents"]

    copy_only_dirs      Array of local directories to copy without encryption.
                        Example: ["~/.password-store"]

    dest_dir            Root of the OneDrive folder where encrypted files will
                        be written.  A /Documents sub-folder is appended
                        automatically.
                        Example: "~/OneDrive - YOUR_ORG"

    log_dir             Directory where encrypt.log will be written.
                        Example: "~/Documents/_encrypt/logs"

    log_file            Name of the log file.
                        Example: "encrypt.log"

    gpg_recipient       GPG key identifier for the encryption recipient.
                        Can be an e-mail address or a key fingerprint.
                        The corresponding public key must exist in the
                        local keyring (gpg --list-keys).
                        Example: "your@email.com"

    excluded_dirs       Array of directory names to skip during traversal.
                        These are matched by base name, not full path, so
                        ".git" excludes every .git folder found anywhere
                        in the source tree.
                        Recommended macOS system directories to exclude:
                        .AppleDouble, .Spotlight-V100, .Trashes, .fseventsd,
                        .DocumentRevisions-V100, .TemporaryItems
                        Example: [".git", "node_modules", ".Spotlight-V100"]

    excluded_files      Array of filename patterns (shell glob syntax) to
                        skip.  Matched against the base name of each file.
                        Supports wildcards: "._*" matches all AppleDouble
                        resource fork files, "*.icloud" matches iCloud
                        placeholder files.
                        Example: [".DS_Store", "._*", "*.gpg"]

    included_dirs       Reserved for future use; leave as an empty array.
                        Example: []

Example encrypt-config.json:

    {
      "source_dirs": [
        "~/Documents"
      ],
      "copy_only_dirs": [
        "~/.password-store"
      ],
      "dest_dir": "~/OneDrive - YOUR_ORG",
      "log_dir": "~/Documents/_encrypt/logs",
      "log_file": "encrypt.log",
      "gpg_recipient": "your@email.com",
      "excluded_dirs": [
        ".git",
        "node_modules",
        "__pycache__",
        ".venv",
        "venv",
        ".terraform",
        "_encrypt",
        ".AppleDouble",
        ".Spotlight-V100",
        ".Trashes",
        ".fseventsd",
        ".DocumentRevisions-V100",
        ".TemporaryItems"
      ],
      "excluded_files": [
        ".DS_Store",
        ".localized",
        ".apdisk",
        ".VolumeIcon.icns",
        "._*",
        "*.icloud",
        "*.gpg",
        "*.tfstate",
        "*.tfstate.backup",
        ".terraform.lock.hcl"
      ],
      "included_dirs": []
    }


## Setup

1. Install dependencies.

        brew install gnupg jq

2. Import the GPG public key that will be used for encryption.

        gpg --import your-public-key.asc

   Verify it appears in the keyring:

        gpg --list-keys

3. Copy encrypt-config.json to the same folder as encrypt-to-onedrive.sh
   and adjust the values for your environment.

4. Make the script executable.

        chmod +x encrypt-to-onedrive.sh


## Usage

Insert your YubiKey, then run:

    ./encrypt-to-onedrive.sh

The script will print colour-coded progress lines and write a full log to
the path configured in log_dir/log_file.


## Output legend

    [INFO]   Informational step (loading config, detecting YubiKey, etc.)
    [OK]     File successfully encrypted or copied.
    [SKIP]   Destination file already up to date; no action taken.
    [ERROR]  Encryption or copy failed; details written to the log file.


## Summary

At the end of each run the script prints a summary:

    Files encrypted:  N
    Files copied:     N
    Files skipped:    N
    Errors:           N


## Troubleshooting

YubiKey not detected
    Make sure the YubiKey is inserted and gpg --card-status returns output
    without error.

gpg: 'your@email.com' is not a valid key
    Run gpg --list-keys and confirm the recipient key is present.  Import
    it with gpg --import if missing.

gpg: encryption failed: Unusable public key
    The key may be expired or have no encryption-capable subkey.  Check the
    key details with gpg --list-keys --with-colons.

jq: command not found
    Install jq with: brew install jq

Destination directory not found
    OneDrive may not be mounted.  Confirm the path in dest_dir matches
    the actual mount point on disk.

Files are re-encrypted on every run
    The modification timestamp of the destination .gpg file is older than
    the source, or the .gpg file was deleted from the cloud.  This is
    expected behaviour; the script overwrites stale copies automatically.


## Notes

- The script never deletes source files from the local machine.
- Existing encrypted files are overwritten only when the source is newer,
  making subsequent runs fast (incremental).
- The _encrypt directory itself is always excluded to prevent the script
  from encrypting its own log files and configuration.
- All operations are logged with timestamps so you can audit exactly which
  files were processed and when.
