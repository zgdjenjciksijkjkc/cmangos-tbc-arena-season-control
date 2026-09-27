Set-StrictMode -Version 2
function New-ArenaWorldLayoutSql {
    param([ValidateSet('Preseason','S1','S2','S3','SettledS1','SettledS2','SettledS3')][string]$State)
    # Input layout must first pass Get-ArenaWorldPreflightSql. World tables are
    # MyISAM: caller MUST persist a recoverable snapshot before executing this.
    $active=0
    if($State -match '^S([123])$'){$active=52+[int]$Matches[1]}
    $b=[Text.StringBuilder]::new()
    foreach($table in @('game_event_creature','game_event_creature_data','game_event_gameobject','game_event_mail','game_event_quest')){
        [void]$b.AppendLine("UPDATE $table SET event=SIGN(event)*(ABS(event)+2000) WHERE ABS(event) IN (53,54,55,56);")
        if($active){
            $park=$active+2000
            [void]$b.AppendLine("UPDATE $table SET event=SIGN(event)*(ABS(event)-2000) WHERE ABS(event)=$park;")
        }
    }
    [void]$b.AppendLine(@'
UPDATE game_event SET schedule_type=1,occurence=0,length=1,linkedTo=0 WHERE entry IN (53,54,55,2053,2054,2055,2056);
UPDATE game_event_time SET start_time='1970-01-01 00:00:00',end_time='1970-01-01 00:00:00' WHERE entry IN (53,54,55,2053,2054,2055,2056);
UPDATE game_event SET schedule_type=1,occurence=525600,length=525600,linkedTo=0 WHERE entry=56;
UPDATE game_event_time SET start_time='2000-01-01 00:00:00',end_time='2050-01-01 00:00:00' WHERE entry=56;
UPDATE conditions SET value1=2056 WHERE condition_entry=507 AND type=12 AND value1 IN (56,2056);
'@)
    if($active){
        [void]$b.AppendLine("UPDATE game_event SET schedule_type=1,occurence=525600,length=525600,linkedTo=0 WHERE entry=$active;")
        [void]$b.AppendLine("UPDATE game_event_time SET start_time='2000-01-01 00:00:00',end_time='2050-01-01 00:00:00' WHERE entry=$active;")
    }
    $b.ToString()
}

function Get-ArenaWorldPreflightSql {
    # Every returned violation must equal zero. This deliberately targets the
    # previously installed V4 data layout, not an arbitrary CMaNGOS database.
    @'
SELECT 'definitions',ABS(8-(SELECT COUNT(*) FROM game_event WHERE entry IN (53,54,55,56,2053,2054,2055,2056)))
UNION ALL SELECT 'times',ABS(8-(SELECT COUNT(*) FROM game_event_time WHERE entry IN (53,54,55,56,2053,2054,2055,2056)))
UNION ALL SELECT 'condition507',ABS(1-(SELECT COUNT(*) FROM conditions WHERE condition_entry=507 AND type=12 AND value1 IN (56,2056) AND value2=0 AND value3=0 AND value4=0 AND flags=0))
UNION ALL SELECT 'conditionsS1S3',ABS(3-(SELECT COUNT(*) FROM conditions WHERE condition_entry IN (504,505,506) AND type=12 AND value1=condition_entry-451 AND value2=0 AND value3=0 AND value4=0 AND flags=0))
UNION ALL SELECT 'unexpected-season-condition',COUNT(*) FROM conditions WHERE type=12 AND value1 IN (53,54,55,56,2053,2054,2055,2056) AND condition_entry NOT IN (504,505,506,507)
UNION ALL SELECT 'vendor507',ABS(396-(SELECT COUNT(*) FROM npc_vendor_template WHERE condition_id=507))
UNION ALL SELECT 'creatureS1',ABS(17-(SELECT COUNT(*) FROM game_event_creature WHERE ABS(event) IN (53,2053)))
UNION ALL SELECT 'creatureS2',ABS(20-(SELECT COUNT(*) FROM game_event_creature WHERE ABS(event) IN (54,2054)))
UNION ALL SELECT 'creatureS3',ABS(26-(SELECT COUNT(*) FROM game_event_creature WHERE ABS(event) IN (55,2055)))
UNION ALL SELECT 'creatureS4',ABS(32-(SELECT COUNT(*) FROM game_event_creature WHERE ABS(event) IN (56,2056)))
UNION ALL SELECT 'dataS1',ABS(0-(SELECT COUNT(*) FROM game_event_creature_data WHERE event IN (53,2053)))
UNION ALL SELECT 'dataS2',ABS(3-(SELECT COUNT(*) FROM game_event_creature_data WHERE event IN (54,2054)))
UNION ALL SELECT 'dataS3',ABS(6-(SELECT COUNT(*) FROM game_event_creature_data WHERE event IN (55,2055)))
UNION ALL SELECT 'dataS4',ABS(8-(SELECT COUNT(*) FROM game_event_creature_data WHERE event IN (56,2056)))
UNION ALL SELECT 'manager-links',ABS(4-(SELECT COUNT(*) FROM game_event_creature WHERE guid=12967 AND event IN (53,54,55,56,2053,2054,2055,2056)))
UNION ALL SELECT 'duplicate-creature',COUNT(*) FROM game_event_creature a JOIN game_event_creature b ON a.guid=b.guid AND ABS(a.event)+2000=ABS(b.event) AND SIGN(a.event)=SIGN(b.event) WHERE ABS(a.event) IN (53,54,55,56)
UNION ALL SELECT 'duplicate-data',COUNT(*) FROM game_event_creature_data a JOIN game_event_creature_data b ON a.guid=b.guid AND a.event+2000=b.event WHERE a.event IN (53,54,55,56)
UNION ALL SELECT 'unsupported-gameobject',COUNT(*) FROM game_event_gameobject WHERE ABS(event) IN (53,54,55,56,2053,2054,2055,2056)
UNION ALL SELECT 'unsupported-mail',COUNT(*) FROM game_event_mail WHERE ABS(event) IN (53,54,55,56,2053,2054,2055,2056)
UNION ALL SELECT 'unsupported-quest',COUNT(*) FROM game_event_quest WHERE event IN (53,54,55,56,2053,2054,2055,2056);
'@
}
Export-ModuleMember -Function New-ArenaWorldLayoutSql,Get-ArenaWorldPreflightSql
