# 验证记录 / Validation record

## 中文

目标为 README 中哈希锁定的 CM70 TBC 定制核心与 V4 场景布局。使用隔离 MySQL 端口 13317 进行集成测试；控制器计算副本使用 13318、世界端口 18086。测试资料不是正式服领奖记录。

已通过：

- S1：预览、仅当季坐骑、正式结算、重复结算拒绝、SQL 失败恢复、完整撤销及撤销后重新结算。
- S1→S2：下一季统计重置；模拟事务提交后中断，恢复保留已提交结果且不再次发奖。
- S2、S3：测试数据每季 196 名角色获奖、28 份当季坐骑、6 名冠军成员；之前赛季邮件仍保留。数字仅表示测试数据，不是固定名额。
- S3 在 Windows PowerShell 5.1 下再次完整执行，验证撤销后重新预览/结算。
- 实际 BAT 入口、中文菜单、中文名单与正常退出；UTF-8 BOM、UTF-8 SQL 输入及重复 Path/PATH 环境兼容处理。
- 旧脚本停用/原字节恢复、同名文件保护、队伍变化时重算原端重置结果、计算中数据变化拒绝、结算文件哈希一致性。
- 原核心启动、就绪、观察、正常关闭后的快照比对：角色头衔、货币、竞技场统计/成员、工具所发奖励邮件及物品均不变。可分发证据见 `evidence/runtime-restart-test.json`。

S1/S2 主流程记录来自 2026-09-06；S3、PowerShell 5.1 及入口/重启回归完成于 2026-09-27。没有等待完整 90 天，没有验证所有未知定制核心回调。

手动验收：

1. 保留完整备份。每次操作前退出游戏、关闭世界服、保留 MySQL；操作完成后再开服。
2. 选 1：普通战场与基础荣誉商店可用，竞技场正常排队入口和赛季商人关闭。紫色荣誉散件不能单独证明阶段错误。
3. 选 2 开始 S1：核实竞技场入口、虚空风暴 **52区** 的 S1 商品、比赛次数和评级记录。51区是错误称呼。
4. 有符合原端资格的队伍后关服，选 5、11 查看名单，选 6 结算。开服后用名单中对应角色验收邮件、坐骑学习/召唤、头衔选择与重登。关服后再次选 6 应拒绝。
5. 选 3 开始 S2，再重复步骤 3–4；之后选 4 开始 S3 并重复。核实每季仅新增本季坐骑，旧坐骑不丢失。S1 30609、S2 34092、S3 37676；冠军头衔规则见 README。
6. 如需测试撤销，在结算后尚未重新开服时立即选 8；应恢复进行中状态并撤回该次奖励。已产生新数据后拒绝撤销属于正常保护。

实际客户端验收尚未由本轮开发执行。用户手动测试会真实切换自己的服务器并发奖。无合格角色时可以验证状态切换与空名单，但不能声称已验证实际奖励。

## English

Target: the hash-locked custom CM70 TBC core and V4 layout described in README. Integration tests used isolated MySQL port 13317; controller clones use 13318 and world port 18086. Test evidence is not a production award record.

Passed checks:

- S1 preview, season-specific mount delivery, settlement, duplicate refusal, SQL failure restoration, full undo and resettlement after verified undo.
- S1→S2 statistics reset; simulated post-commit interruption recovery retained the commit without duplicate awards.
- S2/S3 fixtures each produced 196 awarded characters, 28 season mounts and 6 champion members. Previous-season mail remained. These counts describe fixtures, not fixed quotas.
- S3 complete Windows PowerShell 5.1 run, including undo and fresh preview/settlement.
- Actual BAT launch, Chinese menu/report and clean exit; UTF-8 BOM/input and duplicate Path/PATH handling.
- Legacy disable/byte-identical restoration, conflicting-file protection, native reset recalculation after roster changes, rejection of concurrent changes and settled-plan hash verification.
- Native-core startup, readiness, observation and clean shutdown preserved character titles/currencies, arena stats/members and controller reward mail/items. Distributable evidence: `evidence/runtime-restart-test.json`.

S1/S2 main evidence dates to 2026-09-06. S3, PowerShell 5.1, launcher and restart regression checks completed on 2026-09-27. No full 90-day observation or verification of every unknown custom callback was performed.

Manual acceptance:

1. Keep a full backup. Before each operation exit the game, stop the world server and keep MySQL; restart the world only after completion.
2. Option 1: normal battlegrounds/base honor vendors remain, arena queue access and season vendors close. Purple honor off-pieces alone do not indicate a wrong stage.
3. Option 2 starts S1: check arena access, S1 inventory at **Area 52**, match counts and ratings.
4. After teams qualify under native rules, stop the world and use 5/11 to inspect winners, then 6 to settle. In-game, verify eligible characters' mail, mount learning/summoning, title selection and relogging. After stopping the world again, a second 6 must be rejected.
5. Start S2 with 3, repeat; start S3 with 4, repeat. Check only the current-season mount is newly awarded and earlier mounts remain: S1 30609, S2 34092, S3 37676. Champion-title rules are in README.
6. To verify undo, select 8 immediately after settlement and before restarting the world. It should restore the active season and retract that operation's awards. Refusal after new data is expected protection.

Client acceptance has not been performed in this development round. Manual testing changes the user's real server and grants real awards. Empty winner lists can validate state transitions, but not physical reward delivery.
