#!/bin/bash
#Версия v0.2

# Настройки майнера
WAL=45as9Yj3ctg2JfQFsUxkygQ65vsBAmLtQE
WKN=7945hx-24_M-dai
PW=x

# Интенсивность
COUNT=8     # Кол-во экземпляров
THR=4        # Кол-во потоков на экземпляр
INT=-20      # Лучшее - -20, худшее - 20, увеличивать при слете экземпляров
MSRMOD=true  # Индивидуально true/false. Поддерживает Intel Nehalem+ и AMD zen(1-4)


# Команда без taskset (он добавится позже)
BASE_CMD="./testv4 -Xmx1g -Xms1g -Xss256k -u ${WAL}.${WKN} -h tht.mine-n-krush.org -P 5001 -t $THR -p x"

#Отладчик
log_path="/mnt/ramlogdisk" # Если отказываться от ramdiskа, то изменить на /var/log
log_pattern="miner-*.log"  # Название логов майнера, пока CONST
log_lines_keep=18000       # максимальное количество строк в логе. Чтобы не засорять память.
interval=30                # интервал вывода показателей (сек). Можно снизить, чуть улучшит производиьельность. Стандарт 30, можно и 15 и любое др. значение
ramdisk=true               # Включить логирование на ОЗУ чтобы не тратить ресурс диска true/false
startlat=1.0               # Задержка перед запуском следущей screen сессии. Не факт но может влиять. Пока неподтверждено поэтому 0.0, ради тестов можно 1.0

# Окончание настроек
###############################################################################

killall java
#Ramlogdisk
if [ "$ramdisk" = true ]; then
    mkdir -p /mnt/ramlogdisk
    mount -t tmpfs -o size=1G tmpfs /mnt/ramlogdisk
else
    umount /mnt/ramlogdisk 2>/dev/null
    rm -rf /mnt/ramlogdisk
fi

# MSRMOD

if [ "$MSRMOD" = true ]; then
  echo "MSRMOD is enabled"
  modprobe msr allow_writes=on
  if grep -E 'AMD Eng Sample|AMD Ryzen|AMD EPYC' /proc/cpuinfo > /dev/null;
    then
    if grep "cpu family[[:space:]]\{1,\}:[[:space:]]25" /proc/cpuinfo > /dev/null;
      then
        if grep "model[[:space:]]\{1,\}:[[:space:]]97" /proc/cpuinfo > /dev/null;
          then
            echo "Detected Zen4 CPU"
            wrmsr -a 0xc0011020 0x4400000000000
            wrmsr -a 0xc0011021 0x4000000000040
            wrmsr -a 0xc0011022 0x8680000401570000
            wrmsr -a 0xc001102b 0x2040cc10
            echo "MSR register values for Zen4 applied"
          else
            echo "Detected Zen3 CPU"
            wrmsr -a 0xc0011020 0x4480000000000
            wrmsr -a 0xc0011021 0x1c000200000040
            wrmsr -a 0xc0011022 0xc000000401570000
            wrmsr -a 0xc001102b 0x2000cc10
            echo "MSR register values for Zen3 applied"
          fi
      else
        echo "Detected Zen1/Zen2 CPU"
        wrmsr -a 0xc0011020 0
        wrmsr -a 0xc0011021 0x40
        wrmsr -a 0xc0011022 0x1510000
        wrmsr -a 0xc001102b 0x2000cc16
        echo "MSR register values for Zen1/Zen2 applied"
      fi
  elif grep "Intel" /proc/cpuinfo > /dev/null;
    then
      echo "Detected Intel CPU"
      wrmsr -a 0x1a4 0xf
      echo "MSR register values for Intel applied"
  else
    echo "No supported CPU detected"
    echo "Failed to apply MSRMOD"
  fi
else
  echo "MSRMOD is disabled"
fi

# RAMFREQ
ramfr=$(sudo dmidecode --type memory | grep "Configured Memory Speed" | awk -F': ' '{print $2}' | head -n1)
rams=$(sudo dmidecode --type memory | grep -i "Size:" | grep -v "No Module Installed" | awk '{sum += $2} END {print sum " GB"}')

# Запуск экземпляров с привязкой к ядрам
for i in $(seq 0 $((COUNT - 1))); do
    SESSION="miner-$((i+1))"
    CPU_START=$((i * THR))
    CPU_END=$((CPU_START + THR - 1))
    # Формируем список ядер: например, "0,1,2,3"
    CPU_LIST=$(seq -s, $CPU_START $CPU_END)
    echo "[+] Запускаю screen-сессию $SESSION на ядрах $CPU_LIST"
    screen -L -Logfile /mnt/ramlogdisk/"miner-$((i+1))".log -dmS "$SESSION" bash -c "taskset -c $CPU_LIST $BASE_CMD"
    sleep "$startlat"
done

echo "[✓] Все $COUNT screen-сессий запущены с CPU-биндингом."

# Размеры скользящих окон
size_1m=$((60 / interval))
size_5m=$((300 / interval))
size_15m=$((900 / interval))
size_60m=$((3600 / interval))
# Массивы для хранения значений
declare -a window_1m=()
declare -a window_5m=()
declare -a window_15m=()
declare -a window_60m=()
# ======================= ФУНКЦИИ ===========================
calc_avg() {

  local a


