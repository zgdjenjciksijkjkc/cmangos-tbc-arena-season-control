Set-StrictMode -Version 2
function ConvertFrom-NativeArenaWinners {
    param([ValidateRange(1,3)][int]$Season,[object[]]$BeforeCharacters,
          [object[]]$NativeAfterCharacters,[object[]]$BeforeTeams,[object[]]$BeforeMembers)
    # Consume original binary output from an ISOLATED CLONE ONLY. This avoids
    # inventing a percentage/rounding formula or excluding robot accounts.
    # The future coordinator must bind both snapshots to the same input hash.
    $before=@{};$after=@{};$awards=@{}
    foreach($c in $BeforeCharacters){
        $id=[uint32]$c.guid
        if($before.ContainsKey($id)){throw 'Duplicate before character.'}
        $before[$id]=$c
    }
    foreach($c in $NativeAfterCharacters){
        $id=[uint32]$c.guid
        if(-not $before.ContainsKey($id) -or $after.ContainsKey($id)){throw 'Native result character set mismatch.'}
        $after[$id]=$c
        if($c.knownTitles -notmatch '^\s*\d+\s+\d+\s*$'){throw 'Malformed native title serialization.'}
        $v=$c.knownTitles.Trim() -split '\s+'
        $first=[uint64]$v[0];$second=[uint64]$v[1]
        if($first -gt 4294967295 -or $second -gt 4294967295){throw 'Native title word overflow.'}
        $tier=$null
        if($first -band [uint64]536870912){$tier='Gladiator'}
        elseif($first -band [uint64]1073741824){$tier='Duelist'}
        elseif($first -band [uint64]2147483648){$tier='Rival'}
        elseif($second -band [uint64]1){$tier='Challenger'}
        if($tier){$awards[$id]=$tier}
    }
    if($after.Count -ne $before.Count){throw 'Native result omitted characters.'}
    if($Season -gt 1){
        foreach($type in @(2,3,5)){
            $teams=@($BeforeTeams | Where-Object {[int]$_.type -eq $type} | Sort-Object {[int]$_.rating} -Descending)
            if($teams.Count -eq 0){continue}
            $leaders=@($teams | Where-Object {[int]$_.rating -eq [int]$teams[0].rating})
            $leaderIds=@($leaders | ForEach-Object {[uint32]$_.arenateamid})
            $winners=@($BeforeMembers | Where-Object {[uint32]$_.arenateamid -in $leaderIds -and $awards[[uint32]$_.guid] -eq 'Gladiator'})
            if($winners.Count -eq 0){continue}
            if($leaders.Count -gt 1){throw "${type}v$type 出现并列第一，无法自动确定永久冠军头衔归属；本次不会正式发奖，请先确认分配规则。"}
            foreach($m in $winners){$awards[[uint32]$m.guid]='Champion'}
        }
    }
    @($awards.Keys | Sort-Object | ForEach-Object {[pscustomobject]@{Guid=$_;Tier=$awards[$_]}})
}
Export-ModuleMember -Function ConvertFrom-NativeArenaWinners
