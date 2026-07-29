#!/usr/bin/env bash
# HiveOS h-stats.sh for pearl GPU miner
# This script is sourced by HiveOS (not executed directly): it only needs to set
# the two variables $khs and $stats — do not echo anything.
#   khs   : total hashrate (khs)
#   stats : stats JSON

. `dirname $BASH_SOURCE`/h-manifest.conf
LOG_FILE="$CUSTOM_LOG_BASENAME.log"

khs=0
stats=""

if [[ -f $LOG_FILE ]]; then
    log_age=$(( $(date +%s) - $(stat -c %Y "$LOG_FILE") ))
    if (( log_age <= 60 )); then
        # Use a large tail window: rpc.ping and similar lines can flood the newest
        # part of the log, while large.progress lines only appear roughly every ~15s.
        # A small window risks missing the progress line entirely -> hashrate 0.
        tail_buf=$(tail -n 5000 "$LOG_FILE")

        # Most recent aggregate progress line. The current log format only emits this one:
        #   event=large.progress ... proof_per_sec="830.93 T/s" devices="[4090: 96.01T/s, ...]"
        # Scan the whole file in reverse (tac) to get the true last match, since a fixed
        # tail window can be crowded out by high-frequency lines like rpc.ping and miss it.
        # (HiveOS rotates this log with a size cap, so tac's cost is acceptable.)
        last_prog=$(tac "$LOG_FILE" \
            | grep -F 'event=large.progress' \
            | grep -vF 'event=large.progress.device' \
            | head -n 1)

        # --- per-device hashrate array device_hash_tsv (index<TAB>T/s) ---
        # Prefer the legacy per-device line event=large.progress.device (for backward
        # compatibility); if absent, fall back to parsing the aggregate devices="[...]" line.
        # e.g. ... event=large.progress.device device=0 ... proof_per_sec="69.53 T/s"
        device_hash_tsv=$(echo "$tail_buf" \
            | grep -F 'event=large.progress.device' \
            | awk '
                {
                    dev=""
                    for (i=1;i<=NF;i++)
                        if ($i ~ /^device=/) { split($i,a,"="); dev=a[2] }
                    # proof_per_sec="69.53 T/s" contains a space, so match against the full line
                    if (dev!="" && match($0, /proof_per_sec="[0-9.]+/)) {
                        s=substr($0, RSTART, RLENGTH); sub(/proof_per_sec="/, "", s)
                        rate[dev]=s                      # later occurrence overwrites -> latest value
                        seen=1
                        if (dev+0 > maxd) maxd=dev+0
                    }
                }
                END {
                    # If no per-device lines were found, emit nothing so the aggregate-line
                    # fallback below can take over.
                    if (seen)
                        for (k=0; k<=maxd; k++)
                            printf "%d\t%s\n", k, (k in rate ? rate[k] : "0")
                }')

        # Aggregate-line fallback: read per-GPU rate by position from
        # devices="[4090: 96.01T/s, ...]". Split on /, */ instead of /,[[:space:]]*/ for
        # compatibility with older mawk (no POSIX character classes). Rate is extracted with
        # /[0-9.]+T\/s/ to handle both "96.01T/s" (no space) and the "4090: ..." model prefix.
        if [[ -z $device_hash_tsv && -n $last_prog ]]; then
            device_hash_tsv=$(echo "$last_prog" \
                | awk '{
                    if (match($0, /devices="\[[^"]+\]"/)) {
                        devices=substr($0, RSTART+10, RLENGTH-12)
                        n=split(devices, item, /, */)
                        for (i=1;i<=n;i++)
                            if (match(item[i], /[0-9.]+T\/s/)) {
                                rate=substr(item[i], RSTART, RLENGTH); sub(/T\/s$/,"",rate)
                                printf "%d\t%s\n", i-1, rate
                            }
                    }
                }' | sort -n -k1,1)
        fi

        # Total hashrate (T/s): prefer the authoritative total proof_per_sec="<X> T/s" reported
        # on the aggregate line (avoids drift from rounding individual card values before summing).
        # If unavailable, fall back to summing the per-card values; otherwise 0.
        proof_per_sec=$(echo "$last_prog" \
            | grep -oE 'proof_per_sec="[0-9.]+' | tail -n 1 | cut -d'"' -f2)
        if [[ -z $proof_per_sec || $proof_per_sec =~ ^0+([.]0+)?$ ]]; then
            proof_per_sec=$(echo "$device_hash_tsv" | awk -F'\t' '{s+=$2} END{printf "%.2f", s+0}')
        fi
        [[ -z $proof_per_sec ]] && proof_per_sec=0

        # T/s -> khs:  1 T/s = 10^12 /s = 10^9 khs
        khs=$(awk -v p="$proof_per_sec" 'BEGIN{printf "%.3f", p * 1000000000}')

        # JSON hs array, one value per GPU in khs (x1e9). If the log has no per-device
        # breakdown, fall back to a single-element array with the total.
        if [[ -n $device_hash_tsv ]]; then
            hs_json=$(echo "$device_hash_tsv" \
                | awk -F'\t' '{printf "%.3f\n", $2 * 1000000000}' \
                | jq -Rn '[inputs|tonumber? // 0]')
        else
            hs_json=$(awk -v p="$proof_per_sec" 'BEGIN{printf "[%.3f]", p * 1000000000}')
        fi

        # --- per-device telemetry (temp / fan / power) + bus_numbers, all from nvidia-smi ---
        # Previously this was parsed out of the miner log's ASCII device-table rows, which is
        # fragile: column positions shift between miner versions/log formats and silently break
        # (this was flagged as unreliable). nvidia-smi is the authoritative source and is what
        # the other miner's h-stats.sh already uses successfully, so we adopt that approach here.
        #
        # bus_numbers tells HiveOS which physical GPU each array index corresponds to (this
        # machine also has an Intel iGPU that HiveOS counts as its own row, so without
        # bus_numbers HiveOS cannot map N hs values onto the right rows). Since h-run.sh sets
        # CUDA_DEVICE_ORDER=PCI_BUS_ID, the miner's device index order and nvidia-smi's default
        # (PCI-bus-ordered) listing should line up, so hs[i]/temp[i]/fan[i]/power[i]/bus_numbers[i]
        # all refer to the same GPU.
        temp_json="[]"; fan_json="[]"; power_json="[]"; bus_json=null
        if command -v nvidia-smi >/dev/null 2>&1; then
            gpu_query=$(nvidia-smi --query-gpu=pci.bus,temperature.gpu,fan.speed,power.draw \
                --format=csv,noheader,nounits 2>/dev/null)
            if [[ -n $gpu_query ]]; then
                temp_json=$(awk -F',' '{v=$2; gsub(/ /,"",v); print (v=="N/A"?0:v+0)}' <<< "$gpu_query" \
                    | jq -Rn '[inputs|tonumber? // 0]')
                fan_json=$(awk -F',' '{v=$3; gsub(/ /,"",v); print (v=="N/A"?0:v+0)}' <<< "$gpu_query" \
                    | jq -Rn '[inputs|tonumber? // 0]')
                power_json=$(awk -F',' '{v=$4; gsub(/ /,"",v); print (v=="N/A"?0:int(v+0))}' <<< "$gpu_query" \
                    | jq -Rn '[inputs|tonumber? // 0]')

                # Only emit bus_numbers when the GPU count matches hs length: better to omit
                # the mapping than to map it incorrectly.
                hs_count=$(echo "$hs_json" | jq 'length')
                gpu_count=$(echo "$gpu_query" | grep -c .)
                if (( hs_count > 0 && hs_count == gpu_count )); then
                    bus_hex=()
                    while IFS=',' read -r b _; do
                        b=${b//[[:space:]]/}
                        bus_hex+=("${b#0x}")
                    done <<< "$gpu_query"
                    bus_dec=()
                    for b in "${bus_hex[@]}"; do bus_dec+=( $((16#$b)) ); done
                    bus_json=$(printf '%s\n' "${bus_dec[@]}" | jq -Rn '[inputs|tonumber? // 0]')
                fi
            fi
        fi

        # --- uptime: measured from the miner process's own start time ---
        # BUG FIX: the previous version derived uptime from the first timestamp found in the
        # log file. That value keeps changing whenever the log is rotated/truncated (which
        # HiveOS does periodically), so uptime kept resetting every few seconds. Measuring the
        # actual miner process's runtime via /proc (or `ps etimes` as a fallback) is immune to
        # log rotation, log appends, or leftover historical log content.
        uptime_s=0
        miner_pid=""
        if [[ -n $CUSTOM_MINERBIN ]]; then
            miner_pid=$(pgrep -x "$CUSTOM_MINERBIN" | head -n1)
        fi
        if [[ -z $miner_pid ]]; then
            # Fallback pattern in case CUSTOM_MINERBIN isn't set for this build.
            miner_pid=$(pgrep -n -f 'miner-cuda(11|12|13)' 2>/dev/null)
        fi
        if [[ $miner_pid =~ ^[0-9]+$ ]] && kill -0 "$miner_pid" 2>/dev/null; then
            if [[ -r /proc/$miner_pid/stat && -r /proc/uptime ]]; then
                start_ticks=$(awk '{print $22}' "/proc/$miner_pid/stat" 2>/dev/null)
                system_uptime=$(awk '{print $1}' /proc/uptime 2>/dev/null)
                clock_ticks=$(getconf CLK_TCK 2>/dev/null || echo 100)
                uptime_s=$(awk -v u="$system_uptime" -v s="$start_ticks" -v h="$clock_ticks" \
                    'BEGIN { if (u >= 0 && s >= 0 && h > 0) printf "%d", u-s/h; else print 0 }')
            else
                uptime_s=$(ps -o etimes= -p "$miner_pid" 2>/dev/null | tr -d '[:space:]')
            fi
            [[ $uptime_s =~ ^[0-9]+$ ]] || uptime_s=0
        fi

        # --- accepted/rejected shares: from server acknowledgements event=submit.ack,
        # accepted=true/false ---
        # Must scan the whole LOG_FILE (submit.ack lines are sparse and the tail window
        # usually won't contain even one). Single-pass awk; ~0.3s measured on a 128MB file.
        # Note: counts reset to 0 whenever HiveOS rotates/truncates this log (consistent
        # with how "ar" is normally treated as a running total — acceptable).
        read accepted rejected < <(awk '
            /event=submit.ack/{
                if ($0 ~ /accepted=true/)       a++
                else if ($0 ~ /accepted=false/) r++
            }
            END { print a+0, r+0 }' "$LOG_FILE")
        : "${accepted:=0}" "${rejected:=0}"

        ver="pearl"

        stats=$(jq -nc \
            --argjson hs    "$hs_json" \
            --arg     hs_units "khs" \
            --argjson temp  "$temp_json" \
            --argjson fan   "$fan_json" \
            --argjson power "$power_json" \
            --argjson uptime "$uptime_s" \
            --arg     algo  "pearl" \
            --arg     ver   "$ver" \
            --argjson accepted "$accepted" \
            --argjson rejected "$rejected" \
            --argjson bus   "$bus_json" \
            '{hs:$hs, hs_units:$hs_units, temp:$temp, fan:$fan, power:$power,
              uptime:$uptime, ar:[$accepted,$rejected],
              algo:$algo, ver:$ver}
             + (if $bus != null then {bus_numbers:$bus} else {} end)')

        # Optional self-diagnostics: when PEARL_STATS_DEBUG=1, write key intermediate values
        # to a separate file to help track down empty columns on the rig.
        [[ -n $PEARL_STATS_DEBUG ]] && \
            printf '[h-stats] khs=%s hs=%s bus=%s uptime=%s\n' "$khs" "$hs_json" "$bus_json" "$uptime_s" \
            >> "${CUSTOM_LOG_BASENAME}-stats-debug.log" 2>/dev/null
    fi
fi

[[ -z $khs ]] && khs=0
[[ -z $stats ]] && stats='{"hs":[],"hs_units":"khs","temp":[],"fan":[],"power":[],"uptime":0,"ar":[0,0],"algo":"pearl","ver":"pearl"}'
