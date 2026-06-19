#!/bin/bash

MODEL_NAME=""
PHYSICAL_CORES=""
LOGICAL_CORES=""
CPU_USAGE=()

get_cpu_info() {
    MODEL_NAME=$(grep -m 1 "model name" /proc/cpuinfo | cut -d: -f2)
    PHYSICAL_CORES=$(grep -m 1 "cpu cores" /proc/cpuinfo | cut -d: -f2)
    LOGICAL_CORES=$(grep -m 1 "siblings" /proc/cpuinfo | cut -d: -f2)
    echo "========== cpuinfo =========="
    #cat /proc/cpuinfo
    echo "Имя модели: $MODEL_NAME"
    echo "Кол-во Физических ядер: $PHYSICAL_CORES"
    echo "Кол-во Логических ядер: $LOGICAL_CORES"
}

get_cpu_info

get_cpu_stat() {
    echo "========== stat =========="
    LOGICAL_CORES=$(grep -m 1 "siblings" /proc/cpuinfo | cut -d: -f2)
    
    local TOTAL_VAL=$(grep 'cpu ' /proc/stat | awk '{u1=$2+$4; u2=$2+$4+$5} END {printf "%d %d", u1, u2}' | xargs)
    read -r PART1 PART2 <<< "$TOTAL_VAL"
    CPU_USAGE+=("$PART1")
    CPU_USAGE+=("$PART2")

    local CORE_LIST=$(seq 0 $((LOGICAL_CORES-1)) | paste -sd'|')
    local PATTERN="^cpu($CORE_LIST) "

    while read -r line; do
        RAW_DATA=$(echo "$line" | awk '{u1=$2+$4; u2=$2+$4+$5} END {printf "%d %d", u1, u2}')
        
        read -r PART1 PART2 <<< "$RAW_DATA"
        
        CPU_USAGE+=("$PART1")
        CPU_USAGE+=("$PART2")
        
    done < <(grep -E "$PATTERN" /proc/stat)
    
}


get_cpu_stat
sleep 1

SNAPSHOT_SIZE=$(( 2 + (LOGICAL_CORES * 2) ))

while true; do
    get_cpu_stat
    for ((i=0; i<=$((${#CPU_USAGE[@]}))/2-1; i+=2)); do
            #echo ${CPU_USAGE[$i]}
            #echo ${CPU_USAGE[$i+34]}
            echo "CPU$(($i/2)): $(((${CPU_USAGE[$i+34]} - ${CPU_USAGE[$i]})*100/(${CPU_USAGE[$i+35]} - ${CPU_USAGE[$i+1]})))%"
    done
    CPU_USAGE=("${CPU_USAGE[@]:$((${#CPU_USAGE[@]}/2)):$((${#CPU_USAGE[@]}/2))}")
    sleep 1
done




#grep 'cpu ' /proc/stat
#grep 'cpu ' /proc/stat | awk '{usage=$2} END {print usage}'
#grep 'cpu ' /proc/stat | awk '{usage=$4} END {print usage}'
#grep 'cpu ' /proc/stat | awk '{usage=$5} END {print usage}'

#grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5)} END {print usage "%"}'
#top -bn1 | grep "Cpu(s)" | sed "s/.*, \([0-9,\.]*\)%* id.*/\1/" | awk '{print 100 - $1"%"}'

#echo "========== diskstats =========="
#cat /proc/diskstats
#echo "========== loadavg =========="
#cat /proc/loadavg 
#echo "========== meminfo =========="
#cat /proc/meminfo
#echo "========== stat =========="
#cat /proc/stat
#echo "========== uptime =========="
#cat /proc/uptime