# MacCare AI – privacy

As of October 16, 2026 (after an independent audit that found incorrect statements in the previous version of this description). This description follows from the program's code and is checked by tests (test names in brackets).

## In short
- MacCare AI sends no data off your Mac. There are no accounts, no telemetry, no analytics and no remote crash reports.
- There are two network connections and both depend on you:
  - the local Ollama language-model server at `127.0.0.1` (only if you have it installed; any non-local address is blocked and redirects are not followed – `LoopbackSessionTests`). Models that Ollama runs in the cloud (e.g. names ending in “-cloud”) are skipped and refused – a request to them would leave your Mac (`LocalOnlyModelTests`);
  - checking for updates on GitHub – only when you click “Check for updates” or turn on “once a week” (off by default). It is a single request for the latest release; the program sends no data about your Mac and never downloads or installs a new version by itself (`UpdateCheckerTests`). As with any request, GitHub sees your IP address.
- The program sends no DNS queries for test domains – DNS diagnostics show only the local configuration (`dnsDiagnosticsShowsLocalConfigurationWithoutQueries`).
- After launch the program changes nothing. Changes are possible only in Edit mode, which you turn on yourself and which turns off after a period of inactivity you choose in Settings (5–60 min, 15 by default). Currently Edit mode only lets you move to the Trash: items you selected yourself (in My Files and in Cleanup), an app you chose together with the data of it you selected, and selected leftovers of apps that are no longer installed – always after your confirmation. The AI assistant cannot perform any of these operations (`LLMActionInvariantTests`).

## What the program reads
- **File names, sizes and dates** – for the disk map, large files and Cleanup. It does not read file contents, except for:
  - **Duplicates** – it compares the contents of files of the same size (a cryptographic hash) so that different files are never confused.
  - **Similar photos** – it reads photo thumbnails.
  - **Apps and login items** – it reads their description (`Info.plist`) and has the system check their code signature.
- **System information** – CPU and memory load, battery condition, temperature, security settings (SIP, Gatekeeper, FileVault, firewall), login items, open ports, crash reports from `~/Library/Logs/DiagnosticReports`. This uses system interfaces and a fixed list of system commands that run only with specific read-only arguments (`CommandExactArgumentsTests`).
- **Running programs** – so that it never cleans the cache of a program that is working right now, the program checks your account's process list and reads the command-line arguments of **each** of those processes, but keeps only the names of recognised developer tools (such as npm, cargo, xcodebuild). It does not analyse the processes' environment variables; nothing from this is stored or sent (`ToolActivityTests`).
- **Installed apps** – the Applications folders and the system app database (LaunchServices), so that data of an app installed elsewhere is never treated as a leftover.
- **Cloud files** (iCloud, Dropbox and similar): the program never triggers a download. A file that is not on the disk is skipped and marked as unread (`PathPolicyHardeningTests`).

## What the program stores (only on your Mac)
In `~/Library/Application Support/MacCare AI`:
- `history.sqlite` – scan history, detected issues, measurement samples (condensed after 7 days), the operations log, before/after measurements and settings. Paths inside your home folder are stored with “~” instead of your account name in every table (`HistoryRedactionTests`). If the database gets damaged, the damaged file is kept next to it as `history.sqlite.corrupt-…`.
- `diskmap-cache.lzfse` – remembered folder sizes, so the disk map appears instantly after launch (paths with “~”).
- `bench` – a temporary folder for the file-speed measurement taken during operations in Edit mode; the measurement files are deleted right away.
- `quarantine` – items moved to quarantine (this path is currently off – Cleanup moves items to the Trash). Permanent deletion from quarantine is currently unavailable, even in Edit mode (`expiredQuarantineIsNotPurgedOnStartupInReadOnly`).

The app's standard preferences (`~/Library/Preferences/io.github.u7464145221-max.maccare.plist`) store appearance settings (such as the map view or the menu bar icon), whether update checks and notifications are on, and the time of the last check and of the last notifications. Edit mode is never stored – after every launch the program is read-only (`ExecutionGuardTests`).

## AI assistant
The assistant runs only locally: through Ollama on your Mac (with a model running on your Mac) or through Apple's on-device model. The measurements you ask about go only to that local model. The assistant has read-only tools and changes nothing; proposed operations are shown to you as a preview.

## Report export
This version of the app has no report export. This description will be updated when it does.

## Permissions
- **Notifications** – optional, off by default. When you turn them on in Settings, macOS asks for permission once; MacCare then shows local notifications only about low disk space, a critical Protection issue and a new version – each kind at most once a day, with nothing sent off your Mac (`ImportantNotifierTests`).
- **Full Disk Access** – optional. Without it some folders (such as Mail and Safari) are skipped and the result is marked as incomplete.
- **Administrator password** – only in the macOS system dialog, when you ask for detailed sensors yourself (a one-time `powermetrics` reading). The password never reaches the program and is not stored.

## How to delete the program's data
Quit MacCare AI and move to the Trash the folder `~/Library/Application Support/MacCare AI` and the preferences file `~/Library/Preferences/io.github.u7464145221-max.maccare.plist` (macOS does not remove it by itself when you move the app to the Trash).
