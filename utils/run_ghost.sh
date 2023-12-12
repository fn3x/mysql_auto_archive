#!/bin/bash

function usage {
  echo "Use ./run_ghost.sh table_name 'alter_command' [other_ghost_args]"
  exit 1
}

host="localhost"
database="database"
user="user"
port=25060
password="password"
table=$1
shift

if [ "$table" == "" ]; then
  usage
fi

alter=$1
shift

if [ "$alter" == "" ]; then
  usage
fi

cut_over_file=/root/bin/gh-ost-cut-over.txt
touch $cut_over_file

gh-ost --host=$host --port=$port  --database=$database \
         --table=$table \
   --user=$user \
   --password=$password \
         --alter="$alter" \
         --chunk-size=2000 --max-load=Threads_connected=50 \
         --allow-on-master --ssl --ssl-allow-insecure --exact-rowcount \
         --initially-drop-ghost-table --initially-drop-socket-file \
         --verbose $*
