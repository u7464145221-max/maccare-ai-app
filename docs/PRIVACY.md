# MacCare AI – privacy

As of October 15, 2026. This description follows from the program's code and is checked by tests (test names in brackets).

## In short
- MacCare AI sends no data off your Mac. There are no accounts, no telemetry, no analytics and no remote crash reports.
- There are two network connections and both depend on you:
  - the local Ollama language-model server at `127.0.0.1` (only if you have it installed; any non-local address is blocked – `LoopbackSessionTests`);
  - checking for updates on GitHub – only when you click “Check for updates” or turn on “once a week” (off by default). It is a single request for the latest release; the program sends no data about your Mac and never downloads or installs a new version by itself (`UpdateCheckerTests`). As with any request, GitHub sees your IP address.
- After launch the program changes nothing. Changes are possible only in Edit mode, which you turn on yourself and which turns off after 15 minutes of inactivity. Currently Edit mode only lets you move items you selected yourself (in My Files and in Cleanup) to the Trash, and uninstall an app you chose together with the data of it you selected – always after your confirmation.

## What the program reads
- **File names, sizes and dates** – for the disk map, large files and Cleanup. It does not read file contents, except for:
  - **Duplicates** – it compares the contents of files of the same size (a cryptographic hash) so that different files are never confused.
  - **Similar photos** – it reads photo thumbnails.
- **System information** – CPU and memory load, battery condition, temperature, security settings (SIP, Gatekeeper, FileVault, firewall), login items, open ports, crash reports from `~/Library/Logs/DiagnosticReports`. This uses system interfaces and a fixed list of system commands that run only with specific read-only arguments (`CommandExactArgumentsTests`).
- **Cloud files** (iCloud, Dropbox and similar): the program never triggers a download. A file that is not on the disk is skipped and marked as unread (`PathPolicyHardeningTests`).

## What the program stores (only on your Mac)
Everything lives in `~/Library/Application Support/MacCare AI`:
- `history.sqlite` – scan history, detected issues, measurement samples (condensed after 7 days), the operations log and settings. Paths inside your home folder are stored with “~” instead of your account name.
- `diskmap-cache.lzfse` – remembered folder sizes, so the disk map appears instantly after launch (paths with “~”).
- `quarantine` – items moved to quarantine (this path is currently off – Cleanup moves items to the Trash). They can be restored. After 7 days they may be deleted permanently, but only in Edit mode – in read-only mode the program does not delete them (`expiredQuarantineIsNotPurgedOnStartupInReadOnly`).

Appearance settings (such as the map view or the menu bar icon) are stored in the app's standard preferences. Edit mode is never stored – after every launch the program is read-only (`ExecutionGuardTests`).

## AI assistant
The assistant runs only locally: through Ollama on your Mac or through Apple's on-device model. The measurements you ask about go only to that local model. The assistant has read-only tools and changes nothing; proposed operations are shown to you as a preview.

## Report export
A report is created only when you ask for it and saved where you choose. There are three scopes: minimal (no paths or names), standard (user name, computer name and e-mail addresses replaced with placeholders) and full (for your own use only).

## Permissions
- **Full Disk Access** – optional. Without it some folders (such as Mail and Safari) are skipped and the result is marked as incomplete.
- **Administrator password** – only in the macOS system dialog, when you ask for detailed sensors yourself (a one-time `powermetrics` reading). The password never reaches the program and is not stored.

## How to delete the program's data
Quit MacCare AI and move the folder `~/Library/Application Support/MacCare AI` to the Trash. Appearance preferences are removed together with the app.
