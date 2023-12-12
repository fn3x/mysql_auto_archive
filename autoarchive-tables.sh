#!/bin/bash

set -e

database="MY_DATABASE"
altered_tables=0

function fatal {
  echo "FATAL: $1" >&2
  echo "Exiting now." >&2
  exit 1
}

# calculate the upper limit for a partition
function partition_upper_limit {
  local partition=$1
  local interval_symbol=${partition:0:1}
  local year=${partition:1:4}
  
  case "$interval_symbol" in
    "y")
      mysql -Nse "SELECT DATE_ADD(STR_TO_DATE('$year-1-1', '%Y-%m-%d'), INTERVAL 1 YEAR)"
      ;;
    "m")
      local month=${partition:5:2}
      mysql -Nse "SELECT DATE_ADD(STR_TO_DATE('$year-$month-1', '%Y-%m-%d'), INTERVAL 1 MONTH)"
      ;;
    "w")
      local week=${partition:5:2}
      mysql -Nse "SELECT DATE_ADD(STR_TO_DATE('$year-$week Monday', '%x-%v %W'), INTERVAL 1 WEEK)"
      ;;
    *)
      fatal "Unrecognized interval symbol for partition '$partition'"
      ;;
  esac
}

while read table_name interval keep; do
  
  # sanity checks for the configuration
  if [[ ! ("$table_name" =~ ^[a-z_]+$) ]]; then
    fatal "The configured table name '$table_name' is invalid. Must contain only characters a-z and underscore."
  fi

  if [[ ! ("$interval" =~ ^(yearly|monthly|weekly)$) ]]; then
    fatal "The configured interval '$interval' for '$table_name' is invalid. Must be one of yearly, monthly, weekly."
  fi

  if [[ !("$keep" =~ ^[0-9]+$) || "$keep" == "0" || -z "$keep" ]]; then
    fatal "The configured keep value '$keep' for '$table_name' is invalid. Must be a positive number."
  fi


  echo "Starting archival of '$table_name' with '$interval' interval, keeping $keep partitions"
  
  # read current partitions (excluding "future") into an array
  readarray -t partitions < <(mysql -Nse "SELECT PARTITION_NAME FROM INFORMATION_SCHEMA.PARTITIONS WHERE TABLE_NAME='$table_name' ORDER BY PARTITION_ORDINAL_POSITION")
  unset partitions[-1]
  echo "Found partitions:          ${partitions[@]}"

  for partition in ${partitions[@]}; do
    # sanity check - the partitions naming should be consistent with config
    if [[ ("${partition:0:1}" != "${interval:0:1}") || !("$partition" =~ ^(y[0-9]{4}|[m|w][0-9]{6})$) ]]; then
      fatal "Unexpected partition name '$partition' found for interval '$interval'."
    fi

    # sanity check - the partitions upper limits should be the same as we can calculate
    upper_limit=$(mysql -Nse "SELECT FROM_DAYS(PARTITION_DESCRIPTION) FROM INFORMATION_SCHEMA.PARTITIONS WHERE TABLE_NAME='$table_name' AND PARTITION_NAME='$partition'")
    calculated_upper_limit=$(partition_upper_limit $partition)
    if [[ "$upper_limit" != "$calculated_upper_limit" ]]; then
      fatal "Unexpected upper limit '$upper_limit' in partition '$partition'. Expected '$calculated_upper_limit'."
    fi
  done

  # calculate wanted partitions and read them into an array
  case "$interval" in
    "yearly")
      date_format="y%Y"
      date_unit="YEAR"
      ;;
    "monthly")
      date_format="m%Y%m"
      date_unit="MONTH"
      ;;
    "weekly")
      date_format="w%x%v"
      date_unit="WEEK"
      ;;
    *)
      fatal "Unrecognized interval"
      ;;
  esac

  # generate a sequence of newly calculated partition names
  readarray -t new_partitions < <(for i in $(seq -$keep 1); do mysql -Nse "SELECT DATE_FORMAT(DATE_ADD(DATE(NOW()), INTERVAL $i $date_unit), '$date_format')"; done)
  echo "Calculated new partitions: ${new_partitions[@]}"

  # sanity check - total number of partitions after archival shoud be $keep + 2 (the current partition + the next partition)
  if [[ ${#new_partitions[@]} != $(($keep + 2)) ]]; then
    fatal "Unexpected number of newly calculated partitions: expected $(($keep + 2)), got ${#new_partitions[@]}."
  fi


  # compare the current and newly calculated partitions and get two arrays - partitions to add and partitions to export/delete
  partitions_to_add=()
  partitions_to_export=()

  for partition in ${partitions[@]}; do
    # partition is current but not in newly calculated -> will be exported
    if [[ !( " ${new_partitions[@]} " =~ " $partition ") ]]; then
      partitions_to_export+=($partition)
    fi
  done

  for new_partition in ${new_partitions[@]}; do
    # partition is not current but is newly calculated -> will be added
    if [[ ! (" ${partitions[@]} " =~ " $new_partition ") ]]; then
      partitions_to_add+=($new_partition)
    fi
  done

  echo "Will add partitions:       ${partitions_to_add[@]}"
  echo "Will export partitions:    ${partitions_to_export[@]}"

  # sanity check - the to-be-exported partitions should always be the ones BEFORE the first newly added one
  for partition in ${partitions_to_export[@]}; do
    if [[ $partition > ${new_partitions[0]} ]]; then
      fatal "Partition '$partition' is about to be exported but is after the first new partition '${new_partitions[0]}'."
    fi
  done

  # sanity check - the to-be-added partitions should always be the ones AFTER the last current one
  for partition in ${partitions_to_add[@]}; do
    if [[ $partition < ${partitions[-1]} ]]; then
      fatal "Partition '$partition' is about to be added but is before the last current partition '${partitions[-1]}'."
    fi
  done

  # sanity check - the "future" partition should contain no records
  future_partition_count=$(mysql $database -Nse "SELECT COUNT(*) FROM $table_name PARTITION(future)")
  if [[ "$future_partition_count" != 0 ]]; then
    fatal "There are records present in the 'future' partition of table '$table_name'! Please check this."
  fi

  lock_algorithm="ALGORITHM=INPLACE, LOCK=NONE" # force the most harmless locking

  # DANGER ZONE FOLLOWS...

  # ADDING PARTITIONS

  if [[ ${#partitions_to_add[@]} > 0 ]]; then
    altered_tables=1
    
    # drop the 'future' partition first so that we can add new ones "before" it
    echo "Dropping partition 'future'"
    mysql $database -Nse "ALTER TABLE $table_name $lock_algorithm, DROP PARTITION future"
  
    # add new partitions
    for partition in ${partitions_to_add[@]}; do
      # calculate the new less_than_date for the partition
      upper_limit=$(partition_upper_limit $partition)

      echo "Adding partition '$partition' with dates till '$upper_limit'"
      mysql $database -Nse "ALTER TABLE $table_name $lock_algorithm, ADD PARTITION (PARTITION $partition VALUES LESS THAN (TO_DAYS('$upper_limit')))"
    done

    # add the 'future' partition
    echo "Adding partition 'future'"
    mysql $database -Nse "ALTER TABLE $table_name $lock_algorithm, ADD PARTITION (PARTITION future VALUES LESS THAN (MAXVALUE))"
  fi


  # EXPORTING PARTITIONS

  # alter table outgoing_mails algorithm=inplace, lock=none, add partition (partition future values less than (maxvalue))
  if [[ ${#partitions_to_export[@]} > 0 ]]; then
    altered_tables=1

    for partition in ${partitions_to_export[@]}; do
      echo "Exporting partition '$partition'"
      ./export-partition.sh $table_name $partition
    done
  fi

  echo

done < <(cat ./autoarchived-tables.txt | grep -v "^#" | grep -v "^$")


# if we altered tables, echo something to STDERR to trigger sending email from crontab!
if [[ $altered_tables > 0 ]]; then
  echo "ALTERED TABLES!" >&2
fi
