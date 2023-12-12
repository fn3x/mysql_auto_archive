#!/bin/bash

# "panic button" when run in a for loop:
# exit

port=25060
database="database"
export_dir="archive/"

set -e

if [ -z "$DO_UUID" ]; then
  echo "Digital Ocean's database UUID variable DO_UUID is not set."
  echo "Example: SET DO_UUID=45dd2d3f-2n9e-40e5-9f7d-13a3541abe2c"
  exit 1
fi

if [ -z "$DO_TOKEN" ]; then
  echo "Digital Ocean's access token variable DO_TOKEN is not set."
  echo "Example: SET DO_TOKEN=dop_v1_b92e78646237c539fd633e632d8d0255a597f51dbd1fb34dff044a967cf366ff"
  exit 1
fi

if [ -z "$MYSQL_USER_ALIAS" ]; then
  echo "MySQL user alias is not configured"
  echo "Example: mysql_config_editor set --login-path=sample_alias --host=localhost --user=root --password"
  echo "SET MYSQL_USER_ALIAS=sample_alias"
  exit 1
fi

# reset max exec. time on exit
function cleanup {
  local exit_status=$?
  curl -X PATCH \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DO_TOKEN" \
    -d '{"config": {"connect_timeout": "120"}}' \
    "https://api.digitalocean.com/v2/databases/$DO_UUID/config"
  exit $exit_status
}
trap cleanup INT TERM EXIT


start_time=$SECONDS

# switch off query time limit
curl -X PATCH \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DO_TOKEN" \
  -d '{"config": {"connect_timeout": "0"}}' \
  "https://api.digitalocean.com/v2/databases/$DO_UUID/config"

if [ $# -lt 2 ]; then
  echo "usage export-partition.sh <db_table_name> <time_string>"
  echo "e.g. export-partition.sh yearly_archived_table y2021"
  echo "or   export-partition.sh monthly_archived_table m202111"
  echo "or   export-partition.sh weekly_archived_table w202150"
  exit 1
fi

table=$1
shift
time_string=$1
shift
temp_table="${table}_${time_string}"
export_file_name=$temp_table

# count rows in partition
echo "Counting rows in partition ${table}#${time_string}..."
rows=`mysql --login-path=$MYSQL_USER_ALIAS --port=$port $database -Nse "SELECT COUNT(*) FROM $table PARTITION($time_string)"`
echo "Found $rows row in partition"

echo "Exchanging ${table}#${time_string} partition to ${temp_table}"
mysql -e "CREATE TABLE $temp_table LIKE $table"
mysql --login-path=$MYSQL_USER_ALIAS --port=$port $database -e "ALTER TABLE $temp_table REMOVE PARTITIONING"
mysql --login-path=$MYSQL_USER_ALIAS --port=$port $database -e "ALTER TABLE $table EXCHANGE PARTITION $time_string WITH TABLE $temp_table"

# sanity check
count=`mysql --login-path=$MYSQL_USER_ALIAS --port=$port $database -Nse "SELECT COUNT(*) FROM $temp_table"`
echo "Found $count rows in $temp_table"
if [ $rows = $count ]; then
  echo "Sanity check OK!"
else
  echo "Sanity check failed: $rows rows vs. $count count"
  exit 1
fi

echo "Exporting $temp_table to $export_dir/$table/$export_file_name.gz"
mkdir -p $export_dir/$table
mysqldump --login-path=$MYSQL_USER_ALIAS --port=$port --create-options --single-transaction \
          $database $temp_table | gzip -f > $export_dir/$table/$export_file_name.gz
ls -lh $export_dir/$table/$export_file_name.gz

echo "Dropping table $temp_table"
mysql --login-path=$MYSQL_USER_ALIAS --port=$port $database -e "DROP TABLE $temp_table"

echo "Dropping partition ${table}#${time_string}"
mysql --login-path=$MYSQL_USER_ALIAS --port=$port $database -e "ALTER TABLE $table DROP PARTITION $time_string"

elapsed_time=$(($SECONDS - $start_time))
echo "Done exporting in $(($elapsed_time / 60)) min $(($elapsed_time % 60)) sec"

echo
