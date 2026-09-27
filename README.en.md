# CMaNGOS TBC Arena Season Controller V5

[中文说明](README.md)

A Windows offline tool with a Chinese batch-file menu for preseason, S1–S3, settlement preview, reward delivery and guarded undo. Its workflow is inspired by the [CMaNGOS Classic Ahn'Qiraj event controller](https://github.com/zgdjenjciksijkjkc/cmangos-classic-ahnqiraj-event-control). No core rebuild is needed.

**Target: the tested custom CM70 / CMaNGOS TBC 2.4.3 server with the V4 arena world layout already installed. This is not a generic upstream CMaNGOS installer. The V4 data initializer is not included.** Unsupported binaries or databases are rejected; do not remove checks to force installation.

## Download and installation

Choose **Code → Download ZIP**, or download `downloads/cmangos-tbc-arena-controller-v5.zip` from this repository. The latter contains only runtime files and documentation. Install either package, not one nested inside the other.

Place the complete extracted folder **directly inside the server root**. The server root contains `mangosd.exe`, `mangosd.conf`, `aiplayerbot.conf` and `Database`; it is not the game client folder.

```text
C:\cm70\70CM20260312\                   <- server root
├─ mangosd.exe
├─ mangosd.conf
├─ aiplayerbot.conf
├─ ahbot.conf
├─ Database\bin\
│  ├─ mysql.exe
│  ├─ mysqld.exe
│  ├─ mysqldump.exe
│  └─ mysqladmin.exe
├─ data\                                <- actual path follows DataDir
└─ cmangos-tbc-arena-season-control\      <- tool folder; name may change
   ├─ 启动竞技场控制器.bat
   ├─ Start-Arena.ps1
   ├─ ArenaControl.ps1
   ├─ Storage.psm1
   ├─ Shadow.psm1
   ├─ WorldLayout.psm1
   ├─ RewardEngine.psm1
   ├─ NativeWinnerAdapter.psm1
   ├─ README.md
   └─ README.en.md
```

### Paths and folder names

| Item | Requirement |
|---|---|
| Tool folder name | No fixed name. `cmangos-tbc-arena-season-control`, GitHub's `cmangos-tbc-arena-season-control-main`, or a timestamped name works. The original Chinese delivery folder name was tested. |
| Folder depth | The double-click launcher checks only its own directory and its immediate parent for `mangosd.conf`. Extra nesting such as `server\tools\extracted-package\launcher.bat` prevents automatic detection. |
| Runtime files | Keep the BAT, both PS1 files and all five PSM1 files together with their exact names. Copying the BAT alone will not work. |
| Flat installation | All runtime files may also be placed directly in the server root. A separate child folder is recommended to avoid mixing or overwriting files. |
| Server root name | `70CM20260312` is not hard-coded. Only the tested CM70 environment is verified. Prefer a short local path such as `C:\cm70\70CM20260312`. Other root path character combinations are not fully verified; avoid PowerShell wildcard characters such as `[` and `]`, network shares and deep nesting. |
| Renaming the tool folder | Allowed if all files stay together directly under the same server root. The ledger is not bound to the tool folder name. |
| Moving the server after activation | Do not rename the server root, move it to another drive, or change the database target after first activation. Control records bind to the root path, database port and database names. This version has no automatic migration procedure. |
| Backup directory | Automatically stored at `server-root\.arena-settlement-v5`. Do not delete, rename, relocate independently or publish it. It may contain account/character data, configuration passwords and database clones. |
| Encoding | PS1/PSM1 files use UTF-8 with BOM for Windows PowerShell 5.1. Do not resave them as ANSI or remove the BOM. The launcher switches the console to UTF-8. |

**Correct:** `C:\cm70\70CM20260312\cmangos-tbc-arena-season-control-main\启动竞技场控制器.bat`

**Incorrect:** `C:\cm70\70CM20260312\download\cmangos-tbc-arena-season-control-main\启动竞技场控制器.bat`

Advanced users can explicitly pass the root path; normal use needs no command line:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\tools\arena\ArenaControl.ps1" -ServerRoot "C:\cm70\70CM20260312" -Action Status
```

Optional `-ToolRoot` points to the root containing `Database\bin`, not to the script folder. It defaults to the server root.

## Prerequisites

- Windows; Windows PowerShell 5.1 and the actual BAT launcher were tested. The runtime menu is currently Chinese.
- Stop all `mangosd` world processes before operations; keep the production MySQL instance running. Normal battlegrounds remain available during preseason.
- Write access to the server root, backup and temporary directories. The database account needs permissions to read/dump data and perform the tool's updates and table creation.
- Use the tested bundled MySQL 5.7 tools. Preview needs several GB or more of free disk space, depending on database size. Ports `127.0.0.1:13318` and `18086` must be free.
- Valid `DataDir`, complete core dependencies/DLLs and configuration files. The clone uses the existing game data.
- All five configured database connections must use the same local instance and account/password. World database must be `tbcmangos`; character database must be `tbccharacters`. Remote databases or arbitrary database renaming are unsupported.
- Critical character, arena statistics/member, mail and item tables, and controller ledger tables, must use InnoDB.
- `AiPlayerbot.RandomBotAutoJoinBG = 0` is required. The tool does not disable ordinary battleground bot settings or filter bots out of award eligibility.
- Custom event 33 must not be active. V4 event, condition and NPC layout checks must pass.
- Tested `mangosd.exe` SHA-256: `66CF3C31A26649B4BF6ABC690281508D464D42BC644F37B999EF4EB1D000793E`. Other binaries are rejected.

Keep a full server database backup before use. The tool's operation snapshots cover specific restoration tasks; they are not a complete disaster-recovery backup.

## Usage

1. Exit the game and stop `mangosd`. Keep MySQL running.
2. Double-click `启动竞技场控制器.bat`.
3. Select an option. When prompted, enter `YES` or `Y`; confirmation matching is case-insensitive. Other input cancels.
4. Wait for completion, return to the menu and select `0`. Then restart the world server. Do not start the production world server during preview.

| Option | Function |
|---:|---|
| 1 | Preseason: no settlement or season awards. Returning here is blocked after later season progress or settlement. |
| 2 | Start S1. |
| 3 | Start S2; S1 must already be settled. |
| 4 | Start S3; S2 must already be settled. |
| 5 | Preview current-season settlement in an isolated database/core clone. No production awards. |
| 6 | Official settlement using a valid preview. Grants awards and closes season content, leaving a waiting state. |
| 7 | Status. Reports offline settings and ledger state, not a substitute for in-game NPC/mail checks. |
| 8 | Undo the latest operation only when the complete recorded post-operation state still matches. Restart/gameplay/claiming rewards will typically block it. Undoing an undo is unsupported. |
| 9 | Recover an interrupted operation. Checks whether the transaction committed and preserves committed results without granting twice. |
| 10 | Restore the scene and recognized legacy launcher from before V5 activation. Does not roll back gameplay. Blocked while official settlement awards remain. |
| 11 | View the most recent preview report. It describes the state when generated, not proof of current award delivery. |
| 0 | Exit. |

Sequence: `Preseason → S1 → Preview → Settle → S2 → Preview → Settle → S3 → Preview → Settle`. Settlement itself creates the waiting state; there is no separate intermission option. No S4 start/settlement option is provided.

## Eligibility and rewards

This release **preserves the custom server's award proportions and eligibility, correcting only season-specific rewards**. The original binary calculates winners in an isolated clone, including both players and bots. It does not reproduce the historical retail award percentages.

| Season | Gladiator mount item ID | Season champion title ID | Other arena title IDs |
|---|---:|---:|---|
| S1 | 30609 | Generic Gladiator 42; no later Classic Infernal Gladiator title | 42–45 |
| S2 | 34092 | 62, Merciless Gladiator | 42–45 |
| S3 | 37676 | 71, Vengeful Gladiator | 42–45 |

- Eligible gladiators receive at most one season mount per character; multiple brackets use the highest award tier.
- S2/S3 champion titles are added only for members of each bracket's unique top-rated team whom the native core already qualified as gladiators. A top-team tie is rejected rather than guessed.
- Native clone side effects such as multiple-season mounts and currency overwrites are not imported into production.
- Settlement preserves honor and arena points and does not distribute weekly points. Team statistics reset when the next season starts, using native clone reset results. Teams are not deleted.
- Permanent titles remain; temporary arena titles are updated at subsequent settlement. Starting a season does not automatically qualify characters for rewards.

## Undo, legacy controllers and event 56

The tool uses pre-operation snapshots, SQL transactions, a database duplicate-prevention ledger and interruption journals. Non-transactional world/event tables are backed up/restored separately. Character awards, mail, items and ledger updates commit in one transaction. Failures trigger restoration where safe; unresolved cases retain evidence and report an error.

First activation recognizes marked legacy `ArenaSeasonControl.ps1` files in the root or immediate child folders and renames them with `.disabled-by-v5`, retaining their contents. Use only V5 afterwards. Restoration refuses to overwrite a conflicting new file.

V5 keeps event 56 continuously active while relocating its S4 content and isolating S4 vendor conditions to avoid the native end callback reproduced on this binary. **Event 56 in `game_event_status` during preseason or S1–S3 is therefore expected.** Do not apply the older rule of allowing only one active event; inspect V5 ledger state and content associations together. Do not stop event 56 with GM commands or execute native `arena sendRewards` on production.

The protection schedule ends in 2050; the controller refuses the old setup from 2049 onward. Without source for the custom binary, unknown callbacks cannot all be ruled out. Do not manually alter the protection event.

## Troubleshooting

| Symptom / message | Cause and action |
|---|---|
| Missing `mangosd.conf`, module or `mysql.exe` | Excessive nesting, partial copy or incomplete `Database\bin`. Follow the installation tree and preserve filenames. |
| Window closes, garbled Chinese or PowerShell parse error | Re-extract the complete package and preserve UTF-8 BOM. Run the BAT, not an individual PSM1. If security software blocked a file, identify the affected file first. |
| World server must be stopped | A `mangosd` process remains, possibly another test server. Close the appropriate world server; keep MySQL. |
| Access denied / directory not writable / file lock | Insufficient filesystem rights or another controller window is open. Close the other controller or use a writable local installation. Deleting the ledger is not a fix. |
| SQL failure, database Access denied or connection refused | MySQL is down, configuration is wrong or account permissions are insufficient. Check local configuration; redact passwords and character data before sharing logs. |
| V4 world preflight / event description / core version mismatch | Missing V4 layout, another tool changed data, or a different binary. This repository does not install V4 automatically. Do not bypass checks. |
| Ports 13318 / 18086 occupied | Another clone or application uses them. Identify it before stopping it; do not stop production MySQL by mistake. |
| Clone initialization / world readiness / shutdown failure | Check disk space, TEMP write access, DataDir, DLLs and clone logs: `mysql-init.err`, `mysql.err`, `world.out`, `world.err` under the corresponding `preview-*` folder. Partial clone results cannot be used for production awards. |
| Preview expired / production data changed during evaluation | Gameplay, points, roster, mail or other data changed. Stop the world server and repeat option 5, then proceed directly to 6. |
| Only active S1–S3 can settle | Preseason or a settled state cannot grant awards. Check option 7; advance to the next season in order. |
| Settle S1 / S2 first | Season skipping is blocked. Complete preview and settlement of the preceding season. |
| Empty winner list | No matches or insufficient native qualification may be normal. A few matches do not guarantee awards; an empty list does not validate physical reward delivery. |
| Champion cannot be uniquely determined / tied first place | Preserve the report and logs and verify the native ranking rule. Do not edit the preview file. |
| Undo refused / post-operation data changed | New data exists or the complete post-commit record is unavailable. This is expected protection, not permission to force a rollback. |
| Pending operation / transaction already committed | Keep the world server stopped and use option 9. Do not repeatedly settle or delete `pending.path`/ledger records. |
| Binding mismatch / local backups missing | Root moved, database replaced or `.arena-settlement-v5` lost. Restore the matching original path and backups. Automatic migration is unsupported. |
| Event 56 / S4 isolation / season dates changed | A legacy controller or GM command may have altered them. Keep the world server stopped and preserve logs/backups while investigating. |
| Original-scene restoration blocked by awards | Option 10 cannot reactivate native automatic behavior while V5 settlement awards remain. |
| Purple honor off-pieces / active event 56 | Neither alone identifies the season. Preseason uses the existing base honor inventory; it does not reconstruct every historical patch's inventory. |

Console logs are in `server-root\.arena-settlement-v5\logs`. Include the selected action, full error and redacted logs in an issue. Do not publish raw configs, database clones, account data or the entire backup folder.

## Validation and distributed files

Isolated database workflows, undo, duplicate blocking, interruption recovery, the Windows PowerShell 5.1 launcher and native-core restart protection passed. **Real-client NPC visibility, mail receipt, mount learning/summoning and title display still require in-game acceptance.** See [validation and manual checks](docs/VALIDATION.md).

This repository distributes controller source, documentation and an installable ZIP. It contains no server binaries, extracted client data, account databases, configuration passwords or real backups. `SHA256SUMS.txt` records checksums. No open-source license declaration has been added.
